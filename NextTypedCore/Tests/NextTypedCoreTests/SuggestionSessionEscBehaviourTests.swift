import Testing
@testable import NextTypedCore

/// The Esc behaviour picker: `dismissOnly` keeps the old Esc
/// (hide and stay quiet until the next keystroke); `dismissAndPauseField` also keeps the focused field
/// quiet for `EscBehaviour.fieldPauseSeconds`, typing included, until the timer or a focus change.
@Suite struct SuggestionSessionEscBehaviourTests {
    private func context() -> TypingContext {
        TypingContext(textBeforeCaret: "hello world ", textAfterCaret: "", bundleID: "com.test")
    }

    private func show(_ text: String, in s: inout SuggestionSession) {
        _ = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: text), nil))
    }

    private func runsInference(_ effects: [Effect]) -> Bool {
        effects.contains { if case .runInference = $0 { return true } else { return false } }
    }

    private func pausingSession() -> SuggestionSession {
        var s = SuggestionSession()
        _ = s.handle(.setEscBehaviour(.dismissAndPauseField))
        return s
    }

    @Test func dismissOnlyIsTheDefaultAndLeavesEscEffectsUnchanged() {
        var s = SuggestionSession()
        show(" world", in: &s)
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none)])
    }

    @Test func dismissOnlyPredictsAgainOnTheNextKeystroke() {
        var s = SuggestionSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        _ = s.handle(.typed("a"))
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(runsInference(effects))
    }

    @Test func pauseFieldArmsATimerWithTheEsc() {
        var s = pausingSession()
        show(" world", in: &s)
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none),
                            .scheduleFieldPauseExpiry(seconds: 30, generation: 1)])
    }

    @Test func pausedFieldRefusesAPredictWhileTypingWithAGateToken() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        _ = s.handle(.typed("a"))
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(!runsInference(effects))
        #expect(effects.contains(.logGate("esc-field-pause")))
    }

    @Test func pausedFieldRefusesForceActivateToo() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false),
                                             trigger: .forceActivate))
        #expect(!runsInference(effects))
        #expect(effects.contains(.logGate("esc-field-pause")))
    }

    @Test func timerExpiryLiftsThePauseWithoutPredicting() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        #expect(s.handle(.fieldPauseExpired(generation: 1)) == [])
        _ = s.handle(.typed("a"))
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(runsInference(effects))
    }

    @Test func aStaleTimerDoesNotEndALaterPause() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)                         // generation 1
        let (_, second) = s.interceptKey(.escape)           // generation 2 restarts the pause
        #expect(second.contains(.scheduleFieldPauseExpiry(seconds: 30, generation: 2)))
        _ = s.handle(.fieldPauseExpired(generation: 1))     // the first timer fires late
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects.contains(.logGate("esc-field-pause")))
    }

    @Test func focusChangeEndsThePause() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        _ = s.handle(.focusChanged)
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(runsInference(effects))
    }

    @Test func switchingToDismissOnlyEndsARunningPause() {
        var s = pausingSession()
        show(" world", in: &s)
        _ = s.interceptKey(.escape)
        _ = s.handle(.setEscBehaviour(.dismissOnly))
        let effects = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(runsInference(effects))
    }

    @Test func escDuringTheScreenshotWindowDoesNotPause() {
        var s = pausingSession()
        _ = s.handle(.screenshotShortcut)
        let (_, effects) = s.interceptKey(.escape)
        #expect(effects == [])
    }

    @Test func escWithNothingShownMutesButArmsNoPause() {
        // An Esc meant for the host (closing a popover, leaving vim's insert mode) dismissed nothing,
        // so the field must not go quiet for 30 s.
        var s = pausingSession()
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none)])
        _ = s.handle(.typed("a"))
        let next = s.handle(.contextReady(context(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(runsInference(next))
        #expect(!next.contains(.logGate("esc-field-pause")))
    }

    @Test func escBehaviourIsASettingsEventThatLandsWhilePaused() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        _ = s.handle(.setEscBehaviour(.dismissAndPauseField))
        _ = s.handle(.setPaused(false))
        show(" world", in: &s)
        let (_, effects) = s.interceptKey(.escape)
        #expect(effects.contains(.scheduleFieldPauseExpiry(seconds: 30, generation: 1)))
    }
}
