import Foundation

/// One line of the Status section at the top of Settings -> General: a state that today lives only in
/// the menu bar or nowhere.
public struct StatusLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The user can act on it (pause, quiet).
        case attention
        /// Informational: something is off and needs no action.
        case off
    }

    public enum Action: Equatable, Sendable {
        /// Ends the global pause.
        case resumeAll
        /// Ends one app's temporary quiet.
        case resumeApp(bundleID: String)
    }

    public let kind: Kind
    public let text: String
    public let action: Action?

    public init(kind: Kind, text: String, action: Action?) {
        self.kind = kind
        self.text = text
        self.action = action
    }
}

/// Pure summary of pause, temporary per-app quiet and the model's memory state. No AppKit.
public enum SettingsStatusSummary {
    public struct Quiet: Equatable, Sendable {
        public let bundleID: String
        public let appName: String
        public let until: Date

        public init(bundleID: String, appName: String, until: Date) {
            self.bundleID = bundleID
            self.appName = appName
            self.until = until
        }
    }

    /// Lines in a fixed order: global pause, quiets by app name, then the model. `loaded` and `flushed`
    /// produce no line (a flush is invisible and reloads inside the same predict). A quiet whose time
    /// has run out is dropped.
    public static func lines(
        paused: Bool,
        quiets: [Quiet],
        residency: ModelResidencyPolicy.ModelState,
        now: Date
    ) -> [StatusLine] {
        var result: [StatusLine] = []
        if paused {
            result.append(StatusLine(kind: .attention, text: "Completions are paused", action: .resumeAll))
        }
        let active = quiets.filter { $0.until > now }
            .sorted { ($0.appName, $0.bundleID) < ($1.appName, $1.bundleID) }
        for quiet in active {
            result.append(StatusLine(
                kind: .attention,
                text: "Quiet in \(quiet.appName) for \(remaining(quiet, now: now))",
                action: .resumeApp(bundleID: quiet.bundleID)))
        }
        if residency == .unloaded {
            result.append(StatusLine(
                kind: .off, text: "Model unloaded to save memory. It reloads when you type.", action: nil))
        }
        return result
    }

    /// Caption for a quieted app's row in Settings -> Apps.
    public static func rowCaption(for quiet: Quiet, now: Date) -> String {
        "Quiet for \(remaining(quiet, now: now))"
    }

    private static func remaining(_ quiet: Quiet, now: Date) -> String {
        let minutes = max(1, Int((quiet.until.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes) more minute\(minutes == 1 ? "" : "s")"
    }
}
