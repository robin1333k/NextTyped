import Testing
@testable import NextTypedCore

/// **both** arms of the running-thought gate apply to a **FIM bridge**, not only to
/// a forward continuation.
///
/// Kept apart from `RunningThoughtGateTests`, which is about the arms themselves. These pin the
/// *decision that they reach a mid-text caret* — arm 1 upstream of the route, arm 2 computed off the
/// bridge's own raw middle — which is the property a later "make the gates consistent" pass would
/// otherwise quietly reverse.
///
/// Nothing here runs a model. The FIM predict lives in the App target, the weights are unhosted, the
/// feature is default-off and no harness scenario reaches the path, so what is testable is the pure
/// half: the gate's arithmetic over the raw middle, the shape-destroying step it must run *before*, and
/// the reducer's handling of the flag on a mid-text route.
@Suite struct RunningThoughtGateOnTheFIMPathTests {

    private let midTextCaret = CaretFacts(hasTextToRight: true)

    /// A mid-text caret: text before it *and* text after it, which is the configuration arm 1's premise
    /// is weakest in (a suffix exists, so a thought demonstrably exists).
    private func midTextContext(before: String) -> TypingContext {
        TypingContext(textBeforeCaret: before,
                      textAfterCaret: " den Rest des Absatzes.",
                      windowContext: nil,
                      bundleID: "com.test")
    }

    private func fimSession() -> SuggestionSession {
        var s = SuggestionSession()
        _ = s.handle(.setFIMEnabled(true))
        return s
    }

    // MARK: Arm 1 — applies at a mid-text caret, and was decided rather than inherited

