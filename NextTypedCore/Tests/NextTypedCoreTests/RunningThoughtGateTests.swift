import Testing
@testable import NextTypedCore

/// The hard bar on class C — two asymmetric arms, one reading the caret, one the ghost.
@Suite struct RunningThoughtGateTests {

    // MARK: Arm 1 — "no running thought" (input side)

    @Test func twoWordsInTheSentenceIsARunningThought() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die Untersuchung") == true)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die Untersuchung wurde im Mai") == true)
    }

    @Test func fewerThanTwoWordsIsNotOne() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "") == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die") == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die ") == false)
    }

    /// The defect's own spot: the paragraph is not empty, the sentence is.
    @Test func aJustTypedHeadingLeavesNoRunningThought() {
        let afterHeading = "Die Auswertung ergab folgendes.\n\nTest 4 (Lena):\n"
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: afterHeading) == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: afterHeading + "Lena fand") == true)
    }

    /// The sentence still starts at the NEARER of the last boundary and the last newline — that is
    /// what `wordCount(inSentenceEnding:)` measures, and it is unchanged. What the amendment adds is
    /// that the *origin* of that nearer mark decides whether the arm engages at all.
    @Test func theSentenceStartsAtTheNearerOfBoundaryAndNewline() {
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "Alles war gut. Danach ging es weiter\nSie") == 1)
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "Alles\nwar gut und ausführlich. Sie") == 1)
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "Alles war gut. Danach ging\nSie war") == 2)
    }

    // MARK: Arm 1 — narrowed to structural-break starts

    /// A sentence start reached by a typed `.`/`!`/`?` is NOT a break in the running thought: the
    /// thought is one sentence back, and decoding through clause boundaries exists precisely so the ghost
    /// survives every full
    /// stop — the position where a large share of real typing happens. Un-narrowed, arm 1 reversed
    /// that decision silently.
    @Test func aFreshSentenceAfterAFullStopKeepsTheRunningThought() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Das war alles.") == true)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Das war alles. ") == true)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Das war alles. Bis") == true)
        // The three scenarios this amendment un-breaks, in their own words.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Der Hund läuft über den Zaun.") == true)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Wir gingen nach Hause und mehr zu war.") == true)
        // `!` and `?` are boundaries on the same footing as `.`.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "War das alles? ") == true)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Das war alles! ") == true)
    }

    /// The origin of the NEARER mark is what decides — not whichever mark exists somewhere behind.
    @Test func theOriginOfTheNearerMarkDecides() {
        // Newline is nearer: a structural break, so the arm engages on the 1-word sentence.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Alles war gut. Danach ging es weiter\nSie") == false)
        // Boundary is nearer: the newline is behind it, and the sentence it ended is the thought.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Alles\nwar gut und ausführlich. Sie") == true)
    }

    /// A rule about the START, not about what precedes it: the arm does not ask how substantial the
    /// previous sentence was. A one-word sentence still ends in a boundary, so the ghost continues.
    @Test func aBoundaryStartIsAllowedRegardlessOfThePrecedingSentence() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Ok. ") == true)
    }

    /// The document start is a structural break like any other — the purest "nothing to continue"
    /// case, since nothing whatsoever precedes the caret.
    @Test func theDocumentStartIsAStructuralBreak() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "") == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die") == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "   ") == false)
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die Untersuchung") == true)
    }

    @Test func theSentenceStartOriginIsReadable() {
        #expect(RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: "") == .documentStart)
        #expect(RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: "Die Untersuchung") == .documentStart)
        #expect(RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: "Das war alles. ") == .sentenceBoundary)
        #expect(RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: "Test 4 (Lena):\n") == .structuralBreak)
        // The decimal guard applies here too: "3.500" opens nothing.
        #expect(RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: "Wir zahlten 3.500") == .documentStart)
    }

    /// A paragraph-scoped rule would read the heading spot as populated; a sentence-scoped one does
    /// not. The heading itself is three words — but it is on the line ABOVE, so the sentence the
    /// caret sits in holds only what follows the break.
    @Test func theUnitIsTheSentenceNotTheParagraph() {
        let paragraph = "Test 4 (Lena):\nsie"
        #expect(WordTokenizer.wordCount(paragraph) == 4)              // paragraph-scoped: populated
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: paragraph) == 1)   // sentence-scoped
    }

    @Test func theDecimalGuardKeepsANumberInsideItsSentence() {
        // "3.500" must not start a new sentence, or "Wir zahlten 3.500" would read as one word.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Wir zahlten 3.500") == true)
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "Wir zahlten 3.500") == 3)
    }

    @Test func aCRLFBreakCountsAsANewline() {
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Alles war gut und schön\r\nSie") == false)
    }

    @Test func punctuationOnlyRunsAreNotWords() {
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "— (") == 0)
        #expect(RunningThoughtGate.wordCount(inSentenceEnding: "— ( ok") == 1)
    }

    @Test func acceptedGhostWordsCountBecauseTheyAreInThePrefix() {
        // Arm 1 reads `textBeforeCaret`, which the host echo has already repopulated after an accept.
        #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: "Die Untersuchung wurde") == true)
    }

    @Test func readsTheContextsPrefix() {
        let ctx = TypingContext(textBeforeCaret: "Die Untersuchung", textAfterCaret: "", bundleID: "com.test")
        #expect(RunningThoughtGate.hasRunningThought(in: ctx) == true)
    }

    /// The single scan is what `RunningThoughtArm1CorpusWalk` splits its refusal counts by, so the
    /// tuple it returns has to agree with the two accessors the rest of the codebase reads. If they
    /// could disagree, a refusal could be filed under a branch that did not cause it and the walk's
    /// per-origin numbers would be quietly wrong — the failure mode the single scan exists to
    /// avoid.
    @Test func theSingleScanAgreesWithBothAccessors() {
        let prefixes = [
            "", "Die", "Die Untersuchung", "Das war alles. ", "Test 4 (Lena):\n",
            "Alles war gut. Danach ging es weiter\nSie", "Alles\nwar gut und ausführlich. Sie",
            "Wir zahlten 3.500", "— (", "Alles war gut und schön\r\nSie",
        ]
        for prefix in prefixes {
            let scan = RunningThoughtGate.currentSentence(in: prefix)
            #expect(scan.origin == RunningThoughtGate.sentenceStartOrigin(textBeforeCaret: prefix))
            #expect(scan.wordCount == RunningThoughtGate.wordCount(inSentenceEnding: prefix))
            let expected = scan.origin == .sentenceBoundary
                || scan.wordCount >= RunningThoughtGate.minimumSentenceWords
            #expect(RunningThoughtGate.hasRunningThought(textBeforeCaret: prefix) == expected)
        }
    }

    // MARK: Arm 2 — "abandons a running thought" (output side)

    @Test func aNewlineInTheLeadingBoundaryRunIsTheBreakSignal() {
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: "\n\n8. Offene Punkte") == true)
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: ".\n\nTest 7 (Sara):") == true)
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: "\r\nTest 7") == true)
    }

    @Test func aNewlineAfterContentIsNotOne() {
        // `ClauseStop.firstClause` cuts there anyway — the ghost is " weiter", a legitimate continuation.
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: " weiter\n\n8. Offene Punkte") == false)
    }

    @Test func anOrdinaryContinuationIsUnaffected() {
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: " wurde im Mai durchgeführt") == false)
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: ". Es war") == false)
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: "") == false)
    }

    @Test func theGateSuppressesOnlyWhenTheFlagIsSet() {
        #expect(RunningThoughtGate.continuation(" weiter", abandonsRunningThought: false) == " weiter")
        #expect(RunningThoughtGate.continuation(" weiter", abandonsRunningThought: true) == "")
    }

    /// The gate states the rule as *cut at the break, keep what precedes it*. Because the break
    /// sits in the LEADING boundary run, what precedes it holds no word character, so shaping it
    /// yields nothing — the truncation degenerates to suppression provably, not incidentally.
    @Test func nothingRenderablePrecedesTheBreak() {
        let raw = "\n\n8. Offene Punkte"
        let beforeBreak = String(raw.prefix(while: { !$0.isNewline }))
        #expect(ClauseStop.trimToWords(beforeBreak, max: 8) == "")
        #expect(SuggestionValueGate.isRenderable(beforeBreak) == false)
    }
}
