import Foundation

/// The pure-Core, time-free, **tick-driven** reducer that decides when to reclaim the model's RAM
/// . It owns the minute-scale *model/cache lifecycle* — deliberately **separate** from
/// `SuggestionSession` (which owns the per-keystroke *presentation* decision): different concern,
/// different time scale, different effects (single responsibility).
///
/// **Why this exists.** A fresh app sits at ~1.6 GB resident but grows to ~19 GB over a typing session —
/// not a leak, the **unbounded MLX buffer-cache pool** (`Memory.cacheMemory`). The fix is a three-tier
/// reclaim ladder driven by **prediction-relevant activity** (a keystroke that actually engaged the
/// predict pipeline), not raw keystrokes — so a game (no editable field → no predict) unloads on its own
/// with zero bespoke detectors.
///
/// | Tier | Trigger | Effect | RAM after |
/// | --- | --- | --- | --- |
/// | **0 Cap**   | once at `start` | `.setCacheLimit` | bounded *while* typing |
/// | **1 Flush** | ~30 s idle **or** editable focus lost | `.flushCache` | ~1.6 GB |
/// | **2 Unload**| warm-state ended + ~2–3 min **or** a strong away-signal | `.unloadModel` | ~0.2 GB |
///
/// **Time-free:** the only clock is the `now: TimeInterval` carried on `.tick` and the timer-bearing
/// events, so the 30 s / 2.5 min thresholds are unit-testable with no real
/// waiting. Events in, effects out; the App is a thin effect-interpreter that translates AX / NSWorkspace
/// / memory-pressure callbacks into events and runs the returned effects against the engine + `MLX.Memory`.
public struct ModelResidencyPolicy: Sendable {

    /// Injectable thresholds (so tests need no real waits, and the cap is tunable by measurement).
    public struct Config: Equatable, Sendable {
        /// Tier-0 cap handed to `MLX.Memory.cacheLimit` once at startup. **Moderate, measured** — small
        /// enough to bound the plateau, large enough to hold one inference's working set warm. The
        /// `mlx-swift` "2 MB is often fine" note is a *hypothesis to measure* (too-small risks malloc
        /// churn), not adopted blind; the shipping number is owed from a runtime capture.
        public var cacheLimitBytes: Int
        /// Tier-1: flush the buffer pool after this much continuous idle (no prediction activity).
        ///
        /// Changing this moves a harness scenario with it: `Harness/scenarios/residency-idle-flush`
        /// out-waits this threshold and must keep `sleep > flushIdleSeconds + 2 ×
        /// ModelResidencyController.tickInterval`, or whether a tick lands inside its eligibility
        /// window is decided by fixture start-up jitter rather than by this policy.
        public var flushIdleSeconds: TimeInterval
        /// Tier-2: unload the model after this much *continuous* non-warm absence (the anti-thrash bound).
        public var unloadAbsenceSeconds: TimeInterval
        /// The Tier-2 rule the policy starts with. `nil` in the initializer means
        /// `.whenAway(absenceSeconds: unloadAbsenceSeconds)`, today's rule. `.setUnloadRule` swaps it later.
        public var unloadRule: UnloadRule

        public init(
            cacheLimitBytes: Int = 512 * 1024 * 1024,
            flushIdleSeconds: TimeInterval = 30,
            unloadAbsenceSeconds: TimeInterval = 150,
            unloadRule: UnloadRule? = nil
        ) {
            self.cacheLimitBytes = cacheLimitBytes
            self.flushIdleSeconds = flushIdleSeconds
            self.unloadAbsenceSeconds = unloadAbsenceSeconds
            self.unloadRule = unloadRule ?? .whenAway(absenceSeconds: unloadAbsenceSeconds)
        }
    }

    /// When the tick unloads the model (Tier 2). The user picks it in Settings (`ModelUnloadSetting`).
    /// Display sleep, screen lock and system sleep unload under `.whenAway` and `.afterIdle`, not under
    /// `.never`. Memory pressure acts under every rule: the system's need for RAM wins.
    public enum UnloadRule: Equatable, Sendable {
        /// Unload after this much continuous time outside warm-state (you left the writing app). Today's rule.
        case whenAway(absenceSeconds: TimeInterval)
        /// Unload after this much time since the last activity, whether or not warm-state holds.
        case afterIdle(seconds: TimeInterval)
        /// The tick never unloads.
        case never
    }

    /// System memory-pressure level (from `DispatchSource.makeMemoryPressureSource`). `.warning` flushes
    /// (Tier 1), `.critical` unloads (Tier 2) — the real safety anchor that gives RAM back the instant the
    /// system needs it, however conservative the timers are.
    public enum MemoryPressure: Equatable, Sendable {
        case warning, critical
    }

