/// The pure-Core, time-free, synchronous **event-reducer** that owns the live suggestion
/// decision-state for the focused context. Events in, effects out; the App shell is a thin
/// runtime that translates tap/AX/async callbacks into `Event`s, executes the returned `Effect`s, and
/// re-enters async results as further events.
///
/// This collapses the ~150 lines of suggestion-decision *policy* that used to live inlined across
/// `AppCoordinator` — the one layer that **cannot be unit-tested** (AX/event-tap/overlay) —
/// into one deep module composed of the existing tested seams (`AcceptanceStateMachine`,
/// `SuggestionLifecycle`, the gates, `SmartAdvance`, `DisplayWindow`). The sharpest payoff: the former
/// `postInsertRenderPending` echo-flag, whose invariant was a *comment* (armed 2×, reset 3×), is now `echoPending` — **enforced** internal state, dropped on every teardown via the
/// single `clearPresentation()` chokepoint.
///
/// Structure, not behaviour: the earlier suggestion-lifecycle rules are preserved exactly. The reducer
/// is a plain `mutating struct` the `@MainActor` coordinator holds (pure, synchronous, on main).
public struct SuggestionSession: Sendable {
    // MARK: Composed internal seams (their own tests untouched)

    private var acceptance: AcceptanceStateMachine
    /// "Regenerate, don't discard": caret movement regenerates; Esc mutes proactive regen
    /// until the next keystroke / focus change.
    private var lifecycle: SuggestionLifecycle

    // MARK: Newly-internal decision state (was App fields)

    /// An AX echo from OUR OWN insert is pending and must re-render the CURRENT ghost. Armed when we
    /// emit an insert/replace (`Tab`-accept) AND on a matching `.typed` type-along (`.advanced`);
    /// consumed/cleared on `.hostEcho`; dropped on *every* teardown (`clearPresentation`). This replaces
    /// the comment-only `postInsertRenderPending` invariant with enforced state.
    private var echoPending = false

    /// Redundancy guard: the context + suggestion of the last real inference, so a no-op caret move
    /// (←then→, page-no-move, re-click) restores the cached suggestion instead of re-inferring.
    private var lastContext: TypingContext?
    /// Internal (not private) so the tests can pin what the cache is *told* — the flag it carries is a
    /// guarantee a future reader inherits, not an incidental default.
    private(set) var lastSuggestion: Suggestion?

    /// The context that emitted `.runInference`, stashed so `.predictionArrived` can record it as
    /// `lastContext` (the prediction result event doesn't re-carry the context).
    private var pendingContext: TypingContext?
    /// The trigger that emitted `.runInference`, stashed alongside `pendingContext` for the same
    /// reason: `WordCompletionGate` runs in phase 2 (it judges the model's *text*) but its
    /// discriminator — how the caret got here — is only known in phase 1.
    private var pendingTrigger: SuggestionTrigger?
    /// First-paint streaming: the early paint of the pending run and what the user did with it
    /// before the full decode lands. `nil` when no early paint waits for its full decode.
    private var firstPaint: FirstPaintState?

    private enum FirstPaintState: Sendable {
        /// The early ghost is up. `consumed` is the ghost text the user has taken since (Tab, accept
        /// all, typing along), always a prefix of the painted buffer; `showedCorrection` says the early
        /// paint already showed the run's spell correction, so the full decode must not set it again.
        case waiting(consumed: String, showedCorrection: Bool)
        /// A teardown cleared the early ghost: the full decode describes a caret that is gone.
        case dropped
    }

    /// True while an early paint waits for a full decode that will still arrive.
    private var firstPaintWaits: Bool {
        if case .waiting = firstPaint { return true }
        return false
    }

    private mutating func recordFirstPaintConsumed(_ text: String) {
        guard case .waiting(let consumed, let showedCorrection) = firstPaint else { return }
        firstPaint = .waiting(consumed: consumed + text, showedCorrection: showedCorrection)
    }

    /// While armed (just after a ⌘⇧3/4/5 shortcut) a click does NOT dismiss the suggestion — so the
    /// capture-selection drag can't wipe it mid-screenshot. The 12 s disarm is an App timer
    /// (`.scheduleScreenshotDisarm` → `.screenshotDisarmExpired`); the reducer just flips this Bool.
    private var screenshotArmed = false

    /// What Esc does beyond hiding the ghost. `.dismissOnly` until the App sends
    /// `.setEscBehaviour`, so every existing scenario keeps the old Esc.
    private(set) var escBehaviour: EscBehaviour = .dismissOnly
    /// The Esc field pause: the generation of the Esc that armed it, or `nil` when no field is paused.
    /// Ends on a focus change, on its own timer (matched by generation) or on a switch to `.dismissOnly`.
    private var fieldPauseGeneration: Int?
    /// Counts field pauses so each timer carries its own generation.
    private var fieldPauseCounter = 0

    /// Accepts the user may take back, and the ones they did.
    private(set) var takeBack = TakeBackMemory()
    /// The text before the caret where the current ghost stands: the predicted context's prefix plus
    /// everything accepted or typed along since. Tracked here, never re-read from AX at accept time,
    /// because `interceptKey` runs on the tap path. `nil` when unknown (no ghost, or a
    /// correction changed the text), and then an accept records no anchor.
    private var ghostPrefix: String?

    /// Paused: input is ignored and nothing is shown until resumed.
    private var paused = false

    /// Spelling corrections the user typed past, per word. Lives as long as the
    /// session, so for the rest of the process; never stored.
    private(set) var spellRefusals = SpellRefusalLedger()
    /// Characters typed since the current correction was set, or `nil` once its refusal question is
    /// settled. Non-empty at a word boundary means the correction targets a shorter prefix of the word
    /// the boundary closes, so it is not a refusal of that word.
    private var typedSinceCorrection: String?

    /// Apps the user has temporarily quieted. In-memory by construction, so
    /// it cannot survive a relaunch, and write-only through the two `temporaryQuiet…` events, so it can
    /// never reach the stored per-app preference the Apps pane owns: "I have turned TextEdit off" and
    /// "quiet for fifteen minutes" are different statements, and an expiring timer that restored a
    /// *guessed* value could end up ENABLING an app the user had deliberately disabled.
    /// Internal rather than private so a test can pin the set itself, not only its consequences.
    private(set) var temporarilyQuietBundleIDs: Set<String> = []

    /// Mid-text insertion needs a FIM model: while OFF a caret-move suggestion is
    /// suppressed when there is host text to the right of the caret. Ships **opt-in, default off** as a
    /// normal feature toggle, so it is settable at runtime via `.setFIMEnabled` — not a construction-time
    /// constant, or flipping the switch would need the session (and with it `paused`) rebuilt.
    private var fimEnabled: Bool

    // MARK: Tab grace window

    /// Whether a fresh ghost must SETTLE before it may take `Tab`/`⌥Tab`. The App passes
    /// `tabGraceMs > 0`; with it off no presentation ever starts unsettled and no `.scheduleSettle` is
    /// emitted, so `tabGraceMs = 0` is today's behaviour by construction rather than by a zero-length
    /// timer racing the tap. A construction constant, because the knob is read once at launch.
    private let tabGrace: Bool
    /// Bumped for every presentation that starts unsettled; `.ghostSettled` must name the current one.
    private var presentationGeneration = 0
    /// The current presentation may take `Tab`. Only meaningful while something is showing.
    private var presentationSettled = true
    /// Whether the cached `lastSuggestion` had settled when last shown, so a redundancy replay of a
    /// ghost the user already had in view for the whole grace window does not make them wait again.
    private var lastSuggestionSettled = true
    /// Whether the pending echo, and so the refill it may schedule, follows the USER typing the ghost to
    /// its end rather than OUR insert. Set by both writers of `echoPending`; every `.acceptRefill` comes
    /// from `handleHostEcho`, so the value read at the refill's presentation is always the current one.
    private var echoFollowsTypeAlong = false

