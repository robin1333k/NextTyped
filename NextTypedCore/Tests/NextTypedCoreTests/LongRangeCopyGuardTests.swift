import Testing
@testable import NextTypedCore

/// The hard bar on verbatim recombination: an n-gram overlap against the document prefix.
@Suite struct LongRangeCopyGuardTests {

    /// A paragraph further up the note — the copy source in every case below.
    private let source = "Maja war sehr froh darüber dass sie jetzt Zugang zu so einer Marke hat. "

    // MARK: The threshold, at its boundary

    @Test func sevenTokensPass() {
        let prefix = source + "Lena sagte,"
        let seven = " war sehr froh darüber dass sie jetzt"          // 7 tokens
        #expect(LongRangeCopyGuard.apply(to: seven, textBeforeCaret: prefix).trimmedRun == nil)
    }

    @Test func eightTokensTrim() {
        let prefix = source + "Lena sagte,"
        let eight = " war sehr froh darüber dass sie jetzt Zugang"   // 8 tokens
        let verdict = LongRangeCopyGuard.apply(to: eight, textBeforeCaret: prefix)
        #expect(verdict.trimmedRun == 8)
        #expect(verdict.text == "")   // the run starts at the buffer's first token → nothing survives
    }

    // MARK: Cutting at the match, keeping a genuine head

