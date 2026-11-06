/// Local usage statistics: **words accepted** per day and per app, plus
/// the keystrokes and active typing time that make a measured **keystrokes-per-minute** figure.
///
/// Three properties are load-bearing, and all three are why this is a Core value type rather than a
/// handful of counters in the App:
///
/// - **It counts what happened, and nothing else.** There is no "≈ time saved" here and there must not
///   be one: that number can only be produced by multiplying accepted characters by an *assumed* typing
///   speed, which is a marketing figure wearing a measurement's clothes — the exact thing that
///   trust-first positioning is corroded by. Keystrokes-per-minute is its honest replacement: a rate the app
///   actually measures.
/// - **It stores counts and bundle IDs, never text**. Nothing in this file can hold
///   a character the user typed, which is what makes the claim in the Statistics pane checkable rather
///   than promised.
/// - **It is calendar-free.** A day is an *ordinal* — days since the Unix epoch in the user's own local
///   calendar — supplied by the App, which is where time zones, DST and locale belong (the same
///   time-free rule as the session reducer and `StyleProfile`'s capture ordinal).
public struct UsageStatistics: Codable, Equatable, Sendable {
    /// Rolling retention: per-day counters otherwise grow without bound,
    /// and a bounded window is itself a privacy property worth naming in the UI rather than an
    /// implementation detail. 90 days including today.
    public static let retentionDays = 90

    /// Days keyed by ``UsageDay/storageKey``. A dictionary rather than an array because the App records
    /// into "today" without knowing or caring what else is stored.
    public private(set) var days: [String: DayUsage]

    public init(days: [String: DayUsage] = [:]) {
        self.days = days
    }

    // MARK: Recording

    /// Fold one flushed batch into `day`, then drop anything that has fallen out of the retention window.
    ///
    /// Pruning here (rather than only at load) means the file cannot outgrow the window even in a process
    /// that runs for months, and it means the window is enforced by the same code path the tests cover.
    public mutating func record(_ batch: UsageBatch, on day: UsageDay) {
        guard !batch.isEmpty else { return }
        var usage = self[day]
        usage.acceptedWords += batch.acceptedWords
        usage.keystrokes += batch.keystrokes
        usage.activeSeconds += batch.activeSeconds
        if batch.acceptedWords > 0, let bundleID = batch.bundleID {
            usage.acceptedWordsByApp[bundleID, default: 0] += batch.acceptedWords
        }
        days[day.storageKey] = usage
        prune(asOf: day)
    }

    /// Drop every day older than the retention window ending at `today`.
    public mutating func prune(asOf today: UsageDay) {
        let oldest = today.advanced(by: -(Self.retentionDays - 1))
        days = days.filter { key, _ in
            guard let day = UsageDay(storageKey: key) else { return false }  // junk key → drop
            return day >= oldest && day <= today
        }
    }

    public subscript(day: UsageDay) -> DayUsage {
        days[day.storageKey] ?? DayUsage()
    }

    // MARK: Reading

    /// Words accepted on `day` (the menu-bar figure). Zero for a day with no record.
    public func acceptedWords(on day: UsageDay) -> Int {
        self[day].acceptedWords
    }

    /// True when nothing has been recorded. The Statistics pane shows an **empty state** on this rather
    /// than a screen of zeros, which would read as measured data that happens to be nil.
    public var isEmpty: Bool {
        days.values.allSatisfy(\.isEmpty)
    }

    /// The last `count` days ending at `today`, **oldest first and zero-filled**, so a bar chart shows the
    /// gaps as gaps instead of silently closing them up.
    public func series(endingAt today: UsageDay, count: Int) -> [(day: UsageDay, usage: DayUsage)] {
        guard count > 0 else { return [] }
        return (0..<count).reversed().map { offset in
            let day = today.advanced(by: -offset)
            return (day, self[day])
        }
    }

