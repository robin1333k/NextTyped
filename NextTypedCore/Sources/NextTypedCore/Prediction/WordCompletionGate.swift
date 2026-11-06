/// Decides whether a **word-completing** continuation may be shown — the ghost that carries no
/// leading space and therefore renders *glued* onto the token the caret sits behind
/// (`Wort` + `laut` → `Wortlaut`).
///
/// ## Why this exists
///
/// Completion-first meets the flush prefix: at a caret directly after a word
/// character the engine keeps the model's (absent) leading space, so a continuation extending the
/// current token paints with no gap. That is *deliberate* where the premise holds — the user is
/// mid-word and a fragment is exactly what a completion is for. The defect is that it also fires
/// where the premise is unfounded.
///
/// The two configurations are decided differently, and the discriminator is **how the caret got
/// there**:
///
/// - **Reached by typing** — unchanged. The user typed `Wort` and paused; nothing distinguishes a
///   finished word from a fragment, and betting on the completion is a documented bet.
///   This is also the only way the genuine mid-word case (`Wohnu` → `ng`) is reachable at all.
/// - **Reached by navigation** — a click, an arrow, Home/End, ⌘-arrow, or a delete that lands at a
///   word end. Here the user typed nothing, so there is no fragment to infer: a continuation must
///   be a *next-word* one, i.e. it must bring its own leading space.
///
/// ## What is refused, precisely
///
/// Only the **glue**: a continuation whose first character is a word character while the character
/// before the caret is one too. A continuation opening with punctuation (`:`, `,`, `—`) attaches to
/// the preceding word legitimately and is none of this gate's business — a separate rule owns the
/// boundary-punctuation lead. A continuation opening with whitespace is the next-word shape this
/// gate is asking for and passes untouched.
///
/// ## Refuse, rather than re-ask for a spaced continuation
///
/// The two options are refusing the glued ghost and re-predicting from a space-terminated prompt.
/// The second is **void**: the engine strips trailing whitespace before inference, so
/// a prompt with the space appended is byte-identical to the flush one and greedy decoding at temp 0
///  would return the very same word-completion — a second inference for a guaranteed
/// identical answer. So this refuses, and accepts the cost it names: a silent gap at a common caret
/// position. The suppression is greppable (`[gate]: word-completion suppressed`) precisely so that
/// gap is measurable as a rate rather than felt.
///
/// Pure decision over facts the caret already carries — no model, no AX surface.
public enum WordCompletionGate {
    /// - Parameters:
    ///   - continuation: the continuation text as it would be painted (already shaped by the engine's
    ///     spacing reconciliation, so a leading space here means the ghost renders detached).
    ///   - trigger: what asked for this prediction. Only `.caretMoved` engages the gate: `.typing`
    ///     is the plain typing path, and `.acceptRefill` is our own insert echoing back — the caret
    ///     there sits after a word *we* just typed, mid-clause, and refusing there would break the
    ///     `Tab` accept chain at every buffer exhaustion.
    ///   - charBeforeCaret: the character immediately left of the caret, or `nil` at the field start.
    /// - Returns: `true` if this continuation may be shown.
    public static func allowsContinuation(
        _ continuation: String,
        trigger: SuggestionTrigger,
        charBeforeCaret: Character?
    ) -> Bool {
        guard trigger == .caretMoved else { return true }
        guard let before = charBeforeCaret, before.isWordCharacter else { return true }
        guard let first = continuation.first else { return true }
        return !first.isWordCharacter
    }

    /// Convenience over a `TypingContext`: the character before the caret is the last of
    /// `textBeforeCaret`.
    public static func allowsContinuation(
        _ continuation: String,
        trigger: SuggestionTrigger,
        in context: TypingContext
    ) -> Bool {
        allowsContinuation(continuation, trigger: trigger, charBeforeCaret: context.textBeforeCaret.last)
    }
}
