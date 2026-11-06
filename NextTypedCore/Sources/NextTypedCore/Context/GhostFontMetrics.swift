/// Derives the ghost text's point size from a rendered **line-height** when the host exposes no
/// per-character font, so the overlay still matches the host's size instead of a fixed guess.
///
/// Two App-layer paths feed it (both lack a host `.font` attribute):
///   1. The overlay's existing no-host-font fallback — TextEdit/Notes/claude.ai expose value + caret
///      geometry but `kAXAttributedStringForRange` carries no `.font`
/// .
///   2. The Electron/Chromium **text-marker** caret path — the marker attributed string likewise
///      carries no font, so the size is derived from the marker rect's line box
///      (…`).
///
/// Pure Core (plain `Double` points, no AppKit/CoreGraphics): the App passes the AX line box in and
/// gets a point size out — mirroring the `CaretOverlap`/`GlyphBox` seam convention.
public enum GhostFontMetrics {
    /// Empirical ratio of a font's rendered line box to its point size for the system family
    /// (line box ≈ ascender − descender + leading ≈ pointSize × 1.2 ⇒ inverse ≈ 0.82). Chosen to
    /// reproduce the App layer's prior `axRect.height * 0.82` expression exactly (no behaviour change).
    public static let lineHeightToPointSize: Double = 0.82

    /// Smallest point size the ghost is ever drawn at — a tiny or degenerate line box must not yield
    /// an unreadable ghost. Matches the App layer's prior `max(…, 11)` floor.
    public static let minimumPointSize: Double = 11

    /// The point size to render the ghost at, given the host's rendered line-height (AX line box).
    /// Clamped to `minimumPointSize` so a degenerate/tiny line box degrades gracefully.
    public static func pointSize(forLineHeight lineHeight: Double) -> Double {
        max(lineHeight * lineHeightToPointSize, minimumPointSize)
    }
}
