import AppKit
import NextTypedCore
import Foundation

/// App-side **effect-interpreter** for the pure-Core `ModelResidencyPolicy` reducer — the
/// idle RAM-reclaim ladder (cap → flush → unload) that stops the MLX buffer-cache pool growing to ~19 GB.
///
/// Mirrors the split that `SuggestionSession` uses: the *decisions* (which tier fires, when —
/// 30 s flush / 2.5 min unload / warm-state / away-signals) live in the time-free, unit-tested Core
/// reducer; this class owns only the untestable wiring — the system **event sources** (NSWorkspace away-
/// signals, screen-lock, memory-pressure, a coarse tick) and the **effect mechanism** (calls into the
/// prediction engine + `MLX.Memory`). `AppCoordinator` forwards the two events it is the natural source
/// of: `predictionActivity` (after a real predict) and `contextSwitch` (on a focus change).
///
/// Not Core-unit-testable (AX / NSWorkspace / MLX need a running app), so verify at runtime: the cache flushes
/// to ~1.6 GB on a pause, the model unloads to ~0.2 GB when away, and nothing thrashes.
@MainActor
final class ModelResidencyController {

    private var policy: ModelResidencyPolicy
    private let engine: PredictionEngine
    private var started = false

    /// Side-channel for subsystems that need the **same** system signals rather than a second set of
    /// observers on the same notifications. Screen-context OCR power-gates on exactly these signals: hard off on lock/sleep, constrained under Low
    /// Power / thermal pressure, and an app-level recency feed from the frontmost signal.
    var onPowerStateChange: ((OCRCadencePolicy.PowerState) -> Void)?
    var onFrontmostAppChange: ((String?) -> Void)?

    /// Publishes the policy's tier (loaded, flushed, unloaded) after every event that changes it, for the
    /// Settings status section. The coordinator is the single subscriber.
    var onModelStateChange: ((ModelResidencyPolicy.ModelState) -> Void)?
    private var publishedState: ModelResidencyPolicy.ModelState = .loaded

    /// The coarse heartbeat that advances the idle / absence timers toward their thresholds. ~7 s is
    /// cheap yet fine enough to honor the 30 s flush / 2.5 min unload windows.
    ///
    /// Its **phase is anchored to app launch**, so it drifts freely against anything anchored elsewhere.
    /// `Harness/scenarios/residency-idle-flush` depends on that: its wait must stay above
    /// `ModelResidencyPolicy.Config.flushIdleSeconds + 2 × this`, or the scenario becomes a coin flip
    /// on start-up jitter. Raise this and that scenario's `sleep` has to follow.
    private static let tickInterval: Duration = .seconds(7)
    private var tickTask: Task<Void, Never>?

    /// System event-source handles, torn down in `stop()`.
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    init(engine: PredictionEngine) {
        self.engine = engine
        self.policy = ModelResidencyPolicy()
    }

    // MARK: Lifecycle

    /// Set the Tier-0 cap and install the event sources. Idempotent — a re-entry is a no-op (the model
    /// preload at app start stays the existing path; `start()` does not re-load).
    func start() {
        guard !started else { return }
        started = true
        interpret(policy.start(now: Self.now()))
        setUnloadRule(AppSettingsStore().modelUnloadSetting)
        installEventSources()
        startTick()
    }

    func stop() {
        tickTask?.cancel(); tickTask = nil
        memoryPressureSource?.cancel(); memoryPressureSource = nil
        let ws = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { ws.removeObserver(observer) }
        workspaceObservers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        if let lockObserver { distributed.removeObserver(lockObserver) }
        if let unlockObserver { distributed.removeObserver(unlockObserver) }
        lockObserver = nil
        unlockObserver = nil
        started = false
    }

    /// Apply the user's unload choice. Called at `start()` and on every
    /// change in Settings, so it takes effect without a relaunch. The policy returns no effects; the next
    /// tick applies the new rule.
    func setUnloadRule(_ setting: ModelUnloadSetting) {
        send(.setUnloadRule(setting.rule))
        #if DEBUG
        acLog("[residency]: unload-rule=%@", setting.rawValue)
        #endif
    }

    // MARK: Events forwarded by AppCoordinator

    /// A keystroke engaged the predict pipeline (editable field + gates passed + `predict()` ran) — THE
    /// activity signal that re-warms the model and resets the idle clock. `app` marks the writing app.
    func predictionActivity(app: String?) {
        send(.predictionActivity(app: app, now: Self.now()))
    }

    /// Focus crossed to a different window/field — the explicit context boundary: drop the
    /// KV-cache (no Mamba state carried across) and Tier-1 flush.
    func contextSwitch() {
        send(.contextSwitch(now: Self.now()))
    }

    /// Focus landed on a field (`editable`: passes the eligibility floor and its app is enabled) or on
    /// something we do not complete. Gaining an editable field on an unloaded model pre-warms it, so the
    /// reload overlaps the user orienting in the field. Losing
    /// editable focus flushes (Tier 1). Sent after `contextSwitch()`, so a loaded model is already flushed.
    func focusChanged(editable: Bool, app: String?) {
        send(.focusChanged(editable: editable, app: app, now: Self.now()))
    }

