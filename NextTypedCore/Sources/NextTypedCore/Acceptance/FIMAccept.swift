/// The right-hand half of **two-sided accept reconciliation** for a mid-text bridge (build
/// item 9). Forward continuation has one join to get right (`P|middle`, handled by the flush-prefix
/// reconciliation and `BoundaryLeadJoin`); a bridge has a second one, because the
/// suffix `S` is already sitting to the right of the caret and the accept lands flush against it.
///
/// **Deliberate deviation from the simpler rule.** One could word it as "suppress the
/// trailing space when `S` leads with whitespace/punctuation". That describes the *stated*
/// form; the **realized** form in this codebase is leading-space-preserving — `WordTokenizer`
/// peels `" schnell"` and leaves `" über"` as the remainder, and nothing anywhere appends a trailing
/// space. So the hazard at `middle|S` is the mirror image of that rule: the terminal accept fuses
/// (`…schnell` + `über den Zaun.` → `schnellüber`). This type therefore decides the separator in both
/// directions — add one where the words would fuse, emit none where `S` already brings its own gap or
/// opens with punctuation that attaches to the preceding word (the stray-space typo class of `BoundaryLeadJoin`,
/// applied to the right side).
///
/// **Terminal accepts only.** The rule "interior accepts keep the space unconditionally" needs no code
/// here: an interior accept's right neighbour is the next ghost word, and the remainder still carries
/// the gap in front of it. Only the accept that empties the bridge buffer puts `S` immediately to the
/// right, so only that one consults this. (Accepting an `S`-duplicating bridge is already prevented
/// upstream by `FIMStop.check`.)
public enum FIMAccept {
    /// Punctuation that attaches to the word before it — a space in front of it is a typo.
    ///
    /// Closing and terminal marks only: an *opening* bracket or quote (`(`, `«`, `“`) wants the gap, so
    /// it is deliberately absent. Two judgement calls on the ambiguous marks, since `S`'s first
    /// character is all we have to go on:
    ///   - `'` **is** treated as attaching — at a word boundary it is far more often an apostrophe
    ///     (`it'|s`, `Hans'| Buch`) than an opening quote, and `schnell 's` is the worse error.
    ///   - `"` is **not** — it is never an apostrophe, so a `"` starting `S` reads as an opening quote
    ///     (`sagte "Hallo"`), which wants the gap.
    private static let attachingPunctuation: Set<Character> = [
        ",", ".", "!", "?", ";", ":", "…", ")", "]", "}", "»", "”", "’", "'",
    ]

    /// The text to append after the **final** accepted bridge word so it joins cleanly to `S`.
    ///
    /// - Parameters:
    ///   - accepted: the text being inserted by this accept (as peeled, leading gap included).
    ///   - suffix: the host text immediately right of the caret — `S`.
    /// - Returns: `" "` when the two would otherwise fuse, `""` otherwise.
    public static func terminalJoin(accepted: String, suffix: String) -> String {
        guard let left = accepted.last, !left.isWhitespace else { return "" }
        guard let right = suffix.first, !right.isWhitespace else { return "" }
        guard !attachingPunctuation.contains(right) else { return "" }
        return " "
    }

    /// The text an accept should actually insert — `accepted` as peeled, plus the `middle|S` separator
    /// **iff** this accept is the *terminal* one of a *bridge*. This is the whole of `terminalJoin`'s
    /// call-site decision, kept pure so every branch is unit-testable with no running app: the FIM model
    /// cannot be loaded on a machine without its weights, so this function is the only evidence the
    /// join is reached at all (build item 9).
    ///
    /// Three facts decide it, and all three are already in hand at the acceptance layer:
    ///   - **terminal?** `exhausted` — this accept emptied the continuation buffer, so nothing of the
    ///     bridge remains between the caret and `S`. An *interior* accept's right neighbour is the next
    ///     ghost word, which still carries its own leading gap (the realized, leading-space-
    ///     preserving form), so it needs — and gets — nothing here.
    ///   - **bridge?** `FIMSite.route` on the very same `textAfterCaret` the predict routed on. Re-asking
    ///     the one router (rather than carrying a "was FIM" flag alongside the suggestion) is what makes
    ///     a disagreement between the prompt's `S` and the join's `S` impossible.
    ///   - **which separator?** `terminalJoin`.
    ///
    /// With `fimEnabled == false` — the shipping default — `route` answers `.forward` unconditionally and
    /// this returns `accepted` unchanged, so the forward accept path is byte-identical.
    ///
    /// `textAfterCaret` is read from the context that produced the shown suggestion, i.e. as it was at
    /// predict time. That is the correct reading and not staleness: every accept (and every type-along)
    /// inserts to the *left* of the caret, so the host text to the right of the caret is still `S`.
    public static func insertionText(
        accepted: String,
        exhausted: Bool,
        textAfterCaret: String,
        fimEnabled: Bool
    ) -> String {
        guard exhausted,
              case .fim(let suffix) = FIMSite.route(textAfterCaret: textAfterCaret, fimEnabled: fimEnabled)
        else { return accepted }
        return accepted + terminalJoin(accepted: accepted, suffix: suffix)
    }
}
