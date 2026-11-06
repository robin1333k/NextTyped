/// How the engine prefills the tokens it has to feed the model (the split prefill).
///
/// `.whole` is one `model(tokens, cache:)` call. It runs the LM head on every input position and keeps
/// only the last row. `.split` first feeds every token but the last and evaluates only the cache state,
/// then feeds the last token alone, so the LM head runs on one position.
///
/// The split costs one extra one-token forward and saves the LM head on every other position. On the 4B
/// (enginebench, host, 2026-10-28) that was about +25 ms of prefill on a 12-token prompt and minus 141 to
/// 153 ms on a 520-token prompt, so the break-even sits near 80 tokens. `splitMinimumTokens` keeps short
/// prompts, the common case after a short prefix, on the single call.
public enum PrefillShape: Equatable, Sendable {
    case whole
    case split

    /// Inputs this long or longer split.
    public static let splitMinimumTokens = 128

    public static func forInput(tokenCount: Int) -> PrefillShape {
        tokenCount >= splitMinimumTokens ? .split : .whole
    }
}
