import Foundation

/// Pure display rules for the Statistics pane: how many apps are listed and how dense the chart's
/// day labels are. The view only draws what these return.
public enum StatisticsPresentation {
    /// The first `limit` rows of a ranked list and how many were left out.
    public static func appList(
        _ ranked: [(bundleID: String, acceptedWords: Int)], limit: Int
    ) -> (rows: [(bundleID: String, acceptedWords: Int)], hiddenCount: Int) {
        (Array(ranked.prefix(limit)), max(0, ranked.count - limit))
    }

    /// The text of the row below a capped list.
    public static func moreAppsText(_ hidden: Int) -> String {
        hidden == 1 ? "and 1 more app" : "and \(hidden) more apps"
    }

    /// Label every `n`th day, the smallest `n` for which a label and its gap fit in `n` bar slots.
    public static func labelStride(slotWidth: Double, labelWidth: Double, gap: Double) -> Int {
        guard slotWidth > 0 else { return 1 }
        return max(1, Int(((labelWidth + gap) / slotWidth).rounded(.up)))
    }
}
