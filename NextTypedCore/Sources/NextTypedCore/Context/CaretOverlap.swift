/// The **inline-vs-bubble overlap decision**, lifted out of the AX layer so the
/// surface-independent logic is unit-testable. `CaretLocator` reads the AX
/// geometry and feeds it here; this type decides whether there is host text to the **right** of
/// the caret (same line ⇒ inline would paint over it) or **below** it (a wrapping continuation
/// would collide).
///
/// Why it exists: deciding overlap purely from "the glyph box of the character after the caret"
/// fails differently per surface — on claude.ai (Safari ProseMirror) that box starts *left* of the
/// caret at end-of-text (98 % of reads); in Apple Notes it sits on the *next line* (96 %). There is
/// no single geometry tweak that fixes both, so the primary, surface-independent signal is
/// **end-of-field** (caret index ≥ value length ⇒ nothing follows the caret by construction),
/// backed by two geometry guards as defence-in-depth.
///
/// Pure Core: geometry crosses the App→Core seam as plain `Double`s (a `GlyphBox`), mirroring the
/// `FieldDescriptor`/`FieldSizeGate` convention — no CoreGraphics/AppKit/AX here.
public enum CaretOverlap {
    /// How far LEFT of the caret a next-glyph box may start before it's treated as the rich-editor
    /// artefact rather than genuine adjacent text. The claude.ai ProseMirror artefact is ~2 pt left;
    /// genuine mid-line adjacency reads `next.minX ≈ caret.minX` but can dip a fraction of a point
    /// below it from sub-pixel rounding between two separate AX reads or an overhanging/italic
    /// glyph's tight left side-bearing. A 1 pt band rejects the artefact without suppressing a real
    /// same-line overlap (end-of-field is the primary guard regardless).
    static let leftOfCaretTolerance: Double = 1.0

    /// The caret is at (or past) the end of the field's value, so there is no host text after it —
    /// neither to the right nor below — regardless of what a glyph box claims. This is the cheap,
    /// surface-independent overlap signal; on rich editors AX still hands back a stale/garbage box
    /// for the char "after" the caret even at end-of-text, and this guard ignores it.
    ///
    /// `>=` (not `==`) so an off-by-one AX read can't flip the decision. Returns `false` when either
    /// value is unknown (AX exposed no character count) so the geometry path still applies.
    public static func isAtEndOfField(caretIndex: Int?, valueLength: Int?) -> Bool {
        guard let caretIndex, let valueLength else { return false }
        return caretIndex >= valueLength
    }

    /// Is there visible host text immediately to the **right** of the caret on the SAME line —
    /// i.e. would an inline ghost paint over it (→ route to the bubble)?
    ///
    /// - `next` is the box of the first visible character at/after the caret (AX layer skips
    ///   whitespace), or `nil` when only whitespace / end-of-text follows.
    /// - `nextGeometryReliable` is `false` only on the Electron/Chromium text-marker path, where the
    ///   next-glyph scan (`markerNextVisibleRect`) can be *dead* — returning `nil` even though text
    ///   provably follows the caret. Defaults to `true` so every CFRange caller (TextEdit/Safari/Notes)
    ///   and every existing test is byte-identical.
    /// Decision: not at end-of-field, AND a real next glyph that is on the same line AND not to the
    /// left of the caret. The left-of-caret rejection kills the claude.ai ProseMirror false positive
    /// where the next-glyph box starts a couple of points left of the caret at end-of-text.
    /// Index-signal fallback (Option C): on the Electron marker path the
    /// next-glyph scan can be dead (`next == nil`) even though text follows the caret. Trust the
    /// surface-independent index proof instead — but ONLY when it actually holds: both indices known
    /// AND `caretIndex < valueLength`. Note this is *stronger* than "`isAtEndOfField` returned false",
    /// which is also false when the length is UNKNOWN (`valueLength == nil` short-circuits it) — an
    /// unknown length is not proof that text follows, so it must fall through to geometry (`next == nil`
    /// ⇒ inline, unchanged), not force a bubble over a possibly-empty tail. A real marker `next` box is
    /// trustworthy, so it still takes the geometry path.
    public static func hasTextToRight(caretIndex: Int?, valueLength: Int?,
                                      caret: GlyphBox, next: GlyphBox?,
                                      nextGeometryReliable: Bool = true) -> Bool {
        if isAtEndOfField(caretIndex: caretIndex, valueLength: valueLength) { return false }
        if next == nil, !nextGeometryReliable,
           let caretIndex, let valueLength, caretIndex < valueLength { return true }
        guard let next, next.width > 0.5 else { return false }
        // Reject a glyph starting more than a hair left of the caret (the rich-editor artefact);
        // the tolerance keeps genuine adjacent text (`next.minX ≈ caret.minX`, possibly a fraction
        // below from rounding / glyph bearing) counting as real right-text. See `leftOfCaretTolerance`.
        if next.minX < caret.minX - leftOfCaretTolerance { return false }
        return isSameLine(next, as: caret)
    }

    /// Is there visible host text on the line IMMEDIATELY **below** the caret (a soft-wrapped
    /// paragraph or the next paragraph) — the only line a short wrapping continuation could collide
    /// with? Not at end-of-field, AND a real next glyph on the line just below.
    public static func hasTextBelow(caretIndex: Int?, valueLength: Int?,
                                    caret: GlyphBox, next: GlyphBox?) -> Bool {
        if isAtEndOfField(caretIndex: caretIndex, valueLength: valueLength) { return false }
        return isBelowLine(next, than: caret)
    }

    // MARK: Geometry predicates (ported verbatim from CaretLocator so behaviour is identical)

    /// Whether `next` is on the same visual line as `caret` (vertical-centre overlap). Requires a
    /// real (non-degenerate) glyph width.
    static func isSameLine(_ next: GlyphBox?, as caret: GlyphBox) -> Bool {
        guard let r = next, r.width > 0.5 else { return false }
        return abs(r.midY - caret.midY) < max(caret.height, r.height, 4) * 0.6
    }

    /// Whether `next` is on the line immediately below `caret` (larger midY, since AX y grows
    /// downward), bounded to ~1.8 line-heights so text many blank lines down (a later paragraph) is
    /// correctly ignored — a short continuation only wraps onto the empty next line.
    static func isBelowLine(_ next: GlyphBox?, than caret: GlyphBox) -> Bool {
        guard let r = next, r.width > 0.5 else { return false }
        let gap = r.midY - caret.midY
        let lineHeight = max(caret.height, r.height, 4)
        return gap > lineHeight * 0.6 && gap < lineHeight * 1.8
    }
}

/// A minimal glyph/caret rectangle carried across the App→Core seam for the overlap decision.
/// Plain `Double`s (points) keep Core free of CoreGraphics — `CaretLocator` builds these from its
/// `CGRect`s. `midY` is the vertical centre (AX y grows downward); `width` 0 marks a caret rect.
public struct GlyphBox: Equatable, Sendable {
    public var minX: Double
    public var midY: Double
    public var width: Double
    public var height: Double

    public init(minX: Double, midY: Double, width: Double, height: Double) {
        self.minX = minX
        self.midY = midY
        self.width = width
        self.height = height
    }
}
