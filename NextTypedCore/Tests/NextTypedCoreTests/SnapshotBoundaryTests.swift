import Testing
@testable import NextTypedCore

/// The hybrid snapshot sits a few tokens BEFORE the prompt
/// end, at a boundary that survives typing, instead of at the prompt end. Typing a letter re-tokenizes
/// the word at the caret, so a snapshot of the whole prompt never was a prefix of the next prompt
/// (a logged case: `cached=305 new=305 firstDiff=304`).
@Suite struct SnapshotBoundaryTests {

    // MARK: snapshotCoverage — does the held snapshot cover the head of the next prompt?

    @Test func aSnapshotThatIsAStrictPrefixCoversItsLength() {
        #expect(PrefixReuse.snapshotCoverage(snapshotTokens: [1, 2, 3], next: [1, 2, 3, 4, 5]) == 3)
    }

    @Test func aSnapshotEqualToTheWholePromptCoversNothing() {
        // The last prompt token must run through the model for the first logits.
        #expect(PrefixReuse.snapshotCoverage(snapshotTokens: [1, 2, 3], next: [1, 2, 3]) == nil)
    }

    @Test func aSnapshotThatDivergesCoversNothing() {
        #expect(PrefixReuse.snapshotCoverage(snapshotTokens: [1, 2, 3], next: [1, 2, 9, 4]) == nil)
        #expect(PrefixReuse.snapshotCoverage(snapshotTokens: [1, 2, 3, 4], next: [1, 2, 3]) == nil)
    }

    @Test func anEmptySnapshotCoversNothing() {
        #expect(PrefixReuse.snapshotCoverage(snapshotTokens: [], next: [1, 2]) == nil)
    }

    // MARK: the measured miss, end to end through plan + reuseMode

    @Test func aRetokenizedLastWordIsServedByTheEarlierSnapshot() {
        // Prompt A = front 1...6 + "Hal" as [7, 8]; the user types "l": prompt B ends in [7, 9, 10].
        let promptA = [1, 2, 3, 4, 5, 6, 7, 8]
        let promptB = [1, 2, 3, 4, 5, 6, 7, 9, 10]
        let boundary = PrefixReuse.snapshotBoundary(
            promptTokens: promptA.count, deltaStart: 0, tailMargin: 2, minAdvance: 1)
        #expect(boundary == 6)
        let snapshot = Array(promptA.prefix(6))
        let plan = PrefixReuse.plan(cached: promptA, next: promptB)
        #expect(plan == .reuse(reuseTokens: 7, trimFromCache: 1))   // not a pure append
        let mode = PrefixReuse.reuseMode(
            plan: plan, cacheTrimmable: false, haveCache: true,
            snapshotCoverage: PrefixReuse.snapshotCoverage(snapshotTokens: snapshot, next: promptB),
            snapshotReuseEnabled: true)
        #expect(mode == .snapshot(reuseTokens: 6))
    }

    @Test func theSnapshotAtThePromptEndStillMissesTheRetokenizedWord() {
        // The old boundary (tailMargin 0) reproduces the miss: a rebuild.
        let promptA = [1, 2, 3, 4, 5, 6, 7, 8]
        let promptB = [1, 2, 3, 4, 5, 6, 7, 9, 10]
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: promptA.count, deltaStart: 0, tailMargin: 0, minAdvance: 1) == 8)
        let mode = PrefixReuse.reuseMode(
            plan: PrefixReuse.plan(cached: promptA, next: promptB), cacheTrimmable: false,
            haveCache: true,
            snapshotCoverage: PrefixReuse.snapshotCoverage(snapshotTokens: promptA, next: promptB),
            snapshotReuseEnabled: true)
        #expect(mode == .rebuild(nonTrimmable: true))
    }

    // MARK: snapshotBoundary — where this predict takes its snapshot, if it takes one

    @Test func aRebuildSnapshotsTailMarginTokensBeforeTheEnd() {
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 305, deltaStart: 0, tailMargin: 8, minAdvance: 16) == 297)
    }

    @Test func aReuseThatAdvancesLessThanTheStepKeepsTheOldSnapshot() {
        // Snapshot held at 297; the next prompt is 307 tokens, so a new one would sit at 299.
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 307, deltaStart: 297, tailMargin: 8, minAdvance: 16) == nil)
    }

    @Test func aReuseThatAdvancesAtLeastTheStepMovesTheSnapshot() {
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 321, deltaStart: 297, tailMargin: 8, minAdvance: 16) == 313)
    }

    @Test func aPromptShorterThanMarginPlusStepTakesNoSnapshot() {
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 20, deltaStart: 0, tailMargin: 8, minAdvance: 16) == nil)
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 5, deltaStart: 0, tailMargin: 8, minAdvance: 1) == nil)
    }

    @Test func tailMarginZeroAndStepOneIsThePromptEndBoundary() {
        // The old behaviour, kept reachable for the before/after bench.
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 305, deltaStart: 0, tailMargin: 0, minAdvance: 1) == 305)
        #expect(PrefixReuse.snapshotBoundary(
            promptTokens: 306, deltaStart: 305, tailMargin: 0, minAdvance: 1) == 306)
    }
}

/// Snapshot reuse is on unless the user stored `false`.
@Suite struct SnapshotReuseDefaultTests {
    @Test func anAbsentKeyMeansSnapshotReuseIsOn() {
        #expect(PrefixReuse.snapshotReuseEnabled(stored: nil) == true)
    }

    @Test func aStoredValueWins() {
        #expect(PrefixReuse.snapshotReuseEnabled(stored: false) == false)
        #expect(PrefixReuse.snapshotReuseEnabled(stored: true) == true)
    }
}
