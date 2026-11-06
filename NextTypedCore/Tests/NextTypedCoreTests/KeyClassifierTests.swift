import Testing
@testable import NextTypedCore

/// The keyDown → suggestion-intent decision, lifted out of the App layer (`EventTapController.classify`)
/// so the keycode/modifier routing is unit-testable. The App still owns the AppKit bits (reading the
/// CGEvent's keycode/flags and producing the typed character string for the `nil` fall-through).
///
/// The motivating fix: a backspace/forward-delete during a visible ghost must be
/// treated like a **caret move** — hide the stale ghost and regenerate at the retreating caret — instead
/// of being left to fall through to the printable-character branch (backspace's `\u{7F}` accidentally
/// passed the `>= 0x20` filter) or to `.ignore` (forward-delete's `0xF728` is in the function-key range).
@Suite struct KeyClassifierTests {
    private func classify(_ keyCode: Int, command: Bool = false, control: Bool = false,
                          shift: Bool = false, option: Bool = false,
                          characters: String? = nil) -> KeyCommand? {
        KeyClassifier.classifyKeyDown(keyCode: keyCode, command: command, control: control,
                                      shift: shift, option: option, characters: characters)
    }

    // MARK: the fix — deletes are caret moves

    @Test func backspaceIsCaretMove() {
        // keycode 51 (kVK_Delete, the key above Return) — the burst that left the ghost stale.
        #expect(classify(51) == .caretMove)
    }

    @Test func forwardDeleteIsCaretMove() {
        // keycode 117 (kVK_ForwardDelete, fn+Delete) — previously `.ignore` → ghost never hidden.
        #expect(classify(117) == .caretMove)
    }

    @Test func shiftDeleteIsStillCaretMove() {
        // Shift alone never diverts a key (it only matters combined with ⌘ for the screenshot combo), so
        // ⇧⌫ stays a caret move. ⌥⌫ (delete-word) too: `option` is read for **Tab only**, so it changes
        // nothing anywhere else.
        #expect(classify(51, shift: true) == .caretMove)
        #expect(classify(51, option: true) == .caretMove)
    }

    // MARK: regression — existing keyDown routing is unchanged

    @Test func tabAcceptsAWord() {
        #expect(classify(48) == .acceptWord)
    }

    // MARK: the second accept key — ⌥Tab accepts the whole buffer

    @Test func optionTabAcceptsTheWholeSuggestion() {
        #expect(classify(48, option: true) == .acceptAll)
    }

    @Test func plainTabStillAcceptsOneWord() {
        // The regression the ticket names: before `option` existed the accept branch tested the keycode
        // alone, so ⌥Tab WAS accept-word and the new shortcut would have been indistinguishable from
        // the old one. Plain Tab must keep meaning exactly one word.
        #expect(classify(48) == .acceptWord)
    }

    @Test func shiftTabStaysAcceptWord() {
        // ⇧Tab was rejected as the accept-all binding (backwards field navigation, outdent), so it
        // keeps the meaning it already had rather than acquiring a second one.
        #expect(classify(48, shift: true) == .acceptWord)
        #expect(classify(48, shift: true, option: true) == .acceptAll)
    }

    @Test func commandTabIsStillLeftAlone() {
        // ⌘Tab is the system app switcher: the ⌘/⌃ catch-all runs before the Tab branch, so neither
        // accept key can be reached with ⌘ held — including ⌘⌥Tab.
        #expect(classify(48, command: true) == .modifierShortcut)
        #expect(classify(48, command: true, option: true) == .modifierShortcut)
        #expect(classify(48, control: true, option: true) == .modifierShortcut)
    }

    @Test func escapeDismisses() {
        #expect(classify(53) == .dismiss)
    }

    @Test func navigationKeysAreCaretMoves() {
        for keyCode in [125, 126, 115, 119, 116, 121, 36, 76, 123, 124] {
            #expect(classify(keyCode) == .caretMove)
        }
    }

    @Test func printableCharacterFallsThrough() {
        // A plain letter ('a' = keycode 0) / space (49) is not a command keycode → nil, so the App
        // reads it as a typed character.
        #expect(classify(0) == nil)
        #expect(classify(49) == nil)
    }

    // MARK: modifiers

    @Test func screenshotShortcutsArm() {
        for keyCode in [20, 21, 23] {
            #expect(classify(keyCode, command: true, shift: true) == .screenshotShortcut)
        }
    }

    @Test func commandShortcutsAreLeftAlone() {
        // ⌘C (keycode 8) and other ⌘/⌃ combos must not disturb the suggestion.
        #expect(classify(8, command: true) == .modifierShortcut)
        #expect(classify(0, control: true) == .modifierShortcut)
    }

    @Test func modifiedDeleteIsLeftAlone() {
        // ⌘⌫ / ⌃⌫ carry a ⌘/⌃ modifier → out of scope for the delete fix; classify as a modifier
        // shortcut (passed through, suggestion untouched) exactly as before.
        #expect(classify(51, command: true) == .modifierShortcut)
        #expect(classify(51, control: true) == .modifierShortcut)
    }

    @Test func screenshotTakesPrecedenceOverModifierShortcut() {
        // ⌘⇧3 is both a ⌘ combo and the screenshot shortcut — the screenshot arming wins.
        #expect(classify(20, command: true, shift: true) == .screenshotShortcut)
    }

    // MARK: the fix — ⌘/⌃ + navigation still moves the caret

    @Test func commandArrowsAreCaretMoves() {
        // ⌘← / ⌘→ (line start/end) and ⌘↑ / ⌘↓ (document start/end) move the caret, so the ghost must be
        // hidden + regenerated. Before the fix the generic ⌘/⌃ catch-all swallowed them and the ghost
        // stayed frozen at its old position (harness-confirmed in TextEdit — host-independent).
        for keyCode in [123, 124, 126, 125] {
            #expect(classify(keyCode, command: true) == .caretMove)
        }
    }

