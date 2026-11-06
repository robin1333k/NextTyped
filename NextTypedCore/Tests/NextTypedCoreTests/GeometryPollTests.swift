import Testing
@testable import NextTypedCore

/// The overlay's idle geometry-poll decision, lifted out of the App layer (`AppCoordinator`)
/// so the surface-independent churn logic is unit-testable.
///
/// Runtime logs (claude.ai/Safari, Apple Notes, 2026-06-20) showed the poll re-rendering on
/// 100 % of ticks during active typing — the caret X genuinely advances ~8 pt/char so the
/// `>1 pt` change threshold trips every 200 ms tick, *redundantly* with the typing path which
/// already re-rendered the same keystroke. The fix: while typing is actively flowing the poll
/// must NOT fire (the typing path owns re-rendering); it runs only during true idle, which is
/// its real job — catching a zoom/scroll/window-move no gesture event reported.
@Suite struct GeometryPollTests {
    // A typical caret probe: zero-width, at x=600, top y=490, one ~18 pt line tall (AX coords).
    private static let base = CaretProbe(minX: 600, minY: 490, height: 18)

    // MARK: changed — threshold detection (preserves the App's prior >1pt / >0.5pt behaviour)

    @Test func unchangedForIdenticalProbe() {
        #expect(GeometryPoll.changed(from: Self.base, to: Self.base) == false)
    }

    @Test func unchangedForSubThresholdXJitter() {
        // Sub-pixel caret X (Notes: 99 % of rects have a fractional X) below the move threshold
        // is not a real move — must not trip.
        let jittered = CaretProbe(minX: 600.4, minY: 490, height: 18)
        #expect(GeometryPoll.changed(from: Self.base, to: jittered) == false)
    }

    @Test func changedForXAdvancePastThreshold() {
        // A typed character advances the caret ~8 pt — well past the 1 pt threshold.
        let advanced = CaretProbe(minX: 608, minY: 490, height: 18)
        #expect(GeometryPoll.changed(from: Self.base, to: advanced) == true)
    }

    @Test func changedForVerticalScrollPastThreshold() {
        let scrolled = CaretProbe(minX: 600, minY: 540, height: 18)
        #expect(GeometryPoll.changed(from: Self.base, to: scrolled) == true)
    }

    @Test func changedForHeightZoomPastThreshold() {
        // Zoom rescales the line box height (the X/Y may barely move); the 0.5 pt height term catches it.
        let zoomed = CaretProbe(minX: 600, minY: 490, height: 24)
        #expect(GeometryPoll.changed(from: Self.base, to: zoomed) == true)
    }

    @Test func unchangedAtExactThresholdBoundaries() {
        // Strictly-greater comparison: exactly 1 pt move / 0.5 pt height delta is NOT a change.
        let atMove = CaretProbe(minX: 601, minY: 491, height: 18)
        #expect(GeometryPoll.changed(from: Self.base, to: atMove) == false)
        let atHeight = CaretProbe(minX: 600, minY: 490, height: 18.5)
        #expect(GeometryPoll.changed(from: Self.base, to: atHeight) == false)
    }

    // MARK: shouldRerender — the typing-active gate

    @Test func neverRerendersWhileTypingEvenWhenCaretMoved() {
        // The crux: during continuous typing the caret advances every tick, but the typing path
        // already re-renders each keystroke — the poll must stay quiet to avoid a second render.
        let advanced = CaretProbe(minX: 608, minY: 490, height: 18)
        #expect(GeometryPoll.shouldRerender(probe: advanced, baseline: Self.base,
                                            typingActive: true) == false)
    }

    @Test func rerendersOnIdleGeometryChange() {
        // A zoom/scroll WITHOUT a keystroke (idle) that no gesture event caught — the poll's real
        // job: re-align the ghost.
        let scrolled = CaretProbe(minX: 600, minY: 540, height: 18)
        #expect(GeometryPoll.shouldRerender(probe: scrolled, baseline: Self.base,
                                            typingActive: false) == true)
    }

    @Test func noRerenderWhenIdleAndUnchanged() {
        #expect(GeometryPoll.shouldRerender(probe: Self.base, baseline: Self.base,
                                            typingActive: false) == false)
    }

    @Test func noRerenderOnFirstTickWithoutBaseline() {
        // First tick after a (re)start only establishes the baseline; nothing to compare against.
        let scrolled = CaretProbe(minX: 600, minY: 540, height: 18)
        #expect(GeometryPoll.shouldRerender(probe: scrolled, baseline: nil,
                                            typingActive: false) == false)
    }
}
