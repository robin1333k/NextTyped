import Foundation
import Testing
@testable import NextTypedCore

/// Local usage statistics: the counters, the rolling retention window,
/// and the two arithmetic rules behind the measured keystrokes-per-minute figure.
@Suite struct UsageStatisticsTests {
    private let today = UsageDay(daysSinceEpoch: 20_000)

    // MARK: Recording

    @Test func aBatchLandsOnItsDayAndOnItsApp() {
        var stats = UsageStatistics()
        stats.record(UsageBatch(acceptedWords: 3, keystrokes: 40, activeSeconds: 30,
                                bundleID: "com.apple.TextEdit"), on: today)

        #expect(stats[today].acceptedWords == 3)
        #expect(stats[today].keystrokes == 40)
        #expect(stats[today].activeSeconds == 30)
        #expect(stats[today].acceptedWordsByApp == ["com.apple.TextEdit": 3])
    }

    @Test func batchesAccumulateWithinADayAndStayApartAcrossDays() {
        var stats = UsageStatistics()
        let yesterday = today.advanced(by: -1)
        stats.record(UsageBatch(acceptedWords: 2, keystrokes: 10, bundleID: "a"), on: yesterday)
        stats.record(UsageBatch(acceptedWords: 1, keystrokes: 5, bundleID: "a"), on: today)
        stats.record(UsageBatch(acceptedWords: 4, keystrokes: 7, bundleID: "b"), on: today)

        #expect(stats[yesterday].acceptedWords == 2)
        #expect(stats[today].acceptedWords == 5)
        #expect(stats.totals.acceptedWords == 7)
        #expect(stats.totals.keystrokes == 22)
        #expect(stats.acceptedWordsByApp.map(\.bundleID) == ["b", "a"])
        #expect(stats.acceptedWordsByApp.map(\.acceptedWords) == [4, 3])
    }

    /// An empty batch must not create a day: a day that exists with all-zero counters would show up in
    /// the series as a recorded day on which nothing happened, which is a different claim.
    @Test func anEmptyBatchIsNotRecorded() {
        var stats = UsageStatistics()
        stats.record(UsageBatch(bundleID: "com.apple.TextEdit"), on: today)
        #expect(stats.days.isEmpty)
        #expect(stats.isEmpty)
    }

    /// Keystrokes on a surface whose bundle ID we never learned still count towards the typing rate —
    /// they just cannot be attributed to an app row.
    @Test func keystrokesWithoutABundleIDCountButAreNotAttributed() {
        var stats = UsageStatistics()
        stats.record(UsageBatch(acceptedWords: 2, keystrokes: 9, activeSeconds: 8), on: today)
        #expect(stats[today].keystrokes == 9)
        #expect(stats[today].acceptedWordsByApp.isEmpty)
    }

    // MARK: Retention

    @Test func theWindowIsNinetyDaysIncludingToday() {
        let oldest = today.advanced(by: -(UsageStatistics.retentionDays - 1))
        var stats = UsageStatistics(days: [
            oldest.storageKey: DayUsage(acceptedWords: 1),
            oldest.advanced(by: -1).storageKey: DayUsage(acceptedWords: 1),
        ])
        stats.prune(asOf: today)

        #expect(stats[oldest].acceptedWords == 1)
        #expect(stats[oldest.advanced(by: -1)].isEmpty)
    }

    @Test func recordingPrunesSoTheStoreCannotOutgrowTheWindow() {
        var stats = UsageStatistics()
        stats.record(UsageBatch(acceptedWords: 1), on: today.advanced(by: -200))
        stats.record(UsageBatch(acceptedWords: 1), on: today)
        #expect(stats.days.count == 1)
        #expect(stats.totals.acceptedWords == 1)
    }

    /// A clock that jumped backwards (a corrected system time, a restored backup) must not leave days in
    /// the "future" that the series would never show and the window would never expire.
    @Test func daysAheadOfTodayArePruned() {
        var stats = UsageStatistics(days: [today.advanced(by: 5).storageKey: DayUsage(keystrokes: 3)])
        stats.prune(asOf: today)
        #expect(stats.isEmpty)
    }

    @Test func aJunkKeyIsDroppedRatherThanKeptForever() {
        var stats = UsageStatistics(days: ["not-a-day": DayUsage(acceptedWords: 5)])
        stats.prune(asOf: today)
        #expect(stats.days.isEmpty)
    }

    // MARK: Reading

    @Test func theSeriesIsOldestFirstAndZeroFilled() {
        var stats = UsageStatistics()
        stats.record(UsageBatch(acceptedWords: 4), on: today.advanced(by: -2))
        let series = stats.series(endingAt: today, count: 3)

        #expect(series.map(\.day) == [today.advanced(by: -2), today.advanced(by: -1), today])
        #expect(series.map(\.usage.acceptedWords) == [4, 0, 0])
    }

    @Test func emptinessIsAboutActivityNotAboutKeys() {
        // A day key with all-zero counters is still "nothing has happened" — the pane shows its empty
        // state on this, rather than a screen of zeros that reads as measured data.
        let stats = UsageStatistics(days: [today.storageKey: DayUsage()])
        #expect(stats.isEmpty)
    }

    // MARK: The typing rate

    @Test func onlyGapsShorterThanTheIdleCutCountAsTypingTime() {
        #expect(TypingRate.activeSeconds(sincePreviousKeystroke: nil) == 0)        // first keystroke
        #expect(TypingRate.activeSeconds(sincePreviousKeystroke: 0.2) == 0.2)
        #expect(TypingRate.activeSeconds(sincePreviousKeystroke: TypingRate.idleGapSeconds) ==
                TypingRate.idleGapSeconds)
        #expect(TypingRate.activeSeconds(sincePreviousKeystroke: 600) == 0)        // a coffee break
        #expect(TypingRate.activeSeconds(sincePreviousKeystroke: -3) == 0)         // clock stepped back
    }

    @Test func theRateIsKeystrokesOverMeasuredTypingMinutes() {
        #expect(TypingRate.perMinute(keystrokes: 300, activeSeconds: 120) == 150)
    }

    /// The honesty guard: a rate computed over a few seconds is noise, and printing it anyway would be
    /// inventing precision — exactly the objection that killed "≈ time saved".
    @Test func aRateIsWithheldUntilThereIsEnoughTypingToStateOne() {
        #expect(TypingRate.perMinute(keystrokes: 40, activeSeconds: 4) == nil)
        #expect(TypingRate.perMinute(keystrokes: 0, activeSeconds: 300) == nil)
        #expect(DayUsage(keystrokes: 200, activeSeconds: 100).keystrokesPerMinute == 120)
        #expect(DayUsage(keystrokes: 200, activeSeconds: 10).keystrokesPerMinute == nil)
    }

    // MARK: Persistence shape

    @Test func theStoreRoundTripsThroughJSON() throws {
        var stats = UsageStatistics()
        stats.record(UsageBatch(acceptedWords: 6, keystrokes: 90, activeSeconds: 61,
                                bundleID: "com.apple.Notes"), on: today)
        let data = try JSONEncoder().encode(stats)
        #expect(try JSONDecoder().decode(UsageStatistics.self, from: data) == stats)
    }
}
