import Foundation

/// The text context assembled around the caret for a single prediction.
///
/// v1 fills `textBeforeCaret` from the focused field (the prediction prefix) and,
/// during hardening, `windowContext` from the cached visible-window text. The
/// `ContextProvider` seam is what assembles this.
public struct TypingContext: Equatable, Sendable {
    /// Text immediately before the caret in the focused field — the prediction prefix.
    public var textBeforeCaret: String

    /// Text immediately after the caret, if any (used to avoid suggesting what's already there).
    public var textAfterCaret: String

    /// Broader visible-window context, captured on focus/window change and cached —
    /// NOT re-read per keystroke (latency). `nil` until the hardening pass adds it.
    public var windowContext: String?

    /// **Reply-context**: the interlocutor's most-recent turn on a reply surface (Claude's last
    /// message, the email being answered) — the highest-value context when writing a reply, and precisely
    /// what the focused field does NOT contain. Harvested by a separate targeted-descent AX path, cached
    /// with turn-level freshness, and injected as its own prompt-front segment (after `windowContext`,
    /// immediately before the prefix). A *context-input* source: activity-scoped, never learned.
    /// `nil` when the surface isn't a known reply surface or no interlocutor turn is positively matched.
    public var replyContext: String?

    /// **Clipboard context**: the scrubbed, capped text the user copied within the last 120 s, decided by
    /// `ClipboardContextPolicy` and injected as its own prompt-front segment directly before the
    /// focused document. A *context-input* source, opt-in, never stored, never learned
    /// from. `nil` when the toggle is off (the default) or the policy skipped the clipboard, which
    /// keeps the prompt byte-identical to today's.
    public var clipboardContext: String?

    /// **Screen-context OCR**: text read from the *pixels* rather than the AX tree, in its
    /// two roles — the ambient reference window(s) and the focused-window fill used where AX is blind.
    /// Produced by `ScreenOCRContextProvider`, off by default behind its own Screen-Recording
    /// permission. A *context-input* source: whole-screen capture, scrubbed, activity-scoped,
    /// never learned, never persisted. `nil` whenever OCR is disabled — which is the default, and makes
    /// the no-OCR prompt byte-identical to today's.
    public var ocrContext: OCRContext?

    /// **Style profile**: exemplars of the user's *own* past writing, selected once per
    /// context switch and frozen for the typing burst, injected front-most. The only *style-forming*
    /// source: learned from own-inserted text only, encrypted at rest, user-resettable.
    /// `nil` when the feature is off (the default until the eval GO), the profile is too small to prime
    /// with, or the selection hasn't been frozen yet — in all three cases the prompt is byte-identical to
    /// the no-personalization path.
    public var personalization: String?

    /// Length of the host's **selected-text range**, in characters — `0` for the ordinary collapsed
    /// caret. Drives the `SelectionGate`: while something is selected there is no continuation, because
    /// the next keystroke replaces the selection and the ghost would be continuing a text that is about
    /// to cease existing. Read from the same `kAXSelectedTextRange` the
    /// caret index comes from, whose `length` used to be discarded one line before use. `0` also stands
    /// for *AX exposed no range*, so unreadable data never suppresses.
    public var selectionLength: Int

    /// Bundle ID of the focused app, for per-app policy and tuning.
    public var bundleID: String?

    /// Role/subrole + size of the focused field, harvested by the Accessibility layer. Drives the
    /// `FieldSizeGate` (suppress in small single-line inputs). `nil` when AX exposes nothing usable.
    public var field: FieldDescriptor?

    /// Normalized host of the page in a browser (`SiteHost`), `nil` elsewhere. Gate-only like
    /// ``selectionLength``: it feeds the site-rule verdict, never the prompt, so it stays out of
    /// ``PredictionInputs``.
    public var siteHost: String?

    /// The language verdict for the paragraph tail, stamped by `ContextAssembler` only
    /// when the user switched a language off. Gate-only like ``siteHost``: it never reaches the prompt,
    /// so it stays out of ``PredictionInputs``. `nil` when no language is switched off.
    public var languageVerdict: LanguageVerdict?

