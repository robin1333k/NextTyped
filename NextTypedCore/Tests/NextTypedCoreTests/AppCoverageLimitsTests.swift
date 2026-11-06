import Testing
@testable import NextTypedCore

@Suite struct AppCoverageLimitsTests {
    @Test func mailComposeBodyHasNoAccessibilityText() throws {
        let limit = try #require(AppCoverageLimits.limit(forBundleID: "com.apple.mail"))
        #expect(limit.mode == .noText)
        #expect(limit.reason == "The compose body does not share its text with Accessibility.")
        #expect(limit.statement
            == "No text through Accessibility. The compose body does not share its text with Accessibility.")
    }

    @Test func vsCodeExposesLittleText() throws {
        let limit = try #require(AppCoverageLimits.limit(forBundleID: "com.microsoft.VSCode"))
        #expect(limit.mode == .littleText)
        #expect(limit.reason == "This Electron app exposes little usable text through Accessibility.")
    }

    @Test func slackNotionAndDiscordShareTheElectronReason() {
        for id in ["com.tinyspeck.slackmacgap", "notion.id", "com.hnc.Discord"] {
            #expect(AppCoverageLimits.limit(forBundleID: id)?.mode == .littleText)
        }
    }

    @Test func terminalsExplainTheTabKey() throws {
        let limit = try #require(AppCoverageLimits.limit(forBundleID: "com.apple.Terminal"))
        #expect(limit.mode == .tabIsShellCompletion)
        #expect(limit.reason == "The shell uses Tab for its own completion. You can switch it on per app.")
        #expect(limit.statement == "Off by default. The shell uses Tab for its own completion. You can switch it on per app.")
    }

    @Test func anAppWithoutEvidenceHasNoLimit() {
        #expect(AppCoverageLimits.limit(forBundleID: "com.apple.TextEdit") == nil)
        #expect(AppCoverageLimits.limit(forBundleID: "com.example.unknown") == nil)
    }

    @Test func everyEntryNamesItsHost() {
        #expect(AppCoverageLimits.all.isEmpty == false)
        for entry in AppCoverageLimits.all {
            #expect(entry.bundleIDs.isEmpty == false)
            #expect(entry.hostName.isEmpty == false)
            #expect(entry.limit.statement.contains("Checked") == false)
        }
    }
}
