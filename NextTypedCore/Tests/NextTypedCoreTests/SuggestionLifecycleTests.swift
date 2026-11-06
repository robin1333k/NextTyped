import Testing
@testable import NextTypedCore

@Suite struct SuggestionLifecycleTests {
    // MARK: Base reactions

    @Test func typingRegenerates() {
        var lifecycle = SuggestionLifecycle()
        #expect(lifecycle.react(to: .typing) == .regenerate)
    }

    @Test func caretMoveRegeneratesWhenNotSuppressed() {
        var lifecycle = SuggestionLifecycle()
        #expect(lifecycle.react(to: .caretMoved) == .regenerate)
    }

    @Test func dismissClearsAndSuppresses() {
        var lifecycle = SuggestionLifecycle()
        #expect(lifecycle.react(to: .dismissed) == .clear)
        #expect(lifecycle.proactiveSuppressed == true)
    }

    @Test func cannotPredictClearsWithoutSuppressing() {
        var lifecycle = SuggestionLifecycle()
        #expect(lifecycle.react(to: .cannotPredict) == .clear)
        #expect(lifecycle.proactiveSuppressed == false)
    }

    // MARK: Esc mute — "quiet until I type again"

    @Test func afterEscCaretMovesAreMuted() {
        var lifecycle = SuggestionLifecycle()
        _ = lifecycle.react(to: .dismissed)
        // Clicking / arrowing around after Esc must NOT bring suggestions back.
        #expect(lifecycle.react(to: .caretMoved) == .hold)
        #expect(lifecycle.react(to: .caretMoved) == .hold)
        #expect(lifecycle.proactiveSuppressed == true)
    }

    @Test func typingLiftsTheEscMute() {
        var lifecycle = SuggestionLifecycle()
        _ = lifecycle.react(to: .dismissed)
        #expect(lifecycle.react(to: .typing) == .regenerate)
        #expect(lifecycle.proactiveSuppressed == false)
        // ...and now caret moves regenerate again.
        #expect(lifecycle.react(to: .caretMoved) == .regenerate)
    }

    @Test func focusChangeLiftsTheEscMute() {
        var lifecycle = SuggestionLifecycle()
        _ = lifecycle.react(to: .dismissed)
        #expect(lifecycle.react(to: .focusChanged) == .clear)
        #expect(lifecycle.proactiveSuppressed == false)
        #expect(lifecycle.react(to: .caretMoved) == .regenerate)
    }
}
