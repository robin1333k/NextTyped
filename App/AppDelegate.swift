import AppKit
import SwiftUI
import NextTypedCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator.shared

#if DEBUG
    override init() {
        super.init()
        // Render mode must not take focus: a prohibited app is never activated, so the frontmost app
        // stays what it was (`settings-design` snapshot renderer).
        if SettingsSnapshotRenderer.outputDirectory(from: CommandLine.arguments) != nil {
            NSApp?.setActivationPolicy(.prohibited)
        }
    }
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
#if DEBUG
        // `--render-settings <out-dir>`: write a PNG of every Settings pane and quit, without starting
        // the loop (no event tap, no model load, no harness socket). DEBUG builds only.
        if let outDir = SettingsSnapshotRenderer.outputDirectory(from: CommandLine.arguments) {
            Task { @MainActor in
                await SettingsSnapshotRenderer(coordinator: coordinator, outputDirectory: outDir).run()
                NSApp.terminate(nil)
            }
            return
        }
        // `--render-onboarding <out-dir>`: the same for every onboarding page.
        if let outDir = OnboardingSnapshotRenderer.outputDirectory(from: CommandLine.arguments) {
            Task { @MainActor in
                await OnboardingSnapshotRenderer(coordinator: coordinator, outputDirectory: outDir).run()
                NSApp.terminate(nil)
            }
            return
        }
#endif
#if DEBUG
        // `--install-copy <source.app> <target-dir>`: run only the copy step of the move-to-Applications
        // flow and quit, so `scripts/check-install-copy.sh` can test it without an alert.
        if let i = CommandLine.arguments.firstIndex(of: "--install-copy"), CommandLine.arguments.count > i + 2 {
            let source = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let target = URL(fileURLWithPath: CommandLine.arguments[i + 2], isDirectory: true)
            let ok = (try? MoveToApplications.installCopy(of: source, into: target)) != nil
            exit(ok ? 0 : 1)
        }
        // `--choose-target <system-dir> <home>`: print the directory the move would use.
        if let i = CommandLine.arguments.firstIndex(of: "--choose-target"), CommandLine.arguments.count > i + 2 {
            let dir = MoveToApplications.chooseTargetDirectory(
                system: CommandLine.arguments[i + 1], home: CommandLine.arguments[i + 2])
            print(dir.path)
            exit(0)
        }
#endif
        // The policy decides: no updater under the harness or the fake engine.
        UpdateController.shared.start()
        Task { await coordinator.start() }
        installDeepLinkHost()
    }

    private var deepLinkHostWindow: NSWindow?

    /// A 1x1 invisible window whose view keeps `openSettings` reachable when the menu-bar icon is
    /// hidden (the label view, and with it its observer, is gone then). A probe (review of round 2)
    /// showed `openSettings` acts from a standalone hosting view; the in-app check is still owed.
    private func installDeepLinkHost() {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.contentView = NSHostingView(rootView: DeepLinkSettingsOpener(id: "host"))
        window.orderBack(nil)
        deepLinkHostWindow = window
    }

    func applicationDidBecomeActive(_ notification: Notification) {
#if DEBUG
        if SettingsSnapshotRenderer.outputDirectory(from: CommandLine.arguments) != nil { return }
#endif
        // The user may have just granted Accessibility in System Settings — bring the
        // loop up if it isn't running yet.
        Task { await coordinator.retryStartIfNeeded() }
    }

    /// `nexttyped://settings[/<pane>]` (opening a pane reads and writes nothing, so there is
    /// no confirmation). Never logs the raw URL, only the parsed pane or the rejection reason.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch DeepLink.parse(url) {
            case .success(.openSettings(let pane)):
                if let pane { SettingsNavigation.shared.selection = SettingsSection(pane) }
                // The router logs `[deeplink]: opened` once an opener was called (not proof that a window
                // is on screen; the `[settings]: open <verdict>` line is the proof), or `queued`.
                DeepLinkRouter.shared.request()
            case .failure(let reason):
                #if DEBUG
                acLog("[deeplink]: rejected reason=%@", reason.rawValue)
                #endif
            }
        }
    }

    /// Finder, Spotlight or the Dock opened the app again while it runs. With the icon hidden the menu
    /// is out of reach, so this is the way back to Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.requestSettingsFromReopen()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
#if DEBUG
        if SettingsSnapshotRenderer.outputDirectory(from: CommandLine.arguments) != nil { return }
#endif
        coordinator.stop()
    }
}
