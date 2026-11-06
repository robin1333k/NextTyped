import ServiceManagement

/// Launch-at-login via `SMAppService.mainApp` (macOS 13+, fits the macOS 14+ target).
/// A thin wrapper so the AppCoordinator never touches
/// `ServiceManagement` directly and the authoritative on/off is always the live service `status`
/// (not a mirrored `UserDefaults` bool that can drift from what the user set in System Settings →
/// Login Items).
enum LaunchAtLogin {
    /// Whether the app is currently registered to launch at login. Reads the live service status, so it
    /// reflects a change the user made in System Settings, not just our last write.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register or unregister the app as a login item. Throws if the user has denied login items for the
    /// app in System Settings (`register()` reports it) — the caller reverts the UI to `isEnabled` so the
    /// toggle never shows a state the OS didn't actually grant. Idempotent: registering when already
    /// enabled (or unregistering when already off) is a no-op.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled else { return }
            try service.unregister()
        }
    }
}
