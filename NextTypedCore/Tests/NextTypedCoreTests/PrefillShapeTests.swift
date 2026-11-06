import Testing
@testable import NextTypedCore

/// which prefills split off the last token. The 4B bench put the split's fixed cost at about
/// 25 ms (one extra one-token forward) and its saving at about 0.3 ms per prompt token, so only inputs of
/// 128 tokens or more split.
@Suite struct PrefillShapeTests {
    @Test func aOneTokenInputIsOneCall() {
        #expect(PrefillShape.forInput(tokenCount: 1) == .whole)
    }

    @Test func aShortPromptIsOneCall() {
        #expect(PrefillShape.forInput(tokenCount: 12) == .whole)
        #expect(PrefillShape.forInput(tokenCount: 127) == .whole)
    }

    @Test func aPromptOf128TokensOrMoreSplits() {
        #expect(PrefillShape.forInput(tokenCount: 128) == .split)
        #expect(PrefillShape.forInput(tokenCount: 520) == .split)
    }
}
