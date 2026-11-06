import Testing
@testable import NextTypedCore

@Suite struct TrailingPunctuationTests {
    @Test func absentOrUnknownStoredValueReadsAsTheShippingBehaviour() {
        #expect(TrailingPunctuation(stored: nil) == .bothShortcuts)
        #expect(TrailingPunctuation(stored: "retired") == .bothShortcuts)
    }

    @Test func storedNamesRoundTrip() {
        #expect(TrailingPunctuation(stored: "fullAcceptOnly") == .fullAcceptOnly)
        #expect(TrailingPunctuation(stored: "neither") == .neither)
    }
}
