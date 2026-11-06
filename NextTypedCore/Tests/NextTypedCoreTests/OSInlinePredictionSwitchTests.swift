import Testing
@testable import NextTypedCore

/// The store is the system boundary (the global preferences domain), so it is the one thing faked.
private final class FakeStore: OSInlinePredictionStore, @unchecked Sendable {
    var value: Bool?
    var writes: [Bool] = []
    /// When true, a write is silently dropped (a managed Mac, a sandbox), so the read-back differs.
    var dropsWrites = false
    init(_ value: Bool?) { self.value = value }
    func readValue() -> Bool? { value }
    func writeValue(_ newValue: Bool) {
        writes.append(newValue)
        if !dropsWrites { value = newValue }
    }
}

@Suite("OSInlinePredictionSwitch: an explicit, read-back-checked write of the global key")
struct OSInlinePredictionSwitchTests {
    @Test("Turning off writes false and reports the verified reading")
    func turnOff() {
        let store = FakeStore(nil)
        let result = OSInlinePredictionSwitch(store: store).turnOff()
        #expect(store.writes == [false])
        #expect(result == .changed(.off))
    }

    @Test("Turning back on writes an explicit true, so the row can still read the key")
    func turnBackOn() {
        let store = FakeStore(false)
        let result = OSInlinePredictionSwitch(store: store).turnBackOn()
        #expect(store.writes == [true])
        #expect(result == .changed(.on))
    }

    @Test("A write that does not stick is reported with the reading that remains")
    func writeDoesNotStick() {
        let store = FakeStore(true)
        store.dropsWrites = true
        let result = OSInlinePredictionSwitch(store: store).turnOff()
        #expect(result == .notApplied(stillReading: .on))
    }

    @Test("Turning off when it is already off writes nothing")
    func alreadyOff() {
        let store = FakeStore(false)
        let result = OSInlinePredictionSwitch(store: store).turnOff()
        #expect(store.writes.isEmpty)
        #expect(result == .changed(.off))
    }

    @Test("The row offers the button that matches the reading, and treats an unknown key as the enabled default")
    func buttons() {
        #expect(InlinePredictionStatus.toggleAction(for: .on) == .turnOff)
        #expect(InlinePredictionStatus.toggleAction(for: .off) == .turnBackOn)
        #expect(InlinePredictionStatus.toggleAction(for: .unknown) == .turnOff)
    }
}
