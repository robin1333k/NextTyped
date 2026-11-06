/// One entry of the window server's event-tap list, reduced to what the leak check needs.
/// The App reads `CGGetEventTapList` and maps each entry to this value; tests pass literals.
public struct EventTapRecord: Equatable, Sendable {
    public let ownerPID: Int32
    public let enabled: Bool

    public init(ownerPID: Int32, enabled: Bool) {
        self.ownerPID = ownerPID
        self.enabled = enabled
    }
}

public enum EventTapLeakVerdict: Equatable, Sendable {
    /// No other process reached the threshold; `maxPerOwner` is the highest disabled-tap count seen.
    case healthy(maxPerOwner: Int)
    case leakSuspected(ownerPID: Int32, tapCount: Int)
}

/// Decides whether another process leaks disabled event taps (CT-48). Counts disabled taps
/// per owner: 1126 of 1127 taps disabled for Karabiner-Elements 16.1.0, 14 enabled and none
/// disabled for a healthy app. Our own taps never count.
public enum EventTapLeakPolicy {
    /// Placeholder: a suspected leak starts at this many disabled taps of one other owner.
    public static let maxDisabledPerOwner = 25

    public static func verdict(records: [EventTapRecord], ownPID: Int32) -> EventTapLeakVerdict {
        var disabledByOwner: [Int32: Int] = [:]
        for record in records where !record.enabled && record.ownerPID != ownPID {
            disabledByOwner[record.ownerPID, default: 0] += 1
        }
        // Ties break toward the lower PID so the answer is stable.
        let worst = disabledByOwner.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }
        guard let worst else { return .healthy(maxPerOwner: 0) }
        if worst.value >= maxDisabledPerOwner {
            return .leakSuspected(ownerPID: worst.key, tapCount: worst.value)
        }
        return .healthy(maxPerOwner: worst.value)
    }
}

extension EventTapLeakPolicy {
    /// `nil` records mean the window server read failed: there is no verdict, so a raised
    /// notice stays and the 60 s slot is not used. An empty list is a real (healthy) read.
    public static func verdict(readResult records: [EventTapRecord]?, ownPID: Int32) -> EventTapLeakVerdict? {
        guard let records else { return nil }
        return verdict(records: records, ownPID: ownPID)
    }
}

/// Why macOS disabled our tap.
public enum EventTapDisableCause: String, Equatable, Sendable {
    case timeout
    case userInput = "user-input"
}

/// When the census may run: only after a timeout disable, at most once per 60 s.
public enum EventTapCensusSchedule {
    public static let minInterval: Double = 60

    /// `lastRun` and `now` are seconds on one monotonic clock.
    public static func shouldRun(cause: EventTapDisableCause, lastRun: Double?, now: Double) -> Bool {
        guard cause == .timeout else { return false }
        guard let lastRun else { return true }
        return now - lastRun >= minInterval
    }
}
