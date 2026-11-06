import Testing
@testable import NextTypedCore

@Suite("LanguagePolicy: the language off switch verdict")
struct LanguagePolicyTests {
    private func reading(_ tag: String, _ top: Double = 0.95, _ runnerUp: Double = 0.02, letters: Int = 120) -> LanguageReading {
        LanguageReading(tag: tag, probability: top, runnerUpProbability: runnerUp, letterCount: letters)
    }

    @Test func aSwitchedOffLanguageIsOff() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: reading("de")) == .off("de"))
    }

    @Test func aLanguageThatIsNotSwitchedOffIsAllowed() {
        #expect(LanguagePolicy(disabled: [.tag("en")]).verdict(for: reading("de")) == .allowed("de"))
    }

    @Test func fewerThanFortyLettersIsOpenShort() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: reading("de", letters: 30)) == .open(.short))
    }

    @Test func aTopProbabilityBelowEightyPercentIsOpenUnsure() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: reading("de", 0.70)) == .open(.unsure))
    }

    @Test func aRunnerUpAboveThirtyPercentIsOpenMixed() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: reading("de", 0.90, 0.35)) == .open(.mixed))
    }

    @Test func allOthersSwitchesOffALanguageNoTagNames() {
        #expect(LanguagePolicy(disabled: [.allOthers]).verdict(for: reading("fr")) == .off("fr"))
    }

    @Test func aRegionalTagCountsAsItsBaseLanguage() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: reading("de-CH")) == .off("de"))
    }

    @Test func noReadingIsOpenShort() {
        #expect(LanguagePolicy(disabled: [.tag("de")]).verdict(for: nil) == .open(.short))
    }

    @Test func paragraphTailStopsAtTheLastBreakAndAtFourHundredCharacters() {
        #expect(LanguagePolicy.paragraphTail(of: "First one.\nSecond one") == "Second one")
        let long = String(repeating: "a", count: 500)
        #expect(LanguagePolicy.paragraphTail(of: long) == String(repeating: "a", count: 400))
    }
}

@Suite("LanguagePolicy stored value")
struct LanguagePolicyStoredValueTests {
    @Test func absentValueSwitchesNothingOff() {
        #expect(LanguagePolicy(stored: nil).disabled.isEmpty)
    }

    @Test func tagsAndStarDecode() {
        let policy = LanguagePolicy(stored: ["de", "*"])
        #expect(policy.disabled == [.tag("de"), .allOthers])
    }

    @Test func damagedEntriesAreDropped() {
        #expect(LanguagePolicy(stored: "de").disabled.isEmpty)
        #expect(LanguagePolicy(stored: [7, "", " DE "]).disabled == [.tag("de")])
    }

    @Test func storedValueRoundTripsSorted() {
        let policy = LanguagePolicy(disabled: [.tag("en"), .allOthers, .tag("de")])
        #expect(policy.storedValue == ["*", "de", "en"])
        #expect(LanguagePolicy(stored: policy.storedValue) == policy)
    }
}
