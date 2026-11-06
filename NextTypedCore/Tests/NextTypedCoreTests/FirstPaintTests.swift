import Testing
@testable import NextTypedCore

/// First-paint streaming: which part of a running decode may be painted before the
/// decode ends. Raw decode strings in, the early ghost text (or nothing) out.
@Suite struct FirstPaintTests {

    @Test func threeFinishedWordsAreCutOnceTheFourthWordStarts() {
        #expect(FirstPaint.firstWords(inDecode: " Ich freue mich au", wordCap: 8) == " Ich freue mich")
    }

    @Test func threeWordsWithNoFourthAreNotYetFinished() {
        // The third word may still grow ("mich" -> "michael"), so nothing is cut yet.
        #expect(FirstPaint.firstWords(inDecode: " Ich freue mich", wordCap: 8) == nil)
    }

    @Test func aFlushDecodeWithoutALeadingSpaceKeepsItsShape() {
        #expect(FirstPaint.firstWords(inDecode: "ing the report to", wordCap: 8) == "ing the report")
    }

    @Test func aNewlineInTheDecodeLeavesTheCutToTheFinalResult() {
        // Arm 2 of the running-thought gate reads the decode's own newline; only the final decode may
        // decide it.
        #expect(FirstPaint.firstWords(inDecode: "\nDear team, we are", wordCap: 8) == nil)
    }

    @Test func aFinishedClauseIsNeverPaintedEarly() {
        #expect(FirstPaint.firstWords(inDecode: " is fine. We can meet", wordCap: 8) == nil)
    }

    @Test func aThinkBlockIsNeverPaintedEarly() {
        #expect(FirstPaint.firstWords(inDecode: "<think> a b c d", wordCap: 8) == nil)
    }

    @Test func aCapAtOrBelowThreeWordsHasNothingToStream() {
        #expect(FirstPaint.firstWords(inDecode: " Ich freue mich au", wordCap: 3) == nil)
    }

    @Test func theEarlyCutIsTheShortWindow() {
        #expect(FirstPaint.words == 3)
    }
}
