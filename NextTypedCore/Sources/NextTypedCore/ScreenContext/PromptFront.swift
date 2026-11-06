import Foundation

/// The **prompt-front assembly** — how the context sources are ordered, capped
/// and joined in front of the flush prefix. Lifted out of `MLXPredictionEngine` so the ordering and the
/// disjointness guards are unit-tested rather than living inline in the one layer that can't be.
///
/// Order, furthest-from-prefix first:
///
///     personalization ␣␣ ocrAmbient ␣␣ clipboard ␣␣ [focusedDoc: windowContext + disjoint ocrFill] ␣␣ replyContext ␣␣ prefix
///
/// The `personalization` slot sits first: the style profile is the least volatile source
/// (`contextSwitch` cadence) and the lowest direct pull (a *frame* — "your voice" — rather than
/// next-token content), so it sits outermost. Front-most is explicitly **not** a protected slot: it is
/// the first thing `PrefixReuse.window` evicts once the encoded prompt outgrows the token window, which
/// is aligned with need — the profile matters when the typed prefix is short and is redundant once the
/// user's own writing fills the window in-context.
///
/// The ordering is a claim about **pull**: a base model attends most to what sits nearest the
/// continuation point, so the highest-value, most-directly-relevant source (the interlocutor's turn)
/// sits closest to the prefix, and the noisiest/most-ambient source (other windows' pixels)
/// sits furthest away. The stable front is also the KV-friendly end: ambient context changes rarely, so
/// `PrefixReuse.window`'s anchored front keeps reuse firing.
///
/// **Raw, single-encoded, no labels and no system prompt.** The shipping model is a *base* model
/// : it continues text rather than obeying instructions, so a label like `[Screen]:` would be
/// echoed into ghosts (the answer-mode class). The positional structure needs no explanation because it
/// exploits continuation, not instruction-following.
public enum PromptFront {
    /// Per-segment head caps, in **characters**.
    ///
    /// > Important: these are no longer the binding constraint and must not be read as one. Characters
    /// > cannot see the token window the front actually competes for, which is exactly how the front
    /// > came to be silently evicted on long documents. The real
    /// > arbitration is ``PromptFrontBudget``, in tokens, against `windowMax`. What survives here is a
    /// > **cheap pre-filter**: it bounds how much text is handed to the tokenizer per predict (the
    /// > encode runs on the latency-critical path), and it keeps the disjointness guard operating on a
    /// > bounded string. A cap that is generous relative to the token reserve is therefore fine — the
    /// > token budget trims afterwards, keeping heads.
    public struct Budgets: Equatable, Sendable {
        public var ocrAmbient: Int
        public var focusedDoc: Int
        public var reply: Int
        /// Clipboard segment cap; equals `ClipboardContextPolicy.headCapChars`.
        public var clipboard: Int
        /// ~⅓ of `focusedDoc`: deliberately the smallest segment, because voice-priming
        /// saturates early. Expressed as a share of `windowContext`'s budget so the two content/frame
        /// budgets stay in proportion. Scaling against the token window (`windowMax`) is
        /// ``PromptFrontBudget``'s job, not this cap's.
        public var personalization: Int

        public init(ocrAmbient: Int = 800, focusedDoc: Int = 1500, reply: Int = 1500,
                    personalization: Int = 600, clipboard: Int = ClipboardContextPolicy.headCapChars) {
            self.ocrAmbient = ocrAmbient
            self.focusedDoc = focusedDoc
            self.reply = reply
            self.clipboard = clipboard
            self.personalization = personalization
        }

        public static let `default` = Budgets()
    }

    /// Length of the near-caret tail probed by the disjointness guard, mirroring the AX harvest's own
    /// `overlapProbeChars`.
    public static let overlapProbeChars = 120
    /// Below this the tail is too generic to prove anything ("the ", "und ") — a short-tail match would
    /// drop good context on a coincidence.
    static let minimumProbeChars = 12

    /// The text separator used between front segments **when no document-boundary token is available**.
    /// See ``Assembly/frontSegments`` — the engine prefers the model's own end-of-text token id.
    public static let textSeparator = "\n\n"

