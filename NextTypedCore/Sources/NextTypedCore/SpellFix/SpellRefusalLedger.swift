/// Counts how often the user typed past a spelling correction, per word, and holds the words that
/// reached the threshold (the ignore list). In memory only: nothing is stored and nothing reaches the
/// macOS system dictionary.
public struct SpellRefusalLedger: Equatable, Sendable {
    /// Refusals of one word after which its correction is no longer offered.
    public static let threshold = 3

    private var counts: [String: Int] = [:]
    private var ignored: Set<String> = []

    public init() {}

    /// Case-folded key, so "Qwen" and "qwen" are one word.
    private static func key(_ word: String) -> String { word.lowercased() }

    public func isIgnored(_ word: String) -> Bool { ignored.contains(Self.key(word)) }

    /// Records one refusal. Returns `true` only on the call that puts the word into the ignore list.
    @discardableResult
    public mutating func recordRefusal(of word: String) -> Bool {
        let k = Self.key(word)
        guard !ignored.contains(k) else { return false }
        let n = (counts[k] ?? 0) + 1
        counts[k] = n
        guard n >= Self.threshold else { return false }
        ignored.insert(k)
        counts[k] = nil
        return true
    }
}
