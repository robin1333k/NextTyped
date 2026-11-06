/// The `tabGraceMs` knob: how long a fresh ghost must have been on
/// screen before `Tab` and `⌥Tab` accept it. Read once at launch from `com.robinklotz.NextTyped`.
/// The clock itself is App-side; Core only learns whether the grace is on (`SuggestionSession(tabGrace:)`)
/// and when a ghost has settled (`.ghostSettled`).
public enum TabGrace {
    /// The shipping value. Long enough to cover a `Tab` the user had already decided on when the ghost
    /// appeared, short enough that a deliberate accept never notices it.
    public static let defaultMilliseconds = 150
    public static let range = 0...1000

    /// `stored` is the raw `defaults` value, `nil` when the key is absent.
    public static func milliseconds(stored: Int?) -> Int {
        guard let stored else { return defaultMilliseconds }
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    /// Zero turns the grace window off: every ghost is settled the moment it is presented.
    public static func isEnabled(milliseconds: Int) -> Bool { milliseconds > 0 }
}

/// Which presentation generation owns the App's single grace clock. The App walks the
/// effects behind each `.present` on its own Task, and a correction paint awaits twice where a
/// continuation paint awaits once, so `.scheduleSettle` can arrive out of order. Without this an older
/// generation's clock would cancel the newer one: the reducer then ignores the older `.ghostSettled`,
/// the newer ghost never settles, and its `Tab` reaches the host. Reset it together with the session,
/// whose generations start again at 1.
public struct SettleClockSlot: Sendable {
    private var newest = 0

    public init() {}

    /// True when `generation` is newer than every generation claimed so far; the caller then starts
    /// its clock. False means a newer ghost already owns the clock and this one must leave it alone.
    public mutating func claim(generation: Int) -> Bool {
        guard generation > newest else { return false }
        newest = generation
        return true
    }
}
