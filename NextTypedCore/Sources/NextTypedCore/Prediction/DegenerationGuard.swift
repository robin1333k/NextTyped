/// Degeneration guard for the greedy decode loop.
///
/// Greedy decoding with a mild repetition penalty can still latch into a short token cycle
/// (`:ort:ort:ort`, `d war d war d war`) that neither the clause stop nor the word cap catches.
/// This is the pure token-level check; the engine decodes the trimmed tokens again so the returned
/// text loses the loop too.
public enum DegenerationGuard {
    /// Longest cycle length, in tokens, that counts as a loop.
    public static let maxPeriod = 4
    /// Repetitions of a cycle at the tail that trigger the trim.
    public static let minRepetitions = 3

    /// The tokens cut back to one copy of the cycle when the tail repeats a cycle of 1 to 4 tokens
    /// at least 3 times, or `nil` when the tail is not a loop.
    public static func trim(_ tokens: [Int]) -> [Int]? {
        let n = tokens.count
        for period in 1 ... maxPeriod {
            guard n >= period * minRepetitions else { continue }
            var reps = 1
            var i = n - period
            while i - period >= 0, Array(tokens[(i - period) ..< i]) == Array(tokens[i ..< (i + period)]) {
                reps += 1
                i -= period
            }
            if reps >= minRepetitions { return Array(tokens[..<(n - (reps - 1) * period)]) }
        }
        return nil
    }
}
