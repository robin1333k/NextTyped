/// Result of trying to "smart-advance" a suggestion when the user types.
public enum SmartAdvanceResult: Equatable, Sendable {
    /// The typed input matched the head of the suggestion; here's what remains.
    case advanced(remaining: Suggestion)
    /// The typed input diverged from the suggestion; it's no longer valid and the
    /// loop should re-infer (or clear the ghost text).
    case invalidated
}

/// Pure logic for the "smart-advance" optimization:
/// if the user types text that matches the current ghost suggestion, trim the
/// suggestion instead of re-inferring — near-zero cost, no flicker.
public enum SmartAdvance {
    public static func apply(typed: String, to suggestion: Suggestion) -> SmartAdvanceResult {
        guard !typed.isEmpty else { return .advanced(remaining: suggestion) }
        guard suggestion.text.hasPrefix(typed) else { return .invalidated }
        let remaining = String(suggestion.text.dropFirst(typed.count))
        return .advanced(remaining: Suggestion(text: remaining))
    }

    public static func apply(typed: Character, to suggestion: Suggestion) -> SmartAdvanceResult {
        apply(typed: String(typed), to: suggestion)
    }
}
