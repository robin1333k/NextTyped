/// The engine warm-up: one throwaway forward
/// predict of fixed text right after each model load, so the first real predict does not pay for the
/// first-use Metal kernel builds. On the test machine the first predict after a load decoded at about four
/// times the warm rate (2406 ms against a P50 of 314 ms for the next 23).
///
/// The engine runs it after every `.ready` load event: the launch load, a reload after an unload, a
/// retry and a reload from the model picker. Its result is discarded and never reaches the session, so
/// nothing is shown and nothing counts in the statistics. A real predict cancels it (single
/// slot), and the engine drops the KV-cache it built, so the next prompt starts from the same empty
/// cache as without the warm-up.
public enum EngineWarmUp {
    /// Whether this load event starts the warm-up. `enabled` is the `engineWarmUpEnabled` knob (on when
    /// absent), which exists for the enginebench A/B.
    public static func starts(after event: ModelLoadEvent, enabled: Bool) -> Bool {
        guard enabled else { return false }
        switch event {
        case .ready: return true
        case .loadingStarted, .downloading, .loadingWeights, .failed, .diskTooSmall, .unloaded: return false
        }
    }

    /// The fixed warm-up prompt. It carries no user text and no front segments, and it is long enough
    /// (over `PrefillShape.splitMinimumTokens` tokens) to take the split prefill, so the kernels of both
    /// prefill calls and of the one-token decode step are built.
    public static let context = TypingContext(textBeforeCaret: """
        Thank you for the notes from the meeting this morning. I went through the list again on the \
        train and most of the open points look smaller than they did on the whiteboard. The first one \
        is the order of the chapters in the guide, which we can settle by reading the draft from start \
        to end and moving anything that refers forward. The second one is the wording on the welcome \
        page, where a shorter sentence would help people who only skim it. The third one is the plan \
        for the next few weeks, and here I think we should keep the scope small, finish what we have \
        started, and only then pick the next topic. If you agree, I will write a short summary for the \
        rest of the group and send it before the end of the day, so that everyone can read it before \
        we meet again and bring their own questions. I would also like to
        """)

    /// How a warm-up ended, for its always-compiled log line. The line carries times and counts only,
    /// never text.
    public enum Outcome: Equatable, Sendable {
        /// The warm-up ran to the end of its decode.
        case completed(totalMs: Int, prefillMs: Int, decodeMs: Int, promptTokens: Int, steps: Int)
        /// A real predict (or an unload) cancelled it.
        case yielded
        /// The model was gone again by the time the warm-up ran.
        case noModel
    }

    public static func logLine(_ outcome: Outcome) -> String {
        switch outcome {
        case let .completed(totalMs, prefillMs, decodeMs, promptTokens, steps):
            return "[mlx]: warm-up done total=\(totalMs)ms prefill=\(prefillMs) decode=\(decodeMs) "
                + "promptTok=\(promptTokens) steps=\(steps)"
        case .yielded:
            return "[mlx]: warm-up yielded to a predict"
        case .noModel:
            return "[mlx]: warm-up skipped reason=no-model"
        }
    }
}
