import Testing
@testable import NextTypedCore

/// The SPM S-pinning prompt window (build item 6). Under SPM the prompt is
/// `<fim_suffix> S <fim_prefix>` (pinned front) + `P` (grows at the caret) + `<fim_middle>` (fixed tail).
/// The forward-path `PrefixReuse.window` front-drops, which would eat `S` — the one segment that must
/// never be dropped. This variant caps the **P-head** instead: the oldest prefix tokens, farthest from
/// the caret.
@Suite struct FIMWindowTests {
    /// `<fim_suffix>` + a 4-token S + `<fim_prefix>`.
    private let pinned = [900, 10, 11, 12, 13, 901]
    private let trailing = [902]   // `<fim_middle>`

    private func p(_ range: ClosedRange<Int>) -> [Int] { Array(range) }

    // MARK: S is never dropped

    @Test func theWholePinnedFrontSurvivesALongPrefix() {
        let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...500), trailing: trailing,
                                      max: 64, reanchorStep: 16)
        #expect(Array(w.tokens.prefix(pinned.count)) == pinned)
        #expect(w.tokens.last == 902)
        #expect(w.prefixHeadDropped > 0)
    }

    @Test func evenAnOverlongSuffixKeepsSAndTheSentinels() {
        // Degenerate: the pinned block alone exceeds the budget. Dropping S would turn the prompt into
        // an ordinary forward predict wearing FIM sentinels — worse than an over-budget prompt.
        let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...50), trailing: trailing,
                                      max: 4, reanchorStep: 16)
        #expect(w.tokens == pinned + trailing)
        #expect(w.prefixHeadDropped == 50)
    }

    @Test func aShortPromptIsPassedThroughWhole() {
        let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...5), trailing: trailing,
                                      max: 64, reanchorStep: 16)
        #expect(w.tokens == pinned + p(1...5) + trailing)
        #expect(w.prefixHeadDropped == 0)
    }

    @Test func theMiddleSentinelIsAlwaysTheLastToken() {
        for count in [1, 40, 400] {
            let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...count), trailing: trailing,
                                          max: 64, reanchorStep: 16)
            #expect(w.tokens.last == 902)
        }
    }

    // MARK: Reuse fires across P-growth keystrokes (on a trimmable cache)

    @Test func consecutiveKeystrokesShareEverythingButTheTrailingSentinel() {
        // The item-6 claim: the prompt ends in the fixed `<fim_middle>`, so a P-append is never a *pure*
        // append — `plan` returns `trimFromCache == 1` (the stale sentinel), never 0. On a trimmable
        // (all-attention) cache that is still cheap reuse; on a hybrid it falls to rebuild-always.
        let before = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...201), trailing: trailing,
                                           max: 64, reanchorStep: 16)
        let after = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...202), trailing: trailing,
                                          max: 64, reanchorStep: 16)
        #expect(before.prefixHeadDropped == after.prefixHeadDropped)   // front held still
        let plan = PrefixReuse.plan(cached: before.tokens, next: after.tokens)
        guard case .reuse(let reuseTokens, let trimFromCache) = plan else {
            Issue.record("expected reuse, got \(plan)"); return
        }
        #expect(trimFromCache == 1)                       // exactly the stale `<fim_middle>`
        #expect(reuseTokens == before.tokens.count - 1)   // everything else is kept
    }

    @Test func aTrimmableCacheTakesTheTrimPathAndAHybridRebuilds() {
        let before = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...201), trailing: trailing,
                                           max: 64, reanchorStep: 16)
        let after = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...202), trailing: trailing,
                                          max: 64, reanchorStep: 16)
        let plan = PrefixReuse.plan(cached: before.tokens, next: after.tokens)

        #expect(PrefixReuse.reuseMode(plan: plan, cacheTrimmable: true, haveCache: true,
                                      snapshotCoverage: 7, snapshotReuseEnabled: true)
                == .trim(reuseTokens: before.tokens.count - 1, trimFromCache: 1))
        // Hybrid Mamba: a snapshot taken at the prompt end includes the trailing `<fim_middle>`, so it
        // is never a prefix of the next SPM prompt (`snapshotCoverage == nil`) and the call rebuilds.
        #expect(PrefixReuse.reuseMode(plan: plan, cacheTrimmable: false, haveCache: true,
                                      snapshotCoverage: PrefixReuse.snapshotCoverage(
                                        snapshotTokens: before.tokens, next: after.tokens),
                                      snapshotReuseEnabled: true)
                == .rebuild(nonTrimmable: true))
    }

    @Test func everyKeystrokeInsideOneAnchorReusesTheWholeCacheButTheSentinel() {
        // over = count − budget(57); the anchor holds at 144 for counts 201…216.
        var previous = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...201), trailing: trailing,
                                             max: 64, reanchorStep: 16)
        for count in 202...216 {
            let next = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...count), trailing: trailing,
                                             max: 64, reanchorStep: 16)
            #expect(next.prefixHeadDropped == previous.prefixHeadDropped)
            #expect(PrefixReuse.plan(cached: previous.tokens, next: next.tokens)
                    == .reuse(reuseTokens: previous.tokens.count - 1, trimFromCache: 1))
            previous = next
        }
    }

    // MARK: A P-head re-anchor costs exactly one rebuild

    @Test func theFrontMovesOnlyInReanchorSteps() {
        var dropCounts: Set<Int> = []
        for count in 200...260 {
            let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...count), trailing: trailing,
                                          max: 64, reanchorStep: 16)
            dropCounts.insert(w.prefixHeadDropped)
        }
        // 61 keystrokes, step 16 ⇒ at most a handful of distinct anchors, each a multiple of the step.
        #expect(dropCounts.count <= 5)
        #expect(dropCounts.allSatisfy { $0 % 16 == 0 })
    }

    @Test func aReanchorRePrefillsPButNEVERReprefillsS() {
        // The payoff of pinning: when the P-head re-anchors, the shared run collapses to exactly the
        // pinned block — so the re-anchor costs a P re-prefill, and `S` + the sentinels stay primed.
        // Under the forward `window` the front itself moves, so *everything* would re-prefill.
        let before = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...200), trailing: trailing,
                                           max: 64, reanchorStep: 16)
        let after = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...201), trailing: trailing,
                                          max: 64, reanchorStep: 16)
        #expect(after.prefixHeadDropped != before.prefixHeadDropped)   // this keystroke re-anchored
        #expect(PrefixReuse.plan(cached: before.tokens, next: after.tokens)
                == .reuse(reuseTokens: pinned.count,
                          trimFromCache: before.tokens.count - pinned.count))
    }

    @Test func reanchorsAreRareOverALongTypingBurst() {
        var previous = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...200), trailing: trailing,
                                             max: 64, reanchorStep: 16)
        var reanchors = 0
        for count in 201...280 {
            let next = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...count), trailing: trailing,
                                             max: 64, reanchorStep: 16)
            if next.prefixHeadDropped != previous.prefixHeadDropped { reanchors += 1 }
            previous = next
        }
        #expect(reanchors == 80 / 16)   // one per `reanchorStep` keystrokes, not one per keystroke
    }

    // MARK: The window is a superset of the budget, like the forward one

    @Test func theKeptPrefixTailNeverShrinksBelowTheBudget() {
        // Same superset property `PrefixReuse.window` guarantees: an anchor is the largest multiple of
        // the step that still leaves a full budget of tail, so context can only be equal or larger.
        let budget = 64 - pinned.count - trailing.count
        for count in 100...200 {
            let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...count), trailing: trailing,
                                          max: 64, reanchorStep: 16)
            #expect(count - w.prefixHeadDropped >= budget)
        }
    }

    @Test func theKeptPrefixIsTheTailNearestTheCaret() {
        let w = PrefixReuse.fimWindow(pinned: pinned, prefix: p(1...200), trailing: trailing,
                                      max: 64, reanchorStep: 16)
        let keptPrefix = Array(w.tokens.dropFirst(pinned.count).dropLast(trailing.count))
        #expect(keptPrefix.last == 200)                                    // the caret end is intact
        #expect(keptPrefix.first == 200 - keptPrefix.count + 1)            // a contiguous tail run
    }
}
