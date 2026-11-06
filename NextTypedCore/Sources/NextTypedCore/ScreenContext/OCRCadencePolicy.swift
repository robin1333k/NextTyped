import Foundation

/// **When OCR is allowed to run** — a pure, time-free decision, in the spirit of
/// `ModelResidencyPolicy`: the App owns the clock and the system event sources, this owns the
/// rules and is unit-tested by feeding it timestamps.
///
/// Why a policy rather than a timer: a full-screen `.accurate` Vision pass costs **0.3–1.0 s** and
/// *periodic* whole-screen OCR is a measured **20–40 % battery** hog. So a pass has to earn itself:
///   - only while the user is actually **writing** (ModelResidency's prediction-relevant activity),
///   - at most once per **throttle** window per surface,
///   - refreshed by a **TTL** backstop (scrolling and video fire no focus event),
///   - **hard off** while the screen is locked or a display/the system is asleep — privacy *and* there
///     is nothing useful to read,
///   - **skipped** under Low Power Mode and at thermal `.serious`+.
///
/// Everything here is advisory to the *proactive* path only. The predict path never consults it: it
/// reads the last cached text synchronously and never awaits a pass ("strictly off-path").
public enum OCRCadencePolicy {
    /// Timing constants. Measured-later placeholders, grouped so tuning is a
    /// value edit rather than a logic edit.
    public struct Timing: Equatable, Sendable {
        /// Quiet period after the last keystroke before a pass may fire, so OCR never competes with
        /// the first-paint budget mid-burst.
        public var idleDebounce: TimeInterval
        /// Minimum spacing between passes for the same surface.
        public var throttle: TimeInterval
        /// Age at which cached text is stale even without any focus event.
        public var ttl: TimeInterval
        /// Throttle used when the machine asks us to back off (Low Power / thermal pressure).
        public var constrainedThrottle: TimeInterval

        public init(
            idleDebounce: TimeInterval = 0.5,
            throttle: TimeInterval = 15,
            ttl: TimeInterval = 45,
            constrainedThrottle: TimeInterval = 120
        ) {
            self.idleDebounce = idleDebounce
            self.throttle = throttle
            self.ttl = ttl
            self.constrainedThrottle = constrainedThrottle
        }

        public static let `default` = Timing()
    }

    /// The machine's willingness to spend energy right now.
    public enum PowerState: Equatable, Sendable {
        case normal
        /// Low Power Mode, or thermal state `.serious`/`.critical` — lengthen the throttle.
        case constrained
        /// Screen locked, display asleep, or the system going to sleep — no pass at all.
        case off
    }

    /// Everything the decision needs, as plain values.
    public struct Input: Sendable {
        /// OCR is enabled in Settings *and* Screen Recording is granted.
        public var enabled: Bool
        /// The focused app is not switched off in the per-app policy (the (a) half of the
        /// coupled per-app switch: an app turned off gets no OCR while it is focused).
        public var appAllowed: Bool
        /// A focused secure text field suppresses the whole capture (scrub-chain guard (ii)).
        public var focusedFieldIsSecure: Bool
        public var power: PowerState
        /// When the user last did something prediction-relevant. `nil` = no writing activity yet.
        public var lastActivityAt: TimeInterval?
        /// When the last pass for this surface completed. `nil` = never.
        public var lastPassAt: TimeInterval?
        /// True on a fresh surface (focus moved into a different writing window) — the case the
        /// throttle must not block, or the first prediction in every new context arrives without
        /// context (the reason a lazy serve-stale cadence was rejected).
        public var isNewSurface: Bool
        public var now: TimeInterval

        public init(
            enabled: Bool,
            appAllowed: Bool = true,
            focusedFieldIsSecure: Bool = false,
            power: PowerState = .normal,
            lastActivityAt: TimeInterval?,
            lastPassAt: TimeInterval?,
            isNewSurface: Bool,
            now: TimeInterval
        ) {
            self.enabled = enabled
            self.appAllowed = appAllowed
            self.focusedFieldIsSecure = focusedFieldIsSecure
            self.power = power
            self.lastActivityAt = lastActivityAt
            self.lastPassAt = lastPassAt
            self.isNewSurface = isNewSurface
            self.now = now
        }
    }

    /// Why a pass was or wasn't run — carried into the DEBUG log so runtime cadence is measurable
    /// rather than inferred (the same discipline as `PrefixReuse.rebuildCause`). The raw values double
    /// as greppable log tokens.
    public enum Decision: String, Equatable, Sendable {
        case runNewSurface = "run(new-surface)"
        case runStale = "run(ttl)"
        case runIdle = "run(idle)"
        case skipDisabled = "skip(disabled)"
        case skipAppOff = "skip(app-off)"
        case skipSecureField = "skip(secure-field)"
        case skipPowerOff = "skip(power-off)"
        case skipNoActivity = "skip(no-activity)"
        case skipTyping = "skip(typing)"
        case skipThrottled = "skip(throttled)"

        public var shouldRun: Bool {
            switch self {
            case .runNewSurface, .runStale, .runIdle: return true
            default: return false
            }
        }
    }

    /// Decide whether a capture+OCR pass may run now.
    public static func decide(_ input: Input, timing: Timing = .default) -> Decision {
        guard input.enabled else { return .skipDisabled }
        guard input.appAllowed else { return .skipAppOff }
        // Guard (ii) of the scrub-chain: a focused password field suppresses the WHOLE capture, not
        // just that window — the pixels of a filled password field can land anywhere on screen.
        guard !input.focusedFieldIsSecure else { return .skipSecureField }
        guard input.power != .off else { return .skipPowerOff }

        let throttle = input.power == .constrained ? timing.constrainedThrottle : timing.throttle
        let sinceLastPass = input.lastPassAt.map { input.now - $0 }

        // A brand-new writing surface is the one case worth paying for immediately: without it the
        // first prediction in every new context is context-less.
        if input.isNewSurface {
            if let sinceLastPass, sinceLastPass < throttle { return .skipThrottled }
            return .runNewSurface
        }

        // No writing activity at all ⇒ the user isn't composing; never spend a pass (this is what
        // makes gaming/video cost nothing).
        guard let lastActivityAt = input.lastActivityAt else { return .skipNoActivity }
        let sinceActivity = input.now - lastActivityAt
        guard sinceActivity >= timing.idleDebounce else { return .skipTyping }

        guard let sinceLastPass else { return .runIdle }
        // The TTL backstop outranks the throttle: scrolling a reference doc or a playing video fires
        // no focus event, so without it the cache would go arbitrarily stale mid-session.
        if sinceLastPass >= timing.ttl { return .runStale }
        if sinceLastPass < throttle { return .skipThrottled }
        return .runIdle
    }

    /// Whether cached OCR text is too old to serve. The predict path serves whatever is cached — this
    /// is what stops it serving something from a screen the user left ten minutes ago.
    public static func isExpired(lastPassAt: TimeInterval?, now: TimeInterval, timing: Timing = .default)
        -> Bool
    {
        guard let lastPassAt else { return true }
        return now - lastPassAt >= timing.ttl
    }
}
