import NextTypedCore
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import os
import Tokenizers

/// On-device prediction via Apple's MLX.
///
/// Scope: **Qwen 3 1.7B 4-bit**, fed the **raw prefix with no chat template** — we encode the text
/// straight to tokens, bypassing `applyChatTemplate`, so the instruct model behaves like a completion
/// model. Weights **download on first run**; `preload()` warms the model at app start. Greedy decode
/// (argmax, temp 0) + repetition penalty, capped at ~24 tokens, stops at a clause end / ~5 words.
///
/// **Prefix-KV-cache reuse.** The engine is **stateful across calls**: it
/// carries a KV-cache (and the token sequence that cache represents) between `predict()`s. Successive
/// low-water prefetches differ by ~one appended word, so we reuse the cached KV for the shared token
/// prefix and prefill only the delta — offline-measured at ~28× cheaper than re-prefilling a 512-token
/// prompt (the offline probe). Two design rules fall out:
///   - **Stable-front window.** The prompt token window is anchored (`PrefixReuse.window`) so its front
///     only moves in coarse steps, instead of the old `suffix(512)` sliding it one token per keystroke
///     (which defeats reuse). The window is always a superset of the last 512 tokens, so it never shows
///     *less* context than before.
///   - **Faithful repetition seeding.** The high-level `generate(input:cache:)` re-seeds the repetition
///     penalty from the delta-only input, which the probe showed **diverges** from the from-scratch
///     continuation (visible flicker). So we hand-roll the greedy loop and seed the repetition ring from
///     the **full window** — byte-identical to from-scratch up to benign float-level tail differences on
///     long prompts (the visible ghost head reproduces). An offline probe measured this.
///   - **Trimmability gate.** Reuse fires only when `canTrimPromptCache(cache)` is
///     true. The shipping Qwen3.5-2B-Base is a *hybrid* (Mamba) model whose layer-0 cache is
///     non-trimmable, so `trimPromptCache` no-ops: the committed cache then physically holds
///     `prompt + generated` while `tokens` claims only `prompt`, and a reused prefill would attend past
///     that stale KV (and roll an un-rewindable SSM state) → a *silently wrong* ghost (the observed
///     sub-word-salad / repetition-loop collapse). On a non-trimmable cache the engine therefore
///     **rebuilds from scratch every call** (DEBUG-tagged `rebuild(non-trimmable)`). Whether reuse can be
///     made correct on a Mamba cache is still open: measure first, then decide.
///
/// Cancellation + actor safety: the engine is an `actor`; all cache state lives in a
/// `CacheState` box touched **only inside `container.perform`**, whose serial executor serializes the two
/// performs that a cancel-then-reschedule produces. **Commit-after-prefill:** the cache is
/// committed once the prefill's `eval` lands — not after a clean decode — so a decode-phase cancellation
/// **warms** the cache (it renders nothing) instead of wiping it. The old "any abnormal exit invalidates"
/// rule discarded a perfectly-valid prompt cache on every keystroke-burst cancel, defeating
/// reuse under fast typing (the 896 ms-rebuild death-spiral). The only `invalidate()` left is a
/// prefill-phase throw in the **reuse** branch (the live cache was trimmed in place); a **rebuild** aborted
/// before its prefill lands keeps the old cache (it builds into a local, published only at commit).
/// `cache` and `tokens` are only ever set together, post-prefill. On a trimmable cache the cache represents
/// exactly `tokens`; on the hybrid it holds the snapshot instead, and reuse goes through
/// `snapshot`/`snapshotTokens`, never `cache`. The decision is pure Core (`PrefixReuse.commitDecision`), unit-tested against regressions.
actor MLXPredictionEngine: PredictionEngine {
    /// Model source: the self-quantized **Qwen3.5-4B-Base** MLX model,
    /// with the 2B as the fallback. Base ⇒ raw prefix, no chat template, no BOS; both
    /// share the `qwen3_5` class, the tokenizer and the hybrid cache, so nothing below is size-specific.
    /// **6-bit**: a naive 4-bit regressed EN-flush ~40% below bf16 on the 2B, 6-bit recovers it
    /// (measured in the model eval). The 4B won that eval.
    ///
    /// **Source resolution.** The candidate folders come from pure Core
    /// (`ShippingModel.localDirectoryCandidates`): `~/Models/Qwen3.5-4B-Base-MLX-6bit`, then the 2B
    /// folder. The first one that exists is loaded directly, so the offline dev loop never re-downloads;
    /// with none, the weights are downloaded from the Hub by repo id on first run, and that repo is
    /// the **4B** (`ShippingModel.hubRepoId`).
    ///
    /// **`UserDefaults`-overridable** (`modelDirectory`): a non-empty value replaces
    /// the candidate list, so the 2B or a candidate model loads without a rebuild. An absolute path is
    /// used as is, anything else is relative to the home directory, like `fimModelDirectory`.
    ///
    ///     defaults write com.robinklotz.NextTyped modelDirectory Models/Qwen3.5-2B-Base-MLX-6bit
    ///     defaults delete com.robinklotz.NextTyped modelDirectory   # back to shipping
    ///
    /// Returns the candidate as written (for the Settings label); `nil` when no candidate exists.
    nonisolated static func existingLocalModelDirectory() -> String? {
        return ModelSourceResolver.firstExistingDirectory(currentPlan().candidates) {
            FileManager.default.fileExists(atPath: resolveModelPath($0).path)
        }
    }

    /// The folder this launch loads from, or `nil` for the Hub path. Same decision as the engine's
    /// `loadedContainer()`, without MLX, so Settings → General can name the model.
    nonisolated static func localModelDirectoryForThisLaunch() -> String? {
        let local = existingLocalModelDirectory()
        let plan = currentPlan()
        let source = ModelSourceResolver.resolve(
            localDirectoryExists: local != nil,
            forceDownload: UserDefaults.standard.bool(forKey: "forceModelDownload"),
            repoId: plan.hubRepoId, revision: plan.hubRevision)
        guard case .localDirectory = source else { return nil }
        return local
    }

    /// What loads now: the user's pick (`modelChoice`, Settings → General) and the developer keys
    /// (`modelDirectory`, `modelRepoId`, `modelRevision`). Read on every load, so a change of the pick
    /// applies at the next load.
    nonisolated static func currentPlan() -> ModelPlan {
        let defaults = UserDefaults.standard
        return ShippingModel.plan(
            choice: ModelChoice(stored: defaults.string(forKey: "modelChoice")),
            directoryOverride: defaults.string(forKey: "modelDirectory"),
            repoIdOverride: defaults.string(forKey: "modelRepoId"),
            revisionOverride: defaults.string(forKey: "modelRevision"))
    }

    /// Home-relative unless absolute, the rule `modelDirectory` and `fimModelDirectory` share.
    nonisolated private static func resolveModelPath(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path)
    }

    /// The model's name as Settings shows it: the model this launch loads (4B or 2B). One place,
    /// so no view carries its own copy of the string.
    nonisolated static var displayName: String {
        ShippingModel.settingsLabel(
            localDirectory: localModelDirectoryForThisLaunch(),
            choice: ModelChoice(stored: UserDefaults.standard.string(forKey: "modelChoice")))
    }

    /// The developer-local folder this launch would load, shared with the Settings snapshot fixture.
    nonisolated static var localModelDirectory: URL? {
        existingLocalModelDirectory().map(resolveModelPath)
    }

    /// The folder the base model's weights were actually loaded from: `modelDirectory` when the local
    /// copy won, otherwise the Hub cache snapshot directory the download wrote to. `nil` until a load
    /// has succeeded. Settings → General reveals this folder and disables its button while it is `nil`.
    private(set) var loadedModelDirectory: URL?

    /// The Hugging Face repo the shipping app downloads the 6-bit weights from on first run.
    ///
    /// The 2B was hosted on 2026-08-29, the 4B on 2026-10-28, so a machine
    /// without a `~/Models/` copy downloads and runs the 4B. The HF account is
    /// the one in `ShippingModel.hubRepoId`. Overridable at runtime
    /// (`defaults write com.robinklotz.NextTyped modelRepoId <owner/repo>`).
    ///
    /// The shipping download is **pinned to a commit** (`ShippingModel.hubRevision`), so a push to the
    /// Hub repo changes nothing for a new install. `modelRepoId` alone reads that repo's `main`; the
    /// developer key `modelRevision` sets another revision. Moving the pin is a PR.
    private var modelHubSource: (repoId: String, revision: String) {
        let plan = Self.currentPlan()
        return (plan.hubRepoId, plan.hubRevision)
    }

    /// Developer escape hatch: force the Hub-download path even when the local
    /// `~/Models/` copy is present, to exercise the first-run download UX without deleting it.
    /// `defaults write com.robinklotz.NextTyped forceModelDownload -bool YES`.
    private let forceModelDownload = UserDefaults.standard.bool(forKey: "forceModelDownload")

    /// The **FIM model** for mid-text insertion (build item 2) — a second, smaller model that
    /// bridges between a prefix `P` and a suffix `S`. Kept separate rather than replacing the 2B: the 2B
    /// carries the FIM sentinels but is not FIM-trained (feasibility ticket 06, 0/4 probe), and it remains
    /// the better forward-continuation model.
    ///
    /// > **Human step (build item 1):** these weights are not in `~/Models/` yet and the ship-gate
    /// > the offline probe has not run, so this path is unreachable in practice today —
    /// > `midTextCompletionEnabled` is off by default and `loadedFIMContainer()` degrades to "no
    /// > suggestion" if the directory is absent and the repo doesn't exist. Both the directory name and
    /// > the repo id are `UserDefaults`-overridable so the eval's chosen model/quant can be pointed at
    /// > without a rebuild.
    private let fimModelDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            UserDefaults.standard.string(forKey: "fimModelDirectory")
                ?? "Models/Qwen3-1.7B-MLX-6bit")

    /// Owner corrected to the real HF account alongside `modelRepoId` (`robinklotz` never existed).
    /// These weights are **still unhosted** — this id is where they would go, not where they are.
    private let fimHubSource = ShippingModel.hubSource(
        repoIdOverride: UserDefaults.standard.string(forKey: "fimModelRepoId"),
        revisionOverride: UserDefaults.standard.string(forKey: "fimModelRevision"),
        defaultRepoId: ShippingModel.fimHubRepoId, defaultRevision: ShippingModel.fimHubRevision)

    /// Sentinel ordering for the FIM prompt ( decision; build item 5). **SPM is the primary**
    /// because it puts the static `S` at the stable front and so preserves KV-reuse; PSM is the eval
    /// fallback and runs reuse-off. An offline probe picks the shipping value; until it
    /// runs, override for a probe session with
    /// `defaults write com.robinklotz.NextTyped fimOrdering psm`.
    private let fimOrdering: FIMPrompt.Ordering =
        UserDefaults.standard.string(forKey: "fimOrdering").flatMap(FIMPrompt.Ordering.init(rawValue:))
            ?? .spm

    /// The FIM sentinel *strings* looked up in the FIM model's own vocabulary. Qwen's naming; resolution
    /// is fail-closed (`FIMPrompt.Sentinels` rejects a missing or `<unk>`-resolving id), so a model
    /// without them simply never produces a bridge instead of producing a malformed one.
    private static let fimPrefixToken = "<|fim_prefix|>"
    private static let fimSuffixToken = "<|fim_suffix|>"
    private static let fimMiddleToken = "<|fim_middle|>"
    private static let fimPadToken = "<|fim_pad|>"
    private static let endOfTextToken = "<|endoftext|>"

    /// The **document-boundary token** spliced between prompt-front segments.
    ///
    /// The front is a list of *different documents* — the user's own past sentences, another window's
    /// text, someone else's chat turn — and the shipping model is a **base** model. To it a `"\n\n"`
    /// between two of them is a paragraph break inside one document, so it continues a style exemplar as
    /// content: a learned sentence about a person called "Nola" reappeared as a vendor in an unrelated
    /// competitor analysis. Base models are pre-trained on documents concatenated with an end-of-text
    /// token, so emitting that token is how you say "the previous document ended" in the model's own
    /// vocabulary. It is a *separator*, not a system prompt: no instructions, no labels, no framing text,
    /// so no instruction text enters the prompt.
    ///
    /// **Which token.** `<|endoftext|>` looked up by name in the model's own vocabulary — for Qwen3.5
    /// base that is the pre-training document separator (and the base config's EOS). Deliberately *not*
    /// `tokenizer.eosTokenId`: on a chat-tuned Qwen that resolves to `<|im_end|>`, a conversation-turn
    /// terminator, which is not what pre-training put between documents.
    ///
    /// **Fail-closed**, following `FIMPrompt.Sentinels`: `convertTokenToId` answers `<unk>` rather than
    /// `nil` for a token the vocabulary lacks, so an unfiltered lookup would splice junk into every
    /// prompt. A missing or `<unk>`-resolving id means we fall back to exactly today's plain `"\n\n"`
    /// join, and the verdict is **latched** (a vocabulary does not grow) so it is resolved once rather
    /// than per keystroke.
    private enum BoundaryToken: Sendable {
        case unresolved
        case token(Int)
        case unavailable
    }
    private var boundaryToken: BoundaryToken = .unresolved

    /// Resolve the boundary token from a model's own vocabulary. `nil` ⇒ this model gets the plain-text
    /// join. Static + tokenizer-parameterised so it can run inside the `@Sendable` `perform` closure,
    /// where actor state is unreachable; the verdict travels back on `GenerationOutcome` and is latched
    /// on the actor.
    private static func resolveBoundaryToken(_ tokenizer: any MLXLMCommon.Tokenizer) -> Int? {
        guard let id = tokenizer.convertTokenToId(Self.endOfTextToken) else { return nil }
        if let unknown = tokenizer.unknownTokenId, id == unknown { return nil }
        return id
    }

    /// Model transitions in order (`ModelLoadEvent`), one stream with one consumer (`AppCoordinator`).
    /// Unbounded, so events from before the consumer attaches are kept. `.downloading` only fires on the
    /// Hub path; the local-directory load skips to `.loadingWeights`.
    private let loadEventStream = AsyncStream<ModelLoadEvent>.makeStream()

    /// The stream the App folds through `ModelLoadStatus` (issue `model-status/210`).
    func loadEvents() -> AsyncStream<ModelLoadEvent> { loadEventStream.stream }

    private func emit(_ event: ModelLoadEvent) {
        loadEventStream.continuation.yield(event)
        if EngineWarmUp.starts(after: event, enabled: warmUpEnabled) { startWarmUp() }
    }

    // MARK: - Engine warm-up

    /// `engineWarmUpEnabled` (on when absent), read once at init; `NO` is the enginebench A/B arm.
    private let warmUpEnabled = UserDefaults.standard.object(forKey: "engineWarmUpEnabled") == nil
        || UserDefaults.standard.bool(forKey: "engineWarmUpEnabled")

    /// The warm-up after the latest `.ready`, owned here so a real predict or an unload can cancel it.
    private var warmUpTask: Task<Void, Never>?

    /// Run one throwaway predict of `EngineWarmUp.context` after a load. Nothing is returned to anyone;
    /// the one always-compiled `[mlx]: warm-up` line is the whole trace.
    private func startWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = Task { await self.runWarmUp() }
    }

    private func runWarmUp() async {
        do {
            _ = try await predictForward(for: EngineWarmUp.context, firstWords: { _ in }, purpose: .warmUp)
        } catch {
            acLog("%@", EngineWarmUp.logLine(.yielded))
        }
    }

    /// A real predict goes first (single slot): the warm-up's decode loop sees the cancel and
    /// stops, and a warm-up that has not reached the perform gate yet never touches the cache.
    private func yieldWarmUp() {
        warmUpTask?.cancel()
        warmUpTask = nil
    }

    /// The bench waits here so its first predict meets a finished warm-up, as a user's first keystroke
    /// some seconds after the load does.
    func waitForWarmUp() async {
        await warmUpTask?.value
    }

    /// HEAD char-budget for `windowContext` before it's joined in front of the prefix (C1).
    private static let windowCharBudget = 1500

    /// HEAD char-budget for `replyContext` — the interlocutor's most-recent turn, joined after
    /// windowContext and immediately before the prefix. Sized to admit the Core descriptor's per-turn
    /// head-cap (1200) without truncating a normal turn while still bounding a huge code-block turn.
    private static let replyCharBudget = 1500

    /// HEAD char-budget for the **ambient** OCR segment — Tier-2 screen context, furthest
    /// from the prefix. Smaller than the other two on purpose: it is the noisiest source (OCR of
    /// windows the user isn't typing in), so it gets the smallest claim on the prompt.
    private static let ocrAmbientCharBudget = 800

    /// HEAD char-budget for the **personalization** segment — the style profile, front-most.
    /// ~⅓ of `windowCharBudget`: the smallest claim of all, because voice-priming saturates early and the
    /// segment must beat the context it displaces.
    private static let personalizationCharBudget = 600

    /// Prompt token window. `windowMax` is the minimum recent-token tail kept (the old
    /// `suffix` cap, so context never shrinks); `reanchorStep` is how far the stable front jumps when it
    /// moves — reuse fires on every keystroke between jumps, a single rebuild on a jump (~1 / 128 accepts).
    /// Worst-case prompt length is `windowMax + reanchorStep − 1` (= 639 tok).
    ///
    /// `windowMax` is **`UserDefaults`-overridable** (`promptWindowMax`, clamped to 128…4096) so the
    /// front-budget experiment can force the context front through the
    /// window and price it, **without a rebuild** between the two arms — the `snapshotReuseEnabled`
    /// shape. It is a measurement knob, not a shipping setting: raising it makes every
    /// predict's prefill longer (prefill scales with prompt length and is ~70 % of a predict today), so
    /// it trades directly against the first-paint budget. Read once at first use; absent or
    /// non-positive ⇒ the shipping 512.
    ///
    ///     defaults write com.robinklotz.NextTyped promptWindowMax -int 2048
    ///     defaults delete com.robinklotz.NextTyped promptWindowMax   # back to shipping
    private static let windowMax: Int = {
        let override = UserDefaults.standard.integer(forKey: "promptWindowMax")
        guard override > 0 else { return 512 }
        return min(max(override, 128), 4096)
    }()
    private static let reanchorStep = 128

    /// Share of ``windowMax`` reserved for the **prompt front** (
    /// option 1). The front is the head of the prompt and `PrefixReuse.window` drops from the head, so
    /// without a reserve the front loses the whole window on a long document — measured at 0/392 tokens
    /// on every predict of a long note, while the `built(…)` char counts still read full.
    ///
    /// **`UserDefaults`-overridable** (`promptFrontReserveFraction`, clamped to
    /// `PromptFrontBudget.reserveFractionRange`) following the `promptWindowMax` / `snapshotReuseEnabled`
    /// shape, so the share can be re-tuned against a capture **without a rebuild**. Read once at first
    /// use; absent, non-finite or non-positive ⇒ the shipping `PromptFrontBudget.defaultReserveFraction`
    /// (30 % ≈ 153 tok at 512).
    ///
    ///     defaults write com.robinklotz.NextTyped promptFrontReserveFraction -float 0.4
    ///     defaults delete com.robinklotz.NextTyped promptFrontReserveFraction   # back to shipping
    private static let frontReserveFraction: Double = PromptFrontBudget.clampReserveFraction(
        UserDefaults.standard.double(forKey: "promptFrontReserveFraction"))

    /// Repetition-penalty **window** and **strength**. The penalty is what keeps greedy out
    /// of the "1.1.1…" loop; `repetitionContextSize` is how many of the *prompt window's* trailing
    /// tokens the ring is seeded from (the seeding itself is in the decode loop below — it takes the
    /// last `repetitionContextSize` tokens of the FULL window, which is what makes KV-reuse reproduce
    /// the from-scratch ghost).
    ///
    /// The shipping 20 is the reason a long verbatim copy is not braked at all: a measured 57-word
    /// copy is ~80 tokens, so the attractor runs **structurally past** a 20-token ring — it is never
    /// seen. Both values are therefore **`UserDefaults`-overridable**
    /// following the `promptWindowMax` / `snapshotReuseEnabled` shape, so the arms of that
    /// measurement run **without a rebuild**. The strength knob rides along because it is the only way
    /// to tell a *too-wide window* apart from a *too-strong penalty over a wide window* — the concrete
    /// worry there is German function words (`der/die/und`) being penalised across hundreds of tokens.
    ///
    /// Measurement knobs, not shipping settings. Read once at first use; absent or non-positive ⇒ the
    /// shipping 20 / 1.15.
    ///
    ///     defaults write com.robinklotz.NextTyped repetitionContextSize -int 512
    ///     defaults write com.robinklotz.NextTyped repetitionPenalty -float 1.05
    ///     defaults delete com.robinklotz.NextTyped repetitionContextSize   # back to shipping
    private static let repetitionContextSize: Int = {
        let override = UserDefaults.standard.integer(forKey: "repetitionContextSize")
        guard override > 0 else { return 20 }
        return min(override, 4096)
    }()
    private static let repetitionPenalty: Float = {
        let override = UserDefaults.standard.double(forKey: "repetitionPenalty")
        guard override.isFinite, override > 0 else { return 1.15 }
        return Float(min(max(override, 1.0), 2.0))
    }()

    /// All KV-cache state. `tokens` is the exact token sequence the cache currently represents
    /// (`offset == tokens.count`).
    ///
    /// **What makes the `@unchecked Sendable` sound:** every mutation happens under mutual exclusion
    /// with every other — either inside `container.perform` (serialized by that container's
    /// single-threaded executor) or on the actor while the **cross-model perform gate** is held, which
    /// by construction means no `perform` is running on either container. `invalidateKVCache()` and
    /// `unload()` take the second route; before the FIM model there was only one container and only the
    /// first route existed. Do not add a mutation on a third route.
    private final class CacheState: @unchecked Sendable {
        var cache: [KVCache]?
        /// Clean pre-decode cache for hybrid snapshot-reuse. Captured during the prefill, at
        /// the snapshot boundary a tail margin before the prompt end, on a non-trimmable cache, and
        /// restored whenever `snapshotTokens` is a prefix of the next prompt. Represents exactly
        /// `snapshotTokens`, not `tokens`. Nil whenever snapshot-reuse is off or the live cache is
        /// trimmable (the trim path reuses `cache`).
        /// Dropped together with `cache`/`tokens` on `invalidate()` (context-switch / unload). It is
        /// **deliberately preserved across a Tier-1 `flushCache()`**: that flush only reclaims
        /// the freed-GPU-buffer *pool* and leaves the model weights + this snapshot's (ARC-held, ~MB) KV
        /// resident, so a snapshot reuse right after an idle flush still restores rather than rebuilds.
        var snapshot: [KVCache]?
        /// The prompt tokens `snapshot` represents. The snapshot sits a tail margin before the
        /// end of the prompt it was taken from, so this is a prefix of some earlier `tokens`, not `tokens`.
        var snapshotTokens: [Int] = []
        var tokens: [Int] = []
        func invalidate() { cache = nil; snapshot = nil; snapshotTokens = []; tokens = [] }
    }
    private let cacheState = CacheState()

    /// The FIM model's own KV state ( build item 10). Per-model, never shared: the two models
    /// have different vocabularies and different prompts, so a cache from one is meaningless to the
    /// other. Each runs `PrefixReuse.commitDecision` independently, and both stay warm across
    /// a model switch — a switch cancels the in-flight predict, which *warms* rather than wipes.
    private let fimCacheState = CacheState()

    ///  flag for hybrid (non-trimmable Mamba cache) prefix-KV **snapshot-reuse**. **On by
    /// default**: with the snapshot at the snapshot boundary
    /// it hits on 86–96 % of typing predicts in the host enginebench. Off restores the earlier
    /// rebuild-always behaviour byte for byte. Read once at init:
    /// `defaults write com.robinklotz.NextTyped snapshotReuseEnabled -bool NO`.
    private let snapshotReuseEnabled = PrefixReuse.snapshotReuseEnabled(
        stored: UserDefaults.standard.object(forKey: "snapshotReuseEnabled") == nil
            ? nil : UserDefaults.standard.bool(forKey: "snapshotReuseEnabled"))

    /// Where the hybrid snapshot sits: `snapshotTailMargin`
    /// tokens before the prompt end, so the re-tokenized word at the caret falls after it, and moved
    /// only when it advances at least `snapshotMinAdvance` tokens past the snapshot a reuse restored
    /// (`PrefixReuse.snapshotBoundary`). Measurement knobs read once at init; absent ⇒ 4 / 16. A margin
    /// of 0 with a step of 1 is the old prompt-end boundary, for before/after benches.
    ///
    ///     defaults write com.robinklotz.NextTyped snapshotTailMargin -int 0
    private let snapshotTailMargin: Int =
        UserDefaults.standard.object(forKey: "snapshotTailMargin") == nil
        ? 4 : max(0, UserDefaults.standard.integer(forKey: "snapshotTailMargin"))
    private let snapshotMinAdvance: Int =
        UserDefaults.standard.object(forKey: "snapshotMinAdvance") == nil
        ? 16 : max(1, UserDefaults.standard.integer(forKey: "snapshotMinAdvance"))

    private var container: ModelContainer?
    /// Bumped by every `unload()`. A load that started before the bump is stale (a pick or an idle
    /// unload arrived while it ran) and must not install its container or latch `loadFailed`.
    private var loadGeneration = 0
    /// Lock-protected copy of `loadGeneration`, readable from the downloader's off-actor progress callback.
    private let loadGenerationMirror = OSAllocatedUnfairLock(initialState: 0)
    private let baseLoadFlight = SingleFlight<ModelContainer?>()
    private var loadFailed = false

    private var fimContainer: ModelContainer?

    /// The FIM model's two failure verdicts, split by **lifetime** (and see
    /// `FIMModelAvailability` for the whole argument): a *retryable* load failure that the
    /// Tier-2 `unload()` clears, and a *final* "this model has no FIM sentinels" verdict that nothing
    /// clears. One flag used to carry both, so a transient Hub failure disabled bridging for the rest
    /// of the process lifetime. Written on the FIM paths only: with `midTextCompletionEnabled` off the
    /// FIM container is never constructed and this stays at its fresh value.
    private var fimAvailability = FIMModelAvailability()

    /// Master gate for mid-text insertion (build item 3). Seeded from the persisted setting
    /// by `AppCoordinator.start()` — the same value it seeds `SuggestionSession` with — so the reducer
    /// and the engine can never disagree about which model a caret routes to. **Default false**, which
    /// makes `FIMSite.route` answer `.forward` unconditionally: the FIM model is never selected and so
    /// never loaded, and the forward path is byte-identical to the pre-FIM engine.
    private var fimEnabled = false

    /// Warm the model ahead of the first predict (called once at app start). Safe to call repeatedly.
    ///
    /// **Base model only** — the "lazy-both" residency rule ( build item 2): the FIM model
    /// loads on the first mid-text predict and is *never* eagerly (re)loaded, so a user who never types
    /// mid-text with the feature on pays nothing for it.
    func preload() async {
        _ = try? await loadedContainer()
    }

    /// Mirror the reducer's `fimEnabled` into the engine ( build item 3). Called wherever the
    /// App sends `.setFIMEnabled` to `SuggestionSession`.
    func setFIMEnabled(_ enabled: Bool) {
        fimEnabled = enabled
    }

    /// The decode word cap: the decode loops stop after this many words and
    /// the buffer is trimmed to it. `ContinuationBuffer.maxWords` is the default and the ceiling.
    private var decodeWordCap = ContinuationBuffer.maxWords

    func setDecodeWordCap(_ words: Int) {
        decodeWordCap = min(max(words, 1), ContinuationBuffer.maxWords)
    }

    // MARK: - Cross-model perform gate ( build item 10)
    //
    // With one container, the "one inference at a time" rule was enforced *for free* by the
    // container's single serial executor: a cancelled predict's `perform` and its replacement queued
    // behind each other. Two containers are two independent executors, so a cancelled predict on one
    // model can still be running its decode while the other model's `perform` starts — two concurrent
    // MLX graphs, and (worse) `unload()`'s `clearCache()` racing a live perform on the other container.
    //
    // This async mutex restores the invariant across both: every MLX `perform` — generation *and* the
    // residency effects — is taken under it, so the cancelled model's in-flight work is drained before
    // the next one dispatches. Deliberately NOT an unstructured `Task` wrapper (which would be the
    // shorter spelling): an unstructured Task does not inherit cancellation, so the decode loops'
    // `Task.isCancelled` checks would go blind and predict cancellation would silently stop working.

    private var performBusy = false
    private var performWaiters: [CheckedContinuation<Void, Never>] = []

    /// Wait until no `perform` is in flight on either container, then claim the slot. Every caller must
    /// pair this with `releasePerform()` in a `defer`.
    private func acquirePerform() async {
        while performBusy {
            await withCheckedContinuation { performWaiters.append($0) }
        }
        // No suspension point between the last `performBusy == false` observation and this write, and
        // the actor serializes both, so the claim cannot be lost to a racing caller.
        performBusy = true
    }

    private func releasePerform() {
        performBusy = false
        let waiters = performWaiters
        performWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Lazily load (download on first run) the model, caching the container. Returns `nil` if loading
    /// has failed — the loop then shows nothing rather than crashing.
    ///
    /// Source: the dev-local `~/Models/` copy when present (no download),
    /// else a Hub download by `modelRepoId`. On the download path the byte progress is forwarded to the
    /// menu bar via `loadEvents()`; the local path reports only the weights-into-memory phase.
    private func loadedContainer() async throws -> ModelContainer? {
        if let container { return container }
        if loadFailed { return nil }
        let generation = loadGeneration
        // One load at a time: a second pick or a predict during a load joins it.
        return await baseLoadFlight.run { [self] in await performLoad(generation: generation) }
    }

    private func performLoad(generation: Int) async -> ModelContainer? {

        let localDirectory = Self.existingLocalModelDirectory().map(Self.resolveModelPath)
        let source = ModelSourceResolver.resolve(
            localDirectoryExists: localDirectory != nil,
            forceDownload: forceModelDownload,
            repoId: modelHubSource.repoId, revision: modelHubSource.revision)

        // Build the configuration for the resolved source. Both go through the downloader-backed
        // `loadContainer` overload; `.directory` short-circuits the download inside `resolve(configuration:)`.
        let configuration: ModelConfiguration
        switch source {
        case .localDirectory:
            guard let localDirectory else { return nil }  // unreachable: the resolver saw it exist
            configuration = ModelConfiguration(directory: localDirectory)
        case .hubDownload(let repoId, let revision):
            configuration = ModelConfiguration(id: repoId, revision: revision)
        }

        // The free-disk check runs before the download starts, so a full disk shows a clear
        // message on the Model page instead of a download that fails partway. Sticky like a failed load;
        // Retry checks again.
        if case .hubDownload(let repoId, _) = source,
           let verdict = ModelDiskReader.verdict(repoId: repoId),
           case .tooSmall(let needed, let free) = verdict {
            acLog("[gate]: model-disk-too-small need=%lld free=%lld", needed, free)
            loadFailed = true
            emit(.diskTooSmall(verdict))
            return nil
        }

        do {
            // These lifecycle lines are deliberately always-compiled (unlike the #if DEBUG per-predict
            // diagnostics below): once-per-launch status, no user text, and the failure line is the only
            // record of the load error. Local stderr only — not telemetry, so nothing leaves the Mac.
            switch source {
            case .localDirectory:
                acLog("[mlx]: loading %@ (local)…", localDirectory?.lastPathComponent ?? "?")
            case .hubDownload(let repoId, let revision):
                acLog(
                    "[mlx]: downloading %@ from Hub…",
                    ShippingModel.hubDownloadLabel(repoId: repoId, revision: revision))
            }
            let started = Date()
            emit(.loadingStarted)
            // Report the download-byte fraction on the Hub path; a local load fetches nothing so its
            // handler never fires (the App shows the plain "Loading model…" phase instead).
            let progressSink = loadEventStream.continuation
            let generationMirror = loadGenerationMirror
            // …and write it to the LOG too, throttled. Built only on the Hub
            // path, so a local-directory load cannot emit a download line even if the downloader were
            // ever to call back for a cache hit.
            let progressLog: DownloadProgressLogger? = {
                guard case .hubDownload = source else { return nil }
                return DownloadProgressLogger(tag: "mlx")
            }()
            let recorder = DownloadedDirectoryRecorder(wrapping: #hubDownloader())
            let c = try await LLMModelFactory.shared.loadContainer(
                from: recorder,
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    // A superseded load must not report: it would flip the badge back after Ready.
                    guard generationMirror.withLock({ $0 }) == generation else { return }
                    progressSink.yield(.downloading(progress.fractionCompleted))
                    progressLog?.report(fraction: progress.fractionCompleted)
                }
            )
            // Stale check first: a superseded load must not touch loadedModelDirectory or the load state.
            if generation != loadGeneration {
                acLog("[mlx]: stale load discarded (model choice or unload changed during the load)")
                return nil
            }
            progressLog?.reportSource(freshFileCount: recorder.freshFileCount())
            switch source {
            case .localDirectory: loadedModelDirectory = localDirectory
            case .hubDownload: loadedModelDirectory = recorder.firstDirectory
            }
            acLog("[mlx]: model folder %@", loadedModelDirectory?.path ?? "unknown")
            // Bytes are present; MLX is now loading the weights into memory.
            emit(.loadingWeights)
            container = c
            acLog("[mlx]: model ready in %.1f s", Date().timeIntervalSince(started))
            #if DEBUG
            acLog("[mlx]: after load %@", Self.memorySnapshotTag())  // the residency "after load" floor
            #endif
            emit(.ready)
            return c
        } catch {
            if generation != loadGeneration {
                acLog("[mlx]: stale load discarded (failed after the model choice changed)")
                return nil
            }
            acLog("[mlx]: model load failed: %@", String(describing: error))
            loadFailed = true
            emit(.failed)
            return nil
        }
    }

    /// Lazily load the **FIM model** ( build item 2). Same source resolution as the base model
    /// (dev-local `~/Models/` copy first, else a Hub download), but three deliberate differences:
    ///
    ///   - **Strictly lazy.** Only `predictFIM` calls this; `preload()`/`retryLoad()` do not, so the
    ///     weights are never fetched until the user actually types mid-text with the feature on.
    ///   - **No progress reporting.** `loadEvents()` drives the menu-bar *model status*, which
    ///     means the base model's readiness. Routing a mid-session FIM download through it would flip a
    ///     working app back to "Downloading…" and read as a regression of the model the user is using.
    ///     A first FIM load therefore shows nothing and simply produces no bridge until it lands.
    ///   - **Sticky failure, in two lifetimes.** `fimAvailability` is separate from `loadFailed`, so a
    ///     missing FIM model never marks the base model failed (it must keep predicting forward), and
    ///     the menu-bar Retry stays about the base model. Within it, a *load failure* is transient by
    ///     assumption and cleared by the Tier-2 `unload()`, while the *sentinel* verdict is final
    ///     (one flag used to carry both, and nothing cleared it).
    private func loadedFIMContainer() async throws -> ModelContainer? {
        if let fimContainer { return fimContainer }
        // Either verdict means "do not attempt a load right now" — a standing load failure is what
        // keeps a failing load from being re-attempted on every mid-text keystroke.
        if !fimAvailability.allowsLoadAttempt { return nil }

        let localExists = FileManager.default.fileExists(atPath: fimModelDirectory.path)
        let source = ModelSourceResolver.resolve(
            localDirectoryExists: localExists,
            forceDownload: forceModelDownload,
            repoId: fimHubSource.repoId, revision: fimHubSource.revision)

        let configuration: ModelConfiguration
        switch source {
        case .localDirectory: configuration = ModelConfiguration(directory: fimModelDirectory)
        case .hubDownload(let repoId, let revision):
            configuration = ModelConfiguration(id: repoId, revision: revision)
        }

        do {
            switch source {
            case .localDirectory:
                acLog("[fim]: loading %@ (local)…", fimModelDirectory.lastPathComponent)
            case .hubDownload(let repoId, let revision):
                acLog(
                    "[fim]: downloading %@ from Hub…",
                    ShippingModel.hubDownloadLabel(repoId: repoId, revision: revision))
            }
            let started = Date()
            // The FIM load reports **no** progress to the menu bar on purpose (see the doc comment
            // above), but it does log it: leaving one of the two download paths silent would read as an
            // oversight later. Consistency only — these weights are unhosted and the path is
            // default-off, so this line has never been observed in a real download.
            let progressLog: DownloadProgressLogger? = {
                guard case .hubDownload = source else { return nil }
                return DownloadProgressLogger(tag: "fim")
            }()
            // No `reportSource()` here: `download-source` is asserted only for the base model
            // (`residency-idle-flush-hub`), and the FIM path is default-off.
            let c = try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                progressHandler: { progress in
                    progressLog?.report(fraction: progress.fractionCompleted)
                })
            fimContainer = c
            acLog("[fim]: model ready in %.1f s", Date().timeIntervalSince(started))
            return c
        } catch {
            // Greppably distinct from the sentinel line below, which is the *permanent* verdict: the
            // two are indistinguishable in a log otherwise, and knowing which one you are looking at
            // is the difference between "wait for an idle unload" and "this model will never bridge".
            acLog("[fim]: model load failed, will retry after an idle unload: %@",
                  String(describing: error))
            fimAvailability.recordLoadFailure()
            return nil
        }
    }

    /// Apply a changed `modelChoice`: release the loaded weights and load the model the plan now names
    /// (its local folder, else the pinned Hub download). Clears a sticky load failure too. Settings →
    /// General calls this after it stores the pick; it logs `[mlx]: model choice changed`.
    func reloadForModelChoice() async {
        acLog("[mlx]: model choice changed, reloading")
        await unload()
        loadFailed = false
        _ = try? await loadedContainer()
    }

    /// Retry a failed load: clear the sticky `loadFailed` and re-run the load,
    /// so a transient download failure (no network / low disk) recovers on demand without a relaunch.
    /// A no-op once loaded. The menu-bar "Retry" affordance calls this.
    func retryLoad() async {
        guard container == nil else { return }
        loadFailed = false
        _ = try? await loadedContainer()
    }

    // MARK: - Residency lifecycle
    //
    // The four effects the `ModelResidencyPolicy` reducer (pure Core) emits, interpreted here against
    // `MLX.Memory` + the engine's own state. All MLX-touching, so not Core-unit-testable — the *decision*
    // (when to fire each) is the tested Core reducer; these are just the mechanism. Actor-isolated, so an
    // in-flight `predict` is unaffected mid-flight: its `container.perform` captured the container in a
    // **local** (`loadedContainer()`'s return is bound locally below), so ARC keeps the weights alive
    // until that perform completes even if `unload()` nils `self.container` in between (invariant ②).

    /// Tier 0: bound the MLX buffer-cache pool, once at startup. Unbounded, the freed-GPU-buffer pool
    /// (`Memory.cacheMemory`) grows to the device working set (tens of GB on a roomy Mac) — the 19.4 GB
    /// RSS the user observed. It is a *pool*, not a leak: `activeMemory` stays ~flat ≈ 1.6 GB while
    /// `cacheMemory` is the climber. `bytes` is moderate/measured (`ModelResidencyPolicy.Config`).
    func setCacheLimit(_ bytes: Int) {
        MLX.Memory.cacheLimit = bytes
        #if DEBUG
        acLog("[mlx]: cacheLimit=%d %@", bytes, Self.memorySnapshotTag())
        #endif
    }

    /// Tier 1 (the workhorse): drop the freed-buffer pool. Weights stay resident, so the only cost is the
    /// next predict re-allocating its working set from the OS instead of the pool (noise vs a ~666 ms
    /// predict). Reclaims the pool back to ~1.6 GB.
    ///
    /// The pool is **process-global**, so one `clearCache()` reclaims for both models — but it must not
    /// run while *either* container is mid-perform, which is what the cross-model gate is for
    /// ( build item 10). Taking the gate replaces the old "run it inside `container.perform`"
    /// serialization, which only covered one container.
    func flushCache() async {
        await acquirePerform()
        defer { releasePerform() }
        MLX.Memory.clearCache()
        #if DEBUG
        acLog("[mlx]: flushCache %@", Self.memorySnapshotTag())
        #endif
    }

    /// Drop the KV-cache (a fresh SSM state). Used at a context-switch boundary so hybrid snapshot reuse
    /// can never carry an un-rewindable Mamba state across windows, and as part of `unload()`. The
    /// `cacheState` mutation MUST NOT race an in-flight `perform` — that is the only way the
    /// `@unchecked Sendable` box (see `CacheState`) stays sound — so it is taken under the cross-model
    /// gate, which drains whichever container is mid-predict.
    ///
    /// Both models' caches are dropped: a context switch invalidates the FIM bridge exactly as it does
    /// the forward continuation, and leaving a stale FIM cache behind would be the one place a
    /// window-crossing SSM state could survive. Under the cross-model gate, so no perform is running on
    /// either container while the boxes are touched.
    func invalidateKVCache() async {
        await acquirePerform()
        defer { releasePerform() }
        cacheState.invalidate()
        fimCacheState.invalidate()
        #if DEBUG
        acLog("[mlx]: invalidateKVCache")
        #endif
    }

    /// Tier 2 (the deep tier): release the model weights and return all RAM to the OS (~0.2 GB idle).
    /// **Invariant ①: the `clearCache()` is load-bearing and must come last.** Dropping
    /// `container` only moves the weight buffers from `activeMemory` into the `cacheMemory` *pool* — RSS
    /// does NOT fall until `clearCache()` returns them to the OS. So: invalidate KV, drop the containers,
    /// THEN clearCache — in that order. The cross-model gate is held across all three, so no predict
    /// perform is running on either container and the trailing `clearCache()` can't race one. We
    /// deliberately do **not** set
    /// `loadFailed` — a later predict / focus pre-warm (`preload()`) must be able to reload.
    ///
    /// **Both** models are released ( build item 2): their weights are `activeMemory`, which
    /// the Tier-0 cap does *not* bound (it caps only the freed pool), so Tier 2 is the only tier that
    /// returns a loaded FIM model's ~1.1 GB to the OS. The FIM model reloads lazily on the next mid-text
    /// predict — `preload()` deliberately does not bring it back.
    ///
    /// It is also the **decided recovery boundary for a transient FIM load failure** (option
    /// (a)): a strong away-signal already means "start over", and it means the machine idled, which is
    /// when a transient cause (offline, asleep, low disk, a Hub 5xx) has most likely resolved. So the
    /// retryable half of `fimAvailability` is cleared here — and the *final* sentinel verdict is
    /// deliberately not, which `FIMModelAvailabilityTests` pins. The base model's `loadFailed` keeps
    /// its own semantics: still not set here, and still cleared only by the menu-bar `retryLoad()`.
    ///
    /// **Known residual, stated rather than hidden:** the cross-model gate is held across the clear,
    /// but it does not exclude an *in-flight* FIM container load — `loadedFIMContainer()` is awaited
    /// before `acquirePerform()`, so a load that is still hanging on the Hub when Tier 2 fires can
    /// throw afterwards and re-latch the retryable verdict, which then stands until the next
    /// away-signal. That costs a recovery in some of the very cases the split exists for; it does not
    /// re-latch the final verdict and cannot regress anything that worked before. The same window is
    /// the (pre-existing) one in which a completing load can re-assign `fimContainer` just after Tier 2
    /// nil'd it — one narrowing fixes both, and it is a change to the load's concurrency, not to this
    /// flag split.
    func unload() async {
        loadGeneration += 1
        let newGeneration = loadGeneration
        loadGenerationMirror.withLock { $0 = newGeneration }
        await baseLoadFlight.forget()  // cancels the superseded load
        yieldWarmUp()
        await acquirePerform()
        defer { releasePerform() }
        cacheState.invalidate()
        fimCacheState.invalidate()
        container = nil
        fimContainer = nil
        // Greppable at the TRANSITION rather than at the check: the early return in
        // `loadedFIMContainer` is silent on purpose — a line there would fire per mid-text keystroke —
        // so this is the one place a log can say which verdict was just cleared and which still
        // stands. Always compiled, like the other `[fim]:` lifecycle lines: it fires at most once per
        // away-signal, carries no user text, and only when a verdict was actually standing.
        if !fimAvailability.allowsLoadAttempt {
            acLog("[fim]: unload clears the retryable load failure%@",
                  fimAvailability.isUnusable
                      ? " — the no-sentinels verdict stands, this model still cannot bridge"
                      : "")
        }
        fimAvailability.clearRetryableLoadFailure()
        MLX.Memory.clearCache()
        emit(.unloaded)
        #if DEBUG
        acLog("[mlx]: unload (container released) %@", Self.memorySnapshotTag())
        #endif
    }

    #if DEBUG
    /// `Memory.snapshot()` formatted for the DEBUG log (memory instrumentation): the
    /// active / cache / peak split that proves pool-not-leak (active flat ≈ 1.6 GB while cache climbs) and
    /// confirms invariant ① after an unload (both active *and* cache fall). Cheap; DEBUG-only.
    ///
    /// `footprint` is the process's `phys_footprint`, the number Activity Monitor shows as "Memory"
    /// . It makes the residency floors readable from a `run-with-log.sh` log instead of a human
    /// watching Activity Monitor; `-1` when `task_info` fails.
    static func memorySnapshotTag() -> String {
        let s = MLX.Memory.snapshot()
        return String(format: "[mem active=%.0fMB cache=%.0fMB peak=%.0fMB footprint=%.0fMB]",
                      Double(s.activeMemory) / 1_048_576,
                      Double(s.cacheMemory) / 1_048_576,
                      Double(s.peakMemory) / 1_048_576,
                      physFootprintMB())
    }

    private static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }
    #endif

    /// The **caret-position model router** ( build item 4/5). The pure predicate lives in Core
    /// (`FIMSite`); this only dispatches on its answer, and the two arms are mutually exclusive per
    /// predict, which is what keeps the single in-flight Task intact.
    ///
    /// With `fimEnabled` false — the shipping default — `route` answers `.forward` unconditionally, so
    /// this is a single `switch` in front of the unchanged forward path.
    func predict(for context: TypingContext) async throws -> Suggestion {
        try await predict(for: context, firstWords: { _ in })
    }

    /// First-paint streaming: the forward decode hands its first `FirstPaint.words` words to
    /// `firstWords` as soon as they are finished. A FIM bridge does not stream: its stop rule
    /// (`FIMStop`) can only judge the whole middle.
    func predict(for context: TypingContext,
                 firstWords: @escaping @Sendable (Suggestion) -> Void) async throws -> Suggestion {
        yieldWarmUp()
        switch FIMSite.route(textAfterCaret: context.textAfterCaret, fimEnabled: fimEnabled) {
        case .forward:
            return try await predictForward(for: context, firstWords: firstWords, purpose: .typing)
        case .fim(let suffix):
            return try await predictFIM(for: context, suffix: suffix)
        }
    }

    /// Who asked for a forward predict: the typing loop, or the engine's own warm-up, which
    /// logs one `[mlx]: warm-up` line instead of the predict lines and leaves no KV-cache behind.
    private enum PredictPurpose { case typing, warmUp }

    private func predictForward(for context: TypingContext,
                                firstWords: @escaping @Sendable (Suggestion) -> Void,
                                purpose: PredictPurpose) async throws -> Suggestion {
        try Task.checkCancellation()

        // Flush prefix: a TRAILING-SPACE prefix craters acceptance — every model stalls or
        // restarts after a space (3–10× worse than flush). So strip trailing whitespace and predict the
        // next word from the flush position; the leading space is reconciled on the way out. Side benefit:
        // "foo" and "foo " now share one prompt, so pressing space no longer changes the ghost and the
        // prefix-KV cache reuses straight across it.
        let prefixEndedWithSpace = context.textBeforeCaret.last?.isWhitespace == true
        var flush = String(context.textBeforeCaret)
        while let last = flush.last, last.isWhitespace { flush.removeLast() }
        // Coarse up-front cap; the stable-front window re-caps after encoding.
        let prefix = String(flush.suffix(4000))
        guard !prefix.isEmpty else { return .empty }

        // Prompt-front context segments, single-encoded in front of the flush prefix (generalising the
        // windowContext and reply-context join):
        //
        //     personalization ⏎ ocrAmbient ⏎ [focusedDoc: windowContext + disjoint ocrFill] ⏎ replyContext ⏎ prefix
        //
        // The assembly — ordering, per-segment head-caps, the per-segment `contains(tail)` disjointness
        // guard, and the focusedDoc join — is pure Core (`PromptFront`), so it is unit-tested rather than
        // living inline here. No context → prompt == prefix (byte-identical to the no-context path).
        //
        // The ⏎ above is a real **document-boundary token** (`<|endoftext|>`), not `"\n\n"` — see
        // `BoundaryToken`. Core owns *which segments, in which order, capped how*; the engine owns
        // *encode and splice*, because a token id only exists once a tokenizer does.
        let front = PromptFront.assemble(
            prefix: prefix,
            personalization: context.personalization,
            windowContext: context.windowContext,
            ocrFocusedFill: context.ocrContext?.focusedFill,
            ocrAmbient: context.ocrContext?.ambient,
            replyContext: context.replyContext,
            clipboardContext: context.clipboardContext,
            budgets: PromptFront.Budgets(
                ocrAmbient: Self.ocrAmbientCharBudget,
                focusedDoc: Self.windowCharBudget,
                reply: Self.replyCharBudget,
                personalization: Self.personalizationCharBudget))
        // The segments travel to the closure UNJOINED, tagged with which source each came from: the
        // join happens at token level (the boundary token is a token id, not text — see `BoundaryToken`)
        // and the per-segment budget needs per-segment token counts, which a joined string cannot give.
        let frontSegments = front.segments
        let boundaryState = boundaryToken
        let prefixText = prefix   // captured by name for the @Sendable closure below

        // Not warm yet (or load failed) → no suggestion; preload() is bringing the model up.
        guard let container = try await loadedContainer() else {
            if purpose == .warmUp { acLog("%@", EngineWarmUp.logLine(.noModel)) }
            return .empty
        }
        // A load this predict started has just scheduled a warm-up; this predict goes first.
        if purpose == .typing { yieldWarmUp() }
        try Task.checkCancellation()

        // Greedy (temp 0 → argmax) is deterministic → a STABLE ghost; the repetition penalty prevents
        // the greedy "1.1.1.1…" loop. (Validated against Qwen3-1.7B; see the offline probe.)
        var builder = GenerateParameters()
        builder.maxTokens = 24
        builder.temperature = 0
        builder.topP = 0.9
        builder.repetitionPenalty = Self.repetitionPenalty
        builder.repetitionContextSize = Self.repetitionContextSize
        let params = builder

        let cacheState = self.cacheState
        let snapshotReuseEnabled = self.snapshotReuseEnabled   // capture locally (don't capture `self`)
        let snapshotTailMargin = self.snapshotTailMargin
        let snapshotMinAdvance = self.snapshotMinAdvance
        #if DEBUG
        // Log the lengths that ACTUALLY entered the prompt (post-cap, post-disjointness-guard), not the
        // raw source lengths — otherwise a segment dropped by the guard still reads as injected.
        let winCtxLen = front.focusedDocChars
        let replyCtxLen = front.replyChars
        let ocrCtxLen = front.ocrAmbientChars
        let styleCtxLen = front.personalizationChars
        let clipCtxLen = front.clipboardChars
        #endif
        let started = Date()

        // Drain any perform still running on the FIM container before starting ours ( item 10).
        // With FIM off only a warm-up can hold the gate, and a typing predict has cancelled it.
        await acquirePerform()
        defer { releasePerform() }
        // The warm-up leaves the cache as it found it: empty after a load. A warm-up that a real
        // predict overtook at the gate stops here, before it could wipe that predict's cache.
        if purpose == .warmUp { try Task.checkCancellation() }
        defer { if purpose == .warmUp { cacheState.invalidate() } }

        let wordCap = decodeWordCap   // read on the actor; the closure below runs on the container
        let outcome = await container.perform { ctx -> GenerationOutcome in
            // ---- Read-only phase: encode + window + plan. The cache is NOT touched yet, so a
            //      cancellation here leaves the (still-valid) cache untouched. ----
            let encodeStart = Date()
            // Resolve the document-boundary token once per model (latched on the actor after this
            // returns, via `boundaryResolution` on the outcome).
            let resolution: BoundaryResolution?
            let boundaryId: Int?
            switch boundaryState {
            case .token(let id):
                resolution = nil; boundaryId = id
            case .unavailable:
                resolution = nil; boundaryId = nil
            case .unresolved:
                let id = Self.resolveBoundaryToken(ctx.tokenizer)
                resolution = id.map { BoundaryResolution.token($0) } ?? .unavailable
                boundaryId = id
            }

            // ---- Token-level assembly, budgeted in tokens. ----
            //
            // Each front segment is encoded on its own and followed by a separator run — the
            // document-boundary token when the vocabulary has one, else the encoded `"\n\n"`. The flush
            // prefix (already trailing-whitespace-stripped) is encoded separately and
            // untouched.
            //
            // The front used to be simply *prepended* and the whole thing handed to
            // `PrefixReuse.window`, which drops from the head — so on a long document the front was
            // silently evicted, progressively, as the prefix grew (measured 136 → 8 of 392 tok inside
            // one burst). It now gets a **guaranteed token share of `windowMax`** allocated by the pure
            // `PromptFrontBudget`, and only the *prefix* is windowed, against what the front left over.
            // Same total prompt size, so first-paint is unchanged — the tokens the front takes are the
            // ones the measurement showed the prefix does not use.
            //
            // NB the fallback (no `<|endoftext|>` in the vocabulary) now also encodes per segment
            // rather than encoding one joined string. It has to: a budget needs per-segment token
            // counts, and it cannot get them out of a single encode. Joins may therefore tokenize a
            // hair differently on that path than they did before — it is the degenerate path for a
            // model without the pre-training document separator, and correctness of the budget beats
            // byte-identity there.
            let separatorTokens: [Int]
            if let boundaryId {
                separatorTokens = [boundaryId]
            } else if frontSegments.isEmpty {
                separatorTokens = []
            } else {
                separatorTokens = ctx.tokenizer.encode(text: PromptFront.textSeparator)
            }
            let encodedFront: [(kind: PromptFrontBudget.Segment, tokens: [Int])] = frontSegments.map {
                (kind: $0.kind, tokens: ctx.tokenizer.encode(text: $0.text))
            }
            // The prefix is encoded before the budget runs, because the reserve is a **floor, not a
            // ceiling**: the prefix is served first (capped at `windowMax − reserve`, which is what makes
            // the reserve untouchable) and the front then takes whatever it left. On a short surface —
            // a chat compose box — that lets the whole front through exactly as it did before this
            // change; only a prefix that wants the rest of the window pushes the front back to its
            // reserve.
            let prefixTokens = ctx.tokenizer.encode(text: prefixText)
            let allocation = PromptFrontBudget.allocate(
                windowMax: Self.windowMax,
                reserveFraction: Self.frontReserveFraction,
                segmentTokens: Dictionary(
                    encodedFront.map { ($0.kind, $0.tokens.count) }, uniquingKeysWith: +),
                prefixTokens: prefixTokens.count,
                separatorTokens: separatorTokens.count)

            // Emit in POSITIONAL order (the order `PromptFront` assembled), granting each segment what
            // the PRIORITY allocation gave it. Where a segment is shortened we keep its **head** — for
            // `focusedDoc` that is the document's beginning, the part the measurement credits with the
            // German quality gain; a `0` allowance means dropped whole (no fragment, no separator).
            var frontTokenIds: [Int] = []
            var grantedSegments = 0
            var frontSpans: [PrefixReuse.FrontSpan] = []
            for segment in encodedFront {
                let allowance = allocation.allowance(for: segment.kind)
                guard allowance > 0 else { continue }
                frontTokenIds.append(contentsOf: segment.tokens.prefix(allowance))
                frontTokenIds.append(contentsOf: separatorTokens)
                frontSpans.append(
                    .init(
                        kind: segment.kind,
                        tokens: min(allowance, segment.tokens.count) + separatorTokens.count))
                grantedSegments += 1
            }
            let frontTokens = frontTokenIds.count
            let boundaryCount = boundaryId != nil ? grantedSegments : 0

            // The prefix gets what the front left, and gets it through the SAME stable-front anchoring
            //  the whole prompt used to go through. This is load-bearing: a plain
            // `suffix(prefixAllowance)` would slide the prefix's first token by one per keystroke, so
            // the tokens right after the (now stable) front would change every time and prefix-KV-reuse
            // would diverge on every keystroke. `PrefixReuse.window` keeps the start put and re-anchors
            // in `reanchorStep` jumps instead. Free today (the shipping hybrid runs
            // `rebuild(non-trimmable)`, nothing is reused) but not once snapshot-reuse is
            // promoted — which is why it is built this way now rather than retrofitted then.
            let window = PrefixReuse.window(
                prefixTokens, max: allocation.prefixAllowance, reanchorStep: Self.reanchorStep)
            let promptTokens = frontTokenIds + window.tokens
            let encodeMs = Date().timeIntervalSince(encodeStart) * 1000
            // The front is no longer subject to the window, so what was assembled is what arrived. The
            // kept-vs-total tag stays (it is what a runtime check reads, and it is the alarm if this
            // invariant ever breaks); what the budget trimmed is reported separately.
            let frontTokensKept = frontTokens
            guard !promptTokens.isEmpty else {
                return GenerationOutcome(text: "", boundaryResolution: resolution, cancelled: false)
            }
            if Task.isCancelled {
                return GenerationOutcome(text: "", boundaryResolution: resolution, cancelled: true)
            }

            let plan = PrefixReuse.plan(cached: cacheState.tokens, next: promptTokens)
            // Where this prompt first differs from the cache, for the DEBUG reuse-miss tag.
            let firstDiff = PrefixReuse.firstDiff(
                cached: cacheState.tokens, next: promptTokens, frontSpans: frontSpans)

            // ---- Mutating phase (commit-after-prefill). The cache commit point is AFTER the
            //      prefill, not after a clean decode. Until the prefill lands, the rebuild branch keeps
            //      its new cache in a LOCAL (the committed cache stays published) and the reuse branch has
            //      trimmed the LIVE cache in place. Once the prefill's `eval` lands, the cache holds
            //      exactly `promptTokens`, so EVERY later exit — clean decode OR decode-phase cancel —
            //      commits it (a cancel WARMS the cache, renders nothing). The pure `commitDecision`
            //      encodes which of {commit, keep-old, invalidate} applies. ----
            // How to EXECUTE the plan on the cache we hold — the pure-Core decision. It
            // layers the runtime trimmability of the live cache + snapshot availability + the rollout flag
            // onto the token-level `plan`: trimmable (all-attention) → trim-reuse;
            // non-trimmable hybrid + a held snapshot whose `snapshotTokens` prefix the new prompt + flag on
            // → snapshot-reuse (on by default); else rebuild. With the flag off
            // (`defaults write … -bool NO`) the non-trimmable branch always rebuilds, the earlier
            // behaviour. Trimmability is a runtime property of the cache, so it's read
            // here, not in the pure plan.
            let existing = cacheState.cache
            let cacheTrimmable = existing.map { canTrimPromptCache($0) } ?? false
            let mode = PrefixReuse.reuseMode(
                plan: plan,
                cacheTrimmable: cacheTrimmable,
                haveCache: existing != nil,
                snapshotCoverage: cacheState.snapshot == nil ? nil : PrefixReuse.snapshotCoverage(
                    snapshotTokens: cacheState.snapshotTokens, next: promptTokens),
                snapshotReuseEnabled: snapshotReuseEnabled)

            let cache: [KVCache]
            let deltaStart: Int
            let reused: Bool
            var snapshotReused = false        // hybrid snapshot-restore reuse — DEBUG tag
            let branch: PrefixReuse.Branch
            var nonTrimmableRebuild = false   // gated off a hybrid cache — DEBUG tag
            // Why a genuine (plan-driven) rebuild happened . Nil unless a `.rebuild`
            // mode whose `nonTrimmable` is false; the non-trimmable gated rebuild keeps its own tag.
            var rebuildCause: PrefixReuse.RebuildCause? = nil
            switch mode {
            case .rebuild(let nonTrimmable):
                cache = ctx.model.newCache(parameters: params)   // local; published only at commit
                deltaStart = 0
                reused = false
                branch = .rebuild
                nonTrimmableRebuild = nonTrimmable
                // The non-trimmable gated rebuild owns its own tag; only a genuine plan rebuild splits
                // `cachedTokens == 0` (empty cache: first predict / post-invalidation / post-context-switch
                // — the "empty-cache-after-cancel" bucket that must read ~zero) vs a non-empty
                // cache whose shared prefix diverged (caret jump / mid-text edit / window re-anchor).
                if !nonTrimmable {
                    rebuildCause = PrefixReuse.rebuildCause(cachedTokens: cacheState.tokens.count)
                }
            case .trim(let reuseTokens, let trimFromCache):
                // Trimmable (all-attention) cache: trim the LIVE cache in place to the shared prefix, then
                // prefill the delta. `existing` is non-nil here — trimmable ⇒ present.
                cache = existing!
                if trimFromCache > 0 { trimPromptCache(cache, numTokens: trimFromCache) }
                deltaStart = reuseTokens
                reused = true
                branch = .reuse
            case .snapshot(let reuseTokens):
                // Non-trimmable hybrid (Mamba) snapshot-reuse. Restore the clean pre-decode
                // prompt snapshot — a FRESH `copy()` so the decode that follows dirties only this local and
                // can never perturb the stored snapshot — then prefill only the delta. No trim: `copy()`
                // rewinds the SSM state that `trimPromptCache` no-ops on. The snapshot represents exactly
                // `cacheState.snapshotTokens`, and `reuseTokens` is their coverage of the new
                // prompt (`snapshotCoverage` == `snapshotTokens.count`), so the snapshot's offset ==
                // reuseTokens and the delta appends at the right causal position. Branch is `.rebuild` for commit purposes — the
                // working cache is a local, so a pre-prefill abort keeps the committed snapshot intact
                // (keepOld), not the reuse branch's "trimmed-the-live-cache → invalidate" semantics.
                // `cacheState.snapshot` is non-nil here — snapshotCoverage gated this case.
                cache = cacheState.snapshot!.map { $0.copy() }
                deltaStart = reuseTokens
                reused = true
                snapshotReused = true
                branch = .rebuild
            }

            // Commit decision runs on EVERY exit from here on (incl. a thrown prefill-phase error — the
            // one invalidate case, in the reuse branch). `prefillLanded` gates commit vs keep-old/invalidate.
            var prefillLanded = false
            // The clean prompt-boundary snapshot captured post-prefill/pre-decode; committed
            // alongside the cache+tokens so the next snapshot reuse can restore it. Nil unless
            // snapshot-reuse is enabled and the cache is non-trimmable. Declared here so the commit `defer`
            // (registered below, run at closure exit) can publish whatever the prefill captured.
            var promptSnapshot: [KVCache]? = nil
            var promptSnapshotTokens: [Int] = []
            defer {
                // Token count in the cache = the MAX `.offset` across layers, NOT `cache.first?.offset`:
                // the shipping model (Qwen3.5) is **hybrid** — its linear-attention (Mamba)
                // layers hold a fixed-size SSM cache whose `.offset` never advances, and layer 0 is one of
                // them, so `cache.first?.offset` reads 0. The full-attention layers carry the real offset.
                let cacheOffset = cache.map(\.offset).max() ?? promptTokens.count
                let generatedKV = prefillLanded ? cacheOffset - promptTokens.count : 0
                switch PrefixReuse.commitDecision(
                    branch: branch, prefillLanded: prefillLanded, generatedKV: generatedKV) {
                case .commit(let trim):
                    // Drop the generated tokens' KV so the cache represents EXACTLY the prompt, then commit
                    // (cache + its token sequence, together) for the next call to reuse. NB: on the hybrid
                    // model `trimPromptCache` is a no-op — a non-trimmable Mamba layer makes
                    // `canTrimPromptCache` false — so the generated KV remains and the committed cache then
                    // physically holds more than `tokens` claims. That is now **inert**: the trimmability
                    // gate above forces a rebuild on every reuse against a non-trimmable cache,
                    // so this fat committed cache is never prefilled onto — it can't cause the
                    // silent divergence. (Making reuse itself correct on Mamba layers stays open:
                    // measure first, then decide.)
                    if trim > 0 { trimPromptCache(cache, numTokens: trim) }
                    // On the hybrid with a snapshot held, the dirty working cache is never prefilled onto
                    // again (reuse restores the snapshot), so keep the snapshot in its place instead of a
                    // second full cache: about 50 MB of active memory on the 4B at 520 tokens.
                    if !canTrimPromptCache(cache), let held = promptSnapshot ?? cacheState.snapshot {
                        cacheState.cache = held
                    } else {
                        cacheState.cache = cache
                    }
                    cacheState.tokens = promptTokens
                    // Publish the clean snapshot for the next snapshot reuse. Nil unless a
                    // non-trimmable cache captured one this call — on the trimmable path it's nil and the
                    // trim path reuses `cache` directly, so this leaves `snapshot` correctly empty. On the
                    // hybrid the dirty `cache` above is inert (reuse restores `snapshot`, never `cache`).
                    // A predict that takes no new snapshot keeps the held one: it still
                    // represents exactly `snapshotTokens`, and `snapshotCoverage` checks that against
                    // every new prompt, so it is never restored under the wrong tokens.
                    if let promptSnapshot {
                        cacheState.snapshot = promptSnapshot
                        cacheState.snapshotTokens = promptSnapshotTokens
                    }
                    #if DEBUG
                    // Assert the exact-prompt invariant only where the cache is actually trimmable end to
                    // end (all-attention). A non-trimmable hybrid cache can't shed the generated KV, so the
                    // invariant legitimately doesn't hold there — asserting it would crash on every predict.
                    if canTrimPromptCache(cache) {
                        assert((cache.map(\.offset).max() ?? 0) == promptTokens.count,
                               "A trimmable cache must hold exactly the prompt at commit")
                    }
                    #endif
                case .keepOld:
                    break   // rebuild aborted pre-prefill; the previously-committed cache stands
                case .invalidate:
                    cacheState.invalidate()   // reuse aborted pre-prefill; the live cache is indeterminate
                }
            }

            // Prefill only the tail (the delta on reuse; the whole prompt on rebuild). Direct model
            // forward against the (warm or fresh) cache; the cache offset drives the causal mask. The
            // split prefill runs the LM head on the last position only.
            let inputTokens = Array(promptTokens[deltaStart...])
            // Where this predict snapshots: a tail margin before the prompt end, so the word at
            // the caret, which the next keystroke re-tokenizes, falls after the snapshot. Only on a
            // non-trimmable (hybrid) cache with the flag on; the trimmable path reuses via trim.
            let snapshotAt = snapshotReuseEnabled && !canTrimPromptCache(cache)
                ? PrefixReuse.snapshotBoundary(
                    promptTokens: promptTokens.count, deltaStart: deltaStart,
                    tailMargin: snapshotTailMargin, minAdvance: snapshotMinAdvance)
                : nil
            let genStart = Date()
            let prefilled = prefillTakingSnapshot(
                ctx.model, tokens: inputTokens, cache: cache, snapshotAt: snapshotAt.map { $0 - deltaStart })
            var current = prefilled.logits   // logits for the token after the prompt, evaluated
            prefillLanded = true   // cache now holds exactly promptTokens — from here every exit commits
            let prefillMs = Date().timeIntervalSince(genStart) * 1000
            if let snapshotAt, let snap = prefilled.snapshot {
                promptSnapshot = snap
                promptSnapshotTokens = Array(promptTokens[..<snapshotAt])
            }

            // The snapshot above is CLEAN: taken inside the prefill, before the decode loop below dirties
            // the working cache (the commit point). Correctness bar:
            // **coherent + non-accumulating**, NOT token-for-token identical to from-scratch — any
            // incremental prefill can flip a near-tie greedy token via FP non-associativity (the offline
            // the offline probe shows snapshot-reuse == a no-snapshot chunked prefill; the
            // residual cold-vs-chunked diff is coherent numerics, not corruption). A future review must NOT
            // "fix" an occasional coherent divergence as a regression.

            // Faithful repetition seeding: the ring is the last `repetitionContextSize` tokens of the
            // FULL window (NOT the delta) — this is what makes reuse reproduce the from-scratch ghost.
            var processor = params.processor()
            processor?.prompt(MLXArray(promptTokens))
            let sampler = params.sampler()

            var stopTokens = ctx.configuration.eosTokenIds
            if let eos = ctx.tokenizer.eosTokenId { stopTokens.insert(eos) }
            let unknown = ctx.tokenizer.unknownTokenId

            // Hand-rolled greedy decode + clause-stop (mirrors TokenIterator.next, but with our seeding
            // and stop rule). Each step forwards one token, materialised so the cache stays bounded.
            let decodeStart = Date()
            var generated: [Int] = []
            var text = ""
            var cancelled = false
            var firstWordsAtMs: Double?
            for _ in 0 ..< (params.maxTokens ?? 24) {
                if Task.isCancelled { cancelled = true; break }
                let processed = processor?.process(logits: current) ?? current
                let tokenArr = sampler.sample(logits: processed)
                processor?.didSample(token: tokenArr)
                let tokenId = tokenArr.item(Int.self)
                if tokenId == unknown || stopTokens.contains(tokenId) { break }
                generated.append(tokenId)
                // Degeneration guard: greedy + a mild repetition penalty can still latch into a short
                // loop (":ort:ort…", "d war d war") that neither the clause-stop nor the space-based word
                // cap catches (a space-less loop is one "word" and would run to maxTokens). Detect a
                // repeated token cycle, drop the looped tail, and stop.
                // Re-decode after trimming, not just before: `text` is what gets returned, so
                // assigning only `generated` would drop the loop from the token count and leave it in
                // the ghost.
                if let trimmed = DegenerationGuard.trim(generated) {
                    generated = trimmed
                    text = ctx.tokenizer.decode(tokenIds: generated)
                    break
                }
                text = ctx.tokenizer.decode(tokenIds: generated)
                // The model finishes the phrase, then drifts into rambling / meta-commentary. Stop at
                // the first clause end AFTER content — leading boundary tokens (newline, ".") are
                // decoded through into the next clause, so a boundary-flush prefix still yields a
                // suggestion (the safety word/character cap below still bounds the decode).
                if ClauseStop.firstClause(text) != nil { break }
                if text.split(separator: " ").count > wordCap || text.count > 60 { break }
                // First-paint streaming: once the first words are finished, hand them out and
                // decode on. Same spacing reconciliation as the full result below.
                if firstWordsAtMs == nil, let early = FirstPaint.firstWords(inDecode: text, wordCap: wordCap) {
                    firstWordsAtMs = Date().timeIntervalSince(started) * 1000
                    firstWords(Suggestion(text: prefixEndedWithSpace
                        ? String(early.drop(while: { $0.isWhitespace })) : early))
                }
                let stepLogits = ctx.model(tokenArr.reshaped([1, 1]), cache: cache)
                current = stepLogits[0..., -1, 0...]
                eval(current)
            }
            let decodeMs = Date().timeIntervalSince(decodeStart) * 1000

            // Clean OR cancelled: the `defer` commits the prompt-prefix cache (a cancel warms it and
            // renders nothing — the outer `checkCancellation` throws before render). Emit empty text on a
            // cancel so nothing can leak to the ghost even if cancellation races the outer check.
            return GenerationOutcome(
                text: cancelled ? "" : text,
                firstWordsMs: firstWordsAtMs,
                promptTokens: promptTokens.count,
                prefillTokens: inputTokens.count,
                frontTokens: frontTokens,
                frontTokensKept: frontTokensKept,
                frontAllocation: allocation,
                boundaryResolution: resolution,
                boundaryCount: boundaryCount,
                reused: reused,
                reuseTokens: deltaStart,
                snapshotReused: snapshotReused,
                nonTrimmable: nonTrimmableRebuild,
                rebuildCause: rebuildCause,
                firstDiff: reused ? nil : firstDiff,
                snapshotAt: promptSnapshot == nil ? nil : promptSnapshotTokens.count,
                encodeMs: encodeMs,
                prefillMs: prefillMs,
                decodeMs: decodeMs,
                steps: generated.count,
                prefillLanded: prefillLanded,
                cancelled: cancelled)
        }
        // Latch the boundary-token verdict (see `BoundaryToken`): resolved once per model, never per
        // keystroke. Done here rather than in the closure because that closure is `@Sendable` and cannot
        // touch actor state — the same route `sentinelsMissing` takes on the FIM path.
        if let resolution = outcome.boundaryResolution {
            switch resolution {
            case .token(let id):
                boundaryToken = .token(id)
            case .unavailable:
                boundaryToken = .unavailable
                acLog("[mlx]: no %@ in vocabulary — prompt-front segments fall back to a plain join",
                      Self.endOfTextToken)
            }
        }
        if purpose == .warmUp {
            try Task.checkCancellation()
            acLog("%@", EngineWarmUp.logLine(.completed(
                totalMs: Int(Date().timeIntervalSince(started) * 1000),
                prefillMs: Int(outcome.prefillMs), decodeMs: Int(outcome.decodeMs),
                promptTokens: outcome.promptTokens, steps: outcome.steps)))
            return .empty
        }
        #if DEBUG
        // A cancelled predict throws below and emits no predict line, so the only trace it leaves is this
        // one — how far it got before bailing. `cache-mutated` / `mid-decode` mean the
        // prefill already landed (the cache is warmed/committed, NOT wiped); `encode-only` is the
        // cheap pre-cache bail. The thousands of inter-keystroke cancels under fast typing are otherwise invisible.
        if outcome.cancelled {
            acLog("[mlx]: cancel phase=%@ promptTok=%d prefillTok=%d steps=%d %@",
                  PrefixReuse.cancelPhase(prefillLanded: outcome.prefillLanded,
                                          decodeSteps: outcome.steps).rawValue,
                  outcome.promptTokens, outcome.prefillTokens, outcome.steps, Self.memorySnapshotTag())
        }
        #endif
        try Task.checkCancellation()

        // Keep only the first clause AFTER content (cuts the drift; leading boundary tokens belong
        // to the continuation); return the WHOLE clause as the continuation buffer
        // (≤`ContinuationBuffer.maxWords`, a Core constant
        // because the copy guard's threshold is argued from it). The visible
        // display window is applied in Core (`DisplayWindow`), so the over-decoded tail is buffered
        // for `Tab`, not discarded.
        // `trimToWords` flattens newlines to single spaces — load-bearing: a
        // suggestion never inserts a synthetic Return (chat compose fields send on Return).
        // The gate's arm 2, read HERE because `trimToWords` below flattens the leading boundary run to a
        // space (a ghost must never insert a Return) and the break is gone by the time
        // Core sees the text. Carried on `Suggestion` as one Bool; `SuggestionSession` decides.
        // Reads the raw decode past any `<think>` block (whose own newlines are not a break signal);
        // the shaping expression below is left composed exactly as it was. `predictFIM` mirrors this
        // ordering on its own raw middle: **both arms apply to a bridge too**.
        // The comment that used to stand here justified the FIM
        // omission with "`predictFIM` has its own stop logic in `FIMStop`", which was a non sequitur —
        // that the *stop* logic differs says nothing about whether a structural break means something
        // on a bridge, and the answer decided is that it does.
        let abandonsRunningThought = RunningThoughtGate.abandonsRunningThought(
            rawDecode: stripThink(outcome.text))
        var result = ClauseStop.trimToWords(
            stripThink(ClauseStop.firstClause(outcome.text) ?? outcome.text),
            max: wordCap)
        // The spacing reconciliation: at a whitespace caret drop the model's leading space so
        // the ghost isn't double-spaced; at a flush caret keep it (one space after the word).
        //
        // The old render guard used to sit in front of this and threw the whole suggestion away
        // when a boundary-punctuation lead would land separated from the word. It is gone
        // : the archived counter it shipped for read 7 suppressions in 103
        // predicts, 4 of them complete sentences, so the case is joined rather than discarded — by
        // `BoundaryLeadJoin` in the reducer, which has the prefix in hand and can turn the verdict into
        // a replace-backwards accept. Nothing here decides it any more.
        if prefixEndedWithSpace {
            result = String(result.drop(while: { $0.isWhitespace }))
        }
        #if DEBUG
        let cacheTag = Self.cacheTag(for: outcome)
        let isBoundaryAvailable: Bool = { if case .token = boundaryToken { return true }; return false }()
        acLog(
            "[mlx]: predict total=%.0fms (encode=%.0f prefill=%.0f decode=%.0f) first=%@ cap=%d "
                + "promptTok=%d/winMax%d %@ prefillTok=%d %@ %@ %@ "
                + "built(winCtx=%d replyCtx=%d ocrCtx=%d styleCtx=%d clipCtx=%d) "
                + "rep=%.2f/ctx%d steps=%d %@ → \"%@\"",
            Date().timeIntervalSince(started) * 1000,
            outcome.encodeMs, outcome.prefillMs, outcome.decodeMs,
            outcome.firstWordsMs.map { String(format: "%.0fms", $0) } ?? "-", wordCap,
            outcome.promptTokens, Self.windowMax, cacheTag,
            outcome.prefillTokens,
            Self.frontTag(kept: outcome.frontTokensKept, total: outcome.frontTokens),
            Self.frontBudgetTag(outcome.frontAllocation),
            Self.boundaryTag(count: outcome.boundaryCount, available: isBoundaryAvailable),
            winCtxLen, replyCtxLen, ocrCtxLen, styleCtxLen, clipCtxLen,
            Double(Self.repetitionPenalty), Self.repetitionContextSize, outcome.steps,
            Self.memorySnapshotTag(), result)
        if abandonsRunningThought {
            acLog("[mlx]: running-thought break in the leading decode run → \"%@\"", result)
        }
        #endif
        return Suggestion(text: result, abandonsRunningThought: abandonsRunningThought)
    }

    // MARK: - Mid-text bridge (FIM) — build item 5

    /// Generate a **mid-text bridge**: the middle that joins the prefix `P` to the suffix `S` already in
    /// the document. Reached only when `fimEnabled` is on *and* `FIMSite` found real text in the caret's
    /// paragraph, so with the shipping default this function is dead code.
    ///
    /// Three things differ from the forward path, all of them deliberate design decisions:
    ///
    ///   - **`textAfterCaret` stops being dropped.** It is the whole point: `S` (the paragraph slice
    ///     `FIMSite` already computed, so the router and the prompt cannot disagree about where it ends)
    ///     is encoded into the sentinel block and gets ~¼ of the token budget.
    ///   - **No prompt-front context.** `windowContext`/reply/OCR/personalization are the forward path's
    ///     `PromptFront`; FIM v1 is the local block only, which also keeps the pinned front small enough
    ///     that pinning is worth anything.
    ///   - **A different stop rule.** Forward continuation stops at a clause end because nothing follows
    ///     the caret; a bridge's real terminator is `S` itself, so `FIMStop` (sentinels + the
    ///     `stopAtStartOf(S)` duplication guard) replaces `ClauseStop.firstClause` here. The word/char
    ///     safety caps stay — they are what bounds a bridge that never finds its wall.
    ///
    /// Kept as its own function rather than folded into `predictForward` with flags: the two share the
    /// cache/commit machinery but essentially nothing of the prompt or the stop rule, and the forward
    /// path has to stay byte-identical under a feature that ships off.
    private func predictFIM(for context: TypingContext, suffix: String) async throws -> Suggestion {
        try Task.checkCancellation()

        // **`P` is NOT flushed here — deliberately, and unlike the forward path.** The spacing rule strips the
        // caret's trailing whitespace before a *forward* predict because a base model asked to continue
        // after a space tends to restart rather than continue. That argument does not survive the move
        // to FIM: a bridge is anchored on the right by `S`, so the model is not guessing what comes
        // next — it is joining two known sides, and the trailing space is the only thing telling it
        // whether the caret sits **after** a word or **inside** one. Strip it and the two become
        // indistinguishable, so the model completes the last word instead of bridging: measured on
        // Qwen2.5-Coder-1.5B, `config` → `uration file`, `Konfiguration` → `sdatei`, `Kurier` →
        // `sverkehr` — 0/7 fixtures reassembled grammatically, where the same fixtures with the space
        // preserved produced usable bridges. (the 2026-08-24 (b) comment.)
        //
        // KV-reuse survives this. That strip also bought "foo" and "foo " one shared prompt;
        // here `P` is the *growing* side of the SPM block, so typing into it is the append case
        // `PrefixReuse.plan` is built for. A typed space does move the tokenizer's last token
        // (`[foo]` → `[foo, ▁]` → `[foo, ▁bar]`), so the plan trims and re-prefills **one** token
        // instead of zero — the pinned `<fim_suffix> S <fim_prefix>` front, which is what the ordering
        // was chosen to protect, is untouched either way.
        //
        // The forward path keeps its flush verbatim: this function exists so that a feature shipping
        // off cannot move it.
        let prefixEndedWithSpace = context.textBeforeCaret.last?.isWhitespace == true
        let prefixText = String(context.textBeforeCaret.suffix(4000))
        // Emptiness is judged on the *content*, not the raw string: a caret preceded by nothing but
        // whitespace has no left-hand side to bridge from, and without this it would now survive the
        // guard that the strip used to collapse.
        guard prefixText.contains(where: { !$0.isWhitespace }) else { return .empty }

        // Strictly lazy: this is the *only* thing that loads the FIM model. A missing/failed FIM model
        // shows no bridge and leaves the forward path untouched.
        guard let container = try await loadedFIMContainer() else { return .empty }
        try Task.checkCancellation()

        var builder = GenerateParameters()
        builder.maxTokens = 24
        builder.temperature = 0
        builder.topP = 0.9
        builder.repetitionPenalty = Self.repetitionPenalty
        builder.repetitionContextSize = Self.repetitionContextSize
        let params = builder

        let cacheState = self.fimCacheState
        let snapshotReuseEnabled = self.snapshotReuseEnabled
        let snapshotTailMargin = self.snapshotTailMargin
        let snapshotMinAdvance = self.snapshotMinAdvance
        let ordering = self.fimOrdering
        let suffixText = suffix
        let started = Date()

        await acquirePerform()
        defer { releasePerform() }

        let wordCap = decodeWordCap   // read on the actor; the closure below runs on the container
        let outcome = await container.perform { ctx -> GenerationOutcome in
            // ---- Read-only phase: resolve, encode, window, plan. The cache is untouched. ----
            let encodeStart = Date()
            // Sentinels come from THIS model's vocabulary, never the base model's — the two need not
            // agree, and a wrong id yields a prompt that still decodes but is no longer an infill.
            // Fail-closed (`Sentinels` rejects a missing or `<unk>`-resolving id): a model that can't
            // do FIM produces no bridge rather than a forward predict wearing FIM sentinels.
            guard let sentinels = FIMPrompt.Sentinels(
                prefix: ctx.tokenizer.convertTokenToId(Self.fimPrefixToken),
                suffix: ctx.tokenizer.convertTokenToId(Self.fimSuffixToken),
                middle: ctx.tokenizer.convertTokenToId(Self.fimMiddleToken),
                unknown: ctx.tokenizer.unknownTokenId)
            else {
                return GenerationOutcome(text: "", cancelled: false, sentinelsMissing: true)
            }

            let suffixTokens = FIMPrompt.capSuffix(
                ctx.tokenizer.encode(text: suffixText),
                budget: FIMPrompt.suffixTokenBudget(windowMax: Self.windowMax))
            let prefixTokens = ctx.tokenizer.encode(text: prefixText)
            let layout = FIMPrompt.layout(
                ordering: ordering, sentinels: sentinels,
                suffixTokens: suffixTokens, prefixTokens: prefixTokens)
            // The S-pinning window (build item 6): caps the `P`-head — the oldest tokens, farthest from
            // the caret — instead of front-dropping, which here would eat the sentinels and then `S`.
            let window = PrefixReuse.fimWindow(
                pinned: layout.pinned, prefix: layout.growing, trailing: layout.trailing,
                max: Self.windowMax, reanchorStep: Self.reanchorStep)
            let promptTokens = window.tokens
            let encodeMs = Date().timeIntervalSince(encodeStart) * 1000
            guard !promptTokens.isEmpty else { return GenerationOutcome(text: "", cancelled: false) }
            if Task.isCancelled { return GenerationOutcome(text: "", cancelled: true) }

            // Under PSM, `P` grows in the *middle* of the prompt, so every keystroke shifts `S` and the
            // trailing sentinels: the shared run stops at the caret and all but a few tokens re-prefill.
            // The ticket's answer is to stop pretending that is a reuse (build item 6).
            let plan = layout.reuseEligible
                ? PrefixReuse.plan(cached: cacheState.tokens, next: promptTokens)
                : PrefixReuse.Plan.rebuild

            let existing = cacheState.cache
            let cacheTrimmable = existing.map { canTrimPromptCache($0) } ?? false
            let mode = PrefixReuse.reuseMode(
                plan: plan,
                cacheTrimmable: cacheTrimmable,
                haveCache: existing != nil,
                snapshotCoverage: cacheState.snapshot == nil ? nil : PrefixReuse.snapshotCoverage(
                    snapshotTokens: cacheState.snapshotTokens, next: promptTokens),
                snapshotReuseEnabled: snapshotReuseEnabled)

            let cache: [KVCache]
            let deltaStart: Int
            let reused: Bool
            var snapshotReused = false
            let branch: PrefixReuse.Branch
            var nonTrimmableRebuild = false
            var rebuildCause: PrefixReuse.RebuildCause? = nil
            switch mode {
            case .rebuild(let nonTrimmable):
                cache = ctx.model.newCache(parameters: params)
                deltaStart = 0
                reused = false
                branch = .rebuild
                nonTrimmableRebuild = nonTrimmable
                if !nonTrimmable {
                    rebuildCause = PrefixReuse.rebuildCause(cachedTokens: cacheState.tokens.count)
                }
            case .trim(let reuseTokens, let trimFromCache):
                // The expected SPM steady state. Note `trimFromCache` is never 0 here — the prompt ends
                // in the fixed `<fim_middle>`, so a `P`-append is never a *pure* append; the stale
                // sentinel is trimmed and `δ + <fim_middle>` prefills.
                cache = existing!
                if trimFromCache > 0 { trimPromptCache(cache, numTokens: trimFromCache) }
                deltaStart = reuseTokens
                reused = true
                branch = .reuse
            case .snapshot(let reuseTokens):
                cache = cacheState.snapshot!.map { $0.copy() }
                deltaStart = reuseTokens
                reused = true
                snapshotReused = true
                branch = .rebuild
            }

            // Commit-after-prefill, identical to the forward path and against this model's
            // own `CacheState` — no cross-model bleed is possible, the boxes are distinct.
            var prefillLanded = false
            var promptSnapshot: [KVCache]? = nil
            var promptSnapshotTokens: [Int] = []
            defer {
                let cacheOffset = cache.map(\.offset).max() ?? promptTokens.count
                let generatedKV = prefillLanded ? cacheOffset - promptTokens.count : 0
                switch PrefixReuse.commitDecision(
                    branch: branch, prefillLanded: prefillLanded, generatedKV: generatedKV) {
                case .commit(let trim):
                    if trim > 0 { trimPromptCache(cache, numTokens: trim) }
                    // On the hybrid with a snapshot held, the dirty working cache is never prefilled onto
                    // again (reuse restores the snapshot), so keep the snapshot in its place instead of a
                    // second full cache: about 50 MB of active memory on the 4B at 520 tokens.
                    if !canTrimPromptCache(cache), let held = promptSnapshot ?? cacheState.snapshot {
                        cacheState.cache = held
                    } else {
                        cacheState.cache = cache
                    }
                    cacheState.tokens = promptTokens
                    if let promptSnapshot {
                        cacheState.snapshot = promptSnapshot
                        cacheState.snapshotTokens = promptSnapshotTokens
                    }
                case .keepOld:
                    break
                case .invalidate:
                    cacheState.invalidate()
                }
            }

            let inputTokens = Array(promptTokens[deltaStart...])
            // Same snapshot boundary as the forward path. On SPM it also clears the trailing
            // `<fim_middle>`, which made a prompt-end snapshot unusable there.
            let snapshotAt = snapshotReuseEnabled && !canTrimPromptCache(cache)
                ? PrefixReuse.snapshotBoundary(
                    promptTokens: promptTokens.count, deltaStart: deltaStart,
                    tailMargin: snapshotTailMargin, minAdvance: snapshotMinAdvance)
                : nil
            let genStart = Date()
            let prefilled = prefillTakingSnapshot(
                ctx.model, tokens: inputTokens, cache: cache, snapshotAt: snapshotAt.map { $0 - deltaStart })
            var current = prefilled.logits   // logits-skip split inside
            prefillLanded = true
            let prefillMs = Date().timeIntervalSince(genStart) * 1000
            if let snapshotAt, let snap = prefilled.snapshot {
                promptSnapshot = snap
                promptSnapshotTokens = Array(promptTokens[..<snapshotAt])
            }

            var processor = params.processor()
            processor?.prompt(MLXArray(promptTokens))
            let sampler = params.sampler()

            // The FIM stop set (`FIMStop.stopTokens`) plus the model's ordinary EOS. `<fim_middle>` is
            // passed but deliberately excluded there — it *opens* the middle, so halting on it would end
            // every generation at step 0.
            let unknown = ctx.tokenizer.unknownTokenId
            // `convertTokenToId` answers `<unk>` for a token the vocabulary lacks, so a model without a
            // `<|fim_pad|>` would otherwise contribute the unknown id as a "stop" — harmless here but
            // misleading, and exactly the trap `Sentinels` guards against. Resolve them the same way.
            let resolve = { (token: String) -> Int? in
                let id = ctx.tokenizer.convertTokenToId(token)
                return id == unknown ? nil : id
            }
            var stopTokens = FIMStop.stopTokens(
                fimPad: resolve(Self.fimPadToken),
                endOfText: resolve(Self.endOfTextToken),
                fimPrefix: sentinels.prefix,
                fimSuffix: sentinels.suffix,
                fimMiddle: sentinels.middle)
            stopTokens.formUnion(ctx.configuration.eosTokenIds)
            if let eos = ctx.tokenizer.eosTokenId { stopTokens.insert(eos) }

            let decodeStart = Date()
            var generated: [Int] = []
            var text = ""
            var cancelled = false
            for _ in 0 ..< (params.maxTokens ?? 24) {
                if Task.isCancelled { cancelled = true; break }
                let processed = processor?.process(logits: current) ?? current
                let tokenArr = sampler.sample(logits: processed)
                processor?.didSample(token: tokenArr)
                let tokenId = tokenArr.item(Int.self)
                if tokenId == unknown || stopTokens.contains(tokenId) { break }
                generated.append(tokenId)
                // Re-decode after trimming, not just before: `text` is what gets returned, so assigning
                // only `generated` would drop the loop from the token count and leave it in the ghost.
                // (The forward path at `predictForward` carries the same shape — it was corrected
                // the same way; both call the Core `DegenerationGuard.trim`.)
                if let trimmed = DegenerationGuard.trim(generated) {
                    generated = trimmed
                    text = ctx.tokenizer.decode(tokenIds: generated)
                    break
                }
                text = ctx.tokenizer.decode(tokenIds: generated)
                // `stopAtStartOf(S)` — the bridge has run into the text it was supposed to join, so stop
                // and drop the duplicated run. This is the dominant FIM defect (ticket 06): a middle that
                // re-emits `S` reads fluent in isolation and broken in the document.
                if case .stop(let deduplicated) = FIMStop.check(middle: text, suffix: suffixText) {
                    text = deduplicated
                    break
                }
                // Safety caps only — no clause-stop. A bridge legitimately spans a comma to reach `S`,
                // so cutting at the first clause end would truncate correct middles; `FIMStop` above is
                // the real terminator and these bound the case where it never fires.
                if text.split(separator: " ").count > wordCap || text.count > 60 { break }
                let stepLogits = ctx.model(tokenArr.reshaped([1, 1]), cache: cache)
                current = stepLogits[0..., -1, 0...]
                eval(current)
            }
            let decodeMs = Date().timeIntervalSince(decodeStart) * 1000

            return GenerationOutcome(
                text: cancelled ? "" : text,
                promptTokens: promptTokens.count,
                prefillTokens: inputTokens.count,
                reused: reused,
                reuseTokens: deltaStart,
                snapshotReused: snapshotReused,
                nonTrimmable: nonTrimmableRebuild,
                rebuildCause: rebuildCause,
                encodeMs: encodeMs,
                prefillMs: prefillMs,
                decodeMs: decodeMs,
                steps: generated.count,
                prefillLanded: prefillLanded,
                cancelled: cancelled,
                suffixTokens: suffixTokens.count,
                prefixHeadDropped: window.prefixHeadDropped)
        }

        if outcome.sentinelsMissing {
            // The **final** verdict, and the only writer of it: a vocabulary does not grow,
            // so this is settled for this model and no recovery path — the Tier-2 `unload()` included —
            // may clear it. Without the latch every mid-text keystroke would re-enter `perform` under
            // the cross-model gate (delaying the forward predict behind it) to re-derive the same answer,
            // spam an always-compiled log line, and — worst — keep ~1.1 GB of a model that can never
            // produce a bridge resident until the memory ladder's Tier 2 fires. Releasing it here
            // returns that immediately; `unload()`'s clearCache is not needed because the base model's
            // pool cap still governs and a Tier-1 flush will reclaim the freed buffers.
            fimAvailability.recordUnusable()
            fimContainer = nil
            acLog("[fim]: no FIM sentinels in %@ — this model cannot bridge, disabled for good",
                  fimModelDirectory.lastPathComponent)
            return .empty
        }
        #if DEBUG
        if outcome.cancelled {
            acLog("[fim]: cancel phase=%@ promptTok=%d prefillTok=%d steps=%d",
                  PrefixReuse.cancelPhase(prefillLanded: outcome.prefillLanded,
                                          decodeSteps: outcome.steps).rawValue,
                  outcome.promptTokens, outcome.prefillTokens, outcome.steps)
        }
        #endif
        try Task.checkCancellation()

        // The gate's arm 2 on the bridge, read HERE for the same reason the forward path reads it before
        // `ClauseStop.trimToWords`: `FIMStop.finalize` below flattens the leading boundary run to a
        // space (never a synthetic Return), so a signal computed after the shaping is
        // always `false`. It used to be *defaulted* rather than computed, which made every bridge assert
        // that its decode had not abandoned the running thought — a claim nobody measured, on the path
        // that writes into the MIDDLE of the user's own text (the
        // defaulted-flag trap). The *reason* the order is load-bearing
        // is pinned in Core (`RunningThoughtGateOnTheFIMPathTests` shapes a break-carrying middle and
        // finds the signal gone); this call **site** is not pinned by anything — no test in either
        // target reaches `predictFIM` — so moving the line below `finalize` would silently answer
        // `false` forever and stay green. Read the Core test before touching this ordering.
        let abandonsRunningThought = RunningThoughtGate.abandonsRunningThought(
            rawDecode: stripThink(outcome.text))
        // Shape the raw middle: flatten (never a Return) → de-duplicate against `S` → word-cap →
        // value-gate. The order is load-bearing and lives in Core (`FIMStop.finalize`). `nil` means
        // "show nothing", which is also what an all-whitespace bridge collapses to.
        var result = FIMStop.finalize(
            middle: stripThink(outcome.text), suffix: suffixText,
            maxWords: wordCap) ?? ""
        // Same left-hand reconciliation as forward: the argument — an
        // insert-only accept would commit "Winter. Es" — is about the *caret* side of the join, which
        // mid-text is identical. Note the two clauses do different work here than on the forward path,
        // because `P` is no longer flushed (see the top of this function): the model already saw the
        // caret's trailing space, so a leading space in `result` is now the exception rather than the
        // rule, and the `drop` is a double-space guard rather than the routine reconciliation it is
        // forward. The boundary-lead decision has moved out of both paths into `BoundaryLeadJoin` in
        // the reducer, which reads the caret, not the prompt, and so is
        // identical for a bridge. The right-hand `middle|S` join belongs to `FIMAccept.terminalJoin` at
        // accept time, and is now wired there — `SuggestionSession.apply` routes every
        // `.insertContinuation` through `FIMAccept.insertionText`, which appends the separator on the
        // accept that empties the bridge buffer (build item 9). It has never run against a real FIM
        // model — no such weights exist on a dev machine yet — so it is pinned by Core tests only.
        if prefixEndedWithSpace {
            result = String(result.drop(while: { $0.isWhitespace }))
        }
        #if DEBUG
        acLog(
            "[fim]: bridge total=%.0fms (encode=%.0f prefill=%.0f decode=%.0f) ordering=%@ "
                + "promptTok=%d %@ prefillTok=%d suffixTok=%d pHeadDropped=%d steps=%d %@ → \"%@\"",
            Date().timeIntervalSince(started) * 1000,
            outcome.encodeMs, outcome.prefillMs, outcome.decodeMs, ordering.rawValue,
            outcome.promptTokens, Self.cacheTag(for: outcome), outcome.prefillTokens,
            outcome.suffixTokens, outcome.prefixHeadDropped, outcome.steps,
            Self.memorySnapshotTag(), result)
        if abandonsRunningThought {
            acLog("[fim]: running-thought break in the leading middle run → \"%@\"", result)
        }
        #endif
        return Suggestion(text: result, abandonsRunningThought: abandonsRunningThought)
    }

    #if DEBUG
    /// The cache-path tag shared by both predict paths: `REUSE(n)` for a trim-reuse, `REUSE(snapshot)`
    /// for an hybrid snapshot restore, otherwise a rebuild split by cause —
    /// `rebuild(non-trimmable)` (the hybrid gate) vs `rebuild(empty)`/`rebuild(divergence)`
    /// (the genuine plan-rebuild split).
    /// How much of the context front actually reached the model, as `front=<kept>/<total>tok` plus a
    /// greppable verdict when the stable-front window ate into it.
    ///
    /// Exists because the per-segment `winCtx=`/`styleCtx=`/… numbers are **pre-window**: they say what
    /// `PromptFront` assembled, not what survived. On a long focused document the front is the head of
    /// the prompt and the window drops from the head, so those numbers can read full while the model saw
    /// none of it (found in a real Notes session where the front alone
    /// was ~570 tok against a 516-tok windowed prompt). The tag makes that unmistakable — and it is the
    /// number to read, not the per-segment ones, which are now printed under `built(…)`.
    /// Whether the **document boundary** was actually in this prompt:
    /// `boundary=eot bounds=<n>` when the model's `<|endoftext|>` id was spliced after each of the `n`
    /// front segments, `boundary=none` when the vocabulary had no usable id (plain `"\n\n"` join — the
    /// pre-fix prompt). `bounds=0` with `boundary=eot` simply means the front was empty this predict.
    /// A runtime check has to be able to tell the two arms apart from the log alone.
    private static func boundaryTag(count: Int, available: Bool) -> String {
        available ? "boundary=eot bounds=\(count)" : "boundary=none bounds=0"
    }

    private static func frontTag(kept: Int, total: Int) -> String {
        guard total > 0 else { return "front=none" }
        if kept == 0 { return "front=0/\(total)tok(EVICTED)" }
        if kept < total { return "front=\(kept)/\(total)tok(truncated)" }
        return "front=\(kept)/\(total)tok"
    }

    /// What the token budget had to do to make the front fit:
    /// `frontbudget=<granted>/<allowance>tok res=<reserve> req=<wanted>tok seg=doc:153/380 reply:0/120 …`.
    ///
    /// `<allowance>` is the ceiling that applied on this call and `res=` the guaranteed floor; the two
    /// differ whenever the prefix was short enough to leave the front more than its reserve, which is
    /// how a run can be read as "the front fitted anyway" rather than "the front was clamped".
    ///
    /// `front=` alone can no longer show a squeezed front — it fits by construction now — so the
    /// trimming has to be visible here or it is invisible. Per segment: `<granted>/<requested>`, with
    /// `0/<requested>` meaning dropped whole (below `minimumSegmentTokens`) rather than fragmented.
    /// Only segments that asked for tokens are listed; `frontbudget=none` when none did.
    private static func frontBudgetTag(_ allocation: PromptFrontBudget.Allocation?) -> String {
        guard let allocation, allocation.requestedTokens > 0 else { return "frontbudget=none" }
        let segments = PromptFrontBudget.priority.compactMap { segment -> String? in
            guard let want = allocation.requested[segment], want > 0 else { return nil }
            return "\(segment.rawValue):\(allocation.allowance(for: segment))/\(want)"
        }
        return "frontbudget=\(allocation.frontTokens)/\(allocation.frontAllowance)tok "
            + "res=\(allocation.reserve) req=\(allocation.requestedTokens)tok seg="
            + segments.joined(separator: " ")
    }

    private static func cacheTag(for outcome: GenerationOutcome) -> String {
        // `snapAt=<n>`: this predict took a new snapshot of the first n prompt tokens.
        let snap = outcome.snapshotAt.map { " snapAt=\($0)" } ?? ""
        if outcome.reused {
            return outcome.snapshotReused
                ? "REUSE(snapshot) covered=\(outcome.reuseTokens)" + snap
                : "REUSE(\(outcome.reuseTokens))"
        }
        let diff = outcome.firstDiff.map { " " + $0.logTag } ?? ""
        if outcome.nonTrimmable { return "rebuild(non-trimmable)" + diff + snap }
        if let cause = outcome.rebuildCause { return "rebuild(\(cause.rawValue))" + diff + snap }
        return "rebuild" + diff + snap
    }
    #endif
}

