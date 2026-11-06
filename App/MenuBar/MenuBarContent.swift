import NextTypedCore
import SwiftUI

/// The menu-bar dropdown: pause/resume + quick access to Settings and Quit.
struct MenuBarContent: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject private var updater = UpdateController.shared
    /// The programmatic opener, used instead of `SettingsLink` so the open has a **call site** that can
    /// front the window afterwards. See the button below.
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Another app interferes with our event tap. First item; the icon never changes.
        if let notice = coordinator.hostNotice {
            Text(notice.menuText)
            Divider()
        }

        // Model status — "Loading model…" / "Downloading model… NN%" on first run
        // until it's ready.
        Text(coordinator.modelLoadState.menuLabel)

        // Recoverable failure (no network / low disk): offer a retry rather than requiring a relaunch.
        if coordinator.modelLoadState.isFailed {
            Button("Retry model download") { coordinator.retryModelLoad() }
        }

        // Releases the weights now; the next prediction reloads them.
        if coordinator.modelLoadState.offersUnloadNow {
            Button("Unload model now") { coordinator.unloadModelNow() }
        }

        // Why the last field has a ghost or not. The verdict is in memory only and is
        // cleared on an app switch; the menu never changes the icon.
        let status = coordinator.surfaceStatus
        Text(SurfaceStatusText.line(for: status, appName: coordinator.temporaryQuietTarget?.name))
        // "Complete in <App>": the permanent per-app switch for the app the user writes in. It shows
        // the effective state (default mode and blocklist included) and writes the Apps-pane override.
        // "Complete on <host>" comes first when the last page had a host: a site rule beats the app
        // rule, so the app entry says so when this site has its own.
        if let site = coordinator.menuSite {
            Toggle("Complete on \(site.host)", isOn: Binding(
                get: { coordinator.menuSiteEnabled },
                set: { coordinator.setCompleteOnLastSite($0) }))
        }
        if let target = coordinator.temporaryQuietTarget {
            Toggle("Complete in \(target.name)", isOn: Binding(
                get: { coordinator.menuTargetEnabled },
                set: { coordinator.setCompleteInLastApp($0) }))
            if coordinator.menuSiteHasRule, let site = coordinator.menuSite {
                Text("\(site.host) has its own rule, which wins over this switch")
            }
        }

        // On-demand mode: why suggestions are not appearing by themselves. Shown only while
        // the posture is active. The other reasons are folded into `SurfaceStatus`; this one is its own line.
        if coordinator.batteryOnDemandActive {
            Text("On battery: press \(coordinator.forceActivateShortcutDescription ?? "the shortcut") for a suggestion")
        }

        Divider()

        Toggle("Paused", isOn: $coordinator.isPaused)

        // Temporary per-app quiet. A transient layer above the Apps-pane
        // preference: it can only suppress, it never writes what the user set, and it does not survive
        // a relaunch. The target is the app the user is WRITING in — by the time this menu is open,
        // NextTyped itself is frontmost, so the coordinator tracks the last other app instead.
        if let target = coordinator.temporaryQuietTarget {
            if coordinator.temporarilyQuietBundleIDs.contains(target.bundleID) {
                // The explicit half of decision 3c: pressing this puts a ghost back at the caret at
                // once, unlike the timer running out.
                Button("End quiet in \(target.name)") {
                    coordinator.endTemporaryQuiet(bundleID: target.bundleID, resumedExplicitly: true)
                }
            } else {
                Menu("Quiet completions in \(target.name)") {
                    ForEach(TemporaryQuietDuration.allCases, id: \.self) { duration in
                        Button(Self.label(for: duration)) { coordinator.quietCurrentApp(for: duration) }
                    }
                    Divider()
                    // "Indefinitely" is deliberately NOT a duration here: that is exactly what the
                    // Apps pane's per-app switch already is, and the transient layer must not reach
                    // that state anyway (decision 3a/3b).
                    Text("To turn an app off for good, switch off \"Complete in \(target.name)\" above.")
                }
            }
        }

        // Launch at login. Bound through the coordinator setter so the toggle
        // reflects the authoritative SMAppService status (a denial in System Settings leaves it off).
        Toggle("Launch at login", isOn: Binding(
            get: { coordinator.launchAtLogin },
            set: { coordinator.setLaunchAtLogin($0) }))

        // Today's accepted words next to the icon; the same switch as Settings → Statistics.
        Toggle("Show today's words in the menu bar", isOn: Binding(
            get: { coordinator.showWordCountInMenuBar },
            set: { coordinator.setShowWordCountInMenuBar($0) }))

        // Learning off and profile deleted in one step. Shown only while there is
        // something to stop or delete. The confirmation runs before anything changes.
        if coordinator.showsStopLearningMenuItem {
            Button("Stop learning and delete profile…") { confirmStopLearning() }
        }

        Button("Check for Updates...") { updater.checkForUpdates() }
            .disabled(!updater.isRunning)

        Divider()

        // `SettingsLink` was the supported opener and it is what this used to be. It was replaced on
        // 2026-08-31 because it opens the scene and returns **nothing** — no window, no completion —
        // so every attempt to bring the window forward had to live inside the window itself, keyed off
        // `didBecomeKeyNotification`. That notification does not arrive on exactly the opens that
        // fail: with another app holding the foreground the window is ordered in behind it and never
        // becomes key, so the fronting code did not run at all and the open left **no log line**.
        // Measured against the window server's own z-order: Settings sandwiched behind Finder, three
        // opens in a row, and the app silent for all three.
        //
        // `openSettings` is the same supported path with a call site, so the foreground can be taken
        // BEFORE the window is ordered in — an app that is already active has its new window placed on
        // top, which is why this reads as landing in front rather than jumping there. The keyboard
        // shortcut is unchanged, and the window-side observer stays as a second trigger.
        Button("Settings…") {
            SettingsWindowConfigurator.Coordinator.openAndFront { openSettings() }
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quit NextTyped") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    /// A menu cannot host a confirmation dialog, so this shows a modal alert. Wording follows
    /// Settings → Privacy's "Delete learned profile". Cancel returns without a change.
    private func confirmStopLearning() {
        let alert = NSAlert()
        alert.messageText = "Stop learning and delete everything NextTyped has learned about your writing?"
        alert.informativeText = "Learning is switched off. The encrypted profile and its key are removed. "
            + "Usage statistics are kept; they hold no text."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and delete")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await coordinator.stopLearningAndDeleteProfile() }
    }

    /// Menu wording for a duration. UI text lives here, not in Core (the `CompletionLength` precedent);
    /// the numbers come from the enum so the label and the timer cannot disagree.
    private static func label(for duration: TemporaryQuietDuration) -> String {
        duration == .oneHour ? "For 1 hour" : "For \(duration.minutes) minutes"
    }
}
