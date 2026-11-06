import NextTypedCore
import Foundation

/// Composes the two context mechanisms at the App layer: `AXContextProvider`
/// assembles the prefix, `windowContext`, `replyContext` and the field descriptor; this adds the
/// pixel-derived `ocrContext` on top. The `ContextProvider` seam is unchanged — the loop
/// still sees one provider returning one `TypingContext`.
///
/// The merge is deliberately trivial, and the ordering matters: AX runs **first** so its
/// `windowContext` can be handed to the OCR side as the other half of the **OCR↔AX value-check**
/// (`OCRValueCheck`). That check is what guarantees the focusedDoc prompt slot is filled by
/// `windowContext` XOR the OCR fill, never both — the double-feed that craters acceptance.
///
/// When OCR is disabled (the default) this is a pass-through: `cachedContext` returns `nil` before it
/// touches anything, so the resulting `TypingContext` is byte-identical to the AX-only one.
final class CompositeContextProvider: ContextProvider {
    private let ax: AXContextProvider
    private let ocr: ScreenOCRContextProvider

    init(ax: AXContextProvider, ocr: ScreenOCRContextProvider) {
        self.ax = ax
        self.ocr = ocr
    }

    func currentContext() async -> ContextOutcome {
        // A rejection here means the surface is unusable (secure field, chrome, no text) — OCR must not
        // resurrect it. The trust boundary is upstream of both providers.
        //
        // This `guard` is also **the whole of the pixel-side secure-field protection** and the only
        // caller that can start an OCR pass at all: a focused password field is rejected by
        // `AXContextProvider.isSecure`, so `cachedContext` below is never reached and no capture is
        // taken. See the invariant written out at `ScreenOCRContextProvider.cachedContext` before
        // moving this call, adding a second caller, or driving OCR from a timer.
        let outcome = await ax.currentContext()
        guard case .context(var context) = outcome else { return outcome }

        context.ocrContext = ocr.cachedContext(
            focusedBundleID: context.bundleID,
            axWindowContext: context.windowContext)
        return .context(context)
    }
}
