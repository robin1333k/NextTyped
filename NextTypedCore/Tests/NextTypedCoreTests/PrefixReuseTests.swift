import Testing
@testable import NextTypedCore

@Suite struct PrefixReuseTests {
    // MARK: longestCommonPrefix

    @Test func lcpOfEqualArrays() {
        #expect(PrefixReuse.longestCommonPrefix([1, 2, 3], [1, 2, 3]) == 3)
    }

    @Test func lcpOfExtension() {
        #expect(PrefixReuse.longestCommonPrefix([1, 2, 3], [1, 2, 3, 4, 5]) == 3)
    }

    @Test func lcpStopsAtFirstDifference() {
        #expect(PrefixReuse.longestCommonPrefix([1, 2, 9, 4], [1, 2, 3, 4]) == 2)
    }

    @Test func lcpEmptyAndDisjoint() {
        #expect(PrefixReuse.longestCommonPrefix([], [1, 2]) == 0)
        #expect(PrefixReuse.longestCommonPrefix([9, 9], [1, 2]) == 0)
    }

    // MARK: plan — the common case (Tab-accept appends ~one word/token)

    @Test func extendingPrefixReusesAndPrefillsOnlyTheDelta() {
        // cache holds [1,2,3]; the new prompt is that plus two appended tokens.
        let plan = PrefixReuse.plan(cached: [1, 2, 3], next: [1, 2, 3, 4, 5])
        #expect(plan == .reuse(reuseTokens: 3, trimFromCache: 0))
        // → engine prefills next[3...] = [4,5] against the warm cache.
    }

    @Test func appendingASingleTokenReusesAll() {
        let plan = PrefixReuse.plan(cached: [1, 2, 3], next: [1, 2, 3, 4])
        #expect(plan == .reuse(reuseTokens: 3, trimFromCache: 0))
    }

    // MARK: plan — divergence (caret jump / mid-text edit)

    @Test func divergedTailTrimsThenReprefills() {
        // Shared prefix [1,2], cache went on to [3,4] but the new prompt diverges to [7,8].
        // Keep 2, trim the 2 divergent cached tokens, re-prefill [7,8].
        let plan = PrefixReuse.plan(cached: [1, 2, 3, 4], next: [1, 2, 7, 8])
        #expect(plan == .reuse(reuseTokens: 2, trimFromCache: 2))
    }

    @Test func noSharedPrefixRebuilds() {
        #expect(PrefixReuse.plan(cached: [1, 2, 3], next: [9, 8, 7]) == .rebuild)
    }

    @Test func emptyCacheRebuilds() {
        #expect(PrefixReuse.plan(cached: [], next: [1, 2, 3]) == .rebuild)
    }

    // MARK: plan — shrink and identical (must still leave a token to prefill)

    @Test func shrunkPrefixReusesAndReprefillsLastToken() {
        // User deleted text: prompt shrank from [1,2,3,4,5] to [1,2,3]. lcp=3 but we must keep ≥1
        // token of tail, so reuse 2 and re-prefill the last ([3]); trim the 3 now-stale cached tokens.
        let plan = PrefixReuse.plan(cached: [1, 2, 3, 4, 5], next: [1, 2, 3])
        #expect(plan == .reuse(reuseTokens: 2, trimFromCache: 3))
    }

    @Test func identicalPromptReusesAllButLastToken() {
        // Defensive: an identical prompt (redundancy guard normally prevents this) still needs ≥1
        // delta token because the cache stores no logits for the last token.
        let plan = PrefixReuse.plan(cached: [1, 2, 3], next: [1, 2, 3])
        #expect(plan == .reuse(reuseTokens: 2, trimFromCache: 1))
    }

    @Test func singleTokenPromptRebuilds() {
        // Only one token and we need it as the delta → nothing to reuse.
        #expect(PrefixReuse.plan(cached: [1], next: [1]) == .rebuild)
        #expect(PrefixReuse.plan(cached: [1, 2], next: [9]) == .rebuild)
    }

    // MARK: window — fits under the cap

    @Test func windowUnderCapIsWholeSequence() {
        let toks = Array(0 ..< 100)
        let w = PrefixReuse.window(toks, max: 512, reanchorStep: 128)
        #expect(w.start == 0)
        #expect(w.tokens == toks)
    }