    /// The battery posture. `.normal` until the App sends `.setBatteryPosture`, so every
    /// existing scenario is untouched while the preference is off.
    private(set) var batteryPosture: BatteryPosture = .normal

    /// True while the ghost on screen came from a trigger on-demand mode allows (force-activate or the
    /// accept refill). A flip into on-demand clears only a ghost this flag does not cover.
    private var ghostIsOnDemandExempt = false

    /// English spelling variant applied to the finished continuation. Like the completion
    /// length it is not a construction parameter: the App seeds it with `.setSpellingVariant`.
    private var spellingVariant: SpellingVariant = .off

    /// The completion length is deliberately **not** a construction parameter: the App seeds it with
    /// `.setCompletionLength` at launch on the same path a later flip takes, so there is one route into
    /// the reducer instead of a second one only the initialiser could use.
    /// The emoji names behind the `:fragment` trigger. Injected so tests can use a small one.
    private let emojiLexicon: EmojiLexicon

    /// The last `:fragment` that logged `[gate]: emoji-no-match`, so one request logs once.
    private var lastEmojiNoMatch: String?

    public init(fimEnabled: Bool = false, emojiLexicon: EmojiLexicon = .bundled, tabGrace: Bool = false) {
        self.emojiLexicon = emojiLexicon
        self.acceptance = AcceptanceStateMachine()
        self.lifecycle = SuggestionLifecycle()
        self.fimEnabled = fimEnabled
        self.tabGrace = tabGrace
    }

    /// Whether the current presentation is a **settled ghost**: one `Tab` would accept.
    /// Read by the DEBUG harness snapshot so `wait ghost` can wait for the moment `Tab` is ours.
    public var isPresentationSettled: Bool { presentationSettled }

    // MARK: Derived presentation (the App re-paints from this at fresh pixels)

    /// What should currently be on screen — correction takes visual precedence, then the continuation
    /// display window, else nothing. A pure derived getter: the App's geometry poll + viewport re-render
    /// read it to re-paint at fresh caret geometry without re-deciding the suggestion.
    public var currentPresentation: Presentation {
        if let correction = acceptance.correction {
            return .correction(correction)
        }
        if let display = acceptance.displayContinuation {
            // The window is a derived VIEW of the buffer, so the join verdict is read from
            // the buffer itself — `DisplayWindow` only slices text.
            return .continuation(ContinuationGhost(
                display.text,
                consumesPrecedingSpace: acceptance.continuation?.consumesPrecedingSpace ?? false))
        }
        return .none
    }

    // MARK: The synchronous tap verdict (Tab / → / Esc)

    /// The event tap's synchronous path: a key that may be *intercepted* needs a `TapDecision` returned
    /// to macOS **now**, and that verdict is not a function of the effects (Esc dismisses the ghost yet
    /// still passes through to the host). `AcceptanceKey` is the precise intercept-candidate type
    /// (tab/→/esc), reusing the existing
    /// Core type.
    public mutating func interceptKey(_ key: AcceptanceKey) -> (TapDecision, [Effect]) {
        guard !paused else { return (.passThrough, []) }
        switch key {
        case .tab, .acceptAll:
            // Only intercept while something is showing; otherwise the host keeps Tab and ⌥Tab
            // untouched (indentation, field navigation, terminal completion). This ghost-visible gate
            // is the whole reason intercepting Tab is tolerable at all, and ⌥Tab inherits it —
            // which is what makes the second accept key an *extension* of the posture rather than a
            // change to it.
            guard acceptance.isShowingSomething else { return (.passThrough, []) }
            // The grace window: a ghost that appeared a moment ago
            // may have appeared under a Tab the user had already decided to press for the HOST
            // (indent, next field). Hand that Tab to the host, and since the host just moved the caret
            // or inserted a tab, the ghost is stale: clear and regenerate exactly as a caret move does.
            guard presentationSettled else {
                screenshotArmed = false
                return (.passThrough, [.logGate("tab-grace")]
                        + hideForCaretMoveEffects() + regenerateForCaretMoveEffects())
            }
            // Read BEFORE `handle` mutates: the flag belongs to the buffer this accept peels from, and
            // the remainder it leaves behind deliberately carries `false` (see `Suggestion`).
            let consumesPrecedingSpace = acceptance.continuation?.consumesPrecedingSpace ?? false
            return (.suppress, apply(acceptance.handle(key),
                                     consumesPrecedingSpace: consumesPrecedingSpace))

        case .escape:
            // Esc always hard-clears + mutes proactive regen (the "quiet until I write again" semantic
            // holds even with nothing currently shown — a later click stays quiet), but still reaches the
            // host so its own Esc handling runs. This mirrors the old App `.dismiss` tap case, which never
            // gated on `isShowingSomething`.
            // EXCEPT while the screenshot window is armed: there Esc means "cancel the ⌘⇧3/4/5
            // crosshair", not "dismiss the ghost" — the arm window exists precisely so the capture
            // interaction can't wipe the ghost. Stay armed (the disarm
            // timer / next keystroke ends the window), don't mute, keep the presentation.
            guard !screenshotArmed else { return (.passThrough, []) }
            // Read BEFORE the clear: the field pause answers an Esc that dismissed something.
            let dismissedSomething = acceptance.isShowingSomething
            _ = lifecycle.react(to: .dismissed)   // proactiveSuppressed = true
            let dismissal = [.cancelInFlight] + clearPresentation()
            switch escBehaviour {
            case .dismissOnly:
                return (.passThrough, dismissal)
            case .dismissAndPauseField:
                // The Esc picker's second choice: this field stays quiet, typing included, until
                // the timer or a focus change. It arms only when the Esc dismissed a ghost or a
                // correction, or restarts a pause already running (with a new generation). An Esc
                // meant for the host with nothing shown (a popover, vim's insert mode, a find bar)
                // gets the plain mute above and no pause.
                guard dismissedSomething || fieldPauseGeneration != nil else {
                    return (.passThrough, dismissal)
                }
                fieldPauseCounter += 1
                fieldPauseGeneration = fieldPauseCounter
                return (.passThrough, dismissal + [.scheduleFieldPauseExpiry(
                    seconds: EscBehaviour.fieldPauseSeconds, generation: fieldPauseCounter)])
            }
        }
    }

    // MARK: Events

