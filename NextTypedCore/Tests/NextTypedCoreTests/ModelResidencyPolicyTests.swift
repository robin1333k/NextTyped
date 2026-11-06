import Testing
@testable import NextTypedCore

/// Full-ladder tests for the `ModelResidencyPolicy` reducer. Because the reducer is
/// **time-free** (the clock is just `now: TimeInterval` on the events), the whole 30 s-flush /
/// 2.5 min-unload ladder is exercised by feeding events + ticks and asserting the returned effects — no
/// real waiting, no running app. Categories mirror the issue's plan: cap · idle-flush · focus-loss-flush ·
/// warm-state-suppresses-unload · absence-unload · away-signals · context-switch · no-thrash · reload.
@Suite struct ModelResidencyPolicyTests {

    private typealias P = ModelResidencyPolicy
    private typealias E = ModelResidencyPolicy.Effect

    /// Defaults: 30 s flush, 150 s unload; a recognisable cap so `.setCacheLimit` is easy to assert.
    private func make(cap: Int = 4096) -> P {
        P(config: .init(cacheLimitBytes: cap, flushIdleSeconds: 30, unloadAbsenceSeconds: 150))
    }

    // MARK: Tier 0 — cap at startup

    @Test func startSetsTheCacheLimit() {
        var p = make(cap: 4096)
        #expect(p.start(now: 0) == [.setCacheLimit(bytes: 4096)])
    }

    // MARK: Tier 1 — idle flush

