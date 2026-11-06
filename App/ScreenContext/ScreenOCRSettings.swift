import NextTypedCore
import Foundation

/// The user-facing settings screen-context OCR reads, resolved fresh each time (the same discipline as
/// `AppSettingsStore.policy`: the loop reads live, so a Settings write takes effect on the next pass
/// with no extra wiring).
struct ScreenOCRSettings: Sendable {
    /// The Privacy-panel toggle. **Default false** — with it off, behaviour and
    /// permissions are identical to today's Accessibility-only app.
    var enabled: Bool
    /// Bundle IDs the user switched off in the Apps pane. That switch means
    /// **(a)+(b)** for OCR: no OCR while that app is focused, *and* excluded from every capture.
    var disabledBundleIDs: Set<String>

    init(enabled: Bool = false, disabledBundleIDs: Set<String> = []) {
        self.enabled = enabled
        self.disabledBundleIDs = disabledBundleIDs
    }

    /// Bundle IDs whose windows are excluded from the capture itself (`SCContentFilter`
    /// `excludingApplications`) — the **primary, structural** scrub-chain guard:
    /// their pixels are never captured at all, which is cheaper and more reliable than painting
    /// over rects afterwards. A starter list of credential holders; the user extends it by switching an
    /// app off in the Apps pane.
    ///
    /// Deliberately overlaps `AppEnablementPolicy.defaultBlocklist` without reusing it: that list
    /// answers "do we complete *in* this app", this one answers "may we photograph it" — different
    /// questions that happen to agree about password managers today.
    static let credentialBundleIDs: Set<String> = [
        // Password managers.
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.apple.Passwords",
        "com.apple.keychainaccess",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "com.dashlane.dashlanephonefinal",
        "in.sinew.Enpass-Desktop",
        "com.keepassium.mac",
        "org.keepassxc.keepassxc",
        // Banking / auth apps that render codes and balances.
        "com.apple.Wallet",
        "com.paypal.here",
    ]

    /// Everything excluded from a capture: the credential denylist plus whatever the user switched off.
    var excludedBundleIDs: Set<String> {
        Self.credentialBundleIDs.union(disabledBundleIDs)
    }
}
