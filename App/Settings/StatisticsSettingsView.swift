import AppKit
import NextTypedCore
import SwiftUI

/// Statistics pane — what NextTyped actually counted: **words
/// accepted** per day and per app, and a **measured** typing rate.
///
/// What is deliberately *not* here is a "≈ time saved" figure. It cannot be measured, only computed by
/// multiplying accepted characters by an assumed typing speed — a marketing number wearing a
/// measurement's clothes, and this product's positioning is corroded by exactly that. The
/// keystrokes-per-minute row is its honest replacement, and it stays blank until enough typing has been
/// seen to state a rate.
///
/// This view is also the transparency surface for the store behind it: everything kept is
/// visible here, and the reset below deletes it.
struct StatisticsSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    @State private var statistics: UsageStatistics?
    @State private var confirmingReset = false

    /// How much of the retained window the chart shows. The store keeps 90 days; two weeks is what reads
    /// as a chart rather than a hairline comb.
    private static let chartDays = 14

    /// Apps listed under By app; the rest collapse into one "and N more apps" row.
    private static let appLimit = 12

    private let today = UsageDay.today()

    var body: some View {
        Form {
            if let statistics, !statistics.isEmpty {
                content(statistics)
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing counted yet")
                        Text("Words you accept with Tab are counted here, per day and per app, along "
                             + "with how fast you type.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    deleteRow(isEnabled: false)
                } footer: {
                    footer
                }
                menuBarSection
            }
        }
        .formStyle(.grouped)
        .task { statistics = await coordinator.usageStatistics() }
    }

    private var footer: some View {
        Text("Stored on your Mac only: app identifiers and counts, never any text. The last "
             + "\(UsageStatistics.retentionDays) days are kept; older days are deleted "
             + "automatically. Apps where completions are turned off are never counted.")
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deleteRow(isEnabled: Bool) -> some View {
        SettingsDestructiveRow(
            title: "Delete statistics",
            isEnabled: isEnabled,
            confirmTitle: "Delete all statistics?",
            confirmMessage: "The counts are removed from this Mac. Counting starts again from zero."
        ) {
            Task {
                await coordinator.resetUsageStatistics()
                statistics = await coordinator.usageStatistics()
            }
        }
    }

    @ViewBuilder
    private func content(_ statistics: UsageStatistics) -> some View {
        let totals = statistics.totals
        let appList = StatisticsPresentation.appList(statistics.acceptedWordsByApp, limit: Self.appLimit)

        Section("Totals") {
            SettingsValueRow(title: "Words accepted, last \(UsageStatistics.retentionDays) days",
                             value: "\(totals.acceptedWords)")
            SettingsValueRow(title: "Today", value: "\(statistics[today].acceptedWords)")
            if let kpm = totals.keystrokesPerMinute {
                SettingsValueRow(title: "Typing speed", value: "\(kpm) keystrokes per minute",
                                 monospacesDigits: true)
            } else {
                SettingsValueRow(title: "Typing speed", value: "not enough typing yet")
            }
        }

        Section("Last \(Self.chartDays) days") {
            DailyWordsChart(series: statistics.series(endingAt: today, count: Self.chartDays))
                .frame(height: 120)
                .padding(.vertical, 4)
        }

        Section {
            ForEach(appList.rows, id: \.bundleID) { row in
                SettingsValueRow(title: Self.appName(row.bundleID), value: "\(row.acceptedWords)")
            }
            if appList.hiddenCount > 0 {
                Text(StatisticsPresentation.moreAppsText(appList.hiddenCount))
                    .foregroundStyle(.secondary)
            }
            deleteRow(isEnabled: true)
        } header: {
            Text("By app")
        }

        menuBarSection
        Section { } footer: { footer }
    }

    /// today's accepted words next to the menu-bar icon. Absent key means on.
    private var menuBarSection: some View {
        Section("Menu bar") {
            SettingsToggleRow(
                title: "Show today's words in the menu bar",
                subtitle: "The number of words you accepted today, next to the icon.",
                isOn: Binding(
                    get: { coordinator.showWordCountInMenuBar },
                    set: { coordinator.setShowWordCountInMenuBar($0) }))
        }
    }

    /// A bundle ID is what is *stored*; a readable name is what is *shown*. Resolved live from the
    /// installed app, so nothing extra has to be recorded to make the list legible.
    private static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

/// A plain bar-per-day chart. Hand-rolled rather than pulled from the Charts framework: it is a dozen
/// rectangles, and the empty days must read as empty (a zero-height bar with its label still in place)
/// rather than being closed up the way an auto-scaled chart likes to.
private struct DailyWordsChart: View {
    let series: [(day: UsageDay, usage: DayUsage)]

    private static let spacing: CGFloat = 4
    /// Width of a two-digit day number in `.caption` (10 pt) plus a little room.
    private static let labelWidth: CGFloat = 16
    private static let labelGap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let count = max(series.count, 1)
            let slot = (proxy.size.width - Self.spacing * CGFloat(count - 1)) / CGFloat(count)
            let stride = StatisticsPresentation.labelStride(
                slotWidth: Double(slot), labelWidth: Double(Self.labelWidth), gap: Double(Self.labelGap))
            let peak = max(series.map(\.usage.acceptedWords).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(Array(series.enumerated()), id: \.element.day) { index, entry in
                    let words = entry.usage.acceptedWords
                    VStack(spacing: 4) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(words > 0 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                            .frame(height: barHeight(words, peak: peak))
                        // The last day is always labelled; the stride counts back from it.
                        Text((series.count - 1 - index) % stride == 0 ? Self.label(entry.day) : " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(width: slot)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(words) words")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.accessibilityDate(entry.day)): \(words) words")
                }
            }
        }
    }

    /// Zero keeps a visible sliver so the day is present as a day; everything else scales against the
    /// tallest bar in the window.
    private func barHeight(_ words: Int, peak: Int) -> CGFloat {
        words == 0 ? 2 : max(3, CGFloat(words) / CGFloat(peak) * 84)
    }

    private static func label(_ day: UsageDay) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d")
        return formatter.string(from: day.startOfDay())
    }

    private static func accessibilityDate(_ day: UsageDay) -> String {
        day.startOfDay().formatted(date: .abbreviated, time: .omitted)
    }
}
