import Testing
@testable import NextTypedCore

@Suite struct ReplyContextTests {
    let recipe = ReplySurfaceDescriptor.anthropicChat

    // MARK: Speaker classification (fail-closed)

    @Test func classifiesInterlocutorEN() {
        #expect(recipe.classify("Claude responded:") == .interlocutor)
        #expect(recipe.classify("Claude said") == .interlocutor)
    }

    @Test func classifiesUserEN() {
        #expect(recipe.classify("You said:") == .user)
    }

    @Test func classifiesInterlocutorDE() {
        // Defensive DE variants — a wrong guess is fail-closed, but the shipped guesses classify.
        #expect(recipe.classify("Claude hat geantwortet:") == .interlocutor)
    }

    @Test func classifiesUserDE() {
        #expect(recipe.classify("Du sagtest:") == .user)
        #expect(recipe.classify("Du hast gesagt:") == .user)
    }

    @Test func unknownLabelIsUnknown() {
        #expect(recipe.classify("System message") == .unknown)
        #expect(recipe.classify("Tool result") == .unknown)
    }

    @Test func nilOrEmptyLabelIsUnknown() {
        #expect(recipe.classify(nil) == .unknown)
        #expect(recipe.classify("") == .unknown)
    }

    @Test func caseInsensitive() {
        #expect(recipe.classify("CLAUDE RESPONDED") == .interlocutor)
        #expect(recipe.classify("you said") == .user)
    }

    @Test func userPatternWinsOverInterlocutor() {
        // A pathological label matching BOTH must classify as the user (never emit own text).
        let d = ReplySurfaceDescriptor(
            id: "t", bundleIDs: [],
            interlocutorPatterns: ["responded"],
            userPatterns: ["you"],
            headCapChars: 100
        )
        #expect(d.classify("You responded") == .user)
    }

    // MARK: Turn selection (most-recent interlocutor, fail-closed)

    @Test func selectsMostRecentInterlocutorTurn() {
        let turns = [
            ReplyTurn(speakerLabel: "You said:", text: "first question"),
            ReplyTurn(speakerLabel: "Claude responded:", text: "first answer"),
            ReplyTurn(speakerLabel: "You said:", text: "second question"),
            ReplyTurn(speakerLabel: "Claude responded:", text: "second answer"),
        ]
        #expect(recipe.selectReplyContext(from: turns) == "second answer")
    }

    @Test func ignoresTrailingUserTurn() {
        // The user is mid-reply: the last turn is theirs, but we want the interlocutor's PRIOR turn.
        let turns = [
            ReplyTurn(speakerLabel: "Claude responded:", text: "the answer"),
            ReplyTurn(speakerLabel: "You said:", text: "my half-typed reply"),
        ]
        #expect(recipe.selectReplyContext(from: turns) == "the answer")
    }

    @Test func failsClosedWhenNoInterlocutorTurn() {
        // Only user turns / unknown headings → emit nothing (never fall back to the user's own text).
        let turns = [
            ReplyTurn(speakerLabel: "You said:", text: "only me talking"),
            ReplyTurn(speakerLabel: nil, text: "unattributed chrome text"),
        ]
        #expect(recipe.selectReplyContext(from: turns) == nil)
    }

    @Test func failsClosedOnEmptyTurns() {
        #expect(recipe.selectReplyContext(from: []) == nil)
    }

    @Test func skipsEmptyInterlocutorText() {
        let turns = [
            ReplyTurn(speakerLabel: "Claude responded:", text: "   \n  "),
        ]
        #expect(recipe.selectReplyContext(from: turns) == nil)
    }

    @Test func trimsAndHeadCaps() {
        let long = String(repeating: "a", count: 5000)
        let turns = [ReplyTurn(speakerLabel: "Claude responded:", text: "  " + long + "  ")]
        let out = recipe.selectReplyContext(from: turns)
        #expect(out?.count == recipe.headCapChars)
    }

    // MARK: Applicability

    @Test func recipeAppliesToClaudeSurfaces() {
        #expect(recipe.bundleIDs.contains("com.anthropic.claudefordesktop"))
        #expect(recipe.bundleIDs.contains("com.apple.Safari"))
        #expect(recipe.bundleIDs.contains("com.apple.TextEdit") == false)
    }
}
