import NextTypedCore
import SwiftUI

/// "Where it works" — the Support list shown in Settings → Setup.
///
/// The "works" and "bubble or line-sized" groups are static text: every entry restates a coverage fact that
/// was verified at runtime. The "limited or off by default" group is built from
/// `AppCoverageLimits` (Core), the same table the Apps pane reads its reason lines from, so the two never
/// disagree. No host is listed on a guess.
struct SupportListSection: View {
    private struct Entry: Identifiable {
        let host: String
        let detail: String
        var id: String { host }
    }

    private static let works: [Entry] = [
        Entry(host: "TextEdit", detail: "Ghost text inline at the cursor."),
        Entry(host: "Safari multi-line form fields", detail: "Ghost text inline at the cursor."),
    ]

    private static let limited: [Entry] = [
        Entry(host: "Apple Notes",
              detail: "Works. The app does not report its font, so the ghost size is derived from the line height."),
        Entry(host: "claude.ai in Safari",
              detail: "Works. The page does not report its font, so the ghost size is derived from the line height."),
        Entry(host: "Claude Desktop",
              detail: "Works. When the completion wraps, it can appear in a bubble at the start of the line."),
    ]

    /// Limits from the shared table first, then the one entry that names no app.
    private static let unsupported: [Entry] = AppCoverageLimits.all.map {
        Entry(host: $0.hostName, detail: $0.limit.statement)
    } + [
        Entry(host: "Search bars, address bars and one-line form fields",
              detail: "Spelling fixes only. Word completions are off in single-line fields."),
    ]

    var body: some View {
        Section {
            group(.init(kind: .ok, label: "Works"), entries: Self.works)
            group(.init(kind: .attention, label: "Bubble only or sized from the line"), entries: Self.limited)
            group(.init(kind: .off, label: "Limited or off by default"), entries: Self.unsupported)
        } header: {
            Text("Where it works")
        } footer: {
            Text("Password fields are never read, by design. Apps not listed here are not verified yet.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func group(_ badge: StatusBadge, entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            badge
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.host)
                    Text(entry.detail).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