    /// Where the model currently lives. `loaded` = weights resident **and** the buffer pool may be warm;
    /// `flushed` = weights resident, pool cleared (~1.6 GB); `unloaded` = weights released + pool cleared
    /// (~0.2 GB). The weight buffers move `active → cache` pool on container release, so only `clearCache`
    /// actually returns RAM (invariant ① — enforced App-side in `unload()`).
    public enum ModelState: Equatable, Sendable {
        case loaded, flushed, unloaded
    }

    /// Events the App feeds in (AX / tap / NSWorkspace / memory-pressure / a coarse tick). Timestamps ride
    /// on the events that move a timer ("time enters only as `.tick(now)` and event timestamps").
    public enum Event: Equatable, Sendable {
        /// A keystroke engaged the predict pipeline (editable field + gates passed + `predict()` ran).
        /// THE activity signal — resets the idle clock and marks `app` as the writing app. Raw keystrokes
        /// are deliberately *not* this (gaming would pin the model warm forever).
        case predictionActivity(app: String?, now: TimeInterval)
        /// Focus moved; `editable` says whether the new element accepts our completions. Losing editable
        /// focus flushes (Tier 1); gaining it on an unloaded model pre-warms (`.preloadModel`).
        case focusChanged(editable: Bool, app: String?, now: TimeInterval)
        /// Focus crossed to a *different* window — the explicit cross-context boundary: drop the
        /// KV-cache (fresh SSM state, no bleed) and flush. `windowContext` re-resolution is the AX layer's
        /// own job on the same focus change, not a residency effect.
        case contextSwitch(now: TimeInterval)
        /// The frontmost application changed (NSWorkspace). Tracks "are we still in the writing app" for
        /// warm-state; catches leaving to a non-AX app (a fullscreen game/film) that emits no focus event.
        case frontmostAppChanged(app: String?, now: TimeInterval)
        /// System memory-pressure: `.warning` → flush, `.critical` → unload.
        case memoryPressure(MemoryPressure)
        /// Display sleep / screensaver — a strong "user is away" signal → unload.
        case displaySleep
        /// Screen locked (`com.apple.screenIsLocked`) → unload.
        case screenLocked
        /// System going to sleep → unload.
        case systemWillSleep
        /// A coarse periodic tick (~5–10 s) carrying the current monotonic time — the only thing that
        /// *advances* the idle / absence timers toward their thresholds.
        case tick(now: TimeInterval)
        /// The user changed the unload rule. Returns no effects; the next tick applies it. Idle time counts
        /// from the last activity, not from the change, and a change while unloaded does not reload.
        case setUnloadRule(UnloadRule)
        /// The user chose "Unload model now". Unloads from `loaded` or `flushed` under every rule, and
        /// returns no effects once already unloaded.
        case manualUnload
    }

    /// Effects the App interprets against `MLXPredictionEngine` + `MLX.Memory`.
    public enum Effect: Equatable, Sendable {
        /// Tier 0: `MLX.Memory.cacheLimit = bytes`, once at startup.
        case setCacheLimit(bytes: Int)
        /// Tier 1: `MLX.Memory.clearCache()` — drop the freed-buffer pool, weights stay resident.
        case flushCache
        /// Tier 2: release the `ModelContainer` + `invalidateKVCache()` + `clearCache()` (invariant ①).
        case unloadModel
        /// Pre-warm: `preload()` (idempotent — a no-op when already loaded).
        case preloadModel
        /// Drop the KV-cache (fresh SSM state) — at a context boundary, before any reuse can cross it.
        case invalidateKVCache
    }

    // MARK: Injected config

    private let config: Config
    /// The Tier-2 rule in force. Starts as `config.unloadRule`; `.setUnloadRule` replaces it.
    private var unloadRule: UnloadRule

    // MARK: Mutable decision state

    /// Where the model lives — gates which tier can fire and prevents re-emitting a settled effect.
    private var modelState: ModelState = .loaded

    /// Where the model lives now, for display (Settings -> General status). Read-only.
    public var state: ModelState { modelState }
    /// Whether a KV-cache exists worth invalidating (so `contextSwitch` only emits `.invalidateKVCache`
    /// when there is something to invalidate, keeping effect sequences minimal).
    private var kvValid = false

    /// The instant of the last engagement (prediction activity, or focusing an editable field). The
    /// Tier-1 idle clock measures `now - lastActivityAt`.
    private var lastActivityAt: TimeInterval = 0
    /// When warm-state last ended (became false). nil while warm. The Tier-2 clock measures
    /// `now - warmEndedAt`; clearing it on every return to warm is what makes "continuous absence" the
    /// anti-thrash mechanism (a brief detour never accumulates).
    private var warmEndedAt: TimeInterval?

    /// Is an editable field currently focused. One half of warm-state; also gates flush-on-focus-loss.
    private var focusedEditable = false
    /// The current frontmost app (from focus / NSWorkspace). The other half of warm-state pairs it with…
    private var frontmostApp: String?
    /// …the app where prediction activity last happened. Warm while you stay in it, even clicking around.
    private var writingApp: String?

