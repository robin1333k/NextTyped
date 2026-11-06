import Foundation

/// What "the Settings window is in front of the user" means, as a decidable proposition.
///
/// This exists because the proposition — not the AppKit call — is what three consecutive runtime
/// attempts got wrong (`/06`). Each one measured **`NSApp.isActive`** and treated
/// it as the answer, so a run in which the *process* was active while the *window* sat behind another
/// app short-circuited every fallback and logged nothing: a failing open was byte-identical in the log
/// to a succeeding one. Five silent cycles were read as five successes and were not.
///
/// The rule is therefore a conjunction of four independent facts, and lives in Core so it can be
/// pinned by tests rather than re-derived at each call site. Reading the four facts out of AppKit
/// stays in the App (`SettingsView`), which is the untestable half.
public struct WindowFrontingState: Equatable, Sendable {
    /// `NSApplication.isActive` — the *process* holds the foreground.
    public var appIsActive: Bool
    /// `NSWindow.isVisible` — the window is on screen (as opposed to closed or ordered out).
    public var windowIsVisible: Bool
    /// `NSWindow.isKeyWindow` — it receives keyboard input.
    public var windowIsKey: Bool
    /// `NSWindow.occlusionState.contains(.visible)` — at least part of it is on screen. Note the
    /// **at least part**: this is AppKit's power-saving signal, and it stays `true` for a window with
    /// one visible corner. It separates "ordered front inside our own process" from "entirely buried",
    /// and nothing finer. `windowIsAboveOtherApps` is what covers the rest.
    public var windowIsUnoccluded: Bool
    /// No window belonging to **another application** sits above ours in the window server's z-order
    /// (normal-level windows only — the menu bar and the Dock are always above and mean nothing here).
    ///
    /// This fact exists because 2026-08-31's repro is invisible to the four above it: with Claude
    /// Desktop open and a Finder window raised over it, opening Settings put our window **between the
    /// two** — above Claude, still behind Finder. The process was active, the window visible, key, and
    /// partly on screen, so all four facts held and the line read `fronted` while the user was looking
    /// at Finder. A partial cover is the common case of this defect, and the occlusion signal cannot
    /// see it by construction.
    public var windowIsAboveOtherApps: Bool

    public init(
        appIsActive: Bool,
        windowIsVisible: Bool,
        windowIsKey: Bool,
        windowIsUnoccluded: Bool,
        windowIsAboveOtherApps: Bool = true
    ) {
        self.appIsActive = appIsActive
        self.windowIsVisible = windowIsVisible
        self.windowIsKey = windowIsKey
        self.windowIsUnoccluded = windowIsUnoccluded
        self.windowIsAboveOtherApps = windowIsAboveOtherApps
    }
}

/// The verdict on one open attempt. The raw values double as greppable log tokens (the
/// `PrefixReuse.rebuildCause` convention), because the acceptance criterion is
/// that the logged verdict matches what the user sees on a **good** and a **bad** open alike.
public enum WindowFrontingVerdict: String, Equatable, Sendable, CaseIterable {
    /// On screen, unobscured, key, and the app holds the foreground.
    case fronted
    /// Not on screen at all — the open did not produce a window.
    case hidden
    /// On screen but fully covered by another window: the failure the user reports and the one
    /// `NSApp.isActive` cannot see.
    case occluded
    /// Visible and unobscured, but the process never took the foreground.
    case appInactive = "app-inactive"
    /// Visible, unobscured and the app is active, but the window does not take keyboard input.
    case notKey = "not-key"
    /// On screen and not buried, but another application's window is drawn over it. The partial-cover
    /// failure `occluded` cannot express — reported 2026-08-31 as a window sandwiched between Finder
    /// and Claude Desktop.
    case behindAnotherApp = "behind-app"
}

public enum WindowFronting {
    /// Decide whether the window actually reached the front.
    ///
    /// Ordering is by how far short the attempt fell, worst first, so the token names the most
    /// upstream failure rather than an incidental consequence of it: a window that is not visible is
    /// also not key, and reporting `not-key` there would send the next reader after the wrong cause.
    public static func verdict(_ state: WindowFrontingState) -> WindowFrontingVerdict {
        guard state.windowIsVisible else { return .hidden }
        guard state.windowIsUnoccluded else { return .occluded }
        // Before the process-level facts: "another app is drawn over us" is a statement about what the
        // user sees, and it survives `appIsActive` being true — which is the whole reason it is here.
        guard state.windowIsAboveOtherApps else { return .behindAnotherApp }
        guard state.appIsActive else { return .appInactive }
        guard state.windowIsKey else { return .notKey }
        return .fronted
    }

    /// Whether a further activation attempt is warranted.
    ///
    /// Deliberately *not* `!appIsActive`: that guard is the defect this type replaces. Anything short
    /// of `.fronted` warrants escalation — including the `occluded` case, which the old guard let
    /// through as a success.
    public static func needsEscalation(_ state: WindowFrontingState) -> Bool {
        verdict(state) != .fronted
    }
}
