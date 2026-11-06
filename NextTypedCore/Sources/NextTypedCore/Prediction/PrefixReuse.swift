/// Pure, token-level decision logic for **prefix-KV-cache reuse** in the on-device prediction engine.
/// The MLX engine itself lives in the app target and is
/// inherently untestable (it needs the model + Metal), so the *arithmetic it delegates to* — where the
/// bugs would hide: off-by-one cache trims, divergence detection, window anchoring — lives here and is
/// unit-tested with no model.
///
/// Two pieces work together:
///   1. ``window(_:max:reanchorStep:)`` picks the prompt token window with a **stable front**, so
///      successive keystrokes keep an identical leading prefix.
///   2. ``plan(cached:next:)`` decides how much of the existing KV-cache that stable prefix lets us
///      reuse, and how much tail to (re)prefill.
///
/// Tokens are opaque integers (the tokenizer's ids); this file never interprets them.
public enum PrefixReuse {

    // MARK: - Stable-front prompt window

    /// A bounded token window with a **stable front** — the prompt fed to the model.
    public struct Window: Equatable, Sendable {
        /// Index into the full token array where the window begins (the anchor).
        public let start: Int
        /// The windowed tokens, `full[start...]`. Length is `≤ windowMax + reanchorStep − 1`.
        public let tokens: [Int]

        public init(start: Int, tokens: [Int]) {
            self.start = start
            self.tokens = tokens
        }
    }

    /// Choose the prompt window from the full (encoded) token sequence so its **front only moves in
    /// coarse `reanchorStep` jumps**, instead of sliding one token per keystroke the way a plain
    /// `suffix(windowMax)` does. A sliding front would change the leading tokens on every keystroke and
    /// so defeat KV-reuse entirely; an anchored front stays put across many appends (reuse fires every
    /// keystroke) and only jumps — forcing a single rebuild — once per `reanchorStep` tokens.
    ///
    /// The window is anchored to the largest multiple of `reanchorStep` that still leaves at least
    /// `windowMax` tokens of tail, so it is **always a superset of the last `windowMax` tokens** (it
    /// can carry up to `reanchorStep − 1` *extra* older tokens, never fewer recent ones). That superset
    /// property is what lets us argue the change cannot show *less* context than the old
    /// `suffix(windowMax)` cap — quality can only stay equal or improve.
    ///
    /// - Parameters:
    ///   - tokens: the full encoded prompt tokens (volatile tail last).
    ///   - windowMax: minimum tail length to keep (the old hard cap; e.g. 512).
    ///   - reanchorStep: how far the front jumps when it does move (e.g. 128). Larger ⇒ rarer
    ///     rebuilds but a longer worst-case prompt (`windowMax + reanchorStep − 1`).
    /// - Returns: the anchored window.
    public static func window(_ tokens: [Int], max windowMax: Int, reanchorStep: Int) -> Window {
        precondition(windowMax > 0 && reanchorStep > 0, "window/step must be positive")
        guard tokens.count > windowMax else { return Window(start: 0, tokens: tokens) }
        let over = tokens.count - windowMax
        let anchor = (over / reanchorStep) * reanchorStep   // largest multiple of step ≤ over
        return Window(start: anchor, tokens: Array(tokens[anchor...]))
    }

    // MARK: - S-pinning prompt window (FIM/SPM, build item 6)

    /// A bounded FIM prompt window: the pinned front block, a capped prefix tail, and the fixed
    /// trailing sentinel.
    public struct FIMWindow: Equatable, Sendable {
        /// The assembled prompt tokens, `pinned + prefixTail + trailing`.
        public let tokens: [Int]
        /// How many tokens were dropped from the **head of `P`** — the oldest prefix tokens, farthest
        /// from the caret. Changes only on a re-anchor, so it doubles as the "did the front move this
        /// keystroke" signal.
        public let prefixHeadDropped: Int

        public init(tokens: [Int], prefixHeadDropped: Int) {
            self.tokens = tokens
            self.prefixHeadDropped = prefixHeadDropped
        }
    }

