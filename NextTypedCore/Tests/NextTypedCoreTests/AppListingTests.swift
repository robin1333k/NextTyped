import Testing
@testable import NextTypedCore

@Suite struct AppListingTests {
    typealias Source = AppListing.Source

    @Test func mergesRunningOverriddenInstalledBlocklistedAndAddedAppsSortedAndDeduped() {
        let entries = AppListing.entries(
            running: [Source(bundleID: "com.apple.TextEdit", name: "TextEdit"),
                      Source(bundleID: "com.apple.Terminal", name: "Terminal")],
            overridden: [Source(bundleID: "com.apple.Notes", name: "Notes"),
                         Source(bundleID: "com.apple.TextEdit", name: "TextEdit")],
            installedBlocklisted: [Source(bundleID: "com.apple.Terminal", name: "Terminal"),
                                   Source(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")],
            added: [Source(bundleID: "com.example.zeta", name: "alpha Tool")])
        #expect(entries.map(\.name) == ["alpha Tool", "Notes", "Terminal", "TextEdit", "Visual Studio Code"])
        #expect(entries.map(\.blocklisted) == [false, false, true, false, true])
    }

    @Test func installedBlocklistedAppAppearsWithoutBeingRunning() {
        let entries = AppListing.entries(
            running: [], overridden: [],
            installedBlocklisted: [Source(bundleID: "com.apple.Terminal", name: "Terminal")], added: [])
        #expect(entries == [AppListing.Entry(bundleID: "com.apple.Terminal", name: "Terminal", blocklisted: true)])
    }

    @Test func captionNamesTheEffectiveStateInEveryAppMode() {
        #expect(AppListing.caption(override: nil, blocklisted: false, mode: .everywhere) == "On")
        #expect(AppListing.caption(override: nil, blocklisted: true, mode: .everywhere) == "Off, blocklisted")
        #expect(AppListing.caption(override: true, blocklisted: true, mode: .everywhere) == "Always on")
        #expect(AppListing.caption(override: false, blocklisted: false, mode: .everywhere) == "Always off")
    }

    @Test func captionInOnlySwitchedOnModeShowsNoChoiceAsOff() {
        #expect(AppListing.caption(override: nil, blocklisted: false, mode: .onlySwitchedOn) == "Off, not switched on")
        #expect(AppListing.caption(override: nil, blocklisted: true, mode: .onlySwitchedOn) == "Off, not switched on")
        #expect(AppListing.caption(override: true, blocklisted: true, mode: .onlySwitchedOn) == "Always on")
        #expect(AppListing.caption(override: false, blocklisted: false, mode: .onlySwitchedOn) == "Always off")
    }

    @Test func defaultLabelFollowsTheBlocklistAndTheMode() {
        #expect(AppListing.defaultLabel(blocklisted: false, mode: .everywhere) == "Default (on)")
        #expect(AppListing.defaultLabel(blocklisted: true, mode: .everywhere) == "Default (off)")
        #expect(AppListing.defaultLabel(blocklisted: false, mode: .onlySwitchedOn) == "Default (off)")
        #expect(AppListing.defaultLabel(blocklisted: true, mode: .onlySwitchedOn) == "Default (off)")
    }

    @Test func filterMatchesNameCaseInsensitivelyAndEmptyQueryKeepsAll() {
        let all = [AppListing.Entry(bundleID: "a", name: "Notes", blocklisted: false),
                   AppListing.Entry(bundleID: "b", name: "TextEdit", blocklisted: false)]
        #expect(AppListing.filter(all, query: "").count == 2)
        #expect(AppListing.filter(all, query: "EDIT").map(\.bundleID) == ["b"])
        #expect(AppListing.filter(all, query: "zzz").isEmpty)
    }

    @Test func noMatchTextHasNoQuotes() {
        #expect(AppListing.noMatchText(query: "xyz") == "No apps match xyz.")
    }
}
