import AppKit
@preconcurrency import CoreGraphics   // CGEvent/CGEventTap predate Sendable annotations
import NextTypedCore

/// A keystroke observed by the global event tap, classified for the loop.
enum TapEvent: Sendable {
    case character(String)          // a text-producing keystroke (drives prediction)
    case command(AcceptanceKey)     // Tab / ⌥Tab (intercepted while a suggestion is visible)
    case caretMove(deletion: TextDeletion?, lineBreak: Bool)
                                    // keyboard nav (↑↓/Home/End/Page/Return AND ←/→) AND deletes
                                    //   (backspace/forward-delete): the caret is about to move
                                    //   / text shrinks → hide the stale ghost; the AXObserver drives regen.
                                    // The two payloads exist only for the own-inserted capture buffer
                                    // , which — unlike the suggestion loop — must tell
                                    //   these keys apart: `deletion` so the buffer shrinks with the text,
                                    //   `lineBreak` so two lines aren't concatenated into one run.
    case dismiss                    // Esc → hard clear + mute proactive regen ("regenerate, don't discard")
    case pointer                    // mouse click → hide (unless a screenshot is armed); AX drives regen
    case viewportChange             // scroll moved the text under the caret → reposition a visible suggestion
                                    //   (pinch-zoom is an NSEvent gesture handled outside the tap)
    case screenshotShortcut         // ⌘⇧3/4/5 → arm a brief window so the capture drag doesn't dismiss
    case ignore                     // ⌘/⌃ shortcuts, key-up, flagsChanged, F-keys → leave suggestion alone
}

// `TapDecision` is now defined in `NextTypedCore` (lifted there so `SuggestionSession.interceptKey`
// can return it). Imported via `NextTypedCore` above; the tap consumes it unchanged.

/// Global `CGEventTap` at `kCGSessionEventTap`.
///
/// Skeleton scope: the tap source is added to the MAIN run loop, so the callback
/// runs on the main thread and can call the `@MainActor` handler directly. The
/// handler is fast (a pure state-machine step + scheduling a Task), so it won't
/// stall input.
/// TODO(hardening): move the tap to a DEDICATED run-loop thread so a busy main
/// thread can't starve it.
@MainActor
final class EventTapController {
    typealias Handler = @MainActor (TapEvent) -> TapDecision

    private var handler: Handler?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The user's chords for accept word, accept all and dismiss. The coordinator sets it at
    /// launch and on every rebind; the classifier reads it per keyDown.
    var bindings: InterceptBindings = .defaults
    /// Re-enables of our tap since launch (process lifetime), logged as `count=`.
    private(set) var reenableCount = 0
    /// Reads the tap list after a timeout disable.
    let census = EventTapCensus()

    func start(handler: @escaping Handler) async {
        guard tap == nil else { return }
        self.handler = handler

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<EventTapController>.fromOpaque(refcon).takeUnretainedValue()
            return controller.process(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            // keyDown drives prediction/accept; mouse-downs are observed so the loop can hide a
            // stale suggestion when a click moves the caret (the AXObserver then drives regen).
            eventsOfInterest: CGEventMask(
                (1 << CGEventType.keyDown.rawValue)
                    | (1 << CGEventType.leftMouseDown.rawValue)
                    | (1 << CGEventType.rightMouseDown.rawValue)
                    | (1 << CGEventType.scrollWheel.rawValue)
            ),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // An active keyboard tap is gated by ACCESSIBILITY (not Input Monitoring);
            // creation fails until that's granted. The coordinator retries on activation.
            acLog("[tap]: failed to create event tap — is Accessibility granted?")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        handler = nil
    }

    /// Runs on the main run-loop thread (the tap source lives there).
    private nonisolated func process(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            // macOS disables the tap under load — detect and re-enable.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                let cause: EventTapDisableCause = type == .tapDisabledByTimeout ? .timeout : .userInput
                reenableCount += 1
                acLog("[tap]: re-enabled cause=%@ count=%d", cause.rawValue, reenableCount)
                census.noteDisable(cause: cause)
                return Unmanaged.passUnretained(event)
            }
            // Ignore our own synthetic insertions so we don't loop on them.
            if event.getIntegerValueField(.eventSourceUserData) == SyntheticEvent.magic {
                return Unmanaged.passUnretained(event)
            }
            let decision = handler?(Self.classify(event, type: type, bindings: bindings)) ?? .passThrough
            return decision == .suppress ? nil : Unmanaged.passUnretained(event)
        }
    }

    private static func classify(_ event: CGEvent, type: CGEventType,
                                 bindings: InterceptBindings) -> TapEvent {
        // Scroll moves the text (and the caret) under the overlay → reposition a visible
        // suggestion. Pinch-zoom is an NSEvent gesture (no CGEventType) handled via a monitor.
        if type == .scrollWheel { return .viewportChange }
        // A mouse click dismisses the suggestion instantly (handled in the loop) — unless a
        // screenshot was just armed, so the capture-selection drag survives.
        if type == .leftMouseDown || type == .rightMouseDown { return .pointer }
        guard type == .keyDown else { return .ignore }   // key-up, flagsChanged, etc.

        let flags = event.flags
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // Route the keyDown by keycode + modifiers in pure Core (unit-tested in `KeyClassifierTests`).
        // A `nil` result means "candidate typed character" — fall through to the printability check below.
        // Tab → accept a word (or apply a pending correction; precedence decided in Core). Deletes
        // (backspace / forward-delete) are caret moves so the stale ghost is hidden + regenerated at the
        // retreating caret instead of lingering.
        let characters = NSEvent(cgEvent: event)?.charactersIgnoringModifiers
        switch KeyClassifier.classifyKeyDown(
            keyCode: keyCode,
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift),
            // Read for Tab only — it is what separates accept-word from accept-all.
            // Without it ⌥Tab is indistinguishable from plain Tab.
            option: flags.contains(.maskAlternate),
            // The three intercept keys are the user's chords; defaults Tab, ⌥Tab, Esc.
            bindings: bindings,
            // The undo chord is recognised by character, not keycode (German layout: Z sends kVK_ANSI_Y).
            characters: characters
        ) {
        case .screenshotShortcut: return .screenshotShortcut
        case .modifierShortcut:   return .ignore
        case .acceptWord:         return .command(.tab)
        // ⌥Tab — accept the whole buffer. Intercepted under the SAME ghost-visible gate as Tab
        // : the reducer answers `.passThrough` with nothing showing, so ⌥Tab is
        // untouched in every app the rest of the time.
        case .acceptAll:          return .command(.acceptAll)
        case .dismiss:            return .dismiss
        case .caretMove:
            // An undo or redo changes an unknown amount of text: it carries `.undone`, which ends the
            // own-inserted capture run so the profile never learns what the undo removed.
            return .caretMove(
                deletion: KeyClassifier.deletion(
                    keyCode: keyCode, option: flags.contains(.maskAlternate),
                    command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                    characters: characters),
                lineBreak: KeyClassifier.insertsLineBreak(keyCode: keyCode))
        case nil:                 break
        }

        // Printable characters (incl. space) drive prediction. Exclude the function-key
        // private-use range (0xF700–0xF8FF) where F-keys etc. report their "characters".
        // (Emoji/CJK are above this range and remain typing.)
        if let chars = NSEvent(cgEvent: event)?.characters,
           let scalar = chars.unicodeScalars.first,
           scalar.value >= 0x20,
           !(0xF700...0xF8FF).contains(scalar.value) {
            return .character(chars)
        }
        return .ignore   // any other non-printable key → leave the suggestion alone
    }
}
