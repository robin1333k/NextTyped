/// The **caret-position model router** for mid-text insertion (FIM), build item 4.
///
/// Two models share one caret: `Qwen3.5-2B-Base` continues *forward* from the prefix, and (on the
/// `fimEnabled` path only) a FIM-trained model *bridges* between a prefix `P` and a suffix `S`. The
/// choice is a pure function of where the caret sits, so it lives here rather than in the engine —
/// the engine only dispatches on the answer. They are mutually exclusive per predict, which is what
/// preserves the single in-flight Task.
///
/// **The site is the paragraph, not the line.** `hasTextToRight` (the rendering signal) is
/// same-line only, so at a soft-wrapped mid-paragraph boundary it reads false while real text does
/// follow the caret — routing a genuine FIM site to forward continuation. The predicate therefore
/// slices `textAfterCaret` at its first newline-class grapheme and asks whether *that* slice carries
/// non-whitespace content. In a newline-free field (a soft-wrapped compose box such as Claude
/// Desktop) the whole remainder is the one paragraph, which is the correct reading there.
///
/// The slice is also the suffix `S` handed to the prompt builder (item 5) — one definition, so the
/// predicate and the prompt can never disagree about where `S` ends.
public enum FIMSite {
    /// The current paragraph to the right of the caret: `textAfterCaret` up to (excluding) the first
    /// newline-class grapheme, or all of it when the field holds no newline.
    ///
    /// `Character.isNewline` (not a bare `"\n"` compare) so a CRLF is one break, matching `ClauseStop`.
    public static func paragraphSuffix(afterCaret textAfterCaret: String) -> String {
        guard let firstBreak = textAfterCaret.firstIndex(where: { $0.isNewline }) else {
            return textAfterCaret
        }
        return String(textAfterCaret[..<firstBreak])
    }

    /// Whether the caret sits *inside* a paragraph — there is real text to bridge into.
    ///
    /// Whitespace-only (or empty) means the caret is effectively at the paragraph end, which
    /// routes to ordinary forward continuation; text on *later* lines does not make this a FIM site.
    public static func isFIMSite(textAfterCaret: String) -> Bool {
        paragraphSuffix(afterCaret: textAfterCaret).contains { !$0.isWhitespace }
    }

    /// Which model this predict should run on.
    public enum ModelRoute: Equatable, Sendable {
        /// Mid-text bridge: run the FIM model with this suffix `S` (already the paragraph slice).
        case fim(suffix: String)
        /// Ordinary forward continuation on the base model.
        case forward
    }

    /// Route a predict. `fimEnabled` is the master gate (opt-in, default **off**) — with it
    /// false this always answers `.forward`, so the FIM model is never selected and therefore never
    /// loaded (the "lazy-both" residency guarantee, item 2).
    ///
    /// The floors (chrome/secure/field-size) and the correction precedence sit upstream and are
    /// unchanged: this only splits an already-eligible continuation predict between the two models.
    public static func route(textAfterCaret: String, fimEnabled: Bool) -> ModelRoute {
        guard fimEnabled, isFIMSite(textAfterCaret: textAfterCaret) else { return .forward }
        return .fim(suffix: paragraphSuffix(afterCaret: textAfterCaret))
    }
}
