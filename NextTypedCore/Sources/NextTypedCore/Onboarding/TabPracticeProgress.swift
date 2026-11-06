/// State of the onboarding step where the user practices `Tab` (one word) and `⌥Tab` (the rest) on the
/// real suggestion loop.
///
/// Pure Core: the App feeds it three facts it observes (a ghost appeared, an accept key inserted a
/// continuation, the no-ghost timer fired) plus the user's skip, and renders `phase`.
public struct TabPracticeProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Waiting for the user to accept with each key.
        case practicing
        /// The timeout passed and no ghost ever appeared: point the user to Settings → Setup.
        case noGhost
        /// Both keys were used at least once.
        case done
        /// The user skipped the step.
        case skipped
    }

    public enum Event: Equatable, Sendable {
        case ghostShown
        /// An accept key inserted a continuation (a spell fix applied by `Tab` is not reported).
        case accepted(AcceptanceKey)
        case timeout
        case skip
    }

    public private(set) var wordAccepted = false
    public private(set) var allAccepted = false
    public private(set) var ghostSeen = false
    public private(set) var timedOut = false
    public private(set) var skipped = false

    public init() {}

    public var phase: Phase {
        if skipped { return .skipped }
        if wordAccepted && allAccepted { return .done }
        if timedOut && !ghostSeen && !wordAccepted && !allAccepted { return .noGhost }
        return .practicing
    }

    public mutating func apply(_ event: Event) {
        switch event {
        case .ghostShown:
            ghostSeen = true
        case .accepted(let key):
            ghostSeen = true
            switch key {
            case .tab: wordAccepted = true
            case .acceptAll: allAccepted = true
            case .escape: break   // a dismissal is not an accept
            }
        case .timeout:
            timedOut = true
        case .skip:
            skipped = true
        }
    }
}
