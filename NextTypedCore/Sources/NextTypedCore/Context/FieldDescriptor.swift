import Foundation

/// A pure-Core description of the focused text field, harvested by the Accessibility layer and
/// carried across the App→Core seam on `TypingContext`. Holds the two signals the `FieldSizeGate`
/// keys on: the AX **role/subrole** (the field's semantic kind) and its **size** (geometry).
///
/// Pure by construction — Core never imports ApplicationServices/AppKit, so it cannot reference the
/// `kAX…` role constants or `CGSize`. The role/subrole are therefore plain AX role *strings*
/// (e.g. `"AXTextField"`, `"AXTextArea"`, `"AXSearchField"`) and the size is two `Double`s in points,
/// translated by the App-side `AXContextProvider`.
public struct FieldDescriptor: Equatable, Sendable {
    /// AX role of the focused element, e.g. `"AXTextField"` (single-line) or `"AXTextArea"`
    /// (multi-line). `nil` when AX exposes none.
    public var role: String?

    /// AX subrole, e.g. `"AXSearchField"`. `nil` when AX exposes none.
    public var subrole: String?

    /// Focused element width in points. The other half of the AX size — carried across the seam
    /// for future per-field policies; the current `FieldSizeGate` discriminates single- vs
    /// multi-line by `height`. `nil` when AX exposes no size.
    public var width: Double?

    /// Focused element height in points — the single-line signal the `FieldSizeGate` falls back to
    /// when the role is ambiguous. `nil` when AX exposes no size.
    public var height: Double?

    public init(
        role: String? = nil,
        subrole: String? = nil,
        width: Double? = nil,
        height: Double? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.width = width
        self.height = height
    }
}
