/// The **shape** of a mid-text (FIM) prompt, build item 5.
///
/// A FIM prompt is three pieces and three sentinels: the suffix `S` (caret → paragraph end, from
/// `FIMSite`), the prefix `P` (text before the caret), and the `<fim_middle>` marker that opens the
/// generation. What varies is the *order*:
///
///   - **SPM** (`<fim_suffix> S <fim_prefix> P <fim_middle>`) — the shipping primary. The static `S`
///     block sits at the stable front, so a keystroke only appends to `P` and `PrefixReuse.plan` finds
///     a long shared run. This is what makes KV-reuse survive the FIM path at all.
///   - **PSM** (`<fim_prefix> P <fim_suffix> S <fim_middle>`) — the eval fallback. `P` grows in the
///     *middle*, so every keystroke shifts `S` and the trailing sentinels; the shared run ends at the
///     caret and essentially the whole prompt re-prefills. The ticket's answer is to stop pretending
///     that is a reuse and force a rebuild, which ``Layout/reuseEligible`` reports.
///
/// Which ordering ships is the eval's call (the offline probe), so both are built here rather than
/// one being hard-coded into the engine.
///
/// **No prompt-front context on this path** (`windowContext`/reply/OCR/personalization): FIM v1 is
/// limited to the local block. Those segments are the forward path's `PromptFront`.
public enum FIMPrompt {

    /// The sentinel ordering of the assembled block.
    public enum Ordering: String, Equatable, Sendable {
        /// `<fim_suffix> S <fim_prefix> P <fim_middle>` — reuse-preserving, the primary.
        case spm
        /// `<fim_prefix> P <fim_suffix> S <fim_middle>` — the eval fallback, reuse-off.
        case psm
    }

    /// The FIM sentinel ids, resolved from **the FIM model's own vocabulary**.
    ///
    /// Deliberately not hard-coded: the base 2B and the FIM model need not agree on these ids, and a
    /// wrong id is invisible — the prompt still decodes, it just stops being an infill.
    public struct Sentinels: Equatable, Sendable {
        public let prefix: Int
        public let suffix: Int
        public let middle: Int

        /// Fail-closed resolution. `nil` — meaning "this model can't do FIM, route back to forward" —
        /// whenever any sentinel is missing.
        ///
        /// `unknown` is the tokenizer's `<unk>` id. `Tokenizer.convertTokenToId` answers *that* for a
        /// token the vocabulary lacks rather than `nil`, so without this filter every sentinel on a
        /// non-FIM model would "resolve" to the same junk id and the block would look well-formed.
        public init?(prefix: Int?, suffix: Int?, middle: Int?, unknown: Int? = nil) {
            guard let prefix, let suffix, let middle else { return nil }
            if let unknown, prefix == unknown || suffix == unknown || middle == unknown { return nil }
            self.prefix = prefix
            self.suffix = suffix
            self.middle = middle
        }
    }

    /// An assembled block, split the way `PrefixReuse.fimWindow` needs it.
    public struct Layout: Equatable, Sendable {
        /// The front block that must never be dropped when the prompt overruns its budget.
        public let pinned: [Int]
        /// The prefix `P` — the only part that grows keystroke to keystroke.
        public let growing: [Int]
        /// Everything after `P`, ending in `<fim_middle>`.
        public let trailing: [Int]
        /// Whether a `P`-append leaves a usable shared prefix (SPM) or shifts the tail (PSM).
        public let reuseEligible: Bool

        /// The full prompt token sequence.
        public var tokens: [Int] { pinned + growing + trailing }

        public init(pinned: [Int], growing: [Int], trailing: [Int], reuseEligible: Bool) {
            self.pinned = pinned
            self.growing = growing
            self.trailing = trailing
            self.reuseEligible = reuseEligible
        }
    }

    /// Assemble the block. `suffixTokens`/`prefixTokens` are already encoded and already capped
    /// (``capSuffix(_:budget:)`` for `S`; `fimWindow` caps the `P`-head downstream).
    public static func layout(
        ordering: Ordering, sentinels: Sentinels, suffixTokens: [Int], prefixTokens: [Int]
    ) -> Layout {
        switch ordering {
        case .spm:
            return Layout(
                pinned: [sentinels.suffix] + suffixTokens + [sentinels.prefix],
                growing: prefixTokens,
                trailing: [sentinels.middle],
                reuseEligible: true)
        case .psm:
            return Layout(
                pinned: [sentinels.prefix],
                growing: prefixTokens,
                trailing: [sentinels.suffix] + suffixTokens + [sentinels.middle],
                reuseEligible: false)
        }
    }

    /// How many tokens `S` may claim of the prompt budget — ~¼.
    ///
    /// The split is deliberately lopsided: `P` is the side the model continues *from*, while `S` only
    /// has to establish what the bridge must land on, and the nearest sentence of it does most of that
    /// work. Floored at 1 — a budget of 0 would drop `S` and silently demote the bridge to a forward
    /// predict wearing FIM sentinels.
    public static func suffixTokenBudget(windowMax: Int) -> Int {
        max(1, windowMax / 4)
    }

    /// Cap `S` to its budget, keeping the **head**. `S` runs caret → paragraph end, so its head is the
    /// text immediately right of the caret — the part the bridge actually has to join onto.
    public static func capSuffix(_ tokens: [Int], budget: Int) -> [Int] {
        tokens.count <= budget ? tokens : Array(tokens.prefix(budget))
    }
}
