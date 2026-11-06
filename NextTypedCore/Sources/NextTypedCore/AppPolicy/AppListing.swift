import Foundation

/// What the Settings Apps pane lists and how it words each row. Pure: the App resolves
/// bundle IDs to names and icons through `NSWorkspace` and hands the results in.
public enum AppListing {
    /// A bundle ID and display name resolved by the caller.
    public struct Source: Equatable, Sendable {
        public let bundleID: String
        public let name: String
        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public let bundleID: String
        public let name: String
        /// Whether the app is on the shipped default blocklist.
        public let blocklisted: Bool
        public var id: String { bundleID }
        public init(bundleID: String, name: String, blocklisted: Bool) {
            self.bundleID = bundleID
            self.name = name
            self.blocklisted = blocklisted
        }
    }

    /// Running apps, apps with an override, installed blocklisted apps and apps the user added this
    /// session, deduped by bundle ID (first source wins) and sorted by name.
    public static func entries(
        running: [Source], overridden: [Source], installedBlocklisted: [Source], added: [Source]
    ) -> [Entry] {
        var byID: [String: Entry] = [:]
        for source in running + overridden + installedBlocklisted + added where byID[source.bundleID] == nil {
            byID[source.bundleID] = Entry(
                bundleID: source.bundleID, name: source.name,
                blocklisted: AppEnablementPolicy.defaultBlocklist.contains(source.bundleID))
        }
        return byID.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }
    }

    /// The effective state shown under the app name. In `onlySwitchedOn` mode an app without a choice is off.
    public static func caption(override: Bool?, blocklisted: Bool, mode: DefaultMode) -> String {
        switch override {
        case .some(true): return "Always on"
        case .some(false): return "Always off"
        case .none:
            switch mode {
            case .everywhere: return blocklisted ? "Off, blocklisted" : "On"
            case .onlySwitchedOn: return "Off, not switched on"
            }
        }
    }

    /// The label of the "no override" menu item.
    public static func defaultLabel(blocklisted: Bool, mode: DefaultMode) -> String {
        switch mode {
        case .everywhere: blocklisted ? "Default (off)" : "Default (on)"
        case .onlySwitchedOn: "Default (off)"
        }
    }

    public static func filter(_ entries: [Entry], query: String) -> [Entry] {
        query.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    public static func noMatchText(query: String) -> String { "No apps match \(query)." }
}
