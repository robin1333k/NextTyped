import AppKit
import SwiftUI

/// Guides the user through the ONE permission the loop needs: **Accessibility**.
///
/// The loop runs on an ACTIVE keyboard `CGEventTap` (`.defaultTap`), which macOS
/// authorizes via Accessibility — NOT Input Monitoring. Input Monitoring only gates
/// *listen-only* taps / raw IOHID, so macOS never prompts for it here, and once the tap
/// is running `IOHIDCheckAccess` even reports it as "granted" misleadingly. We therefore
/// don't show Input Monitoring at all — Accessibility alone is the real (and only) gate.
@MainActor
enum PermissionsOnboarding {
    private static var window: NSWindow?

    /// Show onboarding while Accessibility is missing, or until the Tab practice step has been finished,
    /// skipped or closed once (issue `onboarding/148`).
    static func presentIfNeeded(coordinator: AppCoordinator) {
        guard !Permissions.hasAccessibility || !TabPracticeModel.alreadyFinished else { return }
        present(coordinator: coordinator)
    }

    static func present(coordinator: AppCoordinator) {
        // Note: we do NOT auto-fire the prompt here — the system Accessibility prompt
        // only appears once per launch, so we leave it to the window's "Request" button
        // so that button always does something when clicked.
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(coordinator: coordinator))
        let w = NSWindow(contentViewController: hosting)
        w.title = "NextTyped Setup"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        // Closing the window ends the practice step for good: shown once.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                if Permissions.hasAccessibility {
                    // A failed model load never shows the practice view; closing then still ends the step,
                    // or the window would return on every launch.
                    coordinator.tabPractice.markFinishedOnClose(modelFailed: coordinator.modelLoadState == .failed)
                }
                coordinator.tabPractice.deactivate()
            }
        }
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Live Accessibility state for the onboarding + Settings UI. Re-checks on app
/// activation (returning from System Settings flips this without a relaunch).
@MainActor
final class PermissionsModel: ObservableObject {
    @Published var hasAccessibility = PermissionsModel.currentAccessibility()

#if DEBUG
    /// Snapshot fixture `accessibility-missing` (`SettingsSnapshotFixture`): report Accessibility as not
    /// granted whatever the OS says. Set before the Setup pane is built.
    static var debugForceAccessibilityMissing = false
#endif

    private static func currentAccessibility() -> Bool {
#if DEBUG
        if debugForceAccessibilityMissing { return false }
#endif
        return Permissions.hasAccessibility
    }

    /// The loop is ready once Accessibility is granted (nothing else is required).
    var isReady: Bool { hasAccessibility }

    // Retained so the block-based observer lives as long as the model (app lifetime).
    private var activationObserver: (any NSObjectProtocol)?

    init() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        hasAccessibility = Self.currentAccessibility()
    }
}

/// The Accessibility status row with a single "Request" button (which triggers the
/// system Accessibility prompt — that prompt itself offers "Open System Settings").
/// Shared by onboarding and the Settings → Permissions tab.
struct PermissionRow: View {
    let title: String
    let subtitle: String
    let granted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button("Request") { Permissions.requestAccessibilityPrompt() }
            }
        }
    }
}
