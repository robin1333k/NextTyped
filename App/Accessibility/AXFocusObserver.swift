import ApplicationServices
import AppKit

/// Authoritative caret-moved / focus-changed trigger via `AXObserver`
/// (the "regenerate, don't discard" model).
///
/// `kAXSelectedTextChangedNotification` (registered on the *focused* element) signals
/// that the caret moved, with the settled position then readable via AX — the trigger
/// for proactive regeneration AND the replacement for the old fixed ~12 ms post-`Tab`
/// re-render delay. `kAXFocusedUIElementChangedNotification` (on the *application*
/// element) drives the Esc-mute reset on focus change and re-points selection
/// observation at the new element. `kAXFocusedWindowChangedNotification` does the same for a NEW
/// window in the SAME app (⌘N in TextEdit), which never delivers a focused-element notification —
/// a window change is a context boundary exactly like an element change (harness scenario
/// `personalization-learns`); `kAXWindowCreatedNotification` only re-points (creation precedes focus).
///
/// **The launch race (-25204).** `AXObserverAddNotification` on the *application* element fails with
/// `kAXErrorCannotComplete` (-25204) while the target app is still LAUNCHING — exactly the case that
/// matters, because `NSWorkspace.didActivateApplicationNotification` fires the rebuild the instant the
/// user activates/launches an app. `AXObserverCreate` still succeeds and the run-loop source still
/// installs, so the failure is silent: the observer exists but NOTHING is registered, and for the whole
/// lifetime of that app being frontmost no focus- or window-change notification is ever delivered (stale
/// ghost never cleared, no KV `contextSwitch`, personalization never commits). Reproduced by the runtime
/// harness (scenario `personalization-learns`); the identical registration ~1.5 s later returns
/// `.success`. So every add is **error-checked** (`.success` / `.notificationAlreadyRegistered` = OK),
/// failures are **retried on a backoff ladder** (200 ms / 500 ms / 1 s / 2 s) on the main actor, and the
/// predict path carries a cheap O(1) belt (`ensureTrackingFocusedElement`) that re-attempts whatever is
/// still unregistered. Registration is tracked per notification name, so all of this is idempotent.
///
/// Mirrors `EventTapController`'s C-callback + refcon + main-run-loop pattern: the
/// observer source is added to the main run loop, so callbacks arrive on the main
/// thread and hop onto the main actor via `MainActor.assumeIsolated`.
///
/// RUNTIME-VERIFY: every behavior here — whether the notification fires, on which
/// element, and its timing relative to the host's own caret update — can only be
/// confirmed on a running, Accessibility-granted build in real apps
/// (TextEdit/Mail/Notes/Safari). Electron/Chrome may not fire it at all; the loop then
/// degrades to typing-driven regen.
@MainActor
final class AXFocusObserver {
    var onCaretMoved: (() -> Void)?
    var onFocusChanged: (() -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var focusedElement: AXUIElement?
    private var observedPID: pid_t = 0
    private var activationToken: NSObjectProtocol?

    /// The application-element notifications, in registration order. Semantics live in `handle(_:)`.
    private static let appNotifications: [String] = [
        kAXFocusedUIElementChangedNotification as String,
        kAXFocusedWindowChangedNotification as String,
        kAXWindowCreatedNotification as String,
    ]
    /// Which of `appNotifications` are actually registered on the CURRENT observer. Drives both
    /// idempotence (never double-register) and the O(1) no-op of the predict-path belt once complete.
    private var registeredAppNotifications: Set<String> = []
    /// Bumped by `teardown()`. A scheduled retry abandons silently unless it still matches — covers the
    /// app being switched away AND a `pid_t` recycled onto a different app.
    private var registrationGeneration: UInt64 = 0
    /// Registration passes since the current observer was created (1 = the initial pass). Only used for
    /// the DEBUG log so a failure line can be correlated with the retry that eventually fixed it.
    private var registrationAttempt: Int = 0

    func start() {
        guard activationToken == nil else { return }   // idempotent
        rebuildForFrontmostApp()
        // ⌘-Tab to another app won't fire app A's focused-element notification, so rebuild
        // the observer against the newly-frontmost app whenever the user switches apps.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildForFrontmostApp() }
        }
    }

