/// Whether the **FIM model** may be loaded, as two verdicts of different *lifetimes*.
///
/// The engine used to carry one sticky `fimLoadFailed` Bool with two writers — the FIM container
/// load's `catch` and the sentinel-missing branch of the FIM predict — and nothing in the codebase
/// ever cleared it. So one badly timed moment (offline, asleep, low disk, a Hub 5xx) disabled
/// mid-text bridging for the rest of the process lifetime, recoverable only by a relaunch the user
/// has no reason to perform. Because the FIM path deliberately has **no status surface of its own**
/// (see `MLXPredictionEngine.loadedFIMContainer`'s doc comment: the menu-bar status and its Retry
/// mean the *base* model), a dead FIM model looked exactly like a caret that simply did not route to
/// FIM. That is a fail-closed latch, correct about the failure it saw
/// and wrong about how long that failure lasts.
///
/// The fix is to stop one flag standing for two answers:
///
///   - **Retryable** — *this load attempt* failed. It suppresses further attempts, so a failing load
///     is not retried per keystroke, and it is cleared at the Tier-2 unload
///     (`clearRetryableLoadFailure()`), the boundary that already releases both containers on a
///     strong away-signal. Rationale for that boundary over a menu-bar Retry, a timer, or nothing
///     is that it is a *meaningful* boundary, not merely a convenient one — the machine
///     idled, which is when a transient cause has most likely resolved.
///   - **Final** — *this model* lacks the FIM sentinels in its vocabulary and can never bridge. A
///     vocabulary does not grow, so the verdict is final: re-deriving it per keystroke would re-enter
///     `perform` behind the cross-model gate, delay the forward predict, spam an always-compiled log
///     line, and keep ~1.1 GB of a useless model resident. **No** recovery path clears it — that is
///     what `FIMModelAvailabilityTests` pins, because the regression here is re-merging the two.
///
/// Pure state with no MLX in it, so it lives in Core and is unit-testable — the engine's own FIM
/// paths are not (no weights exist on a dev machine, the feature is default-off, and the harness
/// forces the path unreachable).
public struct FIMModelAvailability: Sendable {

    /// "The last load attempt threw." Cleared by the Tier-2 unload.
    private var loadFailedRetryably = false

    /// "This model's vocabulary has no FIM sentinels." Never cleared.
    private var unusableForBridging = false

    public init() {}

    /// True while a FIM container load may be attempted. Either verdict standing means *do not
    /// attempt a load right now*, which is why the lazy accessor consults this one property rather
    /// than the two flags.
    public var allowsLoadAttempt: Bool { !loadFailedRetryably && !unusableForBridging }

    /// True once the model has been judged incapable of bridging at all. The *load* decision goes
    /// through `allowsLoadAttempt`; this exists so the unload can say which verdict it just cleared
    /// and which one is still standing — otherwise "a verdict blocked the load" and "the caret never
    /// routed to FIM" stay indistinguishable in a log, which is confusing to debug.
    public var isUnusable: Bool { unusableForBridging }

    /// The FIM container load threw — transient by assumption, so recoverable at the next unload.
    public mutating func recordLoadFailure() { loadFailedRetryably = true }

    /// The loaded model has no FIM sentinels. Final for this model.
    public mutating func recordUnusable() { unusableForBridging = true }

    /// The Tier-2 unload: everything starts over — except the final verdict, which is
    /// deliberately untouched here.
    public mutating func clearRetryableLoadFailure() { loadFailedRetryably = false }
}
