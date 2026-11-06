import Testing
@testable import NextTypedCore

@Suite struct CaretPositionGateTests {
    // MARK: Suppressed — strictly inside a word

    @Test func suppressesStrictlyInsideAWord() {
        // `hel|lo` — word char on both sides.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "l", after: "l") == false)
    }

    @Test func suppressesInsideANumber() {
        // `12|34` — digits are word characters too.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "1", after: "2") == false)
    }

    @Test func suppressesInsideAGermanWord() {
        // `grü|ßen` — umlaut/ß are Unicode letters.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "ü", after: "ß") == false)
    }

    // MARK: Allowed — every boundary

    @Test func allowsAtEndOfText() {
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "o", after: nil) == true)
    }

    @Test func allowsAtStartOfField() {
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: nil, after: "w") == true)
    }

    @Test func allowsBetweenWordsBeforeNextWord() {
        // `Laden |und` — space to the left.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: " ", after: "u") == true)
    }

    @Test func allowsAtEndOfWordBeforeSpace() {
        // `Laden| und` — space to the right.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "n", after: " ") == true)
    }

    @Test func allowsAfterPunctuation() {
        // `Satz.|` and `Wort|,` — punctuation is not a word character.
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: ".", after: nil) == true)
        #expect(CaretPositionGate.allowsProactiveSuggestion(before: "t", after: ",") == true)
    }

    // MARK: TypingContext convenience

    @Test func contextInsideWordIsSuppressed() {
        let ctx = TypingContext(textBeforeCaret: "hel", textAfterCaret: "lo")
        #expect(CaretPositionGate.allowsProactiveSuggestion(in: ctx) == false)
    }

    @Test func contextBetweenWordsIsAllowed() {
        let ctx = TypingContext(textBeforeCaret: "Ich war im Laden ", textAfterCaret: "und kaufte Milch")
        #expect(CaretPositionGate.allowsProactiveSuggestion(in: ctx) == true)
    }

    @Test func contextAtEndOfTextIsAllowed() {
        let ctx = TypingContext(textBeforeCaret: "Ich war im Laden", textAfterCaret: "")
        #expect(CaretPositionGate.allowsProactiveSuggestion(in: ctx) == true)
    }

    @Test func emptyContextIsAllowed() {
        let ctx = TypingContext(textBeforeCaret: "", textAfterCaret: "")
        #expect(CaretPositionGate.allowsProactiveSuggestion(in: ctx) == true)
    }
}
