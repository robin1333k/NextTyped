import Testing
@testable import NextTypedCore

/// The overlap decision (inline ghost vs below-line bubble) lifted out of the AX layer
/// (`CaretLocator`) so the surface-independent logic is unit-testable. Covers the two real
/// cross-surface false positives from runtime logs:
///   - claude.ai (ProseMirror): the char-after-caret glyph box starts LEFT of the caret while
///     the user types at end-of-text (310/316 reads) → must not count as "text to the right".
///   - Apple Notes: the char-after-caret rect sits on the line BELOW (next paragraph) in 96 % of
///     samples → must not count as "text to the right".
/// The primary fix is the cheap, surface-independent **end-of-field** signal (caret index vs
/// value length); the geometry guards are defence-in-depth.
@Suite struct CaretOverlapTests {
    // A typical caret box: width-0, at x=600, vertical centre 500, one ~18pt line tall.
    private static let caret = GlyphBox(minX: 600, midY: 500, width: 0, height: 18)

    // MARK: End-of-field signal

    @Test func atEndOfFieldWhenCaretAtValueLength() {
        #expect(CaretOverlap.isAtEndOfField(caretIndex: 42, valueLength: 42) == true)
    }

    @Test func atEndOfFieldWhenCaretPastValueLength() {
        // Defensive: an off-by-one AX read shouldn't flip the decision.
        #expect(CaretOverlap.isAtEndOfField(caretIndex: 43, valueLength: 42) == true)
    }

    @Test func notAtEndOfFieldMidValue() {
        #expect(CaretOverlap.isAtEndOfField(caretIndex: 10, valueLength: 42) == false)
    }

    @Test func notAtEndOfFieldWhenLengthUnknown() {
        // AX exposed no character count → can't claim end-of-field; fall back to geometry.
        #expect(CaretOverlap.isAtEndOfField(caretIndex: 10, valueLength: nil) == false)
        #expect(CaretOverlap.isAtEndOfField(caretIndex: nil, valueLength: 42) == false)
    }

    // MARK: hasTextToRight — end-of-field short-circuit

