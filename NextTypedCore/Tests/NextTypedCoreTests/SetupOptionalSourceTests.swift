import Testing
@testable import NextTypedCore

@Suite("SetupOptionalSource")
struct SetupOptionalSourceTests {
    @Test func listsTheTwoSourcesThatShipOff() {
        #expect(SetupOptionalSource.allCases == [.screenText, .writingStyle])
    }

    @Test func offSwitchIsOffNotMissing() {
        #expect(SetupOptionalSource.screenText.state(isOn: false, needsPermission: false) == .off)
        #expect(SetupOptionalSource.writingStyle.state(isOn: false, needsPermission: false) == .off)
    }

    @Test func onSwitchIsOn() {
        #expect(SetupOptionalSource.screenText.state(isOn: true, needsPermission: false) == .on)
        #expect(SetupOptionalSource.writingStyle.state(isOn: true, needsPermission: false) == .on)
    }

    @Test func screenTextWithoutPermissionWaits() {
        #expect(SetupOptionalSource.screenText.state(isOn: true, needsPermission: true) == .waitingForPermission)
    }

    @Test func writingStyleNeverWaitsForPermission() {
        #expect(SetupOptionalSource.writingStyle.state(isOn: true, needsPermission: true) == .on)
    }
}
