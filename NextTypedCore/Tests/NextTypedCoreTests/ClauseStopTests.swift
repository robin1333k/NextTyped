import Testing
@testable import NextTypedCore

@Suite struct ClauseStopTests {
    // MARK: Leading boundary tokens don't stop the decode

    @Test func leadingNewlineIsNotABoundary() {
        // The observed bug class: greedy's FIRST token is a newline (all 26 empty predicts in the
        // 2026-07-03 session). The old rule returned "" here; the new rule keeps decoding.
        #expect(ClauseStop.firstClause("\n") == nil)
        #expect(ClauseStop.firstClause("\n\n") == nil)
        #expect(ClauseStop.firstClause("\r\n") == nil)
    }

    @Test func leadingPunctuationIsNotABoundary() {
        // The bare-"." refill (4 bare-dots in the follow-up log): the model wants to close the
        // clause before starting the next one. Not a stop until content followed.
        #expect(ClauseStop.firstClause(".") == nil)
        #expect(ClauseStop.firstClause(". ") == nil)
        #expect(ClauseStop.firstClause("! ") == nil)
    }

    @Test func decodesThroughLeadingNewlineIntoNextClause() {
        // The rescued case: continuation crosses the boundary and ends at the NEXT clause's end.
        #expect(ClauseStop.firstClause("\nDann kommt der Winter.") == "\nDann kommt der Winter.")
        #expect(ClauseStop.firstClause("\r\n\r\nDer Satz endet hier.") == "\r\n\r\nDer Satz endet hier.")
    }

    @Test func decodesThroughLeadingPunctuationIntoNextClause() {
        #expect(ClauseStop.firstClause(". Es wird kalt.") == ". Es wird kalt.")
    }

    @Test func leadingBoundaryRunOfMixedTokensIsSkipped() {
        // Newlines + dashes + spaces before any content all belong to the continuation.
        #expect(ClauseStop.firstClause("\n\n— Hello world.") == "\n\n— Hello world.")
    }

    // MARK: The behaviour after content is unchanged

    @Test func stopsAtSentenceEndAfterContent() {
        #expect(ClauseStop.firstClause("Hello world. More text") == "Hello world.")
        #expect(ClauseStop.firstClause("Wirklich? Ja") == "Wirklich?")
        #expect(ClauseStop.firstClause("Stop! Now") == "Stop!")
    }

    @Test func stopsBeforeNewlineAfterContent() {
        // A newline after content ends the clause (the newline itself is excluded, as before).
        #expect(ClauseStop.firstClause("Hallo\nWelt") == "Hallo")
    }

    @Test func crlfIsANewlineBoundaryToo() {
        // Swift Characters are grapheme clusters: "\r\n" is ONE Character and `== "\n"` is false.
        // The rule uses `isNewline`, so a CRLF (or lone CR) still ends the clause — otherwise a
        // literal Return could ride a continuation into the ghost and a chat compose field
        // (the message-send hazard).
        #expect(ClauseStop.firstClause("Hallo\r\nWelt") == "Hallo")
        #expect(ClauseStop.firstClause("Hallo\rWelt") == "Hallo")
    }

    @Test func punctuationAtEndOfStringIsABoundary() {
        // Mid-decode the text often ends exactly on the just-decoded "." — that counts (k+1 >= end).
        #expect(ClauseStop.firstClause("Der Satz endet.") == "Der Satz endet.")
    }

    @Test func decimalNumbersAreNotCut() {
        // The decimal guard: "." inside 3.500 is followed by a digit, not whitespace.
        #expect(ClauseStop.firstClause("Preis ist 3.500") == nil)
        #expect(ClauseStop.firstClause("Preis ist 3.500. Danach") == "Preis ist 3.500.")
    }

    @Test func abbreviationsStopAtTheirSpacedPeriod() {
        // Unchanged from the old rule: "z.B." — the first "." is followed by "B" (no stop), the
        // second by a space (stop). Documents the known behaviour rather than changing it.
        #expect(ClauseStop.firstClause("z.B. so") == "z.B.")
    }