    public init(config: Config = Config()) {
        self.config = config
        self.unloadRule = config.unloadRule
    }

    // MARK: Lifecycle

    /// Call once at app start: sets the Tier-0 cap and anchors the idle clock. The initial model load is
    /// the existing `preload()` path (not re-emitted here), so `modelState` starts `.loaded`.
    public mutating func start(now: TimeInterval) -> [Effect] {
        lastActivityAt = now
        recomputeWarm(now: now)
        return [.setCacheLimit(bytes: config.cacheLimitBytes)]
    }

    // MARK: Reduce

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .predictionActivity(let app, let now):
            lastActivityAt = now
            focusedEditable = true
            if let app { frontmostApp = app }
            writingApp = app ?? frontmostApp
            kvValid = true
            if modelState != .loaded { modelState = .loaded }   // a predict ran → weights + pool warm
            recomputeWarm(now: now)
            return []

        case .focusChanged(let editable, let app, let now):
            let lostEditable = focusedEditable && !editable
            focusedEditable = editable
            if let app { frontmostApp = app }
            if editable { lastActivityAt = now }                 // focusing a field is engagement
            recomputeWarm(now: now)

            if editable, modelState == .unloaded {
                modelState = .loaded                             // pre-warm; preload() is idempotent
                return [.preloadModel]
            }
            if lostEditable, modelState == .loaded {
                modelState = .flushed
                return [.flushCache]
            }
            return []

        case .contextSwitch(let now):
            // The explicit cross-context boundary: invalidate KV (no Mamba state carried across), then a
            // Tier-1 flush. Each gated so the effect list stays minimal (and the tier transition honest).
            recomputeWarm(now: now)
            var effects: [Effect] = []
            if kvValid {
                kvValid = false
                effects.append(.invalidateKVCache)
            }
            if modelState == .loaded {
                modelState = .flushed
                effects.append(.flushCache)
            }
            return effects

        case .frontmostAppChanged(let app, let now):
            // Activating a *different* app means the previously-focused editable field is no longer the
            // active focus (until a focusChanged re-arms it) — so warm-state can end here even with no AX
            // focus event (the fullscreen game/film case).
            let changed = (app != frontmostApp)
            frontmostApp = app
            if changed { focusedEditable = false }
            recomputeWarm(now: now)
            return []

        case .memoryPressure(.warning):
            guard modelState == .loaded else { return [] }
            modelState = .flushed
            return [.flushCache]

        case .memoryPressure(.critical):
            return unloadEffects()

        case .displaySleep, .screenLocked, .systemWillSleep:
            if unloadRule == .never { return [] }
            return unloadEffects()

        case .setUnloadRule(let rule):
            unloadRule = rule
            return []

        case .manualUnload:
            return unloadEffects()

        case .tick(let now):
            // Tier 2 first: an unload (drop weights + clearCache) supersedes a flush, so never emit both.
            if modelState != .unloaded, tickShouldUnload(now: now) {
                return unloadEffects()
            }
            // Tier 1: continuous idle flushes the pool (weights stay). Fires once; `.flushed` won't re-emit.
            if modelState == .loaded, now - lastActivityAt >= config.flushIdleSeconds {
                modelState = .flushed
                return [.flushCache]
            }
            return []
        }
    }

    // MARK: Derived / helpers

    /// Does the rule in force call for an unload at `now`?
    private func tickShouldUnload(now: TimeInterval) -> Bool {
        switch unloadRule {
        case .whenAway(let absenceSeconds):
            guard !isWarm, let endedAt = warmEndedAt else { return false }
            return now - endedAt >= absenceSeconds
        case .afterIdle(let seconds):
            return now - lastActivityAt >= seconds
        case .never:
            return false
        }
    }

    /// Warm = an editable field is focused, OR the frontmost app is still the writing app. While warm,
    /// Tier 2 never runs (you're plausibly mid-session — clicking around, even just staring at the draft).
    private var isWarm: Bool {
        focusedEditable || (frontmostApp != nil && frontmostApp == writingApp)
    }

    /// Re-derive warm-state after any event that touched its inputs, maintaining the Tier-2 absence clock:
    /// clear it on a return to warm (restarts the continuous-absence requirement), start it on the first
    /// non-warm moment.
    private mutating func recomputeWarm(now: TimeInterval) {
        if isWarm {
            warmEndedAt = nil
        } else if warmEndedAt == nil {
            warmEndedAt = now
        }
    }

    /// Unload = drop weights + invalidate KV + clearCache (the App's `unload()` enforces invariant ①).
    /// Idempotent at the policy level: a no-op once already unloaded.
    private mutating func unloadEffects() -> [Effect] {
        guard modelState != .unloaded else { return [] }
        modelState = .unloaded
        kvValid = false
        return [.unloadModel]
    }
}
