/// The **continuation buffer** the prediction engine returns for one decode: the *full decoded clause*, of which Core paints only a `DisplayWindow` and from
/// which `Tab` peels word by word with no re-inference.
///
/// The cap lives in Core rather than on the engine because it is not only a decode-loop safety
/// bound: `LongRangeCopyGuard.thresholdTokens` is *justified* by it (N = 8 is "the
/// longest run a single decode can produce"), and that relationship decides whether the guard's
/// head-keeping trim can execute at all. With the constant private to `MLXPredictionEngine`, Core
/// could not see the number its own bar is argued from, and raising the cap would silently change
/// what the guard does. This type owns the value.
public enum ContinuationBuffer {

    /// The most words one decode may return as the buffer.
    ///
    /// The engine's decode loop already bounds a clause to ≈8 words / 60 chars; this is the shaping
    /// cap applied to what comes out. It used to be 5 — the *display* size — which discarded ~3
    /// paid-for words on a long predict; Core now paints a window of it instead
    /// (`CompletionLength` / `DisplayWindow`) and the rest stays buffered for `Tab`.
    public static let maxWords = 8
}
