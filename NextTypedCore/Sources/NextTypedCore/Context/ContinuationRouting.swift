/// Where a continuation ghost is painted: inline (flowing after the caret, wrapping at the document
/// margin) vs a below-line bubble. The pure decision the overlay's `showContinuation` routes on —
/// lifted out of the App (`OverlayWindowController`) so it is unit-testable, mirroring `CaretOverlap`.
public enum ContinuationPlacement: Equatable, Sendable {
    /// Inline gray ghost after the caret, wrapping at the document's left text margin when long.
    case inlineWrapped
    /// A rounded bubble below/above the caret line — used when inline would overlap host text, or when
    /// a wrapped inline line couldn't be placed correctly.
    case bubble
    /// SPLIT: the leading words that fit are painted inline on the caret line (a single line that
    /// never wraps), the overflow goes into the below-line bubble. The Electron marker path's
    /// partial-fit band — inline there must never wrap (the wrapped line's glyph margin is
    /// unreadable), but a fitting head is still worth showing where the text actually is
    /// .
    case splitInlineAndBubble
}

/// The inline-vs-bubble routing for a continuation ghost (two presentation modes).
public enum ContinuationRouting {
    /// Decide the placement for a continuation.
    ///
    /// - `hasTextToRight`: host text on the SAME line as the caret → an inline ghost would paint over
    ///   it → bubble.
    /// - `hasTextBelow` + would-wrap (`!fitsInline`, the STRICT threshold — the WHOLE ghost fits): a
    ///   long continuation would wrap onto host text on the line below (soft-wrapped paragraph / next
    ///   paragraph) → bubble. Strict because any wrap at all overlaps the text below.
    /// - `usesMarkerGeometry` + no room for a meaningful inline chunk (`!roomForMeaningfulInline`, the
    ///   RELAXED threshold): on the Electron/Chromium **text-marker path** a wrapped line's left margin
    ///   is not reliably readable (the glyph margin only surfaces at a `loc==0`-with-text read, which the
    ///   type-forward flow never produces; every char-0 marker route is dead),
    ///   so a continuation that would wrap lands its tail a hair left of the text. We tolerate that when a
    ///   meaningful leading chunk still shows inline, and only fall back to the bubble when the caret is
    ///   so close to the right edge that inline would wrap almost immediately. **This is the
    ///   `shouldBubbleOnWrap` rule** — the RELAXED threshold keeps inline until ~1–2 words of room remain,
    ///   instead of bubbling as soon as the whole ≤5-word ghost stops fitting (which fired at ~¾ of the
    ///   line).
    /// - `usesMarkerGeometry` + a meaningful chunk fits but the WHOLE ghost doesn't (`roomForMeaningfulInline
    ///   && !fitsInline`, the partial-fit band) → `splitInlineAndBubble`: paint the fitting head inline
    ///   (the caret x IS glyph-accurate) and spill the rest into the bubble, so inline **never wraps** on
    ///   the marker path (the leftover "unschöner Umbruch" that survived /05).
    /// - otherwise `inlineWrapped` (fits, or wraps into empty space below with a known CFRange margin).
    ///
    /// `fitsInline` / `roomForMeaningfulInline` are the App's geometry measurements (does the whole
    /// ghost / its leading ~2 words fit in the caret line's remaining width?); everything else is a
    /// surface-independent boolean, so the whole routing is pure.
    public static func placement(hasTextToRight: Bool, hasTextBelow: Bool, usesMarkerGeometry: Bool,
                                 fitsInline: Bool, roomForMeaningfulInline: Bool) -> ContinuationPlacement {
        if hasTextToRight { return .bubble }
        if hasTextBelow && !fitsInline { return .bubble }                    // wrap would cover text below
        if usesMarkerGeometry && !roomForMeaningfulInline { return .bubble } // near right edge → immediate wrap
        if usesMarkerGeometry && !fitsInline { return .splitInlineAndBubble } // partial fit → head inline, rest below
        return .inlineWrapped
    }
}
