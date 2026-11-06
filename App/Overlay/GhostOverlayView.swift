import AppKit

/// Draws the overlay content:
///  - `.continuation`: gray ghost text after the caret (inline), or readable text inside
///    a rounded bubble when there's no inline room.
///  - `.correction`: only the WRONG remainder of the word gets a red strikethrough line.
///    Inline, the wrong letters are invisible (just the line over the host's own text);
///    in a bubble (nothing behind it) they're drawn red so the strike is visible.
/// Background is fully transparent except the bubble's chip.
final class GhostOverlayView: NSView {
    enum Presentation: Equatable {
        case none
        case continuation(text: String)
        case correction(original: String, replacement: String)
    }

    var presentation: Presentation = .none {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var matchedFont: NSFont = .systemFont(ofSize: 13) {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    /// When true, paint inside a rounded chip with padding (the below/above-line bubble).
    var isBubble = false {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    /// Wrap the text within this width (the text content width). nil = single line.
    var maxTextWidth: CGFloat? {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    /// Indent of the first wrapped line (inline-wrapped continuation starts at the caret;
    /// subsequent lines wrap back to the panel's left = the document's left margin).
    var firstLineIndent: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    private let bubblePadding = NSSize(width: 8, height: 4)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    private func baseString() -> NSAttributedString {
        switch presentation {
        case .none:
            return NSAttributedString(string: "")

        case .continuation(let text):
            // In the bubble the text sits on a solid chip → fully opaque, drop the leading
            // space the engine emits; inline stays faint ghost gray.
            let shown = isBubble ? String(text.drop(while: { $0 == " " })) : text
            let color = isBubble
                ? NSColor.secondaryLabelColor
                : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
            return NSAttributedString(string: shown, attributes: [
                .font: matchedFont,
                .foregroundColor: color,
            ])

        case .correction(let original, let replacement):
            // Keep the common prefix (already correct in the host) and strike ONLY the
            // wrong remainder. Inline: prefix + wrong are invisible spacers so the host's
            // own letters show, with just a red strikethrough line over the wrong ones —
            // no red duplicate letters. Bubble: everything is drawn (nothing behind it).
            let prefix = original.commonPrefix(with: replacement)
            let wrong = String(original.dropFirst(prefix.count))
            let fixed = String(replacement.dropFirst(prefix.count))

            let result = NSMutableAttributedString()
            if !prefix.isEmpty {
                result.append(NSAttributedString(string: prefix, attributes: [
                    .font: matchedFont,
                    .foregroundColor: isBubble ? NSColor.secondaryLabelColor : NSColor.clear,
                ]))
            }
            if !wrong.isEmpty {
                result.append(NSAttributedString(string: wrong, attributes: [
                    .font: matchedFont,
                    .foregroundColor: isBubble ? NSColor.systemRed : NSColor.clear,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.systemRed,
                ]))
            }
            if !fixed.isEmpty {
                result.append(NSAttributedString(string: (wrong.isEmpty ? "" : " ") + fixed, attributes: [
                    .font: matchedFont,
                    .foregroundColor: NSColor.systemGreen,
                ]))
            }
            return result
        }
    }

    private func attributedString() -> NSAttributedString {
        let base = baseString()
        guard maxTextWidth != nil else { return base }
        let m = NSMutableAttributedString(attributedString: base)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.firstLineHeadIndent = firstLineIndent
        m.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: m.length))
        return m
    }

    override var intrinsicContentSize: NSSize {
        let str = attributedString()
        if let maxW = maxTextWidth {
            let rect = str.boundingRect(with: NSSize(width: maxW, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(rect.height)
            if isBubble {
                // Bubble sizes to its content (capped at maxW) + padding.
                return NSSize(width: ceil(rect.width) + 2 + bubblePadding.width * 2,
                              height: h + bubblePadding.height * 2)
            }
            // Inline-wrapped: the panel spans the full wrap width.
            return NSSize(width: ceil(maxW), height: h)
        }
        let size = str.size()
        let w = ceil(size.width) + 2
        let h = ceil(size.height)
        if isBubble {
            return NSSize(width: w + bubblePadding.width * 2, height: h + bubblePadding.height * 2)
        }
        return NSSize(width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        let str = attributedString()
        guard str.length > 0 else { return }
        if isBubble {
            // Rounded chip: solid-ish background + hairline border so it reads as a
            // deliberate suggestion bubble, not faux-inline text.
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let radius = min(8, rect.height / 2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            NSColor.controlBackgroundColor.withAlphaComponent(0.98).setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.separatorColor.setStroke()
            path.stroke()
            let textRect = NSRect(x: bubblePadding.width, y: bubblePadding.height,
                                  width: bounds.width - bubblePadding.width * 2,
                                  height: bounds.height - bubblePadding.height * 2)
            str.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return
        }
        if maxTextWidth != nil {
            // Inline-wrapped: draw into the full panel; firstLineHeadIndent offsets line 1.
            str.draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
            return
        }
        // Single-line inline. Top-aligned: the panel's line-box top is aligned to the
        // caret's line top by the controller, so the matched font lands on the baseline.
        str.draw(at: .zero)
    }
}
