import Testing
@testable import NextTypedCore

/// the menu-bar word count label and the ledger behind it.
@Suite struct MenuBarWordCountTests {
    @Test(arguments: [(0, "0"), (1, "1"), (9_999, "9999"), (10_000, "10k"), (12_345, "12k"),
                      (999_999, "999k"), (1_200_000, "1M"), (-3, "0")])
    func labelRule(words: Int, label: String) {
        #expect(MenuBarWordCount.label(words: words) == label)
    }

    @Test func todayReadsTheStoredDay() {
        var stats = UsageStatistics()
        let today = UsageDay(daysSinceEpoch: 20_000)
        stats.record(UsageBatch(acceptedWords: 5, bundleID: "a"), on: today.advanced(by: -1))
        stats.record(UsageBatch(acceptedWords: 3, bundleID: "a"), on: today)
        #expect(stats.acceptedWords(on: today) == 3)
        #expect(stats.acceptedWords(on: today.advanced(by: 1)) == 0)
    }

    @Test func anAcceptOnAProvenSurfaceCountsOnceEvenAfterTheBatchCommits() {
        var ledger = TodayAcceptedWords(committed: 4)
        ledger.noteEligibleSurface()
        ledger.noteAccepted(words: 1)
        #expect(ledger.displayed == 5)
        ledger.commit()
        #expect(ledger.displayed == 5)
        #expect(ledger.committed == 5)
    }

    @Test func anAcceptBeforeTheProofShowsOnlyWhenTheProofArrives() {
        var ledger = TodayAcceptedWords()
        ledger.noteAccepted(words: 2)
        #expect(ledger.displayed == 0)
        ledger.noteEligibleSurface()
        #expect(ledger.displayed == 2)
    }

    @Test func aBatchThatNeverProvedEligibleIsDroppedAtTheContextSwitch() {
        var ledger = TodayAcceptedWords(committed: 3)
        ledger.noteAccepted(words: 2)
        ledger.contextSwitch()
        #expect(ledger.displayed == 3)
    }

    @Test func deleteStatisticsGoesToZeroAndMidnightStartsAtZero() {
        var ledger = TodayAcceptedWords(committed: 7)
        ledger.noteEligibleSurface()
        ledger.noteAccepted(words: 1)
        ledger.reset()
        #expect(ledger.displayed == 0)

        var day = TodayAcceptedWords(committed: 7)
        day.startNewDay()
        #expect(day.displayed == 0)
    }

    @Test func theLaunchSeedNeverLowersAFigure() {
        var ledger = TodayAcceptedWords()
        ledger.noteEligibleSurface()
        ledger.noteAccepted(words: 2)
        ledger.commit()
        ledger.seed(storedToday: 1)
        #expect(ledger.displayed == 2)
        ledger.seed(storedToday: 9)
        #expect(ledger.displayed == 9)
    }
}
