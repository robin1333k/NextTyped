import AppKit
@preconcurrency import CoreGraphics
import NextTypedCore

/// Reads the window server's tap list after our tap was disabled by timeout and logs whether
/// another process leaks disabled taps (CT-48). The trigger rule is Core's
/// `EventTapCensusSchedule`; the verdict is Core's `EventTapLeakPolicy`.
@MainActor
final class EventTapCensus {
    private var lastRun: Double?
    private(set) var lastVerdict: EventTapLeakVerdict?
    /// Called with every verdict, so the coordinator can raise or clear a notice.
    var onVerdict: ((EventTapLeakVerdict) -> Void)?

    private var pending = false

    /// Called from the tap callback. The window-server read runs in a main-actor task after the
    /// callback has returned, so the callback itself stays short.
    func noteDisable(cause: EventTapDisableCause) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !pending,
              EventTapCensusSchedule.shouldRun(cause: cause, lastRun: lastRun, now: now) else { return }
        pending = true
        Task { @MainActor [weak self] in self?.run(at: now) }
    }

    private func run(at now: Double) {
        pending = false
        guard let verdict = EventTapLeakPolicy.verdict(readResult: Self.readTapList(),
                                                       ownPID: ProcessInfo.processInfo.processIdentifier) else {
            // A failed read is not a verdict: keep the last one and leave the slot unused.
            acLog("[tap]: census read-failed")
            return
        }
        lastRun = now
        lastVerdict = verdict
        switch verdict {
        case .healthy(let maxPerOwner):
            acLog("[tap]: census healthy max=%d", maxPerOwner)
        case .leakSuspected(let pid, let count):
            let owner = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? String(pid)
            acLog("[tap]: leak-suspected owner=%@ taps=%d", owner, count)
        }
        onVerdict?(verdict)
    }

    private static func readTapList() -> [EventTapRecord]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var filled: UInt32 = 0
        guard CGGetEventTapList(count, &list, &filled) == .success else { return nil }
        return list.prefix(Int(filled)).map {
            EventTapRecord(ownerPID: $0.tappingProcess, enabled: $0.enabled)
        }
    }
}
