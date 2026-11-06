import NextTypedCore
import MLX
import MLXLMCommon

/// Prefill `tokens` onto `cache` and return the logits of the LAST position only, shaped `[1, vocab]`
/// (the split prefill).
///
/// A single `model(prompt, cache:)` call runs the LM head on every prompt position (248,320 rows on the
/// tied Qwen3.5 head) and the caller keeps one row. MLX does not push a slice back through a matmul, so
/// the rest is computed and thrown away: about 117 ms of a 530-token prefill on the 4B
/// (measured). Splitting the call avoids it:
///
/// 1. `model(tokens[..<n-1], cache:)`, then `eval` only the cache state. The logits of this call are never
///    evaluated, so MLX never computes them.
/// 2. `model(tokens[n-1], cache:)`, a one-token call whose single row is the next-token logits.
///
/// This is how `mlx_lm` and `mlx-swift-lm` themselves prefill (`generate_step`, `prepare`). The split
/// costs one extra one-token forward, so the caller passes `PrefillShape.forInput(tokenCount:)`, which
/// keeps short inputs on the single call. A one-token input is always a single call. The cache ends up
/// holding all of `tokens` either way, so the commit point (the caller's `prefillLanded = true`)
/// stays after this function returns.
///
/// Precondition: `tokens` is not empty (the callers return early on an empty prompt, and a reuse plan
/// always leaves at least one token to prefill).
func prefillLastLogits(
    _ model: any LanguageModel, tokens: [Int], cache: [KVCache], shape: PrefillShape
) -> MLXArray {
    precondition(!tokens.isEmpty, "split prefill needs at least one token")
    var last = tokens
    if shape == .split, tokens.count > 1 {
        let head = Array(tokens.dropLast())
        _ = model(MLXArray(head).reshaped([1, head.count]), cache: cache)
        eval(cache.flatMap { $0.state })
        last = [tokens[tokens.count - 1]]
    }
    let logits = model(MLXArray(last).reshaped([1, last.count]), cache: cache)
    return logits[0..., -1, 0...]
}

/// Prefill `tokens` like ``prefillLastLogits(_:tokens:cache:shape:)`` and, when `snapshotAt` is set,
/// take the hybrid snapshot after the first `snapshotAt` of them.
///
/// `snapshotAt` is an index into `tokens` (the caller's prompt boundary minus its delta start), from
/// `PrefixReuse.snapshotBoundary`. The head `tokens[..<snapshotAt]` runs as one call whose logits are
/// never evaluated (the logits-skip trick), then the cache state is `eval`-materialised and copied. The copy is
/// `eval`-materialised too, so it detaches from the working arrays the rest of the prefill and the decode
/// keep mutating (the first correctness hazard of hybrid reuse). The tail then goes through
/// `prefillLastLogits` with the shape its own length asks for. A `snapshotAt` equal to `tokens.count`
/// (tail margin 0, the old prompt-end boundary) snapshots after the whole prefill.
///
/// Returns the next-token logits, already evaluated, and the snapshot or nil.
func prefillTakingSnapshot(
    _ model: any LanguageModel, tokens: [Int], cache: [KVCache], snapshotAt: Int?
) -> (logits: MLXArray, snapshot: [KVCache]?) {
    func snapshot() -> [KVCache] {
        let snap = cache.map { $0.copy() }
        eval(snap.flatMap { $0.state })
        return snap
    }
    guard let at = snapshotAt, at > 0 else {
        let logits = prefillLastLogits(
            model, tokens: tokens, cache: cache, shape: PrefillShape.forInput(tokenCount: tokens.count))
        eval(logits)
        return (logits, nil)
    }
    guard at < tokens.count else {
        let logits = prefillLastLogits(
            model, tokens: tokens, cache: cache, shape: PrefillShape.forInput(tokenCount: tokens.count))
        eval(logits)
        return (logits, snapshot())
    }
    let head = Array(tokens[..<at])
    _ = model(MLXArray(head).reshaped([1, head.count]), cache: cache)
    eval(cache.flatMap { $0.state })
    let snap = snapshot()
    let tail = Array(tokens[at...])
    let logits = prefillLastLogits(
        model, tokens: tail, cache: cache, shape: PrefillShape.forInput(tokenCount: tail.count))
    eval(logits)
    return (logits, snap)
}
