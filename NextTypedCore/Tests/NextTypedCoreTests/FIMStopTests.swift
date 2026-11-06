import Testing
@testable import NextTypedCore

@Suite struct FIMStopTests {
    // MARK: (a) Sentinel / EOT stop tokens

    @Test func fimMiddleIsNOTAStopToken() {
        // The load-bearing exclusion (build item 7a): `<|fim_middle|>` OPENS the middle — stopping on
        // it would end every generation at step 0.
        let stops = FIMStop.stopTokens(fimPad: 1, endOfText: 2, fimPrefix: 3, fimSuffix: 4, fimMiddle: 5)
        #expect(!stops.contains(5))
    }

    @Test func padEotAndTheOtherSentinelsAreStopTokens() {
        // A re-emitted `<|fim_prefix|>`/`<|fim_suffix|>` inside the middle means the model went
        // off-rails into a fresh FIM block — halt rather than decode a second prompt.
        let stops = FIMStop.stopTokens(fimPad: 1, endOfText: 2, fimPrefix: 3, fimSuffix: 4, fimMiddle: 5)
        #expect(stops == [1, 2, 3, 4])
    }

    @Test func unresolvedSentinelIDsAreSimplyAbsent() {
        // Ids are resolved from the 1.7B's own vocab (never hard-coded — build item 5); a tokenizer
        // that lacks one must not inject a bogus id into the stop set.
        #expect(FIMStop.stopTokens(fimPad: nil, endOfText: 7, fimPrefix: nil, fimSuffix: nil,
                                   fimMiddle: nil) == [7])
    }

    // MARK: (b) stopAtStartOf(S) — the suffix-duplication guard

    @Test func stopsAndTrimsWhenTheMiddleRunsIntoTheSuffix() {
        // The canonical Ticket-06 failure: prefix "The quick brown fox ", suffix " over the lazy dog.",
        // middle "\n jumps over the lazy dog.\n" — the middle re-emits the suffix, so the reassembly
        // reads "…fox jumps over the lazy dog. over the lazy dog."
        let decision = FIMStop.check(middle: " jumps over the lazy dog.", suffix: " over the lazy dog.")
        #expect(decision == .stop(middle: " jumps"))
    }

    @Test func stopsMidRunAsSoonAsTheOverlapQualifies() {
        // Checked after each decoded token: the guard fires the moment the tail matches, before the
        // whole suffix is re-emitted.
        #expect(FIMStop.check(middle: " jumps over the", suffix: " over the lazy dog.")
                == .stop(middle: " jumps"))
    }

    @Test func aSharedSingleFunctionWordDoesNotFire() {
        // The false-positive the 2-token floor exists for: a middle ending in " the" while S also
        // starts " the..." is an ordinary bridge, not a duplication.
        #expect(FIMStop.check(middle: "sprang über the", suffix: " the lazy dog.") == .keepDecoding)
    }

    @Test func aShortOverlapBelowTheCharacterFloorDoesNotFire() {
        // "a b" spans 2 tokens but only 3 chars — far too weak a signal to cut a generation on.
        #expect(FIMStop.check(middle: "x a b", suffix: " a b c") == .keepDecoding)
    }

    @Test func noOverlapKeepsDecoding() {
        #expect(FIMStop.check(middle: " springt schnell", suffix: " über den Zaun.") == .keepDecoding)
    }

    @Test func aContentFreeMiddleNeverStops() {
        // Guard order mirrors ClauseStop: no word character yet ⇒ nothing to judge.
        #expect(FIMStop.check(middle: "\n", suffix: "\n over the lazy dog.") == .keepDecoding)
        #expect(FIMStop.check(middle: "   ", suffix: "   spans plenty of chars") == .keepDecoding)
    }

    @Test func anEmptySuffixNeverStops() {
        #expect(FIMStop.check(middle: " jumps over the lazy dog.", suffix: "") == .keepDecoding)
    }

    @Test func germanOverlapIsHandledLikeEnglish() {
        // Language-agnostic by construction (whitespace tokens + character compare) — umlauts included.
        #expect(FIMStop.check(middle: " springt über den Zaun.", suffix: " über den Zaun.")
                == .stop(middle: " springt"))
    }

    // MARK: (c) + (d) The finalize pipeline — value gate and the never-a-Return flatten

    @Test func finalizeTrimsTheDuplicatedRunAndFlattens() {
        #expect(FIMStop.finalize(middle: "\n jumps over the lazy dog.\n",
                                 suffix: " over the lazy dog.", maxWords: 5) == " jumps")
    }

    @Test func finalizeSuppressesTheDegenerateWhitespaceOnlyMiddle() {
        // The Ticket-06 DE case: middle "\n". `SuggestionValueGate` (≥1 word char) drops it, so no
        // contentless bridge is ever shown or Tab-inserted.
        #expect(FIMStop.finalize(middle: "\n", suffix: " über den Zaun.", maxWords: 5) == nil)
        #expect(FIMStop.finalize(middle: " .", suffix: " über den Zaun.", maxWords: 5) == nil)
    }

    @Test func finalizeNeverEmitsANewline() {
        // a suggestion must never insert a Return (chat compose fields SEND on Return).
        let result = FIMStop.finalize(middle: "\nzwei\nZeilen", suffix: " Ende.", maxWords: 5)
        #expect(result == " zwei Zeilen")
        #expect(!(result ?? "").contains { $0.isNewline })
    }

    @Test func finalizeAppliesTheDisplayWordCap() {
        #expect(FIMStop.finalize(middle: " one two three four five six", suffix: " END.", maxWords: 5)
                == " one two three four five")
    }

    @Test func finalizeDeduplicatesBEFOREApplyingTheWordCap() {
        // Regression: capping first truncates a duplicated run that starts near the cap down below the
        // 8-char floor, so `check` misses it and the ghost duplicates S. Here the cap would leave the
        // overlap as just " over" (5 chars) — the guard must see the full " over the lazy dog." first.
        #expect(FIMStop.finalize(middle: " a b c jumps over the lazy dog.",
                                 suffix: " over the lazy dog.", maxWords: 5) == " a b c jumps")
    }

    @Test func finalizeStillCapsAnUnduplicatedMiddleAtTheWindow() {
        // The cap is not weakened by running second — a long, non-duplicating middle is still windowed.
        #expect(FIMStop.finalize(middle: " one two three four five six seven", suffix: " ENDE.",
                                 maxWords: 5) == " one two three four five")
    }

    @Test func finalizeSuppressesAMiddleThatIsNothingButTheSuffix() {
        // Trimming the duplicated run can empty the middle — that must suppress, not render "".
        #expect(FIMStop.finalize(middle: " over the lazy dog.", suffix: " over the lazy dog.",
                                 maxWords: 5) == nil)
    }
}
