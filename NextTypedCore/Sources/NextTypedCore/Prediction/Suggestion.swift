/// A pending inline continuation suggestion — the ghost text rendered after the caret.
public struct Suggestion: Equatable, Sendable {
    /// The full remaining suggested text, e.g. " world how are you".
    /// A single leading space is significant: it's the gap before the next word.
    public var text: String

    /// The model's **raw decode** carried a newline in its leading boundary run — its own
    /// structural-break signal, which `ClauseStop.trimToWords` flattens to a space before `text` is
    /// built. One Bool rather than a second text field: nothing new must be threaded
    /// through the buffer, the display window and the accept path, and `RunningThoughtGate` arm 2 in
    /// `SuggestionSession.handlePredictionArrived` is the only reader.
    ///
    /// **Set by `MLXPredictionEngine` on both predict paths** — the forward continuation off its raw
    /// decode, the FIM bridge off its raw middle, each read before the shaping that flattens the run
    /// (both arms apply to a bridge). This doc comment used to say the
    /// FIM path was "unchanged", which stated the default as *unchangedness* rather than as a verdict —
    /// and that is exactly what made a later reader take an unmeasured `false` for a settled decision.
    ///
    /// The default remains `false` for the many **non-prediction** constructions — every peel
    /// (`WordTokenizer`), every type-along (`SmartAdvance`) and every test fixture rebuilds a remainder
    /// whose decode was already judged once. A predict path that produced no text returns
    /// `Suggestion.empty`, so an empty result is never a claim about a decode either.
    public var abandonsRunningThought: Bool

    /// Accepting this continuation must **consume the space immediately before the caret** — the
    /// `Winter ` + `". Es wird kalt"` configuration.
    /// Decided by `BoundaryLeadJoin` in `SuggestionSession`, honoured in exactly two places: the
    /// ghost is painted one space-width further left (so the preview shows what `Tab` will produce,
    /// not `Winter. Es`), and the **first** accept writes `.replace(charactersBack: 1, …)` instead
    /// of `.insert`.
    ///
    /// It is a property of the *first* accept only, and that is structural rather than enforced:
    /// every peel (`WordTokenizer`) and every type-along (`SmartAdvance`) rebuilds the remainder
    /// through `Suggestion(text:)`, whose default is `false`. So the continuation-is-insert-only
    /// invariant is broken for one edit and restored by construction.
    public var consumesPrecedingSpace: Bool

    /// This remainder is punctuation the trailing punctuation picker held back from the last accept
    /// , so `SuggestionValueGate` lets a punctuation-only `text` through. Set only by
    /// `AcceptanceStateMachine` when it peels; every other construction leaves it `false`, so a bare
    /// `"."` from the model is still suppressed.
    public var heldBackPunctuation: Bool

    public init(text: String,
                abandonsRunningThought: Bool = false,
                consumesPrecedingSpace: Bool = false,
                heldBackPunctuation: Bool = false) {
        self.heldBackPunctuation = heldBackPunctuation
        self.text = text
        self.abandonsRunningThought = abandonsRunningThought
        self.consumesPrecedingSpace = consumesPrecedingSpace
    }

    public var isEmpty: Bool { text.isEmpty }

    /// "This predict produced nothing to show." Named rather than spelled `Suggestion(text: "")` at
    /// each of the engine's early returns: those sites make no claim about a
    /// decode — several of them never reached one — and reading the arm-2 flag off them would be
    /// reading a default. Everything that *did* decode passes the flag explicitly.
    public static let empty = Suggestion(text: "")
}
