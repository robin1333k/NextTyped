import Testing
@testable import NextTypedCore

@Suite("TabPracticeProgress")
struct TabPracticeProgressTests {
    @Test func startsPracticingWithNothingAccepted() {
        let p = TabPracticeProgress()
        #expect(p.phase == .practicing)
        #expect(!p.wordAccepted && !p.allAccepted)
    }

    @Test func aWordAcceptKeepsPracticingUntilOptionTab() {
        var p = TabPracticeProgress()
        p.apply(.ghostShown)
        p.apply(.accepted(.tab))
        #expect(p.phase == .practicing)
        #expect(p.wordAccepted && !p.allAccepted)
    }

    @Test func bothKeysFinishInEitherOrder() {
        var a = TabPracticeProgress()
        a.apply(.accepted(.tab)); a.apply(.accepted(.acceptAll))
        #expect(a.phase == .done)

        var b = TabPracticeProgress()
        b.apply(.accepted(.acceptAll)); b.apply(.accepted(.tab))
        #expect(b.phase == .done)
    }

    @Test func oneKeyRepeatedNeverFinishes() {
        var p = TabPracticeProgress()
        p.apply(.accepted(.tab)); p.apply(.accepted(.tab))
        #expect(p.phase == .practicing)
    }

    @Test func timeoutWithoutAGhostShowsTheFallback() {
        var p = TabPracticeProgress()
        p.apply(.timeout)
        #expect(p.phase == .noGhost)
    }

    @Test func aGhostArrivingAfterTheTimeoutClearsTheFallback() {
        var p = TabPracticeProgress()
        p.apply(.timeout)
        p.apply(.ghostShown)
        #expect(p.phase == .practicing)
    }

    @Test func timeoutAfterAGhostWasSeenIsNotAFallback() {
        var p = TabPracticeProgress()
        p.apply(.ghostShown)
        p.apply(.timeout)
        #expect(p.phase == .practicing)
    }

    @Test func skipEndsTheStepWhateverCameBefore() {
        var p = TabPracticeProgress()
        p.apply(.accepted(.tab))
        p.apply(.skip)
        #expect(p.phase == .skipped)
        p.apply(.accepted(.acceptAll))
        #expect(p.phase == .skipped)
    }

    @Test func aFinishedStepIgnoresTheTimeout() {
        var p = TabPracticeProgress()
        p.apply(.accepted(.tab)); p.apply(.accepted(.acceptAll))
        p.apply(.timeout)
        #expect(p.phase == .done)
    }
}
