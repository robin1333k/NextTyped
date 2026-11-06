import Testing
@testable import NextTypedCore

@Suite struct SetupChecklistTests {
    @Test func readyWhenAccessibilityAndModelAreDone() {
        let list = SetupChecklist(accessibilityGranted: true, modelReady: true, accessibilityPromptShown: true)
        #expect(list.stepsLeft == 0)
        #expect(list.isReady)
        #expect(list.summaryTitle == "NextTyped is ready")
        #expect(list.summaryBadge == "Ready")
    }

    @Test func countsEachOpenRequirement() {
        let both = SetupChecklist(accessibilityGranted: false, modelReady: false, accessibilityPromptShown: false)
        #expect(both.stepsLeft == 2)
        #expect(both.summaryBadge == "2 steps left")
        #expect(both.summaryTitle == "Finish setup")
        let one = SetupChecklist(accessibilityGranted: true, modelReady: false, accessibilityPromptShown: true)
        #expect(one.stepsLeft == 1)
        #expect(one.summaryBadge == "1 step left")
    }

    @Test func accessibilityOffersRequestUntilThePromptWasShown() {
        let fresh = SetupChecklist(accessibilityGranted: false, modelReady: true, accessibilityPromptShown: false)
        #expect(fresh.accessibilityAction == .requestAccess)
        let afterPrompt = SetupChecklist(accessibilityGranted: false, modelReady: true, accessibilityPromptShown: true)
        #expect(afterPrompt.accessibilityAction == .openSystemSettings)
        let granted = SetupChecklist(accessibilityGranted: true, modelReady: true, accessibilityPromptShown: false)
        #expect(granted.accessibilityAction == nil)
    }
}
