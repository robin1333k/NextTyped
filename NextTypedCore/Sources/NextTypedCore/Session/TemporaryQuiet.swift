/// How long a temporary per-app quiet lasts.
///
/// Three steps, and **no "indefinitely"**: that is exactly what the Apps pane's per-app switch already
/// is, and offering both would be two routes to one state — one of which the transient layer is
/// forbidden to reach anyway, since it may only suppress and must never write the stored preference.
/// The menu that offers these points at the Apps pane for "off for good".
///
/// The raw value is the duration in **minutes**, which is also how the menu spells it; the seconds
/// conversion is here rather than at the timer so the two cannot drift. Labels stay App-side — they are
/// UI text, and Core carries no UI strings (the `CompletionLength` precedent).
public enum TemporaryQuietDuration: Int, CaseIterable, Equatable, Sendable {
    case fiveMinutes = 5
    case fifteenMinutes = 15
    case oneHour = 60

    /// The duration in minutes — the unit the user chose it in.
    public var minutes: Int { rawValue }

    /// The same duration in seconds, for the App's expiry timer.
    public var seconds: Double { Double(rawValue) * 60 }

    /// The step a *key press* applies. A shortcut cannot carry a duration, so the hotkey takes the
    /// middle step and the menu is where a duration is actually chosen — named here rather than
    /// spelled at the key handler, so the two places that mention "the hotkey's duration" are one.
    public static let hotkeyDefault: TemporaryQuietDuration = .fifteenMinutes
}