    @Test func windowExactlyAtCapIsWholeSequence() {
        let toks = Array(0 ..< 512)
        let w = PrefixReuse.window(toks, max: 512, reanchorStep: 128)
        #expect(w.start == 0)
        #expect(w.tokens.count == 512)
    }

    // MARK: window — past the cap: anchored front, superset of suffix(windowMax)

    @Test func windowPastCapAnchorsToStepMultiple() {
        // 700 tokens, cap 512, step 128. over = 188, anchor = floor(188/128)*128 = 128.
        let toks = Array(0 ..< 700)
        let w = PrefixReuse.window(toks, max: 512, reanchorStep: 128)
        #expect(w.start == 128)
        #expect(w.tokens.first == 128)
        #expect(w.tokens.last == 699)
        #expect(w.tokens.count == 572)              // 700 − 128, within [512, 512+128)
    }

    @Test func windowIsAlwaysASupersetOfTheLastWindowMaxTokens() {
        // The anchor never starts later than count − windowMax, so the window contains the full
        // suffix(windowMax) — never less recent context than the old cap.
        for count in [513, 600, 640, 641, 900, 1024] {
            let toks = Array(0 ..< count)
            let w = PrefixReuse.window(toks, max: 512, reanchorStep: 128)
            #expect(w.start <= count - 512)
            #expect(w.tokens.count >= 512)
            #expect(w.tokens.count < 512 + 128)     // bounded worst case
            #expect(w.tokens.last == count - 1)     // always includes the newest token
        }
    }

    // MARK: window + plan integration — reuse fires between re-anchors, rebuild on a jump

    @Test func growingStreamReusesUntilTheFrontReanchors() {
        // Simulate typing into a long doc: token i is the value i. Each keystroke appends one token.
        // After each prediction the engine's cache holds exactly the prompt window, so cached_(n) is
        // window(n) and next is window(n+1). Reuse must fire on every append where the anchor is
        // unchanged, and rebuild exactly when the anchor jumps.
        let windowMax = 512, step = 128
        var rebuilds = 0, reuses = 0
        var jumps = 0
        for count in 600 ..< 900 {
            let prev = PrefixReuse.window(Array(0 ..< count), max: windowMax, reanchorStep: step)
            let cur = PrefixReuse.window(Array(0 ..< (count + 1)), max: windowMax, reanchorStep: step)
            let plan = PrefixReuse.plan(cached: prev.tokens, next: cur.tokens)
            if prev.start == cur.start {
                // Front stable → the new window is the old one plus one appended token → clean reuse.
                #expect(plan == .reuse(reuseTokens: prev.tokens.count, trimFromCache: 0))
                reuses += 1
            } else {
                // Front jumped by exactly one step → leading tokens differ → rebuild.
                #expect(cur.start == prev.start + step)
                #expect(plan == .rebuild)
                rebuilds += 1
                jumps += 1
            }
        }
        // Over 300 keystrokes with step 128 there are ~2 re-anchors; the vast majority reuse.
        #expect(rebuilds == jumps)
        #expect(reuses > 290)
        #expect(rebuilds >= 1 && rebuilds <= 3)
    }

    // MARK: commitDecision — commit-after-prefill (narrow invalidation)

