/// The app that holds Secure Input, as far as the App could resolve it. Every field can be missing:
/// Apple documents no reliable lookup, so the name is only ever what `NSRunningApplication` returned.
public struct SecureInputHolder: Equatable, Sendable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// What the App read about Secure Input at one moment. The App fills it, Core decides.
public struct SecureInputFacts: Equatable, Sendable {
    /// `IsSecureEventInputEnabled()`.
    public let enabled: Bool
    /// `kCGSSessionSecureInputPID`, read only while `enabled`. `nil` when the key is missing.
    public let holderPID: Int32?
    /// The resolved holder, or `nil` for a dead PID or a missing key.
    public let holder: SecureInputHolder?
    public let frontmostPID: Int32?
    public let focusedIsSecureField: Bool
    /// Seconds on one monotonic clock when the flag was first seen on in this hold; `nil` when off.
    public let heldSince: Double?
    public let now: Double

    public init(enabled: Bool, holderPID: Int32?, holder: SecureInputHolder?, frontmostPID: Int32?,
                focusedIsSecureField: Bool, heldSince: Double?, now: Double) {
        self.enabled = enabled
        self.holderPID = holderPID
        self.holder = holder
        self.frontmostPID = frontmostPID
        self.focusedIsSecureField = focusedIsSecureField
        self.heldSince = heldSince
        self.now = now
    }
}

public enum SecureInputVerdict: Equatable, Sendable {
    case clear
    /// The frontmost app holds it because the user sits in a password field. Nothing to tell.
    case expectedSecureField
    /// Another app holds it and our tap sees no keystrokes. `holder` is `nil` when unresolved.
    case blocked(holder: SecureInputHolder?)
}

/// Decides whether Secure Input blinds the event tap (CT-47).
public enum SecureInputPolicy {
    /// Placeholder: a hold by another app becomes `blocked` after this many seconds, so a password
    /// field in another app that is focused for a moment never raises the notice.
    public static let blockedAfterSeconds: Double = 2

    public static func verdict(_ facts: SecureInputFacts) -> SecureInputVerdict {
        guard facts.enabled else { return .clear }
        // An unresolved holder (the IORegistry key is often missing) with a secure field in the
        // frontmost app is the common password-field case, so it counts as expected too.
        if facts.focusedIsSecureField, facts.holderPID == nil || facts.holderPID == facts.frontmostPID {
            return .expectedSecureField
        }
        guard let since = facts.heldSince, facts.now - since >= blockedAfterSeconds else { return .clear }
        // Never name an app that was not resolved: a PID without an identity gives the nameless notice.
        return .blocked(holder: facts.holderPID == nil ? nil : facts.holder)
    }
}

/// A transition of the Secure Input state, one per log line (`[gate]: secure-input`,
/// `[secure-input]: cleared`, `[secure-input]: expected-secure-field`).
public enum SecureInputTransition: Equatable, Sendable {
    case enteredBlocked(holder: SecureInputHolder?)
    case leftBlocked
    case enteredExpectedSecureField
}

/// Keeps the hold start and the last verdict, so the App polls and Core reports only changes.
public struct SecureInputTracker: Sendable {
    public private(set) var verdict: SecureInputVerdict = .clear
    private var heldSince: Double?

    public init() {}

    /// `holderPID` and `focusedIsSecureField` are closures so that nothing is read while the flag is
    /// off: the IORegistry key outlives the hold and would name a stale app.
    public mutating func observe(
        enabled: Bool, now: Double, frontmostPID: Int32?,
        holderPID: () -> Int32?, resolve: (Int32) -> SecureInputHolder?,
        focusedIsSecureField: (Int32?) -> Bool
    ) -> [SecureInputTransition] {
        var pid: Int32?
        var secure = false
        if enabled {
            if heldSince == nil { heldSince = now }
            pid = holderPID()
            secure = focusedIsSecureField(pid)
        } else {
            heldSince = nil
        }
        let facts = SecureInputFacts(
            enabled: enabled, holderPID: pid, holder: pid.flatMap(resolve), frontmostPID: frontmostPID,
            focusedIsSecureField: secure, heldSince: heldSince, now: now)
        let new = SecureInputPolicy.verdict(facts)
        let old = verdict
        verdict = new
        var out: [SecureInputTransition] = []
        if case .blocked = old, !Self.isBlocked(new) { out.append(.leftBlocked) }
        switch new {
        case .blocked(let holder):
            if !Self.isBlocked(old) { out.append(.enteredBlocked(holder: holder)) }
        case .expectedSecureField:
            if old != .expectedSecureField { out.append(.enteredExpectedSecureField) }
        case .clear:
            break
        }
        return out
    }

    private static func isBlocked(_ v: SecureInputVerdict) -> Bool {
        if case .blocked = v { return true }
        return false
    }
}
