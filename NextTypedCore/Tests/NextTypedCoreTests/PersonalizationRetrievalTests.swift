import Testing
@testable import NextTypedCore

/// Retrieval + freeze (§11): which exemplars get injected for a given ambient context, how
/// the segment is packed into its char budget, and the two fallbacks (empty query → recency-top, empty
/// profile → `nil`).
@Suite struct PersonalizationRetrievalTests {

    /// A profile with three topically distinct exemplars, oldest first.
    private func profile() -> StyleProfile {
        var p = StyleProfile()
        p.ingest(ownText: "Die Rechnung für Q3 ist raus und freigegeben.")
        p.ingest(ownText: "Der Deployment Pipeline Fehler ist inzwischen behoben.")
        p.ingest(ownText: "Wir treffen uns am Donnerstag im Büro zum Review.")
        return p
    }

    // MARK: Selection

    @Test func picksTheExemplarSharingTermsWithTheQuery() {
        let selection = PersonalizationRetrieval.select(
            profile: profile(), query: "Wann ist die Rechnung für Q3 fällig?")
        #expect(selection?.text.contains("Rechnung für Q3") == true)
        #expect(selection?.usedRecencyOnly == false)
    }

    @Test func ranksTheMatchingExemplarFirstWhenSeveralFit() {
        let selection = PersonalizationRetrieval.select(
            profile: profile(), query: "Das Deployment ist noch nicht durch, Pipeline hängt.")
        #expect(selection?.text.hasPrefix("Der Deployment Pipeline Fehler") == true)
        #expect(selection?.exemplarCount == 3)   // the rest still fill the budget, just ranked lower
    }

    @Test func emptyQueryFallsBackToTheMostRecentVoice() {
        // A fresh, empty field with no harvested context yet.
        let selection = PersonalizationRetrieval.select(profile: profile(), query: "")
        #expect(selection?.usedRecencyOnly == true)
        #expect(selection?.text.hasPrefix("Wir treffen uns am Donnerstag") == true)
    }

    @Test func aQueryThatMatchesNothingIsTreatedAsNoQuery() {
        let selection = PersonalizationRetrieval.select(
            profile: profile(), query: "Zebra Xylophon Kaktus")
        #expect(selection?.usedRecencyOnly == true)
    }

    // MARK: The two "inject nothing" cases

    @Test func anEmptyProfileYieldsNil() {
        #expect(PersonalizationRetrieval.select(profile: StyleProfile(), query: "irgendwas") == nil)
    }

    @Test func aProfileBelowTheMinimumExemplarCountYieldsNil() {
        var p = StyleProfile()
        p.ingest(ownText: "Ein einzelner Satz reicht nicht.")
        #expect(!p.hasEnoughToInject)
        #expect(PersonalizationRetrieval.select(profile: p, query: "Satz") == nil)
    }

    @Test func aBudgetTooSmallForEvenOneExemplarYieldsNil() {
        #expect(PersonalizationRetrieval.select(profile: profile(), query: "Rechnung", budget: 5) == nil)
    }

    // MARK: Budget packing

    @Test func fillsToBudgetAndNeverExceedsIt() {
        var p = StyleProfile()
        for i in 0..<40 { p.ingest(ownText: "Beispielsatz nummer \(i) mit etwas Fülltext dahinter.") }
        let selection = PersonalizationRetrieval.select(profile: p, query: "", budget: 200)
        #expect(selection != nil)
        #expect(selection!.text.count <= 200)
        #expect(selection!.exemplarCount >= 2)
    }

    @Test func skipsAnOverLongExemplarInsteadOfSuppressingTheWholeSegment() {
        var p = StyleProfile()
        p.ingest(ownText: String(repeating: "Ausschweifend ", count: 30) + "Ende.")
        p.ingest(ownText: "Kurz und knapp gesagt.")
        p.ingest(ownText: "Noch ein kurzer Satz.")
        p.ingest(ownText: "Und ein dritter kurzer Satz.")
        let selection = PersonalizationRetrieval.select(profile: p, query: "", budget: 120)
        #expect(selection != nil)
        #expect(selection!.exemplarCount >= 2)
    }

    @Test func neverInjectsMoreThanTheExemplarCeiling() {
        var p = StyleProfile()
        for i in 0..<40 { p.ingest(ownText: "Kurzer Satz \(i) hier.") }
        let selection = PersonalizationRetrieval.select(profile: p, query: "", budget: 2000)
        #expect(selection!.exemplarCount == PersonalizationRetrieval.maxExemplars)
    }

    // MARK: The eval-gated term line

    @Test func theTermLineIsOffByDefaultBecauseItIsEvalGated() {
        let selection = PersonalizationRetrieval.select(profile: profile(), query: "Rechnung")
        #expect(selection?.termLine == nil)
    }

    @Test func spaceJoinedTermLineLeadsTheSegmentAndCountsAgainstTheBudget() {
        let selection = PersonalizationRetrieval.select(
            profile: profile(), query: "Rechnung", termLine: .spaceJoined)
        let line = selection?.termLine
        #expect(line != nil)
        #expect(!line!.contains(","))
        #expect(selection!.text.hasPrefix(line!))
        #expect(selection!.text.count <= PersonalizationRetrieval.charBudget)
    }

    @Test func commaJoinedTermLineIsTheOtherEvalArm() {
        let selection = PersonalizationRetrieval.select(
            profile: profile(), query: "Rechnung", termLine: .commaJoined)
        #expect(selection?.termLine?.contains(", ") == true)
    }
}

/// The cadence rule: re-select **once** per context switch, when the ambient harvest
/// lands — never per keystroke, and never twice inside a typing burst.
@Suite struct PersonalizationCadenceTests {
    typealias Cadence = PersonalizationCadence

    @Test func aResolvedSelectionIsKeptForTheWholeBurst() {
        #expect(Cadence.decide(selectionResolved: true, ambientQueryAvailable: true,
                               predictsSinceSwitch: 1) == .keepFrozen)
        #expect(Cadence.decide(selectionResolved: true, ambientQueryAvailable: false,
                               predictsSinceSwitch: 99) == .keepFrozen)
    }

    @Test func anEmptyVerdictIsAlsoResolvedAndDoesNotReFirePerPredict() {
        // "Nothing to inject" (profile too small) is a decision. Re-deciding it per keystroke would
        // re-run the whole scan for every user who hasn't written enough yet.
        #expect(Cadence.decide(selectionResolved: true, ambientQueryAvailable: true,
                               predictsSinceSwitch: 50) == .keepFrozen)
    }

    @Test func selectsAsSoonAsTheAmbientHarvestHasLanded() {
        #expect(Cadence.decide(selectionResolved: false, ambientQueryAvailable: true,
                               predictsSinceSwitch: 1) == .selectWithQuery)
    }

    @Test func waitsForTheHarvestInsteadOfSelectingOnTheBareSwitchInstant() {
        // The harvest is async/off-path, so the first predicts after a switch see no context yet;
        // selecting there would degrade every switch to recency-top.
        #expect(Cadence.decide(selectionResolved: false, ambientQueryAvailable: false,
                               predictsSinceSwitch: 1) == .wait)
    }

    @Test func givesUpWaitingAfterAFewPredictsAndUsesRecency() {
        // Surfaces with no harvestable context (a bare TextEdit window) must still get a voice prime.
        #expect(Cadence.decide(selectionResolved: false, ambientQueryAvailable: false,
                               predictsSinceSwitch: Cadence.maxWaitedPredicts) == .selectRecencyOnly)
    }
}
