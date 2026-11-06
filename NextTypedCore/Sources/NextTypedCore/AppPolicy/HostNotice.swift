/// A notice the menu bar shows because another app interferes with our event tap (host-compat).
/// Only one shows at a time: `HostNoticeBoard` picks by `priority`.
public enum HostNotice: Equatable, Sendable {
    /// Another app holds macOS Secure Input; `SecureInputMonitor` produces it.
    case secureInputBlocked(holderName: String?)
    /// Another process leaves many disabled event taps open.
    case eventTapLeak(ownerName: String?)
    case setupHint

    public enum Kind: Int, Sendable, CaseIterable {
        case secureInputBlocked, eventTapLeak, setupHint
    }

    public var kind: Kind {
        switch self {
        case .secureInputBlocked: .secureInputBlocked
        case .eventTapLeak: .eventTapLeak
        case .setupHint: .setupHint
        }
    }

    /// Whether the notice means the loop cannot work, so a hidden menu bar icon comes back.
    /// A `setupHint` lives in the open menu only.
    public var isBlocking: Bool {
        switch self {
        case .secureInputBlocked, .eventTapLeak: true
        case .setupHint: false
        }
    }

    /// The menu line.
    public var menuText: String {
        switch self {
        case .secureInputBlocked(let name?):
            "\(name) has turned on Secure Input, so NextTyped cannot see your typing. Quit \(name), or lock and unlock your Mac."
        case .secureInputBlocked(nil):
            "Another app has turned on Secure Input, so NextTyped cannot see your typing. Quit it, or lock and unlock your Mac."
        case .eventTapLeak(let name?):
            "\(name) has left many keyboard monitors open, which can slow down your Mac. Quitting \(name) fixes it."
        case .eventTapLeak(nil):
            "Another app has left many keyboard monitors open, which can slow down your Mac. Quitting it fixes it."
        case .setupHint:
            "NextTyped needs a setup step. Open Settings."
        }
    }
}

/// The active notices in, the one to show out. Priority: Secure Input, then tap leak, then setup hint.
public struct HostNoticeBoard: Equatable, Sendable {
    private var active: [HostNotice.Kind: HostNotice] = [:]

    public init() {}

    /// Replaces the notice of the same kind.
    public mutating func raise(_ notice: HostNotice) { active[notice.kind] = notice }

    public mutating func clear(_ kind: HostNotice.Kind) { active[kind] = nil }

    /// The highest-priority active notice, or nil.
    public var current: HostNotice? {
        HostNotice.Kind.allCases.lazy.compactMap { active[$0] }.first
    }
}