    public mutating func handle(_ event: Event) -> [Effect] {
        // Paused: ignore all *input* (the App also cancels in-flight work on pausing). The two settings
        // events still land — dropping a Settings flip because the app happened to be paused would leave
        // the reducer disagreeing with the switch the user just moved.
        if paused, !Self.isSettingsEvent(event) { return [] }

        switch event {
        case .typed(let text):
            screenshotArmed = false   // back to editing → clicks dismiss again (mirrors the old `.character` disarm)
            return handleTyped(text)

        case .caretMove:
            // Hide the now-stale ghost and regenerate at the new caret (the ~150 ms predict debounce
            // doubles as the caret-settle delay). A keystroke/move also disarms the screenshot window.
            screenshotArmed = false
            return hideForCaretMoveEffects() + regenerateForCaretMoveEffects()

        case .pointer:
            // A click keeps the suggestion during the screenshot-arm window; otherwise hide + regenerate.
            // (Does not itself disarm — only checks the flag, matching the old tap `.pointer` case.)
            guard !screenshotArmed else { return [] }
            return hideForCaretMoveEffects() + regenerateForCaretMoveEffects()

        case .screenshotShortcut:
            screenshotArmed = true
            return [.scheduleScreenshotDisarm(seconds: 12)]

        case .screenshotDisarmExpired:
            screenshotArmed = false
            return []

        case .hostEcho:
            return handleHostEcho()

        case .focusChanged:
            // New field = fresh start: lift the Esc mute, drop the redundancy cache, cancel + clear.
            _ = lifecycle.react(to: .focusChanged)   // proactiveSuppressed = false
            fieldPauseGeneration = nil                // the Esc field pause belongs to the old field
            takeBack.clear()                          // so do the accept anchors
            lastContext = nil
            lastSuggestion = nil
            return [.cancelInFlight] + clearPresentation()

        case .contextReady(let context, let caret, let trigger, let rejection):
            let verdict = surfaceVerdict(context, caret: caret, trigger: trigger, rejection: rejection)
            return [.surfaceVerdict(verdict)]
                + handleContextReady(context, caret: caret, trigger: trigger, rejection: rejection)

        case .predictionArrived(let suggestion, let correction):
            return handlePredictionArrived(suggestion, correction)

        case .typoSuspected(let correction):
            return [.logGate("typo-suspected")] + handlePredictionArrived(Suggestion(text: ""), correction)

        case .firstWordsArrived(let suggestion, let correction):
            return handleFirstWordsArrived(suggestion, correction)

        case .runCancelled:
            return handleRunCancelled()

        case .setPaused(let isPaused):
            return handleSetPaused(isPaused)

        case .setFIMEnabled(let enabled):
            return handleSetFIMEnabled(enabled)

        case .setSpellingVariant(let variant):
            return handleSetSpellingVariant(variant)

        case .setCompletionLength(let length):
            return handleSetCompletionLength(length)

        case .setBatteryPosture(let posture):
            return handleSetBatteryPosture(posture)
        case .setTrailingPunctuation(let value):
            acceptance.setTrailingPunctuation(value)
            return []

        case .setEscBehaviour(let value):
            escBehaviour = value
            if value == .dismissOnly { fieldPauseGeneration = nil }
            return []

        case .eventTapBlinded:
            return hideForCaretMoveEffects()

        case .fieldPauseExpired(let generation):
            // An expiring timer shows nothing; the next keystroke predicts.
            if fieldPauseGeneration == generation { fieldPauseGeneration = nil }
            return []

        case .forceActivate:
            return handleForceActivate()

        case .temporaryQuietStarted(let bundleID):
            return handleTemporaryQuietStarted(bundleID)

        case .temporaryQuietEnded(let bundleID, let resumedExplicitly):
            return handleTemporaryQuietEnded(bundleID, resumedExplicitly: resumedExplicitly)

        case .ghostSettled(let generation):
            // A late clock for a replaced ghost must not settle its successor.
            guard generation == presentationGeneration, !presentationSettled else { return [] }
            presentationSettled = true
            lastSuggestionSettled = true
            return []
        }
    }

    // MARK: Typing (SmartAdvance type-along)

    private mutating func handleTyped(_ text: String) -> [Effect] {
        _ = lifecycle.react(to: .typing)   // writing again lifts any Esc mute
        let refusalEffects = recordRefusalIfAny(typed: text)
        return refusalEffects + handleTypedAlong(text)
    }

    /// A boundary typed while a correction is presented and untouched since it was set refuses that
    /// correction. `Tab` and `Esc` clear the correction first, so they never reach here with one.
    private mutating func recordRefusalIfAny(typed text: String) -> [Effect] {
        guard let correction = acceptance.correction, let first = text.first, let since = typedSinceCorrection else {
            return []
        }
        if first.isWhitespace || first.isPunctuation {
            typedSinceCorrection = nil
            guard since.isEmpty else { return [] }
            return spellRefusals.recordRefusal(of: correction.original) ? [.logGate("spell-ignore-armed")] : []
        }
        typedSinceCorrection = since + text
        return []
    }

    private mutating func handleTypedAlong(_ text: String) -> [Effect] {
        switch acceptance.advance(typed: text) {
        case .advanced(let exhausted):
            // The keystroke matched the ghost head: the buffer was trimmed in place (the display window
            // slides). Drop any in-flight predict so a stale result can't undo the trim; the host's own
            // insert echoes as `.hostEcho`, which re-renders the shrunk ghost (or refills on exhaustion) —
            // exactly the `Tab`-accept path. Zero re-inference.
            //
            // On EXHAUSTION hide now rather than at the echo: the typed character occupies the spot
            // where the last ghost glyph is still painted, and the refill only arrives after the echo +
            // debounce. `echoPending` stays armed (not `clearPresentation()`), so the echo still refills.
            echoPending = true
            echoFollowsTypeAlong = true
            // The user is typing the ghost itself, so it has been read: the trimmed ghost the echo
            // re-renders takes `Tab` at once.
            presentationSettled = true
            ghostPrefix? += text
            // While an early paint waits, the decode still running is the rest of this very
            // buffer: keep it, and let the full decode skip what was typed instead of a second predict.
            if firstPaintWaits {
                recordFirstPaintConsumed(text)
                return exhausted ? [.present(.none)] : []
            }
            return exhausted ? [.cancelInFlight, .present(.none)] : [.cancelInFlight]

        case .invalidated:
            // The typed text diverged from the ghost: kill the stale ghost NOW (no lingering overlap),
            // then re-infer for the new prefix (typing also re-runs spell-check).
            return clearPresentation() + [.schedulePredict(trigger: .typing, debounceMs: Self.debounceMs(for: .typing))]

        case .notApplicable:
            // No ghost to advance (or a correction owns it) → the normal debounced predict path.
            // A correction survives a typed word boundary (it still targets the word just closed), but
            // not a typed letter: the word grew, so `charactersBackFromCaret` no longer points at it
            // and a `Tab` would replace the wrong characters.
            if acceptance.correction != nil, let first = text.first, !first.isWhitespace, !first.isPunctuation {
                return [.logGate("correction-stale")] + clearPresentation()
                    + [.schedulePredict(trigger: .typing, debounceMs: Self.debounceMs(for: .typing))]
            }
            return [.schedulePredict(trigger: .typing, debounceMs: Self.debounceMs(for: .typing))]
        }
    }

    // MARK: AX echo after our own insert / a type-along

    private mutating func handleHostEcho() -> [Effect] {
        guard echoPending else { return [] }
        echoPending = false
        if acceptance.continuation?.text.isEmpty ?? true {
            // The early ghost ran out while its full decode still runs: that decode refills it,
            // or schedules the refill itself when it has nothing past what the user took.
            if firstPaintWaits { return [.logGate("first-paint refill-deferred")] }
            // The continuation buffer is used up → proactively load the NEXT suggestion at the new caret
            // (bypasses the Esc mute, like the old `handleCaretMoved`).
            return [.schedulePredict(trigger: .acceptRefill, debounceMs: Self.debounceMs(for: .acceptRefill))]
        }
        // Words remain in the buffer → re-render the shrunk ghost in place, no re-inference.
        return [.present(currentPresentation)]
    }

    // MARK: Predict pipeline — phase 1 (gates + redundancy)

    /// The surface verdict for one handled run: the first of the surface-level reasons, in
    /// the order `handleContextReady` applies them. Per-caret gates are `on`.
    private func surfaceVerdict(
        _ context: TypingContext?,
        caret: CaretFacts?,
        trigger: SuggestionTrigger,
        rejection: ContextRejection?
    ) -> SurfaceVerdict {
        guard let context else { return .rejected(rejection ?? .noFocus) }
        if let bundleID = context.bundleID, temporarilyQuietBundleIDs.contains(bundleID) {
            return .temporaryQuiet
        }
        if trigger != .forceActivate, !FieldSizeGate.allowsContinuation(in: context) { return .smallField }
        if caret == nil { return .noCaretGeometry }
        return .on
    }

