import Testing
@testable import NextTypedCore

@Suite struct SuggestionValueGateTests {
    // MARK: Suppressed — no word content

    @Test func suppressesEmpty() {
        // The already-handled empty case: generalised by the same rule.
        #expect(SuggestionValueGate.isRenderable("") == false)
    }

    @Test func suppressesWhitespaceOnly() {
        // A lone gap / multiple spaces / a newline — nothing visible to accept.
        #expect(SuggestionValueGate.isRenderable(" ") == false)
        #expect(SuggestionValueGate.isRenderable("  ") == false)
        #expect(SuggestionValueGate.isRenderable("\n") == false)
    }

    @Test func suppressesBarePeriod() {
        // The single biggest offender in the logs (32× / 63×): a bare "." offers nothing to Tab and
        // would insert a stray period + space. Both flush and leading-space forms.
        #expect(SuggestionValueGate.isRenderable(".") == false)
        #expect(SuggestionValueGate.isRenderable(" .") == false)
    }

    @Test func suppressesPunctuationOnly() {
        // Any punctuation-/symbol-only run, with or without a leading space.
        for junk in [",", ":", ";", "!", "?", "…", "-", " - ", " ,", "()", "\"\"", "—"] {
            #expect(SuggestionValueGate.isRenderable(junk) == false, "expected suppressed: \(junk)")
        }
    }

    // MARK: Kept — carries at least one word character

    @Test func keepsSingleCharWordCompletion() {
        // Completion-first renders a flush word-completion that can be a single character
        // ("worl|" → "d"). It MUST survive the gate.
        #expect(SuggestionValueGate.isRenderable("d") == true)
        #expect(SuggestionValueGate.isRenderable("se") == true)
    }

    @Test func keepsShortRealWords() {
        // One-/two-letter real words (next-word form, leading space) are low char-count but valid.
        #expect(SuggestionValueGate.isRenderable(" a") == true)
        #expect(SuggestionValueGate.isRenderable(" I") == true)
        #expect(SuggestionValueGate.isRenderable(" und") == true)
    }

    @Test func keepsMultiWordContinuation() {
        #expect(SuggestionValueGate.isRenderable(" world how are you") == true)
    }

    @Test func keepsNumbersAndMixedContent() {
        // Digits are word characters — a numeric or currency continuation is real content.
        #expect(SuggestionValueGate.isRenderable(" 2024") == true)
        #expect(SuggestionValueGate.isRenderable(" 3.500") == true)
        #expect(SuggestionValueGate.isRenderable(" 100%") == true)
    }

    @Test func keepsNonLatinScripts() {
        // Language-agnostic (no hardcoded English): umlauts and other scripts count.
        #expect(SuggestionValueGate.isRenderable(" Übung") == true)
        #expect(SuggestionValueGate.isRenderable(" straße") == true)
        #expect(SuggestionValueGate.isRenderable(" 日本") == true)
    }

    // MARK: Suggestion convenience

    @Test func suggestionOverloadMatchesStringRule() {
        #expect(SuggestionValueGate.isRenderable(Suggestion(text: ".")) == false)
        #expect(SuggestionValueGate.isRenderable(Suggestion(text: " world")) == true)
    }

    // MARK: Held-back punctuation

    @Test func heldBackPunctuationRemainderIsRenderable() {
        for held in [".", ",", "?!", "…", ", und"] {
            #expect(SuggestionValueGate.isRenderable(held, heldBackPunctuation: true), "held: \(held)")
        }
    }

    @Test func heldBackFlagDoesNotLetEmptyOrBlankThrough() {
        #expect(SuggestionValueGate.isRenderable("", heldBackPunctuation: true) == false)
        #expect(SuggestionValueGate.isRenderable("  ", heldBackPunctuation: true) == false)
    }

    @Test func aBareModelPeriodStaysSuppressedWithoutTheFlag() {
        #expect(SuggestionValueGate.isRenderable(".", heldBackPunctuation: false) == false)
    }
}
