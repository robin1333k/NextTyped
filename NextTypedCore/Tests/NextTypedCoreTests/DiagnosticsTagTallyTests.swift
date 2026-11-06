import Testing
@testable import NextTypedCore

@Suite("DiagnosticsTagTally")
struct DiagnosticsTagTallyTests {
    @Test func keepsAtMost500Events() {
        var t = DiagnosticsTagTally()
        for _ in 0..<600 { t.record(line: "[gate]: rtl-text") }
        #expect(t.eventCount == 500)
        #expect(t.entries == [.init(event: .known(.gate, "rtl-text"), count: 500)])
    }

    @Test func oldestEventsLeaveTheCountsFirst() {
        var t = DiagnosticsTagTally(capacity: 3)
        t.record(line: "[gate]: rtl-text")
        t.record(line: "[gate]: app-off app=com.x reason=override")
        t.record(line: "[gate]: app-off app=com.y reason=blocklist")
        t.record(line: "[gate]: app-off app=com.z reason=blocklist")
        #expect(t.entries == [.init(event: .known(.gate, "app-off"), count: 3)])
    }

    @Test func theEscFieldPauseGateIsCounted() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: esc-field-pause")
        #expect(t.entries == [.init(event: .known(.gate, "esc-field-pause"), count: 1)])
    }

    @Test func theLanguageGatesAreCountedNotOther() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: language-off lang=de")
        t.record(line: "[gate]: language-open reason=short")
        #expect(t.entries.contains(.init(event: .known(.gate, "language-off"), count: 1)))
        #expect(t.entries.contains(.init(event: .known(.gate, "language-open"), count: 1)))
    }

    @Test func theFirstPaintGateLinesAreCountedUnderOneToken() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: first-paint held")
        t.record(line: "[gate]: first-paint refill-deferred")
        t.record(line: "[gate]: first-paint final-dropped")
        #expect(t.entries == [.init(event: .known(.gate, "first-paint"), count: 3)])
    }

    @Test func theTakeBackGateIsCounted() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: take-back len=6")
        #expect(t.entries == [.init(event: .known(.gate, "take-back"), count: 1)])
    }

    @Test func unknownTagCountsAsOther() {
        var t = DiagnosticsTagTally()
        t.record(line: "[mlx]: predict prefix=\"zqxsentinel42\"")
        t.record(line: "no brackets zqxsentinel42")
        #expect(t.entries == [.init(event: .other, count: 2)])
    }

    @Test func unknownFirstTokenCountsAsOther() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: zqxsentinel42")
        #expect(t.entries == [.init(event: .other, count: 1)])
    }

    @Test func valuesAfterTheFirstTokenAreNotKept() {
        var t = DiagnosticsTagTally()
        t.record(line: "[gate]: app-off app=zqxsentinel42 reason=override")
        t.record(line: "[menubar]: words=12")
        t.record(line: "[residency]: focusChanged(editable: true) → flushCache")
        #expect(t.entries == [
            .init(event: .known(.gate, "app-off"), count: 1),
            .init(event: .known(.residency, "focusChanged"), count: 1),
            .init(event: .known(.menubar, "words"), count: 1),
        ])
    }
}