    private mutating func handleContextReady(
        _ context: TypingContext?,
        caret: CaretFacts?,
        trigger: SuggestionTrigger,
        rejection: ContextRejection?
    ) -> [Effect] {
        // A new run supersedes the old one in the single slot: an early paint of the old run
        // waits for nothing now, whichever way this run ends.
        firstPaint = nil
        // The force-activate shortcut. It overrides
        // exactly one thing: the cold-start gates below, where WE declined to offer a suggestion on a
        // surface the user has enabled. It cannot reach past anything the USER set — an app switched
        // off never produces a context at all (checked App-side), a pause drops the event
        // before this method runs, and the temporary quiet immediately below is checked ahead of every
        // bypass. So force can only put a ghost somewhere *we* said no, never somewhere the user did.
        let forced = trigger == .forceActivate

        // No usable context (AX gave nothing, or the app is policy-disabled).
        guard let context else {
            _ = lifecycle.react(to: .cannotPredict)
            // The one shape the key cannot fix, and it is the shape the ticket named as its payoff:
            // an AX-blind surface (Mail's WebKit compose body) yields no text, and there is nothing to
            // continue from. Logged rather than left silent, so a press that can do nothing is visible
            // as a rate instead of felt as an unreliable shortcut. The fallback that would close it is
            // the keystroke buffer, which is not built.
            var effects: [Effect] = forced ? [.logGate("force-activate no-context")] : []
            // One suppression, one token: app-off was logged by `ContextAssembler`.
            if let rejection, rejection != .appOff {
                effects.append(.logGate("no-context reason=\(rejection.rawValue)"))
            }
            return effects + clearPresentation()
        }

        // Take-back detection, phase 1: the caret is back at an accept's prefix and the accepted
        // text is gone from its right. Ahead of every gate, so the state is right whatever this run does.
        takeBack.observe(context)

        // Temporary per-app quiet. Shaped like the per-app switch it
        // shadows: it suppresses everything the surface would produce, correction included,
        // rather than acting as a continuation gate — "quiet" is an answer about this app, not about
        // this suggestion. Checked BEFORE `forced` can bypass anything: force overrides our gates, and
        // this is the user's own statement.
        if let bundleID = context.bundleID, temporarilyQuietBundleIDs.contains(bundleID) {
            _ = lifecycle.react(to: .cannotPredict)
            return [.logGate("temporary-quiet app=\(bundleID)")] + clearPresentation()
        }

        // Language off switch. The user's own statement about a
        // language, so it sits ahead of every bypass, force-activate included, and suppresses the
        // correction too. An unsure reading (`open`) never suppresses; it is logged and the run goes on.
        var languageOpenLog: [Effect] = []
        switch context.languageVerdict {
        case .off(let tag):
            _ = lifecycle.react(to: .cannotPredict)
            return [.logGate("language-off lang=\(tag)")] + clearPresentation()
        case .open(let reason):
            languageOpenLog = [.logGate("language-open reason=\(reason.rawValue)")]
        case .allowed, nil:
            break
        }
        return languageOpenLog + handleContextAfterLanguageGate(context, caret: caret, trigger: trigger)
    }

    /// The rest of `handleContextReady`, once the surface-wide suppressions (temporary quiet, language
    /// off) have passed.
    private mutating func handleContextAfterLanguageGate(
        _ context: TypingContext,
        caret: CaretFacts?,
        trigger: SuggestionTrigger
    ) -> [Effect] {
        let forced = trigger == .forceActivate

        // The Esc field pause: the user pressed Esc with "Dismiss and pause this field" chosen.
        // Like the temporary quiet it is the user's own statement, so it sits ahead of every bypass,
        // force-activate included, and suppresses the correction too.
        if fieldPauseGeneration != nil {
            _ = lifecycle.react(to: .cannotPredict)
            return [.logGate("esc-field-pause")] + clearPresentation()
        }

        // Battery on-demand: on battery, with the preference on and a force-activate
        // shortcut assigned, only that shortcut (and the refill that continues an accepted ghost)
        // produces a continuation. After the temporary quiet, so a forced press cannot beat the user's
        // own quiet; ahead of the redundancy replay and the cold-start gates, so neither can show a
        // ghost the posture refuses. The spell correction survives, like at every continuation gate.
        if batteryPosture.onDemandOnly, trigger != .forceActivate, trigger != .acceptRefill {
            return [.logGate("battery on-demand trigger=\(trigger.logName)")]
                + correctionOnly(context, trigger: trigger)
        }

        // Right-to-left guard (cold-start, all triggers, force-activate included): the ghost is painted
        // right of the caret and the strike is placed from left-to-right advances, so in Hebrew or
        // Arabic text both land on the typed words. Suppresses the correction too. Fail-closed on any
        // strong right-to-left scalar in the paragraph.
        if WritingDirection.paragraphContainsRightToLeft(in: context) {
            _ = lifecycle.react(to: .cannotPredict)
            return [.logGate("rtl-text")] + clearPresentation()
        }

        // Emoji after a colon. A typing-driven, caret-at-end request: `:smi` becomes a
        // correction of the colon word, so it renders and accepts exactly like a spelling fix
        // (`Tab`) and skips inference. Ahead of the continuation gates because they do not
        // apply to a replacement, and because `:sm` at the start of a text has no running thought.
        if let offer = emojiOffer(context, trigger: trigger) {
            return offer
        }

        // Field-size gate (cold-start, all triggers): suppress in a small single-line input.
        // A CONTINUATION gate — the spell fix survives it, which is what makes
        // "AXTextField stays eligible so corrections still flow" true of the code.
        guard forced || FieldSizeGate.allowsContinuation(in: context) else {
            return [.logGate("field-size")] + correctionOnly(context, trigger: trigger)
        }

        // Selection gate (cold-start, all triggers): while the host holds a
        // non-empty selection there is nothing to continue, because the next keystroke replaces it.
        // Sits here rather than in the key classifier because a MOUSE drag-selection produces no
        // keyDown at all — and because stopping ⌘A ahead of `.runInference` is what lets ⌘A be routed
        // through the ordinary caret-move path without paying for a prediction on a doomed prefix.
        //
        // One of two cold-start gates force-activate does not override (the other is the right-to-left
        // guard), and deliberately so: over a
        // selection there is no "suggestion we declined to offer" to force — the text being continued
        // is the text the next keystroke deletes. Pinned by its own test so a later "make the gates
        // consistent" pass meets a failure rather than a comment.
        guard SelectionGate.allowsContinuation(in: context) else {
            return [.logGate("selection len=\(context.selectionLength)")] + clearPresentation()
        }

        // Running-thought gate, arm 1 (cold-start, all triggers): with fewer than two
        // words in the current SENTENCE there is no running thought to continue, and what the model
        // offers there is an invented one (`Test 7 (Sara):`). Short-circuits ahead of spell-check and
        // inference, like the field-size gate above.
        guard forced || RunningThoughtGate.hasRunningThought(in: context) else {
            // Continuation-only, like the field-size gate: the word before the caret is the FIRST word
            // of the line here, so suppressing the spell check too would put it permanently outside the
            // fix — by the time the gate lifts, the misspelling is no longer the correction's target.
            return [.logGate("running-thought absent")] + correctionOnly(context, trigger: trigger)
        }

        if trigger.isCaretMove {
            // Proactive gate (caret-move only): no suggestion strictly inside a word, and — until FIM is
            // wired — none mid-text (host text to the right). A nil caret reads as "text to the right"
            // (`caret?.hasTextToRight == false` is false when caret is nil), matching the old rule.
            let positionOK = CaretPositionGate.allowsProactiveSuggestion(in: context)
            let rightTextOK = fimEnabled || (caret?.hasTextToRight == false)
            guard positionOK, rightTextOK else { return clearPresentation() }

            // Redundancy guard: a no-op move restores the cached suggestion in place (no re-inference).
            if let last = lastContext, let cached = lastSuggestion, isRedundant(context, last) {
                // The replay has to pass the same bar the live path does, and this is the branch the
                // reported symptom actually takes: a ghost predicted while TYPING (glued, legitimately)
                // would otherwise be restored, unchanged, at a caret the user has since merely navigated
                // to. There is nothing to re-infer instead — equal `predictionInputs` mean an identical
                // prompt, and greedy decoding at temp 0 would hand back the very text just refused.
                guard WordCompletionGate.allowsContinuation(cached.text, trigger: trigger, in: context) else {
                    return [.logGate("word-completion suppressed")] + clearPresentation()
                }
                // The replay passes the take-back gate too: after a delete or an undo of an accept the
                // prompt inputs are often those of the run that produced the accepted text.
                if let length = takeBack.refusal(of: cached.text, textBeforeCaret: context.textBeforeCaret) {
                    return [.logGate("take-back len=\(length)")] + clearPresentation()
                }
                guard acceptance.completionLength.allowsContinuation(textBeforeCaret: context.textBeforeCaret) else {
                    return [.logGate("word-length at-boundary")] + clearPresentation()
                }
                if acceptance.completionLength == .word,
                   DisplayWindow.windowed(cached.text, length: .word).isEmpty {
                    return [.logGate("word-length no-word-rest")] + clearPresentation()
                }
                acceptance.setCorrection(nil)
                acceptance.setContinuation(cached)
                ghostPrefix = context.textBeforeCaret
                return [.present(currentPresentation)]
                    + beginPresentation(settled: lastSuggestionSettled || !startsUnsettled(trigger))
            }
        }

        // Proceed to inference. Corrections are typing-driven only (a caret move gets a continuation,
        // never a spelling flag on a word you merely landed on).
        pendingContext = context
        pendingTrigger = trigger
        // Greppable like every other gate token, and for the same reason: whether force-activate is
        // reaching anything is a **rate**, not a feeling — and a press that produced a ghost is
        // otherwise indistinguishable in the log from a ghost the loop would have offered anyway.
        return (forced ? [.logGate("force-activate override")] : [])
            + [.runInference(context, wantsCorrection: trigger == .typing, wantsContinuation: true)]
    }

