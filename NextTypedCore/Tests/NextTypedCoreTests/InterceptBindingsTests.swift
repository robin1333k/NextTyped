import Foundation
import Testing
@testable import NextTypedCore

/// The rebindable intercept keys: accept word, accept all and
/// dismiss each take a user chord, our keys are only the defaults, and a chord that collides with
/// another of ours, types a character or moves the caret is refused.
@Suite struct InterceptBindingsTests {
    // Carbon keycodes, literal so the tests do not reuse the classifier's table.
    private let tab = 48, escape = 53, f5 = 96, letterA = 0, letterK = 40, leftArrow = 123, space = 49
    private let delete = 51

    private func classify(_ keyCode: Int, command: Bool = false, control: Bool = false,
                          shift: Bool = false, option: Bool = false,
                          _ bindings: InterceptBindings) -> KeyCommand? {
        KeyClassifier.classifyKeyDown(keyCode: keyCode, command: command, control: control,
                                      shift: shift, option: option, bindings: bindings)
    }

    @Test func defaultsAreTabOptionTabAndEsc() {
        let d = InterceptBindings.defaults
        #expect(d[.acceptWord] == KeyChord(keyCode: 48))
        #expect(d[.acceptAll] == KeyChord(keyCode: 48, modifiers: .option))
        #expect(d[.dismiss] == KeyChord(keyCode: 53))
    }

    @Test func reboundAcceptWordMovesToTheNewKeyAndTabFallsThrough() throws {
        let b = try InterceptBindings.defaults.rebinding(.acceptWord, to: KeyChord(keyCode: f5)).get()
        #expect(classify(f5, b) == .acceptWord)
        // Plain Tab is no longer ours, but the host still inserts a tab or moves focus, so the ghost
        // must hide and regenerate rather than stand at the old caret.
        #expect(classify(tab, b) == .caretMove)
        #expect(classify(tab, shift: true, b) == .caretMove)
        // ⌥Tab still accepts everything.
        #expect(classify(tab, option: true, b) == .acceptAll)
    }

    @Test func reboundAcceptAllToControlKIsReachedDespiteTheCommandControlCatchAll() throws {
        let chord = KeyChord(keyCode: letterK, modifiers: .control)
        let b = try InterceptBindings.defaults.rebinding(.acceptAll, to: chord).get()
        #expect(classify(letterK, control: true, b) == .acceptAll)
        #expect(classify(tab, option: true, b) == .caretMove)
    }

    @Test func reboundDismissMovesOffEsc() throws {
        let chord = KeyChord(keyCode: letterK, modifiers: [.command, .shift])
        let b = try InterceptBindings.defaults.rebinding(.dismiss, to: chord).get()
        #expect(classify(letterK, command: true, shift: true, b) == .dismiss)
        #expect(classify(escape, b) == nil)
    }

    @Test func shiftVariantOfAnUnshiftedBindingStillMatches() {
        // ⇧Tab kept the accept-word meaning before bindings existed; the fallback keeps it.
        #expect(classify(tab, shift: true, .defaults) == .acceptWord)
        #expect(classify(tab, shift: true, option: true, .defaults) == .acceptAll)
        #expect(classify(escape, shift: true, .defaults) == .dismiss)
    }

    @Test func anExactShiftedBindingWinsOverTheShiftFallback() throws {
        let b = try InterceptBindings.defaults
            .rebinding(.acceptAll, to: KeyChord(keyCode: tab, modifiers: .shift)).get()
        #expect(classify(tab, shift: true, b) == .acceptAll)
        #expect(classify(tab, b) == .acceptWord)
    }

    @Test func aChordAlreadyBoundToAnotherActionIsRefused() {
        let result = InterceptBindings.defaults.rebinding(.acceptAll, to: KeyChord(keyCode: tab))
        #expect(result == .failure(.collides(with: .acceptWord)))
        let esc = InterceptBindings.defaults.rebinding(.acceptWord, to: KeyChord(keyCode: escape))
        #expect(esc == .failure(.collides(with: .dismiss)))
    }

    @Test func rebindingAnActionToItsOwnChordIsAccepted() {
        let result = InterceptBindings.defaults.rebinding(.acceptWord, to: KeyChord(keyCode: tab))
        #expect(result == .success(.defaults))
    }

    @Test func aChordUsedByAGlobalShortcutIsRefused() {
        let pause = KeyChord(keyCode: letterK, modifiers: [.command, .option])
        let result = InterceptBindings.defaults.rebinding(.dismiss, to: pause, globalShortcuts: [pause])
        #expect(result == .failure(.collidesWithGlobalShortcut))
    }

