import ApplicationServices
import AppKit
import NextTypedCore

/// Caret geometry + best-effort matched font for the overlay.
/// `axRect` is in **Accessibility coordinates** (origin top-left of the primary
/// display, y growing down); the overlay converts to Cocoa space on the main actor.
struct CaretInfo: Sendable {
    let axRect: CGRect
    let fontName: String?
    let fontSize: CGFloat?
    /// True when there's visible text immediately to the right of the caret on the SAME
    /// line — i.e. inline ghost text would paint over it, so use the below-line bubble.
    let hasTextToRight: Bool
    /// True when there's visible host text on a line BELOW the caret (e.g. the continuation
    /// of a soft-wrapped paragraph, or the next paragraph). If a continuation would wrap, it
    /// must NOT do so inline here (it would cover that text) — use the bubble instead.
    let hasTextBelow: Bool
    /// Frame of the focused text element (AX coords) — used to clamp the right wrap margin.
    /// nil if AX doesn't expose it.
    let containerAXRect: CGRect?
    /// AX x to align WRAPPED continuation lines (and empty-line carets) to — the document's left TEXT
    /// margin (where the host's text actually starts, not the element/window edge). Sourced from the
    /// CFRange path only (char-0's left edge); `nil` on the Electron text-marker path, where that margin
    /// is not reliably readable and a wrapping continuation instead routes to the bubble.
    /// `nil` also when the CFRange read yields nothing (honest degradation).
    let textLeftMarginAX: CGFloat?
    /// True when the caret geometry came from the Electron/Chromium **text-marker** path (CFRange bounds
    /// were degenerate). Drives `ContinuationRouting`: a WRAPPING continuation bubbles here rather than
    /// inline-wrapping to the box edge, since the wrapped-line glyph margin is unreadable.
    /// CFRange surfaces (TextEdit/Safari/Notes) are `false` → inline-wrap unchanged.
    let usesMarkerGeometry: Bool
}

