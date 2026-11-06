/// The value types of the `SuggestionSession` reducer's interface: the **events** the App
/// feeds in, the **effects** the App interprets, and the **presentation** the App paints. Semantic
/// payloads only — no pixels, no AX types, no clock crosses this seam, so the whole suggestion-decision
/// policy is pure and unit-testable with no running app.

/// What the reducer wants shown for the focused context. The App fetches caret geometry and decides
/// inline-vs-bubble/wrap; the reducer only says *what* (correction › continuation › nothing).
public enum Presentation: Equatable, Sendable {
    /// Paint this continuation ghost (already the sliding display window).
    case continuation(ContinuationGhost)
    /// Paint this correction (prefix-diff strike + green fix).
    case correction(Correction)
    /// Nothing on screen.
    case none
}

/// The continuation half of a `Presentation`: the text to paint, plus the one fact the App needs to
/// paint it *honestly* — whether accepting will consume the space immediately before the caret
/// . A ghost that will eat that space must be drawn one space-width
/// further left, or the preview reads `Winter. Es` while `Tab` produces `Winter. Es`.
///
/// It rides **inside** `Presentation` rather than beside it as a second session getter, because the
/// App's re-paint guard (`session.currentPresentation == presentation` after the caret `await`) is
/// what keeps a paint from resurrecting superseded state — a fact carried outside the value it
/// guards would not be covered by it.
///
/// `ExpressibleByStringLiteral` so `.continuation("…")` still constructs and pattern-matches the
/// ordinary insert-only ghost: that is the case in every existing call site and assertion, and
/// spelling `consumesPrecedingSpace: false` at each of them would bury the one place it is true.
public struct ContinuationGhost: Equatable, Sendable, ExpressibleByStringLiteral {
    public var text: String
    /// Accepting replaces the character before the caret (a space) rather than inserting after it.
    public var consumesPrecedingSpace: Bool

