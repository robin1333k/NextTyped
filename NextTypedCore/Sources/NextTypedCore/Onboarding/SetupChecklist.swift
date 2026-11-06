/// What the Settings Setup pane summarises: the two required steps (Accessibility, the model) and which
/// action the Accessibility row offers. Pure, so the wording and the counting are tested
/// (`SetupChecklistTests`); the pane only renders it.
public struct SetupChecklist: Equatable, Sendable {
    public enum AccessibilityAction: Equatable, Sendable {
        /// The system prompt has not been shown yet.
        case requestAccess
        /// The prompt was shown and access is still missing; only System Settings can grant it now.
        case openSystemSettings
    }

    public let accessibilityGranted: Bool
    public let modelReady: Bool
    public let accessibilityPromptShown: Bool

    public init(accessibilityGranted: Bool, modelReady: Bool, accessibilityPromptShown: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.modelReady = modelReady
        self.accessibilityPromptShown = accessibilityPromptShown
    }

    public var stepsLeft: Int { (accessibilityGranted ? 0 : 1) + (modelReady ? 0 : 1) }
    public var isReady: Bool { stepsLeft == 0 }
    public var summaryTitle: String { isReady ? "NextTyped is ready" : "Finish setup" }
    public var summaryBadge: String {
        isReady ? "Ready" : (stepsLeft == 1 ? "1 step left" : "\(stepsLeft) steps left")
    }

    public var accessibilityAction: AccessibilityAction? {
        if accessibilityGranted { return nil }
        return accessibilityPromptShown ? .openSystemSettings : .requestAccess
    }
}
