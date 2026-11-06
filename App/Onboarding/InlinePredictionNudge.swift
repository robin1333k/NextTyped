import AppKit
import NextTypedCore

/// One-time, dismissible **first-run nudge** to disable macOS's own inline text prediction
/// .
///
/// macOS (Sonoma 14.2+) ships system-wide inline predictive text — gray next-word suggestions in
/// native fields, accepted with `Tab`. Our ghost is *also* `Tab`-accepted, so with both features on
/// the user sees **two gray ghosts** at once (we always win `Tab` while our ghost shows — see
/// `SuggestionSession.interceptKey` → `.suppress` — so it is never a double-*accept*, only a visual
/// collision). NextTyped takes a **replacement stance**: we recommend turning the OS feature off
/// once, removing the competing ghost at the source.
///
/// **Soft hint only.** The OS enablement lives in the **undocumented** `NSGlobalDomain` key
/// `NSAutomaticInlinePredictionEnabled` (Boolean; **absent ⇒ enabled**, the macOS default). We read it *defensively* and **never gate behavior on it** — it only decides whether to
/// show a dismissible hint. If the key is absent, renamed, or a non-Bool, we degrade by treating the
/// feature as enabled (so the nudge still informs the user; it is harmless if they already disabled it).
///
/// That default is right **here and only here**, because the cost of guessing wrong is one dismissible
/// dialog. The *persistent* Settings → Setup row reads the same key through the same accessor but
/// renders nothing on an unknown — see `InlinePredictionStatus` in Core, which owns both readings so
/// the two surfaces cannot drift into disagreeing about what was read.
///
/// The reading itself is Core-tested; the alert and the `CFPreferences` read are not unit-testable,
/// so verify them at runtime.
@MainActor
enum InlinePredictionNudge {
    /// Our own one-time guard (in the app's `UserDefaults` domain — distinct from the OS key below).
    private static let shownKey = "inlinePredictionNudgeShown"

    /// The **undocumented** `NSGlobalDomain` key for macOS inline predictive text.
    nonisolated private static let osFeatureKey = "NSAutomaticInlinePredictionEnabled"

    /// One **fresh** read of the global key, classified by the pure-Core `OSInlinePredictionReading`.
    ///
    /// Deliberately **not** `UserDefaults.standard.object(forKey:)`, which is how this started: that
    /// search list does include `NSGlobalDomain`, but it is a per-process **cache** of another
    /// process's file, and it is refreshed around app activation. So a poll through `UserDefaults`
    /// keeps returning the stale value for as long as our window stays in the background — i.e. for
    /// exactly the duration of the task the Settings row is advising about — while testing as working
    /// the moment anybody clicks into our window to check. Nor does
    /// `UserDefaults.didChangeNotification` help: it is process-local and never fires for another
    /// process's write.
    ///
    /// `CFPreferencesAppSynchronize` drops that cache; `CFPreferencesCopyAppValue` against
    /// `kCFPreferencesAnyApplication` then reads `NSGlobalDomain` itself. Both are microseconds, and
    /// this is only ever called from the Settings window's own poll or once at launch — never from the
    /// typing path.
    ///
    /// Soft hint only — must not gate behavior.
    static var osInlinePredictionReading: OSInlinePredictionReading {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let raw = CFPreferencesCopyAppValue(osFeatureKey as CFString, kCFPreferencesAnyApplication)
        return .reading(of: raw as? Bool)
    }

    /// The `CFPreferences` side of the Settings button. It writes
    /// `NSGlobalDomain` and flushes, so other processes see the change without waiting for our exit.
    struct GlobalStore: OSInlinePredictionStore {
        func readValue() -> Bool? {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return CFPreferencesCopyAppValue(InlinePredictionNudge.osFeatureKey as CFString,
                                             kCFPreferencesAnyApplication) as? Bool
        }

        func writeValue(_ newValue: Bool) {
            CFPreferencesSetValue(InlinePredictionNudge.osFeatureKey as CFString, newValue as CFBoolean,
                                  kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                     kCFPreferencesAnyHost)
        }
    }

    private static var alreadyShown: Bool {
        UserDefaults.standard.bool(forKey: shownKey)
    }

    /// Show the nudge iff it hasn't been shown before **and** the OS feature is (soft-read as) enabled.
    /// No-op otherwise. Either button dismisses it permanently (one-time by construction).
    static func presentIfNeeded() {
        guard !alreadyShown else { return }
        let reading = osInlinePredictionReading
        guard InlinePredictionStatus.nudgeShouldPresent(for: reading) else { return }
        present(reading: reading)
    }

    private static func present(reading: OSInlinePredictionReading) {
        // Mark shown up front, before any user choice — the nudge is strictly one-time regardless of
        // which button is clicked (or if the alert is dismissed by other means).
        UserDefaults.standard.set(true, forKey: shownKey)
        #if DEBUG
        // Log the value that was actually read, never a hardcoded assumption about it: this issue
        // family has already lost runtime sessions to log lines asserting facts they never checked
        // . Observed 2026-08-28 claiming "absent" with the key present and `true`.
        acLog("[nudge]: presenting macOS inline-prediction nudge (\(osFeatureKey)=\(reading.rawValue))")
        #endif

        let alert = NSAlert()
        alert.messageText = "macOS inline predictions are on"
        alert.informativeText = """
            NextTyped replaces macOS's built-in inline text predictions. With both on, you may see \
            two gray suggestions at once. To use NextTyped alone, turn the macOS feature off in \
            System Settings › Keyboard › Text Input › Edit… › “Show inline predictive text”.

            You can also disable NextTyped for specific apps from its menu-bar Settings.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Keyboard Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openKeyboardSettings()
        }
    }

    /// Best-effort deep link to the Keyboard settings pane. There is no reliable anchor for the exact
    /// "Text Input › Edit…" sub-sheet, so we open the Keyboard pane and rely on the alert's written
    /// instructions for the last step. Silently no-ops if the URL can't be opened. Internal so the
    /// Settings → Setup pane can reuse it for its "macOS text suggestions" row.
    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