    /// Exercises the head-keeping branch directly, with a buffer **longer than
    /// `ContinuationBuffer.maxWords`** — the condition under which it can fire at all (see
    /// `theHeadKeepingTrimCannotFireWhileTheBufferCapDoesNotExceedTheBar`). The guard takes a plain
    /// string, so a test can hand it one; the engine cannot.
    @Test func theHeadBeforeTheCopyIsKept() {
        let prefix = source + "Lena berichtete etwas anderes:"
        let candidate = " sie zögerte und war sehr froh darüber dass sie jetzt Zugang"
        let verdict = LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix)
        #expect(verdict.trimmedRun == 8)
        #expect(verdict.text == " sie zögerte und")   // cut before "war", no trailing gap left
    }

    /// **The coupling that keeps the branch above unreachable in the running product**
    /// . A match anchored at buffer index ≥ 1 never extends backwards over the
    /// seam, so its length is bounded by the words left in the buffer — at most `maxWords - 1`. While
    /// that is below the bar, only the seam-spanning shape is ever refused and the guard is binary.
    ///
    /// Derived from **both** constants, never from the arithmetic written out: raising the decode cap
    /// or lowering the threshold fails here rather than silently waking a branch no runtime path
    /// covers. When it does fail, that is not a bug — it is the moment the head-keeping trim becomes
    /// live and needs a scenario, plus a correction to this test.
    @Test func theHeadKeepingTrimCannotFireWhileTheBufferCapDoesNotExceedTheBar() {
        #expect(ContinuationBuffer.maxWords - 1 < LongRangeCopyGuard.thresholdTokens)

        // The longest mid-buffer match there is: every buffer word but the first, contiguous in the
        // prefix, in a buffer filled exactly to the decode cap.
        let words = (1...ContinuationBuffer.maxWords).map { "wort\($0)" }
        let candidate = " " + words.joined(separator: " ")
        let prefix = "ein satz weiter oben lautete " + words.dropFirst().joined(separator: " ")
            + " und dann ging es weiter"
        let verdict = LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix)
        #expect(verdict.trimmedRun == nil)
        #expect(verdict.text == candidate)   // no head kept, because nothing was cut
    }

    /// Case D, pinned so a later tidy-up cannot silently remove it: a tail that
    /// repeats itself near the caret **is** refused, even though the only available match overlaps the
    /// region it is compared against and the document holds no earlier source. Overlapping occurrences
    /// are in the guard's definition of a copy — periodicity means the run genuinely occurs twice.
    @Test func aSelfRepeatingTailIsRefusedEvenWithNoEarlierSource() {
        let prefix = "Er sagte ja ja ja ja ja ja ja ja"
        let verdict = LongRangeCopyGuard.apply(to: " ja ja", textBeforeCaret: prefix)
        #expect((verdict.trimmedRun ?? 0) >= LongRangeCopyGuard.thresholdTokens)
        #expect(verdict.text == "")
    }

    @Test func aGhostWithNoLongRunIsByteIdentical() {
        let prefix = source + "Lena sagte, dass sie"
        let candidate = " die Marke schon vorher kannte und sie deshalb"
        let verdict = LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix)
        #expect(verdict.trimmedRun == nil)
        #expect(verdict.text == candidate)
    }

    /// The prefix ends with the candidate's own reference text — the tail must not match itself.
    @Test func theAcceptedTailDoesNotMatchItself() {
        let prefix = "Die heuristische Evaluation der Website wurde im Mai 2026 mit acht Personen"
        let candidate = " durchgeführt"
        let verdict = LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix)
        #expect(verdict.trimmedRun == nil)
        #expect(verdict.text == candidate)
    }

    @Test func aShortPrefixCannotProduceAMatch() {
        #expect(LongRangeCopyGuard.apply(to: " world", textBeforeCaret: "hello").trimmedRun == nil)
        #expect(LongRangeCopyGuard.apply(to: "", textBeforeCaret: "hello there world").text == "")
    }

    // MARK: The cumulative case — the chain, judged through the prefix

    /// Buffer 1 carries only 5 tokens of the run and passes; the accepted words re-enter
    /// `textBeforeCaret` through the host echo, and buffer 2 is caught because the TAIL now carries
    /// the rest. The trim can only cut the buffer, never un-accept — hence the deliberate 7-word leak.
    @Test func theThresholdIsReachedCumulativelyThroughTheTail() {
        let first = " war sehr froh darüber dass"                    // 5 tokens
        #expect(LongRangeCopyGuard.apply(to: first, textBeforeCaret: source + "Lena").trimmedRun == nil)

        // …accepted, so the prefix now ends with them.
        let grown = source + "Lena" + first
        let second = " sie jetzt Zugang"
        let verdict = LongRangeCopyGuard.apply(to: second, textBeforeCaret: grown)
        #expect(verdict.trimmedRun != nil)
        #expect(verdict.trimmedRun! >= LongRangeCopyGuard.thresholdTokens)
        #expect(verdict.text == "")   // the run starts inside the accepted tail → whole buffer refused
    }

    /// The run length is load-bearing: it is what separates an 8-word trim from a 60-word trim when
    /// N's calibration is judged as a rate, so the tail must contribute its real length.
    @Test func theReportedRunSpansTheAcceptedTail() {
        let long = "eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf"
        let prefix = long + ". Danach: " + long
        let verdict = LongRangeCopyGuard.apply(to: " dreizehn", textBeforeCaret: prefix + " dreizehn " + long)
        // The second copy of `long` plus the just-typed continuation matches the first — well past 8.
        #expect((verdict.trimmedRun ?? 0) > LongRangeCopyGuard.thresholdTokens)
    }

    // MARK: Normalisation — the measurement's Zählweise

    @Test func aChangedCommaStillMatches() {
        let prefix = "Sie war sehr froh darüber, dass sie jetzt Zugang hat. Und Lena"
        let candidate = " war sehr froh darüber dass sie jetzt Zugang"
        #expect(LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix).trimmedRun == 8)
    }

    @Test func aSentenceInitialCapitalStillMatches() {
        let prefix = "sie war sehr froh darüber dass sie jetzt zugang hat. Und Lena sagte:"
        let candidate = " Sie war sehr froh darüber dass sie jetzt Zugang"
        #expect(LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix).trimmedRun ?? 0 >= 8)
    }

    @Test func punctuationOnlyRunsAreNotTokensOnEitherSide() {
        #expect(LongRangeCopyGuard.tokenize("Er sagte — laut!").map(\.normalized) == ["er", "sagte", "laut"])
        #expect(LongRangeCopyGuard.tokenize("z.B. 3.500").map(\.normalized) == ["zb", "3500"])
    }

    @Test func noStemming() {
        // German inflection stands: "Marken" is not "Marke", so this is 7 matching tokens, not 8.
        let prefix = source + "Lena sagte,"
        let candidate = " war sehr froh darüber dass sie jetzt Marken"
        #expect(LongRangeCopyGuard.apply(to: candidate, textBeforeCaret: prefix).trimmedRun == nil)
    }
}