    @Test func controlArrowsAreCaretMoves() {
        for keyCode in [123, 124, 126, 125] {
            #expect(classify(keyCode, control: true) == .caretMove)
        }
    }

    @Test func commandShiftArrowSelectionIsACaretMove() {
        // ⇧-selection variants are in scope: extending a selection moves the insertion point.
        #expect(classify(123, command: true, shift: true) == .caretMove)
        #expect(classify(124, command: true, shift: true) == .caretMove)
        #expect(classify(125, control: true, shift: true) == .caretMove)
    }

    @Test func modifiedHomeEndPageAreCaretMoves() {
        // Home (115), End (119), Page Up (116), Page Down (121).
        for keyCode in [115, 119, 116, 121] {
            #expect(classify(keyCode, command: true) == .caretMove)
            #expect(classify(keyCode, control: true) == .caretMove)
        }
    }

    @Test func modifiedReturnStaysAModifierShortcut() {
        // Return/keypad Enter are in the plain-navigation set, but ⌘Return is a *send* accelerator in
        // chat apps — deliberately excluded from the ⌘/⌃-navigation arm.
        #expect(classify(36, command: true) == .modifierShortcut)
        #expect(classify(76, command: true) == .modifierShortcut)
        #expect(classify(36, control: true) == .modifierShortcut)
    }

    @Test func ordinaryCommandCombosStayModifierShortcuts() {
        // ⌘S (1) / ⌘C (8) / ⌘V (9) must still leave the suggestion alone.
        #expect(classify(1, command: true) == .modifierShortcut)
        #expect(classify(8, command: true) == .modifierShortcut)
        #expect(classify(9, command: true) == .modifierShortcut)
    }

    @Test func screenshotStillWinsOverModifiedNavigation() {
        // Order pin: the screenshot combo is checked before BOTH the new ⌘/⌃-navigation arm and the
        // generic catch-all, so ⌘⇧3/4/5 keep arming the capture window.
        for keyCode in [20, 21, 23] {
            #expect(classify(keyCode, command: true, shift: true) == .screenshotShortcut)
        }
    }

    @Test func plainArrowsAreStillCaretMoves() {
        for keyCode in [123, 124, 125, 126] {
            #expect(classify(keyCode) == .caretMove)
        }
    }

    // MARK: ⌘A reaches the loop

    @Test func selectAllIsACaretMove() {
        // ⌘A (keycode 0) moves no caret, but it changes the SELECTION — and a ghost standing over a
        // selection continues a text the next keystroke replaces. It used to land in the generic
        // ⌘/⌃ catch-all, so the loop never heard about it and the ghost stayed. The prediction it
        // now triggers is refused by `SelectionGate` before any inference is scheduled.
        #expect(classify(0, command: true) == .caretMove)
        #expect(classify(0, command: true, shift: true) == .caretMove)
    }

    @Test func bareControlAIsUnchanged() {
        // ⌃A is the Emacs beginning-of-line binding, not a selection — deliberately left alone, so
        // the select-all arm is `command`-only.
        #expect(classify(0, control: true) == .modifierShortcut)
    }

    @Test func plainAIsStillATypedCharacter() {
        #expect(classify(0) == nil)
    }

    // MARK: undo and redo are caret moves, recognised by character (issue 80)

    @Test func commandZIsCaretMoveOnTheUSKeyPosition() {
        #expect(classify(6, command: true, characters: "z") == .caretMove)
    }

    @Test func commandZIsCaretMoveOnTheGermanKeyPosition() {
        // On a German layout the key labelled Z sends kVK_ANSI_Y (16).
        #expect(classify(16, command: true, characters: "z") == .caretMove)
    }

    @Test func commandShiftZIsCaretMoveInBothCases() {
        #expect(classify(6, command: true, shift: true, characters: "Z") == .caretMove)
        #expect(classify(16, command: true, shift: true, characters: "z") == .caretMove)
    }

    @Test func theKeyAtTheUSZPositionIsNotUndoWhenItTypesY() {
        // German layout, keycode 6 is the key labelled Y. ⌘Y is not undo there.
        #expect(classify(6, command: true, characters: "y") == .modifierShortcut)
    }

    @Test func otherCommandChordsStayModifierShortcuts() {
        #expect(classify(8, command: true, characters: "c") == .modifierShortcut)
        #expect(classify(9, command: true, characters: "v") == .modifierShortcut)
        #expect(classify(7, command: true, characters: "x") == .modifierShortcut)
        #expect(classify(1, command: true, characters: "s") == .modifierShortcut)
    }

    @Test func controlZAndOptionZAreUnchanged() {
        #expect(classify(6, control: true, characters: "z") == .modifierShortcut)
        #expect(classify(6, command: true, control: true, characters: "z") == .modifierShortcut)
        #expect(classify(6, option: true, characters: "z") == nil)
        #expect(classify(6, command: true, option: true, characters: "z") == .modifierShortcut)
    }

    @Test func commandZWithoutACharacterIsStillAModifierShortcut() {
        #expect(classify(6, command: true) == .modifierShortcut)
    }

    @Test func undoChordIsRecognisedByCharacterAlone() {
        #expect(KeyClassifier.isUndoOrRedo(command: true, control: false, option: false, characters: "Z"))
        #expect(!KeyClassifier.isUndoOrRedo(command: false, control: false, option: false, characters: "z"))
        #expect(!KeyClassifier.isUndoOrRedo(command: true, control: false, option: false, characters: "zz"))
    }
}
