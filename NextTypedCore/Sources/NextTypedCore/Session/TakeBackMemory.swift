import Foundation

/// The accepts the user may take back, and the ones they did.
///
/// Every accept that inserts continuation text records an **accept anchor**: the text before the caret
/// before the insert (`P`) and the inserted text (`T`, what reached the host). An anchor is **taken
/// back** when the caret is at `P` again and `T` is no longer right of it: a delete or an undo removed
/// it. Arrowing back leaves `T` right of the caret and is not a take-back. No clock: the anchor lives
/// until a focus change, a pause or a temporary quiet clears it, or 16 newer accepts push it out.
///
/// Gate-only state in process memory: never stored, never in the prompt, and the gate token
/// carries `T`'s length, never its text.
struct TakeBackMemory: Sendable, Equatable {
    static let capacity = 16

    private struct Anchor: Sendable, Equatable {
        let prefix: String
        let inserted: String
        var takenBack = false
    }

    private var anchors: [Anchor] = []

    /// An accept inserted `inserted` at a caret with `prefix` before it.
    mutating func recordAccept(prefix: String, inserted: String) {
        guard !inserted.isEmpty else { return }
        anchors.append(Anchor(prefix: prefix, inserted: inserted))
        if anchors.count > Self.capacity { anchors.removeFirst(anchors.count - Self.capacity) }
    }

    /// Phase 1: a fresh context marks every anchor at its caret whose text is gone.
    mutating func observe(_ context: TypingContext) {
        for index in anchors.indices where !anchors[index].takenBack
            && anchors[index].prefix == context.textBeforeCaret
            && !context.textAfterCaret.hasPrefix(anchors[index].inserted) {
            anchors[index].takenBack = true
        }
    }

    /// Phase 2: the length of the taken-back text a continuation at `textBeforeCaret` would offer
    /// again (same first word, case-sensitive), or `nil` when it may show.
    func refusal(of continuation: String, textBeforeCaret: String) -> Int? {
        guard let first = Self.firstWord(of: continuation) else { return nil }
        return anchors.last { anchor in
            anchor.takenBack && anchor.prefix == textBeforeCaret && Self.firstWord(of: anchor.inserted) == first
        }?.inserted.count
    }

    mutating func clear() { anchors.removeAll() }

    private static func firstWord(of text: String) -> Substring? {
        text.split(whereSeparator: { $0.isWhitespace }).first
    }
}
