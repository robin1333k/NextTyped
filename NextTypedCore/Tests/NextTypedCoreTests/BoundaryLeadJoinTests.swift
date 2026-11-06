import Testing
@testable import NextTypedCore

/// a continuation opening with attaching
/// punctuation is **joined** to the caret instead of suppressed. Every case the earlier rule pinned as a
/// suppression is re-pinned here as the join it became; the two cases it pinned as *rendering
/// unchanged* (`.Net`-shaped tokens, the flush-caret attached lead) are re-pinned as untouched.
struct BoundaryLeadJoinTests {
    // MARK: The ticket's case — the space belongs to the punctuation, not to the caret

    @Test func consumesTheSpaceBeforeTheCaret() {
        // "Winter |" + ". Es wird kalt" → accepting must produce "Winter. Es wird kalt".
        let r = BoundaryLeadJoin.apply(to: ". Es wird kalt", textBeforeCaret: "Der Winter ")
        #expect(r == .init(text: ". Es wird kalt", consumesPrecedingSpace: true))
    }

    @Test func aBareMarkAtAWhitespaceCaretIsStillAJoin() {
        // The three bare "?" of the archived count. The join is correct here too; whether such a
        // ghost is ever SHOWN is `SuggestionValueGate`'s call, not this one's.
        #expect(BoundaryLeadJoin.apply(to: "?", textBeforeCaret: "wirklich ")
                == .init(text: "?", consumesPrecedingSpace: true))
    }

    // MARK: §3's symmetric arm — the same typo from the result side

    @Test func dropsTheResultsOwnSpaceAtAFlushCaret() {
        // "kalt|" + ". Es" would render "kalt. Es"; there is no caret space to consume, so the
        // fix is free and the accept stays a plain insert.
        #expect(BoundaryLeadJoin.apply(to: " . Es wird", textBeforeCaret: "Es ist kalt")
                == .init(text: ". Es wird", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: " ! Doch", textBeforeCaret: "Nein")
                == .init(text: "! Doch", consumesPrecedingSpace: false))
    }

    @Test func bothGapsCollapseToOneJoin() {
        #expect(BoundaryLeadJoin.apply(to: " . Es", textBeforeCaret: "kalt ")
                == .init(text: ". Es", consumesPrecedingSpace: true))
    }

    // MARK: Untouched — byte-identical to the pre-ticket pipeline

    @Test func theFlushAttachedLeadIsUntouched() {
        // The typographically perfect case the decode-through exists to enable.
        #expect(BoundaryLeadJoin.apply(to: ". Es wird kalt", textBeforeCaret: "Der Winter")
                == .init(text: ". Es wird kalt", consumesPrecedingSpace: false))
    }

    @Test func tokenShapedLeadsAreNotBoundaries() {
        // The mark must be followed by whitespace or end — the earlier shape guard, kept verbatim.
        #expect(BoundaryLeadJoin.apply(to: ".Net is great", textBeforeCaret: "Ich mag ")
                == .init(text: ".Net is great", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: " .Net rocks", textBeforeCaret: "Ich mag")
                == .init(text: " .Net rocks", consumesPrecedingSpace: false))
        // A decimal comma and a clock colon are the same shape as the `3.500` guard in `ClauseStop`.
        #expect(BoundaryLeadJoin.apply(to: ",5 Prozent", textBeforeCaret: "etwa 3 ")
                == .init(text: ",5 Prozent", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: ":30 Uhr", textBeforeCaret: "um 10 ")
                == .init(text: ":30 Uhr", consumesPrecedingSpace: false))
    }

    @Test func ordinaryContinuationsAreUntouched() {
        #expect(BoundaryLeadJoin.apply(to: "Dann kommt", textBeforeCaret: "kalt ")
                == .init(text: "Dann kommt", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: " Dann kommt", textBeforeCaret: "kalt")
                == .init(text: " Dann kommt", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: "", textBeforeCaret: "kalt ")
                == .init(text: "", consumesPrecedingSpace: false))
    }

    @Test func anEllipsisLeadIsNotAttaching() {
        // "..." is neither content nor a clause boundary for `ClauseStop`, and it reads both ways
        // typographically — deliberately left out of the attaching set, as it was out of §3's.
        #expect(BoundaryLeadJoin.apply(to: "... und dann", textBeforeCaret: "kalt ")
                == .init(text: "... und dann", consumesPrecedingSpace: false))
    }

    @Test func openingMarksKeepTheirGap() {
        // A bracket or quote legitimately WANTS the preceding space; consuming it would be the bug
        // this type exists to fix, mirrored.
        #expect(BoundaryLeadJoin.apply(to: "( siehe oben", textBeforeCaret: "Der Wert ")
                == .init(text: "( siehe oben", consumesPrecedingSpace: false))
        #expect(BoundaryLeadJoin.apply(to: "\" Hallo", textBeforeCaret: "sagte ")
                == .init(text: "\" Hallo", consumesPrecedingSpace: false))
    }

    // MARK: The comma class the earlier rule deliberately left rendering (folded in here)

    @Test func commaAndSemicolonLeadsJoinToo() {
        // "kalt, und dann" was pre-existing behaviour: suppressing it would have thrown away real
        // content. Replace-backwards throws nothing away, so the class is folded in.
        #expect(BoundaryLeadJoin.apply(to: ", und dann", textBeforeCaret: "Es ist kalt ")
                == .init(text: ", und dann", consumesPrecedingSpace: true))
        #expect(BoundaryLeadJoin.apply(to: "; aber", textBeforeCaret: "kalt ")
                == .init(text: "; aber", consumesPrecedingSpace: true))
        #expect(BoundaryLeadJoin.apply(to: ": nämlich", textBeforeCaret: "Gründe ")
                == .init(text: ": nämlich", consumesPrecedingSpace: true))
    }

    @Test func aNewlineBeforeTheCaretIsNeverConsumed() {
        // `textBeforeCaret` is host text, so its last character can be a line break. Eating it to
        // save one character would merge two paragraphs — destructive where the gain is typography.
        let r = BoundaryLeadJoin.apply(to: ". Es wird kalt", textBeforeCaret: "Der Winter.\n")
        #expect(r == .init(text: ". Es wird kalt", consumesPrecedingSpace: false))
        // A result-side space at a line start is still dropped: nothing is consumed, the accept
        // stays an insert, and the ghost no longer opens with a stray gap.
        #expect(BoundaryLeadJoin.apply(to: " . Es", textBeforeCaret: "Winter.\n")
                == .init(text: ". Es", consumesPrecedingSpace: false))
    }

    @Test func aTabBeforeTheCaretIsConsumedLikeASpace() {
        #expect(BoundaryLeadJoin.apply(to: ". Es", textBeforeCaret: "Winter\t").consumesPrecedingSpace)
    }
}
