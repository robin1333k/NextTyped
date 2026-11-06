/// A keyDown's suggestion-relevant intent, decided purely from the virtual keycode + modifier flags
/// (no AppKit). The App layer (`EventTapController`) maps this onto its `TapEvent` and, for the `nil`
/// fall-through, reads the typed character string and decides printability itself.
public enum KeyCommand: Equatable, Sendable {
    /// ⌘⇧3 / ⌘⇧4 / ⌘⇧5 — arm a brief window so the capture-selection drag doesn't dismiss the ghost.
    case screenshotShortcut
    /// Any other ⌘/⌃ combo — leave the suggestion untouched (incl. ⌘⌫ / ⌃⌫; ⌥ is excluded because
    /// ⌥+key usually produces a real typed character).
    case modifierShortcut
    /// The accept-word binding (default Tab) — accept the next continuation word (or apply a
    /// pending correction; precedence in Core).
    case acceptWord
    /// ⌥Tab — accept the WHOLE continuation buffer.
    /// Deliberately not `→`, the key Core's accept-all was originally sketched for: `→` is the most-used
    /// navigation key and would be swallowed in exactly the state that occurs constantly — whenever a
    /// ghost is up. ⌥Tab sits in the same finger region as the primary action, one step further, and does not
    /// depend on the layout. The key *above* Tab would, since on a German layout it is the dead key `^`.
    case acceptAll
    /// The dismiss binding (default Esc) — explicit dismiss + mute proactive regen.
    case dismiss
    /// The caret is about to move or text is about to shrink under the ghost: keyboard navigation
    /// (↑↓ / Home / End / Page / Return / ←→, incl. their ⌘/⌃/⇧ word-, line- and document-jump variants)
    /// **and** deletes (backspace / forward-delete). Both hide the stale ghost and regenerate at the new
    /// caret (deletes and ⌘/⌃-navigation included).
    case caretMove
}

/// Pure routing for a keyDown's suggestion intent, lifted out of `EventTapController.classify` so it is
/// unit-testable (the App layer keeps only the AppKit-bound `CGEvent`/`NSEvent` reads).
public enum KeyClassifier {
    // Virtual keycodes (Carbon `kVK_*`), kept here so the routing is self-describing and testable.
    private enum Key {
        static let delete = 51          // kVK_Delete — backspace, the key above Return
        static let forwardDelete = 117  // kVK_ForwardDelete — fn+Delete
        static let tab = 48             // kVK_Tab — only routed here once the user rebinds it away
        static let returns: Set<Int> = [36, 76]   // Return, keypad Enter
        // Pure navigation: ↓ ↑, Home, End, Page Up/Down, ← →, plus the two Return keys.
        static let navigation: Set<Int> = Set([125, 126, 115, 119, 116, 121, 123, 124]).union(returns)
        // The navigation keys that also move the caret when combined with ⌘/⌃ (word/line/document
        // jumps: ⌘←/⌘→/⌘↑/⌘↓, ⌃A/⌃E-style, Home/End/Page). Deliberately EXCLUDES Return/keypad Enter:
        // ⌘Return is a *send* accelerator in chat apps, not a caret move.
        static let modifiedNavigation: Set<Int> = navigation.subtracting(returns)
        // Screenshot capture shortcuts (with ⌘⇧): full screen / selection / capture UI.
        static let screenshot: Set<Int> = [20, 21, 23]
        // ⌘A — select all. It moves nothing, but it changes the selection, and a selection is the one
        // state in which the ghost must not stand. Routed as a caret
        // move so the loop re-reads the context; the `SelectionGate` then suppresses ahead of any
        // inference, so the re-read is free.
        static let selectAll = 0   // kVK_ANSI_A
    }

