import Foundation

/// **Tier-2 ambient ranking**: which of the other visible content windows earn
/// the ambient prompt slot. Whole-screen capture is cheap to *rank* and expensive to *inject* — the
/// budget admits ~1–2 windows, so the ordering decides what "the reference doc I'm working from" means.
///
/// `score = 0.5·recency + 0.3·size + 0.2·proximity`, each term normalised to 0…1 over the candidate set:
///   - **recency** — how recently the window's app was frontmost before the current one. v1 is
///     **app-level**: the App feeds an ordering derived from the `NSWorkspace`
///     frontmost signal ModelResidency already tracks; window-level recency is a later refinement.
///   - **size** — visible area, normalised against the largest candidate. A big document window is
///     more likely to be the reference than a small utility window.
///   - **proximity** — inverse centroid-distance to the focused window, plus a same-display bonus.
///     What you glance at while writing tends to sit next to what you write in.
///
/// The weights are a deliberate **build-time knob** (measured-later placeholders),
/// exposed as `Weights` so tuning is a value change, not an edit to the scoring maths.
public enum OCRAmbientRanking {
    public struct Weights: Equatable, Sendable {
        public var recency: Double
        public var size: Double
        public var proximity: Double

        public init(recency: Double = 0.5, size: Double = 0.3, proximity: Double = 0.2) {
            self.recency = recency
            self.size = size
            self.proximity = proximity
        }

        public static let `default` = Weights()
    }

    /// A Tier-2 candidate: the window plus the text attributed to it.
    public struct Candidate: Equatable, Sendable {
        public var window: ScreenWindow
        public var text: String
        /// Position in the "recently frontmost" ordering — 0 = the app used most recently before the
        /// current one. `nil` = never seen frontmost this session (scores 0 on recency).
        public var recencyIndex: Int?

        public init(window: ScreenWindow, text: String, recencyIndex: Int? = nil) {
            self.window = window
            self.text = text
            self.recencyIndex = recencyIndex
        }
    }

    /// Minimum window area (points²) to count as a content window rather than a stray palette — part
    /// of the **content floor** the ranking runs over.
    public static let minimumWindowArea: Double = 120 * 120

    /// Minimum recognised characters for a window to be worth a prompt slot: below this the text is
    /// almost certainly labels/badges rather than prose.
    public static let minimumTextChars = 40

    /// Rank the ambient candidates and return the top `limit`, best first.
    ///
    /// Candidates below the content floor (too small, too little text, empty) are dropped before
    /// scoring, so a thin ranking never promotes noise just because nothing better exists.
    public static func rank(
        _ candidates: [Candidate],
        focusedWindowRect: OCRRect?,
        focusedDisplayID: UInt32?,
        limit: Int = 2,
        weights: Weights = .default
    ) -> [Candidate] {
        let eligible = candidates.filter {
            $0.window.rect.area >= minimumWindowArea
                && $0.text.count >= minimumTextChars
        }
        guard !eligible.isEmpty, limit > 0 else { return [] }

        let maxArea = eligible.map(\.window.rect.area).max() ?? 1
        // Normalise recency over the candidate set: index 0 → 1.0, the oldest seen → ~0.
        let maxRecencyIndex = eligible.compactMap(\.recencyIndex).max() ?? 0
        let maxDistance = focusedWindowRect.map { focused in
            eligible.map { $0.window.rect.centroidDistance(to: focused) }.max() ?? 1
        } ?? 1

        let scored = eligible.map { candidate -> (Candidate, Double) in
            let recency: Double = {
                guard let index = candidate.recencyIndex else { return 0 }
                guard maxRecencyIndex > 0 else { return 1 }
                return 1 - Double(index) / Double(maxRecencyIndex)
            }()
            let size = maxArea > 0 ? candidate.window.rect.area / maxArea : 0
            let proximity: Double = {
                guard let focusedWindowRect else { return 0 }
                let distance = candidate.window.rect.centroidDistance(to: focusedWindowRect)
                let near = maxDistance > 0 ? 1 - distance / maxDistance : 1
                let sameDisplay = focusedDisplayID.map { $0 == candidate.window.displayID } ?? false
                // The bonus is folded in then clamped, so a same-display window outranks an equally
                // distant one on another monitor without ever exceeding the term's 0…1 range.
                return min(1, max(0, near) + (sameDisplay ? 0.25 : 0))
            }()
            let score = weights.recency * recency + weights.size * size + weights.proximity * proximity
            return (candidate, score)
        }

        // Stable ordering: ties break by window ID so the prompt front doesn't churn between passes
        // for two equally-scored windows (churn would needlessly invalidate the KV prefix).
        return scored
            .sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.window.windowID < rhs.0.window.windowID : lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }
}