// MARK: - Instrumentation

/// The document-boundary token verdict for a model's vocabulary — resolved inside the `perform`
/// closure, latched on the actor.
private enum BoundaryResolution: Sendable {
    case token(Int)
    case unavailable
}

/// Per-prediction result + latency split, returned from the `@Sendable` `perform` closure (so MLXArrays
/// never escape the model actor — only this `Sendable` summary does). `prefillTokens` is the count
/// actually prefilled (the delta on a reuse, the whole prompt on a rebuild); `reused`/`reuseTokens`
/// record how much KV-cache was carried over — the field signal for reuse.
private struct GenerationOutcome: Sendable {
    var text: String
    /// When the first-paint words were handed out, in ms since the predict started; `nil` when
    /// the decode streamed nothing.
    var firstWordsMs: Double? = nil
    var promptTokens: Int = 0
    var prefillTokens: Int = 0
    /// Tokens the **prompt front** (personalization + ocrAmbient + focusedDoc + reply) occupies after
    /// the token budget, and how many of them survived the window. The
    /// front is no longer windowed — the prefix is, against what the front left — so these are equal by
    /// construction and an inequality is an alarm, not a normal reading. They stay because that
    /// invariant is exactly what a runtime check reads (the per-segment
    /// char counts under `built(…)` describe what was *built*, and cannot see the token window).
    var frontTokens: Int = 0
    var frontTokensKept: Int = 0
    /// What each front segment asked for in tokens and what the ``PromptFrontBudget`` reserve granted it
    /// . The `front=` tag says the front arrived; this says what it cost
    /// to make it fit — which segment was trimmed to its head and which was dropped whole.
    var frontAllocation: PromptFrontBudget.Allocation? = nil
    /// The document-boundary token verdict, when this predict was the one that resolved it — `nil` once
    /// the actor has latched it. Carried out of the `@Sendable` closure because actor state is
    /// unreachable inside it (same route as `sentinelsMissing`).
    var boundaryResolution: BoundaryResolution? = nil
    /// How many boundary tokens were spliced into the prompt — one per front segment, `0` when the front
    /// was empty or the token was unavailable.
    var boundaryCount: Int = 0
    var reused: Bool = false
    var reuseTokens: Int = 0
    /// Whether the reuse was an hybrid **snapshot-restore** (vs the trimmable trim-reuse).
    /// Only meaningful when `reused` — splits the DEBUG tag `REUSE(snapshot)` from `REUSE(n)`.
    var snapshotReused: Bool = false
    /// A rebuild forced by the trimmability gate — the cache was non-trimmable
    /// (hybrid Mamba), so reuse was skipped. Distinguishes a gated rebuild from a plan-driven one in the
    /// DEBUG log; always `false` on the all-attention probe model.
    var nonTrimmable: Bool = false
    /// Why a *genuine* (plan-driven) rebuild happened — empty cache vs prefix divergence.
    /// Nil on a reuse or the non-trimmable gated rebuild (which has its own tag).
    var rebuildCause: PrefixReuse.RebuildCause? = nil
    /// Where the new prompt first differs from the cache on a miss. Nil on a reuse and on
    /// the FIM path.
    var firstDiff: PrefixReuse.FirstDiff? = nil
    /// Where this predict took its hybrid snapshot, nil when it took none (flag off, trimmable
    /// cache, or the held snapshot was kept). DEBUG `snapAt=<n>`.
    var snapshotAt: Int? = nil
    var encodeMs: Double = 0
    var prefillMs: Double = 0
    var decodeMs: Double = 0
    var steps: Int = 0
    /// Whether the prefill's `eval` landed — the gate the cancel-phase tag reads:
    /// after it, a cancel leaves the cache warmed/committed, not wiped.
    var prefillLanded: Bool = false
    var cancelled: Bool
    /// FIM path only ( item 5): the FIM model's vocabulary carried no `<|fim_*|>` sentinels, so
    /// no infill prompt could be built. Distinct from an empty result — it is a *configuration* fault
    /// (the wrong model is pointed at), and it is always logged rather than only in DEBUG.
    var sentinelsMissing: Bool = false
    /// FIM path only: how many tokens of the suffix `S` entered the prompt after the ~¼-budget cap, and
    /// how many `P`-head tokens the S-pinning window dropped (non-zero only on a re-anchor, so it
    /// doubles as the "the front moved this keystroke" signal).
    var suffixTokens: Int = 0
    var prefixHeadDropped: Int = 0
}

