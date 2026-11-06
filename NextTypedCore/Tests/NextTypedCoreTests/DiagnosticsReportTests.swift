import Testing
@testable import NextTypedCore

@Suite("DiagnosticsReport")
struct DiagnosticsReportTests {
    static func fixed(settings: DiagnosticsReport.Settings = .init(),
                      crash: DiagnosticsReport.LastCrash? = nil,
                      tally: [DiagnosticsTagTally.Entry] = []) -> DiagnosticsReport {
        DiagnosticsReport(
            exportedAt: "2026-10-29 14:05",
            appVersion: .version("1.0"), appBuild: .version("42"),
            system: .init(macOSVersion: .version("27.2"), chip: .chip("Apple M3 Pro"), memoryGB: 36, freeDiskGB: 120),
            signing: .developer, accessibility: .granted, screenRecording: .notAsked,
            model: .init(name: .modelName("/Users/someone/Models/Qwen3.5-4B-Base-MLX-6bit"), source: .local,
                         load: .loaded, tier: .flushed, unloadAfterIdle: .automatic),
            settings: settings, lastCrash: crash, tally: tally)
    }

    @Test func rendersTheExpectedText() {
        var s = DiagnosticsReport.Settings()
        s.completionLength = .long
        s.appOverrideCount = 2
        let tally: [DiagnosticsTagTally.Entry] = [
            .init(event: .known(.gate, "rtl-text"), count: 4),
            .init(event: .other, count: 7),
        ]
        let text = Self.fixed(settings: s, crash: .init(date: "2026-10-27", exceptionType: "EXC_BAD_ACCESS"),
                              tally: tally).render()
        let expected = """
        NextTyped diagnostics report, exported 2026-10-29 14:05

        App
        App version: 1.0
        Build: 42
        Signing: developer

        System
        macOS: 27.2
        Chip: Apple M3 Pro
        Memory: 36 GB
        Free disk: 120 GB

        Permissions
        Accessibility: granted
        Screen Recording: not asked

        Model
        Name: Qwen3.5-4B-Base-MLX-6bit
        Source: local
        Load state: loaded
        Residency: flushed
        modelUnloadAfterIdle: automatic

        Settings
        globallyEnabled: on
        appOverrides: 2 (changed)
        appDefaultMode: everywhere
        showMenuBarIcon: on
        completionLength: long (changed)
        trailingPunctuation: bothShortcuts
        windowContextEnabled: on
        screenOCREnabled: off
        personalization: off
        snapshotReuseEnabled: on
        midTextCompletionEnabled: off
        spellingVariant: off
        launchAtLogin: off

        Last crash
        Date: 2026-10-27
        Exception: EXC_BAD_ACCESS

        Status counts
        gate rtl-text 4
        other 7

        This report holds no text you typed and no personalization data.

        """
        #expect(text == expected)
    }

    @Test func noCrashAndNoCountsRenderNone() {
        let text = Self.fixed().render()
        #expect(text.contains("Last crash\nnone\n"))
        #expect(text.contains("Status counts\nnone\n"))
    }

    @Test func changedMarkerOnlyOnDeviatingValues() {
        var s = DiagnosticsReport.Settings()
        s.screenOCREnabled = true
        s.globallyEnabled = false
        let text = Self.fixed(settings: s).render()
        #expect(text.contains("screenOCREnabled: on (changed)\n"))
        #expect(text.contains("globallyEnabled: off (changed)\n"))
        #expect(text.contains("showMenuBarIcon: on\n"))
    }

    @Test func snapshotReuseIsOnByDefaultAndOffIsMarkedChanged() {
        #expect(Self.fixed().render().contains("snapshotReuseEnabled: on\n"))
        var s = DiagnosticsReport.Settings()
        s.snapshotReuseEnabled = false
        #expect(Self.fixed(settings: s).render().contains("snapshotReuseEnabled: off (changed)\n"))
    }

    @Test func wholeGBRoundsToNearest() {
        #expect(DiagnosticsReport.wholeGB(bytes: 120_400_000_000) == 120)
        #expect(DiagnosticsReport.wholeGB(bytes: 120_600_000_000) == 121)
    }
}