    @Test func armOneRefusesAMidTextCaretWithNoRunningThought() {
        // `Protokoll` + a newline is the structural break class C was measured on; one word after it is
        // below `minimumSentenceWords`. The route is FIM (the toggle is on and there IS text to the
        // right), and arm 1 still refuses — upstream of the routing decision, before any bridge is
        // attempted. Recorded as a decision on 2026-08-31, not as the
        // accident it was: exempting it would mean the reducer learning the route before it routes, and
        // would weaken a hard bar on an untested belief.
        var s = fimSession()
        let ctx = midTextContext(before: "Protokoll\nDie ")
        #expect(s.handleReady(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
                == [.logGate("running-thought absent"), .present(.none)])
    }

    @Test func armOneAllowsAMidTextCaretWithARunningThought() {
        // The positive control for the pin above — without it the refusal could be true of every
        // mid-text caret (this project's recurring vacuous pass). Two words in the sentence, same
        // caret, same route: the bridge is attempted. (With the toggle OFF this same context is
        // suppressed as mid-text instead, which is what proves these two tests are on the FIM route.)
        var s = fimSession()
        let ctx = midTextContext(before: "Protokoll\nDie Sitzung ")
        #expect(s.handleReady(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
                == [.runInference(ctx, wantsCorrection: false, wantsContinuation: true)])
    }

    @Test func armOneSitsUpstreamOfTheRouteSoTheToggleCannotChangeItsVerdict() {
        // The same prefix with the toggle off refuses identically — arm 1 runs in `handleContextReady`,
        // *above* the branch that decides which model a caret goes to, and it never learns the route.
        // That is the structural fact the decision rests on: exempting it on a FIM route would mean
        // reordering the reducer's gates, which is explicitly out of scope here.
        var s = SuggestionSession()                       // FIM off — the shipping default
        let ctx = midTextContext(before: "Protokoll\nDie ")
        #expect(s.handleReady(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
                == [.logGate("running-thought absent"), .present(.none)])
    }

    @Test func withTheToggleOffTheSameTwoWordMidTextCaretIsSuppressedAsMidText() {
        // Pins in code what `armOneAllowsAMidTextCaretWithARunningThought`'s comment claims: with FIM
        // off, a mid-text caret is refused by the mid-text rule regardless of the running thought. So
        // the `.runInference` that test expects is reachable ONLY on the FIM route, which is what makes
        // it a positive control for the route and not just for arm 1.
        var s = SuggestionSession()                       // FIM off — the shipping default
        let ctx = midTextContext(before: "Protokoll\nDie Sitzung ")
        #expect(s.handleReady(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
                == [.present(.none)])
    }

    // MARK: Arm 2 — computed off the bridge's RAW middle

    @Test func aBridgeWhoseRawMiddleOpensWithABreakAbandonsTheRunningThought() {
        // The signature arm 2 was built on, in a middle rather than a forward decode: the model stops
        // bridging and starts a new block.
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: "\n\n8. Offene Punkte"))
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: " \nDie Sitzung"))
    }

    @Test func anOrdinaryBridgeDoesNot() {
        // A middle that simply joins `P` to `S` — including one opening with the boundary punctuation
        // `BoundaryLeadJoin` handles, which is not a structural break.
        #expect(!RunningThoughtGate.abandonsRunningThought(rawDecode: " und danach"))
        #expect(!RunningThoughtGate.abandonsRunningThought(rawDecode: ", die gestern begann,"))
    }

    @Test func aNewlineAfterContentIsNotABreakInABridge() {
        // Only the LEADING boundary run carries the signal. A bridge legitimately spans a paragraph
        // join once it has started producing content, and `FIMStop.finalize` flattens that for the
        // never-a-Return reason — it is not the abandonment arm 2 refuses.
        #expect(!RunningThoughtGate.abandonsRunningThought(rawDecode: " und danach\nweiter"))
    }

    /// **The ordering pin.** Arm 2 must be read *before* the shaping, on both paths and for the same
    /// reason: `FIMStop.finalize` flattens newlines to spaces, so a signal computed after it is always
    /// `false` — a defaulted claim wearing a computed one's clothes, which is the trap this ticket was
    /// filed for.
    ///
    /// **What this does and does not pin.** It pins the *reason* — that the shaping destroys the
    /// signal. It cannot pin the engine's call **site**: `predictFIM` lives in the App target, which
    /// no test reaches, so a refactor that moves the call below `FIMStop.finalize` would answer
    /// `false` forever and leave this suite green. Saying otherwise would be a pin that does not
    /// exist, which is worse than none — it is what stops the next reader adding the real one.
    @Test func theShapingDestroysTheSignalSoTheOrderIsLoadBearing() {
        let rawMiddle = "\n\n8. Offene Punkte"
        #expect(RunningThoughtGate.abandonsRunningThought(rawDecode: rawMiddle))
        let shaped = FIMStop.finalize(middle: rawMiddle, suffix: " den Rest.", maxWords: 8) ?? ""
        #expect(!shaped.isEmpty)                                  // there IS text to be fooled by
        #expect(!RunningThoughtGate.abandonsRunningThought(rawDecode: shaped))
    }

    // MARK: The reducer consumes the flag identically on both routes

    @Test func aBridgeThatAbandonsTheRunningThoughtIsRefusedAndLogged() {
        // The reducer half is route-agnostic by construction — it reads one Bool. What changes with
        // this ticket is that a bridge can now SET it, so the refusal and the `[gate]` token are
        // reachable on a FIM route at all. The token's population therefore grows deliberately
        // (a counter that silently changes population corrupts the first
        // measurement anyone takes).
        var s = fimSession()
        let ctx = midTextContext(before: "Protokoll\nDie Sitzung ")
        _ = s.handle(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
        let effects = s.handle(
            .predictionArrived(Suggestion(text: " 8. Offene Punkte", abandonsRunningThought: true), nil))
        #expect(effects.contains(.logGate("running-thought abandoned")))
        #expect(s.currentPresentation == .none)
    }

    @Test func aBridgeThatContinuesTheThoughtIsShown() {
        var s = fimSession()
        let ctx = midTextContext(before: "Protokoll\nDie Sitzung ")
        _ = s.handle(.contextReady(ctx, caret: midTextCaret, trigger: .caretMoved))
        let effects = s.handle(
            .predictionArrived(Suggestion(text: " begann pünktlich", abandonsRunningThought: false), nil))
        #expect(!effects.contains(.logGate("running-thought abandoned")))
        #expect(s.currentPresentation == .continuation(" begann pünktlich"))
    }
}
