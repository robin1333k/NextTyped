import Foundation

/// The modifier keys a `KeyChord` holds. Our own type, so Core stays free of AppKit's
/// `NSEvent.ModifierFlags` and CoreGraphics' `CGEventFlags`; the App maps both onto it.
public struct KeyModifiers: OptionSet, Hashable, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)
}

/// One key plus its modifiers, by Carbon virtual keycode (`kVK_*`), so a binding means the same
/// physical key on every keyboard layout.
public struct KeyChord: Hashable, Sendable, Codable {
    public let keyCode: Int
    public let modifiers: KeyModifiers

    public init(keyCode: Int, modifiers: KeyModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The chord as macOS menus write it: modifier symbols in the order ⌃⌥⇧⌘, then the key. Core
    /// names the keys it knows (Tab, Esc, Space, the function keys); any other key's label depends on
    /// the keyboard layout, so the App passes `keyName` to read it from the layout.
    public func displayName(keyName: (Int) -> String? = { _ in nil }) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "\u{2303}" }
        if modifiers.contains(.option) { symbols += "\u{2325}" }
        if modifiers.contains(.shift) { symbols += "\u{21E7}" }
        if modifiers.contains(.command) { symbols += "\u{2318}" }
        let key = KeyCodes.knownName(keyCode) ?? keyName(keyCode) ?? "Key \(keyCode)"
        return symbols + key
    }
}

/// The three keys the event tap may take while a ghost shows.
public enum InterceptAction: String, CaseIterable, Sendable, Codable {
    case acceptWord
    case acceptAll
    case dismiss
}

/// Why a chord cannot become an intercept binding. Each case names a key the user would lose.
public enum BindingRefusal: Error, Equatable, Sendable {
    /// Another of the three intercept actions already has this chord.
    case collides(with: InterceptAction)
    /// One of our global shortcuts (pause, force-activate, temporary quiet) already has this chord.
    case collidesWithGlobalShortcut
    /// The chord produces text (a letter, Space, ⌥+letter). Taking it while a ghost shows would
    /// swallow the character exactly when the user types along the ghost.
    case typesCharacter
    /// The chord moves the caret or deletes text (arrows, Return, Delete), which the loop needs as a
    /// caret move.
    case movesCaret
    /// macOS or the loop already owns the chord: ⌘Tab, ⌘Space, ⌃Space, ⌘⇧3/4/5, ⌘A.
    case systemShortcut
}

/// The user's chord for each intercept action, with our keys as defaults: `Tab` accepts a word,
/// `⌥Tab` the whole completion, `Esc` dismisses. Rebinding goes through `rebinding`, which
/// refuses a chord another action, a global shortcut, typing or navigation already needs, so the
/// stored value never holds a collision.
public struct InterceptBindings: Equatable, Sendable, Codable {
    public private(set) var acceptWord: KeyChord
    public private(set) var acceptAll: KeyChord
    public private(set) var dismiss: KeyChord

    public static let defaults = InterceptBindings(
        acceptWord: KeyChord(keyCode: KeyCodes.tab),
        acceptAll: KeyChord(keyCode: KeyCodes.tab, modifiers: .option),
        dismiss: KeyChord(keyCode: KeyCodes.escape))

    private init(acceptWord: KeyChord, acceptAll: KeyChord, dismiss: KeyChord) {
        self.acceptWord = acceptWord
        self.acceptAll = acceptAll
        self.dismiss = dismiss
    }

    public subscript(action: InterceptAction) -> KeyChord {
        switch action {
        case .acceptWord: return acceptWord
        case .acceptAll: return acceptAll
        case .dismiss: return dismiss
        }
    }

    /// The action this chord triggers. An exact match wins; otherwise ⇧ is ignored, so ⇧Tab keeps the
    /// accept-word meaning it had before bindings existed, unless the user bound a ⇧ chord itself.
    public func action(for chord: KeyChord) -> InterceptAction? {
        if let exact = InterceptAction.allCases.first(where: { self[$0] == chord }) { return exact }
        guard chord.modifiers.contains(.shift) else { return nil }
        let unshifted = KeyChord(keyCode: chord.keyCode, modifiers: chord.modifiers.subtracting(.shift))
        return InterceptAction.allCases.first(where: { self[$0] == unshifted })
    }