    public init(_ text: String, consumesPrecedingSpace: Bool = false) {
        self.text = text
        self.consumesPrecedingSpace = consumesPrecedingSpace
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// The `Double`/`Bool` caret facts the gates need — carried across the App→Core seam in `.contextReady`
/// so no AX type (`CaretInfo`, `CGRect`) leaks into the pure reducer. Currently just the
/// "is there host text to the right of the caret on this line" signal the mid-text (FIM) gate keys on.
public struct CaretFacts: Equatable, Sendable {
    /// True when visible host text sits immediately right of the caret on the same line — inline ghost
    /// would paint over it. Until FIM is wired, a caret-move suggestion is suppressed when this is true.
    public var hasTextToRight: Bool

    public init(hasTextToRight: Bool) {
        self.hasTextToRight = hasTextToRight
    }
}

/// Events the App translates from tap/AX/async callbacks and feeds to `SuggestionSession.handle`
/// (the synchronous `Tab`/`⌥Tab`/`Esc` verdict goes through `interceptKey` instead — it must return a
/// `TapDecision`). `.contextReady`/`.predictionArrived` are the two-phase async-prediction re-entries:
/// the App's single cancelable predict Task fetches context+caret then dispatches `.contextReady`
/// (gates + redundancy run), and — if that asks for inference — spell-checks + predicts then dispatches
/// `.predictionArrived` (value-gate + `setContinuation` run). Cancel-checked around each await App-side,
/// so a superseded pipeline never dispatches a stale event and the reducer needs no stale-guard.
public enum Event: Equatable, Sendable {
    /// A text-producing keystroke (the typed string). Lifts the Esc mute; smart-advances or re-infers.
    case typed(String)
    /// Pure keyboard navigation OR a delete moved/shrank the text under the caret (no character typed).
    case caretMove
    /// A mouse click moved the caret. AX selection-changed doesn't fire for clicks in some apps, so the
    /// tap drives this directly.
    case pointer
    /// A ⌘⇧3/4/5 screenshot shortcut — arm a brief window so the capture-selection drag can't dismiss.
    case screenshotShortcut
    /// The App's 12 s screenshot-disarm timer elapsed.
    case screenshotDisarmExpired
    /// An AX selection-changed echo from OUR own insert (`Tab`-accept) or a SmartAdvance type-along
    /// host insert settled — re-render the remaining ghost in place, or refill the next at the new caret.
    case hostEcho
    /// Focus moved to a different field/window — a fresh context.
    case focusChanged
    /// Phase 1 of the predict pipeline: context + caret facts are ready. `context == nil` means no usable
    /// context (AX gave nothing, or the app is policy-disabled) → the cannot-predict clear. `caret == nil`
    /// means AX exposed no caret geometry (treated as "text to the right" by the proactive gate, matching
    /// the prior `caret?.hasTextToRight == false` rule).
    ///
    /// `rejection` says why `context` is `nil`; the reducer logs it as `no-context reason=`
    /// (`app-off` stays silent, because `ContextAssembler` already logged its own `[gate]: app-off` line).
    case contextReady(TypingContext?, caret: CaretFacts?, trigger: SuggestionTrigger,
                      rejection: ContextRejection? = nil)
    /// Phase 2 of the predict pipeline: inference (+ optional spell-fix) landed.
    case predictionArrived(Suggestion, Correction?)
    /// The spell check suspects a typo at the caret: no predict ran.
    /// The reducer shows no continuation, keeps the correction, and logs `[gate]: typo-suspected`.
    case typoSuspected(Correction?)
    /// First-paint streaming: the first words of a decode that is still running. Painted through
    /// the same shaping as `.predictionArrived`; the full decode follows as `.predictionArrived` and
    /// extends the buffer past whatever the user took off the early ghost in between.
    case firstWordsArrived(Suggestion, Correction?)
    /// The App cancelled the pending predict run on its own, outside a `.cancelInFlight` effect (a
    /// scroll or zoom reuses the single slot for its reposition task). No full decode follows, so an
    /// early paint of that run stops waiting for one.
    case runCancelled
    /// The pause toggle flipped. Pausing cancels in-flight work and clears; un-pausing just resumes.
    case setPaused(Bool)
    /// The mid-text-completion (FIM) toggle flipped in Settings (opt-in, default **off**).
    /// It changes which model a mid-text caret would route to, so a flip tears down anything currently
    /// showing rather than leaving a ghost the other path produced.
    case setFIMEnabled(Bool)
    /// The English spelling variant changed in Settings (default **off**). The buffer the ghost
    /// is cut from was already rewritten for the old variant, so a flip tears down what is showing
    /// and the redundancy cache is dropped, so the next keystroke or caret move predicts again in the new one.
    case setSpellingVariant(SpellingVariant)
    /// The user pressed the **force-activate** shortcut: predict here even though our own
    /// cold-start gates declined to. It overrides only
    /// what *we* decided — never the app's own on/off state, never a pause, never a
    /// temporary quiet, all of which sit above the reducer or ahead of this event.
    case forceActivate
    /// The user asked the app they are writing in to go quiet for a while.
    /// A **transient** layer above the stored per-app preference and never a write to it — the
    /// reducer holds the set in memory and has no access to the settings store at all, so "it can only
    /// suppress, and it does not survive a relaunch" is structural rather than a promise.
    case temporaryQuietStarted(bundleID: String)
    /// The quiet ended. `resumedExplicitly` carries the asymmetry decision 3c turns on: a user who
    /// pressed *resume* gets a ghost back immediately, an **expiring timer** produces nothing — the
    /// user did nothing at that moment, may not be looking, may be in another app entirely.
    case temporaryQuietEnded(bundleID: String, resumedExplicitly: Bool)
    /// The Short / Medium / Long completion-length picker changed. A
    /// **display-only** flip: the buffer is already decoded, so a visible ghost is simply re-painted at
    /// the new window — never cancelled, never re-inferred.
    case setCompletionLength(CompletionLength)
    /// The App's grace clock for presentation `generation` ran out:
    /// that ghost has been on screen for `tabGraceMs` and may now take `Tab`. Ignored unless
    /// `generation` is still the current one, so a late timer for a replaced ghost cannot settle its
    /// successor.
    case ghostSettled(generation: Int)

    /// The battery posture changed: power source, the on-demand preference or the
    /// force-activate shortcut assignment. A settings event, so it lands while paused. The App sends it
    /// only when the posture differs from the last one it sent.
    case setBatteryPosture(BatteryPosture)

    /// The trailing punctuation picker changed. A settings flip with no visible effect: it
    /// only decides how the **next** `Tab` or `⌥Tab` peels, so nothing is repainted or re-inferred.
    case setTrailingPunctuation(TrailingPunctuation)

    /// The Esc behaviour picker changed. A settings flip; switching to `dismissOnly` ends a
    /// running field pause without predicting.
    case setEscBehaviour(EscBehaviour)
    /// The field-pause timer from `.scheduleFieldPauseExpiry` ran out. `generation` matches the Esc
    /// that armed it, so a timer from an earlier Esc cannot end a later pause.
    case fieldPauseExpired(generation: Int)
    /// Another app took Secure Input, so the tap sees no keystrokes. A ghost on screen
    /// could not be accepted, so it is hidden. The next keystroke after the hold ends predicts as usual.
    case eventTapBlinded
}

/// Effects the reducer returns for the App's thin runtime to interpret (IO, timers, the single
/// cancelable predict Task). Carry semantic payloads only.
public enum Effect: Equatable, Sendable {
    /// Insert this text at the caret via synthetic key events.
    case insert(String)
    /// Replace `charactersBack` characters before the caret with `with` (apply a correction).
    case replace(charactersBack: Int, with: String)
    /// Paint this presentation (the App fetches caret geometry; `.none` hides + stops the geometry poll).
    case present(Presentation)
    /// Start the (single, cancelable) predict pipeline after `debounceMs`: re-issuing it cancels any
    /// in-flight predict first (single slot). The App fetches context+caret and re-enters via
    /// `.contextReady`.
    case schedulePredict(trigger: SuggestionTrigger, debounceMs: Int)
    /// Continue the current predict Task into inference: spell-check (iff `wantsCorrection`) + predict
    /// (iff `wantsContinuation`), then re-enter via `.predictionArrived`. Emitted only by
    /// `.contextReady`; interpreted inline by the predict Task, not as a standalone runtime action.
    ///
    /// The two halves are separately switchable because the cold-start gates are **continuation**
    /// gates: refusing a continuation in a small search field or at a sentence
    /// with no running thought must not also refuse the spell fix, or the first word of every line is
    /// permanently outside it. Deliberately a second flag rather than a second effect case — the App
    /// has one async pipeline built around this effect (single in-flight Task, cancel-checked around
    /// each await, re-entry via `.predictionArrived`), and a second case would either
    /// duplicate that pipeline or open a second door into it. With `wantsContinuation` false the
    /// interpreter skips the model entirely and re-enters with an empty suggestion, so the correction
    /// still resolves through the one presentation path.
    case runInference(TypingContext, wantsCorrection: Bool, wantsContinuation: Bool)
    /// Cancel the in-flight predict Task (a teardown that does not itself re-schedule).
    case cancelInFlight
    /// Start/restart the screenshot-disarm timer; on elapse the App dispatches `.screenshotDisarmExpired`.
    case scheduleScreenshotDisarm(seconds: Int)
    /// A fresh ghost was just presented and is **unsettled**: start the `tabGraceMs` clock once the
    /// overlay has painted it, then dispatch `.ghostSettled(generation:)`. Always emitted
    /// right after the `.present` it belongs to, so the list-order walk starts the clock after the paint.
    /// A newer generation supersedes an older clock.
    case scheduleSettle(generation: Int)

    /// Start the Esc field-pause timer; on elapse the App dispatches
    /// `.fieldPauseExpired(generation:)` with the same generation. A newer one replaces an older one.
    case scheduleFieldPauseExpiry(seconds: Int, generation: Int)
    /// A DEBUG observability token the reducer wants in the app log, emitted as `[gate]: <payload>`.
    /// The one effect that carries no action — and it earns its place: a gate suppression is
    /// otherwise indistinguishable in the log from every other `.present(.none)`, while the running-thought gate
    /// makes its operating condition (*local and quiet*) falsifiable only as a **rate**. If the
    /// app falls silent across paragraphs the signature is too broad, not the bar too high — and this
    /// token is what lets a harness scenario assert that rather than a human feeling it.
    case logGate(String)
    /// What this predict run decided about the surface: exactly one per `.contextReady`, ahead
    /// of the run's other effects. The App keeps the last one in memory for the menu-bar status line.
    case surfaceVerdict(SurfaceVerdict)
}
