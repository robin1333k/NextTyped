import Testing
@testable import NextTypedCore

/// A suspected typo withholds the continuation, keeps the correction, and the
/// host echo after `Tab` applies the fix refills from the corrected word.
@Suite struct TypoSuspectedSessionTests {
    private let fix = Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7)

    private func armed(_ before: String) -> SuggestionSession {
        var s = SuggestionSession()
        let context = TypingContext(textBeforeCaret: before, textAfterCaret: "", bundleID: "com.test")
        _ = s.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        return s
    }

    @Test func noCorrectionShowsNothingAndLogsTheGate() {
        var s = armed("I write qzxvw")
        let effects = s.handle(.typoSuspected(nil))
        #expect(effects == [.logGate("typo-suspected"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func aCorrectionStillShowsWithNoContinuation() {
        var s = armed("I write becuase")
        let effects = s.handle(.typoSuspected(fix))
        #expect(effects == [.logGate("typo-suspected"), .present(.correction(fix))])
        #expect(s.currentPresentation == .correction(fix))
    }

    @Test func theEchoAfterTabAppliesTheFixSchedulesARefillAtTheCorrectedWord() {
        var s = armed("I write becuase")
        _ = s.handle(.typoSuspected(fix))
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects.contains(.replace(charactersBack: 7, with: "because")))
        #expect(s.handle(.hostEcho) == [
            .schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }
}
