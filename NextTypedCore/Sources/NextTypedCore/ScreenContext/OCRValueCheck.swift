import Foundation

/// The **OCR↔AX value-check** — the gate on Tier-1 (focused-window) injection.
///
/// OCR's fallback job is to fill in where AX is *blind* (Mail's WebKit compose body, text-less Electron,
/// PDFs, images). But whether a surface is AX-blind is not a static per-app fact — it varies by view and
/// by document. So the decision is made from evidence: compare the focused window's OCR text against the
/// AX `windowContext` harvested from that same window.
///
///   - heavy overlap ⇒ **redundant** — AX already sees it; injecting the pixels would double-feed the
///     focused window's own text, the documented acceptance crater (offline measurements);
///   - partial overlap ⇒ inject only the **net-new remainder** (AX-partial);
///   - no overlap ⇒ inject the OCR text (AX-blind).
///
/// The `focusedDoc` prompt slot is filled by `windowContext` **XOR** this fill, never both — the
/// exclusivity the prompt relies on is produced *here*, not asserted downstream.
///
/// Comparison is **line-wise**, not substring-wise: OCR reflows and re-punctuates text, so a whole-string
/// `contains` would almost always report "disjoint" and defeat the guard. Lines are normalised
/// (case-folded, whitespace-collapsed, punctuation-stripped) so "Dear Anna," and "Dear Anna" match.
public enum OCRValueCheck {
    /// Fraction of OCR lines that must already appear in the AX text before the whole OCR fill is
    /// judged redundant. Deliberately well below 1.0: OCR misreads a few lines on any real screen, so
    /// demanding a perfect match would let a mostly-duplicate fill through.
    public static let redundancyThreshold = 0.6

    /// Minimum characters a net-new remainder must have to be worth a prompt slot — below this it is
    /// OCR noise (a stray label, a misread word), not content.
    public static let minimumRemainderChars = 40

    public enum Verdict: Equatable, Sendable {
        /// AX already covers this window — inject nothing (keep `windowContext` in the slot).
        case redundant
        /// Inject this text as the focused-doc fill (AX blind or partial).
        case fill(String)
    }

    /// Decide what — if anything — the focused window's OCR text contributes.
    ///
    /// - Parameters:
    ///   - ocrText: text attributed to the focused window (Tier 1).
    ///   - axText: the AX `windowContext` harvested from the same window, if any.
    public static func verdict(ocrText: String, axText: String?) -> Verdict {
        let ocrLines = contentLines(ocrText)
        guard !ocrLines.isEmpty else { return .redundant }

        guard let axText, !axText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // AX is blind here — the whole OCR read is the fill (this is case (A), the reason OCR exists).
            return fillOrRedundant(ocrLines.map(\.original))
        }

        let axKeys = Set(contentLines(axText).map(\.normalized))
        let novel = ocrLines.filter { !axKeys.contains($0.normalized) }
        let covered = Double(ocrLines.count - novel.count) / Double(ocrLines.count)
        if covered >= redundancyThreshold { return .redundant }
        return fillOrRedundant(novel.map(\.original))
    }

    private static func fillOrRedundant(_ lines: [String]) -> Verdict {
        let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined.count >= minimumRemainderChars else { return .redundant }
        return .fill(joined)
    }

    /// Split into comparable lines, dropping blanks and single glyphs, keeping the original text
    /// alongside a normalised key. Normalisation absorbs the differences OCR *always* introduces —
    /// case, spacing, stray punctuation — so the overlap measure reflects content, not transcription.
    static func contentLines(_ text: String) -> [(original: String, normalized: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard original.count >= 2 else { return nil }
            let normalized = original
                .lowercased()
                .unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
                .reduce(into: "") { partial, character in
                    if character == " ", partial.last == " " { return }
                    partial.append(character)
                }
                .trimmingCharacters(in: .whitespaces)
            guard !normalized.isEmpty else { return nil }
            return (original, normalized)
        }
    }
}
