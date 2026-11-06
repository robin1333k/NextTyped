import Testing
@testable import NextTypedCore

@Suite("EventTapLeakPolicy")
struct EventTapLeakPolicyTests {
    private let me: Int32 = 100

    private func taps(owner: Int32, disabled: Int, enabled: Int = 0) -> [EventTapRecord] {
        Array(repeating: EventTapRecord(ownerPID: owner, enabled: false), count: disabled)
            + Array(repeating: EventTapRecord(ownerPID: owner, enabled: true), count: enabled)
    }

    @Test func placeholderThresholdIs25() {
        #expect(EventTapLeakPolicy.maxDisabledPerOwner == 25)
    }

    @Test func otherOwnerWith25DisabledTapsIsSuspected() {
        let verdict = EventTapLeakPolicy.verdict(records: taps(owner: 200, disabled: 25), ownPID: me)
        #expect(verdict == .leakSuspected(ownerPID: 200, tapCount: 25))
    }

    @Test func otherOwnerWith24DisabledTapsIsHealthy() {
        let verdict = EventTapLeakPolicy.verdict(records: taps(owner: 200, disabled: 24), ownPID: me)
        #expect(verdict == .healthy(maxPerOwner: 24))
    }

    @Test func thirtyEnabledTapsAreHealthy() {
        let verdict = EventTapLeakPolicy.verdict(records: taps(owner: 200, disabled: 0, enabled: 30), ownPID: me)
        #expect(verdict == .healthy(maxPerOwner: 0))
    }

    @Test func ourOwnDisabledTapsNeverCount() {
        let verdict = EventTapLeakPolicy.verdict(records: taps(owner: me, disabled: 400), ownPID: me)
        #expect(verdict == .healthy(maxPerOwner: 0))
    }

    @Test func twoOwnersAboveThresholdReportsTheOneWithMoreDisabledTaps() {
        let records = taps(owner: 200, disabled: 30) + taps(owner: 300, disabled: 90) + taps(owner: me, disabled: 500)
        #expect(EventTapLeakPolicy.verdict(records: records, ownPID: me)
                == .leakSuspected(ownerPID: 300, tapCount: 90))
    }

    @Test func karabinerReportOf1126DisabledOf1127IsSuspected() {
        let records = taps(owner: 200, disabled: 1126, enabled: 1)
        #expect(EventTapLeakPolicy.verdict(records: records, ownPID: me)
                == .leakSuspected(ownerPID: 200, tapCount: 1126))
    }

    @Test func fourteenEnabledAndTenWithFiveDisabledStayHealthy() {
        let records = taps(owner: 200, disabled: 0, enabled: 14) + taps(owner: 300, disabled: 5, enabled: 5)
        #expect(EventTapLeakPolicy.verdict(records: records, ownPID: me) == .healthy(maxPerOwner: 5))
    }

    @Test func emptyListIsHealthy() {
        #expect(EventTapLeakPolicy.verdict(records: [], ownPID: me) == .healthy(maxPerOwner: 0))
    }
}

@Suite("EventTapCensusSchedule")
struct EventTapCensusScheduleTests {
    @Test func neverRunsWithoutATimeoutDisable() {
        #expect(!EventTapCensusSchedule.shouldRun(cause: .userInput, lastRun: nil, now: 1000))
    }

    @Test func runsOnTimeoutWhenNeverRunBefore() {
        #expect(EventTapCensusSchedule.shouldRun(cause: .timeout, lastRun: nil, now: 1000))
    }

    @Test func skipsWithin60SecondsOfTheLastRun() {
        #expect(!EventTapCensusSchedule.shouldRun(cause: .timeout, lastRun: 1000, now: 1059.9))
    }

    @Test func runsAgainAt60Seconds() {
        #expect(EventTapCensusSchedule.shouldRun(cause: .timeout, lastRun: 1000, now: 1060))
    }

    @Test func failedReadGivesNoVerdict() {
        #expect(EventTapLeakPolicy.verdict(readResult: nil, ownPID: 100) == nil)
    }

    @Test func successfulEmptyReadIsHealthy() {
        #expect(EventTapLeakPolicy.verdict(readResult: [], ownPID: 100) == .healthy(maxPerOwner: 0))
    }
}
