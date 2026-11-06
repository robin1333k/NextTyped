/// Decides whether a continuation may be generated while the host holds a **non-empty selection**
/// — the cold-start sibling of `FieldSizeGate` and `RunningThoughtGate` arm 1.
///
/// The rule is one line: **something is selected ⇒ no continuation.** The next keystroke replaces
/// the whole selection, so a ghost standing over it continues a text that is about to cease
/// existing — and an inference spent on that prefix is spent on text with no future.
///
/// **Why this is a gate and not a key classification.** The obvious fix for the reported symptom
/// (⌘A leaving a ghost standing) is to route ⌘A through the classifier, but a selection made by
/// *dragging the mouse* produces no keyDown at all, so a classifier-only fix would leave half the
/// cases open. The AX selected-text **range** is the one signal both paths share, so the decision
/// belongs where that range arrives. ⌘A still needs to *reach* the loop — otherwise nothing
/// re-reads the context — but it reaches it as an ordinary caret move and is stopped here, ahead
/// of `.runInference`, so the re-read costs no inference.
///
/// Also fixes the invisible half of the same gap: `⇧`+arrow is already a caret move, so extending
/// a selection used to hide the ghost and immediately re-infer over the *growing* selection, once
/// per keystroke.
///
/// Pure Core: the selection length is a plain count of characters, supplied by the AX layer.
public enum SelectionGate {
    /// - Parameter selectionLength: the length of the host's selected-text range, in characters.
    ///   `0` is a collapsed caret — the ordinary case.
    /// - Returns: `true` if a continuation may be generated.
    public static func allowsContinuation(selectionLength: Int) -> Bool {
        selectionLength <= 0
    }

    /// Convenience over a `TypingContext`. A context whose AX layer exposed no range reports
    /// `selectionLength == 0` and is therefore allowed — the gate never suppresses on missing data,
    /// matching `FieldSizeGate`'s "never suppress an editor we can't classify".
    public static func allowsContinuation(in context: TypingContext) -> Bool {
        allowsContinuation(selectionLength: context.selectionLength)
    }
}