    /// The emoji request at the caret, if any. `nil` hands the context to the normal flow. A request
    /// with no match is suppressed (`[gate]: emoji-no-match`); a stale offer is dropped.
    private mutating func emojiOffer(_ context: TypingContext, trigger: SuggestionTrigger) -> [Effect]? {
        guard trigger == .typing, context.selectionLength == 0,
              !(context.textAfterCaret.first?.isLetter ?? false),
              let fragment = EmojiTrigger.fragment(in: context.textBeforeCaret) else {
            lastEmojiNoMatch = nil
            // A shown emoji offer whose colon word is gone must not outlive the keystroke.
            if case .correction(let shown) = currentPresentation, shown.original.hasPrefix(":") {
                return clearPresentation()
            }
            return nil
        }
        guard let emoji = emojiLexicon.bestMatch(for: fragment) else {
            // A request nobody can complete gets no continuation either: a model guess after
            // `:qqxzv` is noise. Logged once per request: a longer fragment cannot match when a
            // shorter one did not, so only the first miss of a growing fragment logs.
            if let missed = lastEmojiNoMatch, fragment.hasPrefix(missed) { return clearPresentation() }
            lastEmojiNoMatch = fragment
            return [.logGate("emoji-no-match")] + clearPresentation()
        }
        lastEmojiNoMatch = nil
        acceptance.setContinuation(nil)
        acceptance.setCorrection(Correction(original: ":" + fragment, replacement: emoji,
                                            charactersBackFromCaret: fragment.count + 1))
        echoPending = false
        return [.cancelInFlight, .present(currentPresentation)]
    }

    /// A continuation gate refused: tear the ghost down through the single `clearPresentation()`
    /// chokepoint (dropping it would strand `echoPending`), then still run the spell check
    /// for this context. Costs no inference: the correction is `NSSpellChecker`, not the model
    /// . On a caret move there is nothing to ask for — corrections are typing-driven by
    /// construction — so the effect is omitted entirely and the branch stays byte-identical
    /// to before. `SelectionGate` deliberately does NOT come through here: over a selection the
    /// corrected word is about to be replaced along with everything else.
    private mutating func correctionOnly(_ context: TypingContext, trigger: SuggestionTrigger) -> [Effect] {
        let cleared = clearPresentation()
        guard trigger == .typing else { return cleared }
        pendingContext = context
        pendingTrigger = trigger
        return cleared + [.runInference(context, wantsCorrection: true, wantsContinuation: false)]
    }

    // MARK: Predict pipeline — phase 2 (value-gate + setContinuation)

    /// The output-side gates run here, in this order, all **before** `setContinuation` and all
    /// deliberately outside the `SuggestionValueGate` chokepoint (whose *one string in, renderable
    /// yes/no* contract several accept paths depend on, holding no `TypingContext` at all).
    ///
    /// **Structure before content**: arm 2 cuts at a structural mark in the raw decode,
    /// and the copy judgement should fall over the text that would actually be shown — otherwise it
    /// inspects text nobody sees, and the more expensive n-gram comparison runs on the longer string.
    ///
    /// What is cached as `lastSuggestion` is the **gated** result, so the redundancy replay on a
    /// no-op caret move restores what passed the bars rather than what the model offered.
    private mutating func handlePredictionArrived(_ suggestion: Suggestion, _ correction: Correction?) -> [Effect] {
        let context = pendingContext
        let trigger = pendingTrigger
        pendingContext = nil
        pendingTrigger = nil

        let early = firstPaint
        firstPaint = nil
        // First-paint streaming: a teardown cleared the early ghost of this run, so the full
        // decode describes a caret that is gone.
        if case .dropped = early { return [.logGate("first-paint final-dropped")] }

        var (gated, effects) = shapeContinuation(suggestion, context: context, trigger: trigger)
        // The redundancy cache pairs `context` with the whole gated suggestion. Text the user took off
        // the early ghost is cut from the buffer below, never from the cache: deleting that text brings
        // the caret back to `context`, and the replay must show what the main path shows there.
        let cached = gated
        var keepsCorrection = false
        var tookFromEarlyGhost = false
        if case .waiting(let consumed, let showedCorrection) = early {
            // The early paint already showed this run's correction: the user may have applied or
            // refused it since, and either way it must not come back.
            keepsCorrection = showedCorrection
            if !consumed.isEmpty {
                tookFromEarlyGhost = true
                // The user took `consumed` off the early ghost. The full decode extends the buffer past
                // it when it starts with the same text; otherwise it is about a different caret.
                guard gated.text.hasPrefix(consumed) else {
                    return [.logGate("first-paint final-dropped")] + refillIfEarlyGhostRanOut()
                }
                let rest = String(gated.text.dropFirst(consumed.count))
                gated = Suggestion(text: rest,
                                   abandonsRunningThought: gated.abandonsRunningThought,
                                   heldBackPunctuation: rest.first.map { !$0.isWhitespace && $0.isPunctuation } ?? false)
            }
        }
        lastContext = context
        lastSuggestion = cached
        // An early paint already set the prefix and moved it along with what the user took since.
        if early == nil { ghostPrefix = context?.textBeforeCaret }
        ghostIsOnDemandExempt = trigger == .forceActivate || trigger == .acceptRefill
        if !keepsCorrection {
            var shown = correction
            if let c = correction, spellRefusals.isIgnored(c.original) {
                effects.append(.logGate("spell-ignored"))
                shown = nil
            }
            acceptance.setCorrection(shown)
            typedSinceCorrection = shown == nil ? nil : ""
        }
        acceptance.setContinuation(gated)   // value-gated + windowed at the chokepoint
        guard early != nil else {
            // A missing trigger (a prediction whose `.contextReady` never ran) does not guess: it keeps
            // today's behaviour, a ghost that takes `Tab` at once.
            let settle = beginPresentation(settled: !(trigger.map(startsUnsettled) ?? false))
            lastSuggestionSettled = presentationSettled
            return effects + [.present(currentPresentation)] + settle
        }
        // The early ghost already started (or skipped) the grace clock; the full decode only extends it.
        lastSuggestionSettled = presentationSettled
        // An own insert of a word off the early ghost is still echoing: the echo re-renders at the new
        // caret, so painting now would place the ghost at the old one.
        if echoPending { return effects }
        return effects + [.present(currentPresentation)] + (tookFromEarlyGhost ? refillIfEarlyGhostRanOut() : [])
    }

