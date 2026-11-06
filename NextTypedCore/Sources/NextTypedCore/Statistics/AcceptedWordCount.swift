/// How many words an *accept* actually inserted — the one counting rule
/// behind the "words accepted" figure, kept pure so the definition is testable instead of implied by
/// where the App happened to put a `+= 1`.
///
/// Three exclusions are the whole point, because each of them would inflate the number with something
/// that is not a completion the user took:
///
/// - **A type-along advance is not an accept.** It produces no write effect at all — the host inserts the
///   character the user typed — so it cannot reach this function.
/// - **A correction is not an accept.** `Tab` applies a pending spell fix with the *same* effect shape a
///   space-consuming continuation accept uses (`.replace`), so the shapes cannot be told apart; the
///   presentation that was on screen when the key was pressed can (correction › continuation),
///   and that is what this takes.
/// - **Punctuation is not a word.** A continuation opening with `". "` inserts a boundary, not a word
/// , so a token needs at least one letter or digit to count.
public enum AcceptedWordCount {
    /// Words inserted by the effects an accept key returned, given what was on screen when it was pressed.
    ///
    /// Counting from the *effects* rather than from the ghost is deliberate: the accept may insert
    /// something the ghost did not literally show — a FIM terminal join adds a separator, a
    /// space-consuming accept rewrites the preceding character — and what the statistic claims is what was written into the document.
    public static func inEffects(_ effects: [Effect], showing presentation: Presentation) -> Int {
        guard case .continuation = presentation else { return 0 }
        return effects.reduce(0) { total, effect in
            switch effect {
            case .insert(let text):            return total + words(in: text)
            case .replace(_, let replacement): return total + words(in: replacement)
            default:                           return total
            }
        }
    }

    /// Whitespace-delimited tokens carrying at least one word character. Language-agnostic, like
    /// `WordTokenizer` — German and English count identically.
    public static func words(in text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }
}
