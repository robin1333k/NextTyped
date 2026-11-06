/// What kind of input triggered a potential change to the on-screen suggestion.
public enum SuggestionTrigger: Equatable, Sendable {
    /// A text-producing keystroke. Always re-enables suggestions and regenerates.
    case typing
    /// Pure navigation moved the caret (click, ←/→, ↑/↓, Home/End, Page, Return) —
    /// no character was typed.
    case caretMoved
    /// The refill after an accept exhausted the continuation buffer: our own inserted text echoed
    /// back through AX and the caret is now at the end of a word **we** just typed.
    ///
    /// Mechanically this is a caret move and it is treated as one everywhere the loop reasons about
    /// caret movement — the proactive/redundancy block, the debounce, "no correction on a move" — and
    /// like the old path it bypasses the Esc mute by never being routed through ``SuggestionLifecycle``
    /// at all. It is a case of its own only because it is the one caret move the user did not make:
    /// ``WordCompletionGate`` refuses a glued continuation at a *navigated* word end, and collapsing
    /// the two back together would break the `Tab` accept chain at every buffer exhaustion
    /// .
    case acceptRefill
    /// The user pressed the **force-activate** shortcut: ask for a suggestion here even though our own cold-start gates declined to offer
    /// one. It is neither typing nor a caret move — nothing changed in the document — which is exactly
    /// why it is its own case: `isCaretMove` must stay false so the redundancy replay cannot answer an
    /// explicit press with the cached suggestion it is being pressed to get past.
    case forceActivate
    /// The user explicitly dismissed (Esc).
    case dismissed
    /// The focused field/window changed — a fresh context.
    case focusChanged
    /// Context is unusable: a secure/password field, a disabled app, paused, or no AX text.
    case cannotPredict

    /// The lower-case name the `[gate]:` tokens print.
    public var logName: String {
        switch self {
        case .typing: return "typing"
        case .caretMoved: return "caretMoved"
        case .acceptRefill: return "acceptRefill"
        case .forceActivate: return "forceActivate"
        case .dismissed: return "dismissed"
        case .focusChanged: return "focusChanged"
        case .cannotPredict: return "cannotPredict"
        }
    }

    /// True for the triggers whose caret arrived without a keystroke, so the loop's caret-move
    /// reasoning (proactive gate, redundancy replay, no-correction, the settle debounce) applies.
    /// Derived rather than hand-listed at each site, so the accept refill cannot silently fall out
    /// of one of them.
    public var isCaretMove: Bool {
        self == .caretMoved || self == .acceptRefill
    }
}

/// How the loop should react to a trigger.
public enum SuggestionReaction: Equatable, Sendable {
    /// Schedule a fresh prediction at the current caret (still subject to `CaretPositionGate`).
    case regenerate
    /// Hide and drop everything; do NOT regenerate.
    case clear
    /// Leave things as they are — nothing on screen to change.
    case hold
}

/// Pure state machine for the "regenerate, don't discard" model: caret *movement*
/// regenerates the suggestion at the new position; an explicit dismiss (Esc) and
/// "can't predict" hard-clear.
///
/// After an Esc, *proactive* (caret-movement) regeneration is muted until the user
/// types again or the focus changes — so Esc reliably means "quiet until I write
/// again." Typing-driven regeneration is never muted.
///
/// This decides *policy* only (regenerate / clear / hold). The caller still applies
/// `CaretPositionGate` (is this a sane caret position?) and the redundancy guard
/// (did the prediction-relevant context actually change?) before inferring, and owns
/// rendering details like "hide the mispositioned ghost immediately on a caret move".
public struct SuggestionLifecycle: Sendable {
    /// True while caret-movement regeneration is muted after an Esc.
    public private(set) var proactiveSuppressed: Bool

    public init(proactiveSuppressed: Bool = false) {
        self.proactiveSuppressed = proactiveSuppressed
    }

    public mutating func react(to trigger: SuggestionTrigger) -> SuggestionReaction {
        switch trigger {
        case .typing:
            proactiveSuppressed = false        // writing again lifts the Esc mute
            return .regenerate

        case .caretMoved, .acceptRefill:
            // Movement regenerates — unless an Esc muted proactive suggestions, in which
            // case there is nothing on screen and we leave it that way until the user types.
            //
            // `.acceptRefill` never actually arrives here: the refill is scheduled directly from the
            // host echo precisely so it bypasses the mute (an Esc cannot strand a half-accepted
            // clause). It shares the arm so that a future route into the lifecycle gets the caret-move
            // policy rather than a compiler error answered by a guess.
            return proactiveSuppressed ? .hold : .regenerate

        case .dismissed:
            proactiveSuppressed = true         // Esc = quiet until next keystroke / focus change
            return .clear

        case .focusChanged:
            proactiveSuppressed = false         // new field = fresh start; nothing to show yet
            return .clear

        case .forceActivate:
            // An explicit press is a statement of intent, like typing: it lifts the Esc mute and
            // regenerates. Never actually arrives here today — `.forceActivate` schedules its predict
            // directly, the same bypass `.acceptRefill` uses, so an Esc mute cannot swallow the one
            // key pressed to get a suggestion. The arm exists so a future route into the lifecycle
            // gets the explicit-action policy rather than a compiler error answered by a guess.
            proactiveSuppressed = false
            return .regenerate

        case .cannotPredict:
            return .clear
        }
    }
}
