import Foundation
import Testing
import MLX
import MLXLLM
import MLXLMCommon
import NextTypedCore

/// the split prefill (`prefillLastLogits`) must pick the same next token as the single
/// full-prompt call it replaces, and leave the cache at the same position. Runs a tiny randomly initialised
/// Qwen3.5 text model, the shipping architecture (hybrid: gated-delta layers with `MambaCache`, one
/// full-attention layer with `KVCacheSimple`), so it needs no weights. Like `SnapshotReuseDetachTests` it
/// touches MLX/Metal at runtime and therefore lives in the `NextTypedTests` target, which compiles `App/Prediction/PrefillLastLogits.swift` in.
@Suite struct SplitPrefillTests {

    /// Four layers with `full_attention_interval` 4: three gated-delta layers, then one attention layer.
    /// Head dims are the shipping 128: MLX has no precompiled Metal kernels for small ones.
    private func tinyHybridModel() throws -> Qwen35TextModel {
        let json = """
        {"model_type": "qwen3_5_text", "hidden_size": 128, "num_hidden_layers": 4,
         "intermediate_size": 256, "num_attention_heads": 2, "num_key_value_heads": 1, "head_dim": 128,
         "linear_num_value_heads": 2, "linear_num_key_heads": 1, "linear_key_head_dim": 128,
         "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4, "vocab_size": 97,
         "tie_word_embeddings": true, "full_attention_interval": 4}
        """
        let config = try JSONDecoder().decode(Qwen35TextConfiguration.self, from: Data(json.utf8))
        MLXRandom.seed(219)
        let model = Qwen35TextModel(config)
        eval(model.parameters())
        return model
    }

    /// One fixed 23-token prompt, below `vocab_size`.
    private let prompt = [5, 17, 3, 88, 41, 41, 9, 60, 2, 33, 71, 14, 90, 6, 25, 52, 8, 19, 77, 30, 11, 46, 64]

    @Test func splitPrefillPicksTheSameNextTokenAsTheFullPromptCall() throws {
        let model = try tinyHybridModel()

        let fullCache = model.newCache(parameters: nil)
        let full = model(MLXArray(prompt).reshaped([1, prompt.count]), cache: fullCache)[0..., -1, 0...]
        eval(full)

        let splitCache = model.newCache(parameters: nil)
        let split = prefillLastLogits(model, tokens: prompt, cache: splitCache, shape: .split)
        eval(split)

        #expect(split.shape == [1, 97])
        #expect(split.argMax(axis: -1).item(Int.self) == full.argMax(axis: -1).item(Int.self))
        #expect(allClose(split, full, rtol: 1e-3, atol: 1e-3).item(Bool.self))
        // The attention layer (index 3) holds every prompt token after either prefill.
        #expect(splitCache[3].offset == 23)
        #expect(fullCache[3].offset == 23)
    }

    @Test func aOneTokenInputPrefillsWithoutASplit() throws {
        let model = try tinyHybridModel()

        let fullCache = model.newCache(parameters: nil)
        let full = model(MLXArray([42]).reshaped([1, 1]), cache: fullCache)[0..., -1, 0...]

        let splitCache = model.newCache(parameters: nil)
        let split = prefillLastLogits(model, tokens: [42], cache: splitCache, shape: .split)

        #expect(split.argMax(axis: -1).item(Int.self) == full.argMax(axis: -1).item(Int.self))
        #expect(splitCache[3].offset == 1)
    }

    // MARK: The snapshot inside the prefill

    @Test func aSnapshotTakenInsideThePrefillHoldsTheHeadAndRestoresToTheSameNextToken() throws {
        let model = try tinyHybridModel()

        let fullCache = model.newCache(parameters: nil)
        let full = model(MLXArray(prompt).reshaped([1, prompt.count]), cache: fullCache)[0..., -1, 0...]
        eval(full)

        let cache = model.newCache(parameters: nil)
        let prefilled = prefillTakingSnapshot(model, tokens: prompt, cache: cache, snapshotAt: 15)
        let snapshot = try #require(prefilled.snapshot)
        #expect(prefilled.logits.argMax(axis: -1).item(Int.self) == full.argMax(axis: -1).item(Int.self))
        #expect(cache[3].offset == 23)
        #expect(snapshot[3].offset == 15)

        // Decode one step on the working cache: the snapshot must not move (it is detached).
        _ = model(MLXArray([7]).reshaped([1, 1]), cache: cache)
        eval(cache.flatMap { $0.state })
        #expect(snapshot[3].offset == 15)

        // The reuse path: restore a copy, prefill the 8-token delta, same next token as the full call.
        let restored = snapshot.map { $0.copy() }
        let delta = prefillTakingSnapshot(
            model, tokens: Array(prompt[15...]), cache: restored, snapshotAt: nil)
        #expect(delta.snapshot == nil)
        #expect(delta.logits.argMax(axis: -1).item(Int.self) == full.argMax(axis: -1).item(Int.self))
        #expect(allClose(delta.logits, full, rtol: 1e-3, atol: 1e-3).item(Bool.self))
        #expect(restored[3].offset == 23)
    }

    @Test func aSnapshotAtThePromptEndHoldsTheWholePrompt() throws {
        let model = try tinyHybridModel()
        let cache = model.newCache(parameters: nil)
        let prefilled = prefillTakingSnapshot(model, tokens: prompt, cache: cache, snapshotAt: 23)
        let snapshot = try #require(prefilled.snapshot)
        #expect(snapshot[3].offset == 23)
    }
}
