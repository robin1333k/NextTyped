import Foundation

/// The two roles screen-context OCR plays in one prediction. They occupy
/// **different prompt slots**, which is why they are separate fields rather than one blob:
///
///   - `focusedFill` is the **(A) fallback** — the focused window's own text, read from pixels because
///     AX is blind or partial there. It competes with `windowContext` for the focusedDoc slot and only
///     ever appears when `windowContext` is absent (`OCRValueCheck` decides; `PromptFront` enforces).
///   - `ambient` is the **(B) ambient reference** — the ranked Tier-2 windows, injected furthest from
///     the prefix because it is the noisiest source.
///
/// Both are already scrubbed (`SensitiveTextScrub`) and tier-filtered before they get here.
public struct OCRContext: Equatable, Sendable {
    /// Tier-2: other visible content windows, ranked and budgeted. `nil` when nothing cleared the floor.
    public var ambient: String?

    /// Tier-1: the focused window's OCR text, when the value-check found it net-new. `nil` when AX
    /// already covers the window (the common case on AX-friendly surfaces).
    public var focusedFill: String?

    public init(ambient: String? = nil, focusedFill: String? = nil) {
        self.ambient = ambient
        self.focusedFill = focusedFill
    }

    /// True when there is nothing to inject — the App uses this to avoid attaching an empty context.
    public var isEmpty: Bool {
        (ambient?.isEmpty ?? true) && (focusedFill?.isEmpty ?? true)
    }
}