    /// The front, **unjoined** — the ordered segments that survived the caps and the disjointness
    /// guard, plus the untouched flush prefix.
    ///
    /// Exists because the join is no longer purely a string operation. Each segment genuinely is a
    /// *different document* (the user's own past sentences, another window, someone else's chat turn),
    /// and a `"\n\n"` between two documents is, to a **base** model, just a paragraph break inside one
    /// document — so it happily continues a style exemplar as content. The
    /// fix is to emit the model's own end-of-text token between segments, which says "the previous
    /// document ended" in the model's native vocabulary. That is a *token id*, not text, so Core hands
    /// the engine the segment list and the engine encodes and splices.
    ///
    /// This is **not** a system prompt: no instructions, no
    /// labels, no framing text — only the separator that pre-training already used between documents.
    ///
    /// ``prompt`` reproduces the old plain-text join byte-for-byte, and is what the engine falls back to
    /// when the boundary token cannot be resolved from the model's vocabulary.
    public struct Assembly: Equatable, Sendable {
        /// One admitted front segment: which source it came from, and its (already capped, already
        /// guarded, never empty) text.
        ///
        /// The **kind** is carried because the engine has to budget these in *tokens* against
        /// `windowMax` (``PromptFrontBudget``), and that allocation is by priority — so a bare list of
        /// strings is no longer enough to describe the front. Order here stays the *positional* order;
        /// the priority order lives in ``PromptFrontBudget/priority`` and is deliberately different.
        public struct Segment: Equatable, Sendable {
            public let kind: PromptFrontBudget.Segment
            public let text: String

            public init(kind: PromptFrontBudget.Segment, text: String) {
                self.kind = kind
                self.text = text
            }
        }

        /// Front segments in prompt order (furthest from the prefix first).
        public let segments: [Segment]
        /// The segment texts alone, in prompt order.
        public var frontSegments: [String] { segments.map(\.text) }
        /// The flush prefix, exactly as passed in (never modified here).
        public let prefix: String
        public let ocrAmbientChars: Int
        public let focusedDocChars: Int
        public let replyChars: Int
        public let personalizationChars: Int
        public let clipboardChars: Int

        public init(segments: [Segment], prefix: String, ocrAmbientChars: Int,
                    focusedDocChars: Int, replyChars: Int, personalizationChars: Int,
                    clipboardChars: Int = 0) {
            self.clipboardChars = clipboardChars
            self.segments = segments
            self.prefix = prefix
            self.ocrAmbientChars = ocrAmbientChars
            self.focusedDocChars = focusedDocChars
            self.replyChars = replyChars
            self.personalizationChars = personalizationChars
        }

        /// The plain-text join — the pre-boundary-token prompt, kept byte-identical.
        public var prompt: String {
            frontSegments.isEmpty
                ? prefix
                : frontSegments.joined(separator: PromptFront.textSeparator) + PromptFront.textSeparator + prefix
        }

        /// The legacy ``Result`` view of this assembly.
        public var result: Result {
            Result(prompt: prompt,
                   ocrAmbientChars: ocrAmbientChars,
                   focusedDocChars: focusedDocChars,
                   replyChars: replyChars,
                   personalizationChars: personalizationChars)
        }
    }

    /// The joined segments plus the per-segment lengths that actually made it in (for the DEBUG log —
    /// what the prompt *contains* should be measurable, not inferred).
    public struct Result: Equatable, Sendable {
        public var prompt: String
        public var ocrAmbientChars: Int
        public var focusedDocChars: Int
        public var replyChars: Int
        public var personalizationChars: Int

        public init(prompt: String, ocrAmbientChars: Int, focusedDocChars: Int, replyChars: Int,
                    personalizationChars: Int = 0) {
            self.prompt = prompt
            self.ocrAmbientChars = ocrAmbientChars
            self.focusedDocChars = focusedDocChars
            self.replyChars = replyChars
            self.personalizationChars = personalizationChars
        }
    }

