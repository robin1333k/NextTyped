/// Splits text for word-by-word acceptance of a suggestion (`Tab` =
/// accept one word). Language-agnostic — whitespace is the only word boundary, so
/// English and German behave identically (no hardcoded assumptions).
public enum WordTokenizer {
    /// Peels the next "word" off the front of a suggestion, KEEPING the leading
    /// whitespace run so that repeatedly accepting words rebuilds the text exactly.
    ///
    /// Examples:
    ///   " world how"  -> (accepted: " world",  remainder: " how")
    ///   "hello there" -> (accepted: "hello",   remainder: " there")
    ///   " world, how" -> (accepted: " world,", remainder: " how")  // punctuation glued on
    ///
    /// With `holdingBackTrailingPunctuation` the peel stops before a trailing run of sentence
    /// punctuation (`., ; : ! ? …`), so `" kalt, und"` -> (accepted: " kalt", remainder: ", und")
    /// (the trailing punctuation picker). A word that is nothing but punctuation is
    /// accepted whole, which is how the held-back run gets inserted by the next press. Closing
    /// quotes and brackets are not in the set, so `kalt.")` is peeled whole.
    public static func peelNextWord(from suggestion: String,
                                    holdingBackTrailingPunctuation: Bool = false)
        -> (accepted: String, remainder: String) {
        guard !suggestion.isEmpty else { return ("", "") }
        var index = suggestion.startIndex
        // 1. Consume the leading whitespace gap before the word.
        while index < suggestion.endIndex, suggestion[index].isWhitespace {
            index = suggestion.index(after: index)
        }
        // 2. Consume the word itself (runs up to the next whitespace).
        while index < suggestion.endIndex, !suggestion[index].isWhitespace {
            index = suggestion.index(after: index)
        }
        if holdingBackTrailingPunctuation {
            index = heldBackEnd(in: suggestion, wordEnd: index)
        }
        let accepted = String(suggestion[suggestion.startIndex..<index])
        let remainder = String(suggestion[index...])
        return (accepted, remainder)
    }

    /// Splits the final punctuation run off the whole of `text` for the full accept (`⌥Tab`):
    /// `" wird kalt."` -> (head: " wird kalt", held: "."). Text that is nothing but punctuation, or
    /// has none at its end, comes back whole with an empty `held`.
    public static func splitTrailingPunctuation(from text: String) -> (head: String, held: String) {
        let cut = heldBackEnd(in: text, wordEnd: text.endIndex)
        return (String(text[..<cut]), String(text[cut...]))
    }

    /// Where an accept ends when the trailing sentence punctuation of `text` is held back: the start
    /// of the final punctuation run of the word ending at `wordEnd`, or `wordEnd` itself when the
    /// word has no such run or is nothing but punctuation.
    static func heldBackEnd(in text: String, wordEnd: String.Index) -> String.Index {
        var cut = wordEnd
        while cut > text.startIndex {
            let before = text.index(before: cut)
            guard trailingPunctuation.contains(text[before]) else { break }
            cut = before
        }
        // Leading whitespace belongs to the gap, not the word: a word made only of punctuation
        // (cut at the word's start) is accepted whole.
        var wordStart = cut
        while wordStart > text.startIndex, !text[text.index(before: wordStart)].isWhitespace {
            wordStart = text.index(before: wordStart)
        }
        return wordStart == cut ? wordEnd : cut
    }

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}"]

    /// Count of whitespace-delimited words in `text` (empties ignored).
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
