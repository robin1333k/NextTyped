import Foundation

/// What the Privacy row for clipboard context shows. The row must never look
/// switched on while macOS blocks the read, so "on" and "blocked" are different states.
public enum ClipboardRowState: Equatable, Sendable {
    case off
    case on
    case blockedByOS

    /// `enabled` is the `clipboardContextEnabled` key; `osDenied` is `NSPasteboard.accessBehavior ==
    /// .alwaysDeny`. A switch that is off is off, whatever macOS says: nothing is read either way.
    public static func resolve(enabled: Bool, osDenied: Bool) -> ClipboardRowState {
        guard enabled else { return .off }
        return osDenied ? .blockedByOS : .on
    }

    /// The disclosure facts, word for word what the Privacy pane shows.
    public static let disclosure: [(label: String, text: String)] = [
        ("Reads", "The text you copied in the last 2 minutes, only while you type. Skipped when a "
                  + "password manager marks the copy as secret."),
        ("Kept", "Used for the current completion, then discarded. Never stored, never learned from."),
    ]
}
