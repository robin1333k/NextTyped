import Foundation
import Testing
@testable import NextTypedCore

/// One prediction run, asserted as **external behaviour**: which adapters were called, in what order,
/// and — at least as often — which were not called at all.
///
/// The success criterion this suite is written against is narrow and literal: **a test must go red when
/// a step is moved.** Every fake therefore appends to one shared `CallLog`, and the ordering cases read
/// that log as a sentence about the loop rather than inspecting the module's shape.
@Suite("PredictRun — the async half of the loop, in order")
@MainActor
struct PredictRunTests {

    /// The opaque caret payload. `CaretInfo` is an App type holding a `CGRect`; Core is generic over it
    /// and passes it through untouched, so a test can use something it can compare with `==`.
    struct TestCaret: Equatable, Sendable { var tag: String }

    /// Every fake writes here, so ordering is one assertion instead of eight timestamps.
    ///
    /// Deliberately NOT `@MainActor`: `SpellChecker` and `PredictionEngine` are `Sendable` seams whose
    /// methods are non-isolated, so two of the fakes below record from off the main actor. A lock keeps
    /// that honest rather than pretending with `assumeIsolated`.
    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        var entries: [String] { lock.withLock { storage } }
        func note(_ what: String) { lock.withLock { storage.append(what) } }
    }

    // MARK: fakes

    final class FakeWait: PredictWaiting {
        let log: CallLog
        var waited: [Int] = []
        /// Runs inside the wait, so a test can cancel the enclosing Task during the debounce.
        var onWait: (() -> Void)?
        init(log: CallLog) { self.log = log }
        func wait(milliseconds: Int) async {
            log.note("wait")
            waited.append(milliseconds)
            onWait?()
        }
    }

    final class FakeAssembler: ContextAssembling {
        let log: CallLog
        var answer: TypingContext?
        /// What the assembler rejects with when `answer` is nil.
        var rejection: ContextRejection = .noFocus
        var calls = 0
        var onCall: (() -> Void)?
        init(log: CallLog, answer: TypingContext?) { self.log = log; self.answer = answer }
        func assembledContext() async -> ContextOutcome? {
            log.note("context")
            calls += 1
            onCall?()
            return answer.map(ContextOutcome.context) ?? .rejected(rejection)
        }
    }

    final class FakeFocus: FocusTracking {
        let log: CallLog
        var calls = 0
        init(log: CallLog) { self.log = log }
        func ensureTrackingFocusedElement() { log.note("focus"); calls += 1 }
    }

    final class FakeCaret: CaretReading {
        let log: CallLog
        var readout: CaretReadout<TestCaret>?
        var calls = 0
        var onCall: (() -> Void)?
        init(log: CallLog, readout: CaretReadout<TestCaret>?) { self.log = log; self.readout = readout }
        func readCaret() async -> CaretReadout<TestCaret>? {
            log.note("caret")
            calls += 1
            onCall?()
            return readout
        }
    }

    final class FakeReducer: SuggestionReducing {
        let log: CallLog
        /// What the reducer answers each event with — the test scripts the run's shape.
        var respond: (Event) -> [Effect] = { _ in [] }
        var events: [Event] = []
        var executed: [(effects: [Effect], caret: TestCaret?)] = []
        var notedContexts: [TypingContext] = []
        var notedTriggers: [SuggestionTrigger] = []
        init(log: CallLog) { self.log = log }
        func handle(_ event: Event) -> [Effect] {
            log.note("handle(\(Self.name(of: event)))")
            events.append(event)
            return respond(event)
        }
        func execute(_ effects: [Effect], caret: TestCaret?) {
            log.note("execute")
            executed.append((effects, caret))
        }
        func noteContextObtained(_ context: TypingContext, trigger: SuggestionTrigger) {
            log.note("skeleton")
            notedContexts.append(context)
            notedTriggers.append(trigger)
        }
        static func name(of event: Event) -> String {
            switch event {
            case .contextReady: return "contextReady"
            case .predictionArrived: return "predictionArrived"
            case .firstWordsArrived: return "firstWordsArrived"
            default: return "other"
            }
        }
    }

    final class FakeSpellChecker: SpellChecker, @unchecked Sendable {
        let log: CallLog
        var answer: Correction?
        /// When true the fake answers `.typoSuspected(answer)` instead of `.clean(answer)`.
        var typoSuspected = false
        var calls = 0
        var queried: [TypingContext] { lock.withLock { queriedStorage } }
        private let lock = NSLock()
        private var queriedStorage: [TypingContext] = []
        /// Runs inside the spell check — off the main actor, hence the `@Sendable` hook.
        var onCall: (@Sendable () -> Void)?
        init(log: CallLog, answer: Correction? = nil) { self.log = log; self.answer = answer }
        func verdict(for context: TypingContext) async -> SpellVerdict {
            log.note("spell")
            lock.withLock { queriedStorage.append(context) }
            calls += 1
            onCall?()
            return typoSuspected ? .typoSuspected(answer) : .clean(answer)
        }
    }

    final class FakeEngine: PredictionEngine, @unchecked Sendable {
        let log: CallLog
        var answer: Suggestion
        var calls = 0
        var queried: [TypingContext] { lock.withLock { queriedStorage } }
        private let lock = NSLock()
        private var queriedStorage: [TypingContext] = []
        init(log: CallLog, answer: Suggestion = Suggestion(text: " weiter")) {
            self.log = log
            self.answer = answer
        }
        /// Runs inside the predict — off the main actor.
        var onCall: (@Sendable () -> Void)?
        /// When set, the engine throws instead of answering (a cancelled or failed inference).
        var failure: Error?
        func predict(for context: TypingContext) async throws -> Suggestion {
            log.note("predict")
            lock.withLock { queriedStorage.append(context) }
            calls += 1
            onCall?()
            if let failure { throw failure }
            return answer
        }
        /// When set, the engine hands these words out before it answers (first-paint streaming).
        var firstWords: Suggestion?
        /// Runs after the first words were handed out, before the engine answers.
        var afterFirstWords: (@Sendable () -> Void)?
        func predict(for context: TypingContext,
                     firstWords sink: @escaping @Sendable (Suggestion) -> Void) async throws -> Suggestion {
            if let firstWords {
                log.note("first-words")
                sink(firstWords)
                afterFirstWords?()
            }
            return try await predict(for: context)
        }
    }

    final class FakeActivity: PredictActivityRecording {
        let log: CallLog
        var recorded: [PredictActivity] = []
        init(log: CallLog) { self.log = log }
        func recordPredict(_ activity: PredictActivity) {
            log.note("activity")
            recorded.append(activity)
        }
    }

    // MARK: assembly

    /// Everything a run needs, held together so a test can reach into any one fake.
    @MainActor struct Fixture {
        let log = CallLog()
        let wait: FakeWait
        let assembler: FakeAssembler
        let focus: FakeFocus
        let caret: FakeCaret
        let reducer: FakeReducer
        let spellChecker: FakeSpellChecker
        let engine: FakeEngine
        let activity: FakeActivity
        let run: PredictRun<TestCaret>

        init(context: TypingContext? = TypingContext(textBeforeCaret: "Der Zug", bundleID: "com.apple.TextEdit"),
             caretReadout: CaretReadout<TestCaret>? = CaretReadout(caret: TestCaret(tag: "read-by-this-run"),
                                                                  facts: CaretFacts(hasTextToRight: false))) {
            let log = self.log
            wait = FakeWait(log: log)
            assembler = FakeAssembler(log: log, answer: context)
            focus = FakeFocus(log: log)
            caret = FakeCaret(log: log, readout: caretReadout)
            reducer = FakeReducer(log: log)
            spellChecker = FakeSpellChecker(log: log)
            engine = FakeEngine(log: log)
            activity = FakeActivity(log: log)
            run = PredictRun(
                wait: wait, context: assembler, focus: focus, caret: caret,
                reducer: reducer, spellChecker: spellChecker, engine: engine, activity: activity
            )
        }

        /// The everyday shape: phase 1 asks for inference on both halves.
        func predictingRun(wantsCorrection: Bool = true, wantsContinuation: Bool = true) {
            let ctx = assembler.answer
            reducer.respond = { event in
                if case .contextReady = event, let ctx {
                    return [.runInference(ctx, wantsCorrection: wantsCorrection,
                                          wantsContinuation: wantsContinuation)]
                }
                return []
            }
        }
    }

    // MARK: ordering

    @Test("The caret is read only after the context adapter has answered")
    func caretFollowsTheContextRead() async throws {
        let fixture = Fixture()
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        let order = fixture.log.entries
        let context = try #require(order.firstIndex(of: "context"))
        let caret = try #require(order.firstIndex(of: "caret"))
        #expect(context < caret)
    }

    @Test("The steps run in one order, and it is the loop's order")
    func theWholeRunInOrder() async {
        let fixture = Fixture()
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The whole sentence, so that moving ANY step — not just the caret read — is a failure with a
        // readable diff. Two `execute`s: phase 1's settled batch (empty here) and phase 2's.
        #expect(fixture.log.entries == [
            "wait", "context", "focus", "caret", "skeleton",
            "handle(contextReady)", "execute",
            "spell", "predict", "activity",
            "handle(predictionArrived)", "execute",
        ])
    }

    @Test("The debounce the reducer decided is the debounce that is waited")
    func debounceIsPassedThrough() async {
        let fixture = Fixture()

        await fixture.run.run(trigger: .caretMoved, debounceMs: 250)

        // The duration stays reducer policy (`SuggestionSession.debounceMs(for:)`); the run only waits it.
        #expect(fixture.wait.waited == [250])
    }

    // MARK: no context

    @Test("No usable context: focus tracking is not registered and the caret is never read")
    func noContextSkipsFocusAndCaret() async {
        let fixture = Fixture(context: nil)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The context read is the proof that a focused editable element exists. Without it there is
        // nothing to register against, and caret geometry has no consumer.
        #expect(fixture.focus.calls == 0)
        #expect(fixture.caret.calls == 0)
        // The reducer still hears about it — that is the cannot-predict clear.
        #expect(fixture.reducer.events == [.contextReady(nil, caret: nil, trigger: .typing, rejection: .noFocus)])
        // ...but the `[skeleton]` line is suppressed, exactly as the App suppresses it. This is the one
        // observable harness scenarios assert on, and a no-op default on the port is how it would be
        // silently dropped instead.
        #expect(fixture.reducer.notedContexts.isEmpty)
        #expect(fixture.spellChecker.calls == 0)
        #expect(fixture.engine.calls == 0)
        #expect(fixture.activity.recorded.isEmpty)
    }

    @Test("A context obtained registers focus tracking, exactly once")
    func contextObtainedRegistersFocusTracking() async {
        let fixture = Fixture()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.focus.calls == 1)
    }

    @Test("A surface with no caret geometry reaches the reducer as nil facts, not as no context")
    func missingCaretGeometryStillReachesTheReducer() async {
        let fixture = Fixture(caretReadout: nil)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // `caret == nil` means AX exposed no geometry; the proactive gate reads that as "text to the
        // right". It must not be confused with "no context", which is a different event payload.
        guard case .contextReady(let context, let facts, _, _)? = fixture.reducer.events.first else {
            Issue.record("expected a contextReady event"); return
        }
        #expect(context != nil)
        #expect(facts == nil)
    }

    // MARK: the caret pass-through

    @Test("The caret handed to the effect execution is the value the adapter returned")
    func caretIsPassedThroughUntouched() async {
        let readout = CaretReadout(caret: TestCaret(tag: "read-at-t0"),
                                   facts: CaretFacts(hasTextToRight: true))
        let fixture = Fixture(caretReadout: readout)
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The ghost is painted at the caret THIS predict read — the guarantee that already cost a bug
        // (the lone `"s"` over `reducer=none`). Both executions carry it, phase 1's included.
        #expect(fixture.reducer.executed.count == 2)
        #expect(fixture.reducer.executed.allSatisfy { $0.caret == TestCaret(tag: "read-at-t0") })
        // ...and the facts the gates saw came from the same read.
        guard case .contextReady(_, let facts, _, _)? = fixture.reducer.events.first else {
            Issue.record("expected a contextReady event"); return
        }
        #expect(facts == CaretFacts(hasTextToRight: true))
    }

    @Test("A run with no caret hands nil through to the paint rather than inventing one")
    func noCaretIsPassedThroughAsNil() async {
        let fixture = Fixture(caretReadout: nil)
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The count is not decoration: `allSatisfy` over an empty array is vacuously true, so without it
        // a run that returned early and executed nothing would pass this case.
        #expect(fixture.reducer.executed.count == 2)
        #expect(fixture.reducer.executed.allSatisfy { $0.caret == nil })
    }

    // MARK: phase 1

    @Test("Phase 1's settled effects are executed as one batch, with `.runInference` removed")
    func phase1SettledEffectsAreExecutedAsABatch() async {
        let fixture = Fixture()
        let ctx = fixture.assembler.answer!
        fixture.reducer.respond = { event in
            if case .contextReady = event {
                return [.logGate("running-thought absent"),
                        .runInference(ctx, wantsCorrection: true, wantsContinuation: true),
                        .present(.none)]
            }
            return []
        }

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // `.runInference` is the one effect the interpreter cannot execute standalone — it continues on
        // this Task. Everything else keeps its list order, which is a guarantee.
        #expect(fixture.reducer.executed.first?.effects == [.logGate("running-thought absent"), .present(.none)])
    }

    @Test("Phase 1 that asks for no inference ends the run there")
    func settledPhase1EndsTheRun() async {
        let fixture = Fixture()
        fixture.reducer.respond = { _ in [.present(.none)] }

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.reducer.executed.count == 1)
        #expect(fixture.spellChecker.calls == 0)
        #expect(fixture.engine.calls == 0)
        #expect(fixture.activity.recorded.isEmpty)
        #expect(fixture.reducer.events.count == 1)
    }

    // MARK: the gated path

    @Test("A gated run spell-checks, does not predict, and fires NO activity signal")
    func gatedRunCorrectsWithoutPredicting() async {
        let fixture = Fixture()
        fixture.spellChecker.answer = Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7)
        fixture.predictingRun(wantsCorrection: true, wantsContinuation: false)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The cold-start gates are CONTINUATION gates: refusing a continuation must not refuse the spell
        // fix, or the first word of every line sits permanently outside it.
        #expect(fixture.spellChecker.calls == 1)
        #expect(fixture.engine.calls == 0)
        // ...and no predict happened, so nothing may keep the model warm or refresh the OCR
        // cadence. This is the assertion that makes that skip a rule rather than a comment.
        #expect(fixture.activity.recorded.isEmpty)
        // The correction still resolves through the one presentation path, carried by an empty suggestion.
        #expect(fixture.reducer.events.last == .predictionArrived(
            Suggestion(text: ""), Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7)))
    }

    @Test("A caret-move run skips the spell check but still predicts")
    func correctionOnlyWhenAsked() async {
        let fixture = Fixture()
        fixture.predictingRun(wantsCorrection: false, wantsContinuation: true)

        await fixture.run.run(trigger: .caretMoved, debounceMs: 80)

        // Corrections are typing-driven by construction.
        #expect(fixture.spellChecker.calls == 0)
        #expect(fixture.engine.calls == 1)
        #expect(fixture.reducer.events.last == .predictionArrived(Suggestion(text: " weiter"), nil))
    }

    // MARK: the activity signal

    @Test("A real predict fires the activity signal once, carrying what both consumers count")
    func realPredictFiresTheActivitySignal() async {
        let fixture = Fixture(context: TypingContext(textBeforeCaret: "Der Zug faehrt",
                                                     bundleID: "com.apple.TextEdit"))
        fixture.engine.answer = Suggestion(text: " nach Hause")
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // One sink, not two: the residency warm-state signal, the OCR cadence signal and the harness
        // counters are the same statement, so they cannot drift apart.
        #expect(fixture.activity.recorded.count == 1)
        let activity = fixture.activity.recorded[0]
        #expect(activity.app == "com.apple.TextEdit")
        #expect(activity.suggestionText == " nach Hause")
        #expect(activity.trigger == .typing)
        #expect(activity.prefixLength == 14)
    }

    @Test("The activity signal fires before the reducer is told the prediction arrived")
    func activityPrecedesTheReEntry() async {
        let fixture = Fixture()
        fixture.predictingRun()

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        let order = fixture.log.entries
        #expect(order.firstIndex(of: "activity")! < order.lastIndex(of: "handle(predictionArrived)")!)
    }

    @Test("An engine that throws still re-enters the reducer, with an empty suggestion")
    func failedInferenceStillSettles() async {
        struct Boom: Error {}
        let fixture = Fixture()
        fixture.engine.failure = Boom()
        fixture.predictingRun(wantsCorrection: false, wantsContinuation: true)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // Verbatim from the App: `(try? await predict(...)) ?? Suggestion(text: "")` — a failed predict
        // must still settle the presentation, or a ghost from the previous run stays on screen.
        #expect(fixture.reducer.events.last == .predictionArrived(Suggestion(text: ""), nil))
    }

    // MARK: first-paint streaming

    @Test("The first words reach the reducer and are painted before the full decode")
    func firstWordsArePaintedBeforeTheFullDecode() async {
        let fixture = Fixture()
        fixture.predictingRun()
        fixture.engine.firstWords = Suggestion(text: " Ich freue")
        fixture.engine.answer = Suggestion(text: " Ich freue mich auf")

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The decode runs in a child task, so the engine's own "predict" entry may land before or
        // after the reducer handles the first words. The run guarantees only the order below.
        let entries = fixture.log.entries
        #expect(entries.filter { $0 != "predict" } == [
            "wait", "context", "focus", "caret", "skeleton",
            "handle(contextReady)", "execute",
            "spell", "first-words",
            "handle(firstWordsArrived)", "execute",
            "activity",
            "handle(predictionArrived)", "execute",
        ])
        #expect(entries.firstIndex(of: "first-words")! < entries.firstIndex(of: "predict")!)
        #expect(entries.firstIndex(of: "predict")! < entries.firstIndex(of: "activity")!)
        #expect(fixture.reducer.events.dropFirst().first == .firstWordsArrived(Suggestion(text: " Ich freue"), nil))
        #expect(fixture.reducer.events.last == .predictionArrived(Suggestion(text: " Ich freue mich auf"), nil))
        // One predict ran, so one activity signal, carrying the full decode.
        #expect(fixture.activity.recorded.map(\.suggestionText) == [" Ich freue mich auf"])
    }

    @Test("The first words carry the spell correction the run already has")
    func firstWordsCarryTheCorrection() async {
        let fixture = Fixture()
        fixture.predictingRun()
        let fix = Correction(original: "Zgu", replacement: "Zug", charactersBackFromCaret: 3)
        fixture.spellChecker.answer = fix
        fixture.engine.firstWords = Suggestion(text: " Ich freue")

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.reducer.events.dropFirst().first == .firstWordsArrived(Suggestion(text: " Ich freue"), fix))
    }

    @Test("After an early paint the full decode executes with no caret, so the App reads it again")
    func theFullDecodeAfterAnEarlyPaintRereadsTheCaret() async {
        let fixture = Fixture()
        fixture.predictingRun()
        let ctx = fixture.assembler.answer!
        fixture.reducer.respond = { event in
            switch event {
            case .contextReady: return [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)]
            case .firstWordsArrived: return [.present(.continuation(" Ich freue"))]
            case .predictionArrived: return [.present(.continuation(" mich auf"))]
            default: return []
            }
        }
        fixture.engine.firstWords = Suggestion(text: " Ich freue")
        fixture.engine.answer = Suggestion(text: " Ich freue mich auf")

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        // The early paint still lands at the caret this run read; the user may Tab or type along on
        // it before the full decode, so that caret is stale for the final batch.
        #expect(fixture.reducer.executed.map(\.caret) == [
            TestCaret(tag: "read-by-this-run"),
            TestCaret(tag: "read-by-this-run"),
            nil,
        ])
    }

    @Test("A held early paint keeps the caret this run read for the full decode")
    func theFullDecodeAfterAHeldEarlyPaintKeepsTheCaret() async {
        let fixture = Fixture()
        fixture.predictingRun()
        let ctx = fixture.assembler.answer!
        fixture.reducer.respond = { event in
            switch event {
            case .contextReady: return [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)]
            case .firstWordsArrived: return [.logGate("first-paint held")]
            default: return []
            }
        }
        fixture.engine.firstWords = Suggestion(text: " Ich freue")

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.reducer.executed.last?.caret == TestCaret(tag: "read-by-this-run"))
    }

    @Test("Cancelled after the first words: no full decode reaches the reducer and no activity fires")
    func cancelledAfterTheFirstWordsDropsTheFullDecode() async {
        let fixture = Fixture()
        let box = PredictRunSendableTaskBox()
        fixture.predictingRun()
        fixture.engine.firstWords = Suggestion(text: " Ich freue")
        fixture.engine.onCall = { box.cancel() }

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        #expect(!fixture.reducer.events.contains { if case .predictionArrived = $0 { return true }; return false })
        #expect(fixture.activity.recorded.isEmpty)
    }

    // MARK: cancellation — every early return is a case

    @Test("Cancelled during the debounce: the context is never read")
    func cancelledDuringDebounceReadsNoContext() async {
        let fixture = Fixture()
        // The Task inherits this actor, so it cannot begin before this synchronous region suspends —
        // cancelling here is deterministic, not a race against a real sleep. That determinism is the
        // whole reason the wait is injected.
        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        task.cancel()
        await task.value

        #expect(fixture.assembler.calls == 0)
        #expect(fixture.reducer.events.isEmpty)
    }

    @Test("Cancelled during the context read: the caret is never read and the reducer never hears")
    func cancelledDuringContextReadStopsBeforeTheCaret() async {
        let fixture = Fixture()
        let box = PredictRunTaskBox()
        fixture.assembler.onCall = { box.task?.cancel() }

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        #expect(fixture.caret.calls == 0)
        #expect(fixture.reducer.events.isEmpty)
        // Focus tracking is downstream of the check too: a superseded run must not register anything.
        #expect(fixture.focus.calls == 0)
    }

    @Test("Cancelled during the caret read: the reducer is never entered")
    func cancelledDuringCaretReadStopsBeforePhase1() async {
        let fixture = Fixture()
        let box = PredictRunTaskBox()
        fixture.caret.onCall = { box.task?.cancel() }

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        #expect(fixture.reducer.events.isEmpty)
        #expect(fixture.engine.calls == 0)
    }

    @Test("Cancelled during phase 1: the prediction engine is never called")
    func cancelledDuringPhase1LeavesTheEngineUncalled() async {
        let fixture = Fixture()
        let ctx = fixture.assembler.answer!
        let box = PredictRunTaskBox()
        fixture.reducer.respond = { event in
            if case .contextReady = event {
                box.task?.cancel()
                return [.runInference(ctx, wantsCorrection: true, wantsContinuation: true)]
            }
            return []
        }

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        // The phase-1 batch still executed — it was decided before the cancel. What must not happen is
        // paying for inference on a superseded run.
        #expect(fixture.spellChecker.calls == 0)
        #expect(fixture.engine.calls == 0)
        #expect(fixture.activity.recorded.isEmpty)
    }

    @Test("Cancelled during the spell check: the prediction engine is never called")
    func cancelledDuringSpellCheckLeavesTheEngineUncalled() async {
        let fixture = Fixture()
        let box = PredictRunSendableTaskBox()
        fixture.spellChecker.onCall = { box.cancel() }
        fixture.predictingRun()

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        #expect(fixture.spellChecker.calls == 1)
        #expect(fixture.engine.calls == 0)
        #expect(fixture.activity.recorded.isEmpty)
        #expect(fixture.reducer.events.count == 1)
    }

    @Test("Cancelled during the predict: no activity signal and no stale suggestion")
    func cancelledDuringPredictFiresNoActivity() async {
        let fixture = Fixture()
        let box = PredictRunSendableTaskBox()
        fixture.engine.onCall = { box.cancel() }
        fixture.predictingRun()

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        // A superseded run must neither reset the residency idle clock nor dispatch a stale
        // `.predictionArrived` — the reducer needs no stale-guard precisely because of this check.
        #expect(fixture.activity.recorded.isEmpty)
        #expect(fixture.reducer.events.count == 1)
    }

    @Test("A context obtained is announced once, with this run's trigger, before phase 1")
    func contextObtainedIsAnnouncedBeforePhase1() async {
        let fixture = Fixture(context: TypingContext(textBeforeCaret: "Der Zug", bundleID: "com.apple.TextEdit"))

        await fixture.run.run(trigger: .caretMoved, debounceMs: 80)

        #expect(fixture.reducer.notedContexts.count == 1)
        #expect(fixture.reducer.notedContexts.first?.textBeforeCaret == "Der Zug")
        #expect(fixture.reducer.notedTriggers == [.caretMoved])
        let order = fixture.log.entries
        #expect(order.firstIndex(of: "skeleton")! < order.firstIndex(of: "handle(contextReady)")!)
    }

    @Test("The trigger the run was started with is the trigger the reducer is gated on")
    func triggerReachesTheReducer() async {
        let fixture = Fixture()

        await fixture.run.run(trigger: .caretMoved, debounceMs: 80)

        guard case .contextReady(_, _, let trigger, _)? = fixture.reducer.events.first else {
            Issue.record("expected a contextReady event"); return
        }
        #expect(trigger == .caretMoved)
    }

    @Test("Inference runs against the context the reducer put on `.runInference`, not the assembled one")
    func inferenceUsesTheContextTheReducerHandedBack() async {
        // They are the same object in production today, but the reducer OWNS which context inference
        // runs against (it is the one that passed the gates), and substituting the assembled context here
        // would be invisible if every test handed back the same value.
        let fixture = Fixture()
        let gated = TypingContext(textBeforeCaret: "the gated prefix", bundleID: "com.apple.Safari")
        fixture.reducer.respond = { event in
            if case .contextReady = event {
                return [.runInference(gated, wantsCorrection: true, wantsContinuation: true)]
            }
            return []
        }

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.spellChecker.queried.map(\.bundleID) == ["com.apple.Safari"])
        #expect(fixture.engine.queried.map(\.bundleID) == ["com.apple.Safari"])
        // ...and the activity signal reports the surface the predict actually ran on.
        #expect(fixture.activity.recorded.first?.app == "com.apple.Safari")
        #expect(fixture.activity.recorded.first?.prefixLength == 16)
    }

    @Test("Cancelled inside the debounce itself: the context is never read")
    func cancelledInsideTheWaitReadsNoContext() async {
        // The sibling case above cancels before the body starts. This one cancels while the run is
        // *suspended in the wait*, which is the state a real supersede arrives in — and it is only
        // expressible because the wait is injected. Against a real `Task.sleep` this would be a race.
        let fixture = Fixture()
        let box = PredictRunTaskBox()
        fixture.wait.onWait = { box.task?.cancel() }

        let task = Task { await fixture.run.run(trigger: .typing, debounceMs: 80) }
        box.task = task
        await task.value

        #expect(fixture.assembler.calls == 0)
        #expect(fixture.reducer.events.isEmpty)
    }
}

