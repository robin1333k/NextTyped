import Foundation

/// Launch-time configuration for the runtime harness. Read **once** from the
/// process environment, so a harness run can never leave a poisoned state behind: the variables die
/// with the process, and nothing here is persisted. Takes precedence over the matching `UserDefaults`
/// keys (which keep working underneath — scenarios exercise the same keys a user sets).
///
/// Release builds ignore the environment entirely (`#if DEBUG`), so a shipping binary has no harness
/// surface at all — the zero-telemetry commitment is untouched.
///
/// Variables (all `NEXTTYPED_*`):
/// - `NEXTTYPED_ENGINE=fake|real` — which `PredictionEngine` the coordinator builds (default real).
/// - `NEXTTYPED_HARNESS_SOCKET=<path>` — start the DEBUG query channel at this UNIX-socket path.
/// - `NEXTTYPED_PERSONALIZATION=off|temp` — force style-profile capture off (the harness default
///   whenever the socket is set), or use a throwaway profile file + Keychain tag (`temp`).
/// - `NEXTTYPED_OCR=off` — force screen-context OCR off.
/// - (no variable) with the socket set, the per-app **learning denylist** is neutralised — see
///   `neutralisesLearningDenylist`; `NEXTTYPED_LEARNING_DENYLIST=user` opts back out.
/// - `NEXTTYPED_SUPPRESS_ONBOARDING=1` — never show the permission/nudge windows.
enum HarnessEnvironment {
    enum Engine: String { case fake, real }
    enum Personalization: String { case off, temp, user }

    static var isActive: Bool { socketPath != nil }

    static var engine: Engine {
        #if DEBUG
        return Engine(rawValue: value("NEXTTYPED_ENGINE") ?? "") ?? .real
        #else
        return .real
        #endif
    }

    static var socketPath: String? {
        #if DEBUG
        return value("NEXTTYPED_HARNESS_SOCKET")
        #else
        return nil
        #endif
    }

    /// Personalization posture. With the socket set and nothing else said, capture is **off** — a harness
    /// run types real sentences, and those must never be learned into the user's profile.
    static var personalization: Personalization {
        #if DEBUG
        if let raw = value("NEXTTYPED_PERSONALIZATION"), let p = Personalization(rawValue: raw) { return p }
        return isActive ? .off : .user
        #else
        return .user
        #endif
    }

    /// Under the harness the per-app **learning denylist** is neutralised. It is a
    /// `UserDefaults` preference the harness does not control, and a machine where the fixture host is
    /// denylisted fails the personalization scenarios for a reason that has nothing to do with the
    /// product — capture never starts, so `commit()` reaches its guard with an empty buffer and even the
    /// `[style]: discard` line is skipped. Safe because the run's text cannot reach the user's profile
    /// anyway: `personalization` is `.off` unless a scenario opted into a throwaway profile + Keychain
    /// tag (`.temp`). Same treatment the posture already gets — env wins, `UserDefaults` keeps working
    /// underneath for every non-harness launch.
    ///
    /// `NEXTTYPED_LEARNING_DENYLIST=user` opts back out, keeping the user's denylist live. That exists
    /// for exactly one reason: without it the `[style]: capture blocked` line this ticket added could
    /// never execute in a run, and an unexercised code path is what `FIMAccept.terminalJoin` was before
    /// it got a call site.
    static var neutralisesLearningDenylist: Bool {
        #if DEBUG
        return isActive && value("NEXTTYPED_LEARNING_DENYLIST") != "user"
        #else
        return false
        #endif
    }

    static var ocrForcedOff: Bool {
        #if DEBUG
        return value("NEXTTYPED_OCR") == "off" || isActive
        #else
        return false
        #endif
    }

    static var suppressOnboarding: Bool {
        #if DEBUG
        return value("NEXTTYPED_SUPPRESS_ONBOARDING") == "1" || isActive
        #else
        return false
        #endif
    }

    private static func value(_ key: String) -> String? {
        guard let v = ProcessInfo.processInfo.environment[key], !v.isEmpty else { return nil }
        return v
    }
}
