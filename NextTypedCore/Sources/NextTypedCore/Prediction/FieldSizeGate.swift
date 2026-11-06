/// Decides whether a continuation may be generated for the focused field, based on its
/// **kind and size** — the third *cold-start* sibling to the `CaretPositionGate` and the
/// minimum-context gate.
///
/// The rule: suppress in a **small single-line input** (a search box, a single-line text field,
/// an address/URL bar) where a multi-word ghost is rarely wanted and mostly noise; allow in a
/// large multi-line editor (a TextEdit document). "Single-line" is read primarily from the AX
/// **role/subrole**, with field **height** as the geometry fallback when the role is ambiguous:
///
///   - subrole `AXSearchField`           → small  → suppress
///   - role    `AXTextField`             → single-line → suppress
///   - role    `AXComboBox`              → single-line search/URL combo → suppress (e.g. Google's box)
///   - role    `AXTextArea`              → multi-line  → allow  (e.g. the TextEdit document)
///   - unknown role + height ≤ threshold → single-line → suppress
///   - unknown role + tall / no size     → allow (never suppress an editor we can't classify)
///
/// Conservative by design: a false negative (a stray ghost in a search box) is cheaper than a
/// false positive (no ghost in a real editor), so the geometry fallback only *suppresses*, and an
/// explicit multi-line `AXTextArea` is never overridden by size.
///
/// Pure Core: the role/subrole are matched against plain AX role *strings* (Core can't import the
/// ApplicationServices `kAX…` constants), and size is a `Double` in points. No AppKit/AX here.
public enum FieldSizeGate {
    /// AX role string for a single-line text field (`kAXTextFieldRole`).
    static let textFieldRole = "AXTextField"
    /// AX role string for a multi-line text area (`kAXTextAreaRole`).
    static let textAreaRole = "AXTextArea"
    /// AX subrole string for a search field (`kAXSearchFieldSubrole`).
    static let searchFieldSubrole = "AXSearchField"
    /// AX role string for a combo box — a single-line search/address control that pairs a text field
    /// with a popup (e.g. Google's search box, the Safari omnibox). `kAXComboBoxRole`.
    static let comboBoxRole = "AXComboBox"

    /// A field at or below this height (points) is treated as single-line when the role is
    /// ambiguous. A single text line is ~17–22 pt; a padded single-line field ~22–40 pt; a
    /// multi-line editor is taller. Used ONLY by the geometry fallback, and only to suppress.
    static let singleLineMaxHeight: Double = 44

    /// - Parameters:
    ///   - role: the focused element's AX role, or `nil` if AX exposes none.
    ///   - subrole: the focused element's AX subrole, or `nil`.
    ///   - height: the focused element's height in points, or `nil` if AX exposes no size.
    /// - Returns: `true` if a continuation may be generated for a field of this kind/size.
    public static func allowsContinuation(role: String?, subrole: String?, height: Double?) -> Bool {
        // A search field is always a small single-line input.
        if subrole == searchFieldSubrole { return false }
        // AX convention: AXTextField is single-line, AXTextArea is multi-line. A combo box is a
        // single-line search/address control (Google's box, the Safari omnibox).
        if role == textFieldRole { return false }
        if role == comboBoxRole { return false }
        if role == textAreaRole { return true }
        // Ambiguous/unknown role → fall back to geometry: a short box is single-line.
        // Unknown size → allow (never suppress an editor we can't classify).
        if let height, height <= singleLineMaxHeight { return false }
        return true
    }

    /// Convenience over a `TypingContext`: reads the field role/subrole + height from
    /// `context.field`. No descriptor (AX exposed nothing) → allowed, so the gate never
    /// suppresses on missing data.
    public static func allowsContinuation(in context: TypingContext) -> Bool {
        guard let field = context.field else { return true }
        return allowsContinuation(role: field.role, subrole: field.subrole, height: field.height)
    }
}
