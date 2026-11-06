import AppKit
@preconcurrency import CoreGraphics

/// Tag stamped on events we post so our own event tap can ignore them (otherwise
/// inserting text would feed back into the loop).
enum SyntheticEvent {
    static let magic: Int64 = 0x4143_4F4D   // "ACOM"
}

/// Inserts accepted text via **synthetic Unicode key events** so the host app's own
/// text engine handles undo/cursor natively.
/// NEVER uses AX `setValue` — that replaces the whole field.
@MainActor
final class KeyEventSynthesizer {
    /// Type `text` at the caret.
    func insert(_ text: String) {
        guard !text.isEmpty, let source = CGEventSource(stateID: .privateState) else { return }
        let utf16 = Array(text.utf16)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.magic)
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Replace the `count` characters before the caret with `replacement`
    /// (applies a spelling correction): delete back, then insert the fix.
    func replace(charactersBack count: Int, with replacement: String) {
        guard count > 0, let source = CGEventSource(stateID: .privateState) else { return }
        let deleteKey: CGKeyCode = 51   // Delete / Backspace
        for _ in 0..<count {
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: keyDown) else { continue }
                event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvent.magic)
                event.post(tap: .cgSessionEventTap)
            }
        }
        insert(replacement)
    }
}
