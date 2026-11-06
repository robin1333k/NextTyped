import Testing
@testable import NextTypedCore

/// `EngineWarmUp` decides when the engine runs its one throwaway predict after a model load and
/// what the always-compiled `[mlx]: warm-up` line says.
@Suite struct EngineWarmUpTests {

    @Test func readyStartsTheWarmUp() {
        #expect(EngineWarmUp.starts(after: .ready, enabled: true))
    }

    @Test func noOtherLoadEventStartsTheWarmUp() {
        let others: [ModelLoadEvent] = [.loadingStarted, .downloading(0.5), .loadingWeights, .failed, .unloaded]
        for event in others {
            #expect(!EngineWarmUp.starts(after: event, enabled: true))
        }
    }

    @Test func theKnobTurnsTheWarmUpOff() {
        #expect(!EngineWarmUp.starts(after: .ready, enabled: false))
    }

    @Test func theWarmUpTextIsAForwardContextWithNoFrontSegments() {
        let context = EngineWarmUp.context
        #expect(context.textAfterCaret.isEmpty)
        #expect(context.windowContext == nil)
        #expect(context.replyContext == nil)
        #expect(context.personalization == nil)
        #expect(context.ocrContext == nil)
        #expect(context.clipboardContext == nil)
    }

    /// The prompt must reach the split prefill (`PrefillShape.splitMinimumTokens` = 128 tokens), so the
    /// kernels of both prefill calls are built. English runs below 5 characters a token for Qwen.
    @Test func theWarmUpTextIsLongEnoughForTheSplitPrefill() {
        #expect(EngineWarmUp.context.textBeforeCaret.count >= 5 * 128)
    }

    @Test func aCompletedWarmUpLogsItsTimesAndNoText() {
        let line = EngineWarmUp.logLine(.completed(totalMs: 1840, prefillMs: 910, decodeMs: 702,
                                                   promptTokens: 141, steps: 9))
        #expect(line == "[mlx]: warm-up done total=1840ms prefill=910 decode=702 promptTok=141 steps=9")
    }

    @Test func aWarmUpThatYieldsSaysSo() {
        #expect(EngineWarmUp.logLine(.yielded) == "[mlx]: warm-up yielded to a predict")
    }

    @Test func aWarmUpWithNoModelSaysSo() {
        #expect(EngineWarmUp.logLine(.noModel) == "[mlx]: warm-up skipped reason=no-model")
    }
}