    @Test func noRightTextAtEndOfFieldEvenWithSameLineGlyph() {
        // claude.ai end-of-text: AX still hands back a same-line glyph box, but the caret is
        // provably at the end of the value → there is nothing to the right by construction.
        let next = GlyphBox(minX: 650, midY: 500, width: 8, height: 18)   // same line, to the right
        #expect(CaretOverlap.hasTextToRight(caretIndex: 42, valueLength: 42,
                                            caret: Self.caret, next: next) == false)
    }

    // MARK: hasTextToRight — geometry guard (left-of-caret)

    @Test func noRightTextWhenNextGlyphIsLeftOfCaret() {
        // claude.ai ProseMirror: caret x=594, next-glyph x=592 (left of caret) while at end of text.
        let caret = GlyphBox(minX: 594, midY: 500, width: 0, height: 18)
        let next = GlyphBox(minX: 592, midY: 500, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 100, valueLength: 200,
                                            caret: caret, next: next) == false)
    }

    @Test func nextGlyphExactlyAtCaretXIsNotRejectedByLeftGuard() {
        // Boundary: next.minX == caret.minX is genuine right-text, not the artefact.
        let caret = GlyphBox(minX: 600, midY: 500, width: 0, height: 18)
        let next = GlyphBox(minX: 600, midY: 500, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 100, valueLength: 200,
                                            caret: caret, next: next) == true)
    }

    @Test func nextGlyphMarginallyLeftByRoundingIsNotRejected() {
        // Genuine mid-line adjacency: caret.minX = the previous glyph's trailing edge, next.minX =
        // the following glyph's leading edge from a SEPARATE AX read. Sub-pixel rounding / an
        // overhanging glyph's left bearing can put next.minX a fraction below caret.minX — that's
        // real right-text and must still route to the bubble (the left guard has a tolerance band).
        let caret = GlyphBox(minX: 600, midY: 500, width: 0, height: 18)
        let next = GlyphBox(minX: 599.4, midY: 500, width: 8, height: 18)   // 0.6pt left, within tolerance
        #expect(CaretOverlap.hasTextToRight(caretIndex: 100, valueLength: 200,
                                            caret: caret, next: next) == true)
    }

    // MARK: hasTextToRight — genuine mid-line typing (must still route to bubble)

    @Test func rightTextWhenGenuinelyMidLine() {
        let next = GlyphBox(minX: 660, midY: 500, width: 8, height: 18)   // to the right, same line
        #expect(CaretOverlap.hasTextToRight(caretIndex: 30, valueLength: 200,
                                            caret: Self.caret, next: next) == true)
    }

    @Test func noRightTextWhenNextGlyphIsOnLineBelow() {
        // Apple Notes: char-after-caret is the next paragraph, ~35pt below the caret line.
        let next = GlyphBox(minX: 600, midY: 535, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 30, valueLength: 200,
                                            caret: Self.caret, next: next) == false)
    }

    @Test func noRightTextWhenNoNextGlyph() {
        #expect(CaretOverlap.hasTextToRight(caretIndex: 30, valueLength: 200,
                                            caret: Self.caret, next: nil) == false)
    }

    @Test func noRightTextWhenLengthUnknownButGeometrySaysLeft() {
        // valueLength nil (rich editor that hides it) → geometry guard still rejects the
        // left-of-caret claude.ai glyph.
        let caret = GlyphBox(minX: 594, midY: 500, width: 0, height: 18)
        let next = GlyphBox(minX: 592, midY: 500, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 100, valueLength: nil,
                                            caret: caret, next: next) == false)
    }

    // MARK: hasTextToRight — Electron marker path (nextGeometryReliable: false)

    @Test func midTextWithDeadMarkerGeometryRoutesToBubble() {
        // Claude Desktop repro (captured log): loc=16 < valueLen=27, so NOT end-of-field, yet the
        // marker next-visible scan returns nil (dead on this surface). With the geometry flagged
        // unreliable the index proof (11 chars follow the caret) must force right-text → bubble.
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: 27,
                                            caret: Self.caret, next: nil,
                                            nextGeometryReliable: false) == true)
    }

    @Test func endOfFieldStillInlineEvenWithUnreliableGeometry() {
        // The Slice-1 dominant case: caret at end of compose text. End-of-field short-circuits to
        // false BEFORE the unreliable-geometry fallback → no right-text → inline, unaffected by Option C.
        #expect(CaretOverlap.hasTextToRight(caretIndex: 27, valueLength: 27,
                                            caret: Self.caret, next: nil,
                                            nextGeometryReliable: false) == false)
    }

    @Test func realMarkerNextGlyphStillUsesGeometry() {
        // When the marker scan DID resolve a real box, it's trustworthy — the unreliable flag must not
        // override genuine geometry. Same-line-right → bubble; line-below → not right-text.
        let right = GlyphBox(minX: 660, midY: 500, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: 27,
                                            caret: Self.caret, next: right,
                                            nextGeometryReliable: false) == true)
        let below = GlyphBox(minX: 600, midY: 535, width: 8, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: 27,
                                            caret: Self.caret, next: below,
                                            nextGeometryReliable: false) == false)
    }

    @Test func unreliableGeometryWithUnknownLengthDoesNotForceBubble() {
        // The fallback needs a POSITIVE index proof (caretIndex < valueLength), not merely
        // "isAtEndOfField was false". When the marker surface can't read its char count
        // (valueLength == nil) the caret may genuinely be at end-of-text, so a dead next scan must
        // fall through to geometry → inline, NOT a false-positive bubble (blast-radius review).
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: nil,
                                            caret: Self.caret, next: nil,
                                            nextGeometryReliable: false) == false)
    }

    @Test func reliableDefaultWithNilNextIsUnchanged() {
        // Regression guard: the CFRange default (reliable = true) with a nil next glyph is byte-identical
        // to the pre-Option-C behaviour — no right-text (the marker fallback must NOT leak to CFRange).
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: 27,
                                            caret: Self.caret, next: nil) == false)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 16, valueLength: 27,
                                            caret: Self.caret, next: nil,
                                            nextGeometryReliable: true) == false)
    }

    // MARK: hasTextBelow

    @Test func belowTextWhenNextGlyphOnLineBelow() {
        // Immediately below: one line down for an 18pt line ≈ +20pt (within the ~1.8 line-height bound).
        let next = GlyphBox(minX: 600, midY: 520, width: 8, height: 18)
        #expect(CaretOverlap.hasTextBelow(caretIndex: 30, valueLength: 200,
                                          caret: Self.caret, next: next) == true)
    }

    @Test func noBelowTextAtEndOfField() {
        // End of value: nothing after the caret at all, neither right nor below.
        let next = GlyphBox(minX: 600, midY: 535, width: 8, height: 18)
        #expect(CaretOverlap.hasTextBelow(caretIndex: 42, valueLength: 42,
                                          caret: Self.caret, next: next) == false)
    }

    @Test func noBelowTextWhenNextGlyphIsSameLine() {
        let next = GlyphBox(minX: 660, midY: 500, width: 8, height: 18)
        #expect(CaretOverlap.hasTextBelow(caretIndex: 30, valueLength: 200,
                                          caret: Self.caret, next: next) == false)
    }

    @Test func noBelowTextWhenGlyphManyLinesDown() {
        // Several blank lines down (a later paragraph) poses no wrap-collision risk — bounded to
        // ~1.8 line-heights, mirroring CaretLocator.isBelowLine.
        let next = GlyphBox(minX: 600, midY: 600, width: 8, height: 18)   // ~100pt below ≫ 1.8 lines
        #expect(CaretOverlap.hasTextBelow(caretIndex: 30, valueLength: 200,
                                          caret: Self.caret, next: next) == false)
    }

    @Test func noBelowTextWhenNoNextGlyph() {
        #expect(CaretOverlap.hasTextBelow(caretIndex: 30, valueLength: 200,
                                          caret: Self.caret, next: nil) == false)
    }

    // MARK: Zero-width glyph rejection (mirrors the AX-layer `width > 0.5` filter)

    @Test func zeroWidthNextGlyphCountsAsNothing() {
        let next = GlyphBox(minX: 660, midY: 500, width: 0, height: 18)
        #expect(CaretOverlap.hasTextToRight(caretIndex: 30, valueLength: 200,
                                            caret: Self.caret, next: next) == false)
        #expect(CaretOverlap.hasTextBelow(caretIndex: 30, valueLength: 200,
                                          caret: Self.caret, next: GlyphBox(minX: 600, midY: 535, width: 0, height: 18)) == false)
    }
}
