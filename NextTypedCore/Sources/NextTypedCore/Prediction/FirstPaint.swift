/// **First-paint streaming**: the part of a running decode
/// that may be painted before the decode ends.
///
/// The decode loop asks this after every token. Once the first `words` words are finished (a later word
/// has started, so none of them can still grow), the engine hands them out once; the reducer paints
/// them, and the full decode replaces them when it lands. Everything a final decode may still decide
/// about the leading words stays with the final decode: a newline (running-thought arm 2), a finished
/// clause, a `<think>` block. In those cases nothing is cut early.
public enum FirstPaint {

    /// How many words the early paint carries: the Short display window.
    public static let words = CompletionLength.short.maxWords

    /// The early ghost text for the decode so far, or `nil` while it is not yet safe or not worth
    /// cutting. `wordCap` is the decode's own cap: at or below `words` the full decode ends where the
    /// early one would, so there is nothing to stream.
    public static func firstWords(inDecode decoded: String, wordCap: Int) -> String? {
        guard wordCap > words else { return nil }
        guard !decoded.contains(where: \.isNewline), !decoded.contains("<think") else { return nil }
        guard ClauseStop.firstClause(decoded) == nil else { return nil }
        // More than `words` space-separated words means word `words + 1` has started.
        guard decoded.split(separator: " ").count > words else { return nil }
        return ClauseStop.trimToWords(decoded, max: words)
    }
}
