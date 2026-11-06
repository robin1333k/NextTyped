/// Where a **mid-text bridge** ends — the FIM sibling of `ClauseStop` (build item 7).
///
/// Forward continuation stops at a clause boundary because nothing follows the caret. A bridge has a
/// hard right-hand wall: the suffix `S` is *already in the document*, so the failure mode is not a
/// run-on clause but **duplication** — the model decodes past the join and re-emits `S`. That is the
/// dominant defect in the Ticket-06 feasibility probe: prefix `"The quick brown fox "`, suffix
/// `" over the lazy dog."`, middle `" jumps over the lazy dog."` reassembles as
/// `"…fox jumps over the lazy dog. over the lazy dog."` — fluent read in isolation, broken read
/// against the suffix. Four rules, in the order the decode meets them:
///
///   a. **Sentinel stop** (``stopTokens(fimPad:endOfText:fimPrefix:fimSuffix:fimMiddle:)``) —
///      token-level, applied by the engine per decoded id.
///   b. **``check(middle:suffix:)``** — the duplication guard, checked per decoded token.
///   c. **`SuggestionValueGate`** — no contentless bridge is shown or Tab-inserted.
///   d. **`ClauseStop.trimToWords`** — the newline→space flatten, so a bridge can never
///      insert a Return, plus the ≤5-word display cap.
///
/// (c) and (d) are reused verbatim rather than re-implemented: "is there content?" and "never a
/// Return" each have exactly one answer in this system.
public enum FIMStop {
    /// Minimum length of a middle-tail/suffix-head overlap before it counts as duplication.
    ///
    /// With (b) below it is the false-positive floor: a bridge legitimately shares short function
    /// words with the text it runs into. 8 characters ∧ 2 whitespace-delimited tokens is the starting
    /// default, pinned by the Ticket-06 fixtures and a shared-function-word negative; the eval
    /// (the offline probe) is where it gets re-tuned against real middles.
    public static let minimumOverlapCharacters = 8

    /// Minimum number of whitespace-delimited `S`-tokens an overlap must span. See
    /// ``minimumOverlapCharacters`` — one shared leading word is coincidence, two is duplication.
    public static let minimumOverlapTokens = 2

    /// (a) The decode-halting token set for a FIM generation.
    ///
    /// **`fimMiddle` is deliberately excluded** — it *opens* the middle, so halting on it would end
    /// every generation at step 0. A re-emitted `fimPrefix`/`fimSuffix` inside the middle, by
    /// contrast, means the model has started a fresh FIM block and should be cut.
    ///
    /// Every id is optional because the engine resolves them from the FIM model's own vocabulary
    /// rather than hard-coding the base model's (item 5): an absent sentinel must simply be missing
    /// from the set, never a bogus id.
    public static func stopTokens(
        fimPad: Int?, endOfText: Int?, fimPrefix: Int?, fimSuffix: Int?, fimMiddle: Int?
    ) -> Set<Int> {
        // `fimMiddle` is a parameter on purpose: it names the one sentinel that must NOT be a stop, so
        // the exclusion is visible at every call site instead of being an omission someone "fixes".
        Set([fimPad, endOfText, fimPrefix, fimSuffix].compactMap { $0 })
    }

    /// The verdict of the duplication guard.
    public enum Decision: Equatable, Sendable {
        /// No qualifying overlap — the bridge has not reached `S` yet.
        case keepDecoding
        /// The middle has run into `S`: stop, and use this middle with the duplicated run removed.
        case stop(middle: String)
    }

    /// (b) `stopAtStartOf(S)` — fire when the decoded middle **ends with** a prefix of `S`.
    ///
    /// A character-level match, not a token one: the tokenizer's boundaries are an implementation
    /// detail of the model, while the duplication the user sees is textual. Only checked once the
    /// middle carries at least one word character (the `ClauseStop` guard order — a leading
    /// whitespace run is not yet a bridge). The **longest** qualifying overlap wins, so the whole
    /// duplicated run is trimmed rather than a fragment of it.
    ///
    /// Cost: `O(|middle|²)` worst case and `O(|middle|)` in the common no-overlap case — the *suffix
    /// never enters the bound*, because only its leading `|middle|` characters can participate and only
    /// those are materialised. The middle is ghost-sized (a few words) while `S` is a paragraph, so a
    /// per-token call stays far below the first-paint budget despite the quadratic shape.
    ///
    /// During generation the engine calls this per decoded token on the raw middle; ``finalize`` calls
    /// it once on the flattened middle, which also catches a duplication that only becomes adjacent
    /// after the newline→space flatten.
    public static func check(middle: String, suffix: String) -> Decision {
        guard middle.contains(where: { $0.isWordCharacter }) else { return .keepDecoding }
        let middleChars = Array(middle)
        // Only the first `middleChars.count` characters of `S` can ever participate: the longest
        // possible overlap is bounded by the middle. Taking that prefix — rather than materialising all
        // of `S` — is what makes the bound below honest, and it matters: this runs per decoded token on
        // the first-paint path, and in a newline-free compose box `S` is the entire rest of the field.
        let suffixChars = Array(suffix.prefix(middleChars.count))
        var length = min(middleChars.count, suffixChars.count)
        while length >= minimumOverlapCharacters {
            defer { length -= 1 }
            guard middleChars.suffix(length).elementsEqual(suffixChars.prefix(length)) else { continue }
            let run = middleChars.suffix(length)
            guard run.split(whereSeparator: { $0.isWhitespace }).count >= minimumOverlapTokens else {
                continue
            }
            return .stop(middle: String(middleChars.dropLast(length)))
        }
        return .keepDecoding
    }

    /// Shape a finished raw middle into the string the ghost may show: (d) flatten, (b) de-duplicate,
    /// (d) word-cap, (c) value-gate. `nil` means "show nothing".
    ///
    /// **The order of those three is load-bearing.** The flatten must run *before* the duplication check,
    /// because a middle whose duplicated run is broken by decoded newlines (`" jumps over the lazy
    /// dog.\n"` — the Ticket-06 fixture) does not match `S` until the newlines become spaces. The word
    /// cap must run *after* it: capping first can truncate a duplicated run that starts near the cap down
    /// below the 8-char/2-token floor, so the check misses it and the ghost duplicates `S` anyway.
    /// `trimToWords` does both jobs, so it is called twice — once uncapped to flatten, once to cap.
    public static func finalize(middle: String, suffix: String, maxWords: Int) -> String? {
        let flattened = ClauseStop.trimToWords(middle, max: .max)
        let deduplicated: String
        switch check(middle: flattened, suffix: suffix) {
        case .stop(let trimmed):  deduplicated = trimmed
        case .keepDecoding:       deduplicated = flattened
        }
        let capped = ClauseStop.trimToWords(deduplicated, max: maxWords)
        guard SuggestionValueGate.isRenderable(capped) else { return nil }
        return capped
    }
}
