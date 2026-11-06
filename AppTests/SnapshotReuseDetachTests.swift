import Testing
import MLX
import MLXLMCommon

///  staged-rollout ladder, **step 2** — a regression guard on the `copy()` + `eval` snapshot
/// mechanics that `MLXPredictionEngine` relies on. It pins that a snapshot is a **separate cache object**
/// whose **offset is independent** of the working cache and whose **materialised state is stable** across a
/// realistic decode (append) and a restore-then-append cycle — i.e. the engine can snapshot the clean
/// prompt cache, decode on the working copy, and restore the snapshot for a pure-append reuse without the
/// decode bleeding into it. Exercised on both cache flavours the shipping hybrid (Qwen3.5-2B-Base) uses:
/// `KVCacheSimple` (the full-attention layers) and `MambaCache` (the linear/SSM layers).
///
/// **Scope note (do not overclaim).** The cache's public API only ever *appends* — `update` scatters at
/// indices ≥ `offset` and grows/reallocates when the buffer is full, and `MambaCache` rebinds whole state
/// slots — so a test built on it cannot force an in-place overwrite of the snapshot's *own* region. This
/// therefore proves object/offset independence + value-stability-under-decode, **not** a full byte-level
/// de-aliasing under an arbitrary in-place mutation. The **authoritative numeric proof** of reuse
/// correctness — snapshot-reuse == a no-snapshot chunked prefill, with a `dirty-continue` control that
/// reproduces the snapshot-reuse corruption — is the offline probe, which runs the
/// real model decode. The two together are the ladder's step 2; this is the cheap Swift-side guard.
///
/// These touch MLX/Metal at runtime, so they live in the app-linked `NextTypedTests` target (run via
/// `xcodebuild test`), not the pure `NextTypedCore` suite. They need no model weights.
@Suite struct SnapshotReuseDetachTests {

    /// A KV block shaped like a layer's per-step input — `[batch, kvHeads, seq, headDim]` — with **distinct
    /// per-element values** (`base, base+1, …`) so a positional corruption of the snapshot is detectable
    /// (a uniform fill could mask a same-valued overwrite).
    private func block(_ seq: Int, _ base: Float) -> MLXArray {
        MLXArray((0 ..< (2 * seq * 4)).map { base + Float($0) }).reshaped([1, 2, seq, 4])
    }

    @Test func kvCacheSimpleSnapshotDetachesFromDecode() {
        let working = KVCacheSimple()
        _ = working.update(keys: block(6, 1), values: block(6, 1000))   // "prefill" 6 prompt tokens
        #expect(working.offset == 6)

        // Snapshot the clean prompt cache: copy() + eval to materialise/detach.
        let snap = working.copy()
        eval(snap.state)
        let snapKeysBefore = snap.state[0].asArray(Float.self)
        #expect(snap.offset == 6)

        // "Decode": append single-token blocks with DIFFERENT values to the WORKING cache.
        for step in 0 ..< 5 {
            _ = working.update(keys: block(1, Float(9000 + step)), values: block(1, Float(90000 + step)))
        }
        #expect(working.offset == 11)

        // The snapshot must be a separate object — same offset, same materialised values.
        #expect(snap.offset == 6)
        #expect(snap.state[0].asArray(Float.self) == snapKeysBefore)
    }

    @Test func mambaCacheSnapshotDetachesFromDecode() {
        let working = MambaCache()                 // ArraysCache(size: 2): conv state + SSM state
        working[0] = block(1, 1)
        working[1] = block(1, 1000)
        working.offset = 6

        let snap = working.copy()
        eval(snap.state)
        let snap0Before = snap.state[0].asArray(Float.self)
        let snap1Before = snap.state[1].asArray(Float.self)
        #expect(snap.offset == 6)

        // "Decode": the SSM recurrence REPLACES the state arrays and advances the offset each step.
        for step in 0 ..< 5 {
            working[0] = block(1, Float(9000 + step))
            working[1] = block(1, Float(90000 + step))
            working.offset += 1
        }
        #expect(working.offset == 11)

        #expect(snap.offset == 6)
        #expect(snap.state[0].asArray(Float.self) == snap0Before)
        #expect(snap.state[1].asArray(Float.self) == snap1Before)
    }

    @Test func restoreThenAppendLeavesTheStoredSnapshotIntact() {
        // Mirror the engine's reuse: snapshot a clean prompt cache, decode on the working copy, then
        // RESTORE the snapshot via a FRESH copy() and prefill a delta on the restore. Both the working
        // cache and the stored snapshot — offset AND values — must be unperturbed by the restore path.
        let working = KVCacheSimple()
        _ = working.update(keys: block(6, 1), values: block(6, 1000))
        let snap = working.copy()
        eval(snap.state)
        let snapKeysBefore = snap.state[0].asArray(Float.self)

        for step in 0 ..< 3 {
            _ = working.update(keys: block(1, Float(9000 + step)), values: block(1, Float(90000 + step)))
        }
        #expect(working.offset == 9)

        let restored = snap.copy()                  // the engine's `snapshot.map { $0.copy() }`
        _ = restored.update(keys: block(2, 5000), values: block(2, 50000))   // prefill a 2-token delta
        #expect(restored.offset == 8)               // 6 (snapshot) + 2 (delta)
        #expect(snap.offset == 6)                    // the stored snapshot survives the restore-copy append
        #expect(snap.state[0].asArray(Float.self) == snapKeysBefore)   // …in value, not just offset
        #expect(working.offset == 9)                 // and the working cache is independent of it
    }
}
