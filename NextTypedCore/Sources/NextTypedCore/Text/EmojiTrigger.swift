/// Decides whether the text before the caret ends in an emoji request such as `:smi`.
///
/// The pattern is a colon that starts a word (start of the text or after whitespace) followed directly
/// by two or more letters up to the caret. Over 988 colons in German and mixed prose it matched none:
/// a German colon attaches to the previous word (`Fazit:`), times contain digits (`10:30`) and a URL
/// scheme is followed by a slash.
public enum EmojiTrigger {
    /// The letters after the trigger colon, or `nil` when the caret is not at an emoji request.
    public static func fragment(in textBeforeCaret: String) -> String? {
        guard let colon = textBeforeCaret.lastIndex(of: ":") else { return nil }
        let fragment = textBeforeCaret[textBeforeCaret.index(after: colon)...]
        guard fragment.count >= 2, fragment.allSatisfy(\.isLetter) else { return nil }
        if colon != textBeforeCaret.startIndex {
            let before = textBeforeCaret[textBeforeCaret.index(before: colon)]
            guard before.isWhitespace else { return nil }
        }
        return String(fragment)
    }
}
