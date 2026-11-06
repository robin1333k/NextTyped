import Testing
import Foundation
@testable import NextTypedCore

/// What the **uncapped-prefix scans on the predict path** cost against first paint.
///
/// `RunningThoughtGate.hasRunningThought` (arm 1, once per `contextReady`),
/// `LongRangeCopyGuard.apply` and `SentenceStartCase.apply` (once per non-empty prediction) all read
/// `TypingContext.textBeforeCaret` **uncapped** — the prompt window caps what reaches the model, not
/// what reaches Core — synchronously inside first paint. The suspicion was that this is a real cost;
/// the measurement says it is ~0.1 % of a predict (0.84 ms of an ~800 ms predict on the 4.7 kB note,
/// the third scan included), so the scans stay as they are and this file
/// exists so the next reader does not re-derive the suspicion by reading the code.
///
/// **Opt-in**, because a timing loop is neither a behaviour assertion nor stable in CI: it runs only
/// under `NEXTTYPED_BENCH=1`, and is compiled with the suite so it cannot rot. Measure in
/// **release** — the debug figures are ~3× higher and are what a harness run (a Debug build) pays:
///
/// ```
/// NEXTTYPED_BENCH=1 swift test -c release --filter PredictPathScanCostBenchmark
/// ```
@Suite struct PredictPathScanCostBenchmark {

    /// A prediction whose head does not copy the fixture, so the guard walks its full index rather
    /// than short-circuiting on an early refusal — the worst case, which is what a bound wants.
    static let candidate = " und die Ergebnisse wurden im Mai"

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXTTYPED_BENCH"] != nil))
    func scanCostAgainstFirstPaint() throws {
        // The harness fixtures, located relative to this file so the benchmark is runnable from a
        // checkout rather than from one machine.
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // NextTypedCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // NextTypedCore
            .deletingLastPathComponent()    // the repo root
            .appendingPathComponent("NextTypedCore/Tests/Fixtures")

        let short = try String(contentsOf: fixtures.appendingPathComponent("short-note-de.txt"), encoding: .utf8)
        let long = try String(contentsOf: fixtures.appendingPathComponent("long-note-de.txt"), encoding: .utf8)
        // 10× the harness worst case: a note far longer than any measured so far, to show the shape
        // of the curve rather than one point on it. Both scans are linear in the prefix.
        let huge = String(repeating: long, count: 10)

        for (name, text) in [("short", short), ("long", long), ("long×10", huge)] {
            let gate = Self.microsecondsPerCall {
                _ = RunningThoughtGate.hasRunningThought(textBeforeCaret: text)
            }
            let copyGuard = Self.microsecondsPerCall {
                _ = LongRangeCopyGuard.apply(to: Self.candidate, textBeforeCaret: text)
            }
            // The sentence-start case guard re-runs arm 1's own scan on the
            // arrival side, so it belongs in the same bound rather than in a note claiming it is free.
            let sentenceCase = Self.microsecondsPerCall {
                _ = SentenceStartCase.apply(to: Self.candidate, textBeforeCaret: text)
            }
            print(String(format: "[latency/11] %-8@ chars=%6d  gate=%8.1fus  copy-guard=%8.1fus  case=%8.1fus  total=%8.1fus",
                         name as NSString, text.count, gate, copyGuard, sentenceCase,
                         gate + copyGuard + sentenceCase))
        }
    }

    private static func microsecondsPerCall(_ body: () -> Void) -> Double {
        for _ in 0..<20 { body() }                       // warm the allocator
        let iterations = 200
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { body() }
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / Double(iterations) / 1000
    }
}
