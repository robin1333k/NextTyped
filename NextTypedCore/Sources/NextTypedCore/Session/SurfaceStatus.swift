/// What the last predict run decided about the surface it ran on. The reducer emits one per
/// handled run as `.surfaceVerdict`. Per-caret gates (running thought, word completion, selection, copy
/// guard, value gate) change with every keystroke, so they map to `on`: the status says whether the
/// *field* can show a ghost, not whether this keystroke did.
///
/// Holds no text, no value length and no window title, and the App never writes it to disk.
public enum SurfaceVerdict: Sendable, Equatable {
    case rejected(ContextRejection)
    case temporaryQuiet
    /// `FieldSizeGate` declined the continuation (search and address bars): spelling fixes only.
    case smallField
    /// The context passed but AX gave no caret readout.
    case noCaretGeometry
    case on
}

/// The one line the menu-bar menu shows under the model label. Pure: the App supplies the
/// inputs and the words.
public enum SurfaceStatus: Sendable, Equatable, CaseIterable {
    case paused
    case accessibilityMissing
    case modelNotReady
    case globalOff
    case appOff
    case temporaryQuiet
    case secure
    case chrome
    case noText
    case noCaretGeometry
    case smallField
    case on
    case noTypingYet

    /// The token for the DEBUG `[status]:` line and the snapshot `status` field.
    public var token: String {
        switch self {
        case .paused: return "paused"
        case .accessibilityMissing: return "accessibility-missing"
        case .modelNotReady: return "model-not-ready"
        case .globalOff: return "global-off"
        case .appOff: return "app-off"
        case .temporaryQuiet: return "temporary-quiet"
        case .secure: return "secure"
        case .chrome: return "chrome"
        case .noText: return "no-text"
        case .noCaretGeometry: return "no-caret"
        case .smallField: return "small-field"
        case .on: return "on"
        case .noTypingYet: return "no-typing-yet"
        }
    }

    /// Order: paused, Accessibility missing, model not ready, globally off, app off, temporary quiet,
    /// secure field, window chrome, no text from this app, no caret position, small field, on, no
    /// typing yet. The first three come from the app's own state and win over any verdict.
    /// A `nil` verdict, and a `noFocus` rejection, read as "no typing yet".
    public static func compose(
        paused: Bool,
        accessibilityGranted: Bool,
        modelReady: Bool,
        lastVerdict: SurfaceVerdict?
    ) -> SurfaceStatus {
        if paused { return .paused }
        if !accessibilityGranted { return .accessibilityMissing }
        if !modelReady { return .modelNotReady }
        guard let lastVerdict else { return .noTypingYet }
        switch lastVerdict {
        case .rejected(.globalOff): return .globalOff
        case .rejected(.appOff): return .appOff
        case .temporaryQuiet: return .temporaryQuiet
        case .rejected(.secure): return .secure
        case .rejected(.chrome): return .chrome
        case .rejected(.noText): return .noText
        case .rejected(.noFocus): return .noTypingYet
        case .noCaretGeometry: return .noCaretGeometry
        case .smallField: return .smallField
        case .on: return .on
        }
    }
}