    /// Everything in the retained window, summed.
    public var totals: DayUsage {
        days.values.reduce(into: DayUsage()) { total, usage in
            total.acceptedWords += usage.acceptedWords
            total.keystrokes += usage.keystrokes
            total.activeSeconds += usage.activeSeconds
            for (bundleID, words) in usage.acceptedWordsByApp {
                total.acceptedWordsByApp[bundleID, default: 0] += words
            }
        }
    }

    /// Accepted words per app over the retained window, most first. Ties break on the bundle ID so the
    /// list has a stable order between reads.
    public var acceptedWordsByApp: [(bundleID: String, acceptedWords: Int)] {
        totals.acceptedWordsByApp
            .map { (bundleID: $0.key, acceptedWords: $0.value) }
            .sorted {
                $0.acceptedWords == $1.acceptedWords
                    ? $0.bundleID < $1.bundleID
                    : $0.acceptedWords > $1.acceptedWords
            }
    }
}

/// One day's counters. `acceptedWordsByApp` is keyed by bundle ID — an identifier, never content.
public struct DayUsage: Codable, Equatable, Sendable {
    /// Words inserted by an accept (`Tab`, and every word of a full accept). Type-along advances are
    /// **not** in here: the user typed those characters, and counting them would inflate the figure with
    /// the user's own work — the same dishonesty as "time saved".
    public var acceptedWords: Int
    /// Character-producing keystrokes seen by the tap on a surface NextTyped actually works on.
    public var keystrokes: Int
    /// Seconds of *active* typing behind those keystrokes (gaps longer than
    /// ``TypingRate/idleGapSeconds`` are not time spent writing).
    public var activeSeconds: Double
    public var acceptedWordsByApp: [String: Int]

    public init(acceptedWords: Int = 0,
                keystrokes: Int = 0,
                activeSeconds: Double = 0,
                acceptedWordsByApp: [String: Int] = [:]) {
        self.acceptedWords = acceptedWords
        self.keystrokes = keystrokes
        self.activeSeconds = activeSeconds
        self.acceptedWordsByApp = acceptedWordsByApp
    }

    public var isEmpty: Bool {
        acceptedWords == 0 && keystrokes == 0 && activeSeconds == 0
    }

    /// Measured typing speed, or `nil` while the sample is too thin to state one
    /// (``TypingRate/minimumActiveSecondsForARate``). A rate over four seconds of typing is noise, and
    /// printing it anyway would be inventing precision — the pane says "not enough typing yet" instead.
    public var keystrokesPerMinute: Int? {
        TypingRate.perMinute(keystrokes: keystrokes, activeSeconds: activeSeconds)
    }
}

/// One flush's worth of pending activity, accumulated by the App between eligibility proofs and folded
/// into the store in one write. Counts only — the batch never holds text either.
public struct UsageBatch: Equatable, Sendable {
    public var acceptedWords: Int
    public var keystrokes: Int
    public var activeSeconds: Double
    /// The surface these counts belong to, known once the predict path proved the surface eligible.
    public var bundleID: String?

    public init(acceptedWords: Int = 0,
                keystrokes: Int = 0,
                activeSeconds: Double = 0,
                bundleID: String? = nil) {
        self.acceptedWords = acceptedWords
        self.keystrokes = keystrokes
        self.activeSeconds = activeSeconds
        self.bundleID = bundleID
    }

    public var isEmpty: Bool {
        acceptedWords == 0 && keystrokes == 0 && activeSeconds == 0
    }

    /// Reset the counters, keeping nothing — used both after a flush and on the discard path (a surface
    /// that never proved eligible).
    public mutating func clear() {
        self = UsageBatch()
    }
}

/// The two arithmetic rules behind the keystrokes-per-minute figure, kept together because they are the
/// only place the honesty of that number is decided.
public enum TypingRate {
    /// A pause longer than this is not typing. Without the cut, "keystrokes per minute" would silently
    /// become "keystrokes per minute of having the app open", which is a different (and much smaller)
    /// number wearing the same label.
    public static let idleGapSeconds: Double = 5

