/// A continuation split for display: the head painted inline after the caret, and the overflow
/// painted in the below-line bubble.
public struct ContinuationParts: Equatable, Sendable {
    /// The leading words that fit on the caret line's remaining width — rendered inline as a SINGLE
    /// line that never wraps. Keeps the engine's leading space (it separates the ghost from the word
    /// being typed).
    public let inline: String
    /// The words that don't fit — rendered in the bubble below, at the line's left margin. Without a
    /// leading space: the bubble draws on its own chip, where a leading space is only a gap.
    public let overflow: String

    public init(inline: String, overflow: String) {
        self.inline = inline
        self.overflow = overflow
    }
}

/// Splitting a continuation between the inline head and the bubble overflow
/// .
///
/// This is a **display** split, not a buffer change — exactly the `DisplayWindow` relationship of
/// the acceptance buffer stays the one whole continuation, so `Tab` keeps peeling words
/// across the inline→bubble boundary without knowing the split exists.
///
/// The App measures how many leading words fit (font metrics aren't pure); the *string* arithmetic —
/// where to cut, which side keeps the leading space — lives here so it is unit-testable.
public enum ContinuationSplit {
    /// Split `text` after its first `fittingWords` space-delimited words.
    ///
    /// `fittingWords <= 0` puts everything in the overflow; a count at or past the word count leaves
    /// no overflow. Newlines are already flattened to spaces upstream (`ClauseStop`), so splitting on
    /// space suffices; runs of spaces collapse rather than producing empty words.
    public static func split(_ text: String, fittingWords: Int) -> ContinuationParts {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return ContinuationParts(inline: "", overflow: "") }

        let count = min(max(fittingWords, 0), words.count)
        let head = words.prefix(count).joined(separator: " ")
        let tail = words.dropFirst(count).joined(separator: " ")
        let inline = head.isEmpty ? "" : (text.hasPrefix(" ") ? " " + head : head)
        return ContinuationParts(inline: inline, overflow: tail)
    }
}
