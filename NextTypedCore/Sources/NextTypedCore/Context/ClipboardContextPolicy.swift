import Foundation

/// What the App's pasteboard adapter observed, as plain values. No clock and no AppKit enter Core
/// : the adapter measures the **first-seen age** (how long ago it first noticed this
/// `changeCount`) and passes it in as a number.
public struct ClipboardSnapshot: Equatable, Sendable {
    /// The `clipboardContextEnabled` opt-in. Absent key means `false`.
    public var enabled: Bool
    /// The OS refused pasteboard access (`NSPasteboard.accessBehavior`); the adapter never reads then.
    public var osAccessDenied: Bool
    public var changeCount: Int
    /// Milliseconds since the App first saw this `changeCount`.
    public var firstSeenAgeMs: Int
    /// The item carries `org.nspasteboard.ConcealedType` (password managers).
    public var isConcealed: Bool
    /// The item carries `org.nspasteboard.TransientType`.
    public var isTransient: Bool
    public var hasText: Bool
    public var text: String

    public init(enabled: Bool, osAccessDenied: Bool = false, changeCount: Int = 0,
                firstSeenAgeMs: Int = 0, isConcealed: Bool = false, isTransient: Bool = false,
                hasText: Bool = true, text: String = "") {
        self.enabled = enabled
        self.osAccessDenied = osAccessDenied
        self.changeCount = changeCount
        self.firstSeenAgeMs = firstSeenAgeMs
        self.isConcealed = isConcealed
        self.isTransient = isTransient
        self.hasText = hasText
        self.text = text
    }
}

public enum ClipboardVerdict: Equatable, Sendable {
    /// The scrubbed, head-capped text that may enter the prompt front.
    case inject(String)
    case skip(Reason)

    /// Skip reasons, in the order the policy checks them. The raw values are the DEBUG
    /// `[clip]: skip reason=<raw>` tokens.
    public enum Reason: String, CaseIterable, Equatable, Sendable {
        case off
        case osDenied = "os-denied"
        case concealed
        case transient
        case stale
        case nonText = "non-text"
        case empty
        case inDocument = "in-document"
    }
}

/// Whether clipboard text may enter the prompt (clipboard context, opt-in, activity-scoped by the
/// first-seen age). Pure: the App reads the pasteboard on the predict
/// path only and hands the result here.
public enum ClipboardContextPolicy {
    /// Clipboard text enters the prompt only while its first-seen age is under this many milliseconds.
    /// A measured-later placeholder, like the screen-context cadence constants.
    public static let maxAgeMs = 120_000

    /// Head-cap of the injected text, in characters. A measured-later placeholder.
    public static let headCapChars = 600

    /// The clipboard has no size bound, so the work below never touches more than this many
    /// characters (after leading whitespace) of it. Four times the cap leaves room for the scrub
    /// and the trailing trim to shrink the head and still fill `headCapChars`.
    public static let boundedHeadChars = headCapChars * 4

    public static func verdict(
        snapshot: ClipboardSnapshot, prefix: String, windowContext: String?
    ) -> ClipboardVerdict {
        guard snapshot.enabled else { return .skip(.off) }
        guard !snapshot.osAccessDenied else { return .skip(.osDenied) }
        guard !snapshot.isConcealed else { return .skip(.concealed) }
        guard !snapshot.isTransient else { return .skip(.transient) }
        // Age before content, as in `mayReadContent`: a stale copy is never read, so the adapter
        // passes hasText:true with empty text, and that must log `stale`, not `empty`.
        guard snapshot.firstSeenAgeMs < maxAgeMs else { return .skip(.stale) }
        guard snapshot.hasText else { return .skip(.nonText) }
        // Bounded head first: only `headCapChars` can reach the prompt, and this runs on the typing
        // path. The in-document check below compares this head, not the full clipboard.
        let head = String(snapshot.text.drop(while: { $0.isWhitespace || $0.isNewline })
            .prefix(boundedHeadChars))
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skip(.empty) }
        if prefix.contains(trimmed) || (windowContext?.contains(trimmed) ?? false) {
            return .skip(.inDocument)
        }
        let kept = String(SensitiveTextScrub.scrub(trimmed).prefix(headCapChars))
        return .inject(kept)
    }
}

extension ClipboardContextPolicy {
    /// Whether the adapter may read the pasteboard **content** at all. The same checks as `verdict`
    /// that need no content, in the same order, so the adapter never touches the string when the
    /// verdict is already decided (the macOS 27 paste-permission alert fires on a content read, not
    /// on `changeCount`).
    public static func mayReadContent(
        enabled: Bool, osAccessDenied: Bool, isConcealed: Bool, isTransient: Bool,
        firstSeenAgeMs: Int
    ) -> Bool {
        enabled && !osAccessDenied && !isConcealed && !isTransient && firstSeenAgeMs < maxAgeMs
    }
}

extension ClipboardVerdict {
    /// The DEBUG `[clip]:` line for one predict. Carries the length and the age, never the text.
    public func logLine(ageMs: Int) -> String {
        switch self {
        case .inject(let text): return "[clip]: inject chars=\(text.count) age=\(ageMs)"
        case .skip(let reason): return "[clip]: skip reason=\(reason.rawValue)"
        }
    }
}

/// Tracks when the App first saw each pasteboard `changeCount`. Reading the count does not read
/// content, so the age of a copy is measured from the first predict that noticed it. Pure: the caller
/// passes the clock in.
public struct ClipboardAgeTracker: Equatable, Sendable {
    private var lastCount: Int?
    private var firstSeenMs: Int = 0

    public init() {}

    public mutating func firstSeenAgeMs(changeCount: Int, nowMs: Int) -> Int {
        if lastCount != changeCount {
            lastCount = changeCount
            firstSeenMs = nowMs
        }
        return max(0, nowMs - firstSeenMs)
    }
}
