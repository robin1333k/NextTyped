import Testing
@testable import NextTypedCore

@Suite struct ModelDownloadProgressLogTests {

    // MARK: The step cadence (the primary signal)

    @Test func logsOncePerTenPercentStep() {
        var log = ModelDownloadProgressLog()
        // Timestamps a second apart so the interval floor never participates: this pins the STEP rule.
        #expect(log.lineDue(fraction: 0.10, at: 1) == 10)
        #expect(log.lineDue(fraction: 0.20, at: 2) == 20)
        #expect(log.lineDue(fraction: 0.95, at: 3) == 90)
        #expect(log.lineDue(fraction: 1.0, at: 4) == 100)
    }

    @Test func swallowsCallbacksInsideTheCurrentStep() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.10, at: 1) == 10)
        // The handler fires hundreds of times per bucket; all of them must be silent.
        #expect(log.lineDue(fraction: 0.11, at: 2) == nil)
        #expect(log.lineDue(fraction: 0.19, at: 3) == nil)
        #expect(log.lineDue(fraction: 0.20, at: 4) == 20)
    }

    @Test func zeroPercentIsNeverLogged() {
        var log = ModelDownloadProgressLog()
        // The engine's `downloading … from Hub…` line already marks the start — a 0 % line adds nothing.
        #expect(log.lineDue(fraction: 0.0, at: 1) == nil)
        #expect(log.lineDue(fraction: 0.05, at: 2) == nil)
        #expect(log.lineDue(fraction: 0.10, at: 3) == 10)
    }

    // MARK: The interval floor (a burst must not print ten lines in a tick)

    @Test func floorSuppressesASecondLineWithinOneSecond() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.10, at: 10) == 10)
        // A resumed/cached download crosses several buckets at once.
        #expect(log.lineDue(fraction: 0.30, at: 10.2) == nil)
        #expect(log.lineDue(fraction: 0.50, at: 10.9) == nil)
    }

    @Test func aSuppressedBucketIsSkipped_notReplayed() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.10, at: 10) == 10)
        #expect(log.lineDue(fraction: 0.30, at: 10.2) == nil)
        // Once the floor lifts, the line reports where the download IS (50 %), not the bucket the floor
        // swallowed (30 %): the log stays monotone and skips rather than lagging behind reality.
        #expect(log.lineDue(fraction: 0.50, at: 11.5) == 50)
    }

    @Test func theFirstLineIsNotDelayedByTheFloor() {
        var log = ModelDownloadProgressLog()
        // No previous line ⇒ nothing to be too close to; a fast small download still says something.
        #expect(log.lineDue(fraction: 0.40, at: 0.05) == 40)
    }

    // MARK: Misreporting downloaders (forward motion only)

    @Test func aFractionThatGoesBackwardsLogsNothing() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.60, at: 1) == 60)
        // Some downloaders reset per file; the log must not walk backwards or repeat a bucket.
        #expect(log.lineDue(fraction: 0.20, at: 2) == nil)
        #expect(log.lineDue(fraction: 0.60, at: 3) == nil)
        #expect(log.lineDue(fraction: 0.70, at: 4) == 70)
    }

    @Test func outOfRangeAndNonFiniteFractionsCannotPoisonTheBuckets() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: .nan, at: 1) == nil)
        #expect(log.lineDue(fraction: .infinity, at: 2) == nil)
        // Clamped, not extrapolated: 1.7 is 100 %, and a negative fraction is silent.
        #expect(log.lineDue(fraction: -0.5, at: 3) == nil)
        #expect(log.lineDue(fraction: 1.7, at: 4) == 100)
        #expect(log.lineDue(fraction: 1.9, at: 5) == nil)
    }

    // MARK: The whole run stays inside the readable bound

    @Test func aFullDownloadEmitsAtMostTenLines() {
        var log = ModelDownloadProgressLog()
        var lines: [Int] = []
        // 470 callbacks over ~47 s — the shape of the measured real download.
        for i in 1...470 {
            let t = Double(i) / 10
            if let percent = log.lineDue(fraction: Double(i) / 470, at: t) { lines.append(percent) }
        }
        #expect(lines == [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    }

    @Test func aCustomStepChangesTheCadence() {
        var log = ModelDownloadProgressLog(step: 0.25, minimumInterval: 0)
        #expect(log.lineDue(fraction: 0.25, at: 1) == 25)
        #expect(log.lineDue(fraction: 0.40, at: 1) == nil)
        #expect(log.lineDue(fraction: 0.50, at: 1) == 50)
    }

    @Test func aNonPositiveStepFallsBackToTheDefaultRatherThanLoggingEveryCallback() {
        // Guard the divide-by-zero-shaped misconfiguration: the whole point of the type is that no
        // construction of it can produce a line per callback.
        var log = ModelDownloadProgressLog(step: 0, minimumInterval: 0)
        #expect(log.lineDue(fraction: 0.10, at: 1) == 10)
        #expect(log.lineDue(fraction: 0.11, at: 1) == nil)
    }

    // MARK: The byte source

    @Test func aCallbackBetweenZeroAndOneMeansTheBytesCameFromTheNetwork() {
        var log = ModelDownloadProgressLog()
        _ = log.lineDue(fraction: 0.0, at: 1)
        _ = log.lineDue(fraction: 0.37, at: 2)
        _ = log.lineDue(fraction: 1.0, at: 3)
        #expect(log.byteSource == .network)
    }

    @Test func aSingleCompletedCallbackMeansTheHubCacheServedTheModel() {
        var log = ModelDownloadProgressLog()
        // A warm Hub cache reports one finished fraction and nothing before it.
        _ = log.lineDue(fraction: 1.0, at: 1)
        #expect(log.byteSource == .cache)
    }

    @Test func noCallbackAtAllCountsAsCache() {
        #expect(ModelDownloadProgressLog().byteSource == .cache)
    }

    @Test func aPartialFractionSwallowedByTheFloorStillCountsAsNetwork() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.10, at: 10) == 10)
        #expect(log.lineDue(fraction: 0.05, at: 10.1) == nil)
        #expect(log.byteSource == .network)
    }

    @Test func aPartialFractionBelowTheFirstStepCountsAsNetwork() {
        var log = ModelDownloadProgressLog()
        #expect(log.lineDue(fraction: 0.05, at: 1) == nil)
        #expect(log.byteSource == .network)
    }

    @Test func nanAndOutOfRangeFractionsAreNotEvidenceOfATransfer() {
        var log = ModelDownloadProgressLog()
        _ = log.lineDue(fraction: .nan, at: 1)
        _ = log.lineDue(fraction: -0.5, at: 2)
        _ = log.lineDue(fraction: 1.5, at: 3)
        #expect(log.byteSource == .cache)
    }

    @Test func aFileWrittenToTheCacheMeansNetworkEvenWithoutAPartialFraction() {
        var log = ModelDownloadProgressLog()
        // The case where the downloader reports only a finished fraction, yet bytes were fetched.
        _ = log.lineDue(fraction: 1.0, at: 1)
        #expect(log.byteSource(freshFileCount: 3) == .network)
        #expect(log.byteSource(freshFileCount: 0) == .cache)
    }
}
