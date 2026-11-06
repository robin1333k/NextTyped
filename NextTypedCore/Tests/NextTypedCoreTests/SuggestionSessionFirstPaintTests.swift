import Testing
@testable import NextTypedCore

/// First-paint streaming in the reducer: the first words paint before the full decode, the full
/// decode then replaces them, and a ghost the user already changed is never overwritten by it.
@Suite struct SuggestionSessionFirstPaintTests {

    private func context() -> TypingContext {
        TypingContext(textBeforeCaret: "hello world ", textAfterCaret: "", bundleID: "com.test")
    }

    /// Phase 1 of a typing predict, so a run is pending.
    private func pendingRun(_ s: inout SuggestionSession) {
        _ = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
    }

    @Test func theFirstWordsPaintWhileTheDecodeRuns() {
        var s = SuggestionSession()
        pendingRun(&s)
        let effects = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(effects == [.present(.continuation("I am glad"))])
    }

    @Test func anEarlyPaintStartsTheGraceClockAndTheFullDecodeDoesNotRestartIt() {
        var s = SuggestionSession(tabGrace: true)
        pendingRun(&s)
        let early = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(early == [.present(.continuation("I am glad")), .scheduleSettle(generation: 1)])
        #expect(s.interceptKey(.tab).0 == .passThrough)   // still unsettled inside the window
    }

