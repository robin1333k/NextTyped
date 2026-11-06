import Testing
@testable import NextTypedCore

@Suite struct AppEnablementPolicyTests {
    @Test func enabledByDefaultInAnOrdinaryApp() {
        let policy = AppEnablementPolicy()
        #expect(policy.isEnabled(forBundleID: "com.apple.TextEdit"))
    }

    @Test func disabledInABlocklistedApp() {
        let policy = AppEnablementPolicy()
        #expect(!policy.isEnabled(forBundleID: "com.apple.Terminal"))
        #expect(!policy.isEnabled(forBundleID: "com.microsoft.VSCode"))
    }

    @Test func disabledInNativeCodeEditors() {
        // Native IDEs expose an AXTextArea (which the field-size gate allows), so the app
        // blocklist is the only thing that keeps a prose ghost out of source code.
        let policy = AppEnablementPolicy()
        #expect(!policy.isEnabled(forBundleID: "com.apple.dt.Xcode"))
        #expect(!policy.isEnabled(forBundleID: "com.jetbrains.intellij"))
        #expect(!policy.isEnabled(forBundleID: "com.sublimetext.4"))
    }

    @Test func userOverrideBeatsTheBlocklist() {
        let policy = AppEnablementPolicy(overrides: ["com.apple.Terminal": true])
        #expect(policy.isEnabled(forBundleID: "com.apple.Terminal"))
    }

    @Test func userCanDisableAnOrdinaryApp() {
        let policy = AppEnablementPolicy(overrides: ["com.apple.TextEdit": false])
        #expect(!policy.isEnabled(forBundleID: "com.apple.TextEdit"))
    }

    @Test func globalPauseDisablesEverythingIncludingForcedOnApps() {
        let policy = AppEnablementPolicy(globallyEnabled: false, overrides: ["com.apple.TextEdit": true])
        #expect(!policy.isEnabled(forBundleID: "com.apple.TextEdit"))
    }

    /// Literal bundle ids, each verified from a public source.
    private static let passwordManagerIDs = [
        "com.apple.Passwords",
        "org.keepassxc.keepassxc",
        "com.markmcguill.strongbox.mac",
        "com.hicknhacksoftware.MacPass",
        "me.proton.pass.electron",
        "com.lastpass.lastpassmacdesktop",
        "com.lastpass.LastPass",
        "com.keepersecurity.passwordmanager",
        "com.callpod.keepermac.lite",
        "com.nordsec.nordpass",
        "in.sinew.Enpass-Desktop",
        "com.SiberSystems.RoboForm",
        "com.outercorner.Secrets",
    ]

    @Test(arguments: passwordManagerIDs)
    func passwordManagerIsDisabledByDefault(bundleID: String) {
        #expect(!AppEnablementPolicy().isEnabled(forBundleID: bundleID))
    }

    @Test(arguments: passwordManagerIDs)
    func passwordManagerIsEnabledByAnExplicitOnOverride(bundleID: String) {
        let policy = AppEnablementPolicy(overrides: [bundleID: true])
        #expect(policy.isEnabled(forBundleID: bundleID))
    }

    @Test func onePasswordBitwardenAndKeychainStayBlocked() {
        let policy = AppEnablementPolicy()
        #expect(!policy.isEnabled(forBundleID: "com.1password.1password"))
        #expect(!policy.isEnabled(forBundleID: "com.bitwarden.desktop"))
        #expect(!policy.isEnabled(forBundleID: "com.apple.keychainaccess"))
    }

    // MARK: verdict and default mode

    private func surface(_ id: String) -> SurfaceIdentity { SurfaceIdentity(bundleID: id) }

    @Test func absentModeReadsAsEverywhereAndOrdinaryAppIsEnabled() {
        let policy = AppEnablementPolicy()
        #expect(policy.defaultMode == .everywhere)
        #expect(policy.verdict(for: surface("com.apple.TextEdit")) == .enabled)
    }

    @Test func everywhereModeReportsTheBlocklistReason() {
        let policy = AppEnablementPolicy()
        #expect(policy.verdict(for: surface("com.apple.Terminal")) == .disabled(.blocklist))
    }

    @Test func overrideFalseReportsTheOverrideReason() {
        let policy = AppEnablementPolicy(overrides: ["com.apple.TextEdit": false])
        #expect(policy.verdict(for: surface("com.apple.TextEdit")) == .disabled(.override))
    }

    @Test func onlySwitchedOnDisablesAnAppWithoutOverride() {
        let policy = AppEnablementPolicy(defaultMode: .onlySwitchedOn)
        #expect(policy.verdict(for: surface("com.apple.TextEdit")) == .disabled(.defaultOff))
    }

    @Test func onlySwitchedOnEnablesAnAppWithATrueOverride() {
        let policy = AppEnablementPolicy(overrides: ["com.apple.TextEdit": true], defaultMode: .onlySwitchedOn)
        #expect(policy.verdict(for: surface("com.apple.TextEdit")) == .enabled)
    }

