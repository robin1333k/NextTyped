import Foundation

/// **Token budgeting for the prompt front** (option 1).
///
/// The defect this exists to kill: ``PromptFront`` capped its four segments in **characters**, while
/// ``PrefixReuse/window(_:max:reanchorStep:)`` caps the prompt in **tokens** and drops from the *head* —
/// which is exactly where the front lives. So on a long focused document the front was evicted, and
/// evicted *progressively* as the prefix grew (measured: 136 → 8 of 392 tokens inside one typing burst;
/// 0/392 on all 17 predicts of a long note). No static check could see it, because neither layer is
/// wrong on its own: they simply measure in different units, and only one of them is the binding
/// constraint. The fix is therefore not a re-calibration of the char caps — **the front has to be
/// budgeted in the same unit as the window it competes for.**
///
/// What the measurement phase established, and what this arithmetic is built on top of (do not re-derive):
///
///  1. **The document head carries the quality gain.** With the front intact the model produced
///     document-specific German (named entities, chapter references) that the front-evicted arms did not.
///  2. **Prefix tokens beyond ~500 buy nothing.** 530 vs 973 prefix tokens were indistinguishable in
///     output quality while the larger cost +368 ms of prefill.
///  3. Therefore the fix is **free at constant prompt size**: spend worthless prefix tokens on the front
///     rather than growing the window. Raising `windowMax` (~1.9–2× first-paint on a long document) and
///     accepting the eviction were both refuted by measurement.
///
/// So: the front gets a **guaranteed share of `windowMax`** (default 30 %), allocated across the segments
/// by priority, and the prefix gets what is left. Total prompt size is unchanged.
///
/// ## The reserve is a floor, not a ceiling
///
/// The guarantee runs one way only: the front can no longer be *out-competed* by the prefix. It is not a
/// cap on the front. The prefix is served first but is itself capped at `windowMax − reserve` — that cap
/// is what makes the reserve a guarantee — and the front then takes everything the prefix did not want,
/// which on a short surface can be far more than the reserve. A chat compose box whose whole front used
/// to fit (`front=419/419tok` is on record) must keep fitting; clamping it to the reserve would be a
/// regression invented by the fix rather than required by it. Concretely:
///
///     frontAllowance  = min(frontWant, max(reserve, windowMax − prefixWant))
///     prefixAllowance = windowMax − frontGranted
///
/// Only when the prefix genuinely wants more than `windowMax − reserve` does the front fall back to
/// exactly its reserve — the long-document case this whole mechanism exists for.
///
/// ## Priority is a value order, not the positional order
///
/// Allocation runs highest-value-first: `focusedDoc` → `reply` → `clipboard` → `personalization` → `ocrAmbient`.
/// Only `focusedDoc` is measured. The `clipboard` rank is **unmeasured and provisional**: it sits above `personalization` and `ocrAmbient` on the argument that a fresh copy is
/// more specific to the moment, not on a number.
/// This **deliberately does not follow the positional order** of ``PromptFront``, where
/// personalization sits front-*most*. Position is a claim about *pull* (what a base model attends to
/// most sits nearest the continuation point); priority is a claim about *value under scarcity*, and the
/// only segment measured to move German quality is the focused document's head. The two orders answer
/// different questions and are allowed to disagree; a segment's rank here says nothing about where it
/// is placed in the prompt.
///
/// ## Drop whole, keep heads
///
/// A segment that would have to be **truncated** below ``minimumSegmentTokens`` is **dropped entirely**
/// rather than cut to a fragment (one that fits whole is admitted however short it is — a two-line
/// reply turn is a complete document): half a sentence is worse than nothing (a base model happily
/// continues it as content), and for personalization the units are whole exemplars. Where a segment
/// *is* shortened, the caller keeps its **head** — `focusedDoc`'s value is the document's beginning,
/// which is the part the measurement credits with the gain.
///
/// Pure integer arithmetic: the engine owns the tokenizer (it supplies the counts) and does the cutting.
public enum PromptFrontBudget {

    /// The five prompt-front sources. `RawValue`s double as greppable log tokens.
    public enum Segment: String, CaseIterable, Sendable, Hashable {
        case focusedDoc = "doc"
        case reply = "reply"
        case clipboard = "clip"
        case personalization = "style"
        case ocrAmbient = "ocr"
    }

