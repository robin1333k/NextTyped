/// Decides whether a *proactive* suggestion — one triggered by the caret MOVING
/// (a click or arrow key), not by typing — should be generated at the caret's
/// current position.
///
/// The rule (the "regenerate, don't discard" redesign): suppress a proactive
/// suggestion ONLY when the caret sits *strictly inside a word* — a word character
/// immediately before AND after the caret (e.g. `hel|lo`). There a "next word"
/// continuation would land mid-word and never makes sense. Everywhere else is
/// allowed: end of text/line, between words (`Laden |und`, `Laden| und`), just
/// before a word, or after punctuation.
///
/// Language-agnostic: a "word character" is any Unicode letter or number, so German
/// umlauts/ß and other scripts behave like English (no hardcoded English
/// assumption). NOTE: this gate only decides *whether* to generate. Whether a mid-text
/// insertion can be generated *well* is a separate FIM concern, feature-flagged App-side
/// until a fill-in-the-middle model is wired.
public enum CaretPositionGate {
    /// - Parameters:
    ///   - before: the character immediately left of the caret, or `nil` at the start of the field.
    ///   - after: the character immediately right of the caret, or `nil` at the end of the field.
    /// - Returns: `true` if a proactive suggestion may be generated here.
    public static func allowsProactiveSuggestion(before: Character?, after: Character?) -> Bool {
        // Suppressed only when BOTH sides are word characters — i.e. strictly inside a word.
        guard let before, before.isWordCharacter,
              let after, after.isWordCharacter
        else { return true }
        return false
    }

    /// Convenience over a `TypingContext`: the char before the caret is the last of
    /// `textBeforeCaret`, the char after is the first of `textAfterCaret`.
    public static func allowsProactiveSuggestion(in context: TypingContext) -> Bool {
        allowsProactiveSuggestion(before: context.textBeforeCaret.last,
                                  after: context.textAfterCaret.first)
    }
}

extension Character {
    /// A "word character" for caret-position classification: any Unicode letter or
    /// number. Whitespace, punctuation and symbols are NOT word characters.
    var isWordCharacter: Bool { isLetter || isNumber }
}
