import Testing
@testable import NextTypedCore

@Suite struct FIMSiteTests {
    // MARK: The paragraph slice

    @Test func suffixIsTheRemainderUpToTheFirstNewline() {
        #expect(FIMSite.paragraphSuffix(afterCaret: " over the lazy dog.\nNext paragraph.")
                == " over the lazy dog.")
    }

    @Test func aNewlineFreeFieldIsOneParagraph() {
        // A soft-wrapped compose box (Claude Desktop) exposes no newline: the whole remainder is the
        // one paragraph, so the suffix is everything right of the caret.
        #expect(FIMSite.paragraphSuffix(afterCaret: " over the lazy dog.") == " over the lazy dog.")
    }

    @Test func crlfCountsAsTheParagraphBreak() {
        // `Character.isNewline` treats CRLF as ONE grapheme — a bare "\n" scan would leak the "\r".
        #expect(FIMSite.paragraphSuffix(afterCaret: "tail\r\nnext") == "tail")
    }

    @Test func aCaretAtParagraphEndHasAnEmptySuffix() {
        #expect(FIMSite.paragraphSuffix(afterCaret: "\nNext paragraph.") == "")
        #expect(FIMSite.paragraphSuffix(afterCaret: "") == "")
    }

    // MARK: The FIM-site predicate

    @Test func nonWhitespaceContentInTheParagraphIsAFIMSite() {
        #expect(FIMSite.isFIMSite(textAfterCaret: " over the lazy dog."))
        #expect(FIMSite.isFIMSite(textAfterCaret: "x"))
    }

    @Test func anEmptyOrWhitespaceOnlyRightSideIsNotAFIMSite() {
        // "empty/whitespace-only right side → base-2B forward."
        #expect(!FIMSite.isFIMSite(textAfterCaret: ""))
        #expect(!FIMSite.isFIMSite(textAfterCaret: "   "))
        #expect(!FIMSite.isFIMSite(textAfterCaret: "  \t "))
    }

    @Test func textOnLATERLinesIsNotAFIMSite() {
        // The predicate is paragraph-scoped: caret at the end of THIS paragraph is forward
        // continuation even though the document has more text below.
        #expect(!FIMSite.isFIMSite(textAfterCaret: "\n\nA whole further paragraph."))
        #expect(!FIMSite.isFIMSite(textAfterCaret: "   \nA whole further paragraph."))
    }

    // MARK: The caret-position model router

    @Test func routesToFIMOnlyWhenEnabledAndAtAFIMSite() {
        #expect(FIMSite.route(textAfterCaret: " over the lazy dog.", fimEnabled: true)
                == .fim(suffix: " over the lazy dog."))
    }

    @Test func theMasterGateOffAlwaysRoutesForward() {
        // The default-off guarantee: with `fimEnabled` false the router is byte-identical to today —
        // the 1.7B is never selected, so it is never loaded.
        #expect(FIMSite.route(textAfterCaret: " over the lazy dog.", fimEnabled: false) == .forward)
    }

    @Test func paragraphEndRoutesForwardEvenWithFIMEnabled() {
        #expect(FIMSite.route(textAfterCaret: "", fimEnabled: true) == .forward)
        #expect(FIMSite.route(textAfterCaret: "\nNext paragraph.", fimEnabled: true) == .forward)
    }

    @Test func midWordIsAFIMSite() {
        // FIM activation explicitly allows mid-word: "Der Hu|nd" bridges into "nd".
        #expect(FIMSite.route(textAfterCaret: "nd sprang", fimEnabled: true) == .fim(suffix: "nd sprang"))
    }

    @Test func routeReadsTheSameSliceTheSuffixHelperReturns() {
        // The suffix handed to the prompt builder IS the paragraph slice — one definition, so the
        // predicate and the prompt can never disagree about where S ends.
        let after = "bridge me\nand not me"
        guard case .fim(let suffix) = FIMSite.route(textAfterCaret: after, fimEnabled: true) else {
            Issue.record("expected a FIM route"); return
        }
        #expect(suffix == FIMSite.paragraphSuffix(afterCaret: after))
    }
}
