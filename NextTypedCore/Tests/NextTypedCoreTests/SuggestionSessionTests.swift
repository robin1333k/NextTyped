import Testing
@testable import NextTypedCore

/// Exhaustive policy tests for the `SuggestionSession` reducer — the previously-untestable
/// suggestion-decision policy that used to live inlined in the App shell. Pure + synchronous: prediction
/// results enter as data, so there are no fakes and no running app. Categories mirror the issue's plan:
/// intercept · presentation/value-gate · type-along · echo · gate-order · redundancy · pause · screenshot.
@Suite struct SuggestionSessionTests {

    // MARK: Helpers

    /// A plain multi-line editor context (no field descriptor → FieldSizeGate allows; caret at end of a
    /// word-boundary so the proactive caret gate allows; two words in the sentence so the
    /// running-thought gate allows — arm 1, which applies to every trigger).
    private func endOfTextContext(before: String = "hello world ", windowContext: String? = nil) -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: "", windowContext: windowContext, bundleID: "com.test")
    }

    /// Drive the two-phase predict pipeline to a settled continuation ghost (typing trigger).
    private func showContinuation(_ text: String, in session: inout SuggestionSession) {
        _ = session.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = session.handle(.predictionArrived(Suggestion(text: text), nil))
    }

    // MARK: Intercept (the synchronous Tab / ⌥Tab / Esc verdict)

    @Test func tabWhileShowingSuppressesInsertsAndKeepsRemainder() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert(" world")])
        #expect(s.currentPresentation == .continuation(" how"))
    }

    @Test func tabWithNothingShowingPassesThrough() {
        var s = SuggestionSession()
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .passThrough)
        #expect(effects.isEmpty)
    }

    @Test func optionTabWhileShowingAcceptsWholeContinuation() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        let (decision, effects) = s.interceptKey(.acceptAll)
        #expect(decision == .suppress)
        // Accept-all always empties the buffer → hide immediately after the insert.
        #expect(effects == [.insert(" world how"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func tabAcceptingTheLastWordHidesImmediatelyAndStillRefillsOnEcho() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)           // single-word ghost → Tab empties the buffer
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        // The just-accepted word would otherwise stay painted over the host's own inserted text until
        // the refill lands ~150–500 ms later (harness scenario `exhaustion-refill-real`).
        #expect(effects == [.insert(" world"), .present(.none)])
        #expect(s.currentPresentation == .none)
        // `echoPending` survives the hide: the echo still schedules the refill at the new caret.
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    @Test func tabWithWordsRemainingDoesNotHide() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert(" world")])       // no `.present(.none)` — unchanged
        #expect(s.currentPresentation == .continuation(" how"))
        #expect(s.handle(.hostEcho) == [.present(.continuation(" how"))])
    }

    @Test func correctionTakesTabPrecedenceOverContinuation() {
        var s = SuggestionSession()
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), fix))
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.replace(charactersBack: 3, with: "the")])
        // After the correction is applied, the continuation remains for the next Tab.
        #expect(s.currentPresentation == .continuation(" world"))
    }

    @Test func escapeClearsAndPassesThroughToHost() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)            // Esc still reaches the host
        #expect(effects == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func escapeWithNothingShowingStillClearsAndMutesProactiveRegen() {
        var s = SuggestionSession()
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none)])
        // The mute holds: a following caret move is HELD (no regenerate) until the user types.
        let moveEffects = s.handle(.caretMove)
        #expect(!moveEffects.contains(.schedulePredict(trigger: .caretMoved, debounceMs: 150)))
    }

    @Test func typingLiftsTheEscMute() {
        var s = SuggestionSession()
        _ = s.interceptKey(.escape)                  // mute proactive regen
        _ = s.handle(.typed("a"))                    // writing again lifts the mute
        let moveEffects = s.handle(.caretMove)
        #expect(moveEffects.contains(.schedulePredict(trigger: .caretMoved, debounceMs: 150)))
    }

    // MARK: Presentation precedence + value gate

    @Test func currentPresentationPrefersCorrectionOverContinuation() {
        var s = SuggestionSession()
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), fix))
        #expect(s.currentPresentation == .correction(fix))
    }

    @Test func lowValueContinuationIsSuppressed() {
        var s = SuggestionSession()
        let effects = { () -> [Effect] in
            _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
            return s.handle(.predictionArrived(Suggestion(text: "."), nil))   // punctuation-only → junk
        }()
        // The caret sits after a space, so the boundary-lead join records its verdict on the way past
        //  — and the value gate still drops the ghost. Order matters: the
        // join shapes, the gate at `setContinuation` decides whether anything is shown.
        #expect(effects == [.logGate("boundary-lead consumes-space"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func continuationShownAsSlidingDisplayWindow() {
        var s = SuggestionSession()
        showContinuation(" one two three four five six", in: &s)   // 6 words → window caps at 5
        #expect(s.currentPresentation == .continuation(" one two three four five"))
    }

    @Test func theCompletionLengthSettingWidensTheWindowWithoutASecondPredict() {
        // Short/Medium/Long is a DISPLAY change over an already-decoded buffer
        // — the flip must repaint, never cancel and never schedule inference.
        var s = SuggestionSession()
        showContinuation(" one two three four five six seven eight", in: &s)
        #expect(s.currentPresentation == .continuation(" one two three four five"))

        #expect(s.handle(.setCompletionLength(.long))
            == [.present(.continuation(" one two three four five six seven eight"))])
        #expect(s.handle(.setCompletionLength(.short))
            == [.present(.continuation(" one two three"))])
        // Tab still peels from the full buffer, so the window slides as before.
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" one")]))
        #expect(s.currentPresentation == .continuation(" two three four"))
    }

    @Test func reSelectingTheSameLengthAndFlippingWithNothingShownDoNothing() {
        var s = SuggestionSession()
        #expect(s.handle(.setCompletionLength(.medium)).isEmpty)   // already the default
        #expect(s.handle(.setCompletionLength(.long)).isEmpty)     // no ghost to repaint
        showContinuation(" one two three four five six", in: &s)
        #expect(s.currentPresentation == .continuation(" one two three four five six"))
    }

    /// Narrowing can uncover a punctuation-only head (the window is what is judged). That is a teardown,
    /// so it goes through the `clearPresentation()` chokepoint rather than painting nothing behind a
    /// still-armed echo.
    @Test func narrowingOntoAJunkHeadHidesTheGhost() {
        var s = SuggestionSession()
        showContinuation(" ( ) [ really", in: &s)
        #expect(s.handle(.setCompletionLength(.short)) == [.present(.none)])
        #expect(s.currentPresentation == .none)
        #expect(s.interceptKey(.tab) == (.passThrough, []))
    }

    // MARK: Word-only length step

    private func wordSession(prefix: String) -> SuggestionSession {
        var s = SuggestionSession()
        _ = s.handle(.setCompletionLength(.word))
        _ = s.handle(.contextReady(TypingContext(textBeforeCaret: prefix, textAfterCaret: "", bundleID: "com.test"),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        return s
    }

    @Test func theWordStepShowsOnlyTheRestOfTheWordBeingTyped() {
        var s = wordSession(prefix: "Thank you for your hel")
        let effects = s.handle(.predictionArrived(Suggestion(text: "lp with the project"), nil))
        #expect(effects == [.present(.continuation("lp"))])
        // Tab and option-Tab insert the same text.
        #expect(s.interceptKey(.acceptAll).1 == [.insert("lp"), .present(.none)])
    }

    @Test func theWordStepShowsNothingAtAWordBoundaryAndLogsTheGate() {
        var s = wordSession(prefix: "Thank you for your ")
        let effects = s.handle(.predictionArrived(Suggestion(text: "help with the project"), nil))
        #expect(effects == [.logGate("word-length at-boundary"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func theWordStepLogsTheGateWhenTheWordIsFinishedAndTheBufferOpensWithAGap() {
        var s = wordSession(prefix: "Thank you for your help")
        let effects = s.handle(.predictionArrived(Suggestion(text: " with the project"), nil))
        #expect(effects == [.logGate("word-length no-word-rest"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func theWordStepLogsTheGateOnTheRedundancyReplayToo() {
        var s = wordSession(prefix: "Thank you for your help.")
        _ = s.handle(.setCompletionLength(.long))
        _ = s.handle(.predictionArrived(Suggestion(text: " We start soon"), nil))
        _ = s.handle(.setCompletionLength(.word))
        let ctx = TypingContext(textBeforeCaret: "Thank you for your help.", textAfterCaret: "", bundleID: "com.test")
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects.contains(.logGate("word-length no-word-rest")))
        #expect(s.currentPresentation == .none)
    }

    @Test func theWordStepStillPresentsASpellCorrectionAtABoundary() {
        var s = wordSession(prefix: "Vershen ")
        let fix = Correction(original: "Vershen", replacement: "Version", charactersBackFromCaret: 8)
        let effects = s.handle(.predictionArrived(Suggestion(text: "of the app"), fix))
        #expect(effects == [.logGate("word-length at-boundary"), .present(.correction(fix))])
    }

    // MARK: Type-along (SmartAdvance)

    @Test func typedMatchingHeadAdvancesArmsEchoAndCancelsInFlight() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let effects = s.handle(.typed(" "))          // matches the ghost's leading gap
        #expect(effects == [.cancelInFlight])
        #expect(s.currentPresentation == .continuation("world"))
        // Echo was armed: the host's own insert re-renders in place.
        #expect(s.handle(.hostEcho) == [.present(.continuation("world"))])
    }

    @Test func typedExhaustingTheGhostArmsEchoForRefill() {
        var s = SuggestionSession()
        showContinuation(" a", in: &s)
        let effects = s.handle(.typed(" a"))         // consumes the whole single-word ghost
        // Exhaustion must HIDE immediately: the host's own character now sits where the last ghost
        // glyph was painted, and the refill is ~150 ms away. (Harness scenario boundary-refill caught a
        // lone trailing "s" visible over `reducer=none`.)
        #expect(effects == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
        // Echo fires the refill of the NEXT suggestion at the new caret.
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    @Test func typedDivergingHidesAndReinfers() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let effects = s.handle(.typed("x"))          // diverges from " world"
        #expect(effects == [.present(.none), .schedulePredict(trigger: .typing, debounceMs: 80)])
        #expect(s.currentPresentation == .none)
    }

    @Test func typedWithNoGhostSchedulesNormalPredict() {
        var s = SuggestionSession()
        let effects = s.handle(.typed("a"))
        #expect(effects == [.schedulePredict(trigger: .typing, debounceMs: 80)])
    }

    @Test func aBoundaryTypedUnderACorrectionKeepsTheCorrectionUntilThePredictArrives() {
        var s = SuggestionSession()
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), fix))
        let effects = s.handle(.typed(" "))          // a correction owns the ghost → notApplicable
        #expect(effects == [.schedulePredict(trigger: .typing, debounceMs: 80)])
        #expect(s.currentPresentation == .correction(fix))   // the word is closed, the fix still targets it
    }

    /// `shor→show` shown while the user is still typing `short`. The word grew, so a `Tab` now
    /// would replace the wrong characters; the stale correction goes at the keystroke, not at the
    /// next predict.
    @Test func aLetterTypedUnderACorrectionClearsTheStaleCorrection() {
        var s = SuggestionSession()
        let fix = Correction(original: "shor", replacement: "show", charactersBackFromCaret: 4)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ""), fix))
        let effects = s.handle(.typed("t"))
        #expect(effects == [.logGate("correction-stale"), .present(.none),
                            .schedulePredict(trigger: .typing, debounceMs: 80)])
        #expect(s.currentPresentation == .none)
    }

    // MARK: Echo (the former postInsertRenderPending invariant, now enforced)

    @Test func hostEchoWithoutAPendingInsertIsANoop() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)           // echoPending stays false (predictionArrived doesn't arm it)
        #expect(s.handle(.hostEcho).isEmpty)
    }

    @Test func hostEchoAfterTabRepaintsTheRemainingGhost() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)                     // arms echo, continuation → " how"
        #expect(s.handle(.hostEcho) == [.present(.continuation(" how"))])
        // Echo is one-shot: a second one without a new insert is a no-op.
        #expect(s.handle(.hostEcho).isEmpty)
    }

    @Test func echoPendingIsDroppedOnCaretMoveTeardown() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)                      // arm echo
        _ = s.handle(.caretMove)                      // teardown
        #expect(s.handle(.hostEcho).isEmpty)          // stale echo dropped
    }

    @Test func echoPendingIsDroppedOnFocusChangeTeardown() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.focusChanged)
        #expect(s.handle(.hostEcho).isEmpty)
    }

    @Test func echoPendingIsDroppedOnEscapeTeardown() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.interceptKey(.escape)
        #expect(s.handle(.hostEcho).isEmpty)
    }

    @Test func echoPendingIsDroppedOnPauseTeardown() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.setPaused(true))
        _ = s.handle(.setPaused(false))               // resume so.hostEcho isn't swallowed by the pause guard
        #expect(s.handle(.hostEcho).isEmpty)
    }

    @Test func echoPendingIsDroppedWhenTypingDiverges() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.tab)                      // arm echo (continuation → " how")
        _ = s.handle(.typed("z"))                     // diverges → clearPresentation drops echo
        #expect(s.handle(.hostEcho).isEmpty)
    }

    // MARK: Gate order / short-circuit (.contextReady)

    @Test func contextReadyWithNoUsableContextClears() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let effects = s.handleReady(.contextReady(nil, caret: nil, trigger: .typing))
        #expect(effects == [.present(.none)])
        #expect(s.currentPresentation == .none)
    }

    /// It suppresses the CONTINUATION and nothing else: the spell check still
    /// runs, honouring the rule that "AXTextField stays eligible so corrections still flow". The
    /// `wantsContinuation: false` effect is what makes this distinguishable from a suppressed
    /// correction — as an absence the two are the same empty effect list.
    @Test func contextReadyFieldSizeGateSuppressesTheContinuationButNotTheCorrection() {
        var s = SuggestionSession()
        let searchField = TypingContext(
            textBeforeCaret: "que", textAfterCaret: "", bundleID: "com.test",
            field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField"))
        let effects = s.handleReady(.contextReady(searchField, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.logGate("field-size"), .present(.none),
                            .runInference(searchField, wantsCorrection: true, wantsContinuation: false)])
    }

    /// Corrections are typing-driven, so a caret move has nothing to ask the spell checker
    /// for — the gate stays a plain teardown there, byte-identical to before the split.
    @Test func contextReadyFieldSizeGateOnACaretMoveAsksForNothing() {
        var s = SuggestionSession()
        let searchField = TypingContext(
            textBeforeCaret: "que ", textAfterCaret: "", bundleID: "com.test",
            field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField"))
        let effects = s.handleReady(.contextReady(searchField, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.logGate("field-size"), .present(.none)])
    }

    /// The end of the correction-only path: the empty suggestion the interpreter re-enters with leaves
    /// the correction as the presentation, which is the whole point of the split.
    @Test func aGatedContextStillPresentsItsCorrection() {
        var s = SuggestionSession()
        let searchField = TypingContext(
            textBeforeCaret: "Vershen", textAfterCaret: "", bundleID: "com.test",
            field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField"))
        _ = s.handle(.contextReady(searchField, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let correction = Correction(original: "Vershen", replacement: "Verschen", charactersBackFromCaret: 7)
        let effects = s.handle(.predictionArrived(Suggestion(text: ""), correction))
        #expect(effects == [.present(.correction(correction))])
        #expect(s.currentPresentation == .correction(correction))
    }

    @Test func contextReadyTypingProceedsToInferenceWantingCorrection() {
        var s = SuggestionSession()
        let ctx = endOfTextContext(before: "hello world")
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)])
    }

    @Test func contextReadyCaretMoveProceedsToInferenceWithoutCorrection() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()                  // caret after a space → proactive gate allows
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.runInference(ctx, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func contextReadyCaretMoveStrictlyInsideAWordSuppressed() {
        var s = SuggestionSession()
        let insideWord = TypingContext(textBeforeCaret: "sag hel", textAfterCaret: "lo", bundleID: "com.test")
        let effects = s.handleReady(.contextReady(insideWord, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
        #expect(effects == [.present(.none)])
    }

    @Test func contextReadyCaretMoveWithTextToTheRightSuppressedUntilFIM() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
        #expect(effects == [.present(.none)])
    }

    @Test func contextReadyCaretMoveWithNoCaretGeometrySuppressed() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()                  // position gate OK, but a nil caret reads as text-to-right
        let effects = s.handleReady(.contextReady(ctx, caret: nil, trigger: .caretMoved))
        #expect(effects == [.present(.none)])
    }

    @Test func fimEnabledAllowsMidTextCaretMove() {
        var s = SuggestionSession(fimEnabled: true)
        let ctx = endOfTextContext()
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
        #expect(effects == [.runInference(ctx, wantsCorrection: false, wantsContinuation: true)])
    }

    // MARK: The mid-text (FIM) toggle as a runtime setting

    @Test func turningFIMOnAtRuntimeLiftsTheMidTextSuppression() {
        var s = SuggestionSession()                       // default off
        let ctx = endOfTextContext()
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
                == [.present(.none)])
        _ = s.handle(.setFIMEnabled(true))
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
                == [.runInference(ctx, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func flippingTheFIMToggleTearsDownTheCurrentGhost() {
        // The showing ghost came from the other model path — stale the moment the route changes.
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        #expect(s.currentPresentation == .continuation(" world"))
        #expect(s.handle(.setFIMEnabled(true)) == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func aNoOpFIMFlipEmitsNothing() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        #expect(s.handle(.setFIMEnabled(false)) == [])
        #expect(s.currentPresentation == .continuation(" world"))
    }

    @Test func theFIMToggleIsRecordedEvenWhilePaused() {
        // Settings flips are not user input: dropping one because the app happened to be paused would
        // leave the reducer disagreeing with the switch the user just moved.
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        _ = s.handle(.setFIMEnabled(true))
        _ = s.handle(.setPaused(false))
        let ctx = endOfTextContext()
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: true), trigger: .caretMoved))
                == [.runInference(ctx, wantsCorrection: false, wantsContinuation: true)])
    }

    // MARK: Redundancy guard

    @Test func redundantCaretMoveRestoresCachedSuggestionWithoutInference() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()
        // A first real inference caches (ctx, " world").
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), nil))
        // A no-op caret move onto the identical context restores the cache — no re-inference.
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.present(.continuation(" world"))])
        #expect(!effects.contains { if case .runInference = $0 { return true } else { return false } })
        #expect(s.currentPresentation == .continuation(" world"))
    }

    @Test func changedWindowContextReInfersInsteadOfRestoring() {
        var s = SuggestionSession()
        let ctx = endOfTextContext(windowContext: nil)
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), nil))
        // Same prefix, but a late AX harvest filled windowContext → NOT redundant → re-infer.
        let enriched = endOfTextContext(windowContext: "surrounding page text")
        let effects = s.handleReady(.contextReady(enriched, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.runInference(enriched, wantsCorrection: false, wantsContinuation: true)])
    }

    // Every field that reaches the prompt must break redundancy; a field that only feeds a gate must
    // not. One case per field, so the next context source added to the
    // prompt meets a failing test rather than a silent omission — which is how `replyContext` and
    // `ocrContext` came to be missing after the same rule had already been applied twice by hand.

    /// Cache a suggestion against `first`, then present `second` on a caret move and report whether the
    /// session re-inferred (`true`) or replayed the cache (`false`).
    private func reInfers(from first: TypingContext, to second: TypingContext) -> Bool {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(first, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), nil))
        let effects = s.handleReady(.contextReady(second, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        return effects.contains { if case .runInference = $0 { return true } else { return false } }
    }

    @Test func changedReplyContextReInfersInsteadOfRestoring() {
        // The interlocutor answers while the compose box is untouched, then the user clicks back in.
        // The prompt now carries a different reply segment, so the cached suggestion — which
        // was computed against the PREVIOUS turn — must not be replayed.
        var withReply = endOfTextContext()
        withReply.replyContext = "Claude's most recent turn."
        #expect(reInfers(from: endOfTextContext(), to: withReply))
    }

    @Test func changedOCRContextReInfersInsteadOfRestoring() {
        var withOCR = endOfTextContext()
        withOCR.ocrContext = OCRContext(ambient: "a reference window", focusedFill: nil)
        #expect(reInfers(from: endOfTextContext(), to: withOCR))

        // Both roles reach the prompt, so both count.
        var withFill = endOfTextContext()
        withFill.ocrContext = OCRContext(ambient: nil, focusedFill: "the AX-blind body text")
        #expect(reInfers(from: endOfTextContext(), to: withFill))
    }

    /// Acceptance item 4: an unchanged screen must NOT re-infer. `OCRContext` carries only its two
    /// prompt-reaching strings, so two reads of the same screen compare equal and the OCR cadence costs
    /// no inference of its own — the failure mode that would be worse than the bug being fixed.
    @Test func anUnchangedOCRReadIsStillRedundant() {
        var ctx = endOfTextContext()
        ctx.ocrContext = OCRContext(ambient: "a reference window", focusedFill: nil)
        var same = endOfTextContext()
        same.ocrContext = OCRContext(ambient: "a reference window", focusedFill: nil)
        #expect(!reInfers(from: ctx, to: same))
    }

    @Test func changedPersonalizationReInfersInsteadOfRestoring() {
        var primed = endOfTextContext()
        primed.personalization = "An exemplar in the user's own voice."
        #expect(reInfers(from: endOfTextContext(), to: primed))
    }

    @Test func changedClipboardContextReInfersInsteadOfRestoring() {
        var copied = endOfTextContext()
        copied.clipboardContext = "Musterstrasse 12, 10115 Berlin"
        #expect(reInfers(from: endOfTextContext(), to: copied))
        #expect(endOfTextContext().predictionInputs != copied.predictionInputs)
    }

    @Test func changedBundleIDReInfersInsteadOfRestoring() {
        var elsewhere = endOfTextContext()
        elsewhere.bundleID = "com.other.app"
        #expect(reInfers(from: endOfTextContext(), to: elsewhere))
    }

    @Test func changedPrefixReInfersInsteadOfRestoring() {
        #expect(reInfers(from: endOfTextContext(), to: endOfTextContext(before: "hello world again ")))
    }

    @Test func changedTextAfterCaretReInfersInsteadOfRestoring() {
        // It becomes the FIM suffix `S` and decides the `FIMSite` route.
        var withSuffix = endOfTextContext()
        withSuffix.textAfterCaret = "and the rest of the paragraph"
        #expect(reInfers(from: endOfTextContext(), to: withSuffix))
    }

    /// The two gate-only fields, asserted on `predictionInputs` rather than through the reducer: both
    /// gates sit AHEAD of the redundancy check in `handleContextReady`, so a context that differs in
    /// `selectionLength` is stopped by `SelectionGate` before redundancy is ever consulted. The claim
    /// being pinned is the rule itself — these decide whether a suggestion is *shown*, never what it
    /// would say, so neither may spend an inference.
    @Test func gateOnlyFieldsDoNotParticipateInTheRedundancyComparison() {
        let base = endOfTextContext()

        var selecting = base
        selecting.selectionLength = 12
        #expect(selecting.predictionInputs == base.predictionInputs)

        var described = base
        described.field = FieldDescriptor(role: "AXTextArea", subrole: nil, width: 600, height: 400)
        #expect(described.predictionInputs == base.predictionInputs)

        var onASite = base
        onASite.siteHost = "docs.google.com"
        #expect(onASite.predictionInputs == base.predictionInputs)
    }

    @Test func predictionArrivedRecordsTheContextThatRequestedInference() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " world"), nil))
        // Proof it was cached: an identical caret move now restores rather than re-infers.
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.present(.continuation(" world"))])
    }

    // MARK: Pause

    @Test func pausingCancelsInFlightAndClears() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let effects = s.handle(.setPaused(true))
        #expect(effects == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func aBlindTapHidesAVisibleGhostAndTheNextKeystrokeRegenerates() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let hide = s.handle(.eventTapBlinded)
        #expect(hide == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
        let next = s.handle(.typed("a"))
        #expect(next.contains { if case .schedulePredict = $0 { return true } else { return false } })
    }

    @Test func eventsWhilePausedAreIgnored() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.typed("a")).isEmpty)
        #expect(s.handle(.caretMove).isEmpty)
        #expect(s.handle(.pointer).isEmpty)
        #expect(s.handle(.focusChanged).isEmpty)
        #expect(s.handle(.screenshotShortcut).isEmpty)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .passThrough)
        #expect(effects.isEmpty)
    }

    /// Resuming is an explicit act and must produce a visible result — the asymmetry against pausing
    /// (which visibly removes the ghost) is what made this read as broken.
    /// Deliberately bypasses the Esc mute the caret-move path honours: pressing the hotkey IS the
    /// statement of intent, and every gate still applies downstream of the scheduled predict.
    @Test func unpausingRegeneratesAtTheCaret() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.setPaused(false)) == [.schedulePredict(trigger: .caretMoved, debounceMs: 150)])
    }

    @Test func unpausingRegeneratesEvenAfterAnEscMute() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.interceptKey(.escape)                    // mutes proactive regen for caret moves
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.setPaused(false)) == [.schedulePredict(trigger: .caretMoved, debounceMs: 150)])
    }

    @Test func redundantPauseToggleIsANoop() {
        var s = SuggestionSession()
        #expect(s.handle(.setPaused(false)).isEmpty)   // already unpaused — no spurious regeneration
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.setPaused(true)).isEmpty)    // already paused
    }

    // MARK: Screenshot arm / disarm + click suppression

    @Test func screenshotShortcutArmsAndSchedulesDisarm() {
        var s = SuggestionSession()
        #expect(s.handle(.screenshotShortcut) == [.scheduleScreenshotDisarm(seconds: 12)])
    }

    @Test func clickWhileArmedKeepsTheGhost() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.handle(.screenshotShortcut)              // arm
        let effects = s.handle(.pointer)
        #expect(effects.isEmpty)                        // click suppressed — drag won't wipe the ghost
        #expect(s.currentPresentation == .continuation(" world"))
    }

    @Test func clickWhileNotArmedHidesAndRegenerates() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        let effects = s.handle(.pointer)
        #expect(effects == [.cancelInFlight, .present(.none),
                            .schedulePredict(trigger: .caretMoved, debounceMs: 150)])
        #expect(s.currentPresentation == .none)
    }

    @Test func screenshotDisarmExpiredReenablesClickDismissal() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.handle(.screenshotShortcut)
        #expect(s.handle(.screenshotDisarmExpired).isEmpty)
        // Now a click dismisses again.
        let effects = s.handle(.pointer)
        #expect(effects.contains(.present(.none)))
    }

    @Test func escWhileArmedKeepsTheGhostAndStaysArmed() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.handle(.screenshotShortcut)              // arm
        let (decision, effects) = s.interceptKey(.escape)   // Esc = cancel the crosshair, not the ghost
        #expect(decision == .passThrough)
        #expect(effects.isEmpty)                        // no clear, no mute
        #expect(s.currentPresentation == .continuation(" world"))
        // Still armed: a click after the Esc keeps the ghost too (the capture interaction survives).
        #expect(s.handle(.pointer).isEmpty)
        #expect(s.currentPresentation == .continuation(" world"))
    }

    @Test func escWhileArmedDoesNotMuteProactiveRegen() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.handle(.screenshotShortcut)              // arm
        _ = s.interceptKey(.escape)                     // swallowed by the arm window — must not mute
        _ = s.handle(.screenshotDisarmExpired)
        // Not muted: a caret move still hides + schedules the regenerate predict.
        let effects = s.handle(.caretMove)
        #expect(effects.contains(.schedulePredict(trigger: .caretMoved, debounceMs: 150)))
    }

    @Test func escAfterDisarmClearsAndMutesAsBefore() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.handle(.screenshotShortcut)
        _ = s.handle(.screenshotDisarmExpired)          // window over → Esc is a normal dismiss again
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func typingDisarmsTheScreenshotWindow() {
        var s = SuggestionSession()
        _ = s.handle(.screenshotShortcut)              // arm (nothing showing yet)
        _ = s.handle(.typed("a"))                       // editing again → disarm
        showContinuation(" world", in: &s)
        #expect(s.handle(.pointer).contains(.present(.none)))   // click now dismisses
    }

    @Test func caretMoveDisarmsTheScreenshotWindow() {
        var s = SuggestionSession()
        _ = s.handle(.screenshotShortcut)
        _ = s.handle(.caretMove)                        // disarms
        showContinuation(" world", in: &s)
        #expect(s.handle(.pointer).contains(.present(.none)))
    }

    // MARK: The `middle|S` terminal join at the accept call site

    /// Drive the pipeline to a bridge-shaped ghost: a mid-text caret (`textAfterCaret` = the suffix `S`)
    /// on the typing trigger, which skips the proactive right-text gate the same way the App does.
    private func showBridge(
        _ text: String,
        suffix: String,
        in session: inout SuggestionSession
    ) {
        let context = TypingContext(
            textBeforeCaret: "Der Hund springt",
            textAfterCaret: suffix,
            bundleID: "com.test"
        )
        _ = session.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: true), trigger: .typing))
        _ = session.handle(.predictionArrived(Suggestion(text: text), nil))
    }

    @Test func terminalBridgeAcceptJoinsToTheSuffix() {
        var s = SuggestionSession(fimEnabled: true)
        showBridge(" schnell", suffix: "über den Zaun.", in: &s)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        // Without the join this would insert " schnell" flush against "über" → "schnellüber".
        #expect(effects == [.insert(" schnell "), .present(.none)])
    }

    @Test func interiorBridgeAcceptInsertsExactlyThePeeledWord() {
        var s = SuggestionSession(fimEnabled: true)
        showBridge(" springt schnell", suffix: "über den Zaun.", in: &s)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert(" springt")])          // the remainder still carries its own gap
        // …and the accept that empties the buffer is the one that joins.
        #expect(s.interceptKey(.tab).1 == [.insert(" schnell "), .present(.none)])
    }

    @Test func acceptAllOnABridgeJoinsToTheSuffix() {
        var s = SuggestionSession(fimEnabled: true)
        showBridge(" springt schnell", suffix: "über den Zaun.", in: &s)
        #expect(s.interceptKey(.acceptAll).1 == [.insert(" springt schnell "), .present(.none)])
    }

    @Test func terminalAcceptIsByteIdenticalWithFIMOff() {
        // The shipping default: the same mid-text shape must insert exactly the peeled word.
        var s = SuggestionSession()
        showBridge(" schnell", suffix: "über den Zaun.", in: &s)
        #expect(s.interceptKey(.tab).1 == [.insert(" schnell"), .present(.none)])
    }

    @Test func terminalForwardAcceptIsUnaffectedEvenWithFIMOn() {
        // End-of-text caret → `FIMSite.route` answers `.forward`, so no separator is appended.
        var s = SuggestionSession(fimEnabled: true)
        showContinuation(" world", in: &s)
        #expect(s.interceptKey(.tab).1 == [.insert(" world"), .present(.none)])
    }

    // MARK: The selection gate

    /// The reported symptom: a ghost is showing, ⌘A selects everything, and the re-read that ⌘A now
    /// triggers must tear the ghost down instead of continuing a text that is about to be replaced.
    @Test func aNonEmptySelectionTearsTheGhostDownAndSpendsNoInference() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        #expect(s.currentPresentation == .continuation(" world how"))

        var selected = endOfTextContext()
        selected.selectionLength = selected.textBeforeCaret.count
        let effects = s.handleReady(.contextReady(selected, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        // The gate short-circuits ahead of `.runInference` — that is what makes routing ⌘A through the
        // ordinary caret-move path free rather than a prediction on a doomed prefix.
        #expect(effects == [.logGate("selection len=12"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    /// It is a gate, not a key classification: a MOUSE drag-selection produces no keyDown, so the same
    /// suppression has to hold on the typing trigger too.
    @Test func theSelectionGateAppliesOnEveryTrigger() {
        var s = SuggestionSession()
        var selected = endOfTextContext()
        selected.selectionLength = 3
        let effects = s.handleReady(.contextReady(selected, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.logGate("selection len=3"), .present(.none)])
    }

    /// The reasoned exception: the other two cold-start gates let the spell fix
    /// through, this one does not — over a selection the corrected word is about to be replaced along
    /// with everything else. Pinned so a later "make the gates consistent" pass has to argue with a
    /// failing test rather than a comment.
    @Test func theSelectionGateSuppressesTheCorrectionToo() {
        var s = SuggestionSession()
        var selected = endOfTextContext(before: "Vershen")
        selected.selectionLength = 7
        let effects = s.handleReady(.contextReady(selected, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.logGate("selection len=7"), .present(.none)])
        #expect(!effects.contains { if case .runInference = $0 { return true } else { return false } })
    }

    @Test func collapsingTheSelectionResumesSuggestions() {
        var s = SuggestionSession()
        var selected = endOfTextContext()
        selected.selectionLength = 12
        _ = s.handle(.contextReady(selected, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))

        let collapsed = endOfTextContext()
        #expect(s.handleReady(.contextReady(collapsed, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
                == [.runInference(collapsed, wantsCorrection: false, wantsContinuation: true)])
    }

    /// Gate order pin: the selection gate sits between the field-size gate and the running-thought
    /// gate, so a selection in a context that would ALSO fail arm 1 is reported as the selection —
    /// the more specific and more actionable of the two, and the one that made the ghost visible.
    @Test func theSelectionGateIsReportedAheadOfTheRunningThoughtGate() {
        var s = SuggestionSession()
        var selected = endOfTextContext(before: "Alles war gut.\n\nTest 4 (Lena):\n")
        selected.selectionLength = 30
        let effects = s.handleReady(.contextReady(selected, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.logGate("selection len=30"), .present(.none)])
    }

    // MARK: Right-to-left guard (`misc: suppress suggestions in right-to-left text`)

    @Test func hebrewTextBeforeTheCaretYieldsNoContinuationAndNoCorrection() {
        var s = SuggestionSession()
        let ctx = endOfTextContext(before: "שלום עולם")
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.logGate("rtl-text"), .present(.none)])
    }

    @Test func arabicAndMixedParagraphsAreSuppressedToo() {
        for before in ["مرحبا بالعالم", "Der Hund שלום"] {
            var s = SuggestionSession()
            let ctx = endOfTextContext(before: before)
            #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                    == [.logGate("rtl-text"), .present(.none)])
        }
    }

    @Test func aLeftToRightParagraphAfterAHebrewParagraphStillGetsItsGhost() {
        var s = SuggestionSession()
        let ctx = endOfTextContext(before: "שלום עולם\nDer Hund läuft")
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                == [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)])
    }

    @Test func forceActivateDoesNotOverrideTheRightToLeftGuard() {
        var s = SuggestionSession()
        let ctx = endOfTextContext(before: "שלום עולם")
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .forceActivate))
                == [.logGate("rtl-text"), .present(.none)])
    }

    // MARK: The two hard bars at the seam

    /// Arm 1 runs alongside `FieldSizeGate` — before spell-check and inference, on EVERY trigger.
    @Test func runningThoughtArm1SuppressesAtASentenceStart() {
        var s = SuggestionSession()
        let afterHeading = endOfTextContext(before: "Alles war gut.\n\nTest 4 (Lena):\n")
        let effects = s.handleReady(.contextReady(afterHeading, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        // Continuation only — the word before the caret is the line's FIRST word,
        // the position where a suppressed spell check can never be recovered from.
        #expect(effects == [.logGate("running-thought absent"), .present(.none),
                            .runInference(afterHeading, wantsCorrection: true, wantsContinuation: false)])
    }

    @Test func runningThoughtArm1LiftsOnceTheSentenceHasTwoWords() {
        var s = SuggestionSession()
        let started = endOfTextContext(before: "Alles war gut.\n\nTest 4 (Lena):\nLena fand")
        let effects = s.handleReady(.contextReady(started, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects == [.runInference(started, wantsCorrection: true, wantsContinuation: true)])
    }

    /// Arm 2 refuses the ghost that carried the model's own structural break — the first link of the
    /// jump chain, which is the only one that carries the signal.
    @Test func runningThoughtArm2RefusesAGhostThatAbandonsTheThought() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: "8.", abandonsRunningThought: true), nil))
        #expect(effects == [.logGate("running-thought abandoned"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func aGhostWithoutTheBreakSignalIsUnaffected() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: " how are you"), nil))
                == [.present(.continuation(" how are you"))])
    }

    /// The copy guard reads the prefix of the context that requested the inference.
    @Test func copyGuardTrimsAVerbatimRunAgainstThePrefix() {
        var s = SuggestionSession()
        let note = TypingContext(
            textBeforeCaret: "Maja war sehr froh darüber dass sie jetzt Zugang zu der Marke hat. Lena war",
            textAfterCaret: "", bundleID: "com.test")
        _ = s.handle(.contextReady(note, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let copied = Suggestion(text: " sehr froh darüber dass sie jetzt Zugang zu")
        let effects = s.handle(.predictionArrived(copied, nil))
        #expect(effects.contains { if case .logGate(let t) = $0 { return t.hasPrefix("copy-guard trimmed run=") }; return false })
        #expect(s.currentPresentation == .none)
    }

    @Test func unsupportedNumberIsTrimmedAndLogged() {
        var s = SuggestionSession()
        let note = TypingContext(textBeforeCaret: "Wir treffen uns", textAfterCaret: "", bundleID: "com.test")
        _ = s.handle(.contextReady(note, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: " am 14. Mai"), nil))
        #expect(effects == [.logGate("unsupported-number trimmed"), .present(.continuation(" am"))])
    }

    @Test func ghostThatIsOnlyANumberIsSuppressedAndLogged() {
        var s = SuggestionSession()
        let note = TypingContext(textBeforeCaret: "Das Jahr", textAfterCaret: "", bundleID: "com.test")
        _ = s.handle(.contextReady(note, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: " 2024"), nil))
        #expect(effects == [.logGate("unsupported-number suppressed"), .present(.none)])
    }

    @Test func numberFromTheWindowContextPassesTheGuard() {
        var s = SuggestionSession()
        var note = TypingContext(textBeforeCaret: "Das Jahr", textAfterCaret: "", bundleID: "com.test")
        note.windowContext = "Bericht 2024"
        _ = s.handle(.contextReady(note, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: " 2024"), nil))
                == [.present(.continuation(" 2024"))])
    }

    /// Structure before content: arm 2 has already emptied the text, so the more expensive n-gram
    /// comparison never runs and only one token is logged.
    @Test func theAbandonedGhostIsNotAlsoCopyChecked() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: "8.", abandonsRunningThought: true), nil))
        #expect(effects.count == 2)
    }

    /// The arm-2 refusal is logged on the DECISION, not on its effect. A decode
    /// that arrives already empty — the boundary-lead suppression can empty the same decode
    /// arm 2 flags — is the cheapest case to hit, so a count conditioned on the text moving biases the
    /// first measurement anyone takes in the reassuring direction.
    @Test func anAlreadyEmptyDecodeStillLogsTheArm2Refusal() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: "", abandonsRunningThought: true), nil))
        #expect(effects == [.logGate("running-thought abandoned"), .present(.none)])
    }

    /// …and an empty decode WITHOUT the flag is an ordinary empty prediction, not a gate refusal.
    @Test func anEmptyDecodeWithoutTheFlagLogsNothing() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: ""), nil)) == [.present(.none)])
    }

    /// The cached copy tells the truth about what the model did. Gating
    /// changes the TEXT; it does not retroactively change whether the decode carried a structural
    /// break, and the flag crosses the engine→Core boundary precisely so a later reader can count it.
    @Test func theCachedSuggestionCarriesTheAbandonsFlag() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " weiter", abandonsRunningThought: true), nil))
        #expect(s.lastSuggestion?.abandonsRunningThought == true)
        #expect(s.lastSuggestion?.text == "")
    }

    @Test func theCachedSuggestionOfACleanPredictionCarriesNoFlag() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " how are you"), nil))
        #expect(s.lastSuggestion?.abandonsRunningThought == false)
    }

    /// The redundancy cache holds the GATED suggestion, so a no-op caret move cannot replay what the
    /// bars refused.
    @Test func theRedundancyCacheHoldsTheGatedSuggestion() {
        var s = SuggestionSession()
        let ctx = endOfTextContext()
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: " weiter", abandonsRunningThought: true), nil))
        // Same context again on a caret move → redundant → restore the cache, which must be empty.
        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.present(.none)])
        #expect(s.currentPresentation == .none)
    }
    // MARK: Word completion vs. next word

    /// A flush caret at the end of a word, i.e. the configuration where a continuation with no
    /// leading space renders glued (`Wort` + `laut` → `Wortlaut`).
    private func flushWordEndContext() -> TypingContext {
        TypingContext(textBeforeCaret: "Am Anfang war das Wort", textAfterCaret: "", bundleID: "com.test")
    }

    @Test func aTypedFlushCaretKeepsTheGluedCompletion() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(flushWordEndContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: "laut ist entscheidend"), nil))
        #expect(effects == [.present(.continuation("laut ist entscheidend"))])
        #expect(s.currentPresentation == .continuation("laut ist entscheidend"))
    }

    @Test func aNavigatedFlushCaretRefusesTheGluedCompletion() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(flushWordEndContext(), caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        let effects = s.handle(.predictionArrived(Suggestion(text: "laut ist entscheidend"), nil))
        #expect(effects == [.logGate("word-completion suppressed"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    @Test func aNavigatedFlushCaretStillShowsANextWordContinuation() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(flushWordEndContext(), caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        let effects = s.handle(.predictionArrived(Suggestion(text: " ist entscheidend"), nil))
        #expect(effects == [.present(.continuation(" ist entscheidend"))])
    }

    /// A caret that arrived by BACKSPACE is navigation (`KeyClassifier` routes it as a caret move) and
    /// lands mid-word by nature — the case the ticket calls out as most likely to be wrong in either
    /// direction. Decided as navigation: the user deleted, they did not type a fragment.
    @Test func aCaretReachedByBackspaceRefusesTheGluedCompletion() {
        var s = SuggestionSession()
        let midWord = TypingContext(textBeforeCaret: "Ich suche eine Woh", textAfterCaret: "", bundleID: "com.test")
        _ = s.handle(.contextReady(midWord, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        let effects = s.handle(.predictionArrived(Suggestion(text: "nung"), nil))
        #expect(effects == [.logGate("word-completion suppressed"), .present(.none)])
    }

    /// The reported flow: the ghost is legitimately glued while typing, the user then leaves the word
    /// and comes back to its end. The context is unchanged, so this takes the REDUNDANCY REPLAY branch
    /// — which therefore has to apply the same bar, or the fix is invisible exactly where the bug was
    /// reported. Re-inferring instead would be pointless: equal `predictionInputs` mean an identical
    /// prompt and greedy decoding would return the same text.
    @Test func theRedundancyReplayDoesNotRestoreAGluedCompletionAtANavigatedCaret() {
        var s = SuggestionSession()
        let ctx = flushWordEndContext()
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: "laut ist entscheidend"), nil))
        #expect(s.currentPresentation == .continuation("laut ist entscheidend"))

        let effects = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(effects == [.logGate("word-completion suppressed"), .present(.none)])
        #expect(s.currentPresentation == .none)
        // And nothing was spent re-asking: no inference in the batch.
        #expect(!effects.contains { if case .runInference = $0 { return true } else { return false } })
    }

    // MARK: Boundary-lead join — replace-backwards instead of suppress

    /// The caret the ticket is about: a finished sentence and the post-`Tab` space after it.
    private func whitespaceCaretContext(before: String = "Es war ein kalter Winter ") -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: "", bundleID: "com.test")
    }

    @Test func aBoundaryLeadAtAWhitespaceCaretIsShownAndFlaggedInsteadOfSuppressed() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))
        #expect(effects == [.logGate("boundary-lead consumes-space"),
                            .present(.continuation(ContinuationGhost(". Es wird kalt",
                                                                     consumesPrecedingSpace: true)))])
    }

    /// The whole point: `Tab` writes over the space rather than after it, so the document reads
    /// `Winter. Es` — exactly once, with no double space (the acceptance criterion's host equality,
    /// asserted here as the effect that produces it).
    @Test func theFirstAcceptConsumesTheSpaceExactlyOnce() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))

        let (decision, first) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(first == [.replace(charactersBack: 1, with: ".")])

        // …and only the first. The remainder is an ordinary insert-only continuation again, so the
        // second accept must NOT eat the space the first one just re-established.
        #expect(s.currentPresentation == .continuation(" Es wird kalt"))
        let (_, second) = s.interceptKey(.tab)
        #expect(second == [.insert(" Es")])
    }

    /// `→` accepts the whole buffer and is the same first edit.
    @Test func acceptAllAlsoConsumesTheSpace() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))
        let (_, effects) = s.interceptKey(.acceptAll)
        #expect(effects == [.replace(charactersBack: 1, with: ". Es wird kalt"), .present(.none)])
    }

    /// Typing the punctuation yourself hands the space back to the user: the type-along trims the
    /// ghost through `SmartAdvance`, whose remainder is a plain `Suggestion`, so nothing downstream
    /// can replace backwards against a caret that has since moved.
    @Test func aTypeAlongDropsTheConsumeFlag() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))
        #expect(s.handle(.typed(".")) == [.cancelInFlight])
        #expect(s.currentPresentation == .continuation(" Es wird kalt"))
        let (_, effects) = s.interceptKey(.tab)
        #expect(effects == [.insert(" Es")])
    }

    /// The verdict must survive into the redundancy cache, or a no-op caret move replays a ghost that
    /// looks identical and accepts differently.
    @Test func theRedundancyReplayKeepsTheConsumeFlag() {
        var s = SuggestionSession()
        let ctx = whitespaceCaretContext()
        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))
        #expect(s.lastSuggestion?.consumesPrecedingSpace == true)

        _ = s.handle(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        let (_, effects) = s.interceptKey(.tab)
        #expect(effects == [.replace(charactersBack: 1, with: ".")])
    }

    /// The flush-caret case the boundary-lead rule exists to enable stays byte-identical — no flag, no replace.
    @Test func aBoundaryLeadAtAFlushCaretIsUnchanged() {
        var s = SuggestionSession()
        let flush = TypingContext(textBeforeCaret: "Es war ein kalter Winter", textAfterCaret: "",
                                  bundleID: "com.test")
        _ = s.handle(.contextReady(flush, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: ". Es wird kalt"), nil))
        #expect(effects == [.present(.continuation(". Es wird kalt"))])
        let (_, accept) = s.interceptKey(.tab)
        #expect(accept == [.insert(".")])
    }

    /// A bare mark is still refused — by `SuggestionValueGate`, not by this join. The three bare `"?"`
    /// of the archived count therefore stay invisible, which is the ticket's own prediction.
    @Test func aBareMarkIsStillDroppedByTheValueGate() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: "?"), nil))
        #expect(effects == [.logGate("boundary-lead consumes-space"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    // MARK: The accept refill keeps its own trigger (the regression this mechanism invites)

    /// Exhausting the buffer must refill exactly as before. The refill's trigger is now `.acceptRefill`
    /// rather than `.caretMoved` — the *only* difference — and everything the loop derives from a caret
    /// move still applies to it. If someone later collapses the two back together, the glued refill
    /// below is refused and the `Tab` chain stalls at every exhaustion; these two tests fail first.
    @Test func exhaustingTheBufferRefillsOnTheAcceptRefillTrigger() {
        var s = SuggestionSession()
        showContinuation(" world", in: &s)
        _ = s.interceptKey(.tab)
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
    }

    @Test func theAcceptRefillShowsAGluedContinuationAtTheWordItJustInserted() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(flushWordEndContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .acceptRefill))
        let effects = s.handle(.predictionArrived(Suggestion(text: "laut ist entscheidend"), nil))
        #expect(effects == [.present(.continuation("laut ist entscheidend"))])
    }

    /// …while staying a caret move in every other respect: no spell-check is asked for (corrections are
    /// typing-driven), the mid-text arm still suppresses, and the debounce is the caret-settle
    /// one. Byte-identical to the old `.caretMoved` refill.
    @Test func theAcceptRefillIsACaretMoveInEveryOtherRespect() {
        var s = SuggestionSession()
        let effects = s.handleReady(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false),
                                             trigger: .acceptRefill))
        #expect(effects == [.runInference(endOfTextContext(), wantsCorrection: false, wantsContinuation: true)])

        var t = SuggestionSession()
        let midText = TypingContext(textBeforeCaret: "hello world ", textAfterCaret: "rest", bundleID: "com.test")
        #expect(t.handleReady(.contextReady(midText, caret: CaretFacts(hasTextToRight: true), trigger: .acceptRefill))
                == [.present(.none)])
    }

    // MARK: Sentence-start case

    /// The ghost that follows a typed `.` opens a sentence, so it is painted — and accepted —
    /// capitalized. The shaping applies to the BUFFER, so the cache the redundancy replay restores
    /// carries the same text.
    @Test func aContinuationOpeningASentenceIsCapitalized() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(before: "Es war ein kalter Winter. "),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: "dann kam der Frühling"), nil))
                == [.present(.continuation("Dann kam der Frühling"))])
        #expect(s.lastSuggestion?.text == "Dann kam der Frühling")
    }

    /// An ordinary mid-sentence continuation is byte-identical — the guard is silent everywhere it
    /// cannot prove an opening, which is nearly everywhere.
    @Test func anOrdinaryContinuationIsUntouchedByTheCaseGuard() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(before: "Es war ein sehr "),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: "kalter Winter"), nil))
                == [.present(.continuation("kalter Winter"))])
    }

    /// Ordering: the join runs first and settles the leading whitespace, then the case guard reads the
    /// word after the punctuation. Both verdicts survive into one presentation.
    @Test func aBoundaryLeadIsJoinedAndThenCapitalized() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(whitespaceCaretContext(), caret: CaretFacts(hasTextToRight: false),
                                   trigger: .typing))
        #expect(s.handle(.predictionArrived(Suggestion(text: ". dann wird es kalt"), nil))
                == [.logGate("boundary-lead consumes-space"),
                    .present(.continuation(ContinuationGhost(". Dann wird es kalt",
                                                             consumesPrecedingSpace: true)))])
    }

    // MARK: Force-activate + the temporary per-app quiet

    /// A small single-line field the `FieldSizeGate` refuses on its own (search/address bars).
    private func searchFieldContext() -> TypingContext {
        TypingContext(textBeforeCaret: "hello world ", textAfterCaret: "", bundleID: "com.test",
                      field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField"))
    }

    /// A caret whose sentence holds no running thought yet — `RunningThoughtGate` arm 1 refuses it.
    private func thinRunningThoughtContext() -> TypingContext {
        TypingContext(textBeforeCaret: "Test 4 (Lena):\nDie ", textAfterCaret: "", bundleID: "com.test")
    }

    @Test func forceActivateSchedulesAnUndebouncedPredict() {
        var s = SuggestionSession()
        // Its own trigger, and no debounce: the debounce coalesces a burst or lets a caret settle, and
        // a single deliberate press is neither.
        #expect(s.handle(.forceActivate) == [.schedulePredict(trigger: .forceActivate, debounceMs: 0)])
    }

    @Test func forceActivateOverridesTheFieldSizeGate() {
        var s = SuggestionSession()
        let field = searchFieldContext()
        // The control: without the press this surface is continuation-gated (correction only).
        #expect(s.handleReady(.contextReady(field, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                == [.logGate("field-size"), .present(.none), .runInference(field, wantsCorrection: true, wantsContinuation: false)])
        #expect(s.handleReady(.contextReady(field, caret: CaretFacts(hasTextToRight: false), trigger: .forceActivate))
                == [.logGate("force-activate override"),
                    .runInference(field, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func forceActivateOverridesTheRunningThoughtGate() {
        var s = SuggestionSession()
        let thin = thinRunningThoughtContext()
        #expect(s.handleReady(.contextReady(thin, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                == [.logGate("running-thought absent"), .present(.none),
                    .runInference(thin, wantsCorrection: true, wantsContinuation: false)])
        #expect(s.handleReady(.contextReady(thin, caret: CaretFacts(hasTextToRight: false), trigger: .forceActivate))
                == [.logGate("force-activate override"),
                    .runInference(thin, wantsCorrection: false, wantsContinuation: true)])
    }

    /// The one cold-start gate force does NOT override: over a selection there is no suggestion we
    /// declined to offer, because the text being continued is the text the next keystroke deletes.
    /// Pinned so a later "make the gates consistent" pass meets a failure rather than a comment.
    @Test func forceActivateDoesNotOverrideTheSelectionGate() {
        var s = SuggestionSession()
        var selected = endOfTextContext()
        selected.selectionLength = 12
        #expect(s.handleReady(.contextReady(selected, caret: CaretFacts(hasTextToRight: false),
                                       trigger: .forceActivate))
                == [.logGate("selection len=12"), .present(.none)])
    }

    /// The named payoff — an AX-blind compose body — is the one shape the key cannot fix: with no text
    /// there is nothing to continue from. It says so in the log instead of failing silently.
    @Test func forceActivateWithNoContextSaysSoRatherThanFailingSilently() {
        var s = SuggestionSession()
        #expect(s.handleReady(.contextReady(nil, caret: nil, trigger: .forceActivate))
                == [.logGate("force-activate no-context"), .present(.none)])
        // Unchanged for every other trigger: the ordinary cannot-predict teardown carries no token.
        #expect(s.handleReady(.contextReady(nil, caret: nil, trigger: .typing)) == [.present(.none)])
    }

    /// It overrides our gates, never the user's own settings. Pause is checked before any event is
    /// interpreted at all, so the press cannot reach the gates from a paused session.
    @Test func forceActivateCannotUnpause() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        #expect(s.handle(.forceActivate).isEmpty)
    }

    /// An Esc mute is deliberately bypassed, exactly as the resume-from-pause arm bypasses it: an Esc
    /// says *not this suggestion*, this key says *one now*.
    @Test func forceActivateIsNotSwallowedByTheEscMute() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        _ = s.interceptKey(.escape)
        #expect(s.handle(.caretMove) == [.cancelInFlight, .present(.none)])   // muted: no predict
        #expect(s.handle(.forceActivate) == [.schedulePredict(trigger: .forceActivate, debounceMs: 0)])
    }

    @Test func quietingAnAppTearsDownTheGhostImmediately() {
        var s = SuggestionSession()
        showContinuation(" world how", in: &s)
        #expect(s.handle(.temporaryQuietStarted(bundleID: "com.test")) == [.cancelInFlight, .present(.none)])
        #expect(s.currentPresentation == .none)
        #expect(s.temporarilyQuietBundleIDs == ["com.test"])
    }

    @Test func aQuietedAppProducesNothingAtAllNotEvenACorrection() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        // Shaped like the per-app switch it shadows, not like a continuation gate: no
        // `.runInference` of either kind comes back.
        #expect(s.handleReady(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false),
                                       trigger: .typing))
                == [.logGate("temporary-quiet app=com.test"), .present(.none)])
    }

    /// Force cannot reach past it: "quiet" is the user's own statement, and force overrides only ours.
    @Test func forceActivateCannotOverrideATemporaryQuiet() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        #expect(s.handleReady(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false),
                                       trigger: .forceActivate))
                == [.logGate("temporary-quiet app=com.test"), .present(.none)])
    }

    // MARK: language off switch

    private func languageContext(_ verdict: LanguageVerdict) -> TypingContext {
        var context = endOfTextContext()
        context.languageVerdict = verdict
        return context
    }

    @Test func aSwitchedOffLanguageProducesNothing() {
        var s = SuggestionSession()
        #expect(s.handleReady(.contextReady(languageContext(.off("de")), caret: CaretFacts(hasTextToRight: false),
                                       trigger: .typing))
                == [.logGate("language-off lang=de"), .present(.none)])
    }

    @Test func forceActivateCannotOverrideASwitchedOffLanguage() {
        var s = SuggestionSession()
        #expect(s.handleReady(.contextReady(languageContext(.off("de")), caret: CaretFacts(hasTextToRight: false),
                                       trigger: .forceActivate))
                == [.logGate("language-off lang=de"), .present(.none)])
    }

    @Test func anOpenLanguageVerdictLogsAndStillRunsInference() {
        var s = SuggestionSession()
        let effects = s.handleReady(.contextReady(languageContext(.open(.unsure)), caret: CaretFacts(hasTextToRight: false),
                                             trigger: .typing))
        #expect(effects.first == .logGate("language-open reason=unsure"))
        #expect(effects.contains { if case .runInference = $0 { return true } else { return false } })
    }

    @Test func contextsDifferingOnlyInLanguageVerdictHaveEqualPredictionInputs() {
        #expect(languageContext(.off("de")).predictionInputs == languageContext(.allowed("en")).predictionInputs)
    }

    @Test func theQuietIsPerAppAndLeavesOtherSurfacesAlone() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.other"))
        let other = endOfTextContext()
        #expect(s.handleReady(.contextReady(other, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                == [.runInference(other, wantsCorrection: true, wantsContinuation: true)])
    }

    /// Decision 3c, the asymmetry: an explicit resume regenerates at the caret…
    @Test func anExplicitResumeRegeneratesImmediately() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        #expect(s.handle(.temporaryQuietEnded(bundleID: "com.test", resumedExplicitly: true))
                == [.schedulePredict(trigger: .caretMoved, debounceMs: 150)])
        #expect(s.temporarilyQuietBundleIDs.isEmpty)
    }

    /// …an EXPIRING TIMER does not. The user did nothing at that moment, may not be looking, may be in
    /// another app entirely — the next keystroke or caret move brings the ghost back.
    @Test func anExpiringTimerLiftsTheQuietWithoutShowingAnything() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        #expect(s.handle(.temporaryQuietEnded(bundleID: "com.test", resumedExplicitly: false)).isEmpty)
        #expect(s.temporarilyQuietBundleIDs.isEmpty)
        // Lifted for real: the very next typing context predicts again.
        let ctx = endOfTextContext()
        #expect(s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
                == [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)])
    }

    /// Ending a quiet nobody started is a no-op — the timer and the menu can both reach this.
    @Test func endingAQuietThatIsNotRunningDoesNothing() {
        var s = SuggestionSession()
        #expect(s.handle(.temporaryQuietEnded(bundleID: "com.test", resumedExplicitly: true)).isEmpty)
    }

    /// Quiet flips are settings, not input, so they land while paused — otherwise the reducer's set
    /// would disagree with the menu the user just used. The resume still shows nothing while paused.
    @Test func quietFlipsAreProcessedWhilePaused() {
        var s = SuggestionSession()
        _ = s.handle(.setPaused(true))
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        #expect(s.temporarilyQuietBundleIDs == ["com.test"])
        #expect(s.handle(.temporaryQuietEnded(bundleID: "com.test", resumedExplicitly: true)).isEmpty)
        #expect(s.temporarilyQuietBundleIDs.isEmpty)
    }

    // MARK: Tab grace window: Tab is taken only on a SETTLED ghost

    /// A grace-on session with an unsettled typing ghost on screen (generation 1).
    private func unsettledGhost(_ text: String) -> SuggestionSession {
        var s = SuggestionSession(tabGrace: true)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: text), nil))
        return s
    }

    @Test func aTypingGhostIsPaintedThenAsksToBeSettled() {
        var s = SuggestionSession(tabGrace: true)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
        // The settle request comes AFTER the paint: the App starts the grace clock once the overlay
        // has actually painted, which on Electron can lag the decision.
        #expect(effects == [.present(.continuation(" world how")), .scheduleSettle(generation: 1)])
    }

    @Test func tabOnAnUnsettledGhostPassesThroughAndRegeneratesLikeACaretMove() {
        var s = unsettledGhost(" world how")
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .passThrough)
        #expect(effects == [.logGate("tab-grace"), .cancelInFlight, .present(.none),
                            .schedulePredict(trigger: .caretMoved, debounceMs: 150)])
        #expect(s.currentPresentation == .none)
    }

    @Test func optionTabOnAnUnsettledGhostPassesThroughToo() {
        var s = unsettledGhost(" world how")
        let (decision, effects) = s.interceptKey(.acceptAll)
        #expect(decision == .passThrough)
        #expect(effects.first == .logGate("tab-grace"))
        #expect(s.currentPresentation == .none)
    }

    @Test func tabAfterTheSettledEventAcceptsAWord() {
        var s = unsettledGhost(" world how")
        #expect(s.handle(.ghostSettled(generation: 1)).isEmpty)
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert(" world")])
    }

    @Test func aStaleSettledEventDoesNotSettleANewerGhost() {
        var s = unsettledGhost(" world how")
        _ = s.handle(.typed("x"))   // diverges: clears and re-predicts
        _ = s.handle(.contextReady(endOfTextContext(before: "hello worldx "),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: " again there"), nil))
        #expect(effects == [.present(.continuation(" again there")), .scheduleSettle(generation: 2)])
        _ = s.handle(.ghostSettled(generation: 1))   // the first ghost's timer, fired late
        let (decision, _) = s.interceptKey(.tab)
        #expect(decision == .passThrough)
    }

    @Test func caretMoveAndForceActivateGhostsStartUnsettled() {
        for trigger in [SuggestionTrigger.caretMoved, .forceActivate] {
            var s = SuggestionSession(tabGrace: true)
            _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: trigger))
            let effects = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
            #expect(effects.last == .scheduleSettle(generation: 1))
        }
    }

    @Test func aCorrectionFromTypingStartsUnsettled() {
        var s = SuggestionSession(tabGrace: true)
        let fix = Correction(original: "teh", replacement: "the", charactersBackFromCaret: 3)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: ""), fix))
        #expect(effects == [.present(.correction(fix)), .scheduleSettle(generation: 1)])
        #expect(s.interceptKey(.tab).0 == .passThrough)
    }

    @Test func theShrunkGhostAfterAnAcceptTakesTabAtOnce() {
        var s = unsettledGhost(" world how are")
        _ = s.handle(.ghostSettled(generation: 1))
        _ = s.interceptKey(.tab)
        #expect(s.handle(.hostEcho) == [.present(.continuation(" how are"))])   // no settle request
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert(" how")])
    }

    @Test func theTypeAlongGhostTakesTabAtOnce() {
        var s = unsettledGhost(" world how")
        #expect(s.handle(.typed(" ")) == [.cancelInFlight])
        #expect(s.handle(.hostEcho) == [.present(.continuation("world how"))])   // no settle request
        let (decision, effects) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(effects == [.insert("world")])
    }

    @Test func theAcceptRefillGhostTakesTabAtOnce() {
        var s = SuggestionSession(tabGrace: true)
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .acceptRefill))
        let effects = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
        #expect(effects == [.present(.continuation(" world how"))])
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" world")]))
    }

    /// The refill after a type-along EXHAUSTION appears under the user's own keystrokes, so a `Tab` meant
    /// for the host (the next form field) can meet it. It must start unsettled like a typing ghost.
    @Test func theRefillAfterATypeAlongExhaustionStartsUnsettled() {
        var s = unsettledGhost(" world")
        #expect(s.handle(.typed(" world")) == [.cancelInFlight, .present(.none)])
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
        _ = s.handle(.contextReady(endOfTextContext(before: "hello world world"),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .acceptRefill))
        let effects = s.handle(.predictionArrived(Suggestion(text: " how are"), nil))
        #expect(effects == [.present(.continuation(" how are")), .scheduleSettle(generation: 2)])
        #expect(s.interceptKey(.tab).0 == .passThrough)
    }

    /// The control: the refill after a `Tab`-accept exhaustion follows OUR insert and stays settled.
    @Test func theRefillAfterATabAcceptExhaustionTakesTabAtOnce() {
        var s = unsettledGhost(" world")
        _ = s.handle(.ghostSettled(generation: 1))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" world"), .present(.none)]))
        #expect(s.handle(.hostEcho) == [.schedulePredict(trigger: .acceptRefill, debounceMs: 150)])
        _ = s.handle(.contextReady(endOfTextContext(before: "hello world world"),
                                   caret: CaretFacts(hasTextToRight: false), trigger: .acceptRefill))
        let effects = s.handle(.predictionArrived(Suggestion(text: " how are"), nil))
        #expect(effects == [.present(.continuation(" how are"))])
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" how")]))
    }

    @Test func aRedundancyReplayOfASettledGhostTakesTabAtOnce() {
        var s = SuggestionSession(tabGrace: true)
        let context = endOfTextContext()
        _ = s.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        _ = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
        _ = s.handle(.ghostSettled(generation: 1))
        _ = s.handle(.caretMove)
        let replay = s.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(replay == [.surfaceVerdict(.on), .present(.continuation(" world how"))])
        #expect(s.interceptKey(.tab).0 == .suppress)
    }

    @Test func aRedundancyReplayOfAnUnsettledGhostStartsANewGrace() {
        var s = SuggestionSession(tabGrace: true)
        let context = endOfTextContext()
        _ = s.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        _ = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
        _ = s.handle(.caretMove)
        let replay = s.handle(.contextReady(context, caret: CaretFacts(hasTextToRight: false), trigger: .caretMoved))
        #expect(replay == [.surfaceVerdict(.on), .present(.continuation(" world how")), .scheduleSettle(generation: 2)])
        _ = s.handle(.ghostSettled(generation: 1))
        #expect(s.interceptKey(.tab).0 == .passThrough)
    }

    @Test func aCompletionLengthReWindowTakesTabAtOnce() {
        var s = unsettledGhost(" one two three four five six")
        #expect(s.handle(.setCompletionLength(.short)) == [.present(.continuation(" one two three"))])
        #expect(s.interceptKey(.tab).0 == .suppress)
    }

    @Test func withTheGraceOffEveryGhostIsSettledAtOnce() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(endOfTextContext(), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handle(.predictionArrived(Suggestion(text: " world how"), nil))
        #expect(effects == [.present(.continuation(" world how"))])
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" world")]))
    }

    @Test func escapeOnAnUnsettledGhostIsUnchanged() {
        var s = unsettledGhost(" world")
        let (decision, effects) = s.interceptKey(.escape)
        #expect(decision == .passThrough)
        #expect(effects == [.cancelInFlight, .present(.none)])
    }

    // MARK: Emoji after a colon

    private func colonContext(_ before: String, after: String = "") -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: after, windowContext: nil, bundleID: "com.test")
    }

    @Test func colonDaumenOffersTheThumbsUpAsACorrectionAndTabReplacesTheColonWord() {
        var s = SuggestionSession()
        let effects = s.handleReady(.contextReady(colonContext("Super :daumen"), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects.contains(.present(.correction(Correction(original: ":daumen", replacement: "👍", charactersBackFromCaret: 7)))))
        #expect(!effects.contains { if case .runInference = $0 { return true } else { return false } })
        let (decision, accept) = s.interceptKey(.tab)
        #expect(decision == .suppress)
        #expect(accept == [.replace(charactersBack: 7, with: "👍")])
    }

    @Test func aTriggerWithNoMatchLogsTheGateOnceAndOffersNoGhost() {
        var s = SuggestionSession()
        let ctx = colonContext("hello world :qqxzv")
        let first = s.handleReady(.contextReady(ctx, caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(first.filter { $0 == .logGate("emoji-no-match") }.count == 1)
        #expect(!first.contains { if case .runInference = $0 { return true } else { return false } })
        // Growing the fragment cannot create a match, so the next keystrokes log nothing.
        for typed in ["hello world :qqxzvv", "hello world :qqxzvvw"] {
            let again = s.handleReady(.contextReady(colonContext(typed), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
            #expect(!again.contains(.logGate("emoji-no-match")))
        }
    }

    @Test func fazitColonNeverTouchesTheEmojiPath() {
        var s = SuggestionSession()
        let effects = s.handleReady(.contextReady(colonContext("Das ist das Fazit: "), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(!effects.contains(.logGate("emoji-no-match")))
        #expect(s.currentPresentation == .none)
    }

    @Test func noEmojiOfferWhileTheCaretIsInsideAWord() {
        var s = SuggestionSession()
        let effects = s.handleReady(.contextReady(colonContext("Super :daumen", after: "x"), caret: CaretFacts(hasTextToRight: true), trigger: .typing))
        #expect(!effects.contains { if case .present(.correction) = $0 { return true } else { return false } })
    }

    @Test func typingOnAfterAnOfferedEmojiDropsTheStaleOffer() {
        var s = SuggestionSession()
        _ = s.handle(.contextReady(colonContext("Super :daumen"), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        let effects = s.handleReady(.contextReady(colonContext("Super :daumenx"), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        #expect(effects.contains(.present(.none)))
        #expect(s.currentPresentation == .none)
    }

    // MARK: Trailing punctuation picker

    @Test func neitherHoldsBackTheSentenceEndAndTheNextTabInsertsIt() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.neither))
        showContinuation(" kalt.", in: &s)
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" kalt")]))
        // The ghost does not blink out: the period is the remainder.
        #expect(s.currentPresentation == .continuation("."))
        #expect(s.handle(.hostEcho) == [.present(.continuation("."))])
        #expect(s.interceptKey(.tab) == (.suppress, [.insert("."), .present(.none)]))
    }

    @Test func neitherHoldsBackAMidBufferCommaOnAWordPeel() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.neither))
        showContinuation(" wird es kalt, und", in: &s)
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" wird")]))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" es")]))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" kalt")]))
        #expect(s.currentPresentation == .continuation(", und"))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(",")]))
        #expect(s.currentPresentation == .continuation(" und"))
    }

    @Test func neitherAlsoHoldsBackOnAcceptAll() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.neither))
        showContinuation(" wird es kalt.", in: &s)
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert(" wird es kalt")]))
        #expect(s.currentPresentation == .continuation("."))
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert("."), .present(.none)]))
    }

    @Test func fullAcceptOnlyHoldsBackOnTabButNotOnAcceptAll() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.fullAcceptOnly))
        showContinuation(" kalt.", in: &s)
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" kalt")]))
        #expect(s.currentPresentation == .continuation("."))
        var t = SuggestionSession()
        _ = t.handle(.setTrailingPunctuation(.fullAcceptOnly))
        showContinuation(" wird kalt.", in: &t)
        #expect(t.interceptKey(.acceptAll) == (.suppress, [.insert(" wird kalt."), .present(.none)]))
    }

    @Test func bothShortcutsInsertsPunctuationWithTheWord() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.bothShortcuts))
        showContinuation(" kalt. Es", in: &s)
        #expect(s.interceptKey(.tab) == (.suppress, [.insert(" kalt.")]))
    }

    @Test func aHeldBackPeriodSurvivesAWindowChange() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.neither))
        showContinuation(" kalt.", in: &s)
        _ = s.interceptKey(.tab)
        #expect(s.handle(.setCompletionLength(.short)) == [.present(.continuation("."))])
        #expect(s.currentPresentation == .continuation("."))
    }

    @Test func aBareModelPeriodIsStillSuppressedUnderNeither() {
        var s = SuggestionSession()
        _ = s.handle(.setTrailingPunctuation(.neither))
        showContinuation(".", in: &s)
        #expect(s.currentPresentation == .none)
    }

    // MARK: Word step with the trailing punctuation picker
    //
    // At the word step both accept keys act on the shown word part only. The picker then decides
    // whether that part's trailing punctuation goes in with it or stays as the ghost.

    private func wordSession(prefix: String, trailing: TrailingPunctuation) -> SuggestionSession {
        var s = wordSession(prefix: prefix)
        _ = s.handle(.setTrailingPunctuation(trailing))
        return s
    }

    @Test func neitherAtTheWordStepHoldsBackTheShownPartsPeriodOnAcceptAll() {
        var s = wordSession(prefix: "Heute ist es ka", trailing: .neither)
        #expect(s.handle(.predictionArrived(Suggestion(text: "lt. Morgen wird es warm"), nil))
                == [.present(.continuation("lt."))])
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert("lt")]))
        #expect(s.currentPresentation == .continuation("."))
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert("."), .present(.none)]))
    }

    @Test func neitherAtTheWordStepInsertsAShownPartWithoutPunctuationWhole() {
        var s = wordSession(prefix: "Thank you for your hel", trailing: .neither)
        _ = s.handle(.predictionArrived(Suggestion(text: "lp with the project."), nil))
        #expect(s.currentPresentation == .continuation("lp"))
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert("lp"), .present(.none)]))
    }

    @Test func neitherAtTheWordStepHoldsBackOnTabAndTheNextTabInsertsIt() {
        var s = wordSession(prefix: "Heute ist es ka", trailing: .neither)
        _ = s.handle(.predictionArrived(Suggestion(text: "lt. Morgen wird es warm"), nil))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert("lt")]))
        #expect(s.currentPresentation == .continuation("."))
        #expect(s.handle(.hostEcho) == [.present(.continuation("."))])
        // The next word is not shown at the word step, so nothing follows the period.
        #expect(s.interceptKey(.tab) == (.suppress, [.insert("."), .present(.none)]))
    }

    @Test func fullAcceptOnlyAtTheWordStepHoldsBackOnTabButNotOnAcceptAll() {
        var s = wordSession(prefix: "Heute ist es ka", trailing: .fullAcceptOnly)
        _ = s.handle(.predictionArrived(Suggestion(text: "lt. Morgen wird es warm"), nil))
        #expect(s.interceptKey(.tab) == (.suppress, [.insert("lt")]))
        #expect(s.currentPresentation == .continuation("."))
        var t = wordSession(prefix: "Heute ist es ka", trailing: .fullAcceptOnly)
        _ = t.handle(.predictionArrived(Suggestion(text: "lt. Morgen wird es warm"), nil))
        #expect(t.interceptKey(.acceptAll) == (.suppress, [.insert("lt."), .present(.none)]))
    }

    @Test func bothShortcutsAtTheWordStepInsertsTheShownPartWithItsPeriod() {
        var s = wordSession(prefix: "Heute ist es ka", trailing: .bothShortcuts)
        _ = s.handle(.predictionArrived(Suggestion(text: "lt. Morgen wird es warm"), nil))
        #expect(s.interceptKey(.acceptAll) == (.suppress, [.insert("lt."), .present(.none)]))
    }

    @Test func changingThePickerWhileShowingChangesNothingOnScreen() {
        var s = SuggestionSession()
        showContinuation(" kalt.", in: &s)
        #expect(s.handle(.setTrailingPunctuation(.neither)).isEmpty)
        #expect(s.currentPresentation == .continuation(" kalt."))
    }
}

