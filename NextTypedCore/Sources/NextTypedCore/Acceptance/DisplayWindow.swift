/// The **sliding display window** over a continuation buffer.
///
/// The prediction engine returns the *full decoded clause* as the continuation buffer — the decode
/// safety cap (≈8 words / 60 chars) already bounds it — rather than discarding everything past the
/// visible cap as it used to (`trimToWords(…, max: 5)`). Only the first few words are *painted*; the
/// rest stay buffered so `Tab` peels them off word-by-word with **no re-inference**, and as the buffer
/// shrinks this window slides forward to reveal the once-hidden words (the old "≤5 words" cap now
/// describes this display window, not the buffer).
///
/// `windowed` returns a **true prefix** of the buffer (exact leading space and internal spacing
/// preserved, no trailing gap) — so what's shown is exactly the first characters `Tab` will insert.
/// Whitespace is the only word boundary, so English and German behave identically (no hardcoded
/// English — same rule as `WordTokenizer`).
public enum DisplayWindow {
    /// Default visible window size — the earlier display cap, now the middle step of the user-facing
    /// **Short / Medium / Long** setting (`CompletionLength`). Derived
    /// from that enum rather than repeated, so the number lives in exactly one place; the live value
    /// is threaded in by `AcceptanceStateMachine`, which holds the user's choice.
    public static let defaultMaxWords = CompletionLength.default.maxWords

    /// The first `maxWords` whitespace-delimited words of `text`, as a prefix of `text`.
    ///
    /// Keeps any significant leading-whitespace gap (the ghost is drawn one space after a flush caret)
    /// and never appends a trailing space. Returns `""` for an empty / whitespace-only buffer or a
    /// non-positive `maxWords`.
    public static func windowed(_ text: String, maxWords: Int = defaultMaxWords) -> String {
        guard maxWords > 0, !text.isEmpty else { return "" }
        var cut = text.startIndex          // end of the last fully-counted word
        var probe = text.startIndex
        var words = 0
        while probe < text.endIndex {
            // Skip the whitespace gap before the next word.
            while probe < text.endIndex, text[probe].isWhitespace { probe = text.index(after: probe) }
            guard probe < text.endIndex else { break }   // only trailing whitespace remains
            // Consume the word itself (runs up to the next whitespace).
            while probe < text.endIndex, !text[probe].isWhitespace { probe = text.index(after: probe) }
            words += 1
            cut = probe                     // include this word and its leading gap
            if words == maxWords { break }
        }
        return String(text[..<cut])
    }

    /// The window for a user-facing step. The word step shows the leading word of a buffer that has
    /// no leading gap (the rest of the word being typed) and nothing for a buffer that opens with
    /// whitespace (the next word). Every other step is `windowed(_:maxWords:)`.
    public static func windowed(_ text: String, length: CompletionLength) -> String {
        if length == .word, text.first?.isWhitespace == true { return "" }
        return windowed(text, maxWords: length.maxWords)
    }
}