    /// After the early ghost ran out and its echo deferred the refill: the refill the echo would
    /// have scheduled, when the full decode left nothing to show.
    private func refillIfEarlyGhostRanOut() -> [Effect] {
        guard !echoPending, acceptance.continuation == nil, acceptance.correction == nil else { return [] }
        return [.schedulePredict(trigger: .acceptRefill, debounceMs: Self.debounceMs(for: .acceptRefill))]
    }

    /// First-paint streaming: paint the first words of a
    /// decode that is still running. The same shaping as the full decode runs on them; when any gate
    /// would change them, the paint waits for the full decode, which logs that gate itself (logging it
    /// here too would double every gate rate). The correction shows too: the spell check finished
    /// before the decode started.
    private mutating func handleFirstWordsArrived(_ suggestion: Suggestion, _ correction: Correction?) -> [Effect] {
        guard pendingContext != nil else { return [] }
        let (gated, effects) = shapeContinuation(suggestion, context: pendingContext, trigger: pendingTrigger)
        let held = effects.contains { effect in
            guard case .logGate(let token) = effect else { return false }
            return !token.hasPrefix("boundary-lead") && !token.hasPrefix("spelling-variant")
        }
        if held || gated.text.isEmpty { return [.logGate("first-paint held")] }
        ghostIsOnDemandExempt = pendingTrigger == .forceActivate || pendingTrigger == .acceptRefill
        let shown = correction.flatMap { spellRefusals.isIgnored($0.original) ? nil : $0 }
        acceptance.setCorrection(shown)
        typedSinceCorrection = shown == nil ? nil : ""
        acceptance.setContinuation(gated)
        guard acceptance.continuation != nil else { return [.logGate("first-paint held")] }
        lastContext = pendingContext
        lastSuggestion = gated
        ghostPrefix = pendingContext?.textBeforeCaret
        firstPaint = .waiting(consumed: "", showedCorrection: shown != nil)
        let settle = beginPresentation(settled: !(pendingTrigger.map(startsUnsettled) ?? false))
        lastSuggestionSettled = presentationSettled
        return [.present(currentPresentation)] + settle
    }

    /// The App cancelled the pending run itself: its full decode never lands. An early ghost on
    /// screen becomes the whole suggestion, so using it up refills like any exhausted buffer; when it
    /// already ran out and its echo deferred the refill to that decode, the refill is scheduled now.
    private mutating func handleRunCancelled() -> [Effect] {
        let early = firstPaint
        firstPaint = nil
        pendingContext = nil
        pendingTrigger = nil
        guard case .waiting = early else { return [] }
        return refillIfEarlyGhostRanOut()
    }

    /// The bars and the shaping a decoded continuation passes before it may be shown, shared by the
    /// full decode and the first-paint words. Returns the gated suggestion and the gate log lines.
    private func shapeContinuation(_ suggestion: Suggestion, context: TypingContext?,
                                   trigger: SuggestionTrigger?) -> (Suggestion, [Effect]) {
        var effects: [Effect] = []
        var text = RunningThoughtGate.continuation(
            suggestion.text, abandonsRunningThought: suggestion.abandonsRunningThought)
        // Logged on the DECISION, not on its effect. A decode can arrive already
        // empty — the earlier boundary-lead suppression empties the same decode arm 2 flags — and a
        // count conditioned on `text != suggestion.text` would drop exactly that case, biasing the
        // arm's measured rate downward. On a corrected build this token appears as often as the
        // engine's unconditional break lines — **both** of them since 2026-09-02: `[mlx]:
        // running-thought break` on the forward path and `[fim]: running-thought break` on a bridge,
        // because arm 2 now applies to the FIM route too.
        // A 1:1 cross-check against `[mlx]` alone was exact before that date and under-counts after it
        // whenever `midTextCompletionEnabled` is on.
        if suggestion.abandonsRunningThought { effects.append(.logGate("running-thought abandoned")) }

        // Word-completion gate: at a caret the user reached by NAVIGATION,
        // a continuation that glues onto the word behind it is refused — there is no fragment to
        // complete, because nothing was typed. Structural like arm 2 above and cheaper than the n-gram
        // comparison, so it runs before the copy guard; a refusal empties the text, which the guard's
        // own `!text.isEmpty` skips.
        // A missing trigger or context (only possible for a prediction whose `.contextReady` never
        // ran) means the discriminator is unknown, and this gate does not guess — same posture as the
        // copy guard below.
        if !text.isEmpty, let context, let trigger,
           !WordCompletionGate.allowsContinuation(text, trigger: trigger, in: context) {
            effects.append(.logGate("word-completion suppressed"))
            text = ""
        }

        // Word-only step: at a word boundary there is no word rest to finish, so the
        // continuation is dropped. Logged on the decision, and the spell correction still presents.
        if !text.isEmpty, let context,
           !acceptance.completionLength.allowsContinuation(textBeforeCaret: context.textBeforeCaret) {
            effects.append(.logGate("word-length at-boundary"))
            text = ""
        }
        // The prefix ends on a finished word or punctuation and the buffer opens with a gap: the
        // word window is empty, so the renderer would drop the continuation without a trace.
        if !text.isEmpty, acceptance.completionLength == .word,
           DisplayWindow.windowed(text, length: .word).isEmpty {
            effects.append(.logGate("word-length no-word-rest"))
            text = ""
        }

        // Take-back gate: at a prefix where the user removed an
        // accepted text, a continuation that opens with the same word is that text again. Structural,
        // so it runs before the copy guard; the correction is not touched.
        if !text.isEmpty, let context,
           let length = takeBack.refusal(of: text, textBeforeCaret: context.textBeforeCaret) {
            effects.append(.logGate("take-back len=\(length)"))
            text = ""
        }

        // The copy guard needs the prefix as its reference text. With no context in hand (only
        // possible for a prediction whose `.contextReady` never ran) it cannot judge, and it does not
        // guess — a missing reference is not evidence of no copy, but nor is it evidence of one.
        if !text.isEmpty, let context {
            let verdict = LongRangeCopyGuard.apply(to: text, textBeforeCaret: context.textBeforeCaret)
            if let run = verdict.trimmedRun {
                effects.append(.logGate("copy-guard trimmed run=\(run)"))
                text = verdict.text
            }
        }

        // Unsupported-number guard: a digit run, month or weekday name the
        // prefix and the front's context segments do not contain is cut off; a ghost left without a
        // word character is suppressed. Before the join, which only shapes what survives.
        if !text.isEmpty, let context {
            let verdict = UnsupportedNumberGuard.apply(
                to: text, textBeforeCaret: context.textBeforeCaret,
                supportingText: [context.windowContext, context.replyContext, context.clipboardContext,
                                 context.ocrContext?.ambient, context.ocrContext?.focusedFill,
                                 context.personalization].compactMap { $0 })
            if let action = verdict.action {
                effects.append(.logGate("unsupported-number \(action == .trimmed ? "trimmed" : "suppressed")"))
                text = verdict.text
            }
        }

        // Boundary-lead join. LAST, after every bar:
        // it shapes what survives rather than deciding whether anything does, and running it earlier
        // would have it reconcile text the copy guard is about to trim away. Needs the prefix, so with
        // no context in hand it does nothing — the same posture as the two gates above, and the safe
        // one: the untouched text is exactly what shipped before this ticket.
        var consumesPrecedingSpace = false
        if !text.isEmpty, let context {
            let join = BoundaryLeadJoin.apply(to: text, textBeforeCaret: context.textBeforeCaret)
            if join.consumesPrecedingSpace {
                // Greppable for the same reason the gates are: the boundary-lead suppression this
                // replaces was measurable as `boundary-suppressed`, and the acceptance criterion is a
                // re-count. `[gate]: boundary-lead consumes-space` is that counter's successor.
                effects.append(.logGate("boundary-lead consumes-space"))
            }
            text = join.text
            consumesPrecedingSpace = join.consumesPrecedingSpace

            // Sentence-start case, last of all: where the continuation provably
            // OPENS a sentence — the caret's sentence was opened by a boundary mark, or the
            // continuation leads with one — its first word character is uppercased. After the join
            // because the join settles where that character sits relative to any leading whitespace,
            // and because both read the same prefix. Never changes the string's LENGTH, so the
            // display window, the copy guard's run and the accept peel all still measure what they did.
            text = SentenceStartCase.apply(to: text, textBeforeCaret: context.textBeforeCaret)

            // Spelling variant, the very last shaping step: it can change the text's length,
            // so it runs after everything that measures it. It rewrites English only;
            // text in any other detected language passes through unchanged.
            if spellingVariant != .off {
                let spelled = spellingVariant.apply(to: text, textBeforeCaret: context.textBeforeCaret)
                if spelled != text {
                    effects.append(.logGate("spelling-variant \(spellingVariant.rawValue) rewrote"))
                    text = spelled
                }
            }
        }

        // The gate changed the TEXT; it did not retroactively change what the model did. The flag
        // crosses the engine→Core boundary as one bit precisely so it can be read later, so
        // the cache carries it rather than inheriting the initialiser's `false`.
        let gated = Suggestion(text: text,
                               abandonsRunningThought: suggestion.abandonsRunningThought,
                               consumesPrecedingSpace: consumesPrecedingSpace)
        return (gated, effects)
    }

