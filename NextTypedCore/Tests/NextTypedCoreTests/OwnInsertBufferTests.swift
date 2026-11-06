import Testing
@testable import NextTypedCore

/// The own-inserted capture buffer — the trust-critical piece. Everything the profile ever
/// learns comes through here, so the tests are as much about what it CANNOT hold as what it does.
@Suite struct OwnInsertBufferTests {

    @Test func accumulatesTypedCharactersAndAcceptedGhosts() {
        var buffer = OwnInsertBuffer()
        buffer.insert("H")
        buffer.insert("i")
        buffer.insert(" there")          // an accepted ghost arrives as one insert
        #expect(buffer.text == "Hi there")
    }

    @Test func popsOnBackspace() {
        var buffer = OwnInsertBuffer()
        buffer.insert("Halo")
        buffer.delete(.backward)
        buffer.insert("lo")
        #expect(buffer.text == "Hallo")
    }

    @Test func backspaceOnAnEmptyBufferIsHarmless() {
        var buffer = OwnInsertBuffer()
        buffer.delete(.backward)
        #expect(buffer.text.isEmpty)
    }

    @Test func optionBackspacePopsTheWholeTrailingWord() {
        var buffer = OwnInsertBuffer()
        buffer.insert("Der Buld ")
        buffer.delete(.backwardWord)
        buffer.insert("Build läuft")
        #expect(buffer.text == "Der Build läuft")
    }

    @Test func forwardDeleteLeavesTheBufferAloneBecauseItRemovesTextRightOfTheCaret() {
        // The flat-buffer v1 tracks own *insertions*, not offsets: fn-Delete removes text after the
        // caret, which is not the tail we accumulated. Popping there would corrupt a correct buffer.
        var buffer = OwnInsertBuffer()
        buffer.insert("Hallo")
        buffer.delete(.forward)
        #expect(buffer.text == "Hallo")
    }

    @Test func takeAllCommitsAndClears() {
        var buffer = OwnInsertBuffer()
        buffer.insert("Ein Satz.")
        #expect(buffer.takeAll() == "Ein Satz.")
        #expect(buffer.text.isEmpty)
        #expect(buffer.takeAll() == nil)
    }

    @Test func clearDiscardsWithoutCommitting() {
        // The fail-closed path: an ineligible surface (secure field, learning-denylisted app) discards.
        var buffer = OwnInsertBuffer()
        buffer.insert("geheim")
        buffer.clear()
        #expect(buffer.takeAll() == nil)
    }

    @Test func capsGrowthByKeepingTheMostRecentText() {
        var buffer = OwnInsertBuffer()
        for _ in 0..<(OwnInsertBuffer.maxChars + 100) { buffer.insert("x") }
        buffer.insert("Ende")
        #expect(buffer.text.count == OwnInsertBuffer.maxChars)
        #expect(buffer.text.hasSuffix("Ende"))
    }
}

/// The keyDown → deletion routing that feeds the buffer's pop (pure, so the App layer keeps only the
/// `CGEvent` reads).
@Suite struct KeyDeletionClassifierTests {
    @Test func backspaceAndForwardDeleteAreDistinguished() {
        #expect(KeyClassifier.deletion(keyCode: 51, option: false) == .backward)
        #expect(KeyClassifier.deletion(keyCode: 117, option: false) == .forward)
    }

    @Test func optionBackspaceIsAWordDelete() {
        #expect(KeyClassifier.deletion(keyCode: 51, option: true) == .backwardWord)
    }

    @Test func commandZIsUndoneOnAnyLayout() {
        #expect(KeyClassifier.deletion(keyCode: 16, option: false, command: true, characters: "z") == .undone)
        #expect(KeyClassifier.deletion(keyCode: 6, option: false, command: true, characters: "Z") == .undone)
    }

    @Test func zWithoutCommandIsNotUndone() {
        #expect(KeyClassifier.deletion(keyCode: 16, option: false, characters: "z") == nil)
    }

    @Test func navigationKeysAreNotDeletions() {
        for keyCode in [123, 124, 125, 126, 36, 48] {
            #expect(KeyClassifier.deletion(keyCode: keyCode, option: false) == nil)
        }
    }

    @Test func bothReturnKeysReportALineBreak() {
        // Return types no character, so without this the capture buffer would concatenate two lines into
        // one run — fabricating a term across the join and losing the only boundary an unpunctuated line
        // (a bullet, a chat line) has.
        #expect(KeyClassifier.insertsLineBreak(keyCode: 36))
        #expect(KeyClassifier.insertsLineBreak(keyCode: 76))
    }

    @Test func otherCaretMovesAreNotLineBreaks() {
        for keyCode in [123, 124, 125, 126, 115, 119, 51, 117, 48] {
            #expect(!KeyClassifier.insertsLineBreak(keyCode: keyCode))
        }
    }

    @Test func aRecordedLineBreakSeparatesTwoLinesIntoTwoExemplars() {
        // The end-to-end shape of the fix, at the seam the App wires: typed line, Return, typed line.
        var buffer = OwnInsertBuffer()
        buffer.insert("Das war gut")
        buffer.insert("\n")          // what the App appends on a Return keyDown
        buffer.insert("Heute ist Montag")
        let clauses = StyleProfile.segment(buffer.text + "\n")
        #expect(clauses == ["Das war gut", "Heute ist Montag"])
    }

    @Test func undoEndsTheRunBecauseTheRemovedTextIsUnknown() {
        var b = OwnInsertBuffer()
        b.insert("Guten Morgen zusammen")
        b.delete(.undone)
        #expect(b.isEmpty)
        #expect(b.takeAll() == nil)
    }
}
