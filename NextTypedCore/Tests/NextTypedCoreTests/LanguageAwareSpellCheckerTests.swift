import Testing
@testable import NextTypedCore

/// the spell correction passes the language detected from the paragraph and shows
/// nothing when it is unsure. The dictionary and the recognizer are faked (system boundaries) with
/// the answers measured on the real `NSSpellChecker`: `Strase` is `Stars` in English, `Straße` in
/// German; `colour` is misspelled in `en` (US) and fine in `en_GB`.
struct LanguageAwareSpellCheckerTests {
    private struct Dictionary: WordSpelling {
        let entries: [String: [String: String]]   // language -> typo -> fix
        let accepted: [String: Set<String>]       // language -> words it accepts
        func isMisspelled(_ word: String, language: String) async -> Bool {
            if accepted[language]?.contains(word) == true { return false }
            return entries[language]?[word] != nil || (language.hasPrefix("en") && !["the", "Hallo"].contains(word))
        }
        func guesses(for word: String, language: String) async -> [String] {
            [entries[language]?[word] ?? "Stars"]
        }
        /// Words that start a longer word in the fake dictionaries (`Sommerferienpl`).
        var prefixes: Set<String> = ["Sommerferienpl"]
        func hasCompletions(for word: String, in context: String, language: String) async -> Bool {
            prefixes.contains(word) && context.hasSuffix(word)
        }
    }

    private static let dictionary = Dictionary(entries: [
        "de": ["Strase": "Straße", "jetz": "jetzt"],
        "en": ["teh": "the", "Strase": "Stars", "jetz": "jets", "colour": "color"],
        "en_GB": ["teh": "the"],
    ], accepted: ["en_GB": ["colour"]])

    /// Reads German when the text holds a German marker word, English when it holds an English one,
    /// nothing otherwise. Records every text it was asked to read.
    private final class Recognizer: LanguageIdentifying, @unchecked Sendable {
        private(set) var texts: [String] = []
        func reading(of text: String) -> LanguageReading? {
            texts.append(text)
            let tag: String
            if text.contains("Wohnung") || text.contains("Zeit") || text.contains("Auswertung") { tag = "de" }
            else if text.contains("market") || text.contains("English") || text.contains("weather") { tag = "en" }
            else { return nil }
            return LanguageReading(tag: tag, probability: 0.95, runnerUpProbability: 0.02, letterCount: 60)
        }
    }

    private final class LogBox: @unchecked Sendable {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    private func correct(_ before: String, words: any WordSpelling = LanguageAwareSpellCheckerTests.dictionary,
                         recognizer: Recognizer = Recognizer(), log: LogBox = LogBox()) async -> Correction? {
        let checker = LanguageAwareSpellChecker(words: words, identifier: recognizer, log: { log.append($0) })
        return await checker.correction(for: TypingContext(textBeforeCaret: before))
    }

    @Test func germanParagraphFixesStrase() async {
        let c = await correct("Ich wohne seit zwei Jahren in einer kleinen Wohnung an der Strase")
        #expect(c?.replacement == "Straße")
        #expect(c?.charactersBackFromCaret == 6)
    }

    @Test func germanParagraphFixesJetz() async {
        let c = await correct("Ich habe heute leider keine Zeit mehr und muss jetz")
        #expect(c?.replacement == "jetzt")
    }

    @Test func englishParagraphStillFixesTeh() async {
        let c = await correct("I went to the market yesterday morning and then walked along teh")
        #expect(c?.replacement == "the")
    }

    @Test func aLoneWordGivesNoLanguageAndNoCorrection() async {
        let log = LogBox()
        let c = await correct("Strase", log: log)
        #expect(c == nil)
        #expect(log.lines == ["[gate]: spell-language-open word=Strase"])
    }

    @Test func onlyTheCurrentParagraphDecidesTheLanguage() async {
        let text = "This is a long English paragraph about nothing in particular at all.\nIch wohne seit zwei Jahren in einer kleinen Wohnung an der Strase"
        let c = await correct(text)
        #expect(c?.replacement == "Straße")
    }

    @Test func theFirstWordOfAParagraphUsesTheEarlierTextLanguage() async {
        let recognizer = Recognizer()
        let c = await correct("Ich wohne seit zwei Jahren in einer kleinen Wohnung.\nStrase", recognizer: recognizer)
        #expect(c?.replacement == "Straße")
        #expect(recognizer.texts == ["", "Ich wohne seit zwei Jahren in einer kleinen Wohnung.\n"])
    }

    @Test func aBritishSetupAcceptsColourAndStillFixesTypos() async {
        let words = VariantAwareWordSpelling(
            base: Self.dictionary, installed: ["en", "en_GB", "de"], preferred: ["en-GB", "de-DE"])
        let text = "I went to the market yesterday and the weather was grand, what a lovely colour"
        #expect(await correct(text, words: words) == nil)
        #expect(await correct("I went to the market yesterday morning and then walked along teh", words: words)?.replacement == "the")
    }

