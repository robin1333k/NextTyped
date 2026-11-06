/// Keys the acceptance layer reacts to — only meaningful while a suggestion shows;
/// the event tap passes them through to the host app otherwise.
///
/// `acceptAll` is named for its **action**, not its key, because its key moved: it was sketched as `→`
/// and left unwired, and the shortcut design bound it to **⌥Tab** instead — `→` is the
/// most-used navigation key and would be swallowed whenever a ghost is up. The other two still name the
/// keys they are, which are unchanged and fixed by the interception design.
public enum AcceptanceKey: Equatable, Sendable {
    case tab          // accept one continuation word — or apply a pending correction
    case acceptAll    // ⌥Tab — accept the whole continuation
    case escape       // dismiss
}

/// Outcome of typing *along* the continuation ghost — the user types characters the ghost already
/// predicts, so the ghost is trimmed in lockstep instead of re-inferred (SmartAdvance). The decision is pure; the coordinator turns it into render/refill/hide.
public enum TypeAlongResult: Equatable, Sendable {
    /// The typed text matched the ghost head; the buffer was trimmed (the display window slides
    /// forward). `exhausted` is true when nothing renderable remains → fetch the next suggestion.
    case advanced(exhausted: Bool)
    /// There is no continuation ghost to advance, or a correction currently owns the ghost — don't
    /// smart-advance; fall through to the normal (re-inferring) typing path.
    case notApplicable
    /// The typed text diverged from the ghost. The continuation is left untouched (the caller hides
    /// the stale ghost and re-infers); this only reports the divergence.
    case invalidated
}

/// What the host app should do in response to a key, decided by precedence.
public enum AcceptanceAction: Equatable, Sendable {
    /// Insert this text at the caret (one continuation word, or the whole suggestion).
    case insertContinuation(String)
    /// Replace the misspelled word with this correction.
    case applyCorrection(Correction)
    /// Dismiss any visible suggestion/correction; render nothing.
    case dismiss
    /// Nothing to offer — let the key reach the host app untouched.
    case passThrough
}

/// Pure state machine deciding what `Tab` / `→` / `Esc` do.
///
/// Corrections take **Tab precedence** over continuations: a correction targets the
/// word you JUST finished, a continuation is the NEXT words, so they rarely coexist —
/// but when they do, fixing the typo wins.
public struct AcceptanceStateMachine: Sendable {
    public private(set) var continuation: Suggestion?
    public private(set) var correction: Correction?

    /// How many words of the buffer the ghost shows — the user's Short/Medium/Long choice
    /// (`CompletionLength`). Held as state rather than read per paint
    /// so the machine stays pure, and settable at runtime (`setCompletionLength`) because the choice
    /// changes only the *view* of an already-decoded buffer.
    public private(set) var completionLength: CompletionLength

    /// Which accept keys insert trailing punctuation with the word. Held as state for the
    /// same reason as `completionLength`: the App seeds it through the reducer's settings event.
    public private(set) var trailingPunctuation: TrailingPunctuation

    public init(continuation: Suggestion? = nil,
                correction: Correction? = nil,
                completionLength: CompletionLength = .default,
                trailingPunctuation: TrailingPunctuation = .default) {
        self.completionLength = completionLength
        self.trailingPunctuation = trailingPunctuation
        self.correction = correction
        self.continuation = nil
        setContinuation(continuation)
    }

    /// Whether anything is currently on screen (and therefore whether we intercept keys).
    public var isShowingSomething: Bool {
        correction != nil || continuation != nil
    }

    /// The **sliding display window** over `continuation` — what the overlay should paint.
    /// `continuation` is the *full decoded clause* (the buffer) that `Tab` peels
    /// from word-by-word (at the word step only the word part is used, the rest is discarded); only the first `completionLength.maxWords` words are shown, so as Tab
    /// shrinks the buffer this window slides forward and reveals already-decoded words with **no
    /// re-inference**. Renders (and refill-on-exhaustion, `handleCaretMoved`) decide on `continuation`
    /// — the full buffer — but *paint* `displayContinuation`. Non-nil exactly when `continuation` is.
    public var displayContinuation: Suggestion? {
        guard let continuation else { return nil }
        return Suggestion(text: DisplayWindow.windowed(continuation.text, length: completionLength))
    }

    public mutating func setContinuation(_ suggestion: Suggestion?) {
        continuation = renderable(suggestion)
    }

