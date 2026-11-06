import Testing
@testable import NextTypedCore

@Suite("MenuBarIconPolicy: when the menu bar icon is inserted")
struct MenuBarIconPolicyTests {
    @Test("The user wants the icon and nothing needs attention: shown")
    func wantedAndQuiet() {
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: true, needsAttention: false) == true)
    }

    @Test("The user wants the icon and something needs attention: shown")
    func wantedAndAttention() {
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: true, needsAttention: true) == true)
    }

    @Test("The user hid the icon and nothing needs attention: hidden")
    func hiddenAndQuiet() {
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: false, needsAttention: false) == false)
    }

    @Test("The user hid the icon but something needs attention: forced visible")
    func hiddenButAttention() {
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: false, needsAttention: true) == true)
    }

    @Test("Missing Accessibility is reported before a failed model")
    func accessibilityWins() {
        #expect(MenuBarIconPolicy.attentionReason(accessibilityMissing: true, modelFailed: true) == .accessibility)
        #expect(MenuBarIconPolicy.attentionReason(accessibilityMissing: true, modelFailed: false) == .accessibility)
    }

    @Test("A failed model alone is reported as model-failed, with the log's spelling")
    func modelFailedAlone() {
        let reason = MenuBarIconPolicy.attentionReason(accessibilityMissing: false, modelFailed: true)
        #expect(reason == .modelFailed)
        #expect(reason?.rawValue == "model-failed")
    }

    @Test("A setup hint is not an input: with Accessibility granted and the model ready, a hidden icon stays hidden")
    func setupHintDoesNotForceTheIcon() {
        // `setupHint` and the why-no-ghost line live in the open menu only (update 2026-10-27).
        // The only attention inputs are the two below, so a hint cannot reach this policy at all.
        let reason = MenuBarIconPolicy.attentionReason(accessibilityMissing: false, modelFailed: false)
        #expect(reason == nil)
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: false, needsAttention: reason != nil) == false)
    }

    @Test("A blocking host notice forces a hidden icon, with the log's spelling, after Accessibility and the model")
    func blockingHostNotice() {
        let reason = MenuBarIconPolicy.attentionReason(
            accessibilityMissing: false, modelFailed: false, blockingHostNotice: true)
        #expect(reason == .hostNotice)
        #expect(reason?.rawValue == "host-notice")
        #expect(MenuBarIconPolicy.isInserted(userWantsIcon: false, needsAttention: reason != nil) == true)
        #expect(MenuBarIconPolicy.attentionReason(
            accessibilityMissing: false, modelFailed: true, blockingHostNotice: true) == .modelFailed)
    }
}
