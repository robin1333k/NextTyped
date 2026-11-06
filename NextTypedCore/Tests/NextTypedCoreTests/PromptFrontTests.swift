import Testing
@testable import NextTypedCore

/// The multi-segment prompt front, generalised out of `MLXPredictionEngine`.
@Suite struct PromptFrontTests {

    @Test func noContextLeavesThePromptEqualToThePrefix() {
        // The default (OCR off, no AX context) must be byte-identical to the no-context path.
        let result = PromptFront.build(prefix: "Sehr geehrte Frau")
        #expect(result.prompt == "Sehr geehrte Frau")
        #expect(result.ocrAmbientChars == 0)
        #expect(result.focusedDocChars == 0)
        #expect(result.replyChars == 0)
        #expect(result.personalizationChars == 0)
    }

    @Test func personalizationLeadsTheFrontAheadOfEverythingElse() {
        // front-most on two axes — least volatile (contextSwitch cadence) and lowest direct
        // pull (a voice *frame*, not next-token content). Being first also means it is the first segment
        // the token window evicts, which is aligned with need, not a bug.
        let result = PromptFront.build(
            prefix: "PREFIX",
            personalization: "VOICE",
            windowContext: "WINDOW",
            ocrAmbient: "AMBIENT",
            replyContext: "REPLY")
        #expect(result.prompt == "VOICE\n\nAMBIENT\n\nWINDOW\n\nREPLY\n\nPREFIX")
        #expect(result.personalizationChars == 5)
    }

    @Test func thePersonalizationSegmentKeepsItsOwnSmallBudget() {
        let result = PromptFront.build(
            prefix: "PREFIX",
            personalization: String(repeating: "v", count: 900),
            budgets: PromptFront.Budgets(personalization: 600))
        #expect(result.personalizationChars == 600)
    }

    @Test func aPersonalizationSegmentEchoingTheCaretTailIsDropped() {
        // Same guard as every other segment: never re-feed the text being typed. Exemplars are the user's
        // own sentences, so on a re-read of an already-written passage this can genuinely fire.
        let tail = String(repeating: "abcdefghij", count: 3)
        let result = PromptFront.build(prefix: tail, personalization: "voice " + tail)
        #expect(result.personalizationChars == 0)
        #expect(result.prompt == tail)
    }

    @Test func segmentsAreOrderedAmbientThenFocusedThenReply() {
        // Ordering is the decision: the noisiest source furthest from the prefix, the interlocutor's
        // turn nearest it.
        let result = PromptFront.build(
            prefix: "PREFIX",
            windowContext: "WINDOW",
            ocrAmbient: "AMBIENT",
            replyContext: "REPLY")
        #expect(result.prompt == "AMBIENT\n\nWINDOW\n\nREPLY\n\nPREFIX")
    }

    @Test func focusedSlotComposesAXTextWithTheDisjointPixelRemainder() {
        // The AX-PARTIAL case (Mail compose: headers via AX, body only in pixels). `ocrFocusedFill` is
        // already the value-checked *net-new* remainder, so composing cannot duplicate — and dropping
        // it would make `OCRValueCheck`'s partial arm dead code.
        let result = PromptFront.build(
            prefix: "PREFIX", windowContext: "FROM-AX", ocrFocusedFill: "NET-NEW-FROM-PIXELS")
        #expect(result.prompt == "FROM-AX\n\nNET-NEW-FROM-PIXELS\n\nPREFIX")
    }

    @Test func aRedundantFillLeavesTheSlotAsPureAX() {
        // The value-check returned `.redundant` ⇒ no fill ⇒ byte-identical to the AX-only path.
        let result = PromptFront.build(
            prefix: "PREFIX", windowContext: "FROM-AX", ocrFocusedFill: nil)
        #expect(result.prompt == "FROM-AX\n\nPREFIX")
    }

    @Test func theComposedFocusedSlotKeepsItsOwnCap() {
        // Composing must not let the slot exceed its budget — the prefix is what decides the next word.
        let result = PromptFront.build(
            prefix: "P",
            windowContext: String(repeating: "a", count: 100),
            ocrFocusedFill: String(repeating: "b", count: 100),
            budgets: PromptFront.Budgets(focusedDoc: 50))
        #expect(result.focusedDocChars == 50)
    }

    @Test func ocrFillTakesTheFocusedSlotWhenAXIsBlind() {
        let result = PromptFront.build(prefix: "PREFIX", ocrFocusedFill: "FROM-PIXELS")
        #expect(result.prompt == "FROM-PIXELS\n\nPREFIX")
        #expect(result.focusedDocChars == "FROM-PIXELS".count)
    }

