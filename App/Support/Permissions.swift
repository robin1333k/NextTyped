import ApplicationServices
import AppKit
import NextTypedCore
import CoreGraphics
import IOKit.hid

/// Permission checks the loop depends on. v1 needs
/// Accessibility + Input Monitoring; **Screen Recording** is the second, opt-in TCC permission that
/// screen-context OCR requires — never requested unless the user enables OCR.
enum Permissions {
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// The title System Settings gives the Accessibility list on this macOS (macOS 27 renamed it).
    static var accessibilityListTitle: String {
        AccessibilityPermissionName.listTitle(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// Where to find the list by hand, worded for this macOS.
    static var accessibilityFindHint: String {
        AccessibilityPermissionName.findHint(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Screen Recording, read **live** — the OCR enable flow re-reads this right after prompting so
    /// the toggle can never show a state the OS didn't grant (the `LaunchAtLogin` precedent).
    /// Preflight does NOT prompt, which is what lets the disabled default stay permission-silent.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system Screen Recording prompt. Called **only** from the OCR enable flow, after
    /// the pre-permission explainer sheet. Returns the immediate verdict; the caller re-reads
    /// `hasScreenRecording` regardless, since the grant may land asynchronously.
    @MainActor @discardableResult static func requestScreenRecordingPrompt() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// `UserDefaults` key remembering that the system Accessibility prompt was shown. The prompt appears
    /// once per binary and a second request does nothing visible, so the Setup row offers "Open System
    /// Settings" once this is set. Every caller of `requestAccessibilityPrompt()` records it.
    static let accessibilityPromptShownKey = "setup.accessibilityPromptShown"

    /// Triggers the system Accessibility prompt (with an "Open System Settings" button) and records that
    /// it was shown.
    @MainActor static func requestAccessibilityPrompt() {
        UserDefaults.standard.set(true, forKey: accessibilityPromptShownKey)
        // Literal value of `kAXTrustedCheckOptionPrompt` — referencing that global
        // `var` directly is rejected under Swift 6 strict concurrency.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Triggers the system Input Monitoring prompt.
    @MainActor static func requestInputMonitoringPrompt() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Open the relevant System Settings → Privacy pane.
    @MainActor static func openSettings(for pane: PrivacyPane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

enum PrivacyPane {
    case accessibility, inputMonitoring, screenRecording, pasteboard

    var urlString: String {
        switch self {
        case .accessibility:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .screenRecording:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .pasteboard:
            // macOS 15.4+ "Paste from Other Apps" has no deep link of its own; the Privacy & Security pane is the closest.
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        }
    }
}
