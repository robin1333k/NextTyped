import Testing
@testable import NextTypedCore

@Suite struct BatteryPolicyTests {
    private func result(_ source: PowerSource, pref: Bool, shortcut: Bool) -> (Bool, String) {
        let r = BatteryPolicy.posture(
            source: source,
            preferences: BatteryPreferences(suggestOnlyOnDemand: pref),
            forceShortcutAssigned: shortcut)
        return (r.posture.onDemandOnly, r.reason)
    }

    @Test func onDemandOnlyOnBatteryWithPreferenceAndShortcut() {
        let (on, reason) = result(.battery, pref: true, shortcut: true)
        #expect(on == true)
        #expect(reason == "active")
    }

    @Test func battery_prefOn_noShortcut() {
        let (on, reason) = result(.battery, pref: true, shortcut: false)
        #expect(on == false); #expect(reason == "no-shortcut")
    }

    @Test func battery_prefOff_shortcut() {
        let (on, reason) = result(.battery, pref: false, shortcut: true)
        #expect(on == false); #expect(reason == "pref-off")
    }

    @Test func battery_prefOff_noShortcut() {
        let (on, reason) = result(.battery, pref: false, shortcut: false)
        #expect(on == false); #expect(reason == "pref-off")
    }

    @Test func acCombinationsReportAc() {
        for pref in [true, false] {
            for shortcut in [true, false] {
                let (on, reason) = result(.ac, pref: pref, shortcut: shortcut)
                #expect(on == false)
                #expect(reason == "ac")
            }
        }
    }

    @Test func decodeWordCapIsTheBufferMaximum() {
        let r = BatteryPolicy.posture(source: .battery,
                                      preferences: BatteryPreferences(suggestOnlyOnDemand: true),
                                      forceShortcutAssigned: true)
        #expect(r.posture.decodeWordCap == 8)
    }

    @Test func preferencesDefaultToOff() {
        #expect(BatteryPreferences().suggestOnlyOnDemand == false)
        #expect(BatteryPreferences().shorterCompletions == false)
    }

    // MARK: Shorter completions (CT-61)

    private func cap(_ source: PowerSource, onDemand: Bool, shorter: Bool, shortcut: Bool) -> Int {
        BatteryPolicy.posture(
            source: source,
            preferences: BatteryPreferences(suggestOnlyOnDemand: onDemand, shorterCompletions: shorter),
            forceShortcutAssigned: shortcut).posture.decodeWordCap
    }

    @Test func batteryWithShorterOnDecodesFiveWords() {
        #expect(cap(.battery, onDemand: false, shorter: true, shortcut: false) == 5)
        #expect(cap(.battery, onDemand: true, shorter: true, shortcut: true) == 5)
        #expect(cap(.battery, onDemand: true, shorter: true, shortcut: false) == 5)
    }

    @Test func everyOtherCombinationDecodesEightWords() {
        for onDemand in [true, false] {
            for shortcut in [true, false] {
                #expect(cap(.battery, onDemand: onDemand, shorter: false, shortcut: shortcut) == 8)
                #expect(cap(.ac, onDemand: onDemand, shorter: true, shortcut: shortcut) == 8)
                #expect(cap(.ac, onDemand: onDemand, shorter: false, shortcut: shortcut) == 8)
            }
        }
    }

    @Test func shorterCapIsFiveAndNeverAboveTheBufferCeiling() {
        #expect(BatteryPosture.shorterDecodeWordCap == 5)
        #expect(BatteryPosture.shorterDecodeWordCap <= ContinuationBuffer.maxWords)
    }

    @Test func shorterAloneDoesNotTurnOnDemandOn() {
        let r = BatteryPolicy.posture(
            source: .battery,
            preferences: BatteryPreferences(shorterCompletions: true),
            forceShortcutAssigned: true)
        #expect(r.posture == BatteryPosture(onDemandOnly: false, decodeWordCap: 5))
        #expect(r.reason == "pref-off")
    }
}