    @Test func theFullDecodeAfterASettledEarlyPaintStaysSettled() {
        var s = SuggestionSession(tabGrace: true)
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.ghostSettled(generation: 1))
        let full = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(full == [.present(.continuation("I am glad you could"))])
        #expect(s.isPresentationSettled)
    }

    @Test func theFullDecodeThenExtendsTheGhostToTheDisplayWindow() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        // Medium window: five words shown, the rest buffered for Tab.
        #expect(effects == [.present(.continuation("I am glad you could"))])
    }

    @Test func theFirstWordsCarryTheSpellCorrectionToo() {
        var s = SuggestionSession()
        pendingRun(&s)
        let fix = Correction(original: "wrold", replacement: "world", charactersBackFromCaret: 6)
        let effects = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), fix))
        #expect(effects == [.present(.correction(fix))])
    }

    @Test func firstWordsWithNoPendingRunAreIgnored() {
        var s = SuggestionSession()
        #expect(s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil)) == [])
        #expect(s.currentPresentation == .none)
    }

    @Test func aGateOnTheFirstWordsHoldsThePaintForTheFullDecode() {
        var s = SuggestionSession()
        _ = s.handle(.setCompletionLength(.word))
        pendingRun(&s)   // the prefix ends on a space: the word step has no word rest to finish
        let effects = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(effects == [.logGate("first-paint held")])
        #expect(s.currentPresentation == .none)
    }

    @Test func aTabOnTheEarlyGhostIsCarriedIntoTheFullDecode() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(s.interceptKey(.tab).1 == [.insert("I")])
        #expect(s.handle(.hostEcho) == [.present(.continuation(" am glad"))])
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        // The buffer grows past the three early words with no second predict.
        #expect(effects == [.present(.continuation(" am glad you could make"))])
    }

    @Test func typingAlongTheEarlyGhostKeepsTheDecodeRunning() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(s.handle(.typed("I")) == [])   // no cancelInFlight: the full decode is still wanted
        #expect(s.handle(.hostEcho) == [.present(.continuation(" am glad"))])
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(effects == [.present(.continuation(" am glad you could make"))])
    }

    @Test func deletingTheTakenTextReplaysTheFullSuggestionNotTheRest() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.typed("I"))
        _ = s.handle(.hostEcho)
        _ = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        // The user deletes the "I": the caret is back at the context the run started from, so the
        // redundancy cache replays what the main path would show there, the "I" included.
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects.contains(.present(.continuation("I am glad you could"))))
        #expect(s.currentPresentation == .continuation("I am glad you could"))
    }

    @Test func typingThroughTheWholeEarlyGhostWaitsForTheFullDecodeInsteadOfARefill() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(s.handle(.typed("I am glad")) == [.present(.none)])
        #expect(s.handle(.hostEcho) == [.logGate("first-paint refill-deferred")])
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(effects == [.present(.continuation(" you could make it"))])
    }

    @Test func aFullDecodeThatDisagreesWithWhatTheUserTookIsDropped() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.typed("I"))
        _ = s.handle(.hostEcho)
        let effects = s.handle(.predictionArrived(Suggestion(text: "We can talk later"), nil))
        #expect(effects == [.logGate("first-paint final-dropped")])
        #expect(s.currentPresentation == .continuation(" am glad"))
    }

    @Test func aDroppedFullDecodeAfterTheEarlyGhostRanOutRefills() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.typed("I am glad"))
        _ = s.handle(.hostEcho)
        let effects = s.handle(.predictionArrived(Suggestion(text: "We can talk later"), nil))
        #expect(effects == [.logGate("first-paint final-dropped"),
                            .schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    @Test func aCorrectionAppliedOnTheEarlyGhostDoesNotComeBackWithTheFullDecode() {
        var s = SuggestionSession()
        pendingRun(&s)
        let fix = Correction(original: "alot", replacement: "a lot", charactersBackFromCaret: 5)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), fix))
        #expect(s.interceptKey(.tab).1 == [.replace(charactersBack: 5, with: "a lot")])
        _ = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), fix))
        _ = s.handle(.hostEcho)
        #expect(s.currentPresentation == .continuation("I am glad you could"))
        // The next Tab takes a word of the continuation; it never replays the replacement.
        #expect(s.interceptKey(.tab).1 == [.insert("I")])
    }

    @Test func anEarlyGhostTornDownWithoutANewRunDropsItsFullDecode() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.focusChanged)
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(effects == [.logGate("first-paint final-dropped")])
        #expect(s.currentPresentation == .none)
    }

    @Test func aFullDecodeWithoutAnEarlyPaintIsUnchanged() {
        var s = SuggestionSession()
        pendingRun(&s)
        let effects = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(effects == [.present(.continuation("I am glad you could"))])
    }

    @Test func theNextRunAfterADroppedDecodePaintsNormally() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.focusChanged)
        _ = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        pendingRun(&s)
        let effects = s.handle(.predictionArrived(Suggestion(text: "we can talk"), nil))
        #expect(effects == [.present(.continuation("we can talk"))])
    }

    @Test func aRunCancelledAfterItsEarlyPaintDoesNotDropTheNextRunsDecode() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.caretMove)   // hides the early ghost and cancels its run: no full decode follows
        pendingRun(&s)
        let effects = s.handle(.predictionArrived(Suggestion(text: "we can talk"), nil))
        #expect(effects == [.present(.continuation("we can talk"))])
    }

    /// A scroll or zoom under the early ghost cancels its run from the App (`handleViewportChange`), so
    /// no full decode follows. Told so, the reducer treats the early ghost as the whole suggestion, and
    /// using it up refills the way any exhausted buffer does.
    @Test func anEarlyGhostWhoseRunTheAppCancelledRefillsWhenUsedUp() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        #expect(s.handle(.runCancelled) == [])
        #expect(s.currentPresentation == .continuation("I am glad"))
        #expect(s.interceptKey(.tab).1 == [.insert("I")])
        _ = s.handle(.hostEcho)
        #expect(s.interceptKey(.tab).1 == [.insert(" am")])
        _ = s.handle(.hostEcho)
        #expect(s.interceptKey(.tab).1 == [.insert(" glad"), .present(.none)])
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    /// The early ghost already ran out and its echo deferred the refill to the full decode; the run then
    /// dies. The refill the echo deferred is scheduled now.
    @Test func aRunCancelledAfterTheEarlyGhostRanOutSchedulesTheDeferredRefill() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.firstWordsArrived(Suggestion(text: "I am glad"), nil))
        _ = s.handle(.typed("I am glad"))
        #expect(s.handle(.hostEcho) == [.logGate("first-paint refill-deferred")])
        #expect(s.handle(.runCancelled) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    @Test func aRunCancelledWithNoEarlyPaintChangesNothing() {
        var s = SuggestionSession()
        pendingRun(&s)
        _ = s.handle(.predictionArrived(Suggestion(text: "I am glad you could make it"), nil))
        #expect(s.handle(.runCancelled) == [])
        #expect(s.currentPresentation == .continuation("I am glad you could"))
    }
}