/// Resolves caret / word screen rectangles + font via the Accessibility API.
/// An `actor` so it's `Sendable` and AX work stays
/// off the main thread.
actor CaretLocator {
    /// How far past the caret the next-visible-char scan looks before giving up — a small bounded
    /// window (only the immediately-following text matters for the overlap decision). Shared by both
    /// scanners (`firstVisibleRectAfter` for CFRange, `markerNextVisibleRect` for text markers) so the
    /// two surfaces use one tuning knob.
    private static let visibleScanWindow = 24

    /// Caret rectangle + matched font, or `nil` if the app doesn't expose bounds.
    func caretInfo() async -> CaretInfo? {
        guard let (element, caret) = focusedElementAndCaret() else { return nil }

        // The caret's own ZERO-length rect is degenerate in many apps (zero height, or a
        // y that resolves to the wrong line) — that's what floated the ghost a line off.
        // Prefer the rect of the glyph JUST BEFORE the caret (a real line box) and anchor
        // to its trailing edge — EXCEPT at the start of a line, where that glyph is the
        // newline belonging to the line ABOVE (which would mis-place us a line up).
        let here = boundsForRange(element, location: caret, length: 0)
        let container = elementFrame(element)
        // The document's left text margin (where real text starts), not the element edge —
        // char 0's left edge is a reliable proxy for the usual uniform-margin document.
        let textLeftMargin = boundsForRange(element, location: 0, length: 1)?.minX
        let prevRect = caret > 0 ? boundsForRange(element, location: caret - 1, length: 1) : nil
        let prevIsNewline = caret > 0 && isNewline(string(element, at: caret - 1, length: 1))

        let caretRect: CGRect
        let fontLocation: Int
        // Non-nil ⇒ the Electron/Chromium text-marker path is in use (CFRange bounds were degenerate),
        // so the next-visible read must also come from markers and there is no per-character host font.
        // Carries the marker-capable element + the caret's selection marker range (read once, reused
        // for the next-visible scan so both describe the same caret).
        var markerContext: (element: AXUIElement, selection: CFTypeRef)?
        if prevIsNewline, let prev = prevRect, prev.height > 0 {
            // START OF A NEW LINE: the glyph before the caret is the newline on the line
            // ABOVE — never anchor to it. The caret sits on the line BELOW. Use `here` only
            // if it really resolved onto that lower line; otherwise (the common AX quirk
            // where `here` snaps back to the previous line's end) synthesize a rect at the
            // document's left margin one line down.
            if let h = here, h.height > 0, h.minY >= prev.maxY - 1 {
                caretRect = h
            } else {
                let leftX = textLeftMargin ?? container?.minX ?? prev.minX
                caretRect = CGRect(x: leftX, y: prev.maxY, width: 0, height: prev.height)
            }
            fontLocation = caret - 1
        } else if let prev = prevRect, prev.height > 0,
                  // not at the start of a soft-wrapped line (caret's own rect is a line lower)
                  !(here.map { $0.minY >= prev.maxY - 1 } ?? false) {
            caretRect = CGRect(x: prev.maxX, y: prev.minY, width: 0, height: prev.height)
            fontLocation = caret - 1
        } else if let h = here, h.height > 0 {
            caretRect = h
            fontLocation = max(caret - 1, 0)
        } else {
            // AX gave us a caret INDEX (selectedTextRange) but no USABLE CFRange bounds: `here` is
            // either nil, or a degenerate zero-height rect. Electron/Chromium apps back the plain
            // attributes (kAXValue, kAXSelectedTextRange — so value + caret index read and prediction
            // runs) but only STUB kAXBoundsForRange, returning a constant garbage rect (e.g. Claude
            // Desktop's {{0,1117},{0,0}} regardless of caret position). These apps DO implement the
            // WebKit **text-marker** AX path once the renderer a11y tree is activated, so fall back to
            // it instead of giving up. Only if markers ALSO yield nothing
            // do we suppress — never paint an off-screen / corner ghost (honest degradation).
            guard let marker = markerCaretRect(element) else {
                #if DEBUG
                if let h = here {
                    acLog("[caret]: degenerate CFRange bounds %@ and no text-marker geometry — suppressing ghost (AX caret-bounds gap; the a11y tree may still be building — type another char)",
                          NSStringFromRect(h))
                }
                #endif
                return nil
            }
            caretRect = marker.rect
            fontLocation = max(caret - 1, 0)
            markerContext = (marker.element, marker.selection)
            #if DEBUG
            acLog("[caret]: text-marker geometry rect=%@ (Electron/Chromium path)",
                  NSStringFromRect(marker.rect))
            #endif
        }

        // The marker attributed string carries no `.font`, so on the marker path leave the font nil and
        // let the overlay derive the point size from the line box (GhostFontMetrics). The CFRange path
        // reads the host's attributed-string font as before.
        let (name, size) = markerContext == nil ? font(element, location: fontLocation) : (nil, nil)
        // First VISIBLE char after the caret (skips spaces/tabs/newlines), fed to the pure-Core
        // overlap decision (`CaretOverlap`) together with the end-of-field signal (caret index vs
        // value length). End-of-field is the surface-independent guard: on rich editors AX hands
        // back a stale glyph box for the char "after" the caret even at end-of-text (claude.ai: it
        // starts left of the caret; Notes: a line below), which the old geometry-only test misread
        // as host text to the right and forced into a bubble.
        // On the marker path the CFRange scan is dead too, so source the next-visible rect from the
        // text-marker API; both feed the SAME pure-Core CaretOverlap.
        let nextVisible: CGRect?
        if let mc = markerContext {
            nextVisible = markerNextVisibleRect(mc.element, selection: mc.selection)
        } else {
            nextVisible = firstVisibleRectAfter(element, caret: caret)
        }
        let valueLength = numberOfCharacters(element)
        let caretBox = glyphBox(caretRect)
        let nextBox = nextVisible.map(glyphBox)
        // On the marker path the next-visible scan can be dead (returns nil even though text follows
        // the caret — e.g. Claude Desktop, where the marker step is unimplemented like
        // AXStartTextMarkerForTextMarkerRange was for the wrap margin). Flag the geometry unreliable so
        // CaretOverlap falls back to the surface-independent index proof and routes mid-text carets to
        // the bubble instead of painting inline over the text to the right.
        // The CFRange path keeps the reliable default → TextEdit/Safari/Notes unchanged.
        let hasRight = CaretOverlap.hasTextToRight(caretIndex: caret, valueLength: valueLength,
                                                   caret: caretBox, next: nextBox,
                                                   nextGeometryReliable: markerContext == nil)
        let hasBelow = CaretOverlap.hasTextBelow(caretIndex: caret, valueLength: valueLength,
                                                 caret: caretBox, next: nextBox)
        // The x WRAPPED inline continuation lines indent to (`textLeftMarginAX`), used by
        // `presentInlineWrapped` on the CFRange path where char-0's `minX` (`textLeftMargin`) is the
        // document text margin. On the Electron **marker path** that margin is not reliably readable
        // (the glyph margin only surfaces at a `loc==0`-with-text read, which the type-forward flow
        // never produces, and every char-0 marker route is dead), so a
        // wrapping continuation there routes to the BUBBLE instead of inline-wrapping to the box edge
        // (`ContinuationRouting`, driven by `usesMarkerGeometry`). This field is therefore unused on the
        // marker path → `nil` (no glyph-margin machinery to feed it).
        let wrapMarginAX: CGFloat? = markerContext == nil ? textLeftMargin : nil
        #if DEBUG
        // fontSize (AX logical pointSize) vs rectH (rendered line box): under host zoom these
        // diverge — the signal `matchedToRenderedSize` corrects against.
        // valueLen drives the end-of-field overlap guard (-1 = AX exposed no character count).
        // marker=1 ⇒ the Electron text-marker path (a wrapping continuation bubbles).
        acLog("[caret]: loc=%d valueLen=%d hasTextToRight=%d hasTextBelow=%d marker=%d fontSize=%.1f rectH=%.1f caretRect=%@ next=%@",
              caret, valueLength ?? -1, hasRight ? 1 : 0, hasBelow ? 1 : 0, markerContext == nil ? 0 : 1,
              Double(size ?? -1), Double(caretRect.height),
              NSStringFromRect(caretRect), nextVisible.map { NSStringFromRect($0) } ?? "nil")
        #endif
        return CaretInfo(axRect: caretRect, fontName: name, fontSize: size,
                         hasTextToRight: hasRight,
                         hasTextBelow: hasBelow,
                         containerAXRect: container,
                         textLeftMarginAX: wrapMarginAX,
                         usesMarkerGeometry: markerContext != nil)
    }

    private func isNewline(_ s: String?) -> Bool {
        guard let s, !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) }
    }


    /// Bounds of the first VISIBLE (non-whitespace) character at/after the caret, skipping
    /// spaces, tabs AND newlines, scanning a small bounded window. nil if only whitespace
    /// (or the end of text) is nearby. 1-char reads stay in-bounds (stop at end of text).
    private func firstVisibleRectAfter(_ element: AXUIElement, caret: Int) -> CGRect? {
        var i = caret
        let limit = caret + Self.visibleScanWindow
        while i < limit {
            guard let s = string(element, at: i, length: 1), let ch = s.first else { return nil }
            if !ch.isWhitespace {                       // isWhitespace covers spaces, tabs, \n
                return boundsForRange(element, location: i, length: 1)
            }
            i += 1
        }
        return nil
    }

    /// Bridge an AX `CGRect` into the pure-Core `GlyphBox` (plain `Double`s) the `CaretOverlap`
    /// decision consumes. The same-line / below-line predicates live in Core now.
    private func glyphBox(_ r: CGRect) -> GlyphBox {
        GlyphBox(minX: Double(r.minX), midY: Double(r.midY), width: Double(r.width), height: Double(r.height))
    }

    /// The focused element's total character count — the value length for `CaretOverlap`'s end-of-field
    /// overlap signal (the surface-independent guard that makes the dominant end-of-compose case render
    /// inline). Prefers `kAXNumberOfCharactersAttribute`; falls back to the `kAXValue` string's UTF-16
    /// length (matching the UTF-16 caret index from `kAXSelectedTextRange`) for apps that expose the
    /// value but not the count — e.g. Electron/Chromium. `nil` only when neither is exposed (the
    /// decision then falls back to geometry).
    ///
    /// DELIBERATELY CROSS-PATH (not marker-only): this helper runs on EVERY `caretInfo()` call — both
    /// the CFRange and the marker path — so the `kAXValue` fallback also supplies a count for a
    /// *healthy-CFRange* app that happens not to expose `kAXNumberOfCharactersAttribute`, making the
    /// end-of-field signal (the PREFERRED primary signal) authoritative
    /// there instead of leaning on geometry. That is the intended, more-robust behaviour. The tuned
    /// claude.ai-in-Safari / Apple Notes surfaces already expose the count attribute, so the fallback is
    /// additive in practice; if a tuned surface turns out to lack it, re-verify inline-vs-bubble there.
    private func numberOfCharacters(_ element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref) == .success,
           let count = (ref as? NSNumber)?.intValue {
            return count
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        return (value as NSString).length
    }

    /// Lightweight geometry probe: just the caret's screen rect, for *cheaply* detecting a
    /// zoom/scroll/window-move between full reads (the geometry poll calls this every tick;
    /// `caretInfo()`'s full read — incl. the up-to-24-read `firstVisibleRectAfter` scan — runs
    /// only once a change is detected). Returns the caret's own zero-length rect; falls back to
    /// the glyph before it where that's degenerate. nil if the app exposes no bounds.
    func caretRectProbe() async -> CGRect? {
        guard let (element, caret) = focusedElementAndCaret() else { return nil }
        if let here = boundsForRange(element, location: caret, length: 0), here.height > 0 {
            return here
        }
        return caret > 0 ? boundsForRange(element, location: caret - 1, length: 1) : nil
    }

    /// Screen rect of the `length` characters ending at the caret — positions a
    /// correction over the misspelled word.
    func wordBounds(charactersBack length: Int) async -> CGRect? {
        guard length > 0, let (element, caret) = focusedElementAndCaret() else { return nil }
        let start = max(caret - length, 0)
        return boundsForRange(element, location: start, length: caret - start)
    }

    // MARK: AX plumbing

    private func focusedElementAndCaret() -> (AXUIElement, Int)? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let value = rangeRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return (element, range.location)
    }

    private func boundsForRange(_ element: AXUIElement, location: Int, length: Int) -> CGRect? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var resultRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &resultRef) == .success,
              let result = resultRef, CFGetTypeID(result) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Best-effort font of the character at `location`, via the attributed string
    /// (works in TextEdit/Mail/Safari; nil in apps that don't provide it).
    private func font(_ element: AXUIElement, location: Int) -> (String?, CGFloat?) {
        var range = CFRange(location: location, length: 1)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return (nil, nil) }
        var resultRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXAttributedStringForRangeParameterizedAttribute as CFString, rangeValue, &resultRef) == .success,
              let attributed = resultRef as? NSAttributedString, attributed.length > 0,
              let nsFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else { return (nil, nil) }
        return (nsFont.fontName, nsFont.pointSize)
    }

    /// Plain substring for a range, or nil if the app doesn't expose it.
    private func string(_ element: AXUIElement, at location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var resultRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &resultRef) == .success,
              let s = resultRef as? String
        else { return nil }
        return s
    }

    /// Frame (AX coords) of the focused text element, from its position + size.
    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = sizeRef, CFGetTypeID(sizeVal) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: Electron/Chromium text-marker geometry (04)
    //
    // CFRange bounds (`kAXBoundsForRange`) are degenerate in these apps; Chromium instead implements
    // the WebKit **text-marker** AX path, but only once the renderer a11y tree is activated. These
    // attributes are private/undocumented → the raw CFString names are passed (no `kAX…` constants).
    // The marker rect is in the SAME AX top-left screen space as `axRect`, so the overlay's Cocoa
    // conversion is unchanged (no special Y-flip). Runtime-validated by the 2026-06-22 probe; every
    // call is gated so a missing attribute degrades to `nil` (suppress / fall back), never a crash.

    /// Caret rect via the text-marker API, for the degenerate-CFRange (Electron/Chromium) case.
    /// Activates the renderer a11y tree (capability-gated by the caller, idempotent per pid), finds the
    /// marker-capable element, then reads the collapsed selection's marker rect (zero width, line-height
    /// tall, at the caret x). Returns the rect + that element + the selection marker range (the latter
    /// two reused for the next-visible read in `markerNextVisibleRect`). `nil` if the marker path yields
    /// nothing usable.
    private func markerCaretRect(_ focused: AXUIElement) -> (rect: CGRect, element: AXUIElement, selection: CFTypeRef)? {
        activateManualAccessibility(for: focused)
        guard let el = markerCapableElement(from: focused),
              let selection = copyAttribute(el, "AXSelectedTextMarkerRange"),
              let rect = boundsForMarkerRange(el, selection), rect.height > 0
        else { return nil }
        return (rect, el, selection)
    }

    /// Bounds of the first VISIBLE (non-whitespace) character at/after the caret, via marker stepping —
    /// the marker-path analogue of `firstVisibleRectAfter`, feeding the same pure-Core `CaretOverlap`
    /// decision. `selection` is the caret's `AXSelectedTextMarkerRange`
    /// (read once in `markerCaretRect` and threaded in, so the rect and the next-visible scan describe
    /// the same caret). Steps one marker at a time from the caret's end marker, skipping whitespace,
    /// within a small bounded window. `nil` when only whitespace / end-of-text follows, or if any marker
    /// call is unavailable (the overlap decision then leans on the end-of-field signal).
    private func markerNextVisibleRect(_ el: AXUIElement, selection: CFTypeRef) -> CGRect? {
        guard var marker = paramAttribute(el, "AXEndTextMarkerForTextMarkerRange", selection)
        else { return nil }
        var steps = 0
        while steps < Self.visibleScanWindow {
            guard let next = paramAttribute(el, "AXNextTextMarkerForTextMarker", marker),
                  let range = paramAttribute(el, "AXTextMarkerRangeForUnorderedTextMarkers",
                                             [marker, next] as CFArray)
            else { return nil }
            guard let s = paramAttribute(el, "AXStringForTextMarkerRange", range) as? String,
                  let ch = s.first
            else { return nil }                       // ran off the end of the document
            if !ch.isWhitespace {                      // isWhitespace covers spaces, tabs, newlines
                return boundsForMarkerRange(el, range)
            }
            marker = next
            steps += 1
        }
        return nil
    }

    /// Turn on the Electron renderer a11y tree for the *application* owning `focused` — the sanctioned
    /// switch assistive tech uses. The policy (latch only on a successful write, forget a pid when its
    /// app quits) lives in ``ManualAccessibilityActivation``, shared with the reply harvest: it is one
    /// capability per app, and two copies of it had already drifted apart.
    private func activateManualAccessibility(for focused: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success else { return }
        ManualAccessibilityActivation.shared.activate(pid: pid, for: .caret)
    }

    /// The focused element, or the nearest ancestor (≤5 up), that advertises the text-marker bounds
    /// API. The runtime probe found the focused `AXTextArea` advertises it directly; the short walk is
    /// defensive for other Chromium surfaces.
    private func markerCapableElement(from focused: AXUIElement) -> AXUIElement? {
        var el: AXUIElement? = focused
        var depth = 0
        while let cur = el, depth < 5 {
            if advertisesMarkerBounds(cur) { return cur }
            el = parent(cur)
            depth += 1
        }
        return nil
    }

    private func advertisesMarkerBounds(_ el: AXUIElement) -> Bool {
        var namesRef: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(el, &namesRef) == .success,
              let names = namesRef as? [String] else { return false }
        return names.contains("AXBoundsForTextMarkerRange")
    }

    /// Screen rect (AX top-left coords) of a text-marker range.
    private func boundsForMarkerRange(_ el: AXUIElement, _ range: CFTypeRef) -> CGRect? {
        guard let ref = paramAttribute(el, "AXBoundsForTextMarkerRange", range),
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(ref as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// A plain (non-parameterized) AX attribute as a raw CFType — for the marker attributes that have
    /// no `kAX…` constant (e.g. `AXSelectedTextMarkerRange`). The value is an opaque `AXTextMarkerRange`
    /// with no PUBLIC `…GetTypeID()` to assert against, so it is returned untyped and only ever threaded
    /// back into the parameterized marker calls (`boundsForMarkerRange` + the stepping in
    /// `markerNextVisibleRect`). Those each guard their own result, so a wrong/foreign type yields a
    /// benign `nil` downstream rather than a force-cast — the missing type assertion here can misbehave
    /// (suppress) but cannot crash.
    private func copyAttribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &ref) == .success else { return nil }
        return ref
    }

    /// A parameterized AX attribute as a raw CFType — the marker stepping / geometry / string calls.
    private func paramAttribute(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &ref) == .success
        else { return nil }
        return ref
    }

    private func parent(_ el: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &ref) == .success,
              let p = ref, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }
}
