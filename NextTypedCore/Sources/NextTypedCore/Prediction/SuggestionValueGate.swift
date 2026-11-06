/// Decides whether a generated continuation carries enough content to be worth showing as a ghost —
/// the *output* sibling to the input/context cold-start gates (`CaretPositionGate`, `FieldSizeGate`).
///
/// Filed from runtime-log analysis: a large share of predictions return a
/// near-zero-value continuation — empty, whitespace-only, or punctuation-only. A bare `"."` appeared
/// 32× / 63× across two real sessions and a whitespace-only `"  "` also showed. Such a ghost offers
/// nothing to Tab-accept, and a lone `"."` would Tab-insert a stray period + trailing space.
/// Suppressing them keeps the overlay quiet and stops the acceptance layer from intercepting `Tab` for
/// junk (the gate is enforced inside `AcceptanceStateMachine`, the single `setContinuation` chokepoint).
///
/// The rule reuses `CaretPositionGate`'s notion of a "word character": a continuation is renderable iff
/// it contains **at least one Unicode letter or number**. This is deliberately the minimal,
/// content-presence test, NOT a length cap:
///   - It **keeps short-but-real continuations** — a flush single-character word-completion
///     (`"worl"` → `"d"`) or a one-letter word (`" a"`, `" I"`) all carry a word character.
///     Length-capping would regress completion-first, which the design explicitly preserves.
///   - It **drops** the genuinely contentless cases: `""`, `" "`, `"."`, `","`, `"…"`, `"()"`.
///   - It is **language-agnostic** (no hardcoded English) — German umlauts/ß and other
///     scripts behave like English because `isWordCharacter` is `isLetter || isNumber`.
///
/// NOTE — *why this isn't an input-side skip-predict gate.* An earlier proposal also floated skipping
/// the predict entirely on a "mid-word, no new boundary" keystroke. That conflicts with the accepted
/// completion-first decision ("we want completion while typing"): a mid-word keystroke is
/// exactly when a flush word-completion is wanted, so a blanket skip would kill it. The steady-state
/// input-side waste is instead the job of `SmartAdvance` (tracked separately). This gate only
/// shapes the *output* and never suppresses a valid completion.
public enum SuggestionValueGate {
    /// True if `continuation` is worth rendering — it holds at least one letter or number.
    public static func isRenderable(_ continuation: String) -> Bool {
        continuation.contains { $0.isWordCharacter }
    }

    /// The same test for a remainder the trailing punctuation picker deliberately held back
    /// : `"."` is what the user's next press inserts, so the ghost keeps showing it
    /// instead of blinking out until the refill. Only the accept path sets the flag, so a bare `"."`
    /// from the model is still suppressed.
    public static func isRenderable(_ continuation: String, heldBackPunctuation: Bool) -> Bool {
        if heldBackPunctuation, continuation.contains(where: { !$0.isWhitespace }) { return true }
        return isRenderable(continuation)
    }

    /// Convenience over a `Suggestion`.
    public static func isRenderable(_ suggestion: Suggestion) -> Bool {
        isRenderable(suggestion.text)
    }
}
