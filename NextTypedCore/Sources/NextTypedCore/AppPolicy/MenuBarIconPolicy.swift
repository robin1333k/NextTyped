/// Whether the menu bar icon is in the menu bar (`menu-bar-shell`).
///
/// The user may hide the icon. Two states make that unsafe, because the icon's menu is the only place
/// that offers the fix: Accessibility is missing (the loop cannot start) and the model load has failed
/// (the menu's "Retry model download"). While either holds, the icon shows whatever the user chose.
///
/// A blocking host notice is an input, without a badge. A setup hint or the why-no-ghost line is **not**. Those notices live in the open menu only,
/// so they neither add a badge nor bring a hidden icon back.
public enum MenuBarIconPolicy {
    /// Why a hidden icon is shown anyway. Its raw value is the `reason=` text of the `[menubar]` log line.
    public enum AttentionReason: String, Sendable, Equatable {
        case accessibility
        case modelFailed = "model-failed"
        /// A blocking `HostNotice` (Secure Input, tap leak) is active; the line is in the menu only.
        case hostNotice = "host-notice"
    }

    /// The first reason that applies, Accessibility before the model because without it nothing runs.
    public static func attentionReason(accessibilityMissing: Bool, modelFailed: Bool,
                                       blockingHostNotice: Bool = false) -> AttentionReason? {
        if accessibilityMissing { return .accessibility }
        if modelFailed { return .modelFailed }
        if blockingHostNotice { return .hostNotice }
        return nil
    }

    public static func isInserted(userWantsIcon: Bool, needsAttention: Bool) -> Bool {
        userWantsIcon || needsAttention
    }
}
