import Testing
@testable import NextTypedCore

/// A suggestion the user accepted and then removed again is not offered again at that caret.
/// Driven through the reducer's events only, with literal contexts.
@Suite struct TakeBackTests {

    private let caretAtEnd = CaretFacts(hasTextToRight: false)

    private func ctx(_ before: String, after: String = "") -> TypingContext {
        TypingContext(textBeforeCaret: before, textAfterCaret: after)
    }

    /// A typed run at `before` that produced the ghost `ghost`.
    private func show(_ ghost: String, at before: String, in s: inout SuggestionSession) {
        _ = s.handle(.contextReady(ctx(before), caret: caretAtEnd, trigger: .typing))
        _ = s.handle(.predictionArrived(Suggestion(text: ghost), nil))
    }

    /// The loop asks again at `before` (a typed run) and the model answers `ghost`.
    private func predict(_ ghost: String, at before: String, after: String = "",
                         in s: inout SuggestionSession) -> [Effect] {
        _ = s.handle(.contextReady(ctx(before, after: after), caret: caretAtEnd, trigger: .typing))
        return s.handle(.predictionArrived(Suggestion(text: ghost), nil))
    }

    // MARK: Criterion 1 and 8: Tab, then backspace

    @Test func aWordAcceptedWithTabAndDeletedIsNotOfferedAgain() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        #expect(s.interceptKey(.tab).1 == [.insert(" liebe")])
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)   // the backspace run

        let effects = predict(" liebe Leute", at: "Guten Morgen", in: &s)

        #expect(effects == [.logGate("take-back len=6"), .present(.none)])
        #expect(s.currentPresentation == .none)
    }

    // MARK: Criterion 2: ⌥Tab, then a backspace run over the whole insert

    @Test func aWholeSuggestionAcceptedWithOptionTabAndDeletedIsNotOfferedAgain() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        #expect(s.interceptKey(.acceptAll).1 == [.insert(" liebe Leute"), .present(.none)])
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)

        let effects = predict(" liebe Leute", at: "Guten Morgen", in: &s)

        #expect(effects == [.logGate("take-back len=12"), .present(.none)])
    }

    // MARK: Criterion 3: a chain of three accepts, each word deleted in turn

    @Test func eachOfThreeChainedAcceptsIsRefusedAtItsOwnPrefixOnTheWayBack() {
        var s = SuggestionSession()
        show(" liebe Leute heute", at: "Guten Morgen", in: &s)
        #expect(s.interceptKey(.tab).1 == [.insert(" liebe")])
        _ = s.handle(.hostEcho)
        #expect(s.interceptKey(.tab).1 == [.insert(" Leute")])
        _ = s.handle(.hostEcho)
        #expect(s.interceptKey(.tab).1 == [.insert(" heute"), .present(.none)])
        _ = s.handle(.hostEcho)

        _ = s.handle(.caretMove)
        #expect(predict(" heute", at: "Guten Morgen liebe Leute", in: &s)
                == [.logGate("take-back len=6"), .present(.none)])
        _ = s.handle(.caretMove)
        #expect(predict(" Leute heute", at: "Guten Morgen liebe", in: &s)
                == [.logGate("take-back len=6"), .present(.none)])
        _ = s.handle(.caretMove)
        #expect(predict(" liebe Leute heute", at: "Guten Morgen", in: &s)
                == [.logGate("take-back len=6"), .present(.none)])
    }

    /// The accept anchor's prefix follows the text typed along the ghost (SmartAdvance), not the
    /// prefix the decode started from.
    @Test func anAcceptAfterTypingAlongAnchorsAtTheTypedPrefix() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        for character in " liebe" { _ = s.handle(.typed(String(character))) }
        _ = s.handle(.hostEcho)
        #expect(s.interceptKey(.tab).1 == [.insert(" Leute"), .present(.none)])
        _ = s.handle(.caretMove)

        #expect(predict(" Leute", at: "Guten Morgen liebe", in: &s)
                == [.logGate("take-back len=6"), .present(.none)])
    }

    // MARK: Criterion 4: arrowing back over the accepted text

    @Test func arrowingBackWithTheAcceptedTextStillRightOfTheCaretIsNotATakeBack() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)   // ← six times

        let effects = predict(" liebe Leute", at: "Guten Morgen", after: " liebe", in: &s)

        #expect(effects == [.present(.continuation(" liebe Leute"))])
    }

    // MARK: Criterion 5: a different first word

    @Test func aContinuationWithADifferentFirstWordIsShownAtTheTakenBackPrefix() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)

        let effects = predict(" zusammen allerseits", at: "Guten Morgen", in: &s)

        #expect(effects == [.present(.continuation(" zusammen allerseits"))])
    }

    /// Words compare case-sensitively: `Liebe` is not the word the user took back.
    @Test func theFirstWordComparesCaseSensitively() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)

        #expect(predict(" Liebe Leute", at: "Guten Morgen", in: &s) == [.present(.continuation(" Liebe Leute"))])
    }

    // MARK: Criterion 6: typing resumes, a focus change forgets

    @Test func afterTypingACharacterThePrefixDiffersAndSuggestionsResume() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)
        _ = predict(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.handle(.typed(","))

        #expect(predict(" liebe Leute", at: "Guten Morgen,", in: &s) == [.present(.continuation(" liebe Leute"))])
    }

    @Test func aFocusChangeDropsTheAnchors() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)
        _ = s.handle(.focusChanged)

        #expect(predict(" liebe Leute", at: "Guten Morgen", in: &s) == [.present(.continuation(" liebe Leute"))])
    }

    @Test func aPauseDropsTheAnchors() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.setPaused(true))
        _ = s.handle(.setPaused(false))

        #expect(predict(" liebe Leute", at: "Guten Morgen", in: &s) == [.present(.continuation(" liebe Leute"))])
    }

    @Test func aTemporaryQuietDropsTheAnchors() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.apple.TextEdit"))
        _ = s.handle(.temporaryQuietEnded(bundleID: "com.apple.TextEdit", resumedExplicitly: false))

        #expect(predict(" liebe Leute", at: "Guten Morgen", in: &s) == [.present(.continuation(" liebe Leute"))])
    }

    // MARK: Criterion 7: an undo that removes exactly T

    /// After ⌘Z (a `.caretMove`) the context is `P` with nothing to the right. The caret-move
    /// predict replays the cached suggestion (same prompt inputs), and the replay passes the gate too.
    @Test func anUndoThatRemovesTheAcceptedTextIsATakeBackOnTheReplay() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)   // ⌘Z

        let effects = s.handle(.contextReady(ctx("Guten Morgen"), caret: caretAtEnd, trigger: .caretMoved))

        #expect(effects == [.surfaceVerdict(.on), .logGate("take-back len=6"), .present(.none)])
    }

    // MARK: What records no anchor

    /// An accept that consumed the space before the caret records nothing.
    @Test func anAcceptThatConsumesThePrecedingSpaceRecordsNoAnchor() {
        var s = SuggestionSession()
        show(". Es ist", at: "Es war Winter ", in: &s)
        #expect(s.interceptKey(.tab).1 == [.replace(charactersBack: 1, with: ".")])
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)

        #expect(predict(". Es ist", at: "Es war Winter ", in: &s)
                == [.logGate("boundary-lead consumes-space"), .present(.continuation(ContinuationGhost(". Es ist", consumesPrecedingSpace: true)))])
    }

    /// The gate is a continuation gate: a correction on the same context still shows.
    @Test func theCorrectionAtATakenBackPrefixStillShows() {
        var s = SuggestionSession()
        show(" liebe Leute", at: "Guten Morgen", in: &s)
        _ = s.interceptKey(.tab)
        _ = s.handle(.hostEcho)
        _ = s.handle(.caretMove)
        let fix = Correction(original: "Morgen", replacement: "Morgen!", charactersBackFromCaret: 6)
        _ = s.handle(.contextReady(ctx("Guten Morgen"), caret: caretAtEnd, trigger: .typing))

        let effects = s.handle(.predictionArrived(Suggestion(text: " liebe Leute"), fix))

        #expect(effects == [.logGate("take-back len=6"), .present(.correction(fix))])
    }
}