    /// Assemble the prompt front: which segments, in which order, capped and guarded.
    ///
    /// - Parameters:
    ///   - prefix: the flush (trailing-whitespace-stripped) text before the caret. Never modified.
    ///   - windowContext: AX-harvested focused-window context. Wins the focusedDoc slot.
    ///   - ocrFocusedFill: Tier-1 OCR fill for the focused window, used **only** when `windowContext`
    ///     is absent — the XOR the design requires. `OCRValueCheck` already guarantees the
    ///     fill is net-new; this is the structural backstop.
    ///   - ocrAmbient: Tier-2 ambient screen context.
    ///   - replyContext: the interlocutor's most-recent turn.
    ///   - personalization: the frozen style-profile segment for this typing burst. Selected
    ///     once per context switch, so it is byte-stable across the burst and costs no extra KV
    ///     invalidation.
    ///   - clipboardContext: the policy-approved clipboard text (`ClipboardContextPolicy`), placed
    ///     directly before `focusedDoc`. `nil` leaves the front byte-identical to the no-clipboard path.
    public static func assemble(
        prefix: String,
        personalization: String? = nil,
        windowContext: String? = nil,
        ocrFocusedFill: String? = nil,
        ocrAmbient: String? = nil,
        replyContext: String? = nil,
        clipboardContext: String? = nil,
        budgets: Budgets = .default
    ) -> Assembly {
        let tail = String(prefix.suffix(overlapProbeChars))

        // The focusedDoc slot. The invariant here is **never feed the same text twice**,
        // which the value-check already guarantees: `ocrFocusedFill` is only ever
        // the *net-new* remainder — what AX did not see — or the whole read when AX was blind.
        //
        // So the slot composes rather than strictly alternates: AX text first (cheaper, more precise),
        // then the disjoint pixel remainder. A pure `windowContext ?? fill` would make the value-check's
        // AX-**partial** arm dead code — the exact Mail-compose case this feature exists for (headers
        // readable via AX, body only in pixels) would inject the headers and drop the body.
        let focusedDoc = joined(
            admit(windowContext, cap: budgets.focusedDoc, tail: tail),
            admit(ocrFocusedFill, cap: budgets.focusedDoc, tail: tail),
            cap: budgets.focusedDoc)
        let ambient = admit(ocrAmbient, cap: budgets.ocrAmbient, tail: tail)
        let reply = admit(replyContext, cap: budgets.reply, tail: tail)
        let clip = admit(clipboardContext, cap: budgets.clipboard, tail: tail)
        let style = admit(personalization, cap: budgets.personalization, tail: tail)

        let segments: [Assembly.Segment] = [
            (PromptFrontBudget.Segment.personalization, style),
            (.ocrAmbient, ambient),
            (.clipboard, clip),
            (.focusedDoc, focusedDoc),
            (.reply, reply),
        ].compactMap { kind, text in text.map { Assembly.Segment(kind: kind, text: $0) } }
        return Assembly(
            segments: segments,
            prefix: prefix,
            ocrAmbientChars: ambient?.count ?? 0,
            focusedDocChars: focusedDoc?.count ?? 0,
            replyChars: reply?.count ?? 0,
            personalizationChars: style?.count ?? 0,
            clipboardChars: clip?.count ?? 0)
    }

    /// The plain-text join of ``assemble(prefix:personalization:windowContext:ocrFocusedFill:ocrAmbient:replyContext:budgets:)``
    /// — the original single-string API, kept for callers (and tests) that only need the joined prompt.
    public static func build(
        prefix: String,
        personalization: String? = nil,
        windowContext: String? = nil,
        ocrFocusedFill: String? = nil,
        ocrAmbient: String? = nil,
        replyContext: String? = nil,
        clipboardContext: String? = nil,
        budgets: Budgets = .default
    ) -> Result {
        assemble(prefix: prefix,
                 personalization: personalization,
                 windowContext: windowContext,
                 ocrFocusedFill: ocrFocusedFill,
                 ocrAmbient: ocrAmbient,
                 replyContext: replyContext,
                 clipboardContext: clipboardContext,
                 budgets: budgets).result
    }

    /// Join the two focusedDoc sources into one slot, keeping the slot's own cap. Either being `nil`
    /// yields the other unchanged, so the AX-only and pixels-only paths stay byte-identical to a
    /// single-source slot.
    ///
    /// Deliberately a **plain text** join, not a document boundary: AX text and the disjoint pixel
    /// remainder are two readings of the *same* document (the focused window), so a boundary token here
    /// would claim a document ended where one did not.
    static func joined(_ first: String?, _ second: String?, cap: Int) -> String? {
        switch (first, second) {
        case (nil, nil): return nil
        case (let only?, nil), (nil, let only?): return only
        case (let a?, let b?): return String((a + "\n\n" + b).prefix(cap))
        }
    }

    /// Head-cap a segment and apply the disjointness guard: a segment that already contains the
    /// near-caret tail would re-feed the text being typed, so it is dropped entirely.
    static func admit(_ segment: String?, cap: Int, tail: String) -> String? {
        guard let segment else { return nil }
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let capped = String(trimmed.prefix(cap))
        if tail.count >= minimumProbeChars, capped.contains(tail) { return nil }
        return capped
    }
}
