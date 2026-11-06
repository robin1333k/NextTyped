import Testing
@testable import NextTypedCore

@Suite("SentenceStartCase — capitalize a provable sentence opening (output-quality/02)")
struct SentenceStartCaseTests {

    // MARK: Signal 1 — the caret sits at a sentence opening

    @Test("a lowercase German sentence start after a typed period is capitalized")
    func capitalizesAfterATypedPeriod() {
        #expect(SentenceStartCase.apply(to: "dann wurde es kalt",
                                        textBeforeCaret: "Es war Winter. ")
                == "Dann wurde es kalt")
    }

    @Test("an umlaut first letter is capitalized as one grapheme")
    func capitalizesAnUmlaut() {
        #expect(SentenceStartCase.apply(to: "über die Straße",
                                        textBeforeCaret: "Er ging los. ")
                == "Über die Straße")
    }

    @Test("a flush caret keeps the continuation's leading space")
    func keepsTheLeadingSpace() {
        let out = SentenceStartCase.apply(to: " dann kam der Frühling",
                                          textBeforeCaret: "Es war Winter.")
        #expect(out == " Dann kam der Frühling")
        #expect(out.count == " dann kam der Frühling".count)
    }

    @Test("only the FIRST word is touched — the rest of the buffer is byte-identical")
    func touchesOnlyTheFirstWord() {
        #expect(SentenceStartCase.apply(to: "dann kam der tag und alles",
                                        textBeforeCaret: "Ende. ")
                == "Dann kam der tag und alles")
    }

    @Test("`!` and `?` open a sentence too")
    func exclamationAndQuestionOpenASentence() {
        #expect(SentenceStartCase.apply(to: "das war knapp", textBeforeCaret: "Halt! ")
                == "Das war knapp")
        #expect(SentenceStartCase.apply(to: "niemand wusste es", textBeforeCaret: "Warum? ")
                == "Niemand wusste es")
    }

    // MARK: Signal 2 — the continuation itself leads with sentence punctuation

    @Test("a boundary-punctuation lead capitalizes the word AFTER the punctuation")
    func capitalizesAfterALeadingBoundary() {
        #expect(SentenceStartCase.apply(to: ". dann wird es kalt",
                                        textBeforeCaret: "Es wird Winter")
                == ". Dann wird es kalt")
    }

    @Test("a leading boundary that still carries its own space is handled")
    func capitalizesAfterALeadingBoundaryWithSpace() {
        // BoundaryLeadJoin normally strips this, but the guard must not depend on having run after it.
        #expect(SentenceStartCase.apply(to: " . dann wird es kalt",
                                        textBeforeCaret: "Es wird Winter")
                == " . Dann wird es kalt")
    }

    // MARK: What must stay byte-identical

    @Test("a mid-sentence continuation is byte-identical")
    func midSentenceIsUntouched() {
        #expect(SentenceStartCase.apply(to: " kalt im Winter",
                                        textBeforeCaret: "Es wird sehr")
                == " kalt im Winter")
    }

    @Test("a sentence already under way is byte-identical — the boundary is not the NEAREST fact")
    func aSentenceAlreadyUnderWayIsUntouched() {
        // The prefix's last boundary is a period, but two words have been written since: the caret is
        // mid-sentence, and reading only "the prefix contains a boundary" would capitalize here.
        #expect(SentenceStartCase.apply(to: " frühling und wärme",
                                        textBeforeCaret: "Es war Winter. Dann kam der")
                == " frühling und wärme")
    }

    @Test("a word completion is byte-identical — structurally, not by a special case")
    func wordCompletionIsUntouched() {
        // A completion ghost sits at a flush caret inside a word, so neither signal can fire.
        #expect(SentenceStartCase.apply(to: "er wurde kalt", textBeforeCaret: "Es war Wint")
                == "er wurde kalt")
    }

    @Test("an already-capitalized start is byte-identical")
    func alreadyCapitalizedIsUntouched() {
        #expect(SentenceStartCase.apply(to: "Dann kam der Frühling",
                                        textBeforeCaret: "Es war Winter. ")
                == "Dann kam der Frühling")
    }

    @Test("a comma/semicolon/colon lead does not open a sentence")
    func attachingPunctuationIsNotASentenceOpening() {
        #expect(SentenceStartCase.apply(to: ", und dann kam er", textBeforeCaret: "Es wird kalt")
                == ", und dann kam er")
        #expect(SentenceStartCase.apply(to: "; dann kam er", textBeforeCaret: "Es wird kalt")
                == "; dann kam er")
    }

    @Test("a `.Net`-style token lead is not a sentence opening")
    func tokenLeadIsNotASentenceOpening() {
        #expect(SentenceStartCase.apply(to: ".net und mehr", textBeforeCaret: "Er nutzt")
                == ".net und mehr")
    }

    @Test("a decimal being typed is not a sentence opening we can change")
    func decimalIsUntouched() {
        // The prefix's "." IS at end-of-text, so the shared boundary rule reads it as an opening —
        // but the first word character is a digit, whose uppercase form is itself.
        #expect(SentenceStartCase.apply(to: "500 Euro", textBeforeCaret: "Der Preis liegt bei 3.")
                == "500 Euro")
    }

    @Test("a single-letter abbreviation does not open a sentence (`z. B.`)")
    func singleLetterAbbreviationIsNotASentenceOpening() {
        #expect(SentenceStartCase.apply(to: "das gilt auch hier",
                                        textBeforeCaret: "Für Tiere, z. B. ")
                == "das gilt auch hier")
        #expect(SentenceStartCase.apply(to: "das gilt auch hier",
                                        textBeforeCaret: "Für Tiere, z.B. ")
                == "das gilt auch hier")
    }

    @Test("a real word before the period still opens a sentence")
    func aRealWordBeforeThePeriodStillOpens() {
        #expect(SentenceStartCase.apply(to: "das gilt auch hier", textBeforeCaret: "So ist es. ")
                == "Das gilt auch hier")
    }

    @Test("a newline caret is left to the running-thought gate, not capitalized here")
    func structuralBreakIsNotThisGuardsBusiness() {
        #expect(SentenceStartCase.apply(to: "dann kam der Frühling",
                                        textBeforeCaret: "Es war Winter.\n")
                == "dann kam der Frühling")
    }

    // MARK: The length trap

    @Test("a first letter whose uppercase is TWO characters is left alone (`ß` → `SS`)")
    func multiCharacterUppercaseIsRefused() {
        let out = SentenceStartCase.apply(to: "ßabc weiter", textBeforeCaret: "Es war Winter. ")
        #expect(out == "ßabc weiter")
        #expect(out.count == "ßabc weiter".count)
    }

    @Test("no word character at all is a no-op")
    func noWordCharacterIsANoOp() {
        #expect(SentenceStartCase.apply(to: ". ", textBeforeCaret: "Es war Winter") == ". ")
        #expect(SentenceStartCase.apply(to: "", textBeforeCaret: "Es war Winter. ") == "")
    }

    @Test("an empty prefix is a no-op — a document start belongs to the running-thought gate")
    func documentStartIsANoOp() {
        #expect(SentenceStartCase.apply(to: "dann kam er", textBeforeCaret: "") == "dann kam er")
    }
}
