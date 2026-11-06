import SwiftUI

/// A key chip such as `⌥Tab`, in the look of a menu key equivalent: body text on a quaternary rounded fill.
struct KeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.body)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        // No `.accessibilityLabel` here: the Text already reads as its own string. On a Text
        // inside a `LabeledContent` (Shortcuts pane, `FixedShortcutRow`) that modifier made SwiftUI's
        // label resolution recurse between the row and the chip until the main thread's stack
        // overflowed, and the app crashed on the first accessibility read of the pane.
    }
}
