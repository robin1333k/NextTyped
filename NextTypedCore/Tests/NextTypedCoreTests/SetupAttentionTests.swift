import Testing
@testable import NextTypedCore

@Suite("SetupAttention: the count badge on the Setup row of the Settings sidebar")
struct SetupAttentionTests {
    @Test("Accessibility granted and the model loaded: no badge")
    func configured() {
        #expect(SetupAttention.badgeCount(accessibilityMissing: false, modelFailed: false) == nil)
    }

    @Test("Accessibility missing only: badge 1")
    func accessibilityMissing() {
        #expect(SetupAttention.badgeCount(accessibilityMissing: true, modelFailed: false) == 1)
    }

    @Test("Model load failed only: badge 1")
    func modelFailed() {
        #expect(SetupAttention.badgeCount(accessibilityMissing: false, modelFailed: true) == 1)
    }

    @Test("Both requirements unmet: badge 2")
    func both() {
        #expect(SetupAttention.badgeCount(accessibilityMissing: true, modelFailed: true) == 2)
    }
}
