import Testing
@testable import NextTypedCore

@Suite struct SmartAdvanceTests {
    @Test func advancesWhenTypedMatchesHead() {
        let s = Suggestion(text: "world how are you")
        #expect(SmartAdvance.apply(typed: "w", to: s) == .advanced(remaining: Suggestion(text: "orld how are you")))
    }

    @Test func multiCharacterPrefixAdvances() {
        let s = Suggestion(text: "world")
        #expect(SmartAdvance.apply(typed: "wor", to: s) == .advanced(remaining: Suggestion(text: "ld")))
    }

    @Test func invalidatesOnDivergence() {
        let s = Suggestion(text: "world")
        #expect(SmartAdvance.apply(typed: "x", to: s) == .invalidated)
    }

    @Test func emptyTypedKeepsSuggestion() {
        let s = Suggestion(text: "world")
        #expect(SmartAdvance.apply(typed: "", to: s) == .advanced(remaining: s))
    }

    @Test func characterOverloadMatchesStringOverload() {
        let s = Suggestion(text: "hello")
        #expect(SmartAdvance.apply(typed: Character("h"), to: s) == .advanced(remaining: Suggestion(text: "ello")))
    }
}
