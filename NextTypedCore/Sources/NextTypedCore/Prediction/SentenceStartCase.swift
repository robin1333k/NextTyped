/// Capitalize a continuation that **provably opens a sentence**.
///
/// ## Why this exists
///
/// The decode may run *through* a leading clause boundary, so a ghost follows a typed `.`
/// and continues past a sentence end. The runtime verify of that decision (2026-07-04, German prose)
/// found the mechanics correct and one cosmetic consequence: such a ghost sometimes begins
/// **lowercase** (`… Satz. |dann kommt …`), a grammar error the user has to notice and repair after
/// accepting an otherwise correct suggestion. In both shipped languages a sentence start is always
/// capitalized, so where the opening is *provable* the case can be decided deterministically rather
/// than hoped for from the model.
///
/// ## What counts as provable
///
/// Exactly two signals, neither of them a guess:
///
/// 1. **The caret sits at a sentence opening** — the sentence it is in was opened by a `.`/`!`/`?`
///    and holds no word yet. Delegated to `RunningThoughtGate.currentSentence`, so the
///    decimal guard (`3.500` opens nothing) has one definition in this codebase rather than two.
/// 2. **The continuation itself leads with sentence punctuation** (`". dann"`), in which case the
///    character to capitalize is the first word character *after* the mark. The same shape guard as
///    everywhere else applies: the mark must be followed by whitespace, so `.net` is a token, not a
///    boundary.
///
/// Everything else is returned byte-identical. A **word completion** is excluded structurally rather
/// than by a special case — it sits at a flush caret inside a word, where neither signal can fire —
/// and that is pinned by a test rather than asserted here.
///
/// Two openings are deliberately **not** claimed, because this guard could never execute there:
/// the start of the document and a caret right after a newline are sentence openings too, but
/// `RunningThoughtGate` arm 1 refuses a continuation at both (zero words at a structural break), so
/// a rule for them would be code with no reachable call — the trap `FIMAccept.terminalJoin` cost
/// this project once already.
///
/// ## Accepted residuals (decided at triage 2026-08-29, not oversights)
///
/// - **Lowercase-by-design leads** (`iPhone`, `iOS`, `eBay`, `.com` brands) are capitalized wrongly
///   when they open a sentence. Declined explicitly: the fix is an exception list, this codebase
///   already carries one unmaintained word list (`CommonWords`) and does not want a second, and the
///   case is rare at a sentence start.
/// - **Multi-letter abbreviations** (`usw.`, `Nr.`) read as sentence ends. Only the *single-letter*
///   shape (`z. B.`, `d. h.`) is excluded, because that one is structural — a lone letter before a
///   period — and needs no list. Everything a list would be needed for is left alone.
///
/// ## Ordering
///
/// Runs **last** in `SuggestionSession.handlePredictionArrived`, after `BoundaryLeadJoin`. Later
/// than the bars because capitalizing text a gate is about to empty computes a result nobody sees;
/// later than the join because the join is what settles where the first word character sits relative
/// to any leading whitespace, and this guard should shape the exact string that gets painted and
/// accepted. It applies to the **buffer**, not the display window: `Tab` inserts from the buffer and
/// the window is a prefix of it, so one application covers both and cannot disagree with
/// itself as the window slides.
///
/// One knock-on worth knowing about: `SmartAdvance` matches case-sensitively, so a user who types the
/// lowercase letter under a capitalized ghost head diverges and pays one re-inference instead of a
/// free type-along. That is the correct reading of the keystroke — they typed something else — and it
/// costs a single predict at exactly one caret position per sentence.
public enum SentenceStartCase {

    /// The continuation with its opening word capitalized when — and only when — that word provably
    /// begins a sentence.
    ///
    /// - Parameters:
    ///   - continuation: the shaped continuation buffer.
    ///   - textBeforeCaret: the host text left of the caret.
    public static func apply(to continuation: String, textBeforeCaret: String) -> String {
        let chars = Array(continuation)
        guard let first = chars.firstIndex(where: { $0.isWordCharacter }) else { return continuation }
        guard leadOpensSentence(chars[..<first], followedBy: chars[first])
                || caretOpensSentence(textBeforeCaret) else { return continuation }

        // The one-character rule, and the trap worth stating: `"ß".uppercased()` is `"SS"`. Every
        // downstream consumer measures this string — the display window, the copy guard's token run,
        // the accept peel — so a shaping step that changes its length would desynchronise all three.
        // A grapheme without a single-character uppercase form is simply left as decoded.
        let c = chars[first]
        let upper = c.uppercased()
        guard upper.count == 1, let u = upper.first, u != c else { return continuation }
        var out = chars
        out[first] = u
        return String(out)
    }

    /// Signal 2: the run of non-word characters ahead of the first word carries a sentence mark that
    /// is followed by whitespace. `followedBy` is the first word character itself, needed only for
    /// the case where the mark is the last character of the lead (`".net"` — a token, not a
    /// boundary).
    private static func leadOpensSentence(_ lead: ArraySlice<Character>,
                                          followedBy firstWord: Character) -> Bool {
        for k in lead.indices where lead[k] == "." || lead[k] == "!" || lead[k] == "?" {
            let next = k + 1 < lead.endIndex ? lead[k + 1] : firstWord
            if next.isWhitespace { return true }
        }
        return false
    }

    /// Signal 1: the caret's own sentence was opened by a boundary mark and holds nothing yet.
    ///
    /// One scan of the prefix (the shared `currentSentence`), then a bounded look at its tail for the
    /// single-letter abbreviation shape. `!` and `?` do not abbreviate anything, so only `.` is
    /// examined.
    private static func caretOpensSentence(_ textBeforeCaret: String) -> Bool {
        let sentence = RunningThoughtGate.currentSentence(in: textBeforeCaret)
        guard sentence.origin == .sentenceBoundary, sentence.wordCount == 0 else { return false }
        return !endsInSingleLetterAbbreviation(textBeforeCaret)
    }

    /// `z. B. ` / `z.B. ` / `d. h. ` — a period whose only letter is a lone one. Conservative on
    /// purpose: refusing to capitalize leaves the pre-ticket behaviour, capitalizing wrongly is the
    /// defect being fixed pointing the other way.
    private static func endsInSingleLetterAbbreviation(_ textBeforeCaret: String) -> Bool {
        var reader = textBeforeCaret.reversed().makeIterator()
        var c = reader.next()
        while let ch = c, ch.isWhitespace { c = reader.next() }
        guard c == "." else { return false }
        guard let letter = reader.next(), letter.isLetter else { return false }
        guard let before = reader.next() else { return true }   // "B." at the very start
        return !before.isLetter
    }
}
