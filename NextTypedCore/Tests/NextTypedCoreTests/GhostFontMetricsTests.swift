import Testing
@testable import NextTypedCore

/// `GhostFontMetrics.pointSize(forLineHeight:)` — the line-height → point-size derivation used
/// whenever the host exposes no per-character font, so the ghost is still sized to match the host.
///
/// Two paths share it: the overlay's existing no-host-font fallback (TextEdit/Notes/claude.ai where
/// `kAXAttributedStringForRange` carries no `.font`), and the Electron **text-marker** caret path
/// , whose attributed string also carries no font, so the size must come
/// from the marker rect's line-height. Lifting the formula out of `OverlayWindowController` de-magics
/// the `0.82` factor + `11 pt` floor and makes it the single tested source of truth.
@Suite struct GhostFontMetricsTests {
    @Test func typicalElectronMarkerLineHeight() {
        // The runtime probe (Claude Desktop, 2026-06-22) measured an 18 pt marker line box.
        #expect(GhostFontMetrics.pointSize(forLineHeight: 18) == 18 * 0.82)
    }

    @Test func typicalDocumentLineHeight() {
        // A ~19 pt line box (system body text) → a sensible body point size, not the floor.
        let pt = GhostFontMetrics.pointSize(forLineHeight: 19)
        #expect(pt == 19 * 0.82)
        #expect(pt > GhostFontMetrics.minimumPointSize)
    }

    @Test func floorAppliesBelowMinimum() {
        // A tiny line box must not produce an unreadably small ghost — clamp to the floor.
        #expect(GhostFontMetrics.pointSize(forLineHeight: 5) == GhostFontMetrics.minimumPointSize)
    }

    @Test func zeroAndNegativeClampToFloor() {
        #expect(GhostFontMetrics.pointSize(forLineHeight: 0) == GhostFontMetrics.minimumPointSize)
        #expect(GhostFontMetrics.pointSize(forLineHeight: -10) == GhostFontMetrics.minimumPointSize)
    }

    @Test func scalesUpForLargeLineBox() {
        // Under host zoom the marker line box grows; the derived size must track it (not the floor).
        #expect(GhostFontMetrics.pointSize(forLineHeight: 40) == 40 * 0.82)
    }

    @Test func preservesPriorOverlayBehaviour() {
        // Regression guard: the formula must equal the App layer's previous inline expression,
        // `max(height * 0.82, 11)`, so the existing (runtime-verified) fallback is unchanged.
        for h in [3.0, 11.0, 13.4146, 18.0, 22.5, 100.0] {
            #expect(GhostFontMetrics.pointSize(forLineHeight: h) == max(h * 0.82, 11))
        }
    }
}
