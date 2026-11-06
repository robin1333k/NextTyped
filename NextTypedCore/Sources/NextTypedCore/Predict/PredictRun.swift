import Foundation

/// **One prediction run**, from the debounce to the painted ghost.
///
/// This is the asynchronous half of the suggestion loop, which the pure reducer left in the shell: the debounce,
/// the context read, the caret read, both reducer re-entries, the spell check, the inference and the
/// post-predict activity signal. Four rules govern the order of those steps, and before this module all
/// four existed only as comments in a 90-line method with no tests.
///
/// **The module executes; the App keeps the slot.** The single cancelable `inFlight` Task is
/// preserved exactly — what moved is the *body* of the Task, never the slot. So cancellation is inherited
/// structurally: the App cancels the Task, `Task.isCancelled` between the steps here observes it, and a
/// test can do the same thing to assert that nothing downstream ran.
///
/// **`@MainActor`** because the reducer it drives is a synchronous `mutating struct` the coordinator
/// holds; a non-isolated module could not touch it across `await` boundaries. That is free in Core (no
/// AppKit) and inherits the reducer's "pure, synchronous, on main" property.
///
/// **Generic over the caret** — see `CaretReadout`. The value read at the top of the run is the value
/// handed to the paint at the bottom, untouched.
///
/// What this module does **not** own, and should not grow: which suggestion to show (the reducer's job),
/// how long the debounce is (`SuggestionSession.debounceMs(for:)`, arriving as a parameter), and whether
/// the surface may produce a context at all (`ContextAssembling`).
@MainActor
public struct PredictRun<Caret> {
    private let wait: any PredictWaiting
    private let context: any ContextAssembling
    private let focus: any FocusTracking
    private let caret: any CaretReading<Caret>
    private let reducer: any SuggestionReducing<Caret>
    private let spellChecker: any SpellChecker
    private let engine: any PredictionEngine
    private let activity: any PredictActivityRecording
    private let now: () -> Date

    /// - Parameter now: the clock the activity signal's elapsed-ms field is measured with. Injected so a
    ///   test is not timing the machine it runs on; the *reducer* stays time-free, and the run
    ///   is where time was always allowed to live.
    ///
    ///   One knowing divergence from the App lives here: `runPredict` reads the clock and builds the
    ///   counter payload under `#if DEBUG`, so a release build makes no `Date()` call at all. This module
    ///   makes two per predict unconditionally, because a payload that exists only in DEBUG is a payload
    ///   no test can assert on. The `#if DEBUG` split therefore moves to the App's fan-out, which must
    ///   fire the residency and OCR-cadence signals **unconditionally** and gate only the three harness
    ///   counters.
    public init(
        wait: any PredictWaiting,
        context: any ContextAssembling,
        focus: any FocusTracking,
        caret: any CaretReading<Caret>,
        reducer: any SuggestionReducing<Caret>,
        spellChecker: any SpellChecker,
        engine: any PredictionEngine,
        activity: any PredictActivityRecording,
        now: @escaping () -> Date = Date.init
    ) {
        self.wait = wait
        self.context = context
        self.focus = focus
        self.caret = caret
        self.reducer = reducer
        self.spellChecker = spellChecker
        self.engine = engine
        self.activity = activity
        self.now = now
    }

