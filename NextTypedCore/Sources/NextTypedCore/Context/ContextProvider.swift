/// Why a surface produced no `TypingContext`. Typed so the reducer can log it as a
/// `[gate]: no-context reason=<token>` line and the menu bar can say it in words.
///
/// `appOff` and `globalOff` come from the enablement verdict (`EnablementVerdict.rejection`); the other
/// four are decided by the `ContextProvider` at the earliest trust boundary. None of the cases carries
/// text, a value length or a window title.
public enum ContextRejection: String, Sendable, Equatable, CaseIterable {
    /// AX reports no focused UI element.
    case noFocus = "no-focus"
    /// A secure (password) field. Decided by `isSecure` before any value read.
    case secure
    /// A focused window-chrome control (button, checkbox, menu...).
    case chrome
    /// A focused element with no AX value: the app shares no text (Mail's WebKit compose body).
    case noText = "no-text"
    /// The app is switched off (per-app override, blocklist or default-off mode).
    case appOff = "app-off"
    /// The master switch is off (`globallyEnabled == false`).
    case globalOff = "global-off"
}

/// The provider's answer: a context, or the typed reason there is none.
public enum ContextOutcome: Sendable, Equatable {
    case context(TypingContext)
    case rejected(ContextRejection)
}

/// The pluggable seam through which typing context is gathered. Keep this seam clean. The AX-based provider is v1; the
/// OCR fallback and future personalization slot in here WITHOUT a rewrite.
public protocol ContextProvider: Sendable {
    /// Gather the current typing context, or the reason none is usable — e.g. a
    /// secure/password field (never read), or an app that exposes no text via AX.
    func currentContext() async -> ContextOutcome
}
