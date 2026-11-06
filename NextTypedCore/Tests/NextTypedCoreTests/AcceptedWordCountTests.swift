import Testing
@testable import NextTypedCore

/// What counts as an accepted word. The exclusions carry the honesty of
/// the whole figure, so each of them is pinned here.
@Suite struct AcceptedWordCountTests {
    @Test func aTabAcceptCountsTheWordItInserted() {
        #expect(AcceptedWordCount.inEffects([.insert(" schnell")], showing: .continuation(" schnell")) == 1)
    }

    @Test func aFullAcceptCountsEveryWordItInserted() {
        // ⌥Tab inserts the whole remaining continuation in one effect.
        #expect(AcceptedWordCount.inEffects([.insert(" über den Zaun")],
                                            showing: .continuation(" über den Zaun")) == 3)
    }

    /// A continuation opening with attaching punctuation rewrites the preceding space
    ///  — still an accept, and still one word.
    @Test func aSpaceConsumingAcceptCountsItsWordsToo() {
        #expect(AcceptedWordCount.inEffects([.replace(charactersBack: 1, with: ". Es")],
                                            showing: .continuation(". Es")) == 1)
    }

    /// A correction uses the same effect shape; only the presentation tells them apart.
    @Test func aCorrectionIsNotAnAcceptedWord() {
        let fix = Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7)
        #expect(AcceptedWordCount.inEffects([.replace(charactersBack: 7, with: "because")],
                                            showing: .correction(fix)) == 0)
    }

    @Test func nothingIsCountedWhenNothingWasShowing() {
        #expect(AcceptedWordCount.inEffects([.insert(" schnell")], showing: .none) == 0)
    }

    /// A type-along advance never produces a write effect — the host inserts the user's own character —
    /// so the empty batch is what the counter sees, and it must stay zero.
    @Test func anAdvanceThatWritesNothingCountsNothing() {
        #expect(AcceptedWordCount.inEffects([.present(.continuation("chnell"))],
                                            showing: .continuation(" schnell")) == 0)
    }

    @Test func punctuationOnItsOwnIsNotAWord() {
        #expect(AcceptedWordCount.words(in: " . ") == 0)
        #expect(AcceptedWordCount.words(in: "") == 0)
        #expect(AcceptedWordCount.words(in: " Größe 3 — ja") == 3)   // the dash is not a word
    }
}