    /// Allocation order, highest value first. See the type doc — this is the value order (only `focusedDoc` measured; `clipboard` provisional) and is
    /// intentionally different from the *positional* order the segments are emitted in.
    public static let priority: [Segment] = [.focusedDoc, .reply, .clipboard, .personalization, .ocrAmbient]

    /// Share of `windowMax` reserved for the whole front. 30 % ≈ 153 tokens at the shipping 512 — enough
    /// for the document head that carried the measured gain (the front was 314 tok when it produced it,
    /// so this is a real shrink, deliberately: finding 2 says the prefix can afford the tokens, finding 3
    /// says the front cannot afford to grow the window).
    public static let defaultReserveFraction = 0.30

    /// The reserve fraction is a tuning knob, not a free parameter: below ~5 % nothing survives the
    /// minimum-segment rule, and above ~60 % the prefix — the tokens that actually decide the next word —
    /// starts losing tokens the measurement never cleared it to lose.
    public static let reserveFractionRange: ClosedRange<Double> = 0.05 ... 0.60

    /// Below this a segment is dropped whole instead of truncated. ~32 tokens is roughly one German
    /// sentence; less than that is a fragment, and a fragment in front of a base model is a prompt to
    /// finish someone else's half-sentence (that is the failure mode with a whole
    /// exemplar — a fragment is strictly worse).
    public static let minimumSegmentTokens = 32

