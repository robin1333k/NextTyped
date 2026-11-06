import Foundation

/// When a first-run model download should write a progress line to the log.
///
/// The Hub downloader's progress handler fires **far more often than is useful** (hundreds of times over
/// a ~47 s fetch), so the engine cannot simply log every callback: a flood of lines is a different way of
/// being unreadable than today's total silence. The *cadence decision* is kept here as a pure, time-free
/// reducer — the engine passes the fraction and a monotonic timestamp and executes the verdict
/// — so the rule is unit-testable without a network, a Hub, or a 1.4 GB download.
///
/// **The cadence, and why:**
///   - **One line per ~10 % step.** A whole download is then ≤10 lines: enough to see it move, few enough
///     to read. The step is the primary signal because it is what a reader wants (`how far did it get`),
///     and because it makes a **stall** legible — the last line before the silence names the percentage
///     it stopped at, which is the second cost the ticket records.
///   - **At most one line per second.** A resumed or partially-cached download can cross several buckets
///     in a burst; the floor keeps that from printing 10 lines in a tick. A bucket suppressed by the
///     floor is not lost — the *next* accepted callback reports the then-current bucket, so the log
///     stays monotone and skips rather than repeats.
///   - **0 % is never logged.** The `downloading … from Hub…` line the engine writes immediately before
///     already marks the start; a `0%` line one millisecond later says nothing.
///
/// Not a `UserDefaults` knob: unlike the measurement knobs, nothing downstream reads
/// these lines mechanically, so a second arm would buy nothing.
public struct ModelDownloadProgressLog: Sendable {
    /// Where a Hub-path load got its bytes.
    public enum ByteSource: String, Sendable, Equatable {
        /// At least one callback reported a fraction strictly between 0 and 1: bytes crossed the network.
        case network
        /// No such callback. A warm Hub cache reports a single finished fraction.
        case cache
    }

    /// Progress step that earns a line, as a fraction (0.1 ⇒ every ~10 %).
    private let step: Double
    /// Minimum seconds between two lines, whatever the step says.
    private let minimumInterval: TimeInterval

    /// Highest bucket already logged. Starts at 0 so a `0 %` callback is silent (see above).
    private var lastLoggedBucket: Int = 0
    /// Timestamp of the last emitted line; `nil` until the first one.
    private var lastLoggedAt: TimeInterval?
    /// Set by any callback with a fraction strictly between 0 and 1, whether or not it earned a line.
    private var sawPartialFraction = false

    /// The source of the bytes, valid once the load has finished. The `[mlx]: download-source` log line
    /// prints it, so a harness scenario can assert "no re-download" on a token instead of on the absence
    /// of percentage lines, which a throttled log could hide.
    public var byteSource: ByteSource { byteSource(freshFileCount: 0) }

    /// The source of the bytes, from two independent signals. A progress callback strictly between 0 and
    /// 1 is the weak one: a real 3.2 GB download once logged only `download 100%`, so the downloader may
    /// send no partial fractions. `freshFileCount`, the number of cached model files written since the
    /// load began (the app counts them on disk), is the strong one. Either signal means `network`.
    public func byteSource(freshFileCount: Int) -> ByteSource {
        (sawPartialFraction || freshFileCount > 0) ? .network : .cache
    }

    public init(step: Double = 0.1, minimumInterval: TimeInterval = 1.0) {
        // A non-positive step would divide the download into infinitely many buckets (a line per
        // callback — the flood this type exists to prevent), so it falls back to the default.
        self.step = step > 0 ? step : 0.1
        self.minimumInterval = max(0, minimumInterval)
    }

    /// Decide whether this progress callback earns a log line.
    ///
    /// - Returns: the **percentage to print** (a multiple of the step, e.g. 10, 20, …) when a line is
    ///   due, `nil` when the callback should be swallowed. Mutating: an emitted line advances the state.
    public mutating func lineDue(fraction: Double, at now: TimeInterval) -> Int? {
        // A NaN fraction (or one outside 0…1) is the downloader misreporting, not progress: clamp rather
        // than let it poison the bucket arithmetic.
        guard fraction.isFinite else { return nil }
        let clamped = min(max(fraction, 0), 1)
        if fraction > 0 && fraction < 1 { sawPartialFraction = true }
        // Nudge before flooring: `0.6 / 0.1` is 5.999… in binary floating point, which would report a
        // download at 60 % as bucket 5 and print `50%`. The epsilon is far below any real step.
        let bucket = Int((clamped / step + 1e-9).rounded(.down))

        // Only forward motion earns a line: a downloader that restarts a file must not walk the log
        // backwards, and it must not re-print a bucket already reported.
        guard bucket > lastLoggedBucket else { return nil }

        if let lastLoggedAt, now - lastLoggedAt < minimumInterval { return nil }

        lastLoggedBucket = bucket
        lastLoggedAt = now
        return Int((Double(bucket) * step * 100).rounded())
    }
}