    /// Choose the FIM prompt window under **SPM** ordering
    /// (`<fim_suffix> S <fim_prefix>` · `P` · `<fim_middle>`).
    ///
    /// ``window(_:max:reanchorStep:)`` front-drops when the prompt overflows — which on this layout
    /// would eat the sentinels and then `S` itself, silently degrading the bridge into a forward
    /// predict wearing FIM sentinels. Here the front block is **pinned** and the cap is applied to the
    /// `P`-head instead: the oldest prefix tokens are the ones farthest from the caret, so they are
    /// also the cheapest context to lose.
    ///
    /// The `P`-head anchor moves in coarse `reanchorStep` jumps for the same reason the forward
    /// window's front does — a per-keystroke slide would change the prompt's leading tokens every time
    /// and defeat reuse. Inside one anchor, successive keystrokes differ only in the appended `P`
    /// token(s) plus the trailing sentinel, so ``plan(cached:next:)`` reuses everything but that
    /// sentinel. **On a re-anchor the shared run collapses to the pinned block** — `P` re-prefills but
    /// `S` stays primed, which is exactly what pinning buys.
    ///
    /// Note the ordering consequence the ticket calls out: because the prompt *ends* in the fixed
    /// `<fim_middle>`, a `P`-append is never a **pure** append — `plan` always reports
    /// `trimFromCache == 1`. On a trimmable (all-attention) cache `reuseMode` still returns `.trim`,
    /// so reuse works; on a hybrid-Mamba cache the `.snapshot` gate (`trimFromCache == 0`) can never be
    /// met, so v1 runs rebuild-always on a hybrid FIM path (absorbed by the small model + ¼ suffix).
    ///
    /// - Parameters:
    ///   - pinned: the front block that must never be dropped (`<fim_suffix>` + `S` + `<fim_prefix>`).
    ///   - prefix: the prefix `P`'s tokens, caret end last.
    ///   - trailing: the fixed tail (`<fim_middle>`).
    ///   - windowMax: the total token budget. Like the forward window this is a *soft* cap: the result
    ///     can carry up to `reanchorStep − 1` extra tokens so the kept tail is never below budget.
    ///   - reanchorStep: how far the `P`-head jumps when it moves.
    public static func fimWindow(
        pinned: [Int], prefix: [Int], trailing: [Int], max windowMax: Int, reanchorStep: Int
    ) -> FIMWindow {
        precondition(windowMax > 0 && reanchorStep > 0, "window/step must be positive")
        let budgetForPrefix = windowMax - pinned.count - trailing.count
        // Degenerate: the pinned block alone overruns the budget. Keep it anyway — dropping `S` would
        // turn the prompt into a forward predict wearing FIM sentinels, which is strictly worse than an
        // over-budget prompt. (The caller caps `S` at ~¼ of the budget upstream, so this is a backstop.)
        guard budgetForPrefix > 0 else {
            return FIMWindow(tokens: pinned + trailing, prefixHeadDropped: prefix.count)
        }
        guard prefix.count > budgetForPrefix else {
            return FIMWindow(tokens: pinned + prefix + trailing, prefixHeadDropped: 0)
        }
        let over = prefix.count - budgetForPrefix
        let dropped = (over / reanchorStep) * reanchorStep   // largest multiple of step ≤ over
        return FIMWindow(tokens: pinned + prefix[dropped...] + trailing, prefixHeadDropped: dropped)
    }

    // MARK: - Reuse plan

    /// How to satisfy a new prompt against the tokens already primed in the KV-cache.
    public enum Plan: Equatable, Sendable {
        /// No usable shared prefix — discard the old cache and prefill the whole new prompt fresh.
        /// (Covers: no cache yet, a caret jump / mid-text edit that diverged the prefix, or a window
        /// re-anchor that shifted the front.)
        case rebuild

        /// Reuse `reuseTokens` leading tokens of the existing cache (after trimming `trimFromCache`
        /// tokens off its end so the cache holds *exactly* that shared prefix), then prefill only the
        /// new prompt's tail starting at index `reuseTokens`. The tail is guaranteed non-empty.
        case reuse(reuseTokens: Int, trimFromCache: Int)
    }

