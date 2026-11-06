import Testing
@testable import NextTypedCore

/// The OCR↔AX value-check — the gate that keeps the focused-doc prompt slot
/// filled by `windowContext` XOR the OCR fill, never both.
@Suite struct OCRValueCheckTests {

    @Test func axBlindSurfaceGetsTheWholeOCRRead() {
        // Case (A), OCR's reason to exist: Mail's WebKit compose body exposes nothing to AX.
        let ocr = """
        Dear Robin,
        Thanks for the detailed write-up on the caret geometry work.
        Could you send the benchmark numbers before Friday?
        """
        #expect(OCRValueCheck.verdict(ocrText: ocr, axText: nil) == .fill(ocr))
    }

    @Test func emptyAXTextCountsAsBlind() {
        let ocr = "A paragraph of genuinely new prose that AX never surfaced at all."
        #expect(OCRValueCheck.verdict(ocrText: ocr, axText: "   \n  ") == .fill(ocr))
    }

    @Test func fullyRedundantOCRIsSuppressed() {
        // AX already sees this window — injecting the pixels too would double-feed the focused
        // window's own text (the acceptance drop offline measurements showed).
        let text = """
        The quick brown fox jumps over the lazy dog.
        A second line of the very same document.
        And a third line for good measure here.
        """
        #expect(OCRValueCheck.verdict(ocrText: text, axText: text) == .redundant)
    }

    @Test func redundancySurvivesOCRTranscriptionNoise() {
        // OCR re-cases and re-punctuates; a substring compare would call this disjoint and inject a
        // duplicate. Line-wise normalised matching is what makes the guard actually bite.
        let ax = """
        The quick brown fox jumps over the lazy dog.
        A second line of the very same document.
        And a third line for good measure here.
        """
        let ocr = """
        The quick brown fox jumps over the lazy dog
        A  second line of the very same document.
        And a third line for good measure here!
        """
        #expect(OCRValueCheck.verdict(ocrText: ocr, axText: ax) == .redundant)
    }

    @Test func partialAXCoverageInjectsOnlyTheNetNewRemainder() {
        let ax = "Shared heading line one.\nShared heading line two."
        let ocr = """
        Shared heading line one.
        Shared heading line two.
        A genuinely new paragraph that AX never exposed to us at all.
        Another new sentence carrying real content for the prompt.
        Yet one more line of fresh material here.
        """
        guard case .fill(let filled) = OCRValueCheck.verdict(ocrText: ocr, axText: ax) else {
            Issue.record("expected a net-new fill")
            return
        }
        #expect(filled.contains("A genuinely new paragraph"))
        #expect(!filled.contains("Shared heading line one"))
    }

    @Test func tinyRemainderIsNotWorthAPromptSlot() {
        // One misread word past an otherwise-covered window is noise, not content.
        let ax = "Line one of the document.\nLine two of the document."
        let ocr = "Line one of the document.\nLine two of the document.\nOK"
        #expect(OCRValueCheck.verdict(ocrText: ocr, axText: ax) == .redundant)
    }

    @Test func emptyOCRTextYieldsNothing() {
        #expect(OCRValueCheck.verdict(ocrText: "", axText: nil) == .redundant)
        #expect(OCRValueCheck.verdict(ocrText: "  \n \n ", axText: "anything") == .redundant)
    }
}

/// The OCR-time pattern scrub — defence-in-depth for the browser-credential
/// residual the structural guards cannot reach.
@Suite struct SensitiveTextScrubTests {

    @Test func dropsLuhnValidCardNumbers() {
        let scrubbed = SensitiveTextScrub.scrub("Pay with 4111111111111111 today")
        #expect(!scrubbed.contains("4111111111111111"))
        #expect(scrubbed.contains("Pay with"))
        #expect(scrubbed.contains("today"))
    }

    @Test func dropsHyphenatedCardNumbers() {
        let scrubbed = SensitiveTextScrub.scrub("Card: 4111-1111-1111-1111.")
        #expect(!scrubbed.contains("4111"))
    }

    @Test func keepsALongNonLuhnNumberThatIsNotCardShaped() {
        // A 13–19 digit run that fails Luhn is an order/reference number… but it is still a long
        // digit run, so the long-run rule redacts it anyway. Documented here so the interaction is
        // intentional rather than surprising.
        let scrubbed = SensitiveTextScrub.scrub("Order 1234567890123 shipped")
        #expect(!scrubbed.contains("1234567890123"))
        #expect(scrubbed.contains("Order"))
    }

    @Test func dropsIBANs() {
        let scrubbed = SensitiveTextScrub.scrub("Überweisung an DE89370400440532013000 bitte")
        #expect(!scrubbed.contains("DE89370400440532013000"))
        #expect(scrubbed.contains("Überweisung"))
    }

    @Test func dropsLongDigitRuns() {
        let scrubbed = SensitiveTextScrub.scrub("Konto 123456789012 gesperrt")
        #expect(!scrubbed.contains("123456789012"))
    }

    @Test func dropsSixDigitCodesOnLinesThatMentionACode() {
        #expect(!SensitiveTextScrub.scrub("Your verification code is 483920").contains("483920"))
        #expect(!SensitiveTextScrub.scrub("OTP: 483920").contains("483920"))
        #expect(!SensitiveTextScrub.scrub("Ihre TAN lautet 483920").contains("483920"))
        #expect(!SensitiveTextScrub.scrub("2FA 483920 expires soon").contains("483920"))
    }

    @Test func keepsShortNumbersOnOrdinaryLines() {
        // The code rule is scoped to lines that name a code — ordinary prose keeps its numbers, or
        // the scrub would quietly shred normal writing context.
        let text = "We shipped 2024 units in Q3 and 1500 in Q4."
        #expect(SensitiveTextScrub.scrub(text) == text)
    }

    @Test func leavesOrdinaryProseUntouched() {
        let text = "Dear Robin,\nThe review is done — ADR-0041 is finalised.\nBest, Claude"
        #expect(SensitiveTextScrub.scrub(text) == text)
    }

    @Test func preservesLineStructure() {
        let scrubbed = SensitiveTextScrub.scrub("first line\n4111111111111111\nthird line")
        #expect(scrubbed.split(separator: "\n", omittingEmptySubsequences: false).count == 3)
        #expect(scrubbed.hasPrefix("first line"))
        #expect(scrubbed.hasSuffix("third line"))
    }

    // MARK: the primitives

    @Test func luhnAcceptsKnownGoodAndRejectsKnownBad() {
        #expect(SensitiveTextScrub.isLuhnValid("4111111111111111") == true)
        #expect(SensitiveTextScrub.isLuhnValid("5500005555555559") == true)
        #expect(SensitiveTextScrub.isLuhnValid("4111111111111112") == false)
    }

    @Test func ibanShapeRecognition() {
        #expect(SensitiveTextScrub.isIBAN("DE89370400440532013000") == true)
        #expect(SensitiveTextScrub.isIBAN("GB29NWBK60161331926819") == true)
        #expect(SensitiveTextScrub.isIBAN("Autocompletion") == false)   // letters only, no check digits
        #expect(SensitiveTextScrub.isIBAN("DE89") == false)             // too short
    }
}
