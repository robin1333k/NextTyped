import AppKit
import NextTypedCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global pause/resume toggle. Ships **unassigned**
    /// (no default key) so it can't collide with a common app shortcut; the user records one in
    /// Settings → General. When fired it toggles the same `AppCoordinator.isPaused` the menu-bar item
    /// does, so pause flows through the one `SuggestionSession` pause event — no new pause
    /// semantics.
    static let togglePause = Self("togglePause")
}

extension KeyboardShortcuts.Name {
    /// **Force a suggestion here**. Ships
    /// **unassigned**, and that is the conservative call this key specifically needs: it is the one
    /// shortcut with no ghost-visible gate — it must fire precisely when nothing is showing, so
    /// whatever key it takes is swallowed permanently, in every app. With the scope narrowed to
    /// "override our own gates, never the app's on/off state", the remaining value sits in a few
    /// surfaces, so discoverability matters less than not taking a key from everyone.
    static let forceActivate = Self("forceActivate")

    /// **Quiet the app I am writing in** for `TemporaryQuietDuration.hotkeyDefault` (decision 3).
    /// Ships unassigned like the two above. A key cannot carry a duration, so the menu is where one is
    /// actually chosen; pressing it again resumes, which is the *explicit* half of decision 3c.
    static let temporaryQuiet = Self("temporaryQuiet")
}

// MARK: Bridging to Core's `KeyChord`

extension KeyModifiers {
    /// The modifiers of an AppKit event or a `KeyboardShortcuts.Shortcut`, ignoring Caps Lock and fn.
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.shift) { insert(.shift) }
    }
}

extension KeyChord {
    /// The chord a global shortcut holds, so the intercept bindings can refuse a collision with it.
    init(shortcut: KeyboardShortcuts.Shortcut) {
        self.init(keyCode: shortcut.carbonKeyCode, modifiers: KeyModifiers(shortcut.modifiers))
    }

    /// The chord as the Shortcuts pane shows it. Keys Core does not name (letters, punctuation) are
    /// read from the current keyboard layout through `KeyboardShortcuts`.
    @MainActor var label: String {
        MainActor.assumeIsolated {
            displayName { keyCode in KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode).description }
        }
    }
}
