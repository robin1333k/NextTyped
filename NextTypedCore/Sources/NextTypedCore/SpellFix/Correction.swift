/// A proposed spelling/word correction for an already-typed word.
///
/// `charactersBackFromCaret` lets the app target locate the word to replace
/// relative to the caret without Core needing AX or a live text buffer.
public struct Correction: Equatable, Sendable {
    /// The misspelled word as the user typed it.
    public var original: String
    /// The proposed replacement.
    public var replacement: String
    /// How many characters back from the caret `original` begins (its length when
    /// the caret sits right after it).
    public var charactersBackFromCaret: Int

    public init(original: String, replacement: String, charactersBackFromCaret: Int) {
        self.original = original
        self.replacement = replacement
        self.charactersBackFromCaret = charactersBackFromCaret
    }
}
