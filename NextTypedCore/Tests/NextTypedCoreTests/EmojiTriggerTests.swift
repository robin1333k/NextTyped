import Testing
@testable import NextTypedCore

@Suite struct EmojiTriggerTests {
    @Test func aGermanColonAttachedToTheWordDoesNotFire() {
        #expect(EmojiTrigger.fragment(in: "Fazit: ") == nil)
        #expect(EmojiTrigger.fragment(in: "Fazit:") == nil)
    }

    @Test func aTimeDoesNotFire() {
        #expect(EmojiTrigger.fragment(in: "Um 10:30") == nil)
    }

    @Test func aUrlSchemeDoesNotFire() {
        #expect(EmojiTrigger.fragment(in: "see https://") == nil)
        #expect(EmojiTrigger.fragment(in: "see https://example") == nil)
    }

    @Test func oneLetterDoesNotFire() {
        #expect(EmojiTrigger.fragment(in: ":s") == nil)
    }

    @Test func twoLettersFire() {
        #expect(EmojiTrigger.fragment(in: ":sm") == "sm")
    }

    @Test func threeLettersFire() {
        #expect(EmojiTrigger.fragment(in: ":smi") == "smi")
    }

    @Test func afterWhitespaceAndNewlineItFires() {
        #expect(EmojiTrigger.fragment(in: "Hallo :daumen") == "daumen")
        #expect(EmojiTrigger.fragment(in: "Hallo\n:daumen") == "daumen")
    }

    @Test func germanUmlautsCountAsLetters() {
        #expect(EmojiTrigger.fragment(in: ":lächeln") == "lächeln")
    }

    @Test func digitsOrSecondColonEndTheTrigger() {
        #expect(EmojiTrigger.fragment(in: ":smi2") == nil)
        #expect(EmojiTrigger.fragment(in: ":smile:") == nil)
        #expect(EmojiTrigger.fragment(in: "a::smi") == nil)
    }
}

@Suite struct EmojiLexiconTests {
    @Test func bundledLexiconFindsThumbsUpFromTheGermanName() {
        #expect(EmojiLexicon.bundled.bestMatch(for: "daumen") == "👍")
    }

    @Test func bundledLexiconFindsThumbsUpFromTheEnglishName() {
        #expect(EmojiLexicon.bundled.bestMatch(for: "thumbs") == "👍")
    }

    @Test func bundledLexiconFindsSmilingFaceFromAShortFragment() {
        #expect(EmojiLexicon.bundled.bestMatch(for: "smi") == "\u{263A}\u{FE0F}")
    }

    @Test func herzGivesTheRedHeartInEmojiPresentation() {
        #expect(EmojiLexicon.bundled.bestMatch(for: "herz") == "\u{2764}\u{FE0F}")
    }

    @Test func punctuationAndMathNamesMatchNoEmoji() {
        for word in ["punkt", "komma", "dollar", "set", "end"] {
            let match = EmojiLexicon.bundled.bestMatch(for: word)
            #expect(match.map { $0.unicodeScalars.count > 1 || $0.unicodeScalars.first!.value > 0x2190 } ?? true,
                    "\(word) matched a plain symbol: \(match ?? "")")
        }
        // "Punkt" still names real emoji (red circle), but never the full stop.
        #expect(EmojiLexicon.bundled.bestMatch(for: "punkt") == "\u{1F534}")
        #expect(EmojiLexicon.bundled.bestMatch(for: "komma") == nil)
        #expect(EmojiLexicon.bundled.bestMatch(for: "dollar") != "$")
    }

    @Test func bundledLexiconDoesNotOfferSkinToneVariants() {
        let match = EmojiLexicon.bundled.bestMatch(for: "daumen")
        #expect(match?.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } == false)
    }

    @Test func nonsenseMatchesNothing() {
        #expect(EmojiLexicon.bundled.bestMatch(for: "qqxzv") == nil)
    }

    @Test func aNameWordPrefixOutranksAKeywordPrefix() {
        let lexicon = EmojiLexicon(rows: [
            "A\tfoo\tcat|bar\t\t",
            "B\tcat face\t\t\t",
        ])
        #expect(lexicon.bestMatch(for: "cat") == "B")
    }

    @Test func matchingIgnoresCase() {
        let lexicon = EmojiLexicon(rows: ["X\t\t\tDaumen hoch\t"])
        #expect(lexicon.bestMatch(for: "daum") == "X")
    }
}