    func stop() {
        if let token = activationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            activationToken = nil
        }
        teardown()
    }

    // MARK: Registration

    private func rebuildForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        #if DEBUG
        acLog("[focus]: rebuild frontmost=%@ pid=%d observed=%d", app.bundleIdentifier ?? "?", pid, observedPID)
        #endif
        if pid == observedPID, observer != nil { return }   // already observing this app
        // ⌘-Tab to another app never delivers app A's focused-element notification, so the
        // in-app focus-change teardown (clear the ghost + Esc-mute reset + KV `contextSwitch`)
        // that `handle(kAXFocusedUIElementChangedNotification)` runs is skipped — the previous
        // app's ghost floats over the new app until an unrelated event tears it down. Fire the
        // same `onFocusChanged` callback here on a genuine pid change, EARLY (after `teardown()`,
        // before the fallible observer rebuild), so the stale ghost is cleared even when the new
        // app can't be observed. `observedPID != 0` excludes the first `start()` registration
        // (no previous app, no ghost to clear); the `pid == observedPID && observer == nil` retry
        // path is likewise excluded.
        let isAppSwitch = observedPID != 0 && pid != observedPID   // capture BEFORE teardown() zeroes observedPID
        teardown()
        observedPID = pid
        if isAppSwitch { onFocusChanged?() }
        // Electron builds its a11y tree only once asked; ask before anything reads the focused element.
        // A native app rejects the attribute and nothing latches, so this costs one AX call per switch.
        ManualAccessibilityActivation.shared.activate(pid: pid, for: .focus)

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AXFocusObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { me.handle(name) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            observedPID = 0
            return
        }
        observer = obs
        let appEl = AXUIElementCreateApplication(pid)
        appElement = appEl
        // Register the application-element notifications:
        //   - focused-element: focus changes bubble up on the application element;
        //   - focused-window / window-created: a NEW document window (fresh launch, ⌘N) makes its text
        //     view first responder WITHOUT a focused-element notification — only the window-level ones
        //     fire. Without these the selection notification was never registered for an app launched
        //     after us, so the post-insert echo (`hostEcho`) never arrived and type-along / Tab left the
        //     ghost stale (harness scenario smart-advance). Both re-point at the focused
        //     element; the focused-window one additionally counts as a focus change (see `handle`),
        //     which is what a ⌘N-in-TextEdit context switch is (scenario `personalization-learns`).
        // These fail with -25204 while the app is still launching — hence the retry ladder below.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        if !registerPendingAppNotifications() {
            scheduleAppNotificationRetry(step: 0)
        }
        registerSelectionOnFocusedElement()
    }

    /// The backoff ladder for a launch-racing app (see the type doc). Short enough that the first rung
    /// usually wins before the user types, long enough overall (~3.7 s) to outlast a cold app launch.
    private static let retryDelays: [Duration] = [
        .milliseconds(200), .milliseconds(500), .seconds(1), .seconds(2),
    ]

    /// Attempt every application-element notification that is not yet registered.
    /// Returns `true` once all of them are attached. Idempotent and O(1) once complete.
    @discardableResult
    private func registerPendingAppNotifications() -> Bool {
        guard let obs = observer, let appEl = appElement else { return false }
        if registeredAppNotifications.count == Self.appNotifications.count { return true }
        registrationAttempt += 1
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.appNotifications where !registeredAppNotifications.contains(name) {
            let err = AXObserverAddNotification(obs, appEl, name as CFString, refcon)
            // `.notificationAlreadyRegistered` means it IS attached (a partially-registered observer must
            // not be treated as a failure) — anything else means it is NOT, so keep retrying.
            if err == .success || err == .notificationAlreadyRegistered {
                registeredAppNotifications.insert(name)
                #if DEBUG
                if registrationAttempt > 1 {
                    acLog("[focus]: add %@ registered on attempt %d", name, registrationAttempt)
                }
                #endif
            } else {
                #if DEBUG
                acLog("[focus]: add %@ failed err=%d (attempt %d)",
                      name, Int(err.rawValue), registrationAttempt)
                #endif
            }
        }
        return registeredAppNotifications.count == Self.appNotifications.count
    }

    /// Retry the still-missing registrations after `retryDelays[step]`, without blocking the main thread.
    /// Abandons silently if the observer was rebuilt or torn down in the meantime.
    private func scheduleAppNotificationRetry(step: Int) {
        guard step < Self.retryDelays.count else {
            #if DEBUG
            acLog("[focus]: add gave up after %d attempts, missing=%d — relying on the predict-path belt",
                  registrationAttempt, Self.appNotifications.count - registeredAppNotifications.count)
            #endif
            return
        }
        let generation = registrationGeneration
        let pid = observedPID
        let delay = Self.retryDelays[step]
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            // Same observer, same app: a rebuild/teardown bumps the generation, and the pid check also
            // covers a recycled `pid_t` landing on a different process.
            guard self.registrationGeneration == generation, self.observedPID == pid,
                  self.observer != nil else { return }
            if !self.registerPendingAppNotifications() {
                self.scheduleAppNotificationRetry(step: step + 1)
            }
        }
    }

    /// Belt to the braces above: make sure the application-element notifications AND the selection
    /// notification are registered on whatever is focused NOW. Called from the predict path (which has
    /// just proven a focused editable element), so a missed window notification can cost at most one
    /// prediction's worth of stale echo — and a launch-race registration that outlived the retry ladder
    /// is repaired the moment the user types. Costs one `Set.count` compare once everything is attached.
    func ensureTrackingFocusedElement() {
        registerPendingAppNotifications()
        guard let appEl = appElement, observer != nil else { return }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return }
        let element = focused as! AXUIElement
        if let current = focusedElement, CFEqual(current, element) { return }
        registerSelectionOnFocusedElement()
    }

    /// (Re)register `kAXSelectedTextChangedNotification` on the *currently focused* element —
    /// selection notifications come from the text element, not the application element.
    private func registerSelectionOnFocusedElement() {
        guard let obs = observer, let appEl = appElement else { return }
        if let old = focusedElement {
            AXObserverRemoveNotification(obs, old, kAXSelectedTextChangedNotification as CFString)
            focusedElement = nil
        }
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return }
        let element = focused as! AXUIElement
        focusedElement = element
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(obs, element, kAXSelectedTextChangedNotification as CFString, refcon)
    }

    private func handle(_ notification: String) {
        #if DEBUG
        acLog("[focus]: notification %@", notification)
        #endif
        if notification == (kAXSelectedTextChangedNotification as String) {
            onCaretMoved?()
        } else if notification == (kAXFocusedUIElementChangedNotification as String) {
            // Hosts re-notify focus for things that are not focus changes — TextEdit emits two of these
            // on a ⌘A, ~100 ms apart. This branch used to fire the fan-out unconditionally, so a
            // re-notification that changed nothing tore down the ghost, threw away the KV cache
            // (`contextSwitch` → `invalidateKVCache, flushCache`) and re-selected the style segment that
            // personalization freezes for the burst. Only the first of those three is visible, which is why
            // it read as a ⌘A quirk. De-duplicated on the SAME
            // positive-proof predicate the focused-window branch below has always used.
            let previous = focusedElement
            // Re-point on EVERY notification, de-duplicated or not: it re-registers the selection
            // notification, and skipping it trades this bug for the -25204 registration blindness above.
            registerSelectionOnFocusedElement()
            fireFocusChangedUnlessUnmoved(from: previous, source: "focused-element")
        } else if notification == (kAXFocusedWindowChangedNotification as String) {
            // A NEW document window in the SAME app (⌘N in TextEdit) delivers only the window-level
            // notifications — never `kAXFocusedUIElementChangedNotification` — so without this the
            // context boundary was missed entirely: the previous document's ghost was never cleared,
            // the KV `contextSwitch` never fired, and personalization never committed (no
            // `[style]: commit`). Found by the runtime harness (scenario
            // `personalization-learns`). A focused-window change IS a focus change: new window, new
            // field, fresh start — so re-point the selection notification AND fire `onFocusChanged`.
            let previous = focusedElement
            registerSelectionOnFocusedElement()   // re-point at the new window's focused element
            fireFocusChangedUnlessUnmoved(from: previous, source: "focused-window")
        } else if notification == (kAXWindowCreatedNotification as String) {
            // Creation precedes focus — re-register only. Firing `onFocusChanged` here too would
            // double-clear (the focused-window notification that follows owns the boundary).
            registerSelectionOnFocusedElement()
        }
    }

    /// Fire the focus-change fan-out unless the focused element is **provably** the same one as before.
    ///
    /// One predicate for both notification branches, deliberately: two focus-identity rules that can
    /// disagree is a defect one layer up — the focused-window branch
    /// carried this treatment while the focused-element branch, which fires far more often, had none.
    ///
    /// Skip only on a POSITIVE proof of sameness: an unreadable element (either side nil) counts as
    /// changed. Never missing a real boundary beats avoiding a redundant, idempotent clear — which is
    /// also why the fix cannot regress a genuine focus change: where the element really moved, the
    /// behaviour is byte-identical to before.
    private func fireFocusChangedUnlessUnmoved(from previous: AXUIElement?, source: String) {
        let unchanged: Bool = {
            guard let previous, let current = focusedElement else { return false }
            return CFEqual(previous, current)
        }()
        if unchanged {
            #if DEBUG
            // Greppable: a suppressed fan-out is otherwise indistinguishable in the log from a
            // notification that never arrived, and the two have very different causes.
            acLog("[focus]: %@ unchanged — no focus change", source)
            #endif
            return
        }
        onFocusChanged?()
    }

    private func teardown() {
        // Invalidate any in-flight retry before the state it checks is cleared.
        registrationGeneration &+= 1
        registeredAppNotifications.removeAll()
        registrationAttempt = 0
        if let obs = observer {
            if let appEl = appElement {
                for name in Self.appNotifications {
                    AXObserverRemoveNotification(obs, appEl, name as CFString)
                }
            }
            if let focused = focusedElement {
                AXObserverRemoveNotification(obs, focused, kAXSelectedTextChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        appElement = nil
        focusedElement = nil
        observedPID = 0
    }
}
