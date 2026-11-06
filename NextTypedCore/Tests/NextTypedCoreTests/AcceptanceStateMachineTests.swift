import Testing
@testable import NextTypedCore

@Suite struct AcceptanceStateMachineTests {
    @Test func tabAcceptsOneWordAndKeepsTheRemainder() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world how are you"))
        #expect(sm.handle(.tab) == .insertContinuation(" world"))
        #expect(sm.continuation == Suggestion(text: " how are you"))
    }

    @Test func tabbingThroughEveryWordEmptiesTheSuggestion() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " a b"))
        #expect(sm.handle(.tab) == .insertContinuation(" a"))
        #expect(sm.handle(.tab) == .insertContinuation(" b"))
        #expect(sm.handle(.tab) == .passThrough)          // nothing left
        #expect(!sm.isShowingSomething)
    }

    @Test func acceptAllAcceptsTheWholeSuggestion() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world how"))
        #expect(sm.handle(.acceptAll) == .insertContinuation(" world how"))
        #expect(sm.continuation == nil)
    }

    @Test func correctionTakesTabPrecedenceThenContinuationResumes() {
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world"), correction: fix)
        #expect(sm.handle(.tab) == .applyCorrection(fix))   // typo wins first
        #expect(sm.correction == nil)
        #expect(sm.handle(.tab) == .insertContinuation(" world"))  // then the word
    }

    @Test func escapeDismissesEverything() {
        var sm = AcceptanceStateMachine(
            continuation: Suggestion(text: " world"),
            correction: Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        )
        #expect(sm.handle(.escape) == .dismiss)
        #expect(!sm.isShowingSomething)
    }

    @Test func keysPassThroughWhenNothingIsShowing() {
        var sm = AcceptanceStateMachine()
        #expect(sm.handle(.tab) == .passThrough)
        #expect(sm.handle(.acceptAll) == .passThrough)
        #expect(sm.handle(.escape) == .passThrough)
    }

    @Test func emptyContinuationIsTreatedAsNothing() {
        let sm = AcceptanceStateMachine(continuation: Suggestion(text: ""))
        #expect(!sm.isShowingSomething)
        #expect(sm.continuation == nil)
    }

    // MARK: Low-value continuations are suppressed (SuggestionValueGate)

    @Test func punctuationOnlyContinuationIsTreatedAsNothing() {
        // A bare "." / whitespace-only continuation carries no word content — drop it like an empty,
        // so it never shows and Tab can't insert a stray period.
        for junk in [".", " .", "  ", " - "] {
            let sm = AcceptanceStateMachine(continuation: Suggestion(text: junk))
            #expect(!sm.isShowingSomething, "expected suppressed at init: \(junk)")
            #expect(sm.continuation == nil)
        }
    }

    @Test func setContinuationDropsPunctuationOnly() {
        var sm = AcceptanceStateMachine()
        sm.setContinuation(Suggestion(text: " ,"))
        #expect(sm.continuation == nil)
        #expect(!sm.isShowingSomething)
    }

    @Test func tabOnPunctuationOnlyPassesThrough() {
        // No real word to peel → the key reaches the host instead of inserting punctuation.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "."))
        #expect(sm.handle(.tab) == .passThrough)
    }

    @Test func shortWordCompletionSurvives() {
        // Regression guard for completion-first: a flush single-/two-char completion must
        // NOT be suppressed by the value gate.
        let sm1 = AcceptanceStateMachine(continuation: Suggestion(text: "d"))
        #expect(sm1.continuation == Suggestion(text: "d"))
        let sm2 = AcceptanceStateMachine(continuation: Suggestion(text: " a"))
        #expect(sm2.continuation == Suggestion(text: " a"))
    }

    @Test func peelingToAPunctuationOnlyRemainderClearsIt() {
        // After accepting the last real word, a trailing-punctuation remainder (".") must clear so a
        // further Tab can't insert it.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world ."))
        #expect(sm.handle(.tab) == .insertContinuation(" world"))
        #expect(sm.continuation == nil)
        #expect(!sm.isShowingSomething)
    }

    // MARK: Sliding display window over the full-clause buffer

    @Test func displayContinuationPaintsOnlyTheWindowWhileTheBufferHoldsTheRest() {
        // The engine now returns the whole decoded clause as the buffer; only the first 5 words show,
        // the rest stay buffered for Tab.
        let sm = AcceptanceStateMachine(continuation: Suggestion(text: " one two three four five six seven"))
        #expect(sm.continuation == Suggestion(text: " one two three four five six seven"))  // full buffer
        #expect(sm.displayContinuation == Suggestion(text: " one two three four five"))       // window only
    }

    @Test func tabSlidesTheWindowForwardWithoutReInference() {
        // Proof that Tab peels a buffered word and the window reveals
        // the once-hidden word — no new prediction needed.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " one two three four five six"))
        #expect(sm.displayContinuation == Suggestion(text: " one two three four five"))  // "six" hidden
        #expect(sm.handle(.tab) == .insertContinuation(" one"))
        #expect(sm.displayContinuation == Suggestion(text: " two three four five six"))  // "six" now shown
    }

    @Test func displayContinuationEqualsBufferWhenItFitsTheWindow() {
        let sm = AcceptanceStateMachine(continuation: Suggestion(text: " how are you"))
        #expect(sm.displayContinuation == Suggestion(text: " how are you"))
    }

    @Test func displayContinuationIsNilWhenNothingShows() {
        #expect(AcceptanceStateMachine().displayContinuation == nil)
        #expect(AcceptanceStateMachine(continuation: Suggestion(text: " .")).displayContinuation == nil)
    }

    @Test func valueGateJudgesTheDisplayWindowNotTheWholeBuffer() {
        // Regression for the buffer/window split: a buffer whose first 5 SHOWN words are
        // pure punctuation is junk even though a real word ("really") sits past the window — pre-split
        // the engine trimmed to 5 so the gate saw only the junk head and dropped it. Must still drop.
        let junkHead = AcceptanceStateMachine(continuation: Suggestion(text: " ( ) [ ] : really"))
        #expect(junkHead.continuation == nil)
        #expect(junkHead.displayContinuation == nil)
        #expect(!junkHead.isShowingSomething)
        // Content INSIDE the window keeps it — a number is a word character, so "(2024)" has content.
        let numbered = AcceptanceStateMachine(continuation: Suggestion(text: " (2024) was the year"))
        #expect(numbered.displayContinuation == Suggestion(text: " (2024) was the year"))
    }

    // MARK: Completion length — Short / Medium / Long

    @Test func theCompletionLengthDecidesHowManyBufferedWordsPaint() {
        let buffer = Suggestion(text: " one two three four five six seven eight")
        #expect(AcceptanceStateMachine(continuation: buffer, completionLength: .short)
            .displayContinuation == Suggestion(text: " one two three"))
        #expect(AcceptanceStateMachine(continuation: buffer, completionLength: .medium)
            .displayContinuation == Suggestion(text: " one two three four five"))
        #expect(AcceptanceStateMachine(continuation: buffer, completionLength: .long)
            .displayContinuation == Suggestion(text: " one two three four five six seven eight"))
    }

    /// The window is a ceiling, never a target: a short buffer renders in full at every setting.
    @Test func aBufferShorterThanTheSettingRendersInFull() {
        // The word step is excluded: a buffer that opens with a gap is the next word, which it hides.
        for length in CompletionLength.allCases where length != .word {
            let sm = AcceptanceStateMachine(continuation: Suggestion(text: " how are you"),
                                            completionLength: length)
            #expect(sm.displayContinuation == Suggestion(text: " how are you"))
        }
    }

    /// Changing the setting re-windows what is *painted* and nothing else — the buffer is intact, so
    /// `Tab` still peels across the whole clause and the window slides exactly as before.
    @Test func changingTheLengthRepaintsTheSameBufferWithoutTouchingIt() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " one two three four five six"))
        sm.setCompletionLength(.short)
        #expect(sm.continuation == Suggestion(text: " one two three four five six"))  // buffer untouched
        #expect(sm.displayContinuation == Suggestion(text: " one two three"))
        sm.setCompletionLength(.long)
        #expect(sm.displayContinuation == Suggestion(text: " one two three four five six"))
    }

    @Test func tabPeelsTheWholeBufferAtEverySetting() {
        // The word step is excluded: a buffer that opens with a gap is the next word, which it hides.
        for length in CompletionLength.allCases where length != .word {
            var sm = AcceptanceStateMachine(continuation: Suggestion(text: " one two three four five six"),
                                            completionLength: length)
            var inserted: [String] = []
            while case .insertContinuation(let word) = sm.handle(.tab) { inserted.append(word) }
            #expect(inserted == [" one", " two", " three", " four", " five", " six"])
        }
    }

    /// The value gate judges the *window*, so narrowing it can uncover a punctuation-only
    /// head. `setCompletionLength` re-runs the gate, keeping "`displayContinuation` is non-nil exactly
    /// when `continuation` is" true rather than leaving an invisible buffer `Tab` would still insert.
    @Test func narrowingToAPunctuationOnlyHeadDropsTheContinuation() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " ( ) [ really"), completionLength: .medium)
        #expect(sm.displayContinuation == Suggestion(text: " ( ) [ really"))
        sm.setCompletionLength(.short)
        #expect(sm.continuation == nil)
        #expect(sm.displayContinuation == nil)
        #expect(!sm.isShowingSomething)
    }

    // MARK: Type-along advance (SmartAdvance wired through the buffer/window)

    @Test func advancingTrimsTheTypedHeadFromTheBuffer() {
        // Typing the ghost's own first character shrinks the buffer by that character — no re-inference.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "Ich möchte das"))
        #expect(sm.advance(typed: "I") == .advanced(exhausted: false))
        #expect(sm.continuation == Suggestion(text: "ch möchte das"))
    }

    @Test func advancingConsumesASignificantLeadingSpace() {
        // Completion-first ghosts carry a leading space (the gap before the next word); typing the space
        // advances through it just like any other matching character.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world how"))
        #expect(sm.advance(typed: " ") == .advanced(exhausted: false))
        #expect(sm.continuation == Suggestion(text: "world how"))
    }

    @Test func divergentTypingInvalidatesAndLeavesTheBufferForTheCallerToClear() {
        // A character the ghost doesn't predict invalidates it; the pure method only reports — the caller
        // (coordinator) hides the stale ghost and re-infers.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "world"))
        #expect(sm.advance(typed: "x") == .invalidated)
        #expect(sm.continuation == Suggestion(text: "world"))
    }

    @Test func advancingToExhaustionReportsExhaustedAndClears() {
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "ab"))
        #expect(sm.advance(typed: "a") == .advanced(exhausted: false))
        #expect(sm.advance(typed: "b") == .advanced(exhausted: true))
        #expect(sm.continuation == nil)
        #expect(!sm.isShowingSomething)
    }

    @Test func advancingToAPunctuationOnlyRemainderReportsExhausted() {
        // The value gate drops a contentless remainder, so it counts as exhausted (refill next).
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "x."))
        #expect(sm.advance(typed: "x") == .advanced(exhausted: true))
        #expect(sm.continuation == nil)
    }

    @Test func advanceIsNotApplicableWithNoContinuation() {
        var sm = AcceptanceStateMachine()
        #expect(sm.advance(typed: "a") == .notApplicable)
    }

    @Test func advanceIsNotApplicableWhileACorrectionIsPending() {
        // A correction owns the ghost (visual precedence) — don't trim the buffered continuation under it.
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: " world"), correction: fix)
        #expect(sm.advance(typed: " ") == .notApplicable)
        #expect(sm.continuation == Suggestion(text: " world"))
    }

    @Test func advancingSlidesTheDisplayWindowForward() {
        // Char-wise analogue of tabSlidesTheWindowForwardWithoutReInference: typing the first word's
        // characters peels it from the buffer and the window reveals the once-hidden tail word.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "alpha two three four five six"))
        #expect(sm.displayContinuation == Suggestion(text: "alpha two three four five"))  // "six" hidden
        #expect(sm.advance(typed: "alpha") == .advanced(exhausted: false))
        #expect(sm.continuation == Suggestion(text: " two three four five six"))
        #expect(sm.displayContinuation == Suggestion(text: " two three four five six"))  // "six" now shown
    }

    @Test func emptyTypedIsANoOpAdvance() {
        // Defensive: a `.character` event always carries ≥1 char, but empty input must not crash or mutate.
        var sm = AcceptanceStateMachine(continuation: Suggestion(text: "world"))
        #expect(sm.advance(typed: "") == .advanced(exhausted: false))
        #expect(sm.continuation == Suggestion(text: "world"))
    }
}
