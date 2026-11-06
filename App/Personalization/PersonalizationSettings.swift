import Foundation

/// Live settings for personalization, read fresh from the store on every use (the `ScreenOCRSettings`
/// precedent) so a Privacy-pane change takes effect on the next keystroke with no extra wiring.
struct PersonalizationSettings: Sendable {
    /// The Privacy-pane toggle. **Default off** until the offline probe returns GO
    /// (a *quality* gate on top of the *privacy* clearance).
    var enabled: Bool
    /// The **learning-source denylist**: apps whose text is never learned from, even though
    /// completions still work there.
    var learningDisabledBundleIDs: Set<String>

    static let disabled = PersonalizationSettings(enabled: false, learningDisabledBundleIDs: [])
}
