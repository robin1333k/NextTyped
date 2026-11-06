/// The count badge on the Setup row of the Settings sidebar.
///
/// It counts the requirements the Setup pane lists as unmet: Accessibility missing and a failed model
/// load. The inputs are the same two facts `MenuBarIconPolicy` reads; a model that is still loading or
/// downloading is not unmet, because it needs no action from the user.
public enum SetupAttention {
    /// The number the badge shows, or `nil` when every requirement is met and the row shows no badge.
    public static func badgeCount(accessibilityMissing: Bool, modelFailed: Bool) -> Int? {
        let unmet = (accessibilityMissing ? 1 : 0) + (modelFailed ? 1 : 0)
        return unmet == 0 ? nil : unmet
    }
}
