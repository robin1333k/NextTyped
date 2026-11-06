/// Where NextTyped cannot fully work, and why. One table for two readers: the Setup pane's
/// "Where it works" list and the reason line under an app in Settings -> Apps, so the two never
/// disagree. An app without evidence has no entry and shows no reason (a host is never listed on a
/// guess).
public struct CoverageLimit: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// The app shows no text through Accessibility (Mail's compose body).
        case noText
        /// Accessibility exposes too little of the text to build a context (text-less Electron apps).
        case littleText
        /// The app owns Tab (shell completion), so completions start off there. A per-app switch can force them on.
        case tabIsShellCompletion
    }

    public let mode: Mode
    public let reason: String

    public init(mode: Mode, reason: String) {
        self.mode = mode
        self.reason = reason
    }

    /// The mode and the reason as one line of user copy.
    public var statement: String {
        "\(modeSummary) \(reason)"
    }

    private var modeSummary: String {
        switch mode {
        case .noText: "No text through Accessibility."
        case .littleText: "Little text through Accessibility."
        case .tabIsShellCompletion: "Off by default."
        }
    }
}

public enum AppCoverageLimits {
    public struct Entry: Equatable, Sendable {
        public let hostName: String
        public let bundleIDs: [String]
        public let limit: CoverageLimit
    }

    private static let electronReason = "This Electron app exposes little usable text through Accessibility."

    public static let all: [Entry] = [
        Entry(hostName: "Mail, compose body", bundleIDs: ["com.apple.mail"],
              limit: CoverageLimit(
                mode: .noText,
                reason: "The compose body does not share its text with Accessibility.")),
        Entry(hostName: "VS Code, Slack, Notion and Discord",
              bundleIDs: ["com.microsoft.VSCode", "com.tinyspeck.slackmacgap", "notion.id", "com.hnc.Discord"],
              limit: CoverageLimit(mode: .littleText, reason: electronReason)),
        Entry(hostName: "Terminals",
              bundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                          "io.alacritty", "net.kovidgoyal.kitty"],
              limit: CoverageLimit(
                mode: .tabIsShellCompletion,
                reason: "The shell uses Tab for its own completion. You can switch it on per app.")),
    ]

    public static func limit(forBundleID id: String) -> CoverageLimit? {
        all.first { $0.bundleIDs.contains(id) }?.limit
    }
}