    @Test func aUSOnlySetupStillFlagsColour() async {
        let words = VariantAwareWordSpelling(base: Self.dictionary, installed: ["en", "de"], preferred: ["en-US"])
        let text = "I went to the market yesterday and the weather was grand, what a lovely colour"
        #expect(await correct(text, words: words)?.replacement == "color")
    }

    private static let tenEnglishDictionaries = [
        "en", "en_CA", "en_PH", "en_GB", "en_AU", "en_IN", "en_SG", "en_ZA", "en_NZ", "en_JP", "de",
    ]

    /// `en_SG` accepts `teh` on a real Mac; only the dictionaries the user writes in may vote.
    private static let sloppySingapore = Dictionary(entries: [
        "en": ["teh": "the"], "en_GB": ["teh": "the"], "en_CA": ["teh": "the"],
    ], accepted: ["en_SG": ["teh"]])

    @Test func anUnrelatedInstalledVariantDoesNotAcceptATypo() async {
        let words = VariantAwareWordSpelling(
            base: Self.sloppySingapore, installed: Self.tenEnglishDictionaries, preferred: ["en-US", "de-DE"])
        let text = "I went to the market yesterday morning and then walked along teh"
        #expect(await correct(text, words: words)?.replacement == "the")
    }

    @Test func theSpellingSettingAddsOnlyItsOwnVariant() async {
        let words = VariantAwareWordSpelling(
            base: Self.sloppySingapore, installed: Self.tenEnglishDictionaries, preferred: ["en-US"],
            spellingVariant: { .british })
        #expect(await words.isMisspelled("teh", language: "en"))
        let gb = VariantAwareWordSpelling(
            base: Self.dictionary, installed: Self.tenEnglishDictionaries, preferred: ["en-US"],
            spellingVariant: { .british })
        #expect(await !gb.isMisspelled("colour", language: "en"))
        let us = VariantAwareWordSpelling(
            base: Self.dictionary, installed: Self.tenEnglishDictionaries, preferred: ["en-US"])
        #expect(await us.isMisspelled("colour", language: "en"))
    }

    @Test func theSpellingSettingPicksTheGuessDictionary() async {
        let dictionary = Dictionary(entries: [
            "en": ["colur": "color"], "en_GB": ["colur": "colour"], "en_CA": ["colur": "colour"],
        ], accepted: [:])
        let british = VariantAwareWordSpelling(
            base: dictionary, installed: Self.tenEnglishDictionaries, preferred: ["en-US"],
            spellingVariant: { .british })
        #expect(await british.guesses(for: "colur", language: "en") == ["colour"])
        let off = VariantAwareWordSpelling(
            base: dictionary, installed: Self.tenEnglishDictionaries, preferred: ["en-US"])
        #expect(await off.guesses(for: "colur", language: "en") == ["color"])
        let notInstalled = VariantAwareWordSpelling(
            base: dictionary, installed: ["en", "de"], preferred: ["en-US"], spellingVariant: { .british })
        #expect(await notInstalled.guesses(for: "colur", language: "en") == ["color"])
    }
}

// MARK: typo-suspected verdict

extension LanguageAwareSpellCheckerTests {
    private func verdict(_ before: String, log: LogBox = LogBox()) async -> SpellVerdict {
        let checker = LanguageAwareSpellChecker(words: Self.dictionary, identifier: Recognizer(),
                                                typoGateEnabled: { true }, log: { log.append($0) })
        return await checker.verdict(for: TypingContext(textBeforeCaret: before))
    }

    @Test func aMisspelledWordWithNoCompletionIsSuspectedAndKeepsItsFix() async {
        let v = await verdict("I went to the market yesterday morning and then walked along teh")
        #expect(v == .typoSuspected(Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)))
    }

    @Test func aMisspelledViablePrefixStaysClean() async {
        let v = await verdict("I went to the market yesterday morning and then planned Sommerferienpl")
        #expect(v == .clean(Correction(original: "Sommerferienpl", replacement: "Stars", charactersBackFromCaret: 14)))
    }

    @Test func aCorrectWordIsClean() async {
        let log = LogBox()
        let v = await verdict("Ich habe heute leider keine Zeit mehr und Hallo", log: log)
        #expect(v == .clean(nil))
        #expect(log.lines.last?.contains("verdict=clean") == true)
    }
}

extension LanguageAwareSpellCheckerTests {
    @Test func theTypoGateIsOffByDefaultSoNoVerdictIsSuspected() async {
        let checker = LanguageAwareSpellChecker(words: Self.dictionary, identifier: Recognizer())
        let v = await checker.verdict(for: TypingContext(
            textBeforeCaret: "I went to the market yesterday morning and then walked along teh"))
        #expect(v == .clean(Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)))
    }
}