    /// The menu's "Unload model now". The policy answers `[.unloadModel]` while the weights are
    /// resident and `[]` once they are gone.
    func unloadNow() {
        send(.manualUnload)
    }

    // MARK: Reduce + interpret

    private func publishStateIfChanged() {
        guard policy.state != publishedState else { return }
        publishedState = policy.state
        onModelStateChange?(publishedState)
    }

    private func send(_ event: ModelResidencyPolicy.Event) {
        let effects = policy.handle(event)
        publishStateIfChanged()
        #if DEBUG
        if !effects.isEmpty {
            acLog("[residency]: %@ → %@", Self.describe(event), Self.describe(effects))
        }
        #endif
        interpret(effects)
    }

    // Each effect is interpreted as its own actor hop. The effects within one event are independent for
    // RAM purposes (e.g. contextSwitch's `[.invalidateKVCache,.flushCache]` — order doesn't change the
    // result), and the engine actor serializes them anyway. A subtler ordering — invalidateKVCache vs. a
    // post-focus predict — is moot today because KV-reuse is gated off on the hybrid (rebuild-always), so a predict rebuilds from a fresh cache regardless; revisit if reuse lands.
    private func interpret(_ effects: [ModelResidencyPolicy.Effect]) {
        for effect in effects {
            switch effect {
            case .setCacheLimit(let bytes): Task { await engine.setCacheLimit(bytes) }
            case .flushCache:               Task { await engine.flushCache() }
            case .unloadModel:              Task { await engine.unload() }
            case .preloadModel:             Task { await engine.preload() }
            case .invalidateKVCache:        Task { await engine.invalidateKVCache() }
            }
        }
    }

    // MARK: Event sources (the untestable wiring)

    private func startTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.send(.tick(now: Self.now()))
            }
        }
    }

    private func installEventSources() {
        let ws = NSWorkspace.shared.notificationCenter

        // Frontmost app changed → tracks "are we still in the writing app" (warm-state); catches leaving
        // to a non-AX app (fullscreen game/film) that emits no focus event. The non-`Sendable`
        // `Notification` must NOT cross the main-actor hop (Swift 6 race), so the (Sendable) bundle id is
        // extracted on the delivery thread, then only that value is carried in.
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                self?.send(.frontmostAppChanged(app: app, now: Self.now()))
                self?.onFrontmostAppChange?(app)
            }
        })
        // Strong away-signals → unload (no payload needed, so `note` is never captured).
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.displaySleep)
                self?.onPowerStateChange?(.off)
            }
        })
        workspaceObservers.append(ws.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.systemWillSleep)
                self?.onPowerStateChange?(.off)
            }
        })

        // Wake signals are OCR-only: the residency policy re-warms lazily on the next predict, but OCR
        // must be told it may capture again (its gate is a latch, not a timer).
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(ws.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.onPowerStateChange?(.normal) }
            })
        }

        // Screen lock rides DistributedNotificationCenter (a different center than NSWorkspace).
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.send(.screenLocked)
                self?.onPowerStateChange?(.off)
            }
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onPowerStateChange?(.normal) }
        }

        // Memory pressure — the real safety anchor: give RAM back the instant the system needs it. The
        // handler reads the level off the stored source (set just below) rather than capturing `source`
        // strongly, so there is no source→handler→source retain cycle.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.memoryPressureSource?.data else { return }
                if event.contains(.critical) {
                    self.send(.memoryPressure(.critical))
                } else if event.contains(.warning) {
                    self.send(.memoryPressure(.warning))
                }
            }
        }
        memoryPressureSource = source
        source.resume()
    }

    // MARK: Helpers

    /// A monotonic seconds clock for the reducer's `now` (does not jump on wall-clock changes).
    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    #if DEBUG
    private static func describe(_ event: ModelResidencyPolicy.Event) -> String {
        switch event {
        case .predictionActivity(let app, _): return "predictionActivity(\(app ?? "?"))"
        case .focusChanged(let editable, _, _): return "focusChanged(editable: \(editable))"
        case .contextSwitch:                  return "contextSwitch"
        case .frontmostAppChanged(let app, _): return "frontmostAppChanged(\(app ?? "?"))"
        case .memoryPressure(let level):      return "memoryPressure(\(level))"
        case .displaySleep:                   return "displaySleep"
        case .screenLocked:                   return "screenLocked"
        case .systemWillSleep:                return "systemWillSleep"
        case .tick:                           return "tick"
        case .setUnloadRule(let rule):        return "setUnloadRule(\(rule))"
        case .manualUnload:                   return "manualUnload"
        }
    }

    private static func describe(_ effects: [ModelResidencyPolicy.Effect]) -> String {
        effects.map { effect in
            switch effect {
            case .setCacheLimit(let b): return "setCacheLimit(\(b))"
            case .flushCache:           return "flushCache"
            case .unloadModel:          return "unloadModel"
            case .preloadModel:         return "preloadModel"
            case .invalidateKVCache:    return "invalidateKVCache"
            }
        }.joined(separator: ", ")
    }
    #endif
}
