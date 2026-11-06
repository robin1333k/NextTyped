import Foundation

/// Which languages a user switched off.
public enum LanguageSelector: Sendable, Hashable {
    /// One language, compared on the base subtag (`.tag("de")` also matches `de-CH`).
    case tag(String)
    /// Every language, whatever its tag.
    case allOthers
}

/// Why a reading was too weak to decide anything. The raw value is the `[gate]: language-open` token.
public enum LanguageOpenReason: String, Sendable, Equatable {
    /// Fewer than ``LanguagePolicy/minimumLetters`` letters, or no reading.
    case short
    /// The top candidate is below ``LanguagePolicy/minimumConfidence``.
    case unsure
    /// The runner-up is above ``LanguagePolicy/maximumRunnerUp``.
    case mixed
}

/// The language verdict for one surface.
public enum LanguageVerdict: Sendable, Equatable {
    /// The user switched this language off. Carries the base subtag.
    case off(String)
    /// The language is identified and not switched off.
    case allowed(String)
    /// The identifier is not sure enough to switch anything off, so the suggestion proceeds.
    case open(LanguageOpenReason)
}

/// The language off switch as a pure decision. It fails open: only a
/// confident, unmixed, long enough reading of a switched-off language suppresses anything.
public struct LanguagePolicy: Sendable, Equatable {
    // The three constants are placeholders until the language-open share of a real typing run is
    // measured. On the running-thought corpus `NLLanguageRecognizer` with no language constraint
    // was sure and right in 97.6 % of cases at 20 letters and 100 % from 30, never sure and wrong;
    // at 10 letters it failed open in 21 %. `minimumLetters` could therefore sit at 20.
    /// Fewer letters than this read as ``LanguageOpenReason/short``.
    public static let minimumLetters = 40
    /// A top probability below this reads as ``LanguageOpenReason/unsure``.
    public static let minimumConfidence = 0.80
    /// A runner-up probability above this reads as ``LanguageOpenReason/mixed``.
    public static let maximumRunnerUp = 0.30

    public var disabled: Set<LanguageSelector>

    public init(disabled: Set<LanguageSelector> = []) {
        self.disabled = disabled
    }

    /// The stored `disabledLanguages` value: an array of base tags (`en`, `de`) and `*` for all other
    /// languages. Anything that is not an array of strings, and any empty string, yields no selector,
    /// so a damaged value never switches a language off.
    public init(stored: Any?) {
        let entries = (stored as? [Any])?.compactMap { $0 as? String } ?? []
        self.init(disabled: Set(entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "*" { return LanguageSelector.allOthers }
            return trimmed.isEmpty ? nil : LanguageSelector.tag(trimmed)
        }))
    }

    /// The array `init(stored:)` reads back, sorted so the stored value is stable.
    public var storedValue: [String] {
        disabled.map { selector -> String in
            switch selector {
            case .tag(let tag): return tag
            case .allOthers: return "*"
            }
        }.sorted()
    }

    public func verdict(for reading: LanguageReading?) -> LanguageVerdict {
        guard let reading, reading.letterCount >= Self.minimumLetters else { return .open(.short) }
        guard reading.probability >= Self.minimumConfidence else { return .open(.unsure) }
        guard reading.runnerUpProbability <= Self.maximumRunnerUp else { return .open(.mixed) }
        let base = Self.baseSubtag(reading.tag)
        let isOff = disabled.contains(.allOthers) || disabled.contains { selector in
            if case .tag(let tag) = selector { return Self.baseSubtag(tag) == base }
            return false
        }
        return isOff ? .off(base) : .allowed(base)
    }

    /// `de-CH` and `de_CH` become `de`.
    static func baseSubtag(_ tag: String) -> String {
        SpellLanguagePolicy.baseTag(of: tag).lowercased()
    }

    /// The paragraph tail the identifier reads: back to the last paragraph break, at most 400 characters.
    public static func paragraphTail(of text: String) -> String {
        let afterBreak = text.lastIndex(where: { $0 == "\n" || $0 == "\u{2029}" })
            .map { String(text[text.index(after: $0)...]) } ?? text
        return String(afterBreak.suffix(400))
    }
}
