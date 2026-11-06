import Testing
@testable import NextTypedCore

@Suite("DiagnosticsRedaction")
struct DiagnosticsRedactionTests {
    static let sentinel = "zqxsentinel42"

    @Test func sentinelNeverReachesTheReport() {
        var tally = DiagnosticsTagTally()
        for line in ["[mlx]: predict prefix=\"\(Self.sentinel)\"",
                     "[gate]: \(Self.sentinel)",
                     "[gate]: app-off app=\(Self.sentinel) reason=override"] {
            tally.record(line: line)
        }
        let report = DiagnosticsReport(
            exportedAt: Self.sentinel,
            appVersion: .version("1.0 \(Self.sentinel)!"), appBuild: .version(Self.sentinel + "/"),
            system: .init(macOSVersion: .version("27 \(Self.sentinel)\n"), chip: .chip("\(Self.sentinel)\u{0}"),
                          memoryGB: 16, freeDiskGB: 50),
            signing: .unknown, accessibility: .denied, screenRecording: .denied,
            model: .init(name: .modelName("/Users/\(Self.sentinel)/Models/\(Self.sentinel)"),
                         source: .local, load: .failed, tier: .unloaded, unloadAfterIdle: .never),
            settings: .init(),
            lastCrash: .init(date: Self.sentinel, exceptionType: Self.sentinel),
            tally: tally.entries)
        let text = report.render()
        #expect(!text.contains(Self.sentinel))
        #expect(text.contains("app-off"))
        #expect(text.contains("App version: invalid"))
        #expect(text.contains("Name: custom"))
    }

    @Test func bareSentinelIsRejectedByEveryVersionAndChipField() {
        #expect(DiagnosticsSafeString.version(Self.sentinel).rendered == "invalid")
        #expect(DiagnosticsSafeString.chip(Self.sentinel).rendered == "invalid")
        #expect(DiagnosticsSafeString.chip("Apple \(Self.sentinel)").rendered == "invalid")
        #expect(DiagnosticsSafeString.chip("Apple M3 Pro").rendered == "Apple M3 Pro")
        #expect(DiagnosticsSafeString.modelName(Self.sentinel).rendered == "custom")
    }

    @Test func versionAcceptsTheDocumentedCharacterSet() {
        #expect(DiagnosticsSafeString.version("1.2.3 (45)").rendered == "1.2.3 (45)")
        #expect(DiagnosticsSafeString.version("").rendered == "invalid")
        #expect(DiagnosticsSafeString.version(String(repeating: "1", count: 41)).rendered == "invalid")
        #expect(DiagnosticsSafeString.version("a/b").rendered == "invalid")
    }

    @Test func modelNameIsTheLastPathComponentOfAShippedFamily() {
        #expect(DiagnosticsSafeString.modelName("Robin1333k/Qwen3.5-2B-Base-MLX-6bit").rendered == "Qwen3.5-2B-Base-MLX-6bit")
        #expect(DiagnosticsSafeString.modelName("/Users/a/Models/Qwen3.5-4B-Base-MLX-6bit/").rendered == "Qwen3.5-4B-Base-MLX-6bit")
        #expect(DiagnosticsSafeString.modelName("/Users/a/Models/My Secret Notes").rendered == "invalid")
        #expect(DiagnosticsSafeString.modelName("/Users/a/Models/tax-returns").rendered == "custom")
    }
}
