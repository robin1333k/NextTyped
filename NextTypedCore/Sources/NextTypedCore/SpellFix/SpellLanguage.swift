import Foundation

/// What a language recognizer read from a stretch of text. The spell
/// correction, the typo gate and the language off switch share it.
public struct LanguageReading: Equatable, Sendable {
    /// Top BCP-47 tag, such as `de` or `en-GB`.
    public let tag: String
    public let probability: Double
    /// Probability of the second hypothesis, 0 when there is none.
    public let runnerUpProbability: Double
    /// Letters in the text that was read.
    public let letterCount: Int

    public init(tag: String, probability: Double, runnerUpProbability: Double, letterCount: Int) {
        self.tag = tag
        self.probability = probability
        self.runnerUpProbability = runnerUpProbability
        self.letterCount = letterCount
    }
}

/// Names the language of a stretch of text. `NLLanguageRecognizer` is the App adapter; tests use a stub.
public protocol LanguageIdentifying: Sendable {
    /// The reading of `text`, or nil when there is nothing to read (no letters).
    func reading(of text: String) -> LanguageReading?
}

/// What the spell correction knows about the language of the paragraph.
/// `NSSpellChecker` given one word and no language falls back to the system language
/// and turns German typos into English words (`Strase` into `Stars`), so the correction passes the
/// detected language explicitly, or shows nothing.
public enum SpellLanguageVerdict: Equatable, Sendable {
    /// A BCP-47 base tag such as `de` or `en`.
    case language(String)
    /// The recognizer is unsure. The correction is withheld (`[gate]: spell-language-open`).
    case open
}

/// The one place the spell correction's language thresholds live.
public enum SpellLanguagePolicy {
    /// The top hypothesis must reach this probability. A first value, not measured against a corpus.
    public static let minimumProbability = 0.8

    public static func verdict(for reading: LanguageReading?) -> SpellLanguageVerdict {
        guard let reading, reading.probability >= minimumProbability else { return .open }
        return .language(baseTag(of: reading.tag))
    }

    /// `de-CH` and `de_CH` count as `de`.
    public static func baseTag(of tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(tag))
    }
}

/// Picks the text the language is read from. The word being typed is left out because the typo
/// itself would skew the verdict.
public enum SpellLanguageContext {
    /// At most this many characters are read.
    public static let tailLength = 200

    /// The current paragraph before the caret, without the word being typed. Empty at a paragraph start.
    public static func tail(of textBeforeCaret: String) -> String {
        var text = Substring(textBeforeCaret)
        if let newline = text.lastIndex(where: \.isNewline) {
            text = text[text.index(after: newline)...]
        }
        if let space = text.lastIndex(where: \.isWhitespace) {
            text = text[...space]
        } else {
            text = ""
        }
        return String(text.suffix(tailLength))
    }

    /// The text before the word being typed, across paragraph breaks. The fallback when the current
    /// paragraph is too short to read (the first word of a paragraph).
    public static func earlierText(of textBeforeCaret: String) -> String {
        var text = Substring(textBeforeCaret)
        if let boundary = text.lastIndex(where: \.isWhitespace) {
            text = text[...boundary]
        } else {
            text = ""
        }
        return String(text.suffix(tailLength))
    }
}
