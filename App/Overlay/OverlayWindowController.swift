import AppKit
import NextTypedCore

/// Borderless, click-through overlay that paints the ghost text / correction at the
/// caret. Converts Accessibility (top-left) coordinates
/// to Cocoa (bottom-left) here. Two presentation modes: inline (wraps with the document,
/// never past the window/screen edge) and a rounded bubble below/above the line.
@MainActor
final class OverlayWindowController {
    /// One click-through panel + its ghost view. There are TWO: the `main` layer carries every
    /// single-presentation case (inline ghost, inline correction, bubble), and the `overflow` layer
    /// only the bubble half of a SPLIT continuation, which is the one
    /// case that paints in two places at once.
    @MainActor
    private final class Layer {
        let panel: NSPanel
        let view = GhostOverlayView()

        init() {
            panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .statusBar
            panel.ignoresMouseEvents = true        // click-through
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.contentView = view
        }

        func hide() {
            panel.orderOut(nil)
            view.presentation = .none   // harness state must not report a stale text after a hide
        }
    }

    private let main = Layer()
    private let overflow = Layer()

    /// How far left of the caret the inline ghost starts — one space-width when the accept will consume
    /// the preceding space, 0 otherwise. Set by `showContinuation` and read by the two inline
    /// placements below; a correction never sets it (it anchors over a word, not at the caret).
    private var inlineBackshift: CGFloat = 0

    private var panel: NSPanel { main.panel }
    private var view: GhostOverlayView { main.view }

    /// Continuation: inline gray ghost after the caret when there's room (wrapping at the
    /// document/screen edge); otherwise a suggestion bubble below/above the line.
    /// `consumesPrecedingSpace`: accepting this ghost replaces the space
    /// immediately before the caret rather than inserting after it, so painting at the caret would
    /// preview `Winter. Es` for an accept that produces `Winter. Es`. The inline ghost is therefore
    /// shifted left by one space-width, over the host's own (blank) space — the only way an additive
    /// overlay can show a subtractive edit. The **bubble** is left alone: it is a panel below the line,
    /// not an overlay on the text, so it carries no claim about the gap in front of it.
    func showContinuation(_ text: String, consumesPrecedingSpace: Bool = false, caret: CaretInfo?) {
        // Defense-in-depth: a degenerate caret rect (zero height — e.g. an Electron app that
        // stubs kAXBoundsForRange) must never paint the ghost off-screen. CaretLocator already
        // returns nil for that case; this guard makes the overlay independently safe.
        guard !text.isEmpty, let caret, caret.axRect.height > 0 else { hide(); return }
        let font = resolveFont(caret)
        inlineBackshift = consumesPrecedingSpace
            ? ceil(" ".size(withAttributes: [.font: font]).width)
            : 0
        view.presentation = .continuation(text: text)
        view.matchedFont = font
        overflow.view.matchedFont = font
        let fits = fitsInline(text, caret: caret)                       // whole ghost fits (strict)
        let room = hasRoomForMeaningfulInline(text, caret: caret)       // ≥ first ~2 words fit (relaxed)
        #if DEBUG
        acLog("[overlay]: continuation hasTextToRight=%d hasTextBelow=%d marker=%d fitsInline=%d roomInline=%d",
              caret.hasTextToRight ? 1 : 0, caret.hasTextBelow ? 1 : 0,
              caret.usesMarkerGeometry ? 1 : 0, fits ? 1 : 0, room ? 1 : 0)
        #endif
        // Inline vs bubble is the pure-Core routing decision: bubble when inline would
        // overlap host text (text to the right on this line, or a wrap onto host text below), AND —
        // on the Electron marker path — when a continuation would WRAP with the caret already near the
        // right edge (bubble-on-wrap; the wrapped-line glyph margin is
        // unreadable there). A partial-fit stays inline (`room`), so the bubble no longer fires at ~¾
        // of the line. In the band between the two thresholds — a head fits but the whole ghost doesn't —
        // the continuation is SPLIT: head inline, overflow in the bubble, so inline never wraps on the
        // marker path. The continuation bubble anchors at the line's LEFT
        // margin (stable, doesn't jump with the caret x).
        switch ContinuationRouting.placement(hasTextToRight: caret.hasTextToRight,
                                             hasTextBelow: caret.hasTextBelow,
                                             usesMarkerGeometry: caret.usesMarkerGeometry,
                                             fitsInline: fits, roomForMeaningfulInline: room) {
        case .bubble:
            overflow.hide()
            presentBubble(caret: caret, atLineStart: true)
        case .inlineWrapped:
            overflow.hide()
            presentInlineWrapped(caret: caret)
        case .splitInlineAndBubble:
            presentSplit(text, caret: caret)
        }
    }

