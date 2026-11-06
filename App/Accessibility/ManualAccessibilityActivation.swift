import ApplicationServices
import AppKit
import os

/// The single place `AXManualAccessibility` is switched on.
///
/// Electron/Chromium hosts only build their renderer a11y tree once an assistive client asks for it, by
/// setting `AXManualAccessibility` on the **application** element. That is one capability, per app, so it
/// has one correct policy — but it used to be written twice, once for caret geometry
/// (`CaretLocator`) and once for the reply harvest (`AXContextProvider`), and **the two copies
/// disagreed**. This type is that policy, written once:
///
/// 1. **Latch only on success.** The write fails while the target app is still launching (the same
///    -25204 window that once broke activation). Marking the pid activated *before* the call
///    turns one transient failure into a permanent one: the tree is never activated again for that app,
///    for the lifetime of our process, and the symptom is silence — a caret with no marker geometry, a
///    reply harvest that reports `turns=0` exactly like a surface with no transcript.
/// 2. **Forget a pid when its app quits.** macOS recycles `pid_t`, so a latch that outlives the app it
///    describes suppresses activation for whatever launches into that pid next.
///
/// One shared ``shared`` instance backs both consumers: the capability is global to the app being
/// activated, so a second set could only buy a second redundant write — and after (1) a *failed* write
/// no longer latches anywhere, so each consumer's retry loop survives regardless of which one drove the
/// successful write. The terminate→activate race is benign both ways: re-activation is idempotent.
///
/// A `final class` with lock-guarded state rather than an actor, because both callers are synchronous —
/// `CaretLocator` on its own actor, `AXContextProvider` on `harvestQueue`.
final class ManualAccessibilityActivation: Sendable {
    /// Which subsystem asked — DEBUG log only, so a missing activation can be attributed.
    enum Consumer: String {
        case caret
        case reply
        /// The app became frontmost, or a keystroke found no focused element. Without the tree an
        /// Electron host reports no focused element, so the floor stops at `no-focus` before the caret or
        /// reply consumer ever runs: the activation has to come first.
        case focus
    }

    static let shared = ManualAccessibilityActivation()

    private let activatedPids = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    init() {
        // The observer lives for the app lifetime (this LSUIElement agent never frees either consumer),
        // `[weak self]` only so the type stays free of a retain cycle claim it does not need.
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.forget(pid: app.processIdentifier)
        }
    }

    /// Switch on `pid`'s renderer a11y tree, at most once per pid. Idempotent and cheap to call on every
    /// keystroke: an already-activated pid costs one lock acquisition.
    ///
    /// The tree builds asynchronously in the other process, so what it exposes (marker geometry, the
    /// transcript) typically appears a keystroke or two after the first successful activation.
    func activate(pid: pid_t, for consumer: Consumer) {
        // Read-only check first: the write is what may fail, so the pid must not be inserted until it has.
        guard !activatedPids.withLock({ $0.contains(pid) }) else { return }
        let app = AXUIElementCreateApplication(pid)
        guard AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        else { return }
        let firstTime = activatedPids.withLock { $0.insert(pid).inserted }
        #if DEBUG
        if firstTime {
            acLog("[a11y]: set AXManualAccessibility on pid=%d for=%@ (Electron a11y tree; builds async)",
                  pid, consumer.rawValue)
        }
        #endif
    }

    /// Drop a pid's latch when that app terminates, so a recycled `pid_t` re-activates from scratch.
    private func forget(pid: pid_t) {
        activatedPids.withLock { _ = $0.remove(pid) }
    }
}
