import Foundation

/// The log tags the diagnostics report may count. The set is closed:
/// a line whose tag is not here counts as ``DiagnosticsTagTally/Event/other``.
public enum DiagnosticsTag: String, CaseIterable, Sendable {
    case gate, residency, install, menubar, deeplink, onboarding, update, clip

    /// The first tokens this tag may carry, taken from the subsystem table.
    /// This is the only place the list lives. A token outside it counts
    /// as `other`, so a typed word or a bundle ID that lands in the first-token slot never reaches
    /// the report.
    public var vocabulary: Set<String> {
        switch self {
        case .gate:
            return ["rtl-text", "app-off", "emoji-no-match", "spell-language-open", "spell-ignore-armed",
                    "spell-ignored", "spelling-fix", "spelling-variant", "copy-guard", "word-completion",
                    "word-length", "unsupported-number", "running-thought", "no-context", "boundary-lead",
                    "field-size", "selection", "force-activate", "temporary-quiet", "prewarm-skip",
                    "esc-field-pause", "first-paint", "site-off", "take-back", "model-disk-too-small",
                    "language-off", "language-open"]
        case .residency:
            return ["unload-rule", "predictionActivity", "focusChanged", "contextSwitch",
                    "frontmostAppChanged", "memoryPressure", "displaySleep", "screenLocked",
                    "systemWillSleep", "setUnloadRule", "manualUnload"]
        case .install:
            return ["offer", "skip", "origin", "step", "dispose", "declined", "moved", "failed"]
        case .menubar:
            return ["icon", "words"]
        case .deeplink:
            return ["opened", "rejected", "queued"]
        case .onboarding:
            return ["tab-practice", "tab-demo", "page"]
        case .update:
            return ["check", "found", "none", "failed", "installed"]
        case .clip:
            return ["skip", "inject"]
        }
    }
}

/// A bounded in-memory tally of the last ``capacity`` log events, for the diagnostics report.
///
/// ``record(line:)`` parses `[tag]: first-token`. It keeps an event only when the tag is a
/// ``DiagnosticsTag`` and the first token is in that tag's vocabulary. Every other line counts under
/// ``Event/other`` with no text. Values after the first token (`app=`, `reason=`) are never kept, and
/// a parenthesised suffix on the token (`focusChanged(editable: true)`) is cut.
public struct DiagnosticsTagTally: Sendable, Equatable {
    public static let defaultCapacity = 500

    public enum Event: Hashable, Sendable {
        case known(DiagnosticsTag, String)
        case other
    }

    public struct Entry: Equatable, Sendable {
        public let event: Event
        public let count: Int
    }

    public let capacity: Int
    private var window: [Event] = []
    private var tally: [Event: Int] = [:]

    public init(capacity: Int = DiagnosticsTagTally.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(line: String) {
        let event = Self.parse(line)
        window.append(event)
        tally[event, default: 0] += 1
        if window.count > capacity {
            let dropped = window.removeFirst()
            if let n = tally[dropped], n > 1 { tally[dropped] = n - 1 } else { tally[dropped] = nil }
        }
    }

    /// Number of events currently held (at most ``capacity``).
    public var eventCount: Int { window.count }

    /// Counts in a fixed order: tags in declaration order, tokens alphabetical, `other` last.
    public var entries: [Entry] {
        let order = DiagnosticsTag.allCases
        return tally.map { Entry(event: $0.key, count: $0.value) }.sorted { a, b in
            switch (a.event, b.event) {
            case (.other, .other): return false
            case (.other, _): return false
            case (_, .other): return true
            case let (.known(ta, ka), .known(tb, kb)):
                if ta != tb { return order.firstIndex(of: ta)! < order.firstIndex(of: tb)! }
                return ka < kb
            }
        }
    }

    static func parse(_ line: String) -> Event {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return .other }
        let tagText = line[line.index(after: line.startIndex)..<close]
        guard let tag = DiagnosticsTag(rawValue: String(tagText)) else { return .other }
        var rest = line[line.index(after: close)...]
        guard rest.hasPrefix(":") else { return .other }
        rest = rest.dropFirst().drop(while: { $0 == " " })
        let word = rest.prefix(while: { !$0.isWhitespace })
        let token = String(word.prefix(while: { $0 != "(" && $0 != "=" }))
        guard tag.vocabulary.contains(token) else { return .other }
        return .known(tag, token)
    }
}
