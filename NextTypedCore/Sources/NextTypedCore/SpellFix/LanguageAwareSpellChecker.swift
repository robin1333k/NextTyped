import Foundation

/// The system dictionary seam: `NSSpellChecker` in the App, a fake in tests.
public protocol WordSpelling: Sendable {
    /// Whether `word` is misspelled in `language`.
    func isMisspelled(_ word: String, language: String) async -> Bool
    /// Replacement guesses for `word` in `language`, best first.
    func guesses(for word: String, language: String) async -> [String]
    /// Whether `language` completes `word` into a longer word (`Sommerferienpl` has completions,
    /// `qzxvw` has none). Decides between a viable prefix and a suspected typo.
    /// `context` is the paragraph before the caret with `word` at its end: the system's English
    /// completions are predictive and return nothing for a bare word (the offline probe).
    func hasCompletions(for word: String, in context: String, language: String) async -> Bool
}

/// the correction receives the language detected from the
/// paragraph before the caret, and shows nothing when that is unsure.
public struct LanguageAwareSpellChecker: SpellChecker {
    private let words: any WordSpelling
    private let identifier: any LanguageIdentifying
    private let log: @Sendable (String) -> Void
    private let typoGateEnabled: @Sendable () -> Bool

    /// - Parameter typoGateEnabled: whether a misspelled word without completions counts as a
    ///   suspected typo. Default off: the probe measured too many false suspects,
    ///   so until it is wired on every verdict is `.clean`.
    /// - Parameter log: receives the greppable `[gate]:` and `[spell]:` lines; the App writes them to its log.
    public init(words: any WordSpelling,
                identifier: any LanguageIdentifying,
                typoGateEnabled: @escaping @Sendable () -> Bool = { false },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.typoGateEnabled = typoGateEnabled
        self.words = words
        self.identifier = identifier
        self.log = log
    }

    public func verdict(for context: TypingContext) async -> SpellVerdict {
        let word = context.currentWordPrefix
        guard word.count >= 3 else { return .clean(nil) }   // don't nag on 1-2 letter fragments

        let language: String
        switch languageVerdict(for: context.textBeforeCaret) {
        case .open:
            log("[gate]: spell-language-open word=\(word)")
            return .clean(nil)
        case .language(let tag):
            language = tag
        }

        guard await words.isMisspelled(word, language: language) else {
            log("[spell]: word=\(word) lang=\(language) ok (not misspelled) verdict=clean")
            return .clean(nil)
        }
        var suspected = false
        if typoGateEnabled() {
            let paragraph = SpellLanguageContext.tail(of: context.textBeforeCaret) + word
            suspected = !(await words.hasCompletions(for: word, in: paragraph, language: language))
        }
        let tag = suspected ? "typo-suspected" : "clean (viable prefix)"
        let guesses = await words.guesses(for: word, language: language)
        guard let best = guesses.first, best.lowercased() != word.lowercased() else {
            log("[spell]: word=\(word) lang=\(language) misspelled, no usable guess verdict=\(tag)")
            return suspected ? .typoSuspected(nil) : .clean(nil)
        }
        log("[spell]: word=\(word) lang=\(language) fix=\(best) verdict=\(tag)")
        let fix = Correction(original: word, replacement: best, charactersBackFromCaret: word.count)
        return suspected ? .typoSuspected(fix) : .clean(fix)
    }

    /// The current paragraph decides; when it is too short to read (a paragraph's first word), the
    /// text before it does.
    private func languageVerdict(for textBeforeCaret: String) -> SpellLanguageVerdict {
        let tail = SpellLanguageContext.tail(of: textBeforeCaret)
        let own = SpellLanguagePolicy.verdict(for: identifier.reading(of: tail))
        if own != .open { return own }
        let earlier = SpellLanguageContext.earlierText(of: textBeforeCaret)
        guard earlier != tail else { return .open }
        return SpellLanguagePolicy.verdict(for: identifier.reading(of: earlier))
    }
}
