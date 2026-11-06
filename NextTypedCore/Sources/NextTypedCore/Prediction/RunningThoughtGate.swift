/// The hard bar on **class C** — *the ghost does not continue a running thought*.
///
/// Class C broke in **all three** arms of the Ticket-02 baseline, at `winCtx=22` just as at
/// `winCtx=1224` (`… was` → `"8. Offene Punkte"`, `"Test 7 (Sara):"` — invented headings and
/// participants), so it is neither a context problem nor an outlier, and the prompt-shape lever is
/// closed for it. What is left is a gate, and it has **two deliberately asymmetric arms**: one reads
/// the caret, the other reads the ghost.
///
/// Both are pure arithmetic over data that is already in hand — `TypingContext.textBeforeCaret` for
/// arm 1, the engine's raw decode for arm 2 — so neither adds AX work or new plumbing.
///
/// **Deliberately not** an extension of `SuggestionValueGate`: that chokepoint's contract is *one
/// string in, renderable yes/no*, which is what makes it callable from every accept path, several of
/// which hold no `TypingContext` at all. Arm 1 lives in `SuggestionSession.handleContextReady`
/// alongside `FieldSizeGate`, arm 2 in `handlePredictionArrived` before `setContinuation`.
///
/// Named for the **mechanism**, not the defect: class C also covers jumps emitted with no newline
/// anywhere, which this gate does not catch (an accepted residual; pattern-matching the
/// flattened ghost was considered and rejected).
public enum RunningThoughtGate {

    // MARK: Arm 1 — "no running thought" (input side)

    /// The number of words the current sentence must hold before a continuation may be generated.
    /// Chosen at the narrow end deliberately (silence is a first-class cost) and
    /// never measured against a corpus — the `[gate]: running-thought absent` token is what makes
    /// measuring it possible.
    public static let minimumSentenceWords = 2

    /// How the sentence the caret sits in was opened. The distinction is the whole of the
    /// only a **structural** opening leaves nothing to continue.
    ///
    /// `internal`, like `currentSentence` and `wordCount(inSentenceEnding:)` — the tests reach it
    /// through `@testable import`, and no caller outside Core has a use for it.
    enum SentenceStartOrigin: Equatable, Sendable {
        /// Nothing precedes the caret at all — the purest "no running thought" case.
        case documentStart
        /// A `Character.isNewline` grapheme: the paragraph/heading break class C actually keyed on.
        case structuralBreak
        /// A typed `.`/`!`/`?`: the previous sentence IS the running thought.
        case sentenceBoundary
    }

    /// True when there **is** a running thought to continue.
    ///
    /// Two conditions, and the arm engages only when both hold: the sentence the caret sits in was
    /// opened by a **structural break** (a newline, or the start of the document), *and* it holds
    /// fewer than `minimumSentenceWords` words.
    ///
    /// The origin test is the **narrowing** decided on 2026-08-28. As first
    /// built, arm 1 asked only the word count, which made every typed `.` suppress the next ghost
    /// until two words had been typed — silently reversing
    /// the clause-stop decision, which was eval-gated (`probe_clause_stop.py`, empty-rate 69 %→0 %) and
    /// runtime-verified with the user on 2026-07-04. Three previously-green scenarios caught it on
    /// the gate's first contact with the suite. The two behaviours are separable because a full stop
    /// is not a break in the thought — the thought is one sentence back — whereas
    /// `Test 4 (Lena):` + newline is exactly the break class C was measured on. This is the
    /// "signature too broad" risk this gate was filed with, narrowed rather than accepted.
    ///
    /// The rule reads the **origin of the start**, not the substance of what precedes it: a one-word
    /// previous sentence still ends in a boundary, so the ghost continues there. Asking how
    /// substantial the previous sentence was would be a second heuristic stacked on the first, with
    /// no measurement behind it, and arm 2 already refuses the jump ghost itself.
    ///
    /// **The price, stated plainly:** at a boundary-reached start this arm no longer stands between
    /// the caret and a fabrication, so everything now rests on arm 2 there — and arm 2 sees only
    /// jumps carrying a newline. The *accepted residual* (a jump the model opens inline, with
    /// no newline anywhere) is therefore **enlarged by this narrowing, precisely at a full stop**,
    /// which is the most frequent caret position in real typing. That is the cost of keeping
    /// that decision, taken knowingly: the residual is a *shape* nobody has a machine-recognisable
    /// signature for, while the ghost-after-a-full-stop it buys back was measured.
    ///
    /// The sentence starts at the **nearer** of the last sentence boundary and the last newline. The
    /// unit is the sentence, **not** the paragraph: after `Test 4 (Lena):` plus a newline the
    /// paragraph is not empty, yet the running thought is precisely what is missing there — a
    /// paragraph-scoped rule reads that spot as populated and lets the fabrication through.
    ///
    /// A sentence boundary is `.`/`!`/`?` **followed by whitespace or end of text** — the same
    /// decimal guard `ClauseStop.firstClause` applies, so `3.500` does not start a new sentence. A
    /// newline is any `Character.isNewline` grapheme (LF, CR, **CRLF**, VT, FF, NEL, LS, PS): a bare
    /// `"\n"` compare is the mistake already paid for once.
    ///
    /// Words the user **accepted** from a ghost count as typed — they are in `textBeforeCaret` like
    /// any other text. Tracking provenance would need a second notion of authorship next to
    /// personalization's, for a hole arm 2 already closes: the model cannot seed itself two words
    /// deep without first emitting a jump ghost, and that ghost is what arm 2 refuses.
    public static func hasRunningThought(textBeforeCaret: String) -> Bool {
        let sentence = currentSentence(in: textBeforeCaret)
        switch sentence.origin {
        case .sentenceBoundary:
            return true
        case .documentStart, .structuralBreak:
            return sentence.wordCount >= minimumSentenceWords
        }
    }

