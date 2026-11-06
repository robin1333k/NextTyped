/// The clause-stop rule for the greedy decode: where does a
/// generated continuation end — plus the two shaping guards that make its output safe to render.
///
/// The original rule stopped at the *first* clause boundary — but at a clause boundary the model's most
/// likely next token IS the boundary token, so that rule degenerated to "stop immediately":
/// 26/155 predicts in the 2026-07-03 runtime-verify session returned `""` (`steps=1`, all
/// newline-first), so no ghost ever followed a finished sentence and `Tab`-accept chains stalled
/// silently at buffer-exhaustion refills.
///
/// The rule therefore counts a boundary only **after at least one word character**: leading
/// boundary tokens (newlines, sentence punctuation) belong to the continuation, and the decode
/// runs into the next clause and stops at *its* end. "Word character" is the same content
/// definition the `SuggestionValueGate` uses (`Character.isWordCharacter` = letter/number), so the
/// system has exactly one answer to "is there content?". Offline eval-gated before wiring
/// (the offline probe, 2026-07-04): boundary-cut hit-rate 8→38 % EN / 0→15 % DE with the
/// empty-rate 69→0 %, and byte-identical output on all 108 mid-clause cuts.
///
/// The §3 render guard that used to live here (`isSuppressedBoundaryLead`) is gone: a
/// boundary-punctuation lead at a whitespace caret is no longer suppressed but **joined**, by
/// `BoundaryLeadJoin` in the reducer.
///
/// The decimal guard is unchanged from the original rule: `.`/`!`/`?` only ends the clause when followed by
/// whitespace or end-of-string, so `3.500` is never cut. Known scoping (deliberate, pinned by
/// tests): a sentence-final period *before a closing quote* (`…"Halt." Dann`) is not a boundary
/// (followed by a non-whitespace char), and `…`/`,`/`;` are neither content nor boundary — such
/// clauses run on to the next real boundary or the engine's safety caps.
public enum ClauseStop {
    /// The first complete clause, **including any leading boundary tokens**: text up to and
    /// including the first sentence-ending punctuation that follows a word character and is
    /// followed by whitespace/end-of-string, or up to (excluding) the first newline-class grapheme
    /// (`Character.isNewline`: LF, CR, **CRLF**, VT, FF, NEL, LS, PS — a bare `"\n"` compare would
    /// let a CRLF through and a literal Return could reach the ghost) that follows a word
    /// character. `nil` while no such boundary has appeared — used both to stop the decode early
    /// and to cut the final output.
    public static func firstClause(_ s: String) -> String? {
        var seenContent = false
        let chars = Array(s)
        for k in chars.indices {
            let c = chars[k]
            if c.isWordCharacter {
                seenContent = true
                continue
            }
            guard seenContent else { continue }   // leading boundary run: decode on
            if c.isNewline { return String(chars[..<k]) }
            if c == "." || c == "!" || c == "?" {
                if k + 1 >= chars.count || chars[k + 1].isWhitespace {
                    return String(chars[...k])
                }
            }
        }
        return nil
    }

    /// Keep at most `max` whitespace-delimited words, preserving a leading space if the input led
    /// with whitespace (the ghost is drawn immediately after the caret). Splitting on space **and
    /// every newline-class grapheme** is the flatten step and it is load-bearing: the output
    /// NEVER contains a newline, so `Tab` can never insert a synthetic Return (chat compose fields
    /// send on Return). Lifted from the engine when the flatten became a design invariant.
    public static func trimToWords(_ s: String, max: Int) -> String {
        let leading = s.first?.isWhitespace == true ? " " : ""
        let words = s.split(whereSeparator: { $0 == " " || $0.isNewline }).prefix(max)
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? "" : leading + joined
    }
}