    @Test func onlySwitchedOnEnablesABlocklistedAppWithATrueOverride() {
        let policy = AppEnablementPolicy(overrides: ["com.apple.Terminal": true], defaultMode: .onlySwitchedOn)
        #expect(policy.verdict(for: surface("com.apple.Terminal")) == .enabled)
    }

    @Test func onlySwitchedOnIgnoresTheBlocklistReason() {
        let policy = AppEnablementPolicy(defaultMode: .onlySwitchedOn)
        #expect(policy.verdict(for: surface("com.apple.Terminal")) == .disabled(.defaultOff))
    }

    @Test func pauseBeatsATrueOverrideInBothModes() {
        for mode in [DefaultMode.everywhere, .onlySwitchedOn] {
            let policy = AppEnablementPolicy(
                globallyEnabled: false, overrides: ["com.apple.TextEdit": true], defaultMode: mode)
            #expect(policy.verdict(for: surface("com.apple.TextEdit")) == .disabled(.pause))
            #expect(!policy.isEnabled(forBundleID: "com.apple.TextEdit"))
        }
    }

    // MARK: site rules

    private func site(_ pattern: String, _ enabled: Bool) -> SiteRule {
        SiteRule(pattern: pattern, enabled: enabled)!
    }

    private func onSite(_ bundleID: String, _ host: String?) -> SurfaceIdentity {
        SurfaceIdentity(bundleID: bundleID, host: host)
    }

    @Test func siteRuleOffInAnEnabledBrowserDisablesIt() {
        let policy = AppEnablementPolicy(siteRules: [site("mail.example.com", false)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", "mail.example.com")) == .disabled(.siteRule))
        #expect(policy.verdict(for: onSite("com.apple.Safari", "other.com")) == .enabled)
    }

    @Test func siteRuleOnBeatsAnAppOverrideOff() {
        let policy = AppEnablementPolicy(
            overrides: ["com.apple.Safari": false], siteRules: [site("docs.google.com", true)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", "docs.google.com")) == .enabled)
        #expect(policy.verdict(for: onSite("com.apple.Safari", "other.com")) == .disabled(.override))
    }

    @Test func siteRuleOnWorksInOnlySwitchedOnMode() {
        let policy = AppEnablementPolicy(defaultMode: .onlySwitchedOn, siteRules: [site("docs.google.com", true)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", "docs.google.com")) == .enabled)
        #expect(policy.verdict(for: onSite("com.apple.Safari", "other.com")) == .disabled(.defaultOff))
    }

    @Test func siteRuleOnBeatsTheBlocklist() {
        let policy = AppEnablementPolicy(siteRules: [site("example.com", true)])
        #expect(policy.verdict(for: onSite("com.apple.Terminal", "example.com")) == .enabled)
    }

    @Test func pauseBeatsASiteRuleOn() {
        let policy = AppEnablementPolicy(globallyEnabled: false, siteRules: [site("docs.google.com", true)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", "docs.google.com")) == .disabled(.pause))
    }

    @Test func aNilHostIgnoresAllSiteRules() {
        let policy = AppEnablementPolicy(siteRules: [site("*.example.com", false), site("example.com", false)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", nil)) == .enabled)
    }

    @Test func theMostSpecificSiteRuleWinsInTheVerdict() {
        let policy = AppEnablementPolicy(siteRules: [site("*.example.com", false), site("*.mail.example.com", true)])
        #expect(policy.verdict(for: onSite("com.apple.Safari", "a.mail.example.com")) == .enabled)
        #expect(policy.verdict(for: onSite("com.apple.Safari", "a.example.com")) == .disabled(.siteRule))
    }

    @Test func siteRuleReasonReadsAsSiteRule() {
        #expect(DisabledReason.siteRule.rawValue == "site-rule")
        #expect(EnablementVerdict.disabled(.siteRule).rejection == .appOff)
    }

    @Test func modeParsesFromStoredStringAndUnknownReadsAsEverywhere() {
        #expect(DefaultMode(storedValue: "onlySwitchedOn") == .onlySwitchedOn)
        #expect(DefaultMode(storedValue: "everywhere") == .everywhere)
        #expect(DefaultMode(storedValue: "bogus") == .everywhere)
        #expect(DefaultMode(storedValue: nil) == .everywhere)
    }

    // The "at most two lines" limit is a layout rule that the settings snapshots check; this test pins
    // the label and footer wording only.
    @Test func eachModeHasAPickerLabelAndAFooterOfAtMostTwoLines() {
        #expect(DefaultMode.everywhere.pickerLabel == "Every app")
        #expect(DefaultMode.onlySwitchedOn.pickerLabel == "Only apps I turn on")
        #expect(DefaultMode.everywhere.pickerFooter
            == "Apps without a choice below complete, except the ones that start off.")
        #expect(DefaultMode.onlySwitchedOn.pickerFooter
            == "Apps without a choice below stay off, including the ones that normally start on.")
    }
}