// MARK: - Output shaping (pure, file-private)

// The clause-stop rule (`firstClause`), the word trim (`trimToWords` — its newline→space flatten is
// the load-bearing never-a-Return invariant), and the suppress predicate all moved
// to pure Core as `ClauseStop` (unit-tested there, which keeps the
// logic in Core).

/// Defensive guard: Qwen's thinking-mode shouldn't fire on a raw prefix, but strip `<think>…</think>`
/// (or an unterminated `<think>`) if it ever appears.
private func stripThink(_ s: String) -> String {
    guard let open = s.range(of: "<think>") else { return s }
    if let close = s.range(of: "</think>") {
        return String(s[..<open.lowerBound]) + String(s[close.upperBound...])
    }
    return String(s[..<open.lowerBound])
}

/// Passes every download to the wrapped downloader and remembers the directory it returned, which is
/// the Hub cache snapshot the weights load from. `loadContainer` does not report that path itself.
private final class DownloadedDirectoryRecorder: Downloader, @unchecked Sendable {
    private let wrapped: any Downloader
    private let lock = NSLock()
    private var directories: [URL] = []

    /// Start of the load. A cached file older than this was not fetched by it.
    private let startedAt = Date()

    init(wrapping wrapped: any Downloader) { self.wrapped = wrapped }

    /// How many files in the returned snapshots were written since the recorder was created. A Hub
    /// snapshot holds symlinks into `blobs/`; a re-download writes new blobs, a cache hit touches none.
    /// This does not depend on the downloader's progress callbacks.
    func freshFileCount() -> Int {
        let dirs = lock.withLock { directories }
        let cutoff = startedAt.addingTimeInterval(-2)
        var count = 0
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let real = item.resolvingSymlinksInPath()
                let modified = (try? real.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                if let modified, modified >= cutoff { count += 1 }
            }
        }
        return count
    }

    /// The first directory returned: the model repository (a tokenizer download, if any, comes second).
    var firstDirectory: URL? {
        lock.withLock { directories.first }
    }

    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let url = try await wrapped.download(
            id: id, revision: revision, matching: patterns, useLatest: useLatest,
            progressHandler: progressHandler)
        lock.withLock { directories.append(url) }
        return url
    }
}
