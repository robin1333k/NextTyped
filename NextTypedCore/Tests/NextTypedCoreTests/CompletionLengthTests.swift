import Testing
@testable import NextTypedCore

/// The user-facing Short / Medium / Long completion length — three
/// named steps over the *display window*, all of them inside the already-decoded 8-word
/// buffer, so no step costs a decode.
@Suite struct CompletionLengthTests {
    @Test func stepsMapToTheDecidedWordCounts() {
        #expect(CompletionLength.short.maxWords == 3)
        #expect(CompletionLength.medium.maxWords == 5)
        #expect(CompletionLength.long.maxWords == 8)
    }

    @Test func mediumIsTheShippingDefaultAndMatchesTheOldConstant() {
        // The pre-setting behaviour was a hard 5-word window (the display cap).
        #expect(CompletionLength.default == .medium)
        #expect(DisplayWindow.defaultMaxWords == 5)
    }

    @Test func longStaysInsideTheDecodedBuffer() {
        // The decode safety cap is 8 words; Long may reveal the whole buffer but never asks for more.
        #expect(CompletionLength.long.maxWords <= 8)
    }

    /// The persisted value is the *step*, not the number, so re-tuning 3/5/8 later cannot invalidate
    /// what is already stored.
    @Test func storedValuesRoundTripAndFallBackToTheDefault() {
        for length in CompletionLength.allCases {
            #expect(CompletionLength(stored: length.rawValue) == length)
        }
        #expect(CompletionLength(stored: nil) == .default)          // never chosen
        #expect(CompletionLength(stored: "") == .default)           // junk in the domain
        #expect(CompletionLength(stored: "extra-long") == .default) // a step that no longer exists
    }

    @Test func theWordStepRoundTripsAndKeepsTheUnknownFallback() {
        #expect(CompletionLength(stored: "word") == .word)
        #expect(CompletionLength.allCases.contains(.word))
        #expect(CompletionLength(stored: "words") == .medium)
    }

    @Test func theWordStepShowsOnlyTheRestOfTheCurrentWord() {
        #expect(DisplayWindow.windowed("lp with the project", length: .word) == "lp")
        #expect(DisplayWindow.windowed("lp", length: .word) == "lp")
        // A leading gap means the buffer opens at the next word, which this step never proposes.
        #expect(DisplayWindow.windowed(" with the project", length: .word) == "")
        #expect(DisplayWindow.windowed("", length: .word) == "")
        // The other steps are unchanged.
        #expect(DisplayWindow.windowed(" one two three four", length: .short) == " one two three")
    }

    @Test func onlyTheWordStepNeedsAMidWordPrefix() {
        #expect(CompletionLength.word.allowsContinuation(textBeforeCaret: "Thank you for your hel"))
        #expect(!CompletionLength.word.allowsContinuation(textBeforeCaret: "Thank you for your "))
        #expect(!CompletionLength.word.allowsContinuation(textBeforeCaret: ""))
        #expect(!CompletionLength.word.allowsContinuation(textBeforeCaret: "Hello.\n"))
        #expect(CompletionLength.medium.allowsContinuation(textBeforeCaret: "Thank you for your "))
    }
}
