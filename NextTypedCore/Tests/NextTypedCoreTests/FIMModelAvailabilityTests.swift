import Testing
@testable import NextTypedCore

/// the FIM model's two failure verdicts have different **lifetimes**, and the defect was one
/// flag standing for both. These pins are the regression bar for re-merging them.
@Suite struct FIMModelAvailabilityTests {

    // MARK: The default state

    @Test func freshStateAllowsALoad() {
        // Nothing has been attempted: the strictly-lazy loader must be free to try.
        let availability = FIMModelAvailability()
        #expect(availability.allowsLoadAttempt)
        #expect(!availability.isUnusable)
    }

    // MARK: The retryable verdict — "this load attempt failed"

    @Test func aLoadFailureSuppressesFurtherAttemptsWithoutBeingFinal() {
        // The state half of "a failing load is not retried per keystroke": while the retryable verdict
        // stands, `allowsLoadAttempt` is false, so the engine's early return blocks the load. That
        // early return itself is NOT unit-reachable (it needs an MLX container) and is verified by
        // reading — this pins only the answer it consults, and that the answer is not the final one.
        var availability = FIMModelAvailability()
        availability.recordLoadFailure()
        #expect(!availability.allowsLoadAttempt)
        #expect(!availability.isUnusable)
    }

    @Test func theTierTwoUnloadClearsALoadFailure() {
        // The Tier-2 unload is the decided recovery boundary: a
        // strong away-signal means the machine idled, which is also when a transient cause (offline,
        // asleep, low disk, a Hub 5xx) has most likely resolved.
        var availability = FIMModelAvailability()
        availability.recordLoadFailure()
        availability.clearRetryableLoadFailure()
        #expect(availability.allowsLoadAttempt)
    }

    // MARK: The final verdict — "this model cannot bridge"

    @Test func aMissingSentinelVocabularySuppressesFurtherAttempts() {
        var availability = FIMModelAvailability()
        availability.recordUnusable()
        #expect(!availability.allowsLoadAttempt)
        #expect(availability.isUnusable)
    }

    /// **The pin the whole ticket exists for.** A vocabulary does not grow, so the sentinel verdict is
    /// final for this model; the recovery built for the *transient* failure must not re-open the cost
    /// the final latch was added to close (a ~1.1 GB model that can never produce a bridge, reloaded
    /// per mid-text keystroke behind the cross-model gate).
    @Test func theFinalVerdictSurvivesWhateverClearsTheRetryableOne() {
        var availability = FIMModelAvailability()
        availability.recordUnusable()
        availability.clearRetryableLoadFailure()
        #expect(availability.isUnusable)
        #expect(!availability.allowsLoadAttempt)
    }

    @Test func bothVerdictsStandingIsStillFinal() {
        // A transient failure, then a load that succeeded and turned out to lack the sentinels: the
        // unload clears only the first, and the model stays disabled for good.
        var availability = FIMModelAvailability()
        availability.recordLoadFailure()
        availability.recordUnusable()
        availability.clearRetryableLoadFailure()
        #expect(availability.isUnusable)
        #expect(!availability.allowsLoadAttempt)
    }
}
