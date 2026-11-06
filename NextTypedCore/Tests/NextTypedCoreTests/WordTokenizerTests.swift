import Testing
@testable import NextTypedCore

@Suite struct WordTokenizerTests {
    @Test func peelsLeadingSpaceAndWord() {
        let (word, remainder) = WordTokenizer.peelNextWord(from: " world how")
        #expect(word == " world")
        #expect(remainder == " how")
    }

    @Test func peelsFirstWordWithNoLeadingSpace() {
        let (word, remainder) = WordTokenizer.peelNextWord(from: "hello there")
        #expect(word == "hello")
        #expect(remainder == " there")
    }

    @Test func gluesPunctuationToTheWord() {
        let (word, remainder) = WordTokenizer.peelNextWord(from: " world, how")
        #expect(word == " world,")
        #expect(remainder == " how")
    }

    @Test func acceptingEveryWordRebuildsTheText() {
        // Simulate pressing Tab repeatedly: the concatenation must equal the original.
        var remaining = " world how are you"
        var rebuilt = ""
        while !remaining.isEmpty {
            let (word, rest) = WordTokenizer.peelNextWord(from: remaining)
            rebuilt += word
            remaining = rest
        }
        #expect(rebuilt == " world how are you")
    }

    @Test func emptyYieldsEmpty() {
        let (word, remainder) = WordTokenizer.peelNextWord(from: "")
        #expect(word == "")
        #expect(remainder == "")
    }

    @Test func countsWords() {
        #expect(WordTokenizer.wordCount("how are you") == 3)
        #expect(WordTokenizer.wordCount("   ") == 0)
    }

    // MARK: Held-back trailing punctuation

    @Test func holdingBackStopsBeforeTheSentenceEnd() {
        let r = WordTokenizer.peelNextWord(from: " kalt.", holdingBackTrailingPunctuation: true)
        #expect(r.accepted == " kalt")
        #expect(r.remainder == ".")
    }

    @Test func holdingBackStopsBeforeAMidBufferComma() {
        let r = WordTokenizer.peelNextWord(from: " kalt, und dunkel", holdingBackTrailingPunctuation: true)
        #expect(r.accepted == " kalt")
        #expect(r.remainder == ", und dunkel")
    }

    @Test func holdingBackKeepsAWholeRunOfPunctuation() {
        let r = WordTokenizer.peelNextWord(from: " what?!", holdingBackTrailingPunctuation: true)
        #expect(r.accepted == " what")
        #expect(r.remainder == "?!")
    }

    @Test func aPunctuationOnlyWordIsAlwaysAccepted() {
        // The held-back remainder must be insertable by the next press.
        #expect(WordTokenizer.peelNextWord(from: ".", holdingBackTrailingPunctuation: true)
            == (accepted: ".", remainder: ""))
        let r = WordTokenizer.peelNextWord(from: ", und", holdingBackTrailingPunctuation: true)
        #expect(r.accepted == ",")
        #expect(r.remainder == " und")
    }

    @Test func holdingBackLeavesWordsWithoutTrailingPunctuationAlone() {
        let r = WordTokenizer.peelNextWord(from: " don't stop", holdingBackTrailingPunctuation: true)
        #expect(r.accepted == " don't")
        #expect(r.remainder == " stop")
    }

    @Test func notHoldingBackIsTheShippingPeel() {
        let r = WordTokenizer.peelNextWord(from: " kalt. Es")
        #expect(r.accepted == " kalt.")
        #expect(r.remainder == " Es")
    }
}
