import Foundation

/// App-wide diagnostic logging.
///
/// Every diagnostic line goes through ``acLog(_:_:)`` so it carries a **monotonic ms-since-launch
/// timestamp**, the one thing the prior `NSLog` output lacked — without it none of the wall-clock
/// analysis the latency budget (T1) needs is possible: keystroke→ghost perceived lag,
/// inter-keystroke cadence under fast typing, and whether a slow predict actually stalled the user.
/// The captures are read from stderr (`open --stderr …`), where the OS syslog timestamp is absent and,
/// even when present, is wall-clock (non-monotonic) and awkward for cadence math.

/// Monotonic milliseconds since first use (≈ app launch). Backed by the monotonic uptime clock
/// (`DispatchTime` / `mach_absolute_time`), so it never jumps backward on a wall-clock change. It does
/// not advance while the system is asleep — fine here, we only correlate lines within a live session.
enum AppLogClock {
    private static let launch = DispatchTime.now().uptimeNanoseconds
    static func millisSinceLaunch() -> UInt64 {
        // Read `launch` FIRST: it is a lazily-initialised static, and evaluating `now()` before its first
        // initialisation made the very first line wrap to ~2^64 ms (seen as `t=18446744073709ms`).
        let origin = launch
        let now = DispatchTime.now().uptimeNanoseconds
        return (now >= origin ? now - origin : 0) / 1_000_000
    }
}

/// Line-buffer the log streams, once, before the first line is written.
///
/// `scripts/run-with-log.sh` hands the process a **file** for stdout and stderr, not a tty, and a file
/// is fully buffered by default — output then sits in a 4 KB block until enough follows it, so a log
/// read while the app is alive is a *truncated* slice and an assertion about an absence ("no commit
/// followed") can be wrong rather than merely weak.
///
/// Measured 2026-08-30 (minimal LSUIElement bundle launched the same way): `stderr` —
/// where `NSLog`, and therefore every ``acLog`` line, lands — is already unbuffered and was never
/// affected; `stdout` is block-buffered exactly as described (0 lines for 2 s, then 58 at once). No
/// app code prints to stdout today, so no diagnostic line has ever lagged; a dependency that does
/// (MLX, the Hub downloader) would surface minutes late and interleaved at the wrong offset. The two
/// `setvbuf` calls make the promptness guarantee **structural** rather than a property of which
/// logging API we happen to call — the `stderr` one is a no-op today and is written down so a future
/// change to it fails loudly instead of silently reintroducing the lag.
///
/// Deliberately a lazy global rather than a `configure()` someone must remember to call from
/// `AppCoordinator.start()`: Swift initialises it exactly once, thread-safely, on first touch, and the
/// only toucher is ``acLog`` itself — so it cannot run after the first line it is meant to protect.
private let logStreamsAreLineBuffered: Bool = {
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
    return true
}()

/// Log a diagnostic line, prefixed with the app tag + a monotonic ms-since-launch timestamp
/// (`NextTyped t=<ms>ms <message>`). Pass the `[tag]: …` format **without** the leading
/// `"NextTyped"` (this adds it); the `printf`-style format and varargs behave exactly like `NSLog`,
/// so existing call sites convert by dropping that literal prefix. Always compiled — call sites keep
/// their own `#if DEBUG` gate, so DEBUG-only lines are still stripped from release.
func acLog(_ format: String, _ args: CVarArg...) {
    // The discarded read IS the point: it runs the global's `setvbuf` side effects exactly once,
    // and necessarily before the first line they exist to make promptly visible.
    _ = logStreamsAreLineBuffered
    // The diagnostics tally sees the line before it gets its timestamp prefix. It keeps only a
    // closed tag and token, so formatting here costs one string for lines that start a tag.
    if format.hasPrefix("[") || format == "%@" {
        let message = withVaList(args) { NSString(format: format, arguments: $0) as String }
        DiagnosticsTallyHub.shared.record(line: message)
    }
    withVaList(args) { NSLogv("NextTyped t=\(AppLogClock.millisSinceLaunch())ms \(format)", $0) }
}