    /// Below this much measured typing there is no rate to report.
    public static let minimumActiveSecondsForARate: Double = 60

    /// The active time a keystroke adds, given the gap since the previous one. `nil` (the first keystroke
    /// after a pause, or of the session) adds nothing: there is no measured interval before it.
    public static func activeSeconds(sincePreviousKeystroke gap: Double?) -> Double {
        guard let gap, gap > 0, gap <= idleGapSeconds else { return 0 }
        return gap
    }

    /// Keystrokes per minute, or `nil` when the sample is too thin to state one.
    public static func perMinute(keystrokes: Int, activeSeconds: Double) -> Int? {
        guard activeSeconds >= minimumActiveSecondsForARate, keystrokes > 0 else { return nil }
        return Int((Double(keystrokes) / (activeSeconds / 60)).rounded())
    }
}

/// A calendar day as an **ordinal** — days since 1970-01-01 in the user's own local calendar. Core never
/// asks what today is; the App supplies it, which keeps time zones, DST and locale on the side of the
/// boundary that has a `Calendar`.
public struct UsageDay: Hashable, Comparable, Codable, Sendable {
    public let daysSinceEpoch: Int

    public init(daysSinceEpoch: Int) {
        self.daysSinceEpoch = daysSinceEpoch
    }

    /// The dictionary key used in the stored JSON.
    public var storageKey: String { String(daysSinceEpoch) }

    public init?(storageKey: String) {
        guard let value = Int(storageKey) else { return nil }
        self.init(daysSinceEpoch: value)
    }

    public func advanced(by days: Int) -> UsageDay {
        UsageDay(daysSinceEpoch: daysSinceEpoch + days)
    }

    public static func < (lhs: UsageDay, rhs: UsageDay) -> Bool {
        lhs.daysSinceEpoch < rhs.daysSinceEpoch
    }
}

/// The label next to the menu-bar icon: today's accepted words, as the plain number below
/// 10,000 and a compact form from there ("12k"). Pure, so the rule has literal tests.
public enum MenuBarWordCount {
    public static func label(words: Int) -> String {
        let words = max(0, words)
        if words < 10_000 { return String(words) }
        if words < 1_000_000 { return "\(words / 1_000)k" }
        return "\(words / 1_000_000)M"
    }
}

/// Today's accepted words as the menu bar shows them, kept beside the usage store without a
/// second source of truth: `committed` mirrors what the store holds for today, `pending` is the open
/// batch. The figure counts `pending` only once the surface has proved eligible, which is the rule the
/// store applies, so the menu bar never shows a word the store would discard. A commit moves `pending`
/// into `committed`, so one accept is never in both.
public struct TodayAcceptedWords: Equatable, Sendable {
    public private(set) var committed: Int
    public private(set) var pending = 0
    public private(set) var surfaceProven = false

    public init(committed: Int = 0) {
        self.committed = max(0, committed)
    }

    /// The figure to draw.
    public var displayed: Int { committed + (surfaceProven ? pending : 0) }

    public mutating func noteAccepted(words: Int) {
        guard words > 0 else { return }
        pending += words
    }

    /// The predict path proved the surface eligible; the open batch is committed with it.
    public mutating func noteEligibleSurface() {
        surfaceProven = true
        commit()
    }

    /// The store took the open batch.
    public mutating func commit() {
        guard surfaceProven else { return }
        committed += pending
        pending = 0
    }

    /// A context switch: commit a proven batch, drop one that never proved eligible.
    public mutating func contextSwitch() {
        commit()
        pending = 0
        surfaceProven = false
    }

    /// "Delete statistics".
    public mutating func reset() {
        self = TodayAcceptedWords()
    }

    /// Midnight: the new day starts at 0. The open batch lands on the new day, as the store records it.
    public mutating func startNewDay() {
        committed = 0
    }

    /// The store's figure for today, read once at launch. Never lowers a figure already counted.
    public mutating func seed(storedToday: Int) {
        committed = max(committed, storedToday)
    }
}
