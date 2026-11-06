/// Which accept keys insert a suggestion's trailing punctuation together with the last word, the
/// **trailing punctuation picker** under Settings → Shortcuts.
///
/// Punctuation a key leaves out is not lost. It stays in the buffer as the ghost's remainder, and the
/// next press of either key inserts it (`Tab` and `⌥Tab` always accept a punctuation-only remainder).
/// Stored as the **named case**, like `CompletionLength`, so an absent or retired value reads as the
/// shipping behaviour.
public enum TrailingPunctuation: String, CaseIterable, Sendable {
    /// `Tab` and `⌥Tab` both insert the punctuation with the word. The shipping behaviour.
    case bothShortcuts
    /// Only `⌥Tab` (the full accept) inserts it; `Tab` stops before it.
    case fullAcceptOnly
    /// Neither key inserts it with the word; the next press does.
    case neither

    public static let `default` = TrailingPunctuation.bothShortcuts

    public init(stored: String?) {
        self = stored.flatMap(TrailingPunctuation.init(rawValue:)) ?? .default
    }

    /// Whether the word peel (`Tab`) stops before a punctuation-shaped end.
    public var holdsBackOnWordAccept: Bool { self != .bothShortcuts }

    /// Whether the full accept (`⌥Tab`) stops before a punctuation-shaped end.
    public var holdsBackOnFullAccept: Bool { self == .neither }
}