    /// Execute the run. Returns when it has finished **or** been superseded; every early return below is
    /// a cancellation, and each one is a test case.
    ///
    /// The caller owns the Task. Cancelling it is how a newer keystroke supersedes this run.
    public func run(trigger: SuggestionTrigger, debounceMs: Int) async {
        // The debounce. Sleep-then-cancel: a newer keystroke cancels this Task while it waits, and the
        // check below is what turns that into a dropped run rather than a stale prediction.
        await wait.wait(milliseconds: debounceMs)
        if Task.isCancelled { return }

        // One call, one complete context, or the typed reason there is none (
        // `ContextAssembler`). A **cancelled** assembly answers nil, which is not a rejection: the
        // check below is what keeps the two apart.
        let outcome = await self.context.assembledContext()
        if Task.isCancelled { return }
        // `nil` is a cancelled assembly (checked above), so a run never continues on it.
        guard let outcome else { return }
        let context: TypingContext?
        let rejection: ContextRejection?
        switch outcome {
        case .context(let assembled): (context, rejection) = (assembled, nil)
        case .rejected(let reason): (context, rejection) = (nil, reason)
        }

        // Rule: focus tracking follows a SUCCESSFUL context read, because the context read is what proves
        // a focused editable element exists. Registering earlier registers against whatever AX last had.
        if context != nil { focus.ensureTrackingFocusedElement() }

        // Rule: the caret is read AFTER the context, and only when there is a context to gate — caret
        // facts feed the proactive gate, and reading geometry for a surface that produced nothing is
        // spend with no consumer.
        let readout = context == nil ? nil : await caret.readCaret()
        if Task.isCancelled { return }

        // The App's `[skeleton]` line, and its rule: only when there IS a context (harness scenarios
        // assert on it, so its absence is an assertion elsewhere).
        if let context { reducer.noteContextObtained(context, trigger: trigger) }

        // Phase 1 — gates + redundancy, in the reducer.
        let phase1 = reducer.handle(.contextReady(context, caret: readout?.facts, trigger: trigger, rejection: rejection))

        // `.runInference` is plucked out because it continues on THIS Task (it is the one effect the
        // interpreter cannot execute standalone, so the case stays with this one named
        // consumer). Everything else is handed back as a batch, so the effect list's order guarantee
        // still holds here.
        var inference: (TypingContext, Bool, Bool)?
        var settled: [Effect] = []
        for effect in phase1 {
            if case .runInference(let ctx, let wantsCorrection, let wantsContinuation) = effect {
                inference = (ctx, wantsCorrection, wantsContinuation)
            } else {
                settled.append(effect)
            }
        }
        reducer.execute(settled, caret: readout?.caret)
        guard let (ctx, wantsCorrection, wantsContinuation) = inference else { return }
        if Task.isCancelled { return }

        // Phase 2 — spell check (typing only) + predict, then re-enter the reducer.
        let spell = wantsCorrection ? await spellChecker.verdict(for: ctx) : .clean(nil)
        let correction = spell.correction
        if Task.isCancelled { return }

        // A suspected typo withholds the continuation like a gate does: no predict, no
        // activity signal, and the correction, if any, resolves through the one presentation path.
        // Only a run that wanted a continuation gets here with a typo; the correction-only run
        // below already refuses the model.
        if spell.isTypoSuspected, wantsContinuation {
            reducer.execute(reducer.handle(.typoSuspected(correction)), caret: readout?.caret)
            return
        }

        // A continuation gate refused: the spell check above still ran, the model
        // does not. Re-enter with an empty suggestion so the correction resolves through the one
        // presentation path — and fire NO activity signal, because no predict happened: nothing here
        // should keep the model warm or refresh the OCR cadence. That skip is the
        // whole reason the cold-start gates could stop refusing corrections without restarting the idle
        // clock, so it is asserted, not commented.
        guard wantsContinuation else {
            reducer.execute(reducer.handle(.predictionArrived(Suggestion(text: ""), correction)),
                            caret: readout?.caret)
            return
        }

        // First-paint streaming: the engine may hand out the first words while it decodes on.
        // They reach the reducer on THIS Task, before the full decode, so a cancellation in between
        // drops both, and effects still execute in list order. `async let` keeps the decode a child of
        // this Task, so the App's cancel reaches it structurally.
        let started = now()
        let (firstWords, sink) = AsyncStream.makeStream(of: Suggestion.self, bufferingPolicy: .bufferingNewest(1))
        let engine = self.engine
        async let decoded: Suggestion = {
            defer { sink.finish() }
            return (try? await engine.predict(for: ctx, firstWords: { sink.yield($0) })) ?? Suggestion(text: "")
        }()
        var paintedEarly = false
        for await early in firstWords {
            if Task.isCancelled { break }
            let effects = reducer.handle(.firstWordsArrived(early, correction))
            if effects.contains(where: { if case .present = $0 { return true }; return false }) { paintedEarly = true }
            reducer.execute(effects, caret: readout?.caret)
        }
        let suggestion = await decoded
        if Task.isCancelled { return }

        // A real predict ran into an editable, gates-passed field: the one post-predict signal (model
        // residency + OCR cadence + the DEBUG harness counters), which the App fans out.
        activity.recordPredict(PredictActivity(
            app: ctx.bundleID,
            suggestionText: suggestion.text,
            elapsedMs: now().timeIntervalSince(started) * 1000,
            trigger: trigger,
            prefixLength: ctx.textBeforeCaret.count
        ))
        // Once an early ghost was painted, the user may have taken a word off it (Tab, or typing
        // along) and its echo redrew the ghost at the new caret. The caret this run read is then one
        // word to the left, and the geometry poll would not repair a paint there, so the final batch
        // goes out with no caret and the App reads it again.
        reducer.execute(reducer.handle(.predictionArrived(suggestion, correction)),
                        caret: paintedEarly ? nil : readout?.caret)
    }
}