    /// Correction: only the wrong remainder is struck (prefix-diff). Anchored over the
    /// misspelled word when there's room; otherwise shown in a bubble below/above the line.
    func showCorrection(_ original: String, replacement: String, wordRect axWordRect: CGRect?, caret: CaretInfo?) {
        // Same degenerate-rect guard as showContinuation: in an app that exposes no usable caret
        // geometry the word rect is equally degenerate, so neither inline-over-word nor the bubble
        // can be placed — suppress rather than mislocate.
        guard let caret, caret.axRect.height > 0 else { hide(); return }
        inlineBackshift = 0
        view.presentation = .correction(original: original, replacement: replacement)
        view.matchedFont = resolveFont(caret)
        #if DEBUG
        acLog("[overlay]: correction \"%@\"→\"%@\" hasTextToRight=%d inline=%d",
              original, replacement, caret.hasTextToRight ? 1 : 0,
              (axWordRect != nil && !caret.hasTextToRight) ? 1 : 0)
        #endif
        // Inline strike-over-the-word needs the word's rect to align over the host's wrong
        // letters; without it (or with text to the right) the strike can't line up, so the
        // bubble — which draws the red letters itself — is the correct presentation.
        overflow.hide()   // a correction is never split
        if let wordRect = axWordRect, !caret.hasTextToRight {
            presentInlineOverWord(anchorAX: wordRect, startAtRightEdge: false)
        } else {
            presentBubble(caret: caret)
        }
    }

    func hide() {
        main.hide()
        overflow.hide()
    }

    // MARK: Harness state (presentation truth)

    /// What one panel is *actually* showing right now — the harness's presentation truth, read from
    /// the panel/view themselves rather than from the reducer's intent.
    struct PanelState: Sendable {
        var visible: Bool
        var kind: String        // "continuation" | "correction" | "none"
        var text: String        // the drawn continuation, or "original→replacement"
        var mode: String        // "inline" | "bubble"
        var frame: CGRect       // Cocoa screen coordinates (bottom-left origin)
    }

    struct State: Sendable {
        var main: PanelState
        var overflow: PanelState
    }

    func state() -> State {
        State(main: Self.panelState(main), overflow: Self.panelState(overflow))
    }

    private static func panelState(_ layer: Layer) -> PanelState {
        let kind: String
        let text: String
        switch layer.view.presentation {
        case .none:                          kind = "none"; text = ""
        case .continuation(let t):           kind = "continuation"; text = t
        case .correction(let o, let r):      kind = "correction"; text = "\(o)→\(r)"
        }
        return PanelState(visible: layer.panel.isVisible, kind: kind, text: text,
                          mode: layer.view.isBubble ? "bubble" : "inline", frame: layer.panel.frame)
    }

    // MARK: Presentation

