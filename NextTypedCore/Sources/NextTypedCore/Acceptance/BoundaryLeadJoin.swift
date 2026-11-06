/// How a continuation that **opens with attaching punctuation** joins to the caret — the
/// replace-backwards decision, which replaces the earlier suppression rule.
///
/// ## The configuration
///
/// The decode may run *through* a leading clause boundary, so the model legitimately
/// offers `". Es wird kalt"` at a caret that has just finished a sentence. When that caret sits
/// after a space — the post-`Tab` gap, or one the user typed — insert-only acceptance
/// commits the stray-space typo `Winter. Es`. The suppression rule therefore threw the whole suggestion away.
///
/// The archived-log count that gated the fix (three sessions, 103 predicts) found **7 suppressions,
/// 4 of them complete sentences** — a `Tab`-chain dead end roughly every 25 predicts, for a defect
/// whose fix is one character wide. So the verdict is no longer *suppress*; it is *how to join*:
///
/// - **caret after whitespace** (`Winter |` + `". Es"`) → the space belongs to the punctuation's
///   left, not to the caret: accepting consumes it. `consumesPrecedingSpace == true`.
/// - **result leads with its own whitespace at a flush caret** (`Winter|` + `". Es"`) → the same
///   typo from the other side, and here it costs nothing to fix: drop the result's space and the
///   accept stays a plain insert. This is §3's symmetric arm, subsumed.
/// - **both** → drop the result's space *and* consume the caret's.
/// - **flush caret, attached lead** (`Winter|` + `". Es"`) → already perfect; untouched. This is the
///   case the decode-through rule exists to enable and must stay byte-identical.
///
/// ## Which punctuation attaches
///
/// `.` `!` `?` `,` `;` `:` — the marks that are *never* preceded by a space in either shipped
/// language. The earlier rule covered only `.!?`, because a comma lead was rendered rather than
/// suppressed: throwing away `", und dann"` to avoid `kalt, und` would have cost more than the typo.
/// With replace-backwards nothing is thrown away, so the commas the old rule deliberately left out are
/// folded in here (the ticket asked for that decision explicitly).
///
/// Deliberately **out**: brackets and quotes (`(`, `"`, `«`) legitimately want the preceding gap;
/// `'` is ambiguous between apostrophe and opening quote and never appeared in the measured data;
/// `…` reads both ways. `FIMAccept.attachingPunctuation` is a *different* list for a different side
/// (what may follow the accept), and is left alone.
///
/// ## The shape guard (unchanged from the earlier rule)
///
/// The mark must be followed by whitespace or end-of-string. `.Net`, `3,5` and `10:30` are tokens,
/// not clause boundaries, and they render exactly as before — the same decimal-guard reasoning
/// `ClauseStop.firstClause` applies.
public enum BoundaryLeadJoin {
    /// Punctuation that attaches to the word on its left; a space in front of it is a typo.
    private static let attaching: Set<Character> = [".", "!", "?", ",", ";", ":"]

    public struct Result: Equatable, Sendable {
        /// The continuation as it should be painted and accepted.
        public var text: String
        /// Accepting must replace the one character before the caret (a space) with the accept.
        public var consumesPrecedingSpace: Bool

        public init(text: String, consumesPrecedingSpace: Bool) {
            self.text = text
            self.consumesPrecedingSpace = consumesPrecedingSpace
        }
    }

    /// - Parameters:
    ///   - continuation: the continuation as shaped by the engine (spacing reconciliation
    ///     has already run, so at a whitespace caret the model's own leading space is gone).
    ///   - textBeforeCaret: the host text left of the caret — only its last character is read.
    /// - Returns: the text to show/accept, and whether the accept consumes the preceding space.
    public static func apply(to continuation: String, textBeforeCaret: String) -> Result {
        let unchanged = Result(text: continuation, consumesPrecedingSpace: false)
        let head = continuation.drop(while: { $0.isWhitespace })
        guard let mark = head.first, attaching.contains(mark) else { return unchanged }
        let next = head.dropFirst().first
        guard next == nil || next!.isWhitespace else { return unchanged }   // ".Net", "3,5": a token
        let leadsWithWhitespace = head.startIndex != continuation.startIndex
        // A **space or tab**, never a line break: consuming a newline would merge two paragraphs to
        // save one character, which is destructive where the whole point is a typographic nicety.
        // (The engine's spacing reconciliation asks a different question — "is the model's leading
        // space redundant?" — and rightly keeps `isWhitespace` there.)
        let caretSpace = textBeforeCaret.last
        let caretAfterWhitespace = caretSpace?.isWhitespace == true && caretSpace?.isNewline == false
        guard caretAfterWhitespace || leadsWithWhitespace else { return unchanged }
        return Result(text: String(head), consumesPrecedingSpace: caretAfterWhitespace)
    }
}