    // MARK: Pause

    /// Symmetric by decision: pausing visibly removes the ghost, so resuming
    /// must visibly restore one. Pressing the hotkey again IS the statement of intent, so the resume
    /// regenerates unconditionally — it deliberately does NOT go through `lifecycle.react(to:)` the way
    /// a caret move does, because honouring an Esc mute here would reinstate the silent no-op this
    /// exists to remove. Nothing is bypassed downstream: the App fetches a fresh context (the caret may
    /// have moved while paused) and every gate, plus the redundancy cache, applies unchanged.
    ///
    /// This is the *explicit-action* half of the rule the quiet timer also follows: an explicit action
    /// produces an immediate result, an expiring timer does not.
    private mutating func handleSetPaused(_ isPaused: Bool) -> [Effect] {
        guard isPaused != paused else { return [] }
        paused = isPaused
        guard isPaused else {
            return [.schedulePredict(trigger: .caretMoved, debounceMs: Self.debounceMs(for: .caretMoved))]
        }
        takeBack.clear()
        // Pausing: stop in-flight work and clear any visible suggestion now.
        return [.cancelInFlight] + clearPresentation()
    }

    /// Flipping mid-text completion changes which *model* a mid-text caret routes to, so a
    /// ghost produced by the other path is stale the moment it flips — tear down like a pause rather
    /// than leave it showing. The next keystroke/caret move regenerates on the new route.
    private mutating func handleSetFIMEnabled(_ enabled: Bool) -> [Effect] {
        guard enabled != fimEnabled else { return [] }
        fimEnabled = enabled
        return [.cancelInFlight] + clearPresentation()
    }

    /// A new variant makes the cached buffer stale (it was spelled for the old one), so tear down like
    /// a FIM flip. It also drops the redundancy cache: `lastSuggestion` holds the already-rewritten
    /// text, and a caret move with unchanged inputs would otherwise replay it in the old spelling.
    /// The next keystroke or caret move then runs a fresh predict in the new variant.
    private mutating func handleSetSpellingVariant(_ variant: SpellingVariant) -> [Effect] {
        guard variant != spellingVariant else { return [] }
        spellingVariant = variant
        lastContext = nil
        lastSuggestion = nil
        return [.cancelInFlight] + clearPresentation()
    }

    /// Adopt the new Short/Medium/Long window. Unlike the two flips
    /// above this costs **nothing**: the length picks how much of an already-decoded buffer is painted
    /// , so there is no in-flight work to cancel and no reason to re-predict — a visible ghost
    /// is simply re-presented at the new window, and the acceptance buffer `Tab` peels from is untouched.
    /// The one teardown case is a *shorter* window whose head no longer carries word content
    /// ; it goes through `clearPresentation()` so `echoPending` cannot survive the ghost.
    private mutating func handleSetCompletionLength(_ length: CompletionLength) -> [Effect] {
        guard length != acceptance.completionLength else { return [] }
        let wasShowing = acceptance.isShowingSomething
        acceptance.setCompletionLength(length)
        guard wasShowing else { return [] }
        guard acceptance.isShowingSomething else { return clearPresentation() }
        // Display-only: the user already has this buffer in view, so the re-window takes `Tab` at once.
        presentationSettled = true
        return [.present(currentPresentation)]
    }

    /// A flip into on-demand tears down a ghost a refused trigger produced; a flip out schedules
    /// nothing, since the next keystroke or caret move regenerates (the expiring-timer rule).
    private mutating func handleSetBatteryPosture(_ posture: BatteryPosture) -> [Effect] {
        let wasOnDemand = batteryPosture.onDemandOnly
        // A new decode cap makes the cached suggestion stale (an 8-word buffer decoded on AC would
        // replay on battery), and `PredictionInputs` holds prompt inputs only. Drop the redundancy
        // cache so the next caret move runs a fresh predict under the new cap.
        if posture.decodeWordCap != batteryPosture.decodeWordCap {
            lastContext = nil
            lastSuggestion = nil
        }
        batteryPosture = posture
        guard posture.onDemandOnly, !wasOnDemand else { return [] }
        guard acceptance.isShowingSomething, !ghostIsOnDemandExempt else { return [] }
        return [.cancelInFlight] + clearPresentation()
    }

    // MARK: Force-activate / temporary quiet

    /// The explicit "give me one here" press. Schedules the predict **directly** rather than routing
    /// through `lifecycle.react(to:)`, which is the same bypass the accept refill uses and the same
    /// rule `handleSetPaused`'s resume arm follows: an Esc mute says *not this suggestion*, this key
    /// says *one now*, and honouring the mute here would answer the one key pressed to get a ghost
    /// with silence. Nothing downstream is bypassed — the App fetches a fresh context and every gate
    /// the trigger does not name still applies (`handleContextReady`).
    private mutating func handleForceActivate() -> [Effect] {
        [.schedulePredict(trigger: .forceActivate, debounceMs: Self.debounceMs(for: .forceActivate))]
    }

    /// Quiet starts. Explicit action ⇒ immediate result: the ghost on screen belongs to the surface
    /// just silenced, so it goes now rather than lingering until the next keystroke.
    private mutating func handleTemporaryQuietStarted(_ bundleID: String) -> [Effect] {
        guard temporarilyQuietBundleIDs.insert(bundleID).inserted else { return [] }
        takeBack.clear()
        return [.cancelInFlight] + clearPresentation()
    }

    /// Quiet ends — and this is the asymmetric half of the same rule:
    /// **an explicit action produces an immediate result; an expiring timer
    /// does not.** A user who pressed *resume* gets a ghost back at the caret; a timer that ran out
    /// produces nothing at all, because the user did nothing at that moment, may not be looking, and
    /// may be in another app entirely — a suggestion appearing unbidden fifteen minutes later is a
    /// different event from one following a keypress. The next keystroke or caret move regenerates.
    private mutating func handleTemporaryQuietEnded(_ bundleID: String,
                                                    resumedExplicitly: Bool) -> [Effect] {
        guard temporarilyQuietBundleIDs.remove(bundleID) != nil else { return [] }
        guard resumedExplicitly, !paused else { return [] }
        return [.schedulePredict(trigger: .caretMoved, debounceMs: Self.debounceMs(for: .caretMoved))]
    }