    /// Inline correction anchored over the misspelled word (single line; the host's own
    /// text shows through, we only overlay the strike + the green fix).
    private func presentInlineOverWord(anchorAX: CGRect, startAtRightEdge: Bool) {
        view.isBubble = false
        view.maxTextWidth = nil
        view.firstLineIndent = 0
        let font = view.matchedFont
        let cocoa = cocoaRect(fromAX: anchorAX)
        let lineHeight = max(cocoa.height, ceil(font.ascender - font.descender + font.leading))
        let width = view.intrinsicContentSize.width
        // Only the caret-anchored use (a split continuation's inline head) can carry the backshift;
        // the correction anchors over the misspelled word, where it is always 0.
        let x = startAtRightEdge ? cocoa.maxX - inlineBackshift : cocoa.minX
        let lineTopY = cocoa.maxY                       // Cocoa y of the line's top edge
        let frame = CGRect(x: x, y: lineTopY - lineHeight, width: width, height: lineHeight)
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    /// Inline continuation after the caret that WRAPS at the document's right margin
    /// (clamped to the screen) instead of overflowing. The first line starts at the caret
    /// (firstLineIndent); wrapped lines fall back to the document's left margin.
    private func presentInlineWrapped(caret: CaretInfo) {
        view.isBubble = false
        let font = view.matchedFont
        let caretCocoa = cocoaRect(fromAX: caret.axRect)
        let lineHeight = max(caretCocoa.height, ceil(font.ascender - font.descender + font.leading))
        let caretX = caretCocoa.maxX - inlineBackshift  // width-0 caret rect → minX == maxX
        let lineTopY = caretCocoa.maxY

        let screen = visibleScreenFrame(containing: caretCocoa)
        let container = caret.containerAXRect.map { cocoaRect(fromAX: $0) }
        // Wrapped lines align to the document's left TEXT margin (AX x maps 1:1 to Cocoa x),
        // not the element/window edge — so the ghost matches the document's formatting.
        let docLeft = caret.textLeftMarginAX ?? container?.minX ?? caretX
        let leftMargin = max(docLeft, screen.minX + 2)
        let rightMargin = min(container?.maxX ?? screen.maxX, screen.maxX - 2)
        let panelX = min(leftMargin, caretX)
        let panelWidth = max(rightMargin - panelX, 40)

        view.firstLineIndent = max(caretX - panelX, 0)
        view.maxTextWidth = panelWidth
        let height = max(view.intrinsicContentSize.height, lineHeight)
        let frame = CGRect(x: panelX, y: lineTopY - height, width: panelWidth, height: height)
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    /// SPLIT continuation (Electron marker path, partial-fit band): the leading words that fit are
    /// painted inline after the caret as a SINGLE line that never wraps, the rest goes into the
    /// line-start bubble below. Only the DISPLAY is split — the acceptance buffer stays one
    /// continuation, so `Tab` keeps peeling words across the boundary (the `DisplayWindow`
    /// relationship).
    private func presentSplit(_ text: String, caret: CaretInfo) {
        let parts = ContinuationSplit.split(text, fittingWords: fittingWordCount(text, caret: caret))
        #if DEBUG
        acLog("[overlay]: split inline=\"%@\" overflow=\"%@\"", parts.inline, parts.overflow)
        #endif
        // Degenerate splits (nothing fits / everything fits) can't occur under the routing thresholds,
        // but measuring is geometry — fall back to the whole-ghost presentations rather than painting
        // an empty panel.
        guard !parts.inline.isEmpty else {
            overflow.hide()
            presentBubble(caret: caret, atLineStart: true)
            return
        }
        guard !parts.overflow.isEmpty else {
            overflow.hide()
            presentInlineWrapped(caret: caret)
            return
        }
        // The tail must land BELOW the head, or the phrase reads out of order — so place the overflow
        // bubble first and give up the split (whole continuation in one bubble, free to flip above)
        // when there's no room below, e.g. a caret line near the bottom of the screen.
        overflow.view.presentation = .continuation(text: parts.overflow)
        guard presentBubble(caret: caret, atLineStart: true, in: overflow, requireBelow: true) else {
            overflow.hide()
            presentBubble(caret: caret, atLineStart: true)
            return
        }
        view.presentation = .continuation(text: parts.inline)
        // A zero-width caret rect: minX == maxX, so anchoring at its right edge starts at the caret.
        presentInlineOverWord(anchorAX: caret.axRect, startAtRightEdge: true)
    }

    /// Rounded suggestion bubble. Defaults to just below the caret's line; flips to just
    /// above when there isn't room below (bottom of screen). Width is capped to the screen.
    ///
    /// `atLineStart` anchors the bubble's left at the line's LEFT text margin instead of the caret x —
    /// a stable position under the line that doesn't jump horizontally as the caret
    /// moves, and sidesteps caret-x on the Electron marker path. The margin
    /// is `textLeftMarginAX` on the CFRange path; `nil` on the marker path, where the element's left edge
    /// (`containerAXRect.minX`) is the stable proxy (~10–15 pt left of the glyphs — fine for a bubble,
    /// which is a distinct element below the line, not an overlay on the text). AX x maps 1:1 to Cocoa x.
    /// The correction bubble keeps the caret anchor (near the word) by leaving `atLineStart` false.
    ///
    /// `in` selects the panel: the `main` layer for a whole-continuation bubble, the `overflow` layer
    /// for the bubble half of a SPLIT continuation (which paints alongside the inline head).
    ///
    /// `requireBelow` refuses the above-the-line flip and returns `false` instead, painting nothing: a
    /// SPLIT continuation's tail flipped above would read *before* its own inline head (and cover the
    /// line above), so the split falls back to a whole-continuation bubble there.
    @discardableResult
    private func presentBubble(caret: CaretInfo, atLineStart: Bool = false, in layer: Layer? = nil,
                               requireBelow: Bool = false) -> Bool {
        let layer = layer ?? main
        let view = layer.view
        view.isBubble = true
        view.firstLineIndent = 0
        let caretCocoa = cocoaRect(fromAX: caret.axRect)
        let screen = visibleScreenFrame(containing: caretCocoa)
        let anchorX = atLineStart
            ? (caret.textLeftMarginAX ?? caret.containerAXRect?.minX ?? caretCocoa.minX)
            : caretCocoa.minX
        view.maxTextWidth = max(screen.maxX - anchorX - 24, 80)   // 24 ≈ padding + margin

        let size = view.intrinsicContentSize
        let gap: CGFloat = 3
        var x = anchorX
        x = min(x, screen.maxX - size.width - 2)
        x = max(x, screen.minX + 2)

        let belowY = caretCocoa.minY - gap - size.height    // bottom-of-line, going down
        let aboveY = caretCocoa.maxY + gap                  // top-of-line, going up
        let fitsBelow = belowY >= screen.minY + 2
        guard fitsBelow || !requireBelow else { return false }
        var y = fitsBelow ? belowY : aboveY
        // Keep the whole bubble on-screen even after flipping (e.g. tall bubble, tiny line).
        y = min(max(y, screen.minY + 2), screen.maxY - size.height - 2)

        let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        layer.panel.setFrame(frame, display: true)
        view.needsDisplay = true
        layer.panel.orderFrontRegardless()
        return true
    }

    // MARK: Helpers

    private func resolveFont(_ caret: CaretInfo) -> NSFont {
        let base: NSFont
        if let name = caret.fontName, let size = caret.fontSize, let font = NSFont(name: name, size: size) {
            base = font
        } else if let size = caret.fontSize {
            base = .systemFont(ofSize: size)
        } else {
            // No host font (TextEdit/Notes/claude.ai expose none; the Electron text-marker path
            // carries none either) → derive the size from the rendered line box. Single tested
            // source of truth in Core.
            let pt = GhostFontMetrics.pointSize(forLineHeight: Double(caret.axRect.height))
            return .systemFont(ofSize: CGFloat(pt))
        }
        return matchedToRenderedSize(base, lineBox: caret.axRect.height)
    }

    /// Reconcile the matched font's SIZE against the line box actually rendered on screen.
    /// Under host zoom (e.g. trackpad pinch in TextEdit), `kAXBoundsForRange` returns RENDERED
    /// (scaled) geometry while the AX font's `pointSize` stays LOGICAL — so the matched font would
    /// draw the ghost/correction at the wrong scale, drifting the strike onto the wrong glyphs.
    /// Only rescale when the discrepancy is FAR larger than any normal line-spacing variation, so
    /// 100% zoom is untouched (the control case can't regress) and it's a harmless no-op if
    /// `pointSize` turns out to scale with zoom too.
    private func matchedToRenderedSize(_ base: NSFont, lineBox: CGFloat) -> NSFont {
        guard lineBox > 1 else { return base }
        let baseLineHeight = base.ascender - base.descender + base.leading
        guard baseLineHeight > 1 else { return base }
        let ratio = lineBox / baseLineHeight
        guard ratio < 0.6 || ratio > 1.5 else { return base }   // outside the band ⇒ zoom, not spacing
        let size = min(max(base.pointSize * ratio, 3), 400)
        return NSFont(name: base.fontName, size: size) ?? base
    }

    /// Does the WHOLE continuation fit on the rest of the caret's current line (no wrap needed)? The
    /// strict threshold — used for the text-below bubble rule (any wrap there overlaps the text below).
    private func fitsInline(_ text: String, caret: CaretInfo) -> Bool {
        textWidth(text) <= availableInlineWidth(caret)
    }

    /// Does a MEANINGFUL leading chunk (the first ~2 words) of the continuation fit on the caret line's
    /// remaining width? The relaxed threshold for the Electron marker-path bubble-on-wrap trigger
    /// : prefer inline while a useful part still shows, and only bubble when
    /// the caret is so near the right edge that inline would wrap almost immediately. Measuring the whole
    /// ≤5-word ghost (as `fitsInline` does) reserved far too much width and bubbled at ~¾ of the line.
    private func hasRoomForMeaningfulInline(_ text: String, caret: CaretInfo) -> Bool {
        textWidth(leadingWords(text, 2)) <= availableInlineWidth(caret)
    }

    /// How many leading words of the continuation fit on the caret line's remaining width — the split
    /// point for `presentSplit`. Greedy word-by-word against the same
    /// measurements the routing thresholds use, so the split agrees with the placement decision:
    /// `roomForMeaningfulInline` guarantees ≥2, `!fitsInline` guarantees < all.
    private func fittingWordCount(_ text: String, caret: CaretInfo) -> Int {
        let available = availableInlineWidth(caret)
        let total = text.split(separator: " ", omittingEmptySubsequences: true).count
        guard total > 0 else { return 0 }
        var fitting = 0
        for count in 1...total {
            guard textWidth(leadingWords(text, count)) <= available else { break }
            fitting = count
        }
        return fitting
    }

    /// Remaining width from the caret to the document's right margin (clamped to the screen).
    private func availableInlineWidth(_ caret: CaretInfo) -> CGFloat {
        let caretCocoa = cocoaRect(fromAX: caret.axRect)
        let screen = visibleScreenFrame(containing: caretCocoa)
        let container = caret.containerAXRect.map { cocoaRect(fromAX: $0) }
        let rightMargin = min(container?.maxX ?? screen.maxX, screen.maxX - 2)
        return rightMargin - caretCocoa.maxX
    }

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: view.matchedFont]).width
    }

    /// The leading up-to-`count` space-delimited words of `text`, preserving a leading space (a
    /// continuation often starts with one) so the measured width matches the render. The ghost's
    /// newlines are already flattened to spaces upstream (ClauseStop), so splitting on space suffices.
    private func leadingWords(_ text: String, _ count: Int) -> String {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return text }
        let lead = parts.prefix(count).joined(separator: " ")
        return text.hasPrefix(" ") ? " " + lead : lead
    }

    /// Visible frame (excludes menu bar / Dock) of the screen containing `cocoaRect`.
    private func visibleScreenFrame(containing cocoaRect: CGRect) -> CGRect {
        let p = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main
        return screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
    }

    private func cocoaRect(fromAX axRect: CGRect) -> CGRect {
        // AX: origin top-left of primary display, y down. Cocoa: bottom-left, y up.
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)
    }
}
