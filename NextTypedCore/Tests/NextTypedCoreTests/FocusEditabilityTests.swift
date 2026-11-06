import Testing
@testable import NextTypedCore

@Suite("FocusEditability: pre-warm only on a field we complete")
struct FocusEditabilityTests {
    private let allOn: (SurfaceIdentity) -> EnablementVerdict = { _ in .enabled }

    @Test("a plain text field in an enabled app is editable")
    func editable() {
        #expect(FocusEditability.rejection(floor: nil, bundleID: "com.apple.TextEdit", verdict: allOn) == nil)
    }

    @Test("every floor rejection wins, even in an enabled app")
    func floorWins() {
        for floor in [ContextRejection.noFocus, .secure, .chrome, .noText] {
            #expect(FocusEditability.rejection(floor: floor, bundleID: "com.apple.TextEdit", verdict: allOn) == floor)
        }
    }

    @Test("a field in a switched-off app is app-off")
    func appOff() {
        let policy = AppEnablementPolicy(overrides: ["com.agilebits.onepassword7": false])
        let result = FocusEditability.rejection(
            floor: nil, bundleID: "com.agilebits.onepassword7", verdict: { policy.verdict(for: $0) })
        #expect(result == .appOff)
    }

    @Test("the pause switch reads as global-off")
    func paused() {
        let policy = AppEnablementPolicy(globallyEnabled: false)
        let result = FocusEditability.rejection(
            floor: nil, bundleID: "com.apple.TextEdit", verdict: { policy.verdict(for: $0) })
        #expect(result == .globalOff)
    }

    @Test("an app without a bundle ID is judged as the empty ID")
    func noBundle() {
        let policy = AppEnablementPolicy(defaultMode: .onlySwitchedOn)
        #expect(FocusEditability.rejection(floor: nil, bundleID: nil, verdict: { policy.verdict(for: $0) }) == .appOff)
    }
}
