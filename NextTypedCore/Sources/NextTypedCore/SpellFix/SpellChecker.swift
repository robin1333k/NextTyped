/// What the spell check concluded about the word immediately before the caret.
///
/// A word can be misspelled and still be a viable prefix of a longer word (`Sommerferienpl`); the
/// dictionary then has completions and the verdict stays `.clean`. A typo is suspected only when
/// the word is misspelled and nothing completes it. Either case may carry a `Correction`.
public enum SpellVerdict: Equatable, Sendable {
    /// Nothing to withhold: the word is spelled right, is a viable prefix, or was not checked.
    case clean(Correction?)
    /// The word is misspelled and no completion exists. The continuation is withheld; the
    /// correction, if the dictionary has one, still shows.
    case typoSuspected(Correction?)

    public var correction: Correction? {
        switch self {
        case .clean(let correction), .typoSuspected(let correction): return correction
        }
    }

    public var isTypoSuspected: Bool {
        if case .typoSuspected = self { return true }
        return false
    }
}

/// Judges the word immediately before the caret.
///
/// v1 is backed by `NSSpellChecker` (instant, multilingual, free) in the app
/// target; LLM-backed context-aware corrections (homophones, right-spelling-
/// wrong-word) are a fast-follow that implements this same seam.
public protocol SpellChecker: Sendable {
    func verdict(for context: TypingContext) async -> SpellVerdict
}

extension SpellChecker {
    /// The correction alone, for callers that do not care whether a typo is suspected.
    public func correction(for context: TypingContext) async -> Correction? {
        await verdict(for: context).correction
    }
}