    @Test func idleThirtySecondsFlushesOnce() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        #expect(p.handle(.tick(now: 20)) == [])             // only 19 s idle
        #expect(p.handle(.tick(now: 31)) == [.flushCache])  // 30 s idle → flush
        #expect(p.handle(.tick(now: 40)) == [])             // already flushed → no re-emit
    }

    @Test func predictionActivityRewarmsAndResetsTheIdleClock() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        #expect(p.handle(.tick(now: 31)) == [.flushCache])  // flushed
        _ = p.handle(.predictionActivity(app: "A", now: 32)) // a predict re-warms the pool
        #expect(p.handle(.tick(now: 40)) == [])             // 8 s since activity → no flush
    }

    // MARK: Tier 1 — flush on losing editable focus

    @Test func losingEditableFocusFlushesImmediately() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        #expect(p.handle(.focusChanged(editable: false, app: "A", now: 2)) == [.flushCache])
    }

    @Test func focusLossWhenAlreadyFlushedDoesNotReflush() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.tick(now: 31))                        // → flushed
        #expect(p.handle(.focusChanged(editable: false, app: "A", now: 32)) == [])
    }

    // MARK: Tier 2 — warm-state suppresses unload

    @Test func stayingInTheWritingAppNeverUnloads() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        // Editable focus lost, but still frontmost in the writing app → warm.
        _ = p.handle(.focusChanged(editable: false, app: "A", now: 2))
        #expect(p.handle(.tick(now: 10_000)) == [])         // hours later, still warm → no unload
    }

    // MARK: Tier 2 — unload after continuous absence

    @Test func leavingTheWritingAppUnloadsAfterTheAbsenceThreshold() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.frontmostAppChanged(app: "B", now: 2)) // warm ends at t=2
        #expect(p.handle(.tick(now: 140)) == [.flushCache])  // 138 s absence < 150 → only the idle flush
        #expect(p.handle(.tick(now: 152)) == [.unloadModel]) // 150 s continuous absence → unload
        #expect(p.handle(.tick(now: 200)) == [])             // already unloaded → no double unload
    }

    @Test func unloadSupersedesFlushOnTheSameTick() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.frontmostAppChanged(app: "B", now: 2))
        // One tick where BOTH idle≥30 and absence≥150 hold on a still-loaded model: unload wins, alone.
        #expect(p.handle(.tick(now: 200)) == [.unloadModel])
    }

    // MARK: Strong away-signals (override the conservative timer)

    @Test func memoryWarningFlushesAndCriticalUnloads() {
        var warn = make()
        _ = warn.start(now: 0)
        _ = warn.handle(.predictionActivity(app: "A", now: 1))
        #expect(warn.handle(.memoryPressure(.warning)) == [.flushCache])
        #expect(warn.handle(.memoryPressure(.warning)) == [])    // already flushed

        var crit = make()
        _ = crit.start(now: 0)
        _ = crit.handle(.predictionActivity(app: "A", now: 1))
        #expect(crit.handle(.memoryPressure(.critical)) == [.unloadModel])
        #expect(crit.handle(.memoryPressure(.critical)) == [])   // already unloaded
    }

    @Test func displaySleepLockAndSystemSleepEachUnload() {
        for signal in [P.Event.displaySleep, .screenLocked, .systemWillSleep] {
            var p = make()
            _ = p.start(now: 0)
            _ = p.handle(.predictionActivity(app: "A", now: 1))
            #expect(p.handle(signal) == [.unloadModel], "expected unload for \(signal)")
            #expect(p.handle(signal) == [], "idempotent for \(signal)")
        }
    }

    // MARK: Context-switch — invalidate KV then flush

    @Test func contextSwitchInvalidatesKVThenFlushes() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))  // builds a KV cache
        #expect(p.handle(.contextSwitch(now: 2)) == [.invalidateKVCache, .flushCache])
        // Nothing left to invalidate or flush on a repeat.
        #expect(p.handle(.contextSwitch(now: 3)) == [])
    }

    @Test func contextSwitchAfterUnloadIsANoOp() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.systemWillSleep)                       // unloaded, kv invalidated
        #expect(p.handle(.contextSwitch(now: 5)) == [])
    }

    // MARK: Reload — pre-warm on editable focus

    @Test func focusingAnEditableFieldWhileUnloadedPreWarms() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.displaySleep)                          // → unloaded
        #expect(p.handle(.focusChanged(editable: true, app: "A", now: 10)) == [.preloadModel])
    }

    @Test func focusingAnEditableFieldWhileLoadedDoesNotPreWarm() {
        var p = make()
        _ = p.start(now: 0)
        #expect(p.handle(.focusChanged(editable: true, app: "A", now: 1)) == [])
    }

    // MARK: Anti-thrash — rapid focus toggling

    @Test func rapidLeaveReturnDoesNotThrashUnload() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 1))
        _ = p.handle(.frontmostAppChanged(app: "B", now: 2))   // leave → absence clock starts at 2
        _ = p.handle(.tick(now: 60))                           // idle flush, no unload (58 s absence)
        _ = p.handle(.frontmostAppChanged(app: "A", now: 70))  // return to writing app → warm, clock cleared
        _ = p.handle(.frontmostAppChanged(app: "B", now: 71))  // leave again → clock restarts at 71
        // 129 s of *this* absence — the continuous-absence requirement means no unload yet.
        #expect(p.handle(.tick(now: 200)) == [])
    }

    // MARK: Unload rule

    private func make(rule: P.UnloadRule) -> P {
        P(config: .init(cacheLimitBytes: 4096, flushIdleSeconds: 30, unloadRule: rule))
    }

    @Test func afterIdleUnloadsWhileWarmStateHolds() {
        var p = make(rule: .afterIdle(seconds: 300))
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 0))
        _ = p.handle(.focusChanged(editable: true, app: "A", now: 0))
        #expect(p.handle(.tick(now: 35)) == [.flushCache])
        #expect(p.handle(.tick(now: 299)) == [])
        #expect(p.handle(.tick(now: 300)) == [.unloadModel])
    }

    @Test func whenAwayNeverUnloadsWhileWarmStateHolds() {
        var p = make(rule: .whenAway(absenceSeconds: 150))
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 0))
        _ = p.handle(.focusChanged(editable: true, app: "A", now: 0))
        #expect(p.handle(.tick(now: 300)) == [.flushCache])
        #expect(p.handle(.tick(now: 10_000)) == [])
    }

    @Test func neverKeepsTheModelButMemoryPressureStillWins() {
        var p = make(rule: .never)
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 0))
        _ = p.handle(.frontmostAppChanged(app: "B", now: 1))
        #expect(p.handle(.tick(now: 35)) == [.flushCache])
        #expect(p.handle(.tick(now: 10_000)) == [])
        #expect(p.handle(.screenLocked) == [])
        #expect(p.handle(.displaySleep) == [])
        #expect(p.handle(.systemWillSleep) == [])
        #expect(p.handle(.memoryPressure(.critical)) == [.unloadModel])
    }

    @Test func afterIdleUnloadsOnScreenLock() {
        var p = make(rule: .afterIdle(seconds: 300))
        _ = p.start(now: 0)
        #expect(p.handle(.screenLocked) == [.unloadModel])
    }

    @Test func changingTheRuleCountsIdleFromTheLastActivity() {
        var p = make(rule: .whenAway(absenceSeconds: 150))
        _ = p.start(now: 0)
        _ = p.handle(.predictionActivity(app: "A", now: 0))
        _ = p.handle(.focusChanged(editable: true, app: "A", now: 0))
        #expect(p.handle(.tick(now: 600)) == [.flushCache])
        #expect(p.handle(.setUnloadRule(.afterIdle(seconds: 300))) == [])
        #expect(p.handle(.tick(now: 607)) == [.unloadModel])
    }

    @Test func changingTheRuleWhileUnloadedDoesNotReload() {
        var p = make(rule: .afterIdle(seconds: 300))
        _ = p.start(now: 0)
        #expect(p.handle(.screenLocked) == [.unloadModel])
        #expect(p.handle(.setUnloadRule(.never)) == [])
    }

    @Test func defaultConfigRuleIsTheTodayRule() {
        #expect(P.Config().unloadRule == .whenAway(absenceSeconds: 150))
        #expect(P.Config(unloadAbsenceSeconds: 99).unloadRule == .whenAway(absenceSeconds: 99))
    }

    // MARK: Manual unload

    @Test func manualUnloadFromLoadedUnloadsOnce() {
        var p = make()
        _ = p.start(now: 0)
        #expect(p.handle(.manualUnload) == [.unloadModel])
        #expect(p.handle(.manualUnload) == [])
    }

    @Test func manualUnloadFromFlushedUnloads() {
        var p = make()
        _ = p.start(now: 0)
        #expect(p.handle(.tick(now: 31)) == [.flushCache])
        #expect(p.handle(.manualUnload) == [.unloadModel])
    }

    @Test func predictionActivityAfterManualUnloadIsLoadedAgain() {
        var p = make()
        _ = p.start(now: 0)
        _ = p.handle(.manualUnload)
        _ = p.handle(.predictionActivity(app: "A", now: 5))
        #expect(p.handle(.manualUnload) == [.unloadModel])
    }

    @Test func manualUnloadWorksUnderTheNeverRule() {
        var p = make(rule: .never)
        _ = p.start(now: 0)
        #expect(p.handle(.manualUnload) == [.unloadModel])
    }
}
