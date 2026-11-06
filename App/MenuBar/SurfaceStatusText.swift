import NextTypedCore

/// The words for `SurfaceStatus`. UI text lives in the App, not in Core (the
/// `CompletionLength` precedent). One line each, with the app's display name where the line is about it.
enum SurfaceStatusText {
    static func line(for status: SurfaceStatus, appName: String?) -> String {
        let app = appName ?? "this app"
        switch status {
        case .paused: return "Paused"
        case .accessibilityMissing: return "Needs Accessibility permission"
        case .modelNotReady: return "Waiting for the model"
        case .globalOff: return "Turned off in Settings"
        case .appOff: return "Off in \(app)"
        case .temporaryQuiet: return "Paused in \(app)"
        case .secure: return "Password field, never read"
        case .chrome: return "Not a text field"
        case .noText: return "\(app) does not share its text"
        case .noCaretGeometry: return "\(app) does not report the caret position"
        case .smallField: return "Search and address bars get spelling fixes only"
        case .on: return "On in \(app)"
        case .noTypingYet: return "Start typing in a text field"
        }
    }
}