/// Lets a fake cancel the very Task it is running inside: the handle exists only after `Task { … }`
/// returns, and a main-actor-inheriting body cannot start before then, so the assignment always wins.
@MainActor
final class PredictRunTaskBox {
    var task: Task<Void, Never>?
}

/// The same, for the two fakes whose seams are non-isolated (`SpellChecker`, `PredictionEngine`) and
/// therefore record from off the main actor.
final class PredictRunSendableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Task<Void, Never>?
    var task: Task<Void, Never>? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    func cancel() { task?.cancel() }
}

// MARK: typo suspected

extension PredictRunTests {
    @Test("A suspected typo skips the engine, records no activity and re-enters as typoSuspected")
    func typoSuspectedSkipsTheEngine() async {
        let fixture = Fixture()
        let fix = Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7)
        fixture.spellChecker.answer = fix
        fixture.spellChecker.typoSuspected = true
        fixture.predictingRun(wantsCorrection: true, wantsContinuation: true)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.spellChecker.calls == 1)
        #expect(fixture.engine.calls == 0)
        #expect(fixture.activity.recorded.isEmpty)
        #expect(fixture.reducer.events.last == .typoSuspected(fix))
    }

    @Test("A clean verdict with a correction still predicts")
    func cleanVerdictStillPredicts() async {
        let fixture = Fixture()
        fixture.spellChecker.answer = Correction(original: "Sommerferienpl", replacement: "Sommerferien", charactersBackFromCaret: 14)
        fixture.predictingRun(wantsCorrection: true, wantsContinuation: true)

        await fixture.run.run(trigger: .typing, debounceMs: 80)

        #expect(fixture.engine.calls == 1)
        #expect(fixture.activity.recorded.count == 1)
    }
}