    @Test func aBindingWhoseShiftVariantIsAGlobalShortcutIsRefused() {
        // ⌃K would also match ⌃⇧K through the ⇧ fallback and swallow that global while a ghost shows.
        let quiet = KeyChord(keyCode: letterK, modifiers: [.control, .shift])
        let result = InterceptBindings.defaults
            .rebinding(.acceptWord, to: KeyChord(keyCode: letterK, modifiers: .control), globalShortcuts: [quiet])
        #expect(result == .failure(.collidesWithGlobalShortcut))
    }

    @Test func aGlobalOnTheShiftVariantOfAnInterceptKeyCollides() {
        // ⇧Tab is accept word through the fallback, so a global recording on it is refused.
        #expect(InterceptBindings.defaults.collidesWithIntercept(KeyChord(keyCode: tab, modifiers: .shift))
                == .acceptWord)
        #expect(InterceptBindings.defaults.collidesWithIntercept(KeyChord(keyCode: escape, modifiers: .shift))
                == .dismiss)
        #expect(InterceptBindings.defaults.collidesWithIntercept(KeyChord(keyCode: letterK, modifiers: .control))
                == nil)
    }

    @Test func aChordThatTypesACharacterIsRefused() {
        // A plain letter, ⇧letter, ⌥letter (⌥L is @ on a German Mac) and Space all produce text, and a
        // ghost-visible intercept would swallow it while typing along the ghost.
        for chord in [KeyChord(keyCode: letterA), KeyChord(keyCode: letterA, modifiers: .shift),
                      KeyChord(keyCode: letterA, modifiers: .option), KeyChord(keyCode: space),
                      KeyChord(keyCode: space, modifiers: .option)] {
            #expect(InterceptBindings.defaults.rebinding(.acceptWord, to: chord) == .failure(.typesCharacter))
        }
    }

    @Test func aNavigationOrDeleteKeyIsRefused() {
        for chord in [KeyChord(keyCode: leftArrow), KeyChord(keyCode: leftArrow, modifiers: .command),
                      KeyChord(keyCode: delete, modifiers: .option), KeyChord(keyCode: 36)] {
            #expect(InterceptBindings.defaults.rebinding(.acceptAll, to: chord) == .failure(.movesCaret))
        }
    }

    @Test func systemShortcutsAreRefused() {
        for chord in [KeyChord(keyCode: tab, modifiers: .command),
                      KeyChord(keyCode: tab, modifiers: [.command, .shift]),
                      KeyChord(keyCode: space, modifiers: .command),
                      KeyChord(keyCode: 21, modifiers: [.command, .shift]),
                      KeyChord(keyCode: letterA, modifiers: .command)] {
            #expect(InterceptBindings.defaults.rebinding(.acceptAll, to: chord) == .failure(.systemShortcut))
        }
    }

    @Test func functionKeysAndModifiedTabAreAllowedWithoutCommandOrControl() {
        #expect((try? InterceptBindings.defaults.rebinding(.acceptAll, to: KeyChord(keyCode: f5)).get()) != nil)
        let ctrlTab = KeyChord(keyCode: tab, modifiers: .control)
        #expect((try? InterceptBindings.defaults.rebinding(.acceptAll, to: ctrlTab).get()) != nil)
    }

    @Test func codableRoundTripKeepsTheChords() throws {
        let b = try InterceptBindings.defaults.rebinding(.dismiss, to: KeyChord(keyCode: f5)).get()
        let data = try JSONEncoder().encode(b)
        #expect(try JSONDecoder().decode(InterceptBindings.self, from: data) == b)
    }

    @Test func storedBindingsThatCollideFallBackToDefaults() throws {
        let json = #"{"acceptWord":{"keyCode":48,"modifiers":0},"acceptAll":{"keyCode":48,"modifiers":0},"dismiss":{"keyCode":53,"modifiers":0}}"#
        #expect(InterceptBindings.restored(from: Data(json.utf8)) == .defaults)
        #expect(InterceptBindings.restored(from: nil) == .defaults)
        #expect(InterceptBindings.restored(from: Data("garbage".utf8)) == .defaults)
    }

    @Test func displayNamesUseModifierSymbolsInMacOrder() {
        #expect(KeyChord(keyCode: tab).displayName() == "Tab")
        #expect(KeyChord(keyCode: tab, modifiers: .option).displayName() == "\u{2325}Tab")
        #expect(KeyChord(keyCode: escape).displayName() == "Esc")
        #expect(KeyChord(keyCode: f5, modifiers: [.command, .shift, .control, .option]).displayName()
                == "\u{2303}\u{2325}\u{21E7}\u{2318}F5")
        #expect(KeyChord(keyCode: letterK, modifiers: .control).displayName { _ in "K" } == "\u{2303}K")
    }
}