    /// Settings flips, as opposed to user input — processed even while paused.
    private static func isSettingsEvent(_ event: Event) -> Bool {
        switch event {
        case .setPaused, .setFIMEnabled, .setCompletionLength, .setSpellingVariant,
             .setTrailingPunctuation, .setBatteryPosture, .setEscBehaviour: return true
        // The timer's end is not input either: dropping it while paused would leave the field
        // paused after resume with no timer left to end it.
        case .fieldPauseExpired: return true
        // The quiet flips are settings, not input: dropping one because the app happened to be paused
        // would leave the reducer's set disagreeing with the menu the user just used.
        case .temporaryQuietStarted, .temporaryQuietEnded: return true
        default: return false
        }
    }

    // MARK: Shared teardown / helpers

    /// Record whether the presentation just decided is settled, and if not, ask the App for a grace
    /// clock under a fresh generation. Emitted AFTER its `.present` so the App's list-order walk starts
    /// the clock once the paint is done. Nothing showing, or the grace off, is
    /// settled by definition.
    private mutating func beginPresentation(settled: Bool) -> [Effect] {
        guard tabGrace, !settled, acceptance.isShowingSomething else {
            presentationSettled = true
            return []
        }
        presentationGeneration += 1
        presentationSettled = false
        return [.scheduleSettle(generation: presentationGeneration)]
    }

    /// The triggers whose ghost appears under a user's own keystroke or click, and so may meet a `Tab`
    /// meant for the host: typing, a caret move, a force-activate press, and the refill after the user
    /// typed the ghost to its end. The refill after a `Tab`-accept follows OUR insert, during an accept
    /// chain, where the next `Tab` is meant for us.
    private func startsUnsettled(_ trigger: SuggestionTrigger) -> Bool {
        switch trigger {
        case .typing, .caretMoved, .forceActivate: return true
        case .acceptRefill: return echoFollowsTypeAlong
        case .dismissed, .focusChanged, .cannotPredict: return false
        }
    }

    /// Drop everything currently shown and the pending echo, and ask the App to hide. The single
    /// chokepoint that resets `echoPending` — any teardown of the current ghost goes through here, so a
    /// stale AX echo can never re-render replaced state or inject a spurious predict.
    private mutating func clearPresentation() -> [Effect] {
        acceptance.setCorrection(nil)
        acceptance.setContinuation(nil)
        echoPending = false
        ghostPrefix = nil
        if firstPaint != nil { firstPaint = .dropped }
        return [.present(.none)]
    }

    /// Hide the mispositioned ghost immediately on a caret move (cancel in-flight + clear). AX/tap-driven
    /// regen repopulates it. Mirrors the old `hideForCaretMove()`.
    private mutating func hideForCaretMoveEffects() -> [Effect] {
        [.cancelInFlight] + clearPresentation()
    }

    /// A caret move regenerates at the new position — unless an Esc muted proactive regen, in which case
    /// nothing is shown and we leave it that way until the user types. Mirrors `regenerateForCaretMove()`.
    private mutating func regenerateForCaretMoveEffects() -> [Effect] {
        switch lifecycle.react(to: .caretMoved) {
        case .regenerate:
            return [.schedulePredict(trigger: .caretMoved, debounceMs: Self.debounceMs(for: .caretMoved))]
        case .hold, .clear:
            return []
        }
    }

    /// Turn an acceptance verdict into effects, arming `echoPending` for inserts/replaces (our own insert
    /// echoes back as `.hostEcho`, which re-renders the remaining ghost). Mirrors the old `apply()`.
    private mutating func apply(_ action: AcceptanceAction,
                                consumesPrecedingSpace: Bool = false) -> [Effect] {
        switch action {
        case .insertContinuation(let text):
            echoPending = true
            echoFollowsTypeAlong = false
            recordFirstPaintConsumed(text)
            // If the accept EMPTIED the buffer, hide now rather than at the echo — same shape as the
            // type-along exhaustion arm in `handleTyped` (harness scenario
            // `exhaustion-refill-real`): the host's own inserted text lands exactly where the last ghost
            // glyph is still painted, and the refill predict is only scheduled by the echo + debounce
            // (~150–500 ms later), so the overlay would keep painting the just-accepted word on top of
            // it. `echoPending` deliberately stays armed (NOT `clearPresentation()`), so the echo still
            // fires the refill. Words remaining in the buffer → byte-identical to before: no
            // `.present(.none)`, the echo re-renders the shrunk ghost.
            let exhausted = acceptance.continuation == nil
            // On the FIM path the *terminal* accept lands flush against the suffix `S` still sitting to
            // the right of the caret, and nothing anywhere appends a trailing space — so without a join
            // the two fuse (`…schnell` + `über den Zaun.` → `schnellüber`). `FIMAccept.insertionText`
            // owns that whole decision (terminal? bridge? which separator?) and is a no-op returning
            // `text` unchanged whenever `fimEnabled` is off — the shipping default — or the accept is
            // interior.
            let insertion = FIMAccept.insertionText(
                accepted: text,
                exhausted: exhausted,
                textAfterCaret: lastContext?.textAfterCaret ?? "",
                fimEnabled: fimEnabled
            )
            // a continuation opening with attaching punctuation at a caret
            // that sits after a space consumes that space instead of adding to it (`Winter ` + `". Es"`
            // → `Winter. Es`, never `Winter. Es`). This is the ONE edit where a continuation is not
            // insert-only; the machinery is the correction path's, and the remainder left in the buffer
            // is a plain continuation again, so the peel/type-along/echo paths below are untouched.
            // The accept anchor. An accept that consumed the preceding space records none: its
            // prefix is not a prefix of the host text after the edit.
            if let prefix = ghostPrefix {
                if consumesPrecedingSpace {
                    ghostPrefix = String(prefix.dropLast()) + insertion
                } else {
                    takeBack.recordAccept(prefix: prefix, inserted: insertion)
                    ghostPrefix = prefix + insertion
                }
            }
            let write: Effect = consumesPrecedingSpace
                ? .replace(charactersBack: 1, with: insertion)
                : .insert(insertion)
            return exhausted ? [write, .present(.none)] : [write]
        case .applyCorrection(let fix):
            echoPending = true
            echoFollowsTypeAlong = false
            ghostPrefix = nil   // a correction accept records no anchor, and the prefix is now unknown
            return [.replace(charactersBack: fix.charactersBackFromCaret, with: fix.replacement)]
        case .dismiss:
            _ = lifecycle.react(to: .dismissed)
            return [.present(.none)]
        case .passThrough:
            return []
        }
    }

    /// Whether two contexts would produce the same prediction — in which case `handleContextReady`
    /// restores `lastSuggestion` instead of inferring again.
    ///
    /// Which fields participate is ``TypingContext/PredictionInputs``, and the rule is *every field that
    /// reaches the prompt, none that only feeds a gate*. It used to be five hand-written clauses here,
    /// which is how the two context-input sources added after `windowContext` and
    /// `personalization` were both left out: a fresh interlocutor turn or OCR read changed the
    /// prompt, this said "redundant", and a caret move replayed the suggestion computed against the
    /// *previous* turn — with no predict and no log line saying why.
    private func isRedundant(_ a: TypingContext, _ b: TypingContext) -> Bool {
        a.predictionInputs == b.predictionInputs
    }

    /// Typing debounces at ~80 ms; every caret move — the accept refill included — waits ~150 ms for
    /// the caret to settle. A **force-activate** waits for nothing: the debounce exists to coalesce a
    /// burst of keystrokes or let a caret settle, and a single deliberate press is neither.
    private static func debounceMs(for trigger: SuggestionTrigger) -> Int {
        switch trigger {
        case .typing:        return 80
        case .forceActivate: return 0
        default:             return 150
        }
    }
}
