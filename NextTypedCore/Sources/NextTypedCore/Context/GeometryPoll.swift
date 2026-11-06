/// The **idle geometry-poll decision** for the overlay, lifted out of the AX/App
/// layer so the surface-independent churn logic is unit-testable — mirroring `CaretOverlap`.
///
/// While a suggestion is visible the App (`AppCoordinator`) re-reads the caret rect every ~200 ms and
/// re-aligns the ghost on a zoom/scroll/window-move that no gesture event reported (the reliable
/// catch-all). The problem this type fixes: during *active typing* the caret X advances ~8 pt/char, so
/// a naive `>1 pt` change check trips on **every** tick (runtime logs: 2415/2415 and 3045/3045 ticks)
/// and re-renders **redundantly** with the typing path, which already re-rendered that keystroke.
///
/// The rule: the poll fires only when *idle*. While typing flows the typing path owns re-rendering, so
/// `typingActive` suppresses the poll entirely; idle ticks still compare against the previous probe and
/// re-align on a real geometry change.
///
/// Pure Core: the caret rect crosses the App→Core seam as plain `Double`s (`CaretProbe`), mirroring the
/// `GlyphBox`/`FieldDescriptor` convention — no CoreGraphics/AppKit/AX here.
public enum GeometryPoll {
    /// Minimum horizontal/vertical movement (AX points) that counts as a real caret move. Below this is
    /// sub-pixel jitter (in Notes 99 % of caret rects have a fractional X) — not worth a re-render.
    public static let moveThreshold: Double = 1.0
    /// Minimum line-box height delta (AX points) that counts as a zoom. Smaller than the move threshold
    /// because a zoom can rescale height while the caret's x/y barely shift.
    public static let heightThreshold: Double = 0.5

    /// Whether two probes differ enough to warrant re-aligning the ghost. Strictly-greater so an
    /// exactly-threshold delta does not trip (preserves the App's prior comparison verbatim).
    public static func changed(from old: CaretProbe, to new: CaretProbe) -> Bool {
        abs(new.minX - old.minX) > moveThreshold
            || abs(new.minY - old.minY) > moveThreshold
            || abs(new.height - old.height) > heightThreshold
    }

    /// Whether the idle poll should trigger a full re-render this tick.
    ///
    /// - Parameters:
    ///   - probe: the caret rect just read this tick.
    ///   - baseline: the previous tick's probe; `nil` on the first tick after a (re)start, which only
    ///     establishes the baseline (so: never fire).
    ///   - typingActive: a keystroke is actively flowing. The typing path already re-renders each
    ///     keystroke, so the poll must stay quiet.
    /// - Returns: `true` only when idle AND the caret geometry changed vs the baseline.
    public static func shouldRerender(probe: CaretProbe, baseline: CaretProbe?,
                                      typingActive: Bool) -> Bool {
        guard !typingActive, let baseline else { return false }
        return changed(from: baseline, to: probe)
    }
}

/// A minimal caret rectangle carried across the App→Core seam for the idle geometry poll. Plain
/// `Double`s (AX points) keep Core free of CoreGraphics — the App builds these from its `CGRect`
/// caret probe. Only the fields the change check needs: top-left origin + line-box height.
public struct CaretProbe: Equatable, Sendable {
    public var minX: Double
    public var minY: Double
    public var height: Double

    public init(minX: Double, minY: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.height = height
    }
}
