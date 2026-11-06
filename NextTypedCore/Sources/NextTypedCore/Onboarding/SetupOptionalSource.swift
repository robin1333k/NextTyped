/// A context source that ships off and is offered in the Optional section of Settings → Setup.
/// The section lists every one of them whether it is on or not. None of them is ever a missing
/// requirement: `SetupChecklist` and `SetupAttention` take no input from here, so the Setup
/// badge and the summary row never count them.
public enum SetupOptionalSource: CaseIterable, Equatable, Sendable {
    case screenText
    case writingStyle

    public enum State: Equatable, Sendable {
        case off
        case on
        /// The switch is on, but macOS has not granted Screen Recording yet.
        case waitingForPermission
    }

    public func state(isOn: Bool, needsPermission: Bool) -> State {
        guard isOn else { return .off }
        if self == .screenText, needsPermission { return .waitingForPermission }
        return .on
    }
}
