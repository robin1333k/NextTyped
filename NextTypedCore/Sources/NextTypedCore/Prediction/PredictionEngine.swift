/// Generates a short (≤5-word) continuation for a context. The MLX-backed
/// implementation lives in the app target; this seam keeps Core testable with a
/// fake engine and no model.
///
/// Implementations MUST honor cancellation (check `Task.isCancelled` / let
/// `CancellationError` propagate) — the loop cancels in-flight inference on the
/// next keystroke.
public protocol PredictionEngine: Sendable {
    func predict(for context: TypingContext) async throws -> Suggestion

    /// Predict, and hand the first words to `firstWords` once while the decode still runs (first-paint
    /// streaming). `FirstPaint.firstWords` decides what may
    /// be handed out; the return value is the full decode, as from `predict(for:)`. Called at most once,
    /// never after the decode ended. Default: `predict(for:)`, with no early words.
    func predict(for context: TypingContext,
                 firstWords: @escaping @Sendable (Suggestion) -> Void) async throws -> Suggestion

    /// Warm up ahead of the first `predict` (e.g. load/download the model). The loop calls this once
    /// at startup. Default: no-op — engines without a load step (the fake) need not implement it.
    func preload() async

    /// The engine's model transitions (load started, download progress, ready, failed, unloaded), in the
    /// order they happened, as one stream (issue `model-status/210`). The App consumes it with a single
    /// task and folds it through `ModelLoadStatus`. Default: one `.ready` event, then the stream finishes,
    /// because engines without a load step (the fake) are ready from the start.
    func loadEvents() async -> AsyncStream<ModelLoadEvent>

    /// Retry a failed load: clears the sticky failure and re-runs `preload()`
    /// so a transient download failure (no network / low disk) can recover without relaunching.
    /// Default: no-op — always-ready engines have nothing to retry.
    func retryLoad() async

    /// The user picked another model in Settings → General:
    /// release the loaded weights and load the model the stored choice names. Default: no-op, because
    /// engines without a model (the fake) have nothing to swap.
    func reloadForModelChoice() async

    // MARK: Residency lifecycle
    //
    // The four reclaim/lifecycle actions a `ModelResidencyPolicy` decides — interpreted by the App
    // against the real engine, so they ride the same seam as `predict`/`preload`. Engines without a
    // model (the fake) inherit the no-op defaults, so the residency interpreter can call them blind.

    /// Tier 0: bound the engine's buffer-cache pool (`MLX.Memory.cacheLimit`), once at startup.
    func setCacheLimit(_ bytes: Int) async
    /// Tier 1: drop the freed-buffer pool (`clearCache`) — weights stay resident.
    func flushCache() async
    /// Tier 2: release the model weights + invalidate KV + clearCache (~0.2 GB idle). `preload()` reloads.
    func unload() async
    /// Drop the KV-cache (fresh state) — at a context-switch boundary or as part of unload.
    func invalidateKVCache() async

    /// Mirror `SuggestionSession`'s `fimEnabled` into the engine ( build item 3).
    ///
    /// The reducer decides *whether a mid-text caret may produce a bridge*; the engine decides *which
    /// model answers a predict* (`FIMSite.route`). Both readings must come from the same flag, or a
    /// mid-text caret could be allowed by one and routed forward by the other. Default: no-op — an
    /// engine with no FIM model (the fake) has nothing to switch.
    func setFIMEnabled(_ enabled: Bool) async

    /// The most words one prediction may decode. The App sends
    /// `BatteryPosture.decodeWordCap`: `ContinuationBuffer.maxWords` normally, 5 on battery with
    /// "Shorter suggestions on battery". Engines clamp to `1...ContinuationBuffer.maxWords`.
    /// Default: no-op.
    func setDecodeWordCap(_ words: Int) async
}

public extension PredictionEngine {
    func predict(for context: TypingContext,
                 firstWords: @escaping @Sendable (Suggestion) -> Void) async throws -> Suggestion {
        try await predict(for: context)
    }
    func preload() async {}
    func loadEvents() async -> AsyncStream<ModelLoadEvent> { AsyncStream { continuation in continuation.yield(.ready); continuation.finish() } }
    func retryLoad() async {}
    func reloadForModelChoice() async {}
    func setCacheLimit(_ bytes: Int) async {}
    func flushCache() async {}
    func unload() async {}
    func invalidateKVCache() async {}
    func setFIMEnabled(_ enabled: Bool) async {}
    func setDecodeWordCap(_ words: Int) async {}
}