    /// These bindings with `action` moved to `chord`, or the reason the chord is refused.
    /// `globalShortcuts` are the chords our `KeyboardShortcuts` registrations hold right now.
    public func rebinding(_ action: InterceptAction, to chord: KeyChord,
                          globalShortcuts: [KeyChord] = []) -> Result<InterceptBindings, BindingRefusal> {
        if let refusal = Self.intrinsicRefusal(chord) { return .failure(refusal) }
        if let other = InterceptAction.allCases.first(where: { $0 != action && self[$0] == chord }) {
            return .failure(.collides(with: other))
        }
        var next = self
        switch action {
        case .acceptWord: next.acceptWord = chord
        case .acceptAll: next.acceptAll = chord
        case .dismiss: next.dismiss = chord
        }
        // Compare through `action(for:)`, not by equality: the ⇧ fallback means ⌃K also takes ⌃⇧K while
        // a ghost shows, so a global on ⌃⇧K would be swallowed.
        if globalShortcuts.contains(where: { next.action(for: $0) == action }) {
            return .failure(.collidesWithGlobalShortcut)
        }
        return .success(next)
    }

    /// Whether a global shortcut may take `chord` while these bindings hold. The other half of the
    /// collision rule: the Shortcuts pane refuses a global recording that lands on an intercept key,
    /// including the ⇧ variant `action(for:)` matches (⇧Tab is accept word under the defaults).
    public func collidesWithIntercept(_ chord: KeyChord) -> InterceptAction? {
        action(for: chord)
    }

    /// Bindings read back from storage. Missing, unreadable or colliding data yields the defaults, so a
    /// hand-edited `defaults` value can never leave two actions on one key.
    public static func restored(from data: Data?) -> InterceptBindings {
        guard let data, let decoded = try? JSONDecoder().decode(InterceptBindings.self, from: data) else {
            return .defaults
        }
        let chords = InterceptAction.allCases.map { decoded[$0] }
        guard Set(chords).count == chords.count,
              chords.allSatisfy({ intrinsicRefusal($0) == nil }) else { return .defaults }
        return decoded
    }

    /// The refusals that hold for a chord regardless of the other bindings.
    private static func intrinsicRefusal(_ chord: KeyChord) -> BindingRefusal? {
        let m = chord.modifiers
        let key = chord.keyCode
        if KeyCodes.caretMoving.contains(key) { return .movesCaret }
        if m.contains(.command), key == KeyCodes.tab { return .systemShortcut }
        if key == KeyCodes.space, m.contains(.command) || m.contains(.control) { return .systemShortcut }
        if m.isSuperset(of: [.command, .shift]), KeyCodes.screenshot.contains(key) { return .systemShortcut }
        if m.contains(.command), key == KeyCodes.letterA { return .systemShortcut }
        let hasCommandOrControl = m.contains(.command) || m.contains(.control)
        if !hasCommandOrControl, !KeyCodes.nonTyping.contains(key) { return .typesCharacter }
        return nil
    }
}

/// Carbon virtual keycodes the bindings and the classifier share.
enum KeyCodes {
    static let tab = 48
    static let escape = 53
    static let space = 49
    static let letterA = 0
    static let screenshot: Set<Int> = [20, 21, 23]
    /// Arrows, Home, End, Page Up/Down, Return, keypad Enter, Delete, Forward Delete.
    static let caretMoving: Set<Int> = [125, 126, 115, 119, 116, 121, 123, 124, 36, 76, 51, 117]
    static let functionKeys: [Int: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
    /// Keys that type no character with any modifier, so they may be bound without ⌘ or ⌃.
    static let nonTyping: Set<Int> = Set(functionKeys.keys).union([tab, escape])

    static func knownName(_ keyCode: Int) -> String? {
        switch keyCode {
        case tab: return "Tab"
        case escape: return "Esc"
        case space: return "Space"
        default: return functionKeys[keyCode]
        }
    }
}