    /// How the caret's sentence was opened — so the narrowing can be tested on its own, and so anyone
    /// reasoning about the bar can see which arm-1 branch a given prefix takes.
    static func sentenceStartOrigin(textBeforeCaret: String) -> SentenceStartOrigin {
        currentSentence(in: textBeforeCaret).origin
    }

    /// Convenience over a `TypingContext`.
    public static func hasRunningThought(in context: TypingContext) -> Bool {
        hasRunningThought(textBeforeCaret: context.textBeforeCaret)
    }

    /// Words in the sentence the caret sits in — exposed for tests and for anyone reasoning about
    /// the threshold. A "word" is a whitespace-delimited run holding at least one word character
    /// (`Character.isWordCharacter` = letter/number, the system's single answer to "is there
    /// content?"), so a lone `(` or `—` does not count as a running thought.
    static func wordCount(inSentenceEnding textBeforeCaret: String) -> Int {
        currentSentence(in: textBeforeCaret).wordCount
    }

    /// The single scan behind both halves of arm 1: where the caret's sentence starts, how it was
    /// opened, and how many words it holds. One pass so the origin and the count can never disagree
    /// about which mark was the nearer one.
    static func currentSentence(in textBeforeCaret: String) -> (origin: SentenceStartOrigin, wordCount: Int) {
        let chars = Array(textBeforeCaret)
        var sentenceStart = 0
        var origin = SentenceStartOrigin.documentStart
        for k in chars.indices {
            let c = chars[k]
            if c.isNewline {
                sentenceStart = k + 1
                origin = .structuralBreak
                continue
            }
            if c == "." || c == "!" || c == "?" {
                // Decimal guard: a boundary only when whitespace or the end follows.
                if k + 1 >= chars.count || chars[k + 1].isWhitespace {
                    sentenceStart = k + 1
                    origin = .sentenceBoundary
                }
            }
        }
        let words = chars[sentenceStart...]
            .split(whereSeparator: { $0.isWhitespace })
            .count { $0.contains { $0.isWordCharacter } }
        return (origin, words)
    }

    // MARK: Arm 2 — "abandons a running thought" (output side)

    /// True when the model's **raw decode** carries a newline in its **leading boundary run** — its
    /// own structural-break signal, and the signature behind `… was` → `"8. Offene Punkte"`.
    ///
    /// Called by `MLXPredictionEngine` on **both** predict paths, each time *before* the shaping that
    /// flattens that run to a space (load-bearing: a ghost must never insert a Return):
    /// `ClauseStop.trimToWords` on the forward path, `FIMStop.finalize` on a bridge. The result is
    /// carried on `Suggestion` as one Bool. The flatten stays exactly as it is; what changes is that
    /// the *fact* of the break survives it.
    ///
    /// Only the leading run needs inspecting: `ClauseStop.firstClause` cuts at the first newline
    /// *after* content, so a newline inside the returned clause is impossible — the only newline a
    /// ghost's raw slice can carry sits ahead of the first word character.
    ///
    /// **Both arms apply to a FIM route.** Arm 2
    /// was forward-only until then, and `predictFIM` built its `Suggestion` from text alone — so the
    /// initialiser's `false` default asserted, on every bridge, that the decode had not abandoned the
    /// running thought. On the path that writes into the *middle* of the user's own text, that is the
    /// defaulted-flag trap, not a decision. `predictFIM` now computes the signal off its raw middle;
    /// the ordering there is unpinned by any test that reaches the call site, so
    /// `RunningThoughtGateOnTheFIMPathTests` pins the *reason* instead. (Arm 1 needs no call site of
    /// its own: it sits upstream of the route, in the reducer's context-ready handling.)
    public static func abandonsRunningThought(rawDecode: String) -> Bool {
        for c in rawDecode {
            if c.isWordCharacter { return false }   // leading boundary run ended: no break in it
            if c.isNewline { return true }
        }
        return false                                 // no content at all → the value gate answers
    }

    /// Apply arm 2 to the shaped continuation: **cut at the break and keep what precedes it**
    /// .
    ///
    /// Because the break sits in the *leading* boundary run, nothing renderable can precede it, so
    /// this degenerates to full suppression — provably, not incidentally (pinned by a test that
    /// shapes a pre-break slice and finds it empty). The rule is stated as a truncation anyway
    /// because that is what keeps the bar cheap: no predict is discarded wholesale when part of it
    /// genuinely continues the sentence.
    public static func continuation(_ text: String, abandonsRunningThought: Bool) -> String {
        abandonsRunningThought ? "" : text
    }
}
