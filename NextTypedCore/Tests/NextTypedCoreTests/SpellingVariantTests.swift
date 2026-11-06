import Testing
@testable import NextTypedCore

@Suite("SpellingVariant: US to British or Canadian spelling on the decoded continuation (CT-20)")
struct SpellingVariantTests {

    private let prefix = "I wrote a long note about "

    @Test("British maps -or/-our and -ize/-ise")
    func britishAcceptanceExample() {
        #expect(SpellingVariant.british.apply(to: "the color of the organization", textBeforeCaret: prefix)
                == "the colour of the organisation")
    }

    @Test("Canadian maps -or/-our and keeps -ize")
    func canadianAcceptanceExample() {
        #expect(SpellingVariant.canadian.apply(to: "the color of the organization", textBeforeCaret: prefix)
                == "the colour of the organization")
    }

    @Test("off returns the text unchanged")
    func offIsIdentity() {
        let text = "the color of the organization"
        #expect(SpellingVariant.off.apply(to: text, textBeforeCaret: prefix) == text)
    }

    @Test("the source word's case pattern is kept")
    func caseIsKept() {
        #expect(SpellingVariant.british.apply(to: "Color and COLOR and color", textBeforeCaret: prefix)
                == "Colour and COLOUR and colour")
    }

    @Test("inflected forms map")
    func inflections() {
        #expect(SpellingVariant.british.apply(to: "colors, colored, coloring, favorite, neighborhood",
                                              textBeforeCaret: prefix)
                == "colours, coloured, colouring, favourite, neighbourhood")
        #expect(SpellingVariant.british.apply(to: "organizes realized analyzing", textBeforeCaret: prefix)
                == "organises realised analysing")
    }

    @Test("-er to -re, doubled l, -og to -ogue")
    func otherRegularClasses() {
        #expect(SpellingVariant.canadian.apply(to: "the center traveled to the theater",
                                               textBeforeCaret: prefix)
                == "the centre travelled to the theatre")
        #expect(SpellingVariant.british.apply(to: "a catalog and a dialog", textBeforeCaret: prefix)
                == "a catalogue and a dialogue")
    }

    @Test("British-only irregulars stay as they are in Canadian")
    func britishOnlyIrregulars() {
        #expect(SpellingVariant.british.apply(to: "my mom has aluminum", textBeforeCaret: prefix)
                == "my mum has aluminium")
        #expect(SpellingVariant.canadian.apply(to: "my mom has aluminum", textBeforeCaret: prefix)
                == "my mom has aluminum")
    }

    @Test("words outside the table, including near-matches, pass through")
    func unlistedWordsPass() {
        let text = "a prize for the size of the rumour and the doctor"
        #expect(SpellingVariant.british.apply(to: text, textBeforeCaret: prefix) == text)
    }

    @Test("a fragment glued onto the word before the caret is not rewritten")
    func wordCompletionFragmentIsUntouched() {
        #expect(SpellingVariant.british.apply(to: "or of", textBeforeCaret: "the col")
                == "or of")
        #expect(SpellingVariant.british.apply(to: " color", textBeforeCaret: "the ")
                == " colour")
    }

    @Test("punctuation and whitespace survive")
    func punctuationSurvives() {
        #expect(SpellingVariant.british.apply(to: " color, (honor) \"labor\"\n", textBeforeCaret: "x ")
                == " colour, (honour) \"labour\"\n")
    }

    @Test("a German continuation passes through unchanged")
    func germanIsUntouched() {
        let before = "Gestern habe ich mit meinem Kollegen über die Arbeit gesprochen und wir haben beschlossen, dass "
        let text = "das Wort color und organize in unserem deutschen Text nicht übersetzt werden soll"
        #expect(SpellingVariant.british.apply(to: text, textBeforeCaret: before) == text)
    }

    @Test("a Spanish continuation passes through unchanged")
    func spanishIsUntouched() {
        let before = "El cuadro tiene un "
        let text = "color muy bonito y el valor del honor es alto"
        #expect(SpellingVariant.british.apply(to: text, textBeforeCaret: before) == text)
    }

    @Test("stored value reads fail-safe, default is off")
    func storedValue() {
        #expect(SpellingVariant(stored: nil) == .off)
        #expect(SpellingVariant(stored: "klingon") == .off)
        #expect(SpellingVariant(stored: "british") == .british)
        #expect(SpellingVariant.default == .off)
    }

    // MARK: Through the reducer

    private func session(_ variant: SpellingVariant) -> SuggestionSession {
        var s = SuggestionSession()
        _ = s.handle(.setSpellingVariant(variant))
        return s
    }

    private func present(_ text: String, in s: inout SuggestionSession) -> [Effect] {
        let ctx = TypingContext(textBeforeCaret: "We discussed the plan and the ", textAfterCaret: "",
                                bundleID: "com.test")
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        return s.handle(.predictionArrived(Suggestion(text: text), nil))
    }

    @Test("the presented ghost carries the British spelling and the change is logged")
    func reducerAppliesVariant() {
        var s = session(.british)
        let effects = present("color of the organization", in: &s)
        #expect(s.currentPresentation == .continuation("colour of the organisation"))
        #expect(effects.contains(.logGate("spelling-variant british rewrote")))
    }

    @Test("with off the presented ghost is byte-identical and nothing is logged")
    func reducerOffIsIdentity() {
        var s = session(.off)
        let effects = present("color of the organization", in: &s)
        #expect(s.currentPresentation == .continuation("color of the organization"))
        #expect(!effects.contains(.logGate("spelling-variant british rewrote")))
    }

    @Test("Tab inserts the British spelling")
    func tabInsertsVariant() {
        var s = session(.british)
        _ = present("color of the organization", in: &s)
        let (_, effects) = s.interceptKey(.tab)
        #expect(effects == [.insert("colour")])
    }

    @Test("flipping the variant clears a showing ghost")
    func flipClearsGhost() {
        var s = session(.off)
        _ = present("color of the organization", in: &s)
        _ = s.handle(.setSpellingVariant(.british))
        #expect(s.currentPresentation == .none)
    }

    @Test("after a flip to off, a caret move with unchanged inputs does not replay the British ghost")
    func flipDropsRedundancyCache() {
        var s = session(.british)
        _ = present("color of the organization", in: &s)
        #expect(s.currentPresentation == .continuation("colour of the organisation"))
        _ = s.handle(.setSpellingVariant(.off))
        let ctx = TypingContext(textBeforeCaret: "We discussed the plan and the ", textAfterCaret: "",
                                bundleID: "com.test")
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(s.currentPresentation == .none)
        #expect(!effects.contains(.present(.continuation("colour of the organisation"))))
        let after = s.handle(.predictionArrived(Suggestion(text: "color of the organization"), nil))
        #expect(s.currentPresentation == .continuation("color of the organization"))
        #expect(!after.contains(.logGate("spelling-variant british rewrote")))
    }
}
