/// The hard bar on **verbatim recombination** — the ghost reproducing a passage from further up the
/// same document, often re-attributed. Sibling to `RunningThoughtGate`, applied
/// immediately after it and likewise **outside** the `SuggestionValueGate` chokepoint.
///
/// The field defect: `" Sie war sehr froh darüber, dass sie jetzt Zugang zu so einer Marke haben"` —
/// near-word-for-word the *Maja* paragraph higher up in the note, under a different participant's
/// name. Not confabulation: the source really is in the prompt, and the result reads as a
/// **quotation**. Ticket-02 measured 51 % (heterogeneous) and 92 % (repetitive) of accepted words to
/// be verbatim ≥5-gram copies, longest single run **57 words** — the dominant operating mode of the
/// build on a long document, not an outlier. A decoding lever lowers a probability; it cannot promise
/// "never", so this is enforcement.
///
/// **Reference text = the whole of `TypingContext.textBeforeCaret`, uncapped.** Not the prompt front
/// (a guard against the front catches 0 of 114 copied words — the attractor is the prefix, 100 % of
/// measured sources lie in it, 64 % within the last 600 characters) and not `textAfterCaret` (that is
/// the mid-text case, i.e. FIM, left untouched here for the same reason the running-thought gate leaves it untouched).
/// No look-back window: a bounded one would be an arbitrary number that lets through precisely the
/// case that broke the bar — an identically shaped paragraph further up.
///
/// **No state.** The unit of judgement is the accepted *chain*, not the single ≤5-word ghost (every
/// ghost is a fragment of the copy and unremarkable alone) — but every accepted word re-enters
/// `textBeforeCaret` through the host echo, so `tail(textBeforeCaret) ⧺ buffer` **is** the chain at
/// the next predict. One consequence is accepted deliberately: the threshold is reached
/// **cumulatively**, and a trim can only cut the buffer, never un-accept — so the maximum leak is
/// exactly `thresholdTokens − 1 = 7` words.
public enum LongRangeCopyGuard {

    /// The run length at which a match is refused, in word-normalised tokens.
    ///
    /// The calibration is coarse, not fine — the measured defects are 48 and 57 words, so any
    /// sensible threshold separates cleanly. 8 is the only value in the band with a **structural**
    /// meaning rather than a chosen one: it is `ContinuationBuffer.maxWords`, the longest run a
    /// single decode can produce. N = 8 therefore reads as *no single ghost may be wholly a copy,
    /// and no chain may accumulate more than 7 copied words.*
    ///
    /// The equality with the buffer cap is the **reason** for the value, not a definition — the two
    /// stay separate numbers so a re-calibration of the bar is not a change to the decode, and vice
    /// versa. But while `ContinuationBuffer.maxWords <= thresholdTokens`, a match that starts inside
    /// the buffer can never reach the bar (it is bounded by the words left in the buffer), so only
    /// the seam-spanning shape is refused and the head-keeping trim below cannot fire. That is
    /// derived from both constants in `LongRangeCopyGuardTests`, so raising the cap — or lowering
    /// the bar — fails a test instead of silently waking a branch nothing covers at runtime
    /// .
    public static let thresholdTokens = 8

    /// A safety bound on how far a single match is followed in either direction. It bounds **work**,
    /// not detection: a run is refused at 8, and this only caps the length reported in the log. A
    /// document whose every paragraph is identical would otherwise let one occurrence be chased for
    /// its whole length, times every occurrence.
    static let maxExtension = 512

    /// What the guard decided about one candidate continuation.
    public struct Verdict: Equatable, Sendable {
        /// The continuation to use: unchanged, cut before the copied run, or `""` when nothing
        /// survives (`SuggestionValueGate` already answers there).
        public var text: String
        /// Length of the refused run in tokens, or `nil` when nothing was trimmed. Logged as
        /// `[gate]: copy-guard trimmed run=<n>`.
        public var trimmedRun: Int?

        public init(text: String, trimmedRun: Int? = nil) {
            self.text = text
            self.trimmedRun = trimmedRun
        }
    }

