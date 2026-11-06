import Testing
@testable import NextTypedCore

///  build item 5 — the FIM prompt *shape*: which sentinel goes where, which block is pinned
/// for reuse, and how much of the prompt budget the suffix `S` may claim.
///
/// The engine owns the tokenizer and the MLX call; everything here is the arithmetic that decides what
/// it feeds them, so it is tested with no model. The high-value property is the ordering split: SPM and
/// PSM put the *same* three pieces in a different order, and getting it wrong yields a prompt that still
/// decodes (so no crash, no test failure downstream) but silently stops being an infill.
@Suite struct FIMPromptTests {

    private let sentinels = FIMPrompt.Sentinels(prefix: 90, suffix: 91, middle: 92)!
    private let suffixTokens = [10, 11, 12]
    private let prefixTokens = [20, 21]

    // MARK: Sentinel resolution

    @Test func sentinelsResolveWhenEveryIdIsPresent() {
        #expect(FIMPrompt.Sentinels(prefix: 1, suffix: 2, middle: 3) != nil)
    }

    /// Fail-closed: a model missing any one sentinel is not a FIM model, and a prompt built with a
    /// hole in it would be a forward predict wearing FIM sentinels. The engine routes back to forward.
    @Test func sentinelsFailClosedWhenAnyIdIsMissing() {
        #expect(FIMPrompt.Sentinels(prefix: nil, suffix: 2, middle: 3) == nil)
        #expect(FIMPrompt.Sentinels(prefix: 1, suffix: nil, middle: 3) == nil)
        #expect(FIMPrompt.Sentinels(prefix: 1, suffix: 2, middle: nil) == nil)
    }

    /// `Tokenizer.convertTokenToId` answers the *unknown* id for a token the vocabulary lacks rather
    /// than nil, so an unfiltered lookup would resolve every sentinel to `<unk>` and build a prompt of
    /// three identical junk ids. Treating the unknown id as absent is what keeps that fail-closed.
    @Test func sentinelsTreatTheUnknownIdAsAbsent() {
        #expect(FIMPrompt.Sentinels(prefix: 5, suffix: 2, middle: 3, unknown: 5) == nil)
        #expect(FIMPrompt.Sentinels(prefix: 1, suffix: 2, middle: 3, unknown: 5) != nil)
    }

    // MARK: SPM layout — the shipping primary

    @Test func spmPinsTheSuffixBlockAndGrowsThePrefix() {
        let layout = FIMPrompt.layout(
            ordering: .spm, sentinels: sentinels,
            suffixTokens: suffixTokens, prefixTokens: prefixTokens)

        // <fim_suffix> S <fim_prefix> · P · <fim_middle>
        #expect(layout.pinned == [91, 10, 11, 12, 90])
        #expect(layout.growing == [20, 21])
        #expect(layout.trailing == [92])
        #expect(layout.tokens == [91, 10, 11, 12, 90, 20, 21, 92])
    }

    /// The whole point of SPM: the static `S` sits at the stable front, so a `P`-append leaves the
    /// pinned block byte-identical and `PrefixReuse.plan` can reuse it.
    @Test func spmIsReuseEligible() {
        let layout = FIMPrompt.layout(
            ordering: .spm, sentinels: sentinels,
            suffixTokens: suffixTokens, prefixTokens: prefixTokens)
        #expect(layout.reuseEligible)
    }

    // MARK: PSM layout — the eval fallback

    @Test func psmPutsThePrefixFirstAndTheSuffixBlockInTheTail() {
        let layout = FIMPrompt.layout(
            ordering: .psm, sentinels: sentinels,
            suffixTokens: suffixTokens, prefixTokens: prefixTokens)

        // <fim_prefix> P <fim_suffix> S <fim_middle>
        #expect(layout.pinned == [90])
        #expect(layout.growing == [20, 21])
        #expect(layout.trailing == [91, 10, 11, 12, 92])
        #expect(layout.tokens == [90, 20, 21, 91, 10, 11, 12, 92])
    }

    /// PSM grows `P` in the *middle* of the prompt, so every keystroke shifts `S` and the sentinels
    /// that follow it. The shared run still exists, but everything past it re-prefills — which is the
    /// whole prompt minus a few tokens. The ticket's answer is to force a rebuild rather than pay the
    /// bookkeeping for a reuse that saves nothing.
    @Test func psmIsNotReuseEligible() {
        let layout = FIMPrompt.layout(
            ordering: .psm, sentinels: sentinels,
            suffixTokens: suffixTokens, prefixTokens: prefixTokens)
        #expect(!layout.reuseEligible)
    }

    /// Both orderings carry the same pieces exactly once — a rearrangement, never a drop.
    @Test func bothOrderingsCarryEveryPieceExactlyOnce() {
        for ordering in [FIMPrompt.Ordering.spm, .psm] {
            let layout = FIMPrompt.layout(
                ordering: ordering, sentinels: sentinels,
                suffixTokens: suffixTokens, prefixTokens: prefixTokens)
            #expect(layout.tokens.sorted() == [10, 11, 12, 20, 21, 90, 91, 92])
        }
    }

    /// A caret at the very start of a paragraph has an empty `P`. The block must still be well-formed
    /// (the model infills from nothing on the left), not silently collapse a sentinel.
    @Test func anEmptyPrefixStillProducesAWellFormedBlock() {
        let layout = FIMPrompt.layout(
            ordering: .spm, sentinels: sentinels, suffixTokens: suffixTokens, prefixTokens: [])
        #expect(layout.growing.isEmpty)
        #expect(layout.tokens == [91, 10, 11, 12, 90, 92])
    }

    // MARK: Suffix budget

    /// `S` gets ~¼ of the prompt budget. The remaining ¾ is `P`, which is the side the
    /// model actually continues from.
    @Test func suffixBudgetIsAQuarterOfTheWindow() {
        #expect(FIMPrompt.suffixTokenBudget(windowMax: 512) == 128)
        #expect(FIMPrompt.suffixTokenBudget(windowMax: 400) == 100)
    }

    /// Never zero: a budget of 0 would drop `S` entirely and turn the bridge into a forward predict.
    @Test func suffixBudgetIsNeverZero() {
        #expect(FIMPrompt.suffixTokenBudget(windowMax: 1) == 1)
        #expect(FIMPrompt.suffixTokenBudget(windowMax: 3) == 1)
    }

    /// `S` runs caret → paragraph end, so its **head** is the part adjacent to the caret and the part
    /// the bridge has to land on. Capping keeps the head and drops the far tail.
    @Test func cappingTheSuffixKeepsTheHeadNearestTheCaret() {
        #expect(FIMPrompt.capSuffix([1, 2, 3, 4, 5], budget: 3) == [1, 2, 3])
    }

    @Test func cappingIsANoOpWhenTheSuffixFits() {
        #expect(FIMPrompt.capSuffix([1, 2], budget: 5) == [1, 2])
    }
}
