import Foundation
import Testing
@testable import NextTypedCore

/// The two stores of the personalization profile: sentence exemplars (voice) and the
/// characteristic-term table (vocabulary). Both are pure and time-free — the "clock" is a capture
/// ordinal the caller advances, so eviction and recency-decay are deterministic in tests.
@Suite struct StyleProfileTests {

    // MARK: Emptiness (the Privacy pane disables "Delete learned profile" for an empty profile)

    @Test func aFreshProfileIsEmpty() {
        #expect(StyleProfile().isEmpty)
    }

    @Test func aProfileWithOneLearnedSentenceIsNotEmpty() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Ich habe das Ticket heute geschlossen.")
        #expect(!profile.isEmpty)
    }

    // MARK: Segmentation (the own-inserted stream is cut with ClauseStop)

    @Test func segmentsTheOwnInsertedStreamIntoClauses() {
        let parts = StyleProfile.segment("Ich habe das Ticket geschlossen. Die Review ist durch!")
        #expect(parts == ["Ich habe das Ticket geschlossen.", "Die Review ist durch!"])
    }

    @Test func dropsTheIncompleteTailThatHasNoBoundaryYet() {
        // The user is mid-sentence when focus leaves; a half sentence is not a voice exemplar.
        let parts = StyleProfile.segment("Fertig für heute. Morgen schaue ich mir")
        #expect(parts == ["Fertig für heute."])
    }

    @Test func dropsClausesTooShortToCarryVoice() {
        // "Danke!" is a reflex, not a style signal — and would flood the store from sign-offs.
        #expect(StyleProfile.segment("Danke! Ok. Ich schaue mir das gleich an.")
                == ["Ich schaue mir das gleich an."])
    }

    @Test func aNewlineEndsAClauseSoOwnInsertedLinesAreSeparateExemplars() {
        let parts = StyleProfile.segment("Der Build läuft wieder durch\nDas Ticket ist damit erledigt\n")
        #expect(parts == ["Der Build läuft wieder durch", "Das Ticket ist damit erledigt"])
    }

    // MARK: Store A — exemplars

    @Test func ingestStoresOneExemplarPerClause() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Der Build läuft durch. Ich merge das gleich.", language: "de")
        #expect(profile.exemplars.map(\.text)
                == ["Der Build läuft durch.", "Ich merge das gleich."])
        #expect(profile.exemplars.allSatisfy { $0.language == "de" })
    }

    @Test func exemplarsCarryAMonotonicCaptureOrdinal() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Erste Zeile hier steht.")
        profile.ingest(ownText: "Zweite Zeile kommt später.")
        let stamps = profile.exemplars.map(\.capturedAt)
        #expect(stamps == stamps.sorted())
        #expect(stamps[0] < stamps[1])
    }

    @Test func dropsAnExactRepeatSoSignOffsDoNotFlood() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Viele Grüße und ein schönes Wochenende.")
        profile.ingest(ownText: "Viele Grüße und ein schönes Wochenende.")
        #expect(profile.exemplars.count == 1)
    }

    @Test func dropsANormalizedRepeatDifferingOnlyInCaseSpacingOrFinalPunctuation() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Ich schaue mir das morgen an.")
        profile.ingest(ownText: "ich  schaue mir  das morgen an!")
        #expect(profile.exemplars.count == 1)
    }

    @Test func dropsANearDuplicateAboveTheJaccardThreshold() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Vielen Dank für die schnelle Rückmeldung zum Ticket.")
        // Same token set bar one — a greeting variant, not a new voice sample.
        profile.ingest(ownText: "Vielen Dank für die schnelle Rückmeldung zum Ticket heute.")
        #expect(profile.exemplars.count == 1)
    }

    @Test func dropsAWordPrefixOfAnExistingExemplarBeyondTheWordFloor() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Ich habe die Review abgeschlossen und das Ticket zugemacht.")
        profile.ingest(ownText: "Ich habe die Review abgeschlossen.")
        #expect(profile.exemplars.count == 1)
    }

    @Test func keepsAGenuinelyDifferentSentence() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Der Build läuft wieder durch.")
        profile.ingest(ownText: "Die Latenz liegt jetzt unter dreihundert Millisekunden.")
        #expect(profile.exemplars.count == 2)
    }

    @Test func evictsTheOldestExemplarsAtTheCap() {
        // Seeded rather than ingested: the dedup scan is O(store) by design, so filling the cap through
        // `ingest` would make this a performance test rather than an eviction test.
        var profile = StyleProfile()
        profile.exemplars = (0..<StyleProfile.exemplarCap).map {
            StyleExemplar(text: "Vorbelegter Satz nummer \($0).", capturedAt: $0)
        }
        profile.ingest(ownText: "Ein frisch getippter Satz kommt dazu.")
        #expect(profile.exemplars.count == StyleProfile.exemplarCap)
        // LRU by capture time: the oldest went, the newest is at the tail.
        #expect(profile.exemplars.first?.text.contains("nummer 1.") == true)
        #expect(profile.exemplars.last?.text == "Ein frisch getippter Satz kommt dazu.")
    }

    // MARK: Store B — characteristic terms

    @Test func learnsCharacteristicTermsAndSkipsCommonWords() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Der Deployment Pipeline Fehler ist behoben.")
        let terms = Set(profile.characteristicTerms)
        #expect(terms.contains("deployment"))
        #expect(terms.contains("pipeline"))
        // "der"/"ist" are in the shipped DE denylist; "the"/"is" in the EN one — the union is tested
        // against every term regardless of the text's language (no per-text detection).
        #expect(!terms.contains("der"))
        #expect(!terms.contains("ist"))
    }

    @Test func theDenylistIsTheUnionOfBothLanguages() {
        var profile = StyleProfile()
        // A German sentence containing an English common word: "and" must still be filtered.
        profile.ingest(ownText: "Wir nutzen Kubernetes and Terraform im Cluster.")
        #expect(!profile.characteristicTerms.contains("and"))
        #expect(profile.characteristicTerms.contains("kubernetes"))
    }

    @Test func learnsBigramsOnlyWhenBothHalvesAreCharacteristic() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Ich teste das in Claude Desktop und im Browser.")
        let terms = Set(profile.characteristicTerms)
        #expect(terms.contains("claude desktop"))
        // "in claude" pairs a common word with a characteristic one — not a phrase worth storing.
        #expect(!terms.contains("in claude"))
    }

    @Test func ranksFrequentTermsAboveOneOffs() {
        var profile = StyleProfile()
        profile.ingest(ownText: "Das Deployment war erfolgreich heute.")
        profile.ingest(ownText: "Das Deployment läuft jetzt schneller durch.")
        profile.ingest(ownText: "Ein einzelner Sonderfall bleibt offen.")
        let terms = profile.characteristicTerms
        #expect(terms.first == "deployment")
        #expect(terms.contains("sonderfall"))
    }

    @Test func countsTermsEvenWhenTheSentenceItselfIsDedupedAway() {
        // a repeated sign-off contributes its *voice* once but its *frequency* every time —
        // that split is the whole reason the term table exists alongside the exemplars.
        var profile = StyleProfile()
        profile.ingest(ownText: "Viele Grüße aus Hamburg heute.")
        profile.ingest(ownText: "Viele Grüße aus Hamburg heute.")
        #expect(profile.exemplars.count == 1)
        #expect((profile.terms["hamburg"]?.score ?? 0) > 1.0)
    }

    @Test func recencyDecayLetsCurrentVocabularyOvertakeStaleVocabulary() {
        var profile = StyleProfile()
        for _ in 0..<4 { profile.ingest(ownText: "Damals ging es nur um Faxgeräte.") }
        // A stretch of new vocabulary decays the old counts below the new ones.
        for _ in 0..<4 { profile.ingest(ownText: "Inzwischen geht es ausschließlich um Kubernetes.") }
        let ranked = profile.characteristicTerms
        let kubernetes = ranked.firstIndex(of: "kubernetes") ?? .max
        let fax = ranked.firstIndex(of: "faxgeräte") ?? .max
        #expect(kubernetes < fax)
    }

    @Test func evictsTheLowestScoringTermsAtTheCap() {
        var profile = StyleProfile()
        for i in 0..<StyleProfile.termCap {
            profile.terms["streuwort\(i)"] = TermStat(score: 0.01, lastSeenAt: i)
        }
        profile.terms["kernbegriff"] = TermStat(score: 42, lastSeenAt: 0)
        profile.ingest(ownText: "Ein frischer Fachbegriff erscheint hier.")
        #expect(profile.terms.count == StyleProfile.termCap)
        // The heavily-used term outranks the flood of one-offs and the fresh term got in.
        #expect(profile.terms["kernbegriff"] != nil)
        #expect(profile.terms["fachbegriff"] != nil)
        #expect(profile.terms["streuwort0"] == nil)
    }

    // MARK: Round-trip + reset

    @Test func roundTripsThroughJSON() throws {
        var profile = StyleProfile()
        profile.ingest(ownText: "Der Build läuft wieder durch.", language: "de")
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(StyleProfile.self, from: data)
        #expect(decoded == profile)
    }

    @Test func isEmptyUntilTheMinimumExemplarCountIsReached() {
        var profile = StyleProfile()
        #expect(!profile.hasEnoughToInject)
        for i in 0..<StyleProfile.minimumExemplars {
            profile.ingest(ownText: "Ein weiterer Beispielsatz nummer \(i).")
        }
        #expect(profile.hasEnoughToInject)
    }
}
