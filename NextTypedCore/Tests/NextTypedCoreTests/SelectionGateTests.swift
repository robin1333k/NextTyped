import Testing
@testable import NextTypedCore

@Suite("SelectionGate — a non-empty selection suppresses the continuation")
struct SelectionGateTests {
    @Test("A collapsed caret is allowed")
    func collapsedCaretAllowed() {
        #expect(SelectionGate.allowsContinuation(selectionLength: 0))
    }

    @Test("A one-character selection already suppresses")
    func oneCharacterSuppresses() {
        #expect(!SelectionGate.allowsContinuation(selectionLength: 1))
    }

    @Test("A ⌘A-sized selection suppresses")
    func selectAllSuppresses() {
        #expect(!SelectionGate.allowsContinuation(selectionLength: 4_000))
    }

    @Test("A negative length cannot happen but must not invert the rule")
    func negativeLengthAllowed() {
        #expect(SelectionGate.allowsContinuation(selectionLength: -1))
    }

    @Test("A context with no selection is allowed")
    func contextWithoutSelection() {
        let context = TypingContext(textBeforeCaret: "Der Zug fährt")
        #expect(SelectionGate.allowsContinuation(in: context))
    }

    @Test("A context carrying a selection is suppressed")
    func contextWithSelection() {
        let context = TypingContext(textBeforeCaret: "Der Zug fährt", selectionLength: 13)
        #expect(!SelectionGate.allowsContinuation(in: context))
    }

    @Test("A context whose AX layer exposed no range defaults to allowed")
    func missingDataDegradesToAllow() {
        // `selectionLength` defaults to 0 precisely so an unreadable range never suppresses.
        #expect(TypingContext(textBeforeCaret: "x").selectionLength == 0)
    }
}
