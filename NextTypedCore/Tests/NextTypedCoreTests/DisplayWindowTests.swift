import Testing
@testable import NextTypedCore

/// `DisplayWindow` is the *sliding display window* over the full continuation buffer:
/// the engine now returns the whole decoded clause as the buffer and only the first
/// few words are painted, so `Tab` reveals already-decoded words with no re-inference.
@Suite struct DisplayWindowTests {
    @Test func fewerWordsThanTheCapReturnsTheWholeBuffer() {
        #expect(DisplayWindow.windowed(" world", maxWords: 5) == " world")
        #expect(DisplayWindow.windowed(" how are you", maxWords: 5) == " how are you")
    }

    @Test func moreWordsThanTheCapKeepsOnlyTheFirstN() {
        // Six words, cap 5 → the sixth ("there") stays buffered, not shown.
        #expect(DisplayWindow.windowed(" world how are you today there", maxWords: 5)
            == " world how are you today")
    }

    @Test func preservesASignificantLeadingSpace() {
        // The ghost is drawn one space after a flush caret — the leading space must survive.
        #expect(DisplayWindow.windowed(" a b c", maxWords: 2) == " a b")
        #expect(DisplayWindow.windowed("a b c", maxWords: 2) == "a b")
    }

    @Test func neverEmitsATrailingSpace() {
        // Cutting at the Nth word must not leave a dangling gap that renders a phantom space.
        let windowed = DisplayWindow.windowed(" one two three four", maxWords: 2)
        #expect(windowed == " one two")
        #expect(windowed.last == "o")
    }

    @Test func theWindowIsAlwaysAPrefixOfTheBuffer() {
        // Invariant: what's shown must equal the first characters Tab will insert.
        for buffer in [" world how are you today there", "hello there friend a b c", " x"] {
            #expect(buffer.hasPrefix(DisplayWindow.windowed(buffer, maxWords: 5)))
        }
    }

    @Test func punctuationGluedToAWordCountsWithThatWord() {
        #expect(DisplayWindow.windowed(" world, how are you, friend", maxWords: 3)
            == " world, how are")
    }

    @Test func defaultCapIsFiveWords() {
        #expect(DisplayWindow.defaultMaxWords == 5)
        #expect(DisplayWindow.windowed(" a b c d e f g") == " a b c d e")
    }

    @Test func emptyAndWhitespaceOnlyYieldEmpty() {
        #expect(DisplayWindow.windowed("", maxWords: 5) == "")
        #expect(DisplayWindow.windowed("   ", maxWords: 5) == "")
        #expect(DisplayWindow.windowed(" world", maxWords: 0) == "")
    }

    @Test func slidingForwardRevealsTheNextBufferedWord() {
        // Model the Tab peel: the window over the remaining buffer surfaces the once-hidden word.
        let buffer = " one two three four five six"   // 6 words, only 5 shown
        #expect(DisplayWindow.windowed(buffer) == " one two three four five")
        let (_, remainder) = WordTokenizer.peelNextWord(from: buffer)   // peel "one"
        #expect(DisplayWindow.windowed(remainder) == " two three four five six")  // "six" now visible
    }
}