    public init(
        textBeforeCaret: String,
        textAfterCaret: String = "",
        windowContext: String? = nil,
        replyContext: String? = nil,
        clipboardContext: String? = nil,
        ocrContext: OCRContext? = nil,
        personalization: String? = nil,
        selectionLength: Int = 0,
        bundleID: String? = nil,
        field: FieldDescriptor? = nil,
        siteHost: String? = nil,
        languageVerdict: LanguageVerdict? = nil
    ) {
        self.textBeforeCaret = textBeforeCaret
        self.textAfterCaret = textAfterCaret
        self.windowContext = windowContext
        self.replyContext = replyContext
        self.clipboardContext = clipboardContext
        self.ocrContext = ocrContext
        self.personalization = personalization
        self.selectionLength = selectionLength
        self.bundleID = bundleID
        self.field = field
        self.siteHost = siteHost
        self.languageVerdict = languageVerdict
    }

    /// Everything about this context that could change **what would be predicted** — the redundancy
    /// comparison, extracted so the enumeration lives next to the fields it enumerates.
    ///
    /// The rule, which used to exist only as five hand-written `&&` clauses in `SuggestionSession`
    /// : **every field that reaches the prompt participates; a field that
    /// only feeds a gate does not.** The same defect had already been found and fixed twice — once for
    /// `windowContext`, once for `personalization` — each time for the one field in
    /// hand, so each context source added since started out excluded and silently replayed a stale
    /// suggestion after a caret move.
    ///
    /// The prompt-reaching set is exactly `PromptFront.assemble`'s parameter list (prefix,
    /// personalization, windowContext, ocrFocusedFill, ocrAmbient, replyContext, clipboard) plus the two fields that
    /// select *which* prompt is built at all: `textAfterCaret`, which becomes the FIM suffix `S` and
    /// decides the `FIMSite` route, and `bundleID`, the surface identity behind per-app policy.
    /// Deliberately **out**: ``selectionLength``, ``siteHost``, ``languageVerdict`` and ``field``, which drive `SelectionGate` and
    /// `FieldSizeGate` — they decide whether a suggestion is *shown*, never what it would say, so a change
    /// in either must not spend an inference. `AcceptanceKey`-level state is out for the same reason.
    ///
    /// Adding a field to `TypingContext` that reaches the prompt means adding it here; `SuggestionSessionTests`
    /// pins one case per field so the omission fails a test instead of passing silently.
    public struct PredictionInputs: Equatable, Sendable {
        let textBeforeCaret: String
        /// Bounded: only the suffix that can reach a prompt (the FIM `S` is capped well below this) —
        /// unbounded, an edit far to the right of the caret would invalidate for nothing.
        let textAfterCaretHead: String
        let bundleID: String?
        let windowContext: String?
        let replyContext: String?
        let clipboardContext: String?
        /// `OCRContext` holds *only* its two prompt-reaching strings (`ambient`, `focusedFill`), so
        /// comparing the value compares exactly what reaches the prompt. That is load-bearing: were the
        /// struct ever to grow a pass-level detail (a timestamp, a block count), two reads of an
        /// unchanged screen would stop comparing equal and every OCR tick would re-infer — a worse defect
        /// than the one this comparison exists to fix. Keep such detail out of `OCRContext`.
        let ocrContext: OCRContext?
        let personalization: String?
    }

    /// See ``PredictionInputs``.
    public var predictionInputs: PredictionInputs {
        PredictionInputs(
            textBeforeCaret: textBeforeCaret,
            textAfterCaretHead: String(textAfterCaret.prefix(Self.suffixComparisonChars)),
            bundleID: bundleID,
            windowContext: windowContext,
            replyContext: replyContext,
            clipboardContext: clipboardContext,
            ocrContext: ocrContext,
            personalization: personalization
        )
    }

    /// How much of `textAfterCaret` participates in the redundancy comparison.
    private static let suffixComparisonChars = 200

    /// The last whitespace-delimited token before the caret — the in-progress word,
    /// or "" if the caret sits just after whitespace.
    public var currentWordPrefix: String {
        guard let lastSeparator = textBeforeCaret.lastIndex(where: { $0.isWhitespace }) else {
            return textBeforeCaret
        }
        return String(textBeforeCaret[textBeforeCaret.index(after: lastSeparator)...])
    }
}
