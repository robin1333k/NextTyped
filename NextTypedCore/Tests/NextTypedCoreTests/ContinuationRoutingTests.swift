import Testing
@testable import NextTypedCore

/// The inline-vs-bubble routing for a continuation ghost. Pins the base rules plus the
/// bubble-on-wrap rule for the Electron marker path: a continuation that
/// would wrap on the marker path routes to the bubble ONLY once the caret is near the right edge (the
/// relaxed `roomForMeaningfulInline` threshold — a meaningful leading chunk no longer fits), while a
/// partial-fit stays inline; the text-below rule keeps the STRICT `fitsInline` threshold; CFRange
/// surfaces keep inline-wrap unchanged.
@Suite struct ContinuationRoutingTests {
    // MARK: bubble when host text is to the right (any surface)

    @Test func textToRightAlwaysBubbles() {
        // Even if it fits and no marker path: text on the same line → inline would overlap → bubble.
        #expect(ContinuationRouting.placement(hasTextToRight: true, hasTextBelow: false,
                                              usesMarkerGeometry: false, fitsInline: true,
                                              roomForMeaningfulInline: true) == .bubble)
    }

    // MARK: bubble-on-wrap on the marker path — RELAXED threshold (the Electron tuning)

    @Test func markerPathNearRightEdgeBubbles() {
        // Caret so close to the right edge that not even a meaningful chunk fits → bubble.
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: false,
                                              usesMarkerGeometry: true, fitsInline: false,
                                              roomForMeaningfulInline: false) == .bubble)
    }

    @Test func markerPathPartialFitSplits() {
        // THE /07 REFINEMENT: the whole ghost does NOT fit (would wrap) but a meaningful leading chunk
        // DOES → show the fitting head inline and spill the rest into the bubble. Neither a full inline
        // (which would wrap with the unreadable glyph margin) nor a full bubble (which would hide a head
        // that fits where the text actually is).
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: false,
                                              usesMarkerGeometry: true, fitsInline: false,
                                              roomForMeaningfulInline: true) == .splitInlineAndBubble)
    }

    @Test func markerPathTextToRightStillBubblesWhole() {
        // The split must not loosen the overlap rules: host text on the caret line means an inline head
        // would paint over it → the WHOLE continuation goes to the bubble, no split.
        #expect(ContinuationRouting.placement(hasTextToRight: true, hasTextBelow: false,
                                              usesMarkerGeometry: true, fitsInline: false,
                                              roomForMeaningfulInline: true) == .bubble)
    }

    @Test func markerPathTextBelowStillBubblesWhole() {
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: true,
                                              usesMarkerGeometry: true, fitsInline: false,
                                              roomForMeaningfulInline: true) == .bubble)
    }

    @Test func markerPathFittingContinuationStaysInline() {
        // A continuation that fully fits on the marker path stays inline (no wrap at all).
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: false,
                                              usesMarkerGeometry: true, fitsInline: true,
                                              roomForMeaningfulInline: true) == .inlineWrapped)
    }

    // MARK: text-below keeps the STRICT threshold (any wrap overlaps the text below)

    @Test func textBelowUsesStrictFitsEvenWithRoomForChunk() {
        // With host text below, a ghost whose whole width doesn't fit would wrap ONTO it → bubble, even
        // though a meaningful chunk fits (the relaxed threshold must NOT loosen this case).
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: true,
                                              usesMarkerGeometry: false, fitsInline: false,
                                              roomForMeaningfulInline: true) == .bubble)
    }

    @Test func textBelowButFitsStaysInline() {
        // Text below only forces a bubble when the continuation would actually wrap onto it.
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: true,
                                              usesMarkerGeometry: false, fitsInline: true,
                                              roomForMeaningfulInline: true) == .inlineWrapped)
    }

    // MARK: CFRange path (TextEdit/Safari/Notes) — inline-wrap kept, never bubbles on length alone

    @Test func cfRangeWrappingIntoEmptySpaceStaysInlineWrapped() {
        // No marker path, no text below: a long continuation wraps inline into the empty space below,
        // to the CFRange char-0 margin (correct there). NOT a bubble — even when it fully overflows.
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: false,
                                              usesMarkerGeometry: false, fitsInline: false,
                                              roomForMeaningfulInline: false) == .inlineWrapped)
    }

    @Test func cfRangeFittingStaysInline() {
        #expect(ContinuationRouting.placement(hasTextToRight: false, hasTextBelow: false,
                                              usesMarkerGeometry: false, fitsInline: true,
                                              roomForMeaningfulInline: true) == .inlineWrapped)
    }
}