    /// Classify a keyDown by keycode + modifiers. Returns `nil` when the key is a *candidate typed
    /// character* — the App then produces the character string and decides whether it is printable
    /// (so emoji/CJK keep working) or should be ignored.
    ///
    /// Order matters and mirrors the prior App logic exactly: the screenshot combo is recognised
    /// *before* the generic ⌘/⌃ catch-all, so ⌘⇧3 arms the screenshot rather than being left alone.
    /// `option` is read for **Tab only**: it is what separates accept-word from accept-all
    /// . Before this parameter existed the accept branch tested `keyCode == Key.tab`
    /// alone, so ⌥Tab and ⇧Tab were *already* accept-word and the new shortcut would have been
    /// indistinguishable from the old one. Everywhere else ⌥+key usually produces a real typed
    /// character, so option keeps falling through to the printability check in the App.
    ///
    /// The three intercept keys come from `bindings` and are
    /// checked right after the screenshot combo, ahead of the ⌘/⌃ catch-all, so a user chord such as
    /// ⌃K is reached. `InterceptBindings` refuses chords that move the caret, type a character or
    /// belong to macOS, so a binding never shadows one of the branches below.
    public static func classifyKeyDown(keyCode: Int, command: Bool, control: Bool, shift: Bool,
                                       option: Bool,
                                       bindings: InterceptBindings = .defaults,
                                       characters: String? = nil) -> KeyCommand? {
        if command, shift, Key.screenshot.contains(keyCode) { return .screenshotShortcut }
        var modifiers: KeyModifiers = []
        if command { modifiers.insert(.command) }
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        switch bindings.action(for: KeyChord(keyCode: keyCode, modifiers: modifiers)) {
        case .acceptWord: return .acceptWord
        case .acceptAll: return .acceptAll
        case .dismiss: return .dismiss
        case nil: break
        }
        // ⌘Z / ⌘⇧Z change the host text under the ghost, so they hide and regenerate like a delete
        // . Recognised by CHARACTER: on a German layout the key labelled Z sends
        // `kVK_ANSI_Y`, so a keycode test would fire on ⌘Y and miss undo. Checked after the bindings,
        // so a user chord keeps its bound meaning.
        if isUndoOrRedo(command: command, control: control, option: option, characters: characters) {
            return .caretMove
        }
        // ⌘/⌃ + a navigation key still MOVES THE CARET (word/line/document jump), so it must hide +
        // regenerate the ghost like a plain arrow does — checked before the generic ⌘/⌃ catch-all, which
        // used to swallow it and leave the ghost frozen at its old position (
        // host-independent — confirmed in TextEdit by the runtime harness). ⇧-selection variants are
        // included: a selection change moves the insertion point. ⌘⌫ / ⌃⌫ are deliberately NOT here —
        // delete-with-modifier semantics stay `.modifierShortcut` (out of scope), and neither is Return.
        if command || control {
            if Key.modifiedNavigation.contains(keyCode) { return .caretMove }
            // ⌘A/⌃A-with-⌘ select-all: the caret does not move but the *selection* does, and a ghost
            // over a selection continues a text the next keystroke replaces. `.caretMove` is the
            // cheapest correct route — hide now, re-read, and let the `SelectionGate` refuse the
            // continuation before any inference is scheduled.
            // Deliberately `command`-only: bare ⌃A is the Emacs beginning-of-line binding, which is
            // already covered as navigation on the hosts that honour it, and is NOT a selection.
            if command, keyCode == Key.selectAll { return .caretMove }
            return .modifierShortcut
        }

        // Tab, ⌥Tab and Esc are no longer special here: as defaults they matched `bindings` above
        // (⇧Tab through the ⇧ fallback). A Tab the user moved elsewhere still reaches the host, which
        // inserts a tab or moves focus, so it hides and regenerates like any caret move;
        // as `.ignore` it would leave the ghost standing at the old caret. An unbound Esc moves
        // nothing and falls through to the App's printability check, which ignores it.
        if keyCode == Key.tab { return .caretMove }
        // Deletes shrink the text under the ghost, so they regenerate at the retreating caret just like
        // navigation does — instead of falling through to be misread as a typed character (backspace's
        // `\u{7F}`) or as `.ignore` (forward-delete's `0xF728`).
        if keyCode == Key.delete || keyCode == Key.forwardDelete { return .caretMove }
        if Key.navigation.contains(keyCode) { return .caretMove }

        return nil   // candidate typed character — the App reads the string and decides printability
    }

    /// Which text a delete keyDown removes, or `nil` if this key deletes nothing. Orthogonal to
    /// `classifyKeyDown` (where both deletes and navigation are `.caretMove`, since both hide + regenerate
    /// the ghost): the own-inserted capture buffer needs the *deletion* distinction so it can shrink with
    /// the text instead of committing characters the user removed.
    /// Whether this keyDown ends a line. Return is a `.caretMove` for the suggestion loop (it never types
    /// a character), but the own-inserted capture buffer must record the **break**: without it two
    /// separate lines are concatenated into one run (`"…gut" + "Heute…"` → `"gutHeute"`), which both
    /// fabricates a nonexistent characteristic term and destroys the only boundary that can segment
    /// unpunctuated lines and bullet lists.
    public static func insertsLineBreak(keyCode: Int) -> Bool {
        Key.returns.contains(keyCode)
    }

    /// Whether this chord is undo or redo: ⌘ plus the character `z` in either case (with or without ⇧),
    /// without ⌃ or ⌥. `characters` is `charactersIgnoringModifiers` from the App; `nil` never matches.
    public static func isUndoOrRedo(command: Bool, control: Bool, option: Bool,
                                    characters: String?) -> Bool {
        command && !control && !option && characters?.lowercased() == "z"
    }

    public static func deletion(keyCode: Int, option: Bool, command: Bool = false, control: Bool = false,
                                characters: String? = nil) -> TextDeletion? {
        if isUndoOrRedo(command: command, control: control, option: option, characters: characters) {
            return .undone
        }
        switch keyCode {
        case Key.delete:        return option ? .backwardWord : .backward
        case Key.forwardDelete: return .forward
        default:                return nil
        }
    }
}