    /// Length of the longest common leading run of two token sequences.
    public static func longestCommonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }

    /// Decide how much of the cache (currently holding `cached`) can be reused to predict from `next`.
    ///
    /// The cache is keyed only by the tokens it represents, so the shared leading run is what we can
    /// keep; everything past it is trimmed and the divergent/new tail is (re)prefilled. We always keep
    /// **at least one token of tail** to prefill, because the engine discards generated-token KV after
    /// each prediction (so the logits needed to *start* decoding are not in the cache — the last prompt
    /// token must be re-run). Greedy determinism makes reusing the shared prefix's KV safe:
    /// identical prefix ⇒ identical KV ⇒ the continuation reproduces, no ghost flicker.
    public static func plan(cached: [Int], next: [Int]) -> Plan {
        let lcp = longestCommonPrefix(cached, next)
        // Keep ≥1 token of tail to (re)prefill — the cache has no stored logits for the last token.
        let reuseTokens = min(lcp, max(0, next.count - 1))
        guard reuseTokens > 0 else { return .rebuild }
        let trimFromCache = cached.count - reuseTokens   // ≥ 0: reuseTokens ≤ lcp ≤ cached.count
        return .reuse(reuseTokens: reuseTokens, trimFromCache: trimFromCache)
    }

    // MARK: - Reuse execution mode ( hybrid snapshot-reuse)

    /// How the engine should *execute* a ``Plan``, given the two runtime facts only the engine knows:
    /// whether the live cache is trimmable, and whether a clean prompt-boundary snapshot is available.
    public enum ReuseMode: Equatable, Sendable {
        /// Discard the cache and prefill the whole prompt fresh. `nonTrimmable` distinguishes a rebuild
        /// *forced* by a non-trimmable (hybrid Mamba) cache that couldn't reuse — flag off, a backward
        /// jump, or no snapshot — from a genuine no-shared-prefix rebuild; it drives the DEBUG cause-tag
        /// (`rebuild(non-trimmable)` vs `rebuild(empty/divergence)`), nothing else.
        case rebuild(nonTrimmable: Bool)
        /// Trimmable (all-attention) cache: trim `trimFromCache` off the live cache to the shared prefix,
        /// then prefill the delta from `reuseTokens`. The cheaper, in-place path.
        case trim(reuseTokens: Int, trimFromCache: Int)
        /// Non-trimmable (hybrid Mamba) cache, a snapshot that is a strict prefix of the new prompt, flag
        /// on: restore the clean snapshot and prefill only the delta from `reuseTokens`.
        /// `reuseTokens` is the snapshot's length, which sits a few tokens before the end of
        /// the prompt it was taken from.
        /// `copy()` rewinds the SSM state that `trim` cannot, so this is the *correct* hybrid reuse.
        case snapshot(reuseTokens: Int)
    }

    /// Choose how to execute a ``Plan`` on the cache the engine currently holds.
    ///
    /// The snapshot gate no longer asks for a pure append of the cached prompt
    /// (`trimFromCache == 0`): typing a letter re-tokenizes the word at the caret, so that never held.
    /// It asks whether the held snapshot, taken at ``snapshotBoundary(promptTokens:deltaStart:tailMargin:minAdvance:)``,
    /// is a strict prefix of the new prompt (``snapshotCoverage(snapshotTokens:next:)``).
    ///
    /// `plan` is pure token arithmetic and stays oblivious to the model; this layers on the runtime
    /// trimmability of the live cache (all-attention ⇒ trimmable; the shipping hybrid's Mamba layer ⇒
    /// not), snapshot availability, and the staged-rollout flag. It is the branching the MLX engine used
    /// to inline across its `switch plan` — exactly the regression-prone part — pulled out so it is
    /// unit-tested with no model, like ``commitDecision(branch:prefillLanded:generatedKV:)``.
    ///
    /// **With `snapshotReuseEnabled == false` the non-trimmable branch always rebuilds**, the issue-07
    /// rebuild-always behaviour; only the trimmable trim-reuse and plan-rebuild paths are reachable. That
    /// is the off switch kept since snapshot reuse turned on by default.
    ///
    /// - Parameters:
    ///   - plan: the token-level reuse plan from ``plan(cached:next:)``.
    ///   - cacheTrimmable: `canTrimPromptCache(liveCache)` — true only for an all-attention cache.
    ///   - haveCache: whether a live cache exists at all (so a `.reuse` plan with no cache is a *plain*
    ///     rebuild, not a non-trimmable-gated one — defensive; `.reuse` normally implies a cache).
    ///   - snapshotCoverage: how many leading tokens of the new prompt the held snapshot covers, from
    ///     ``snapshotCoverage(snapshotTokens:next:)``; nil when no snapshot covers it.
    ///   - snapshotReuseEnabled: the rollout flag, on when the key is absent (see
    ///     ``snapshotReuseEnabled(stored:)``).
    public static func reuseMode(
        plan: Plan,
        cacheTrimmable: Bool,
        haveCache: Bool,
        snapshotCoverage: Int?,
        snapshotReuseEnabled: Bool
    ) -> ReuseMode {
        switch plan {
        case .rebuild:
            return .rebuild(nonTrimmable: false)
        case .reuse(let reuseTokens, let trimFromCache):
            if cacheTrimmable {
                return .trim(reuseTokens: reuseTokens, trimFromCache: trimFromCache)
            }
            // Non-trimmable (hybrid) cache. Snapshot-reuse only when the held snapshot is a prefix of the
            // new prompt: an edit before the snapshot boundary leaves nothing to restore, and Mamba can't
            // trim back to an earlier point.
            if snapshotReuseEnabled, let covered = snapshotCoverage {
                return .snapshot(reuseTokens: covered)
            }
            // Couldn't reuse: rebuild. Tag it non-trimmable iff a (hybrid) cache actually existed to gate
            // off; a missing cache is just a plain rebuild.
            return .rebuild(nonTrimmable: haveCache)
        }
    }

    // MARK: - Snapshot boundary ( §Amendment 2026-10-29)

    /// Whether hybrid snapshot reuse runs, from the stored `snapshotReuseEnabled` value (nil when the key
    /// is absent). On by default; `defaults write … -bool NO`
    /// turns it off. The engine and the diagnostics report both read it through here, so they agree.
    public static func snapshotReuseEnabled(stored: Bool?) -> Bool {
        stored ?? true
    }

    /// How many leading tokens of `next` the held snapshot covers: its length when `snapshotTokens` is a
    /// **strict** prefix of `next`, else nil. Strict, because the last prompt token must run through the
    /// model for the first decode logits; an empty snapshot covers nothing.
    public static func snapshotCoverage(snapshotTokens: [Int], next: [Int]) -> Int? {
        guard !snapshotTokens.isEmpty, snapshotTokens.count < next.count,
              next.starts(with: snapshotTokens) else { return nil }
        return snapshotTokens.count
    }

    /// Where this predict takes its hybrid snapshot, as a token index into the prompt, or nil to keep
    /// the snapshot already held.
    ///
    /// The snapshot sits `tailMargin` tokens before the prompt end. Typing appends letters to the word
    /// at the caret and re-tokenizes only that word, so the tokens before it, and a snapshot of them,
    /// survive the next keystrokes. A snapshot at the prompt end (`tailMargin == 0`, the earlier
    /// boundary) never survived one.
    ///
    /// A new snapshot is taken only when it lies at least `minAdvance` tokens past `deltaStart` (where
    /// this predict's prefill begins: 0 on a rebuild, the restored snapshot's length on a reuse).
    /// Taking it splits the prefill into one more forward call, so a reuse that moved only a few tokens
    /// keeps the old snapshot and prefills a slightly longer delta instead.
    ///
    /// - Returns: an index in `max(1, deltaStart + minAdvance)... promptTokens`, or nil.
    public static func snapshotBoundary(
        promptTokens: Int, deltaStart: Int, tailMargin: Int, minAdvance: Int
    ) -> Int? {
        let boundary = promptTokens - max(0, tailMargin)
        guard boundary >= max(1, deltaStart + max(1, minAdvance)) else { return nil }
        return boundary
    }

    // MARK: - Commit decision ( commit-after-prefill)

    /// Which cache branch a `predict()` took. The two branches differ **only** in what an abort *before
    /// the prefill lands* leaves behind — which is exactly what the commit decision needs to know.
    public enum Branch: Equatable, Sendable {
        /// Reuse trimmed the **live** cache in place before prefilling, so a pre-prefill abort leaves it
        /// half-trimmed (indeterminate).
        case reuse
        /// Rebuild built a fresh cache into a **local** and publishes it only at commit, so a pre-prefill
        /// abort leaves the previously-committed cache untouched.
        case rebuild
    }

    /// What to do with the KV-cache when a `predict()` exits. The `predict()` call mutates
    /// MLX state directly (untestable); this models the *decision* it delegates — the regression-prone
    /// part — so it can be unit-tested with no model.
    public enum CacheAction: Equatable, Sendable {
        /// Publish the cache + its token sequence after trimming `trim` generated-token KV entries off the
        /// end, so it represents exactly the prompt. Reached on **every** post-prefill exit — a clean
        /// decode *or* a decode-phase cancellation (the latter warms the cache and renders nothing).
        case commit(trim: Int)
        /// Leave the committed cache exactly as it was (a rebuild aborted before its local was published).
        case keepOld
        /// Discard the cache — a reuse aborted after trimming the live cache in place, before the prefill
        /// could re-establish it. The **one** genuinely-indeterminate state.
        case invalidate
    }

    /// Decide the cache action for a finished `predict()` ( commit-after-prefill).
    ///
    /// The cache **commit point moves from "after a clean decode" to "after the prefill lands."** Once the
    /// prefill's `eval` lands, the cache deterministically holds exactly the prompt (`offset == prompt
    /// length`), so every later exit — clean *or* decode-cancelled — commits it (a cancelled prediction
    /// **warms** the cache). This replaces's blanket "any abnormal exit invalidates," which
    /// wiped a perfectly-valid prompt cache on every decode-phase cancel and so defeated reuse under fast
    /// typing. The regression guard this function must enforce: **a landed prefill never invalidates.**
    ///
    /// - Parameters:
    ///   - branch: which cache branch ran (only matters pre-prefill).
    ///   - prefillLanded: whether the prefill's `eval` completed (the cache then holds exactly the prompt).
    ///   - generatedKV: generated-token KV entries sitting past the prompt (`offset − promptLen`); trimmed
    ///     on commit. Ignored unless `prefillLanded`.
    public static func commitDecision(
        branch: Branch, prefillLanded: Bool, generatedKV: Int
    ) -> CacheAction {
        guard prefillLanded else {
            // Pre-prefill abort: rebuild's new cache was a local (old cache intact); reuse trimmed the
            // live cache in place (now indeterminate).
            switch branch {
            case .rebuild: return .keepOld
            case .reuse:   return .invalidate
            }
        }
        return .commit(trim: max(0, generatedKV))
    }

    // MARK: - Instrumentation cause-tags
    //
    // Pure classifications the MLX engine logs so a runtime capture can be analysed without re-running
    // the model. They derive from the same `prefillLanded` / cache-token concepts the commit decision
    // uses, so they live here next to it. The raw values double as stable, greppable log tokens.

    /// Why a `predict()` rebuilt instead of reusing the KV-cache — split by whether *any* prior cache
    /// existed. Only meaningful when ``plan(cached:next:)`` returned `.rebuild`.
    public enum RebuildCause: String, Equatable, Sendable {
        /// No cached tokens at all: the first predict, a post-invalidation predict, or the predict right
        /// after a context-switch KV drop. This is the **`cachedTokens == 0`** bucket — the
        /// "empty-cache-after-cancel" counter that must read ~zero once the commit-after-prefill
        /// is correct (a decode-phase cancel must *warm* the cache, not empty it).
        case emptyCache = "empty"
        /// A non-empty cache whose shared leading prefix was unusable — a caret jump, a mid-text edit, or
        /// a window re-anchor that shifted the stable front. The **`cachedTokens > 0`** bucket.
        case divergence = "divergence"
    }

    /// Classify a rebuild by the size of the cache it discarded. The cause is purely a function of
    /// whether the prior cache held any tokens, which is exactly the `== 0` vs `> 0` split the
    /// instrumentation needs. Call only on a `.rebuild` (the engine already knows it took that branch).
    public static func rebuildCause(cachedTokens: Int) -> RebuildCause {
        cachedTokens == 0 ? .emptyCache : .divergence
    }

    // MARK: - First differing token

    /// One granted front segment as it sits in the prompt: its kind and the tokens it occupies,
    /// **including** the separator run that follows it. Positional order, as the engine emitted them.
    public struct FrontSpan: Equatable, Sendable {
        public let kind: PromptFrontBudget.Segment
        public let tokens: Int
        public init(kind: PromptFrontBudget.Segment, tokens: Int) {
            self.kind = kind
            self.tokens = tokens
        }
    }

    /// Where the new prompt first differs from the cached token sequence, for the DEBUG reuse-miss tag.
    public struct FirstDiff: Equatable, Sendable {
        /// First token index where the two differ; the shorter length when one is a prefix of the
        /// other; the common length when they are equal.
        public let index: Int
        /// The prompt-front segment holding `index`: `personalization`, `ocr`, `clip`, `doc`, `reply`,
        /// or `prefix` for anything after the front.
        public let segment: String
        public let cachedTokens: Int
        public let newTokens: Int

        /// `firstDiff=<i> seg=<name> cached=<n> new=<n>`, the greppable form (runtime-knobs.md).
        public var logTag: String {
            "firstDiff=\(index) seg=\(segment) cached=\(cachedTokens) new=\(newTokens)"
        }
    }

    /// Compute ``FirstDiff`` for a cache miss. `frontSpans` are the granted front segments in prompt
    /// order; an index inside a segment's separator run counts for that segment.
    public static func firstDiff(
        cached: [Int], next: [Int], frontSpans: [FrontSpan]
    ) -> FirstDiff {
        let index = longestCommonPrefix(cached, next)
        var segment = "prefix"
        var start = 0
        for span in frontSpans {
            if index < start + span.tokens {
                segment = logName(span.kind)
                break
            }
            start += span.tokens
        }
        return FirstDiff(
            index: index, segment: segment, cachedTokens: cached.count, newTokens: next.count)
    }

    private static func logName(_ kind: PromptFrontBudget.Segment) -> String {
        switch kind {
        case .personalization: return "personalization"
        case .ocrAmbient: return "ocr"
        case .clipboard: return "clip"
        case .focusedDoc: return "doc"
        case .reply: return "reply"
        }
    }

    /// How far a *cancelled* `predict()` got before it bailed, so a capture can
    /// tell apart a cheap pre-cache cancel from one that already paid for a prefill. Ordered by cost.
    public enum CancelPhase: String, Equatable, Sendable {
        /// Cancelled in the read-only phase (encode + window + plan), before the mutating switch — the
        /// cache was never touched, so the cancel cost only the tokenizer pass.
        case encodeOnly = "encode-only"
        /// The prefill landed (the cache is committed to exactly the prompt — a *warm* cache for the next
        /// call) but the decode loop was cancelled before producing a single token.
        case cacheMutated = "cache-mutated"
        /// The prefill landed and ≥1 token decoded before the cancel.
        case midDecode = "mid-decode"
    }

    /// Classify a cancelled predict from the two facts the engine tracks: whether the prefill's `eval`
    /// landed (the only point after which the cache is mutated/committed) and how many decode steps ran.
    /// `prefillLanded` is authoritative — a pre-prefill cancel is `.encodeOnly` regardless of `decodeSteps`.
    public static func cancelPhase(prefillLanded: Bool, decodeSteps: Int) -> CancelPhase {
        guard prefillLanded else { return .encodeOnly }
        return decodeSteps == 0 ? .cacheMutated : .midDecode
    }
}