    /// Adopt a new display length. **Display-only** — the buffer is untouched, so nothing is
    /// re-inferred and, at Short, Medium and Long, `Tab` keeps peeling across the whole clause; only how
    /// much of it is painted changes. At the word step `Tab` uses the word part and the rest of the
    /// buffer is discarded (word step). The buffer is re-run through the same gate because that gate judges the *window*: a
    /// shorter window could leave a punctuation-only head that must not paint, which is
    /// what keeps "`displayContinuation` is non-nil exactly when `continuation` is" true.
    public mutating func setCompletionLength(_ length: CompletionLength) {
        guard length != completionLength else { return }
        completionLength = length
        continuation = renderable(continuation)
    }

    /// Adopt a new trailing punctuation choice. It only changes how the **next** accept peels; the
    /// buffer and the ghost are untouched.
    public mutating func setTrailingPunctuation(_ value: TrailingPunctuation) {
        trailingPunctuation = value
    }

    /// Normalise a continuation to what's worth showing: `nil` unless it carries real word content
    /// (`SuggestionValueGate`). This generalises the old "drop empties" rule so a punctuation-/
    /// whitespace-only result (a bare `"."`, `"  "`) is also dropped — it never renders and `Tab`
    /// can't insert it. Short word-completions survive.
    ///
    /// The gate judges the **display window**, not the whole buffer: now that
    /// `continuation` stores the full clause but only the first `completionLength.maxWords` words are
    /// painted, a buffer whose *shown head* is punctuation-only is still junk even if a real word sits
    /// past the window — gating on the window keeps the pre-split "gate what's shown" semantics and stops
    /// `displayContinuation` ever painting a contentless ghost.
    private func renderable(_ suggestion: Suggestion?) -> Suggestion? {
        guard let suggestion,
              SuggestionValueGate.isRenderable(
                DisplayWindow.windowed(suggestion.text, length: completionLength),
                heldBackPunctuation: suggestion.heldBackPunctuation)
        else { return nil }
        return suggestion
    }

    public mutating func setCorrection(_ correction: Correction?) {
        self.correction = correction
    }

    /// Try to advance the continuation by text the user just typed (SmartAdvance).
    ///
    /// When the typed text matches the head of the visible continuation, trim it through the same
    /// `setContinuation` chokepoint `Tab` uses — so the full-clause buffer peels forward, the display
    /// window slides, and the value gate still judges the shown head. This is the
    /// "typing-along" case: the user "accepted" the ghost word by typing it, so the ghost shrinks with
    /// **zero re-inference** instead of lingering stale until the next prediction lands.
    ///
    /// A pending correction owns the ghost (it has visual precedence in `render`), so we never
    /// smart-advance under one (`.notApplicable`). Divergence reports `.invalidated` without mutating —
    /// the caller hides the stale ghost and re-infers.
    public mutating func advance(typed: String) -> TypeAlongResult {
        guard correction == nil, let current = continuation else { return .notApplicable }
        switch SmartAdvance.apply(typed: typed, to: current) {
        case .advanced(let remaining):
            setContinuation(remaining)                 // re-windows + value-gates the trimmed buffer
            return .advanced(exhausted: continuation == nil)
        case .invalidated:
            return .invalidated
        }
    }

    public mutating func handle(_ key: AcceptanceKey) -> AcceptanceAction {
        switch key {
        case .escape:
            guard isShowingSomething else { return .passThrough }
            continuation = nil
            correction = nil
            return .dismiss

        case .tab:
            if let pending = correction {              // correction wins Tab
                correction = nil
                return .applyCorrection(pending)
            }
            guard let current = continuation else { return .passThrough }
            let (word, remainder) = WordTokenizer.peelNextWord(
                from: current.text,
                holdingBackTrailingPunctuation: trailingPunctuation.holdsBackOnWordAccept)
            setContinuation(Suggestion(text: remainder,
                                       heldBackPunctuation: startsWithHeldBackPunctuation(remainder)))
            return .insertContinuation(word)

        case .acceptAll:
            guard let current = continuation else { return .passThrough }
            // The word step accepts the shown word part, not the buffered next words. The trailing
            // punctuation picker then applies to that part (word step).
            let accepted = completionLength == .word
                ? DisplayWindow.windowed(current.text, length: .word)
                : current.text
            continuation = nil
            guard trailingPunctuation.holdsBackOnFullAccept else { return .insertContinuation(accepted) }
            let (head, held) = WordTokenizer.splitTrailingPunctuation(from: accepted)
            setContinuation(Suggestion(text: held, heldBackPunctuation: true))
            return .insertContinuation(head)
        }
    }

    /// True when the peel left punctuation behind on purpose. A peel ends at whitespace or at the end
    /// of the text, so a remainder that does not start with whitespace can only be held-back punctuation.
    private func startsWithHeldBackPunctuation(_ remainder: String) -> Bool {
        trailingPunctuation.holdsBackOnWordAccept && !(remainder.first?.isWhitespace ?? true)
    }
}
