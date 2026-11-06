/// What a delete key removes, relative to the caret. Fed by `KeyClassifier.deletion` so the capture
/// buffer can shrink with the text.
public enum TextDeletion: Equatable, Sendable {
    /// Backspace — removes the character before the caret, i.e. the tail we just accumulated.
    case backward
    /// fn-Delete — removes the character *after* the caret.
    case forward
    /// ⌥-Backspace — removes the word before the caret.
    case backwardWord
    /// ⌘Z / ⌘⇧Z — removes or restores text of unknown extent, so the buffer cannot shrink by the right
    /// amount. It ends the capture run instead (nothing is committed from it).
    case undone
}

/// The **own-inserted capture buffer** — the mechanism that makes "own text only" true by
/// construction rather than by assumption.
///
/// The profile may only ever learn text the user **typed or accepted**. The rejected alternative was to
/// read the field's settled AX value at blur, which routinely contains *foreign* text: a `>`-quoted
/// reply, pasted content of unknown provenance, a co-author's paragraphs in a shared doc — the exact leak
/// that fail-closed speaker separation exists to prevent, and here it would land in the one artifact
/// that *persists*. So capture accumulates only what passes the insert layer:
///
/// - typed characters seen at the event tap, and
/// - accepted-ghost insertions, which go through our own synthetic-key path.
///
/// **Paste is excluded by construction** — a bulk system insert never enters the keystroke stream. So is
/// anything already in the field before we arrived.
///
/// v1 is a flat char buffer with pop-on-delete rather than reconstruction of own-authored *ranges* from
/// tracked offsets (a documented v1.1 refinement): after heavy mid-text editing the buffer is a slightly
/// scrambled record of what the user wrote — but never a record of what someone *else* wrote, which is
/// the property that has to hold.
public struct OwnInsertBuffer: Equatable, Sendable {
    /// Growth guard for one field. Long-form writing commits at the next context switch anyway, and the
    /// segmentation only ever needs whole clauses — so keeping the most recent text loses nothing that
    /// isn't already committed.
    public static let maxChars = 8000

    public private(set) var text = ""

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    /// Record own-inserted text: one typed character, or a whole accepted continuation.
    public mutating func insert(_ inserted: String) {
        guard !inserted.isEmpty else { return }
        text += inserted
        if text.count > Self.maxChars { text.removeFirst(text.count - Self.maxChars) }
    }

    /// Shrink with the host text.
    public mutating func delete(_ kind: TextDeletion) {
        switch kind {
        case .backward:
            if !text.isEmpty { text.removeLast() }
        case .backwardWord:
            while let last = text.last, last.isWhitespace { text.removeLast() }
            while let last = text.last, !last.isWhitespace { text.removeLast() }
        case .undone:
            text = ""
        case .forward:
            // Removes text to the RIGHT of the caret — not the tail we accumulated. A flat buffer has no
            // offsets to consult, so popping here would corrupt a correct buffer; leaving it is the
            // honest degradation.
            break
        }
    }

    /// Commit: hand over the accumulated text and clear. `nil` when there is nothing to commit, so the
    /// caller can skip the ingest entirely.
    public mutating func takeAll() -> String? {
        guard !text.isEmpty else { return nil }
        defer { text = "" }
        return text
    }

    /// Discard without committing — the fail-closed path for an ineligible surface (a secure field, a
    /// learning-denylisted app, or a burst that never proved its surface eligible).
    public mutating func clear() {
        text = ""
    }
}
