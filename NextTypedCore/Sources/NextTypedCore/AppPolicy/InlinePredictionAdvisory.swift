import Foundation

/// What one read of the **undocumented** `NSGlobalDomain` key `NSAutomaticInlinePredictionEnabled`
///  actually told us.
///
/// Three states, not two, because the key is undocumented: it may be absent (the macOS default, which
/// *means* enabled), present and Boolean, or present as something we cannot interpret — and one day it
/// may simply be renamed out from under us. Collapsing "absent" into a Bool at the read site is what
/// forces every consumer to inherit one default, and the two consumers here need **different** ones.
///
/// The raw values double as greppable log tokens (the `PrefixReuse.rebuildCause` convention): the
/// acceptance criterion is that the row tracks the OS setting **while our window
/// is never activated**, so the only evidence available is what the log says was read.
public enum OSInlinePredictionReading: String, Equatable, Sendable, CaseIterable {
    /// The key is present and `true` — macOS's own inline prediction is on, and collides with our ghost.
    case on
    /// The key is present and `false` — the user has turned the OS feature off. The only *positive*
    /// reading there is, and therefore the only one that may claim the recommendation is satisfied.
    case off
    /// Absent, or present as a value we cannot read as a Boolean. **Not** an error: absent is the
    /// ordinary state on a Mac where nobody ever touched the setting.
    case unknown

    /// Classify a raw read. The App does the `as? Bool` bridge at the `CFPreferences` boundary and
    /// hands the result in, so a non-Bool value arrives here as `nil` — indistinguishable from absent,
    /// deliberately: both mean *we do not know*, and neither may drive behaviour (soft use only).
    public static func reading(of rawValue: Bool?) -> OSInlinePredictionReading {
        guard let rawValue else { return .unknown }
        return rawValue ? .on : .off
    }
}

/// What the **persistent** Settings → Setup row should display for that reading.
///
/// The raw values are greppable log tokens for the same reason as above.
public enum InlinePredictionAdvisory: String, Equatable, Sendable, CaseIterable {
    /// Show the row, unsatisfied: macOS inline prediction is on and should be turned off.
    case actionNeeded = "action-needed"
    /// Show the row, satisfied: the OS feature is off and our advice has been followed.
    case satisfied
    /// Show the row with a neutral badge and the "Turn off for me" button: the key is absent or
    /// unreadable, so the state is unknown.
    case offerTurnOff = "offer-turn-off"
    /// Show **nothing at all**. Only the model's initial value before the first read.
    case hidden
}

public enum InlinePredictionStatus {
    /// The persistent row's verdict.
    ///
    /// `.unknown` shows the row without an "Action needed" claim. The old reason to hide it was a
    /// permanent "Action needed" that no user action could clear after Apple renamed the key. The
    /// button clears that state, because it writes `false` and the next read says `.off`. The badge
    /// stays neutral, since we do not know whether the OS feature is on.
    public static func advisory(for reading: OSInlinePredictionReading) -> InlinePredictionAdvisory {
        switch reading {
        case .on:      .actionNeeded
        case .off:     .satisfied
        case .unknown: .offerTurnOff
        }
    }

    /// Whether the one-time first-run nudge should be shown for that reading (given it has not been
    /// shown before — that guard is the App's).
    ///
    /// Unchanged: **absent ⇒ enabled ⇒ present**. It lives here next to `advisory` so the
    /// two readings of the one key are decided in one place and cannot drift into disagreeing about
    /// what was read — only, deliberately, about what to do with an unknown.
    public static func nudgeShouldPresent(for reading: OSInlinePredictionReading) -> Bool {
        reading != .off
    }
}

/// Which button the Settings → Setup row offers.
public enum InlinePredictionToggleAction: String, Equatable, Sendable {
    case turnOff = "turn-off"
    case turnBackOn = "turn-back-on"
}

extension InlinePredictionStatus {
    /// `.off` offers the way back. `.on` offers the switch. `.unknown` also offers the switch, because
    /// absent means the macOS default, which is enabled; the row shows for `.unknown` too
    /// (see `advisory`).
    public static func toggleAction(for reading: OSInlinePredictionReading) -> InlinePredictionToggleAction {
        reading == .off ? .turnBackOn : .turnOff
    }
}

/// The global preferences domain, as far as this feature needs it. The App implements it with
/// `CFPreferences` against `kCFPreferencesAnyApplication`; tests fake it.
public protocol OSInlinePredictionStore: Sendable {
    /// One fresh read of `NSAutomaticInlinePredictionEnabled`; `nil` when absent or not a Boolean.
    func readValue() -> Bool?
    /// Writes the key and flushes it to disk and to other processes' preference daemon.
    func writeValue(_ newValue: Bool)
}

/// What a click on the button achieved, judged by reading the key back.
public enum OSInlinePredictionSwitchResult: Equatable, Sendable {
    /// The read-back shows the requested state.
    case changed(OSInlinePredictionReading)
    /// The write did not stick (a managed Mac, for example). The row falls back to the manual steps.
    case notApplied(stillReading: OSInlinePredictionReading)
}

/// The one place NextTyped writes the undocumented global key.
/// It runs only from a user click, never automatically, and it verifies every write by reading it back.
public struct OSInlinePredictionSwitch: Sendable {
    private let store: any OSInlinePredictionStore
    public init(store: any OSInlinePredictionStore) { self.store = store }

    public func turnOff() -> OSInlinePredictionSwitchResult { apply(enabled: false) }
    public func turnBackOn() -> OSInlinePredictionSwitchResult { apply(enabled: true) }

    private func apply(enabled: Bool) -> OSInlinePredictionSwitchResult {
        let wanted: OSInlinePredictionReading = enabled ? .on : .off
        if OSInlinePredictionReading.reading(of: store.readValue()) != wanted {
            store.writeValue(enabled)
        }
        let after = OSInlinePredictionReading.reading(of: store.readValue())
        return after == wanted ? .changed(after) : .notApplied(stillReading: after)
    }
}
