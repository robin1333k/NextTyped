import NextTypedCore
import Foundation

/// The harness's **scripted** engine. Mechanics scenarios (type-along, peel,
/// routing, boundary refill) need a prediction whose *text* is known in advance, so they run against
/// this instead of the model; the scenario installs its rules over the debug channel (`fake.script`).
///
/// A rule matches when the **flush** prefix (trailing whitespace stripped, like the MLX path) ends
/// with `suffix`; the first matching rule wins; no match ⇒ empty suggestion (the value gate drops it).
/// `latencyMs` sleeps cancellably before answering, so cancel-mid-predict paths can be driven.
actor FakePredictionEngine: PredictionEngine {
    struct Rule: Sendable {
        var suffix: String
        var answer: String
        var latencyMs: Int
    }

    private var rules: [Rule] = []
    private(set) var predictCount = 0
    /// The decode word cap. At the ceiling the script is answered verbatim, as
    /// before the cap existed; below it the answer is trimmed like the MLX path's `trimToWords`.
    private(set) var decodeWordCap = ContinuationBuffer.maxWords

    func setDecodeWordCap(_ words: Int) {
        decodeWordCap = min(max(words, 1), ContinuationBuffer.maxWords)
    }

    func setRules(_ rules: [Rule]) {
        self.rules = rules
    }

    func reset() {
        rules = []
        predictCount = 0
    }

    func predict(for context: TypingContext) async throws -> Suggestion {
        try Task.checkCancellation()
        predictCount += 1
        let flush = trimTrailingWhitespace(context.textBeforeCaret)
        guard let rule = rules.first(where: { flush.hasSuffix($0.suffix) }) else {
            return .empty
        }
        if rule.latencyMs > 0 {
            try await Task.sleep(for: .milliseconds(rule.latencyMs))
        }
        try Task.checkCancellation()
        // Reconcile the leading space the way the MLX path does: typed `foo ` + answer `bar` renders
        // `bar` without a second gap; typed `foo` + answer ` bar` keeps the gap.
        var text = rule.answer
        if context.textBeforeCaret.last?.isWhitespace == true {
            text = String(text.drop(while: { $0.isWhitespace }))
        }
        if decodeWordCap < ContinuationBuffer.maxWords {
            text = ClauseStop.trimToWords(text, max: decodeWordCap)
        }
        return Suggestion(text: text)
    }

    private func trimTrailingWhitespace(_ s: String) -> String {
        var t = Substring(s)
        while let last = t.last, last.isWhitespace { t.removeLast() }
        return String(t)
    }
}
