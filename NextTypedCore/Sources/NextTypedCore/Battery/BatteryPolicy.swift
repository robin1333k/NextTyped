/// Where the Mac draws power from. Read by the App from IOKit, never by Core.
public enum PowerSource: String, Equatable, Sendable {
    case ac
    case battery
}

/// The user's battery preferences. Both default off, so absent keys change nothing.
public struct BatteryPreferences: Equatable, Sendable {
    public var suggestOnlyOnDemand: Bool
    public var shorterCompletions: Bool

    public init(suggestOnlyOnDemand: Bool = false, shorterCompletions: Bool = false) {
        self.suggestOnlyOnDemand = suggestOnlyOnDemand
        self.shorterCompletions = shorterCompletions
    }
}

/// What the suggestion loop does under the current power source and preferences.
public struct BatteryPosture: Equatable, Sendable {
    /// True: a ghost appears only through the force-activate shortcut (and the accept refill).
    public var onDemandOnly: Bool
    /// The most words the decode may produce: `ContinuationBuffer.maxWords` normally,
    /// `shorterDecodeWordCap` on battery with "Shorter suggestions on battery" on. Never above
    /// `ContinuationBuffer.maxWords`. Distinct from the display window, which only limits what is painted.
    public var decodeWordCap: Int

    public init(onDemandOnly: Bool, decodeWordCap: Int) {
        self.onDemandOnly = onDemandOnly
        self.decodeWordCap = decodeWordCap
    }

    /// The decode cap on battery with shorter completions on (CT-61).
    public static let shorterDecodeWordCap = 5

    /// The posture on AC with no preference set: behaviour identical to before the feature.
    public static let normal = BatteryPosture(onDemandOnly: false,
                                              decodeWordCap: ContinuationBuffer.maxWords)
}

public enum BatteryPolicy {
    /// The posture and the `reason` token the App prints in its `[power]` line
    /// (`ac`, `pref-off`, `no-shortcut`, `active`).
    public static func posture(
        source: PowerSource,
        preferences: BatteryPreferences,
        forceShortcutAssigned: Bool
    ) -> (posture: BatteryPosture, reason: String) {
        let normalCap = ContinuationBuffer.maxWords
        guard source == .battery else {
            let cap = normalCap
            return (BatteryPosture(onDemandOnly: false, decodeWordCap: cap), "ac")
        }
        let cap = preferences.shorterCompletions
            ? min(BatteryPosture.shorterDecodeWordCap, normalCap) : normalCap
        guard preferences.suggestOnlyOnDemand else {
            return (BatteryPosture(onDemandOnly: false, decodeWordCap: cap), "pref-off")
        }
        guard forceShortcutAssigned else {
            return (BatteryPosture(onDemandOnly: false, decodeWordCap: cap), "no-shortcut")
        }
        return (BatteryPosture(onDemandOnly: true, decodeWordCap: cap), "active")
    }
}
