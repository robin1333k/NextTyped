/// Decides whether the caret's paragraph contains right-to-left text (the right-to-left guard).
///
/// The overlay paints the ghost to the right of the caret and strikes corrections from left-to-right
/// glyph advances. In a Hebrew or Arabic line the end of the typed text is on the left of the caret's
/// visual neighbours, so the ghost lands on top of the typed words. Full right-to-left presentation
/// has no spec; the guard suppresses the whole suggestion instead.
///
/// Fail-closed: a paragraph with one strong right-to-left scalar counts, however much Latin text
/// surrounds it, because the host's base direction is not visible to us.
public enum WritingDirection {
    /// - Parameters:
    ///   - before: the text before the caret; the paragraph starts after its last newline.
    ///   - after: the text after the caret; the paragraph ends at its first newline.
    public static func paragraphContainsRightToLeft(before: String, after: String) -> Bool {
        // Character.isNewline covers LF, CR, CRLF (one Character), U+2028 and U+2029.
        let head = before[(before.lastIndex(where: \.isNewline).map { before.index(after: $0) } ?? before.startIndex)...]
        let tail = after[..<(after.firstIndex(where: \.isNewline) ?? after.endIndex)]
        return head.unicodeScalars.contains(where: isStrongRightToLeft)
            || tail.unicodeScalars.contains(where: isStrongRightToLeft)
    }

    public static func paragraphContainsRightToLeft(in context: TypingContext) -> Bool {
        paragraphContainsRightToLeft(before: context.textBeforeCaret, after: context.textAfterCaret)
    }

    /// Hebrew, Arabic (with supplement and extended-A), Syriac, Thaana, NKo, and the presentation forms.
    static func isStrongRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF, 0x0600...0x06FF, 0x0700...0x074F, 0x0750...0x077F,
             0x0780...0x07BF, 0x07C0...0x07FF, 0x08A0...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }
}
