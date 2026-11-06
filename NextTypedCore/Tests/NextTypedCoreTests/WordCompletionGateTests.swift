import Testing
@testable import NextTypedCore

/// The word-completion gate: a continuation that glues onto the token
/// behind the caret is allowed where the caret was reached by TYPING and refused where it was
/// reached by NAVIGATION. Both directions are pinned, because the risk is symmetric —
/// too broad and the completion-first rule is silently withdrawn; too narrow and the reported
/// `Wort` → `Wortlaut` stays.
@Suite struct WordCompletionGateTests {

    private func ctx(_ before: String) -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: "", bundleID: "com.test")
    }

    // MARK: Reached by typing — completion-first territory, untouched

    @Test func aTypedFlushCaretStillGetsTheGluedCompletion() {
        #expect(WordCompletionGate.allowsContinuation("laut", trigger: .typing, in: ctx("Am Anfang war das Wort")))
    }

    @Test func theGenuineMidWordCompletionSurvives() {
        // `Wohnu` → `ng` is only reachable by typing, which is why it is out of this gate's reach.
        #expect(WordCompletionGate.allowsContinuation("ng", trigger: .typing, in: ctx("Ich suche eine Wohnu")))
    }

    // MARK: Reached by navigation — no fragment was typed, so nothing may glue

    @Test func aNavigatedFlushCaretRefusesTheGluedCompletion() {
        #expect(!WordCompletionGate.allowsContinuation("laut", trigger: .caretMoved, in: ctx("Am Anfang war das Wort")))
    }

    @Test func aNavigatedFlushCaretStillAcceptsANextWordContinuation() {
        // The next-word shape the gate is asking for: it brings its own gap, so it cannot read as a
        // compound.
        #expect(WordCompletionGate.allowsContinuation(" ist entscheidend", trigger: .caretMoved,
                                                      in: ctx("Am Anfang war das Wort")))
    }

    @Test func aCaretAfterBackspaceIsNavigation() {
        // `KeyClassifier` routes backspace as a caret move, and a delete lands mid-word by nature —
        // the case most likely to be wrong in either direction. Decided as navigation: the user
        // deleted, they did not type a fragment.
        #expect(!WordCompletionGate.allowsContinuation("nung", trigger: .caretMoved, in: ctx("Ich suche eine Woh")))
    }

    @Test func aCaretAfterAWordAndASpaceIsNotAffected() {
        // Not a flush caret at all: whatever follows renders detached whichever way it starts.
        #expect(WordCompletionGate.allowsContinuation("laut", trigger: .caretMoved, in: ctx("Am Anfang war das Wort ")))
    }

    @Test func aCaretAfterPunctuationIsNotAffected() {
        #expect(WordCompletionGate.allowsContinuation("Dann", trigger: .caretMoved, in: ctx("Das war alles.")))
    }

    @Test func aDigitCountsAsAWordCharacterOnBothSides() {
        #expect(!WordCompletionGate.allowsContinuation("00", trigger: .caretMoved, in: ctx("Der Betrag lag bei 35")))
    }

    @Test func anUmlautCountsAsAWordCharacter() {
        // Language-agnostic, like `CaretPositionGate`: ß/ä/ö/ü are letters, not punctuation.
        #expect(!WordCompletionGate.allowsContinuation("ren", trigger: .caretMoved, in: ctx("Wir wollten dorthin fahren müssen sie erklä")))
    }

    // MARK: Punctuation leads are somebody else's decision

    @Test func aBoundaryPunctuationLeadIsNotGlue() {
        // `Wort` + `: nämlich` attaches legitimately; the boundary-lead rule owns whether it renders.
        #expect(WordCompletionGate.allowsContinuation(": nämlich das", trigger: .caretMoved,
                                                      in: ctx("Am Anfang war das Wort")))
    }

    // MARK: The refill exemption — the failure this mechanism invites

    @Test func theAcceptRefillIsExemptEvenThoughItsCaretLooksNavigated() {
        // After a `Tab` chain empties the buffer the caret sits flush behind a word WE just inserted,
        // and the refill arrives on a caret-move-shaped trigger. Refusing there would break the accept
        // chain at every exhaustion — which is why the refill has a trigger of its own.
        #expect(WordCompletionGate.allowsContinuation("laut", trigger: .acceptRefill,
                                                      in: ctx("Am Anfang war das Wort")))
    }

    @Test func theEmptyStringIsNeverTheGatesBusiness() {
        #expect(WordCompletionGate.allowsContinuation("", trigger: .caretMoved, in: ctx("Am Anfang war das Wort")))
    }

    @Test func aFieldStartHasNothingToGlueOnto() {
        #expect(WordCompletionGate.allowsContinuation("Hallo", trigger: .caretMoved, charBeforeCaret: nil))
    }
}