// MARK: Spelling refusal memory

@Suite struct SpellRefusalSessionTests {
    private func ctx(_ before: String) -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: "", windowContext: nil, bundleID: "com.test")
    }
    private func fix(_ o: String, _ r: String) -> Correction {
        Correction(original: o, replacement: r, charactersBackFromCaret: o.count)
    }
    private func arrive(_ s: inout SuggestionSession, _ c: Correction?, continuation: String = "") -> [Effect] {
        _ = s.handle(.contextReady(ctx("I write \(c?.original ?? "x")"), caret: CaretFacts(hasTextToRight: false), trigger: .typing))
        return s.handle(.predictionArrived(Suggestion(text: continuation), c))
    }
    private func refuse(_ s: inout SuggestionSession, _ c: Correction) -> [Effect] {
        _ = arrive(&s, c)
        return s.handle(.typed(" "))
    }

    @Test func threeRefusalsArmThenTheFourthCorrectionIsDropped() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        _ = refuse(&s, c); _ = refuse(&s, c)
        #expect(refuse(&s, c).contains(.logGate("spell-ignore-armed")))
        let effects = arrive(&s, c)
        #expect(effects.contains(.logGate("spell-ignored")))
        #expect(s.currentPresentation == .none)
    }

    @Test func twoRefusalsStillShowTheCorrection() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        _ = refuse(&s, c); _ = refuse(&s, c)
        let effects = arrive(&s, c)
        #expect(!effects.contains(.logGate("spell-ignored")))
        #expect(s.currentPresentation == .correction(c))
    }

    @Test func caseFoldedAcrossSession() {
        var s = SuggestionSession()
        for _ in 0..<3 { _ = refuse(&s, fix("Qwen", "Queen")) }
        _ = arrive(&s, fix("qwen", "queen"))
        #expect(s.currentPresentation == .none)
    }

    @Test func leftoverCorrectionForShorterPrefixIsNoRefusal() {
        var s = SuggestionSession()
        let c = fix("becuas", "because")
        for _ in 0..<3 {
            _ = arrive(&s, c)
            _ = s.handle(.typed("e")); _ = s.handle(.typed(" "))
        }
        #expect(s.spellRefusals.isIgnored("becuas") == false)
        #expect(s.spellRefusals.isIgnored("becuase") == false)
    }

    @Test func tabAndEscRecordNoRefusal() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        for _ in 0..<3 {
            _ = arrive(&s, c); _ = s.interceptKey(.tab); _ = s.handle(.typed(" "))
            _ = arrive(&s, c); _ = s.interceptKey(.escape); _ = s.handle(.typed(" "))
        }
        #expect(s.spellRefusals.isIgnored("becuase") == false)
    }

    @Test func aSecondBoundaryOnTheSameCorrectionCountsOnce() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        _ = arrive(&s, c)
        _ = s.handle(.typed(" ")); _ = s.handle(.typed(" ")); _ = s.handle(.typed(" "))
        #expect(s.spellRefusals.isIgnored("becuase") == false)
    }

    @Test func armingIsLoggedExactlyOnce() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        var armed = 0
        for _ in 0..<5 { armed += refuse(&s, c).filter { $0 == .logGate("spell-ignore-armed") }.count }
        #expect(armed == 1)
    }

    @Test func continuationArrivingWithAnIgnoredCorrectionIsStillShown() {
        var s = SuggestionSession()
        let c = fix("becuase", "because")
        for _ in 0..<3 { _ = refuse(&s, c) }
        _ = arrive(&s, c, continuation: " we agreed")
        #expect(s.currentPresentation == .continuation(" we agreed"))
    }

    @Test func otherWordsAreStillCorrected() {
        var s = SuggestionSession()
        for _ in 0..<3 { _ = refuse(&s, fix("becuase", "because")) }
        let r = fix("recieve", "receive")
        _ = arrive(&s, r)
        #expect(s.currentPresentation == .correction(r))
    }
}

extension SuggestionSession {
    /// `handle` for a `.contextReady` event, without the leading `.surfaceVerdict` effect, for
    /// the tests whose subject is the gate effects. `SurfaceVerdictTests` asserts the verdict itself.
    mutating func handleReady(_ event: Event) -> [Effect] {
        handle(event).filter { if case .surfaceVerdict = $0 { return false } else { return true } }
    }
}
