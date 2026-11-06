/// Whether the menu bar offers "Stop learning and delete profile" (CT-89).
///
/// The item is the one-step version of Settings → Privacy: turn learning off, then delete the learned
/// profile. It is shown while there is something to stop or something to delete, and hidden otherwise,
/// so a user who never used Personalization never sees it.
public enum StopLearningMenuPolicy {
    /// - Parameters:
    ///   - personalizationEnabled: the Personalization setting.
    ///   - profileFileExists: the encrypted profile file is on disk. This is a file-existence check, not a
    ///     decrypt, so an unreadable profile counts too: deleting it is the repair.
    public static func isVisible(personalizationEnabled: Bool, profileFileExists: Bool) -> Bool {
        personalizationEnabled || profileFileExists
    }
}