    @Test func asciiEllipsisRunStopsAtItsLastDot() {
        // "..." after content: dots followed by dots don't stop; the run's LAST dot (followed by
        // space/end) does. Pins the k+1 lookahead against a refactor that cuts mid-ellipsis.
        #expect(ClauseStop.firstClause("Warte... und dann") == "Warte...")
        #expect(ClauseStop.firstClause("Na gut...") == "Na gut...")
    }

    @Test func periodBeforeClosingQuoteIsNotABoundary() {
        // Known scoping (deliberate): '."' has a non-whitespace follower, so quoted
        // dialogue runs on to the next real boundary (the engine caps bound the overrun). A future
        // quote-aware rule is a conscious change, not drift — this test documents today.
        #expect(ClauseStop.firstClause("Er rief: \"Halt.\" Dann ging er. Mehr")
                == "Er rief: \"Halt.\" Dann ging er.")
    }

    // MARK: No boundary yet / nothing at all

    @Test func noBoundaryYieldsNil() {
        // nil = "keep decoding" (or, post-decode, "use the raw text"): mid-clause continuations.
        #expect(ClauseStop.firstClause("Hello there") == nil)
        #expect(ClauseStop.firstClause(" und dann") == nil)
    }

    @Test func emptyYieldsNil() {
        // The genuine-nothing case (EOS as first token): the engine renders nothing, once.
        #expect(ClauseStop.firstClause("") == nil)
    }

    @Test func boundaryOnlySoupYieldsNil() {
        // A degenerate all-boundary decode never "ends a clause" — the caps + value gate handle it.
        #expect(ClauseStop.firstClause("...\n\n??") == nil)
    }

    // MARK: Content definition is shared with the value gate

    @Test func numbersCountAsContent() {
        // isWordCharacter = letter OR number (the SuggestionValueGate definition): a digit arms
        // the boundary just like a letter.
        #expect(ClauseStop.firstClause("42. Und weiter") == "42.")
        #expect(ClauseStop.firstClause("\n42 Prozent. Mehr") == "\n42 Prozent.")
    }

    @Test func nonAsciiLettersCountAsContent() {
        // DE is the primary runtime-verified language: umlauts/ß MUST arm seenContent (a narrowing
        // of isWordCharacter to ASCII would silently un-fix the leading-boundary rule for German — every decode
        // would run to the raw caps). One CJK case guards the property broadly.
        #expect(ClauseStop.firstClause("Schön. Mehr") == "Schön.")
        #expect(ClauseStop.firstClause("heißt\nJa") == "heißt")
        #expect(ClauseStop.firstClause("你好. x") == "你好.")
    }

    // MARK: trimToWords — the §2 flatten (load-bearing: never a Return in a ghost)

    @Test func trimFlattensNewlinesToSingleSpaces() {
        #expect(ClauseStop.trimToWords("\nDann kommt der Winter.", max: 8) == " Dann kommt der Winter.")
        #expect(ClauseStop.trimToWords("a\nb", max: 8) == "a b")
        #expect(ClauseStop.trimToWords("a\r\nb", max: 8) == "a b")   // the CRLF grapheme too
    }

    @Test func trimOutputNeverContainsANewline() {
        // THE §2 invariant: whatever the decode produced, the shipped ghost has no newline-class
        // grapheme — Tab can never type a Return (chat compose fields send on Return).
        for raw in ["\r\n\r\nDer Satz.", "a\nb\r\nc\rd", "\u{2028}line\u{2029}sep"] {
            let trimmed = ClauseStop.trimToWords(raw, max: 8)
            #expect(!trimmed.contains(where: { $0.isNewline }), "newline leaked for: \(raw)")
        }
    }

    @Test func trimCapsWordsAndKeepsLeadingSpaceMarker() {
        #expect(ClauseStop.trimToWords(" one two three", max: 2) == " one two")
        #expect(ClauseStop.trimToWords("one two three", max: 2) == "one two")
        #expect(ClauseStop.trimToWords("", max: 8) == "")
        #expect(ClauseStop.trimToWords("   ", max: 8) == "")
    }
}
