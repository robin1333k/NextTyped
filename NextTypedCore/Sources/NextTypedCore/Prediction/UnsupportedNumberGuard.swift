/// Output gate against invented numbers and dates. A base model completing "Der Termin
/// ist am" happily writes "14. Mai 2024" although nothing in the document says so. In the quality-gap
/// probe 7 of 40 real-app ghosts and 8 of 40 offline ghosts carried such a number.
/// None of the 40 true continuations contained a digit, so the guard costs no accepted word.
///
/// A token is **unsupported** when it is
///   - a digit run that does not occur as a whole digit run in the support text, or
///   - a month or weekday name (English or German) that does not occur as a word in the support text.
/// The continuation is cut before the first unsupported token. If no word character is left, the
/// ghost is suppressed. The support text is the prefix plus the front's context segments (window,
/// reply, clipboard, OCR, personalization), because the model may quote any of them.
///
/// Two deliberate choices:
///   - Month and weekday names count only when capitalised. "may", "march" and "sun" are ordinary
///     lowercase words in English. German names are nouns and always capitalised.
///   - A day number of one or two digits, optionally followed by a period, passes when the very next
///     word is a month name that the support text contains ("am 3. März" after a prefix with "März").
///     The month is the anchor; the day is the ordinary way to write it.
///
/// A token that straddles the caret (prefix ends in "20", ghost starts "24") is judged as the whole
/// token, so a half-typed number is not waved through.
public enum UnsupportedNumberGuard {
    public enum Action: Equatable, Sendable {
        case trimmed
        case suppressed
    }

    public struct Verdict: Equatable, Sendable {
        /// The continuation to use: unchanged, cut before the unsupported token, or `""`.
        public var text: String
        /// `nil` when nothing was changed. Logged as `[gate]: unsupported-number <action>`.
        public var action: Action?

        public init(text: String, action: Action? = nil) {
            self.text = text
            self.action = action
        }
    }

    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december",
        "januar", "februar", "märz", "mai", "juni", "juli", "oktober", "dezember",
    ]

    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag", "sonnabend", "sonntag",
    ]

    private enum Kind { case digits, letters }

    private struct Token {
        let kind: Kind
        let text: String
        /// Character offset of the token start within `tail + continuation`.
        let start: Int
        let end: Int
    }

    public static func apply(to continuation: String, textBeforeCaret: String,
                             supportingText: [String] = []) -> Verdict {
        guard !continuation.isEmpty else { return Verdict(text: continuation) }

        // The word fragment already typed, so a token that straddles the caret is judged whole.
        let tail = String(textBeforeCaret.reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
        let chars = Array(tail + continuation)
        let tailCount = tail.count
        let tokens = tokenize(chars)

        // Only tokens that reach into the continuation can be cut.
        let candidates = tokens.filter { $0.end > tailCount && isCandidate($0) }
        guard !candidates.isEmpty else { return Verdict(text: continuation) }

        let support = SupportIndex(texts: [textBeforeCaret] + supportingText)

        for (index, token) in tokens.enumerated() where token.end > tailCount && isCandidate(token) {
            if isSupported(token, at: index, in: tokens, support: support) { continue }
            let cut = max(token.start, tailCount) - tailCount
            let kept = String(continuation.prefix(cut))
            let trimmed = String(kept.reversed().drop { $0.isWhitespace }.reversed())
            if SuggestionValueGate.isRenderable(trimmed) {
                return Verdict(text: trimmed, action: .trimmed)
            }
            return Verdict(text: "", action: .suppressed)
        }
        return Verdict(text: continuation)
    }

    // MARK: Tokens

    private static func tokenize(_ chars: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let kind: Kind? = chars[i].isNumber && chars[i].isASCII ? .digits
                : (chars[i].isLetter ? .letters : nil)
            guard let kind else { i += 1; continue }
            var j = i
            while j < chars.count, matches(chars[j], kind) { j += 1 }
            tokens.append(Token(kind: kind, text: String(chars[i..<j]), start: i, end: j))
            i = j
        }
        return tokens
    }

    private static func matches(_ c: Character, _ kind: Kind) -> Bool {
        switch kind {
        case .digits: return c.isNumber && c.isASCII
        case .letters: return c.isLetter
        }
    }

    private static func isCandidate(_ token: Token) -> Bool {
        switch token.kind {
        case .digits: return true
        case .letters: return isDateName(token.text)
        }
    }

    /// Capitalised only (see the type comment).
    private static func isDateName(_ word: String) -> Bool {
        guard let first = word.first, first.isUppercase else { return false }
        let lower = word.lowercased()
        return months.contains(lower) || weekdays.contains(lower)
    }

    private static func isSupported(_ token: Token, at index: Int, in tokens: [Token],
                                    support: SupportIndex) -> Bool {
        switch token.kind {
        case .letters:
            return support.words.contains(token.text.lowercased())
        case .digits:
            if support.digitRuns.contains(token.text) { return true }
            // Day number anchored by a supported month: "3. März".
            if token.text.count <= 2, index + 1 < tokens.count {
                let next = tokens[index + 1]
                if next.kind == .letters, isDateName(next.text),
                   support.words.contains(next.text.lowercased()),
                   next.start - token.end <= 2 {
                    return true
                }
            }
            return false
        }
    }

    private struct SupportIndex {
        var digitRuns: Set<String> = []
        var words: Set<String> = []

        init(texts: [String]) {
            for text in texts {
                for token in tokenize(Array(text)) {
                    switch token.kind {
                    case .digits: digitRuns.insert(token.text)
                    case .letters: words.insert(token.text.lowercased())
                    }
                }
            }
        }
    }
}
