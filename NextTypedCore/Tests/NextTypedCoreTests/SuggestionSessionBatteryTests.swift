import Testing
@testable import NextTypedCore

/// Battery on-demand mode in the reducer.
@Suite struct SuggestionSessionBatteryTests {
    private let onDemand = BatteryPosture(onDemandOnly: true, decodeWordCap: 8)
    private let caret = CaretFacts(hasTextToRight: false)

    private func context(_ before: String = "hello world ") -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: "", bundleID: "com.test")
    }

    private func onDemandSession() -> SuggestionSession {
        var s = SuggestionSession()
        _ = s.handle(.setBatteryPosture(onDemand))
        return s
    }

    @Test func typingUnderOnDemandWantsCorrectionOnly() {
        var s = onDemandSession()
        let c = context()
        #expect(s.handle(.contextReady(c, caret: caret, trigger: .typing))
                == [.surfaceVerdict(.on), .logGate("battery on-demand trigger=typing"), .present(.none),
                    .runInference(c, wantsCorrection: true, wantsContinuation: false)])
    }

    @Test func caretMoveUnderOnDemandRunsNoInference() {
        var s = onDemandSession()
        #expect(s.handle(.contextReady(context(), caret: caret, trigger: .caretMoved))
                == [.surfaceVerdict(.on), .logGate("battery on-demand trigger=caretMoved"), .present(.none)])
    }

    @Test func forceActivateReachesInferenceUnderOnDemand() {
        var s = onDemandSession()
        let c = context()
        #expect(s.handle(.contextReady(c, caret: caret, trigger: .forceActivate))
                == [.surfaceVerdict(.on), .logGate("force-activate override"),
                    .runInference(c, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func acceptRefillReachesInferenceUnderOnDemand() {
        var s = onDemandSession()
        let c = context()
        var plain = SuggestionSession()
        let expected = plain.handle(.contextReady(c, caret: caret, trigger: .acceptRefill))
        #expect(s.handle(.contextReady(c, caret: caret, trigger: .acceptRefill)) == expected)
        #expect(expected == [.surfaceVerdict(.on), .runInference(c, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func temporaryQuietStillBeatsAForcedPress() {
        var s = onDemandSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        #expect(s.handle(.contextReady(context(), caret: caret, trigger: .forceActivate))
                == [.surfaceVerdict(.temporaryQuiet), .logGate("temporary-quiet app=com.test"), .present(.none)])
    }

    @Test func pausedSessionStillTakesThePostureAndDropsAForcedPress() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.setBatteryPosture(onDemand)) == [])
        #expect(s.batteryPosture == onDemand)
        #expect(s.handle(.contextReady(context(), caret: caret, trigger: .forceActivate)) == [])
    }

    @Test func flippingIntoOnDemandClearsATypingGhost() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(context(), caret: caret, trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: "again soon"), nil))
        #expect(s.currentPresentation != .none)
        #expect(s.handle(.setBatteryPosture(onDemand)) == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func flippingIntoOnDemandKeepsAForcedGhost() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(context(), caret: caret, trigger: .forceActivate))
        _ = s.handle(.predictionArrived(Suggestion(text: "again soon"), nil))
        #expect(s.handle(.setBatteryPosture(onDemand)) == [])
        #expect(s.currentPresentation != .none)
    }

    @Test func flippingOutOfOnDemandSchedulesNothing() {
        var s = onDemandSession()
        #expect(s.handle(.setBatteryPosture(.normal)) == [])
    }

    @Test func normalPostureLeavesTypingEffectsAsOnMain() {
        let c = context()
        var plain = SuggestionSession()
        let expected = plain.handle(.contextReady(c, caret: caret, trigger: .typing))
        var s = SuggestionSession()
        _ = s.handle(.setBatteryPosture(.normal))
        #expect(s.handle(.contextReady(c, caret: caret, trigger: .typing)) == expected)
        #expect(expected == [.surfaceVerdict(.on), .runInference(c, wantsCorrection: true, wantsContinuation: true)])
    }

    @Test func capChangeDropsRedundancyReplay() {
        var s = SuggestionSession()
        let c = context("We discussed the plan and the ")
        _ = s.handle(.contextReady(c, caret: caret, trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: "eight words decoded on the charger before unplug"), nil))
        _ = s.handle(.setBatteryPosture(BatteryPosture(onDemandOnly: false, decodeWordCap: 5)))
        let effects = s.handleReady(.contextReady(c, caret: caret, trigger: .caretMoved))
        #expect(effects.contains(.runInference(c, wantsCorrection: false, wantsContinuation: true)))
        #expect(!effects.contains(.present(.continuation("eight words decoded on the charger before unplug"))))
    }

    @Test func unchangedCapKeepsRedundancyReplay() {
        var s = SuggestionSession()
        let c = context("We discussed the plan and the ")
        _ = s.handle(.contextReady(c, caret: caret, trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: "eight words decoded on the charger before unplug"), nil))
        _ = s.handle(.setBatteryPosture(BatteryPosture(onDemandOnly: false, decodeWordCap: 8)))
        let effects = s.handleReady(.contextReady(c, caret: caret, trigger: .caretMoved))
        #expect(!effects.contains(where: { if case .runInference = $0 { return true } else { return false } }))
    }
}
