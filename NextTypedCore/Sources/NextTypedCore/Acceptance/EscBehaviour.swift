/// What `Esc` does beyond hiding the ghost. Settings →
/// Shortcuts picker, `defaults` key `escBehaviour`.
public enum EscBehaviour: String, CaseIterable, Sendable {
    /// Hide the ghost and stay quiet until the next keystroke (the mute). The behaviour before
    /// the picker, so the default leaves every effect list unchanged.
    case dismissOnly
    /// Also keep the focused field quiet for `fieldPauseSeconds`, typing included. A focus change or
    /// the timer ends it; the timer running out shows nothing.
    case dismissAndPauseField

    /// How long `dismissAndPauseField` keeps a field quiet. Provisional, like the other timing
    /// constants; it can be tuned.
    public static let fieldPauseSeconds = 30
}
