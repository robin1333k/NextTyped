import Testing
@testable import NextTypedCore

/// What the Statistics pane lists: the By app cap and the chart's label density.
@Suite struct StatisticsPresentationTests {
    private func apps(_ count: Int) -> [(bundleID: String, acceptedWords: Int)] {
        (0..<count).map { (bundleID: "app.\($0)", acceptedWords: 100 - $0) }
    }

    @Test func fifteenAppsShowTwelveRowsAndThreeMore() {
        let list = StatisticsPresentation.appList(apps(15), limit: 12)

        #expect(list.rows.count == 12)
        #expect(list.rows.last?.bundleID == "app.11")
        #expect(list.hiddenCount == 3)
    }

    @Test func twelveAppsShowNoMoreRow() {
        let list = StatisticsPresentation.appList(apps(12), limit: 12)

        #expect(list.rows.count == 12)
        #expect(list.hiddenCount == 0)
    }

    @Test func moreRowReadsSingularAndPlural() {
        #expect(StatisticsPresentation.moreAppsText(1) == "and 1 more app")
        #expect(StatisticsPresentation.moreAppsText(3) == "and 3 more apps")
    }

    @Test func everyDayIsLabelledWhenTheLabelsFit() {
        // 14 slots of 40 pt, a 14 pt label plus 4 pt gap.
        #expect(StatisticsPresentation.labelStride(slotWidth: 40, labelWidth: 14, gap: 4) == 1)
    }

    @Test func everyOtherDayIsLabelledWhenTheLabelsDoNotFit() {
        #expect(StatisticsPresentation.labelStride(slotWidth: 10, labelWidth: 14, gap: 4) == 2)
        #expect(StatisticsPresentation.labelStride(slotWidth: 5, labelWidth: 14, gap: 4) == 4)
    }
}
