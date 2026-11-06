import Testing
@testable import NextTypedCore

@Suite struct FIMAcceptTests {
    // MARK: The `middle|S` join (build item 9)
    //
    // NOTE — the ticket words this as "suppress the trailing space". That wording describes
    // the *stated* form; the **realized** form in this codebase is leading-space-preserving
    // (`WordTokenizer.peelNextWord` keeps the gap in front of the word and nothing ever appends a
    // trailing one — see `interiorAcceptCarriesItsOwnLeadingSpace`). So at a FIM site the hazard is the
    // mirror image: the terminal accept lands flush against `S` and needs a separator ADDED. This suite
    // pins both directions — add where a word would fuse, suppress where `S` already brings its own gap
    // or opens with attaching punctuation.

    @Test func addsASeparatorWhenTheLastWordWouldFuseWithTheSuffix() {
        // "Der Hund |über den Zaun." + middle "springt schnell": without this, the terminal accept
        // reads "…schnellüber den Zaun."
        #expect(FIMAccept.terminalJoin(accepted: " schnell", suffix: "über den Zaun.") == " ")
    }

    @Test func suppressesWhenTheSuffixAlreadyBringsItsOwnGap() {
        // S = " over the lazy dog." — adding one would double it.
        #expect(FIMAccept.terminalJoin(accepted: " jumps", suffix: " over the lazy dog.") == "")
        #expect(FIMAccept.terminalJoin(accepted: " jumps", suffix: "\tindented") == "")
    }

    @Test func suppressesBeforeAttachingPunctuation() {
        // A stray space before terminal/closing punctuation is the stray-space typo class, right side.
        for suffix in [",", ".", "!", "?", ";", ":", ")", "]", "}", "»", "…", "”"] {
            #expect(FIMAccept.terminalJoin(accepted: " schnell", suffix: suffix) == "",
                    "expected no separator before \(suffix)")
        }
    }

    @Test func theAmbiguousQuoteMarksSplitOnWhichMisreadIsWorse() {
        // `'` at a word boundary is far more often an apostrophe than an opening quote — "schnell 's"
        // is the worse error, so it attaches.
        #expect(FIMAccept.terminalJoin(accepted: " it", suffix: "'s Buch") == "")
        // `"` is never an apostrophe, so it reads as an opening quote and wants the gap.
        #expect(FIMAccept.terminalJoin(accepted: " sagte", suffix: "\"Hallo\"") == " ")
    }

    @Test func addsASeparatorBeforeAnOpeningBracket() {
        // Openers are not attaching punctuation — "schnell (sehr)" wants the gap.
        #expect(FIMAccept.terminalJoin(accepted: " schnell", suffix: "(sehr schnell)") == " ")
        #expect(FIMAccept.terminalJoin(accepted: " schnell", suffix: "«zitiert»") == " ")
    }

    @Test func suppressesWhenTheAcceptedTextAlreadyEndsWithWhitespace() {
        #expect(FIMAccept.terminalJoin(accepted: " schnell ", suffix: "über den Zaun.") == "")
    }

    @Test func suppressesAtTheEndOfTheField() {
        // No `S` at all: the terminal accept is an ordinary forward accept.
        #expect(FIMAccept.terminalJoin(accepted: " schnell", suffix: "") == "")
    }

    @Test func suppressesForAnEmptyAcceptedRun() {
        #expect(FIMAccept.terminalJoin(accepted: "", suffix: "über den Zaun.") == "")
    }

    @Test func addsASeparatorAfterTerminalPunctuationInTheMiddle() {
        // The middle may close a clause ("…schnell.") while S opens a new word — still a word gap.
        #expect(FIMAccept.terminalJoin(accepted: " schnell.", suffix: "Danach kam") == " ")
    }

    // MARK: The interior accept is untouched (the "helloworld" regression guard)

    @Test func interiorAcceptCarriesItsOwnLeadingSpace() {
        // Item 9's "interior accepts keep the trailing space unconditionally" is already structural
        // here: the remainder retains the gap, so the NEXT peel re-inserts it. `terminalJoin` is
        // therefore only ever consulted on the accept that empties the buffer.
        let (first, remainder) = WordTokenizer.peelNextWord(from: " springt schnell")
        #expect(first == " springt")
        #expect(remainder == " schnell")
        let (second, rest) = WordTokenizer.peelNextWord(from: remainder)
        #expect(second == " schnell")
        #expect(rest.isEmpty)
        // Reassembled the bridge is intact — no fused "springtschnell".
        #expect(first + second == " springt schnell")
    }

    // MARK: The call-site decision (`insertionText`) — terminal? bridge? which separator?

    @Test func insertionJoinsOnlyTheTerminalBridgeAccept() {
        // Terminal accept of a bridge whose S starts with a word → the separator is added.
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "über den Zaun.",
            fimEnabled: true
        ) == " schnell ")
    }

    @Test func insertionLeavesAnInteriorAcceptUntouched() {
        // Words remain in the buffer → the next peel carries the gap; nothing to join yet.
        #expect(FIMAccept.insertionText(
            accepted: " springt",
            exhausted: false,
            textAfterCaret: "über den Zaun.",
            fimEnabled: true
        ) == " springt")
    }

    @Test func insertionIsAByteIdenticalNoOpWhileFIMIsOff() {
        // The shipping default. Even at a textbook FIM site with a terminal accept, the forward path
        // must insert exactly what it peeled.
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "über den Zaun.",
            fimEnabled: false
        ) == " schnell")
    }

    @Test func insertionDoesNotJoinAtAForwardCaret() {
        // fimEnabled but no text right of the caret (or whitespace only) → not a FIM site, so the
        // terminal accept is an ordinary forward accept and gets nothing appended.
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "",
            fimEnabled: true
        ) == " schnell")
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "   ",
            fimEnabled: true
        ) == " schnell")
    }

    @Test func insertionRoutesOnTheParagraphNotTheWholeRemainder() {
        // Text only on a LATER line is not a bridge target (`FIMSite`), so no join — and conversely the
        // suffix consulted is the paragraph slice, so the separator is decided against `über`, not `\n`.
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "\nüber den Zaun.",
            fimEnabled: true
        ) == " schnell")
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: "über den Zaun.\nNächster Absatz",
            fimEnabled: true
        ) == " schnell ")
    }

    @Test func insertionSuppressesTheSeparatorWhereSBringsItsOwn() {
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: " über den Zaun.",
            fimEnabled: true
        ) == " schnell")
        #expect(FIMAccept.insertionText(
            accepted: " schnell",
            exhausted: true,
            textAfterCaret: ", aber sicher.",
            fimEnabled: true
        ) == " schnell")
    }
}
