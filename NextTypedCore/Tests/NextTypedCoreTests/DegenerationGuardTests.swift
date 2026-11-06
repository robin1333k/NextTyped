import Testing
@testable import NextTypedCore

@Suite struct DegenerationGuardTests {
    // Token ids stand in for the tokenised text: 10 = " und", 11 = " dann", 5 = "Heute".

    @Test func repeatedTwoTokenCycleIsCutToOneCopy() {
        // "Heute und dann und dann und dann" -> "Heute und dann"
        let tokens = [5, 10, 11, 10, 11, 10, 11]
        #expect(DegenerationGuard.trim(tokens) == [5, 10, 11])
    }

    @Test func singleTokenLoopIsCutToOneCopy() {
        #expect(DegenerationGuard.trim([7, 3, 3, 3, 3, 3]) == [7, 3])
    }

    @Test func fourTokenCycleIsCutToOneCopy() {
        let tokens = [9, 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3, 4]
        #expect(DegenerationGuard.trim(tokens) == [9, 1, 2, 3, 4])
    }

    @Test func twoRepetitionsAreNotALoop() {
        #expect(DegenerationGuard.trim([5, 10, 11, 10, 11]) == nil)
    }

    @Test func fiveTokenCycleIsNotDetected() {
        let tokens = [1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5]
        #expect(DegenerationGuard.trim(tokens) == nil)
    }

    @Test func ordinarySequencePassesUnchanged() {
        #expect(DegenerationGuard.trim([5, 10, 11, 12, 13, 14]) == nil)
        #expect(DegenerationGuard.trim([]) == nil)
    }

    @Test func loopInTheMiddleIsNotTrimmed() {
        // Only a tail loop counts; the sequence moved on afterwards.
        #expect(DegenerationGuard.trim([10, 11, 10, 11, 10, 11, 12]) == nil)
    }
}