    /// Clamp a raw (e.g. `UserDefaults`-supplied) reserve fraction into ``reserveFractionRange``;
    /// a non-finite or non-positive value falls back to ``defaultReserveFraction``.
    public static func clampReserveFraction(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return defaultReserveFraction }
        return min(max(raw, reserveFractionRange.lowerBound), reserveFractionRange.upperBound)
    }

    /// What each segment asked for and what it got, plus what is left for the prefix.
    public struct Allocation: Equatable, Sendable {
        /// Granted token count per segment. A segment absent from the map (or mapped to `0`) is **not**
        /// emitted at all — including its separator.
        public let allowances: [Segment: Int]
        /// What each segment's text would have cost, as handed in.
        public let requested: [Segment: Int]
        /// The token reserve the front is *guaranteed* (`round(windowMax × fraction)`) — a floor, not a
        /// cap. See ``frontAllowance`` for what it was actually allowed to spend on this call.
        public let reserve: Int
        /// The ceiling actually applied to the front this call: the reserve when the prefix wants the
        /// rest of the window, more when the prefix is short enough to leave room. Never below
        /// ``reserve``, never above `windowMax`.
        public let frontAllowance: Int
        /// Tokens the granted front actually occupies, **including** one separator run per granted
        /// segment. `≤ frontAllowance` by construction.
        public let frontTokens: Int
        /// What the full front would have occupied, separators included — the "before" number.
        public let requestedTokens: Int
        /// Tokens left for the prefix window: `windowMax − frontTokens`. The caller must feed this to
        /// ``PrefixReuse/window(_:max:reanchorStep:)`` as the *max*, never as a plain `suffix(_:)` — see
        /// the note in ``allocate(windowMax:reserveFraction:segmentTokens:separatorTokens:minimumSegmentTokens:)``.
        public let prefixAllowance: Int

        public init(allowances: [Segment: Int], requested: [Segment: Int], reserve: Int,
                    frontAllowance: Int, frontTokens: Int, requestedTokens: Int,
                    prefixAllowance: Int) {
            self.allowances = allowances
            self.requested = requested
            self.reserve = reserve
            self.frontAllowance = frontAllowance
            self.frontTokens = frontTokens
            self.requestedTokens = requestedTokens
            self.prefixAllowance = prefixAllowance
        }

        /// Granted tokens for one segment; `0` means "not emitted".
        public func allowance(for segment: Segment) -> Int { allowances[segment] ?? 0 }

        /// Whether anything was trimmed or dropped — the signal the DEBUG log surfaces so a reader can
        /// tell a front that fit from one that was squeezed.
        public var isTrimmed: Bool { frontTokens < requestedTokens }
    }

    /// Allocate the front's token reserve across the segments, highest priority first.
    ///
    /// - Parameters:
    ///   - windowMax: the prompt token window the front and the prefix share (``PrefixReuse``'s cap).
    ///   - reserveFraction: share of `windowMax` the front is **guaranteed**. Clamped to
    ///     ``reserveFractionRange``. A floor, not a cap — see the type doc.
    ///   - segmentTokens: encoded length of each segment's text. Absent or `≤ 0` ⇒ the segment does not
    ///     participate (and costs no separator).
    ///   - prefixTokens: what the flush prefix would cost if untrimmed. The prefix is served first, up
    ///     to `windowMax − reserve`; whatever it leaves unclaimed the front may take **beyond** its
    ///     reserve. Pass the untrimmed encoded length, not an already-capped one.
    ///   - separatorTokens: tokens spliced *after* each emitted segment — the document-boundary token
    ///     (1) or the encoded text separator. Counted against the reserve, because they are prompt
    ///     tokens like any other.
    ///   - minimumSegmentTokens: below this a segment is dropped whole rather than truncated.
    ///
    /// A segment that does not fit is skipped, **not** a stop: allocation continues down the priority
    /// list, so a huge `focusedDoc` cannot starve a short reply turn that would have fitted in the
    /// remainder.
    ///
    /// ### Why `prefixAllowance` is a *window max* and not a truncation length
    ///
    /// Capping the prefix at a fixed token count while keeping its tail would slide the prefix's start by
    /// one token per keystroke, so the tokens immediately after the (stable) front would change every
    /// time and prefix-KV-reuse would diverge on **every** keystroke. That is the exact problem
    /// ``PrefixReuse/window(_:max:reanchorStep:)`` already solves with its anchored front, so
    /// the allowance is handed to that function as its `max` — the prefix start then stays put and
    /// re-anchors only in `reanchorStep` jumps, as it does today. It is free under the shipping
    /// `rebuild(non-trimmable)` default (nothing is reused), but not once snapshot reuse is
    /// promoted, which is why it is built this way now rather than later.
    public static func allocate(
        windowMax: Int,
        reserveFraction: Double = defaultReserveFraction,
        segmentTokens: [Segment: Int],
        prefixTokens: Int,
        separatorTokens: Int,
        minimumSegmentTokens: Int = PromptFrontBudget.minimumSegmentTokens
    ) -> Allocation {
        precondition(windowMax > 0, "windowMax must be positive")
        let separator = max(0, separatorTokens)
        let fraction = clampReserveFraction(reserveFraction)
        let reserve = min(windowMax, max(0, Int((Double(windowMax) * fraction).rounded())))

        let requested = segmentTokens.filter { $0.value > 0 }
        let requestedTokens = requested.values.reduce(0) { $0 + $1 + separator }

        // Floor, not ceiling. The prefix is served first but never past `windowMax − reserve`, so the
        // reserve is untouchable; the front then claims what the prefix left, which on a short surface
        // exceeds the reserve and on a long document collapses back to exactly it. Asking for no more
        // than `requestedTokens` keeps an empty/short front from reserving tokens it has no use for.
        let prefixWant = max(0, prefixTokens)
        let frontAllowance = min(requestedTokens, min(windowMax, max(reserve, windowMax - prefixWant)))

        var allowances: [Segment: Int] = [:]
        var remaining = frontAllowance
        for segment in priority {
            guard let want = requested[segment], want > 0 else { continue }
            let room = remaining - separator
            guard room > 0 else { continue }
            let granted = min(want, room)
            // The minimum guards against a **fragment**, not against a small source: a segment that
            // fits whole is admitted however short it is (a two-line reply turn is a complete
            // document), while one that would have to be cut below the minimum is dropped instead.
            guard granted == want || granted >= minimumSegmentTokens else { continue }
            allowances[segment] = granted
            remaining -= granted + separator
        }

        let frontTokens = frontAllowance - remaining
        return Allocation(
            allowances: allowances,
            requested: requested,
            reserve: reserve,
            frontAllowance: frontAllowance,
            frontTokens: frontTokens,
            requestedTokens: requestedTokens,
            prefixAllowance: max(1, windowMax - frontTokens))
    }
}
