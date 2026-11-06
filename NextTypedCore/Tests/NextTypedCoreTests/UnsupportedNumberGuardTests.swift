import Testing
@testable import NextTypedCore

@Suite struct UnsupportedNumberGuardTests {
    private func run(_ ghost: String, after prefix: String, support: [String] = [])
        -> UnsupportedNumberGuard.Verdict {
        UnsupportedNumberGuard.apply(to: ghost, textBeforeCaret: prefix, supportingText: support)
    }

    @Test func trimsDigitRunNotInPrefix() {
        let v = run(" in 2024 wieder", after: "Wir treffen uns")
        #expect(v.text == " in")
        #expect(v.action == .trimmed)
    }

    @Test func passesDigitRunThatIsInPrefix() {
        let v = run(" ist 2024 vorbei", after: "Das Jahr 2024")
        #expect(v.text == " ist 2024 vorbei")
        #expect(v.action == nil)
    }

    @Test func doesNotTreatSubstringOfLongerNumberAsSupport() {
        let v = run(" and 20 more", after: "Order 2024")
        #expect(v.text == " and")
        #expect(v.action == .trimmed)
    }

    @Test func passesDayAnchoredByMonthInPrefix() {
        let v = run(" am 3. März", after: "Die Sitzung ist im März,")
        #expect(v.text == " am 3. März")
        #expect(v.action == nil)
    }

    @Test func trimsDayWhenMonthIsNotSupported() {
        let v = run(" am 3. März", after: "Die Sitzung ist")
        #expect(v.text == " am")
        #expect(v.action == .trimmed)
    }

    @Test func trimsEnglishMonthNotInPrefix() {
        let v = run(" on March the", after: "We will meet")
        #expect(v.text == " on")
    }

    @Test func passesEnglishMonthInPrefix() {
        let v = run(" on March the", after: "March is when we meet")
        #expect(v.text == " on March the")
    }

    @Test func trimsGermanWeekdayNotInPrefix() {
        let v = run(" am Montag um", after: "Wir sehen uns")
        #expect(v.text == " am")
        #expect(v.action == .trimmed)
    }

    @Test func trimsEnglishWeekdayNotInPrefix() {
        let v = run(" next Friday works", after: "See you")
        #expect(v.text == " next")
    }

    @Test func passesWeekdayInPrefix() {
        let v = run(" am Montag um", after: "Am Montag ist frei, also")
        #expect(v.text == " am Montag um")
    }

    @Test func lowercaseMayAndMarchAreOrdinaryWords() {
        #expect(run(" may go", after: "We").text == " may go")
        #expect(run(" march on", after: "They").text == " march on")
    }

    @Test func suppressesGhostThatIsOnlyANumber() {
        let v = run(" 2024", after: "Das Jahr")
        #expect(v.text == "")
        #expect(v.action == .suppressed)
    }

    @Test func suppressesGhostWhoseFirstTokenIsADateName() {
        let v = run(" Montag.", after: "Wir sehen uns am")
        #expect(v.text == "")
        #expect(v.action == .suppressed)
    }

    @Test func contextSegmentsSupportANumber() {
        let v = run(" costs 49 euros", after: "The ticket", support: ["Price list: 49 per seat"])
        #expect(v.text == " costs 49 euros")
        #expect(v.action == nil)
    }

    @Test func halfTypedNumberIsJudgedWhole() {
        // Prefix ends in "20", ghost completes it to "2024", which is nowhere in the text.
        let v = run("24 war", after: "Im Jahr 20")
        #expect(v.text == "")
        #expect(v.action == .suppressed)
    }

    @Test func halfTypedNumberPassesWhenWholeNumberIsSupported() {
        let v = run("24 war", after: "2024 war gut. Im Jahr 20")
        #expect(v.text == "24 war")
    }

    @Test func plainTextIsUntouched() {
        let v = run(" gerne vorbeikommen", after: "Du kannst")
        #expect(v.text == " gerne vorbeikommen")
        #expect(v.action == nil)
    }
}
