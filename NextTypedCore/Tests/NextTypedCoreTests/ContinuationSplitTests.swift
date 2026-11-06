import Testing
@testable import NextTypedCore

/// Splitting a continuation into the head that fits on the caret line and the overflow that goes into
/// the below-line bubble. A pure DISPLAY split — the acceptance buffer is
/// untouched (the `DisplayWindow` pattern).
@Suite struct ContinuationSplitTests {
    @Test func splitsAtTheWordBoundary() {
        let parts = ContinuationSplit.split(" der Umbruch ist unschön hier", fittingWords: 2)
        #expect(parts.inline == " der Umbruch")
        #expect(parts.overflow == "ist unschön hier")
    }

    @Test func preservesTheLeadingSpaceOnTheInlineHeadOnly() {
        // The engine emits a leading space; inline must keep it (it separates the ghost from the
        // typed word), the bubble draws on its own chip and drops it.
        let parts = ContinuationSplit.split(" one two three", fittingWords: 1)
        #expect(parts.inline == " one")
        #expect(parts.overflow == "two three")
    }

    @Test func noLeadingSpaceInInputStaysWithout() {
        let parts = ContinuationSplit.split("one two three", fittingWords: 2)
        #expect(parts.inline == "one two")
        #expect(parts.overflow == "three")
    }

    @Test func everythingFitsLeavesNoOverflow() {
        let parts = ContinuationSplit.split(" one two", fittingWords: 5)
        #expect(parts.inline == " one two")
        #expect(parts.overflow == "")
    }

    @Test func nothingFitsPutsEverythingInTheOverflow() {
        let parts = ContinuationSplit.split(" one two", fittingWords: 0)
        #expect(parts.inline == "")
        #expect(parts.overflow == "one two")
    }

    @Test func negativeCountBehavesLikeZero() {
        let parts = ContinuationSplit.split(" one two", fittingWords: -3)
        #expect(parts.inline == "")
        #expect(parts.overflow == "one two")
    }

    @Test func collapsesRunsOfSpacesBetweenWords() {
        // Defensive: the ghost's newlines are flattened to spaces upstream (ClauseStop), which can
        // leave a double space. The split must not emit an empty "word".
        let parts = ContinuationSplit.split(" one  two three", fittingWords: 2)
        #expect(parts.inline == " one two")
        #expect(parts.overflow == "three")
    }

    @Test func emptyTextSplitsToEmptyParts() {
        let parts = ContinuationSplit.split("", fittingWords: 2)
        #expect(parts.inline == "")
        #expect(parts.overflow == "")
    }

    @Test func whitespaceOnlyTextHasNoWordsToSplit() {
        // A whitespace-only ghost never renders (SuggestionValueGate), but the split must be total.
        let parts = ContinuationSplit.split("   ", fittingWords: 1)
        #expect(parts.inline == "")
        #expect(parts.overflow == "")
    }

    @Test func singleWordEitherFitsOrOverflowsWhole() {
        #expect(ContinuationSplit.split(" Wort", fittingWords: 1).inline == " Wort")
        #expect(ContinuationSplit.split(" Wort", fittingWords: 1).overflow == "")
        #expect(ContinuationSplit.split(" Wort", fittingWords: 0).overflow == "Wort")
    }
}
