/// The adapters one prediction run reaches the outside world through.
///
/// Three of the run's dependencies already existed as Core seams — `ContextProvider` behind
/// `ContextAssembling`, `SpellChecker` and `PredictionEngine`
/// . The five below are the new ones, and they are deliberately narrow: each is the smallest
/// statement the run has to make to the App, so a fake is a handful of lines and an assertion about the
/// loop is an assertion about a call.

import Foundation

// MARK: - Waiting (the debounce)

/// The debounce, injected.
///
/// The *duration* stays reducer policy (`SuggestionSession.debounceMs(for:)`) and arrives as
/// `.schedulePredict(trigger:debounceMs:)`; what this seam abstracts is only the **waiting**. It exists
/// so "cancelled during the debounce ⇒ no context read" is a precise assertion rather than a race
/// against a real 80 ms sleep — a test that really sleeps is a test someone eventually deletes.
///
/// Deliberately *not* a "has enough quiet time passed?" predicate: the debounce is **sleep-then-cancel**
/// (`aa13e4e`), and a predicate here would quietly revive the shape that commit removed.
@MainActor
public protocol PredictWaiting {
    /// Suspend for `milliseconds`. Implementations must be cancellable — the run's `Task.isCancelled`
    /// check immediately after is what turns a superseded debounce into a dropped run.
    func wait(milliseconds: Int) async
}

// MARK: - The caret (generic, passed through untouched)

/// What one caret read yields: the Core-typed facts the gates need, plus the **opaque** caret value the
/// run hands back to the paint.
///
/// `CaretInfo` is an App type holding a `CGRect`, so Core must not know it — but the ghost has to be
/// painted at the caret *this* predict read, a guarantee that has already cost a bug (the lone `"s"`
/// painted over `reducer=none`). Hence the pass-through: Core never inspects `caret`, it only carries it
/// from the read to the effect execution.
public struct CaretReadout<Caret> {
    /// The App's own caret value. Core treats it as opaque.
    public var caret: Caret
    /// The `Bool`/`Double` facts the gates key on (no AX type crosses the seam).
    public var facts: CaretFacts

    public init(caret: Caret, facts: CaretFacts) {
        self.caret = caret
        self.facts = facts
    }
}

/// Reads the caret for this run. Answers `nil` when AX exposes no caret geometry — which the reducer
/// reads as "text to the right" via a `nil` `CaretFacts` (see `Event.contextReady`).
@MainActor
public protocol CaretReading<Caret> {
    associatedtype Caret
    func readCaret() async -> CaretReadout<Caret>?
}

// MARK: - Focus tracking

/// The one call that must follow a **successful** context read.
///
/// A context is proof that a focused editable element exists; registering its selection-changed
/// notification (the `hostEcho` source) before that proof would register against whatever AX last
/// answered. A window that appeared after the app switch would otherwise never deliver the echo — the
/// -25204 observer-registration race.
@MainActor
public protocol FocusTracking {
    func ensureTrackingFocusedElement()
}

// MARK: - The reducer port

/// The run's door to `SuggestionSession`, which is **not** reopened here: an event goes in,
/// effects come back, and the run hands effects back to be executed.
///
/// It is a port rather than a direct dependency because the App does three things at this boundary that
/// Core has no business doing — the harness sequence counter (`bumpSeq`), the DEBUG `[session]` event log
/// and the batch-ordering walk of `interpret(_:caret:)`, where a later `.present` cancels an earlier
/// queued paint (`7fb08ac`). All three ride this seam.
@MainActor
public protocol SuggestionReducing<Caret> {
    associatedtype Caret

    /// Hand the reducer an event and receive its effects, bumping the harness sequence counter as the
    /// App does around every `session.handle`.
    ///
    /// Deliberately **not** "and log, like `AppCoordinator.dispatch`": the predict path calls
    /// `session.handle` *directly* and bypasses `dispatch`, so a running build emits **no** `[session]`
    /// line for `.contextReady` or `.predictionArrived`. An implementation that adds one is adding three
    /// DEBUG lines per predict — possibly worth doing, never worth doing by accident.
    func handle(_ event: Event) -> [Effect]

    /// Execute a batch of effects, carrying the caret **this run** read so a freshly-decided ghost is
    /// painted where the predict looked. Order within the batch is a guarantee, which is why
    /// the run hands over a list rather than calling once per effect.
    func execute(_ effects: [Effect], caret: Caret?)

    /// DEBUG observability at the phase boundary — the App's `[skeleton]` line, which harness scenarios
    /// assert on.
    ///
    /// Two shapes here are load-bearing. The parameter is **non-optional** and the run calls this only
    /// when a context was obtained, because that is the App's rule (`if let context { acLog("[skeleton]"…) }`)
    /// and a port taking an optional would let the rule quietly become the adapter's business. And there
    /// is deliberately **no default implementation**: a no-op default is how an observable that harness
    /// scenarios assert on gets silently dropped by an adapter that simply omits the method.
    func noteContextObtained(_ context: TypingContext, trigger: SuggestionTrigger)
}

// MARK: - Activity (one sink, not two)

/// What a **real** predict just did. One value because the four consumers are one statement.
public struct PredictActivity: Equatable, Sendable {
    /// The bundle ID of the app the predict ran into, the warm-state signal for model residency.
    public var app: String?
    /// The suggestion's text, for the harness snapshot's last-suggestion field.
    public var suggestionText: String
    /// How long the engine took, in milliseconds (harness snapshot).
    public var elapsedMs: Double
    /// Which trigger started the run (harness snapshot).
    public var trigger: SuggestionTrigger
    /// Characters before the caret at the surface the predict ran on (harness snapshot's last surface).
    public var prefixLength: Int

    public init(app: String?, suggestionText: String, elapsedMs: Double,
                trigger: SuggestionTrigger, prefixLength: Int) {
        self.app = app
        self.suggestionText = suggestionText
        self.elapsedMs = elapsedMs
        self.trigger = trigger
        self.prefixLength = prefixLength
    }
}

/// The single post-predict signal, which the App fans out.
///
/// **One sink, not two.** The rule worth protecting is not that the residency and OCR-cadence
///  signals exist, but that they fire **together and only after a real predict** — never on the
/// gated path, where the spell check ran and the model did not. Two adapters are two
/// half-rules; one call makes the rule structural, and a test can assert its absence.
///
/// The DEBUG harness counters ride the same call on purpose: `predicts` in a harness snapshot and
/// "prediction-relevant activity" for model residency are the same statement, and one source is what stops them
/// drifting.
@MainActor
public protocol PredictActivityRecording {
    func recordPredict(_ activity: PredictActivity)
}
