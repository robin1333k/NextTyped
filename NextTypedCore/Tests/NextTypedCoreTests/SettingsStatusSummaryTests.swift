import Foundation
import Testing
@testable import NextTypedCore

@Suite struct SettingsStatusSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func nothingActiveReturnsNoLines() {
        let lines = SettingsStatusSummary.lines(paused: false, quiets: [], residency: .loaded, now: now)
        #expect(lines == [])
    }

    @Test func pausedOnly() {
        let lines = SettingsStatusSummary.lines(paused: true, quiets: [], residency: .loaded, now: now)
        #expect(lines == [StatusLine(kind: .attention, text: "Completions are paused", action: .resumeAll)])
    }

    @Test func oneQuietRoundsUpToWholeMinutes() {
        let until = now.addingTimeInterval(11 * 60 + 10)
        let lines = SettingsStatusSummary.lines(
            paused: false, quiets: [.init(bundleID: "com.apple.Notes", appName: "Notes", until: until)],
            residency: .loaded, now: now)
        #expect(lines == [StatusLine(
            kind: .attention, text: "Quiet in Notes for 12 more minutes",
            action: .resumeApp(bundleID: "com.apple.Notes"))])
    }

    @Test func lastMinuteIsSingular() {
        let until = now.addingTimeInterval(20)
        let lines = SettingsStatusSummary.lines(
            paused: false, quiets: [.init(bundleID: "com.apple.Notes", appName: "Notes", until: until)],
            residency: .loaded, now: now)
        #expect(lines.first?.text == "Quiet in Notes for 1 more minute")
    }

    @Test func twoQuietsListInNameOrder() {
        let lines = SettingsStatusSummary.lines(
            paused: false,
            quiets: [
                .init(bundleID: "com.apple.TextEdit", appName: "TextEdit", until: now.addingTimeInterval(300)),
                .init(bundleID: "com.apple.Notes", appName: "Notes", until: now.addingTimeInterval(900)),
            ],
            residency: .loaded, now: now)
        #expect(lines.map(\.text) == ["Quiet in Notes for 15 more minutes", "Quiet in TextEdit for 5 more minutes"])
    }

    @Test func unloadedShowsTheModelLineWithoutAction() {
        let lines = SettingsStatusSummary.lines(paused: false, quiets: [], residency: .unloaded, now: now)
        #expect(lines == [StatusLine(
            kind: .off, text: "Model unloaded to save memory. It reloads when you type.", action: nil)])
    }

    @Test func flushedIsInvisible() {
        let lines = SettingsStatusSummary.lines(paused: false, quiets: [], residency: .flushed, now: now)
        #expect(lines == [])
    }

    @Test func everythingTogetherKeepsPauseQuietsModelOrder() {
        let lines = SettingsStatusSummary.lines(
            paused: true,
            quiets: [.init(bundleID: "a", appName: "Notes", until: now.addingTimeInterval(60))],
            residency: .unloaded, now: now)
        #expect(lines.map(\.text) == [
            "Completions are paused", "Quiet in Notes for 1 more minute",
            "Model unloaded to save memory. It reloads when you type."])
    }

    @Test func quietCaptionForTheAppsRow() {
        let q = SettingsStatusSummary.Quiet(bundleID: "a", appName: "Notes", until: now.addingTimeInterval(11 * 60 + 10))
        #expect(SettingsStatusSummary.rowCaption(for: q, now: now) == "Quiet for 12 more minutes")
    }

    @Test func anExpiredQuietIsDropped() {
        let lines = SettingsStatusSummary.lines(
            paused: false, quiets: [.init(bundleID: "a", appName: "Notes", until: now.addingTimeInterval(-5))],
            residency: .loaded, now: now)
        #expect(lines == [])
    }
}