    @Test func emptyAndWhitespaceSegmentsAreSkipped() {
        let result = PromptFront.build(
            prefix: "PREFIX", windowContext: "", ocrAmbient: "   \n ", replyContext: nil)
        #expect(result.prompt == "PREFIX")
    }

    // MARK: budgets

    @Test func eachSegmentIsHeadCappedIndependently() {
        let long = String(repeating: "x", count: 5000)
        let result = PromptFront.build(
            prefix: "PREFIX", windowContext: long, ocrAmbient: long, replyContext: long,
            budgets: PromptFront.Budgets(ocrAmbient: 10, focusedDoc: 20, reply: 30))
        #expect(result.ocrAmbientChars == 10)
        #expect(result.focusedDocChars == 20)
        #expect(result.replyChars == 30)
    }

    @Test func capsKeepTheHeadNotTheTail() {
        let result = PromptFront.build(
            prefix: "P", ocrAmbient: "HEAD-then-a-very-long-tail",
            budgets: PromptFront.Budgets(ocrAmbient: 4))
        #expect(result.prompt.hasPrefix("HEAD"))
    }

    // MARK: the disjointness guard

    @Test func aSegmentContainingTheNearCaretTailIsDropped() {
        // Re-feeding the text being typed craters acceptance (offline measurements) — so a segment that
        // already contains the near-caret tail is dropped whole.
        let prefix = "Der Bericht über die Latenzmessung ist fertig und liegt bei"
        let result = PromptFront.build(prefix: prefix, windowContext: "Vorher: " + prefix + " …")
        #expect(result.prompt == prefix)
        #expect(result.focusedDocChars == 0)
    }

    @Test func theGuardIsPerSegmentNotAllOrNothing() {
        // One duplicating segment must not take the innocent ones down with it.
        let prefix = "Der Bericht über die Latenzmessung ist fertig und liegt bei"
        let result = PromptFront.build(
            prefix: prefix,
            windowContext: prefix,
            ocrAmbient: "Ein völlig anderes Fenster mit Referenztext.",
            replyContext: "Claude: Schick mir die Zahlen bitte bis Freitag.")
        #expect(result.focusedDocChars == 0)
        #expect(result.ocrAmbientChars > 0)
        #expect(result.replyChars > 0)
    }

    @Test func aShortPrefixTailNeverTriggersTheGuard() {
        // A 3-char tail matches everywhere; dropping context on that coincidence would be worse than
        // the duplication it guards against.
        let result = PromptFront.build(prefix: "und", windowContext: "und so weiter und so fort")
        #expect(result.focusedDocChars > 0)
    }

    @Test func guardRunsAfterTheCapSoATrimmedSegmentStillCounts() {
        // The duplicate sits past the cap: once trimmed away, the segment is clean and admissible.
        let prefix = "eine sehr charakteristische Textstelle am Ende"
        let segment = String(repeating: "a", count: 100) + prefix
        let result = PromptFront.build(
            prefix: prefix, windowContext: segment, budgets: PromptFront.Budgets(focusedDoc: 50))
        #expect(result.focusedDocChars == 50)
    }
}

/// The **unjoined** front — `PromptFront.assemble`, the seam the engine needs to splice a real
/// document-boundary token between segments.
@Suite struct PromptFrontAssemblyTests {

    @Test func noContextYieldsAnEmptyFrontAndAnUntouchedPrefix() {
        let a = PromptFront.assemble(prefix: "Sehr geehrte Frau")
        #expect(a.frontSegments.isEmpty)
        #expect(a.prefix == "Sehr geehrte Frau")
        // Nothing to separate ⇒ the engine encodes the prefix alone, boundary token or not.
        #expect(a.prompt == "Sehr geehrte Frau")
    }

    @Test func segmentsComeOutInPromptOrderFurthestFromThePrefixFirst() {
        let a = PromptFront.assemble(
            prefix: "PREFIX",
            personalization: "VOICE",
            windowContext: "WINDOW",
            ocrAmbient: "AMBIENT",
            replyContext: "REPLY")
        #expect(a.frontSegments == ["VOICE", "AMBIENT", "WINDOW", "REPLY"])
        #expect(a.prefix == "PREFIX")
    }

    @Test func absentSegmentsLeaveNoHoleInTheList() {
        // The segment adjacent to the prefix varies with which sources are populated — which is why the
        // engine must place a boundary between *every* adjacent pair, not only before the prefix.
        let a = PromptFront.assemble(prefix: "PREFIX", personalization: "VOICE", replyContext: "REPLY")
        #expect(a.frontSegments == ["VOICE", "REPLY"])
    }