    /// Refuse a continuation whose word-normalised token run over *accepted chain ⧺ buffer* matches a
    /// contiguous run anywhere in the document prefix at `thresholdTokens` or more, cutting the
    /// buffer **before** the start of the matched run and keeping the head — the head before the copy
    /// is genuine, un-copied continuation, and discarding it punishes without gain.
    ///
    /// Where the run starts inside the already-accepted tail, every word of the buffer belongs to it
    /// and the trim degenerates to full suppression. Near-total silence on a repetitive document is
    /// **accepted behaviour, not counter-evidence** — v1 is an accelerator, not a co-author, and an
    /// accelerator with nothing to offer says nothing.
    ///
    /// **At the shipping constants that degenerate case is the only one**, so the guard is binary in
    /// practice: a seam-spanning run suppresses the whole continuation, or nothing happens. A match
    /// anchored inside the buffer cannot extend backwards over the seam, so its length is bounded by
    /// the words left in the buffer — below `thresholdTokens` while `ContinuationBuffer.maxWords`
    /// does not exceed it. The head-keeping branch is kept rather than deleted because it becomes
    /// correct the moment the buffer grows, and it is exercised by tests that pass a longer buffer
    /// directly.
    public static func apply(to continuation: String, textBeforeCaret: String) -> Verdict {
        let buffer = tokenize(continuation)
        guard !buffer.isEmpty else { return Verdict(text: continuation) }

        let reference = referenceTokens(textBeforeCaret)
        guard reference.count >= thresholdTokens else { return Verdict(text: continuation) }

        // Index only the tokens the buffer could start a match with — at most `bufferMaxWords` of
        // them, against a reference that may be tens of thousands of tokens long. The whole
        // comparison runs synchronously between the decode landing and the ghost painting, so its
        // cost is first-paint latency.
        let wanted = Set(buffer.map(\.normalized))
        var positions: [String: [Int]] = [:]
        for (index, token) in reference.enumerated() where wanted.contains(token) {
            positions[token, default: []].append(index)
        }

        // The chain is `reference ⧺ buffer`, so a run that reaches the buffer either **spans the
        // seam** — in which case it necessarily contains the buffer's first token, and every buffer
        // word belongs to it — or starts inside the buffer. Anchoring on those two shapes is what
        // makes the accepted tail free: it is followed backwards from the seam rather than scanned as
        // candidate starts, so the *forward* loop cannot match the tail against itself (that
        // self-alignment would need an occurrence at `reference.count`, which is not an index), and
        // the reported run is the run's real length rather than one clipped to a look-back window.
        //
        // The **backward** walk carries no such guarantee, and deliberately so:
        // it compares the tail against a region that may overlap it, so a phrase repeating itself
        // near the caret self-matches and is refused. That is not a false positive — two occurrences
        // a distance d apart mean the region is periodic with period d, and an overlapping occurrence
        // is still an occurrence, so the refused chain does contain a genuine ≥ `thresholdTokens`
        // run. The shape it catches is defect class D (a degenerating tail), which the sibling bar
        // wants refused anyway. Consequence on the record: `[gate]: copy-guard trimmed run=` mixes
        // two populations — a long-range copy from further up, and a periodic tail at the caret — so
        // the next calibration of N from that rate must know it is a blend.
        for start in buffer.indices {
            var longest = 0
            for origin in positions[buffer[start].normalized] ?? [] {
                var forward = 0
                while forward < maxExtension,
                      origin + forward < reference.count,
                      start + forward < buffer.count,
                      reference[origin + forward] == buffer[start + forward].normalized {
                    forward += 1
                }
                guard forward > 0 else { continue }
                // Only the seam-spanning shape reaches back into the already-accepted text.
                var backward = 0
                if start == 0 {
                    while backward < maxExtension,
                          origin - backward > 0,
                          reference.count - backward > 0,
                          reference[origin - backward - 1] == reference[reference.count - backward - 1] {
                        backward += 1
                    }
                }
                longest = max(longest, forward + backward)
            }
            guard longest >= thresholdTokens else { continue }
            guard start > 0 else { return Verdict(text: "", trimmedRun: longest) }
            let head = String(continuation[..<buffer[start].start])
            // A head left with a trailing gap would keep a whitespace-only remainder alive in the
            // acceptance buffer after the last word is peeled.
            return Verdict(text: trimmingTrailingWhitespace(head), trimmedRun: longest)
        }
        return Verdict(text: continuation)
    }

    // MARK: Normalisation

    /// One word-normalised token and where it starts in the original string (so the cut can be made
    /// on the real text, not the normalised one).
    struct Token {
        var normalized: String
        var start: String.Index
    }

    /// Lowercased, punctuation stripped, whitespace collapsed — exactly the
    /// [Zählweise] the defect was measured with,
    /// or the gate would enforce something other than the bar it was measured against. The field
    /// defect was *near*-word-for-word, so a literal comparison would be walked past by one changed
    /// comma or a sentence-initial capital.
    ///
    /// Deliberately **no stemming** (German inflection stands) and **no stop-word list**: every token
    /// counts the same. A stop-word list is a second, unevidenced decision with its own maintenance
    /// cost, and an eight-token run of function words alone does not occur in prose.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            var normalized = ""
            while index < text.endIndex, !text[index].isWhitespace {
                let c = text[index]
                if c.isWordCharacter { normalized.append(contentsOf: c.lowercased()) }
                index = text.index(after: index)
            }
            // A punctuation-only run ("—", "…") normalises away and is not a token on either side.
            if !normalized.isEmpty { tokens.append(Token(normalized: normalized, start: start)) }
        }
        return tokens
    }

    /// The reference side needs no character offsets — only the candidate is ever cut — so it skips
    /// `tokenize`'s per-character index stepping, which is what dominates the cost on a long document.
    static func referenceTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            var normalized = ""
            normalized.reserveCapacity(word.count)
            for c in word where c.isWordCharacter { normalized.append(contentsOf: c.lowercased()) }
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func trimmingTrailingWhitespace(_ s: String) -> String {
        var out = s
        while let last = out.last, last.isWhitespace { out.removeLast() }
        return out
    }
}
