import Testing
@testable import NextTypedCore

/// Window attribution + tiering and the Tier-2 composite ranking (decision 4).
@Suite struct OCRWindowAttributionTests {

    private func block(_ text: String, at rect: OCRRect, confidence: Double = 0.9) -> OCRTextBlock {
        OCRTextBlock(text: text, rect: rect, confidence: confidence)
    }

    private func window(
        _ id: UInt32, bundle: String? = "com.example.app", layer: Int = 0,
        rect: OCRRect, display: UInt32 = 1
    ) -> ScreenWindow {
        ScreenWindow(windowID: id, bundleID: bundle, layer: layer, rect: rect, displayID: display)
    }

    // MARK: attribution

    @Test func attributesABlockToTheContainingWindow() {
        let editor = window(1, rect: OCRRect(x: 0, y: 0, width: 500, height: 500))
        let reference = window(2, rect: OCRRect(x: 600, y: 0, width: 500, height: 500))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("hello", at: OCRRect(x: 650, y: 40, width: 100, height: 20))],
            windows: [editor, reference],
            focusedWindowID: 1)
        #expect(result.first?.window == reference)
        #expect(result.first?.tier == .ambient)
    }

    @Test func frontmostWindowWinsAnOverlap() {
        // A block drawn where two windows overlap belongs to the one in front — otherwise an occluded
        // window claims text it cannot possibly be showing.
        let front = window(1, rect: OCRRect(x: 0, y: 0, width: 400, height: 400))
        let behind = window(2, rect: OCRRect(x: 0, y: 0, width: 800, height: 800))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("overlap", at: OCRRect(x: 100, y: 100, width: 50, height: 10))],
            windows: [front, behind],           // front-to-back z-order
            focusedWindowID: nil)
        #expect(result.first?.window?.windowID == 1)
    }

    @Test func blockOutsideEveryWindowIsChrome() {
        // Desktop wallpaper text / an overlay that vanished between the two snapshots: never injected.
        let only = window(1, rect: OCRRect(x: 0, y: 0, width: 100, height: 100))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("stray", at: OCRRect(x: 900, y: 900, width: 50, height: 10))],
            windows: [only],
            focusedWindowID: 1)
        #expect(result.first?.window == nil)
        #expect(result.first?.tier == .chrome)
    }

    // MARK: tiering

    @Test func focusedWindowBlocksAreTierOne() {
        let focused = window(7, rect: OCRRect(x: 0, y: 0, width: 500, height: 500))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("typed here", at: OCRRect(x: 10, y: 10, width: 100, height: 20))],
            windows: [focused],
            focusedWindowID: 7)
        #expect(result.first?.tier == .focused)
    }

    @Test func nonZeroLayerIsChrome() {
        // Menu bar, Dock, pop-ups and floating panels all report a non-zero window layer.
        let popup = window(3, layer: 25, rect: OCRRect(x: 0, y: 0, width: 300, height: 80))
        #expect(OCRWindowAttribution.isChrome(popup) == true)
        let result = OCRWindowAttribution.attribute(
            blocks: [block("File Edit View", at: OCRRect(x: 10, y: 5, width: 200, height: 20))],
            windows: [popup],
            focusedWindowID: nil)
        #expect(result.first?.tier == .chrome)
    }

    @Test func systemUIBundlesAreChromeEvenAtLayerZero() {
        let dock = window(4, bundle: "com.apple.dock", layer: 0,
                          rect: OCRRect(x: 0, y: 800, width: 1440, height: 100))
        #expect(OCRWindowAttribution.isChrome(dock) == true)
    }

    @Test func chromeBandBackstopCatchesLayerZeroMenuBarText() {
        // A content-layer window that happens to sit in the menu-bar band still loses: the geometric
        // backstop is the last line of defence for chrome that misreports its layer.
        let menuBarBand = OCRRect(x: 0, y: 0, width: 1440, height: 24)
        let sneaky = window(5, rect: OCRRect(x: 0, y: 0, width: 1440, height: 30))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("Wi-Fi 100%", at: OCRRect(x: 1200, y: 4, width: 80, height: 14))],
            windows: [sneaky],
            focusedWindowID: nil,
            screenBands: [menuBarBand])
        #expect(result.first?.tier == .chrome)
    }

    @Test func contentBelowTheChromeBandSurvives() {
        let menuBarBand = OCRRect(x: 0, y: 0, width: 1440, height: 24)
        let doc = window(6, rect: OCRRect(x: 0, y: 0, width: 1440, height: 800))
        let result = OCRWindowAttribution.attribute(
            blocks: [block("real prose", at: OCRRect(x: 100, y: 300, width: 400, height: 18))],
            windows: [doc],
            focusedWindowID: nil,
            screenBands: [menuBarBand])
        #expect(result.first?.tier == .ambient)
    }

    // MARK: ranking

    private func candidate(
        _ id: UInt32, area: Double, recency: Int?, x: Double = 0, display: UInt32 = 1,
        chars: Int = 200
    ) -> OCRAmbientRanking.Candidate {
        let side = area.squareRoot()
        return OCRAmbientRanking.Candidate(
            window: window(id, rect: OCRRect(x: x, y: 0, width: side, height: side), display: display),
            text: String(repeating: "a", count: chars),
            recencyIndex: recency)
    }

    @Test func mostRecentlyUsedWindowRanksFirst() {
        // Recency carries the heaviest weight (0.5): with size/proximity equal, MRU wins.
        let ranked = OCRAmbientRanking.rank(
            [candidate(1, area: 400 * 400, recency: 2), candidate(2, area: 400 * 400, recency: 0)],
            focusedWindowRect: nil, focusedDisplayID: nil, limit: 2)
        #expect(ranked.map(\.window.windowID) == [2, 1])
    }

    @Test func capsToTheRequestedLimit() {
        let ranked = OCRAmbientRanking.rank(
            [candidate(1, area: 400 * 400, recency: 0),
             candidate(2, area: 400 * 400, recency: 1),
             candidate(3, area: 400 * 400, recency: 2)],
            focusedWindowRect: nil, focusedDisplayID: nil, limit: 2)
        #expect(ranked.count == 2)
    }

    @Test func dropsWindowsBelowTheContentFloor() {
        // A tiny palette and a text-poor window are noise, not ambient reference context.
        let tiny = candidate(1, area: 60 * 60, recency: 0)
        let textPoor = candidate(2, area: 400 * 400, recency: 0, chars: 5)
        #expect(OCRAmbientRanking.rank([tiny, textPoor],
                                       focusedWindowRect: nil, focusedDisplayID: nil).isEmpty)
    }

    @Test func sameDisplayBeatsAnEquallyRecentWindowOnAnotherMonitor() {
        let focused = OCRRect(x: 0, y: 0, width: 400, height: 400)
        let near = candidate(1, area: 400 * 400, recency: 0, x: 500, display: 1)
        let far = candidate(2, area: 400 * 400, recency: 0, x: 3000, display: 2)
        let ranked = OCRAmbientRanking.rank([far, near],
                                            focusedWindowRect: focused, focusedDisplayID: 1, limit: 1)
        #expect(ranked.first?.window.windowID == 1)
    }

    @Test func biggerWindowWinsWhenRecencyAndProximityTie() {
        let big = candidate(1, area: 800 * 800, recency: 0)
        let small = candidate(2, area: 300 * 300, recency: 0)
        let ranked = OCRAmbientRanking.rank([small, big],
                                            focusedWindowRect: nil, focusedDisplayID: nil, limit: 1)
        #expect(ranked.first?.window.windowID == 1)
    }

    @Test func neverSeenFrontmostScoresLowestOnRecency() {
        let seen = candidate(1, area: 400 * 400, recency: 0)
        let unseen = candidate(2, area: 400 * 400, recency: nil)
        let ranked = OCRAmbientRanking.rank([unseen, seen],
                                            focusedWindowRect: nil, focusedDisplayID: nil, limit: 1)
        #expect(ranked.first?.window.windowID == 1)
    }

    @Test func emptyCandidateSetRanksToNothing() {
        #expect(OCRAmbientRanking.rank([], focusedWindowRect: nil, focusedDisplayID: nil).isEmpty)
    }
}