    @Test func cleanDecodeCommitsAndTrimsTheGeneratedKV() {
        // The ordinary path: prefill landed, decode finished; trim the generated-token KV so the cache
        // represents exactly the prompt, then commit. Branch-independent.
        #expect(PrefixReuse.commitDecision(branch: .reuse, prefillLanded: true, generatedKV: 3)
            == .commit(trim: 3))
        #expect(PrefixReuse.commitDecision(branch: .rebuild, prefillLanded: true, generatedKV: 3)
            == .commit(trim: 3))
    }

    @Test func aDecodePhaseCancelAfterPrefillCommitsNotInvalidates() {
        // THE regression guard against the old blanket-invalidate bug. A decode-phase cancel used to leave
        // `committed == false` → blanket invalidate, wiping a perfectly-valid prompt cache on every
        // keystroke-burst (the 896 ms-rebuild death-spiral). Post-prefill the cache validly holds the
        // prompt, so a cancel must COMMIT (warm the cache), never invalidate — on either branch.
        #expect(PrefixReuse.commitDecision(branch: .reuse, prefillLanded: true, generatedKV: 1)
            == .commit(trim: 1))
        #expect(PrefixReuse.commitDecision(branch: .rebuild, prefillLanded: true, generatedKV: 2)
            == .commit(trim: 2))
    }

    @Test func aLandedPrefillNeverInvalidates() {
        // The whole point of commit-after-prefill, asserted exhaustively: once the prefill lands, NO input — any
        // branch, any generated-KV count — yields `.invalidate`. This is the property that breaks the
        // death-spiral.
        for branch in [PrefixReuse.Branch.reuse, .rebuild] {
            for gen in [0, 1, 5, 24] {
                let action = PrefixReuse.commitDecision(
                    branch: branch, prefillLanded: true, generatedKV: gen)
                #expect(action != .invalidate)
            }
        }
    }

    @Test func aPrePrefillAbortOnRebuildKeepsTheOldCache() {
        // The rebuild branch builds into a LOCAL and publishes only at commit, so aborting before the
        // prefill lands leaves the previously-committed cache untouched (keep-old, not invalidate).
        #expect(PrefixReuse.commitDecision(branch: .rebuild, prefillLanded: false, generatedKV: 0)
            == .keepOld)
    }

    @Test func aPrePrefillAbortOnReuseInvalidates() {
        // The reuse branch trimmed the LIVE cache in place before prefilling; aborting before the prefill
        // re-establishes it leaves the cache indeterminate — the one remaining invalidate case.
        #expect(PrefixReuse.commitDecision(branch: .reuse, prefillLanded: false, generatedKV: 0)
            == .invalidate)
    }

    @Test func commitNeverTrimsANegativeCount() {
        // The engine derives the trim from (offset − promptLen); guard against an unexpected negative
        // (e.g. nothing generated) collapsing to a no-op trim rather than a bad cache call.
        #expect(PrefixReuse.commitDecision(branch: .reuse, prefillLanded: true, generatedKV: 0)
            == .commit(trim: 0))
        #expect(PrefixReuse.commitDecision(branch: .rebuild, prefillLanded: true, generatedKV: -2)
            == .commit(trim: 0))
    }

    // MARK: rebuildCause — instrumentation cause-tag

    @Test func rebuildOnAnEmptyCacheIsTaggedEmpty() {
        // No prior cache: first predict, post-invalidation, or post-context-switch. This is the
        // "empty-cache-after-cancel" bucket must read ~zero once
        // commit-after-prefill is correct (a cancel WARMS the cache rather than emptying it).
        #expect(PrefixReuse.rebuildCause(cachedTokens: 0) == .emptyCache)
    }

    @Test func rebuildOnANonEmptyCacheIsTaggedDivergence() {
        // A cache existed but its shared prefix was unusable — a caret jump / mid-text edit / window
        // re-anchor diverged the leading tokens.
        #expect(PrefixReuse.rebuildCause(cachedTokens: 1) == .divergence)
        #expect(PrefixReuse.rebuildCause(cachedTokens: 512) == .divergence)
    }

    @Test func rebuildCauseAgreesWithPlanOnTheTwoRebuildPaths() {
        // Tie the cause to the actual plan: both of these produce `.rebuild`, split by whether a cache
        // was present. The engine reads `cachedTokens` straight off the cached token sequence.
        let emptyCached: [Int] = []
        #expect(PrefixReuse.plan(cached: emptyCached, next: [1, 2, 3]) == .rebuild)
        #expect(PrefixReuse.rebuildCause(cachedTokens: emptyCached.count) == .emptyCache)

        let divergedCached = [9, 8, 7]
        #expect(PrefixReuse.plan(cached: divergedCached, next: [1, 2, 3]) == .rebuild)
        #expect(PrefixReuse.rebuildCause(cachedTokens: divergedCached.count) == .divergence)
    }

    @Test func rebuildCauseRawValuesAreStableLogTokens() {
        // The raw values double as greppable DEBUG log tokens — pin them so a rename can't silently
        // break a capture-analysis script.
        #expect(PrefixReuse.RebuildCause.emptyCache.rawValue == "empty")
        #expect(PrefixReuse.RebuildCause.divergence.rawValue == "divergence")
    }

    // MARK: cancelPhase — how far a cancelled predict got

    @Test func cancelBeforePrefillIsEncodeOnly() {
        // Cancel detected in the read-only phase (encode + window + plan), before any cache mutation.
        // decodeSteps is 0 there, but the classifier must stay encode-only even if a stray step count
        // is passed — `prefillLanded` is the authoritative gate.
        #expect(PrefixReuse.cancelPhase(prefillLanded: false, decodeSteps: 0) == .encodeOnly)
        #expect(PrefixReuse.cancelPhase(prefillLanded: false, decodeSteps: 4) == .encodeOnly)
    }

    @Test func cancelRightAfterPrefillWithNoStepsIsCacheMutated() {
        // The prefill landed (the cache is warmed/committed to exactly the prompt) but the decode loop
        // was cancelled on its first iteration → zero generated tokens.
        #expect(PrefixReuse.cancelPhase(prefillLanded: true, decodeSteps: 0) == .cacheMutated)
    }

    @Test func cancelDuringDecodeIsMidDecode() {
        // The prefill landed and ≥1 token decoded before the cancel.
        #expect(PrefixReuse.cancelPhase(prefillLanded: true, decodeSteps: 1) == .midDecode)
        #expect(PrefixReuse.cancelPhase(prefillLanded: true, decodeSteps: 24) == .midDecode)
    }

    @Test func cancelPhaseRawValuesAreStableLogTokens() {
        #expect(PrefixReuse.CancelPhase.encodeOnly.rawValue == "encode-only")
        #expect(PrefixReuse.CancelPhase.cacheMutated.rawValue == "cache-mutated")
        #expect(PrefixReuse.CancelPhase.midDecode.rawValue == "mid-decode")
    }

    // MARK: reuseMode — how to EXECUTE a plan given the cache's runtime trimmability
    //
    // `plan` is pure token arithmetic; `reuseMode` layers on the two runtime facts only the engine
    // knows — whether the live cache is trimmable (all-attention) or not (hybrid Mamba), and whether a
    // clean snapshot is available — plus the staged-rollout flag, to pick trim-reuse / snapshot-reuse /
    // rebuild. This is the regression-prone branching the engine used to inline; modelled here so it's
    // unit-tested with no model (the same reason `commitDecision` lives here).

    @Test func reuseModeRebuildPlanAlwaysRebuilds() {
        // A `.rebuild` plan (no shared prefix / empty cache) rebuilds regardless of trimmability or flag,
        // and is NOT tagged non-trimmable (it's a genuine plan rebuild, the `rebuild(empty/divergence)` tag).
        for trimmable in [true, false] {
            for enabled in [true, false] {
                #expect(PrefixReuse.reuseMode(
                    plan: .rebuild, cacheTrimmable: trimmable, haveCache: trimmable,
                    snapshotCoverage: 7, snapshotReuseEnabled: enabled)
                    == .rebuild(nonTrimmable: false))
            }
        }
    }

    @Test func reuseModeTrimmableCacheTrimReusesAndIgnoresSnapshotFlag() {
        // All-attention cache: the trim path. The snapshot flag is irrelevant here —
        // trimmable caches never snapshot-reuse (trim is correct and cheaper).
        let plan = PrefixReuse.Plan.reuse(reuseTokens: 5, trimFromCache: 0)
        for enabled in [true, false] {
            #expect(PrefixReuse.reuseMode(
                plan: plan, cacheTrimmable: true, haveCache: true,
                snapshotCoverage: nil, snapshotReuseEnabled: enabled)
                == .trim(reuseTokens: 5, trimFromCache: 0))
        }
        // A diverged (trimFromCache > 0) reuse on a trimmable cache still trims, not rebuilds.
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 2, trimFromCache: 3), cacheTrimmable: true, haveCache: true,
            snapshotCoverage: nil, snapshotReuseEnabled: true)
            == .trim(reuseTokens: 2, trimFromCache: 3))
    }

    @Test func reuseModeNonTrimmablePureAppendSnapshotReusesWhenEnabled() {
        // The hybrid snapshot win: a non-trimmable hybrid cache, a pure append (trimFromCache == 0), a snapshot
        // on hand, flag on → restore-and-prefill-delta instead of a full rebuild.
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 7, trimFromCache: 0), cacheTrimmable: false, haveCache: true,
            snapshotCoverage: 7, snapshotReuseEnabled: true)
            == .snapshot(reuseTokens: 7))
    }

    @Test func reuseModeNonTrimmableRebuildsWhenFlagOff() {
        // Production default (issue-07): flag off ⇒ a non-trimmable cache always rebuilds, tagged
        // non-trimmable. THIS is the "behaviour unchanged with the flag off" guarantee.
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 7, trimFromCache: 0), cacheTrimmable: false, haveCache: true,
            snapshotCoverage: 7, snapshotReuseEnabled: false)
            == .rebuild(nonTrimmable: true))
    }

    @Test func reuseModeNonTrimmableBackwardJumpRebuildsEvenWhenEnabled() {
        // A backward caret jump / mid-text edit past the snapshot boundary leaves no snapshot that is a
        // prefix of the new prompt (`snapshotCoverage == nil`), so it rebuilds even with the flag on.
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 2, trimFromCache: 3), cacheTrimmable: false, haveCache: true,
            snapshotCoverage: nil, snapshotReuseEnabled: true)
            == .rebuild(nonTrimmable: true))
    }

    @Test func reuseModeNonTrimmableRebuildsWhenNoSnapshot() {
        // Flag on, pure append, but no snapshot captured yet (e.g. the predict right after a
        // context-switch KV drop) → rebuild; the rebuild then captures the first snapshot.
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 7, trimFromCache: 0), cacheTrimmable: false, haveCache: true,
            snapshotCoverage: nil, snapshotReuseEnabled: true)
            == .rebuild(nonTrimmable: true))
    }

    @Test func reuseModeReuseWithNoCacheIsAPlainRebuild() {
        // Defensive: a `.reuse` plan with no live cache (shouldn't happen — tokens imply a cache) is a
        // plain rebuild, NOT tagged non-trimmable (there was no hybrid cache to gate off).
        #expect(PrefixReuse.reuseMode(
            plan: .reuse(reuseTokens: 3, trimFromCache: 0), cacheTrimmable: false, haveCache: false,
            snapshotCoverage: nil, snapshotReuseEnabled: true)
            == .rebuild(nonTrimmable: false))
    }

    // MARK: firstDiff

    // Front: personalization 3 tokens, doc 4 tokens (each with its separator), then the prefix.
    private let spans: [PrefixReuse.FrontSpan] = [
        .init(kind: .personalization, tokens: 3), .init(kind: .focusedDoc, tokens: 4),
    ]
    private let base = [10, 11, 12, 20, 21, 22, 23, 30, 31, 32]

    @Test func identicalPromptsDifferAtTheirLengthInThePrefix() {
        let d = PrefixReuse.firstDiff(cached: base, next: base, frontSpans: spans)
        #expect(d.index == 10)
        #expect(d.segment == "prefix")
        #expect(d.logTag == "firstDiff=10 seg=prefix cached=10 new=10")
    }

    @Test func pureAppendDiffersAtTheCachedLength() {
        let d = PrefixReuse.firstDiff(cached: base, next: base + [33, 34], frontSpans: spans)
        #expect(d.index == 10)
        #expect(d.segment == "prefix")
        #expect(d.newTokens == 12)
    }

    @Test func anEditInsideThePrefixIsReportedAtThatToken() {
        var next = base
        next[8] = 99
        let d = PrefixReuse.firstDiff(cached: base, next: next, frontSpans: spans)
        #expect(d.index == 8)
        #expect(d.segment == "prefix")
    }

    @Test func aChangeInsideTheDocSegmentNamesDoc() {
        var next = base
        next[5] = 99
        let d = PrefixReuse.firstDiff(cached: base, next: next, frontSpans: spans)
        #expect(d.index == 5)
        #expect(d.segment == "doc")
    }

    @Test func aChangeInTheFirstSegmentNamesIt() {
        var next = base
        next[0] = 99
        let d = PrefixReuse.firstDiff(cached: base, next: next, frontSpans: spans)
        #expect(d.index == 0)
        #expect(d.segment == "personalization")
    }

    @Test func aChangeInASeparatorBelongsToTheSegmentItEnds() {
        var next = base
        next[6] = 99   // last token of the doc span
        #expect(PrefixReuse.firstDiff(cached: base, next: next, frontSpans: spans).segment == "doc")
    }

    @Test func anEmptyCacheDiffersAtZero() {
        let d = PrefixReuse.firstDiff(cached: [], next: base, frontSpans: spans)
        #expect(d.index == 0)
        #expect(d.segment == "personalization")
        #expect(d.logTag == "firstDiff=0 seg=personalization cached=0 new=10")
    }

    @Test func withoutAFrontEverythingIsPrefix() {
        let d = PrefixReuse.firstDiff(cached: [1, 2, 3], next: [1, 9, 3], frontSpans: [])
        #expect(d.index == 1)
        #expect(d.segment == "prefix")
    }
}
