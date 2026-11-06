/// How much of the decoded continuation buffer the ghost shows — the user-facing **Short / Medium /
/// Long** setting, expressed as a display-window size in words.
///
/// Four *named steps* (Short, Medium, Long and the word-only step), not a raw word count: the stored preference records the step the user chose,
/// so re-tuning what a step means (3/5/8 today) does not invalidate what is already persisted.
///
/// The whole range fits inside what is **already decoded** — `predict()` returns an 8-word buffer
/// (the decode safety cap) and Core paints a window of it, so this changes only how much
/// of an existing clause is visible: no extra decode steps, no latency change, no interaction with
/// clause-stop, and `Tab`-accept is untouched because it always peels from the full buffer.
///
/// The window is a **ceiling, never a target**: `DisplayWindow.windowed` cuts after the last real
/// word, so a 3-word buffer renders in full at every setting — nothing pads.
public enum CompletionLength: String, CaseIterable, Sendable {
    case short
    case medium
    case long
    /// Finishes the word being typed and never proposes the next one. The window is the
    /// remainder of the current word (`DisplayWindow.windowed(_:length:)`), a prefix at a word
    /// boundary shows nothing (`allowsContinuation`). The decode buffer is unchanged.
    case word

    /// The "≤5 words" setting is `.medium`; `.long` is the decode cap itself, so the window can reveal
    /// the whole buffer without ever asking for another token.
    public var maxWords: Int {
        switch self {
        case .short: return 3
        case .medium: return 5
        case .long: return 8
        case .word: return 1
        }
    }

    /// The shipping default — the length the product had before this became a setting.
    public static let `default` = CompletionLength.medium

    /// Read a persisted value fail-safe: an absent, misspelled or retired step falls back to the
    /// default rather than leaving the ghost at some unexpected length.
    public init(stored: String?) {
        self = stored.flatMap(CompletionLength.init(rawValue:)) ?? .default
    }

    /// Whether a continuation may show for this prefix. Only the word step refuses: it proposes the
    /// rest of the word being typed, so a prefix that is empty or ends in whitespace has none.
    public func allowsContinuation(textBeforeCaret: String) -> Bool {
        guard self == .word else { return true }
        guard let last = textBeforeCaret.last else { return false }
        return !last.isWhitespace
    }
}