    @Test func theListIsCappedAndGuardedExactlyLikeTheJoinedForm() {
        let prefix = String(repeating: "z", count: 130)
        let a = PromptFront.assemble(
            prefix: prefix,
            personalization: String(repeating: "v", count: 900),
            windowContext: "head " + prefix,          // echoes the caret tail ⇒ dropped
            replyContext: "REPLY",
            budgets: PromptFront.Budgets(personalization: 600))
        #expect(a.frontSegments == [String(repeating: "v", count: 600), "REPLY"])
        #expect(a.personalizationChars == 600)
        #expect(a.focusedDocChars == 0)
    }

    @Test func theJoinedPromptIsByteIdenticalToBuild() {
        // The plain-text join is the fallback the engine uses when the boundary token cannot be
        // resolved, so it must stay exactly what shipped before.
        let args: (String, String?, String?, String?, String?) =
            ("PREFIX", "VOICE", "WINDOW", "AMBIENT", "REPLY")
        let a = PromptFront.assemble(
            prefix: args.0, personalization: args.1, windowContext: args.2,
            ocrAmbient: args.3, replyContext: args.4)
        let r = PromptFront.build(
            prefix: args.0, personalization: args.1, windowContext: args.2,
            ocrAmbient: args.3, replyContext: args.4)
        #expect(a.prompt == r.prompt)
        #expect(a.result == r)
    }

    @Test func theFocusedDocSlotStaysOneSegmentAcrossItsTwoSources() {
        // AX text + the disjoint pixel remainder are two readings of the SAME document, so they must not
        // be separated by a document boundary — they arrive as a single segment.
        let a = PromptFront.assemble(
            prefix: "PREFIX", windowContext: "AXTEXT", ocrFocusedFill: "PIXELS")
        #expect(a.frontSegments == ["AXTEXT\n\nPIXELS"])
    }
}

@Suite struct OCRContextTests {
    @Test func emptyWhenNeitherRoleHasText() {
        #expect(OCRContext().isEmpty == true)
        #expect(OCRContext(ambient: "", focusedFill: "").isEmpty == true)
        #expect(OCRContext(ambient: "something").isEmpty == false)
        #expect(OCRContext(focusedFill: "something").isEmpty == false)
    }

    @Test func typingContextDefaultsToNoOCR() {
        // OCR is opt-in: a context built the old way carries none, so nothing changes by default.
        #expect(TypingContext(textBeforeCaret: "abc").ocrContext == nil)
    }
}

/// Clipboard context segment: directly before `focusedDoc`, absent means byte-identical.
@Suite("PromptFront clipboard segment")
struct PromptFrontClipboardTests {
    @Test func clipboardSitsDirectlyBeforeTheFocusedDoc() {
        let a = PromptFront.assemble(
            prefix: "PREFIX",
            personalization: "VOICE",
            windowContext: "WINDOW",
            ocrAmbient: "AMBIENT",
            replyContext: "REPLY",
            clipboardContext: "CLIP")
        #expect(a.frontSegments == ["VOICE", "AMBIENT", "CLIP", "WINDOW", "REPLY"])
        #expect(a.segments.map(\.kind) == [.personalization, .ocrAmbient, .clipboard, .focusedDoc, .reply])
        #expect(a.clipboardChars == 4)
    }

    @Test func aNilClipboardLeavesTheFrontExactlyAsBefore() {
        let without = PromptFront.assemble(
            prefix: "PREFIX", personalization: "VOICE", windowContext: "WINDOW",
            ocrAmbient: "AMBIENT", replyContext: "REPLY")
        let explicitNil = PromptFront.assemble(
            prefix: "PREFIX", personalization: "VOICE", windowContext: "WINDOW",
            ocrAmbient: "AMBIENT", replyContext: "REPLY", clipboardContext: nil)
        #expect(without == explicitNil)
        #expect(without.prompt == "VOICE\n\nAMBIENT\n\nWINDOW\n\nREPLY\n\nPREFIX")
        #expect(without.clipboardChars == 0)
    }

    @Test func theClipboardSegmentIsHeadCappedAtItsOwnBudget() {
        let a = PromptFront.assemble(
            prefix: "PREFIX", clipboardContext: String(repeating: "c", count: 900),
            budgets: PromptFront.Budgets(clipboard: 600))
        #expect(a.frontSegments == [String(repeating: "c", count: 600)])
    }
}
