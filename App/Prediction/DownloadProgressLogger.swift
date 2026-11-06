import NextTypedCore
import Foundation

/// Writes a first-run model download's progress to the log, throttled.
///
/// The download is the only part of the model-distribution feature a user watches, and until now it was
/// the only part no log could show: the fraction reached the menu-bar label and stopped there, so a
/// redirected-log session of a real cold download held 47 seconds of nothing between `downloading …
/// from Hub…` and `model ready`. That also made a **stalled** download indistinguishable from a slow one.
///
/// All this class does is *execute* a decision: the cadence lives in the pure-Core
/// ``ModelDownloadProgressLog``, which is where it is tested. The class exists because the
/// Hub downloader's `progressHandler` is `@Sendable` and fires off a background thread, so the reducer's
/// state needs a lock — the engine's actor isolation is unreachable from inside that closure.
///
/// Constructed **only on the Hub path**, so a local-directory load can emit no download line at all.
final class DownloadProgressLogger: @unchecked Sendable {
    /// Log tag of the model this download belongs to — `mlx` (base) or `fim`.
    private let tag: String
    private let lock = NSLock()
    private var policy = ModelDownloadProgressLog()

    init(tag: String) {
        self.tag = tag
    }

    /// Feed one downloader callback. Logs `[<tag>]: download NN%` when the cadence says a line is due.
    func report(fraction: Double) {
        let now = Double(AppLogClock.millisSinceLaunch()) / 1000
        lock.lock()
        let percent = policy.lineDue(fraction: fraction, at: now)
        lock.unlock()
        guard let percent else { return }
        // Always-compiled, like the other load-lifecycle lines: once-per-machine status, no user text.
        acLog("[%@]: download %d%%", tag, percent)
    }

    /// Log where the bytes came from, once, after the load finished: `[<tag>]: download-source network`
    /// or `cache`. A warm Hub cache still writes `download 100%`, so the percentage lines alone cannot
    /// separate a cache hit from a re-download whose intermediate lines were throttled.
    /// `freshFileCount` comes from the cache on disk, so it holds even when the downloader sends no
    /// partial fraction.
    func reportSource(freshFileCount: Int) {
        lock.lock()
        let source = policy.byteSource(freshFileCount: freshFileCount)
        lock.unlock()
        acLog("[%@]: download-source %@", tag, source.rawValue)
    }
}
