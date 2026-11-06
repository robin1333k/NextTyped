import Foundation

/// The **perceptual-hash pre-diff** ("built in v1"): skip the expensive
/// `.accurate` Vision pass when the screen looks the same as it did last time.
///
/// The cadence rules bound *how often* OCR may run; this bounds *whether it is worth running at all*.
/// A user re-reading the same reference window can sit through many eligible windows without a single
/// pixel changing — and a full-screen recognition pass to re-derive identical text is the exact cost
/// the design sets out to avoid.
///
/// Classic **dHash**: the App downsamples one capture to a `(width+1) × height` grayscale grid (cheap —
/// no recognition involved), and this compares each pixel with its right-hand neighbour into a bit
/// string. Gradient comparison rather than absolute luma makes it robust to brightness/wallpaper shifts
/// while still flipping bits when text or window layout changes.
public enum PerceptualScreenHash {
    /// Rows of the downsample grid. With `width + 1 = 9` samples per row this yields a 64-bit hash.
    public static let gridHeight = 8
    /// Comparison columns per row (the grid the App produces is `gridWidth + 1` wide).
    public static let gridWidth = 8

    /// Hamming distance below which two captures count as visually unchanged. Non-zero on purpose:
    /// a blinking caret, a clock digit, or an antialiasing shift must not force a pass.
    public static let unchangedThreshold = 4

    /// Build a dHash from a row-major grayscale grid of `gridHeight` rows × `gridWidth + 1` samples,
    /// each 0…1 (or 0…255 — only the comparison between neighbours matters).
    ///
    /// Returns `nil` when the grid isn't the expected shape, so a malformed capture degrades to
    /// "unknown ⇒ run the pass" rather than to a false "unchanged" that would freeze the context.
    public static func hash(grayscaleGrid grid: [[Double]]) -> UInt64? {
        guard grid.count == gridHeight else { return nil }
        var bits: UInt64 = 0
        var index = 0
        for row in grid {
            guard row.count == gridWidth + 1 else { return nil }
            for column in 0..<gridWidth {
                if row[column] < row[column + 1] { bits |= (1 << UInt64(index)) }
                index += 1
            }
        }
        return bits
    }

    /// Number of differing bits between two hashes.
    public static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Whether the screen is unchanged enough to skip recognition. An absent previous hash means we
    /// have nothing to compare against — always run (fail toward correct context, not toward cheap).
    public static func isUnchanged(previous: UInt64?, current: UInt64, threshold: Int = unchangedThreshold)
        -> Bool
    {
        guard let previous else { return false }
        return distance(previous, current) <= threshold
    }
}
