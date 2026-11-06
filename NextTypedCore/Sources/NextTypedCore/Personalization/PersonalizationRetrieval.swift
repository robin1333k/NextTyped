import Foundation

/// The frozen personalization segment plus what went into it — the segment the prompt front injects and
/// the numbers the DEBUG log reports (what the prompt *contains* should be measurable, not inferred).
public struct PersonalizationSelection: Equatable, Sendable {
    /// The injected text: the optional term line, then the selected exemplars as prose.
    public var text: String
    public var exemplarCount: Int
    /// The literal characteristic-term line, when the eval-gated arm is enabled (`nil` otherwise).
    public var termLine: String?
    /// True when nothing in the query matched, so the selection is "current voice" rather than
    /// "voice about this topic" (the recency-top fallback).
    public var usedRecencyOnly: Bool

    public init(text: String, exemplarCount: Int, termLine: String? = nil, usedRecencyOnly: Bool) {
        self.text = text
        self.exemplarCount = exemplarCount
        self.termLine = termLine
        self.usedRecencyOnly = usedRecencyOnly
    }
}

/// **Context-cadenced lexical retrieval**: pick the exemplars that fit the current ambient
/// context, pack them into a small char budget, and hand back a segment that stays byte-stable for the
/// whole typing burst.
///
/// Lexical term-overlap + recency, **no embedding model**. Two reasons make that the right call rather
/// than a compromise: the cadence (this runs ~once per field, off-path, so vector speed is moot) and the
/// statistic — the characteristic-term table *already is* the scoring signal, TF-IDF-flavored, and any
/// additional resident model is standing RAM the model-residency ladder would have to manage.
public enum PersonalizationRetrieval {
    /// ~⅓ of `windowContext`'s 1500-char budget: ~120–150 tokens ≈ 3–5 short sentences,
    /// deliberately the *smallest* front segment, because voice-priming saturates early.
    ///
    /// A char cap is a **packing** limit, not a presence guarantee: whether the segment reaches the model
    /// is decided post-encode by `PrefixReuse.window`, which evicts the front first — and personalization
    /// sits front-most (§10). That is aligned with need: the profile matters when the typed prefix is
    /// short, and is redundant once the user's own writing fills the window in-context.
    public static let charBudget = 600
    /// Ceiling on exemplars regardless of budget — beyond a handful of sentences the prime stops adding
    /// voice and starts adding noise.
    public static let maxExemplars = 5
    /// How many characteristic terms the (eval-gated) term line carries.
    public static let termLineLength = 6

    /// A shared query term counts once; one that is also *characteristic for this user* counts double —
    /// this is how the vocabulary signal biases selection without a pseudo-instruction (§3).
    static let characteristicTermBoost = 2.0
    /// Recency's share of the score. Small: topical fit should win, with recency breaking ties and
    /// keeping current voice ahead of equally-relevant old voice.
    static let recencyWeight = 0.5
    /// How many top terms count as "characteristic" for the boost above.
    static let boostedTermCount = 50

    /// Format candidates for the literal term line. The label form ("Wörter die ich
    /// nutze:") is rejected up front — the shipping model is a *base* model and would echo the label into
    /// ghosts. Which of the remaining candidates ships (if any) is decided by
    /// the offline probe's sub-arm; **`.none` is the default until that GO**.
    public enum TermLineFormat: Equatable, Sendable {
        case none
        /// Candidate (a), the first-build default *when enabled*: bare space-joined terms, no label.
        case spaceJoined
        /// Candidate (b).
        case commaJoined
    }

    /// Select the segment for a context switch.
    ///
    /// - Parameters:
    ///   - query: the ambient signals harvested at the switch (`windowContext`, `replyContext`, any
    ///     field text). Empty or non-matching → recency-top.
    ///   - budget: char cap for the whole segment, term line included (it must beat the sentence it
    ///     displaces).
    /// - Returns: `nil` when the profile is too small to prime with (§9) or nothing fits the budget — in
    ///   both cases the prompt stays byte-identical to the no-personalization path.
    public static func select(
        profile: StyleProfile,
        query: String,
        budget: Int = charBudget,
        termLine format: TermLineFormat = .none
    ) -> PersonalizationSelection? {
        guard profile.hasEnoughToInject else { return nil }

        let queryTokens = Set(StyleProfile.tokens(query))
        let boosted = Set(profile.characteristicTerms.prefix(boostedTermCount))
        let clockRange = recencyRange(profile)

        var scored: [(exemplar: StyleExemplar, overlap: Double, score: Double)] = []
        for exemplar in profile.exemplars {
            let overlap = self.overlap(exemplar: exemplar, queryTokens: queryTokens, boosted: boosted)
            let recency = self.recency(exemplar.capturedAt, in: clockRange)
            scored.append((exemplar, overlap, overlap + recency * recencyWeight))
        }

        let usedRecencyOnly = scored.allSatisfy { $0.overlap == 0 }
        // Sort by score, then newest-first — so the recency-only fallback is exactly "current voice".
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.exemplar.capturedAt > $1.exemplar.capturedAt
        }

        let line = termLineText(profile: profile, format: format)
        var text = line ?? ""
        var count = 0
        for candidate in ranked.prefix(maxExemplars) {
            let addition = text.isEmpty ? candidate.exemplar.text : " " + candidate.exemplar.text
            // `continue`, not `break`: fill-to-budget. One over-long top-ranked exemplar must not suppress
            // the whole segment — the shorter candidates behind it still fit, in rank order.
            guard text.count + addition.count <= budget else { continue }
            text += addition
            count += 1
        }
        guard count > 0 else { return nil }

        return PersonalizationSelection(
            text: text, exemplarCount: count, termLine: line, usedRecencyOnly: usedRecencyOnly)
    }

    /// Shared-token count, with the user's own characteristic terms weighted double, damped by the
    /// exemplar's length so a long sentence doesn't win on sheer surface area.
    static func overlap(exemplar: StyleExemplar, queryTokens: Set<String>, boosted: Set<String>) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let tokens = StyleProfile.tokens(exemplar.text)
        guard !tokens.isEmpty else { return 0 }
        var sum = 0.0
        for token in Set(tokens) where queryTokens.contains(token) {
            guard StyleProfile.isCharacteristic(token) else { continue }
            sum += boosted.contains(token) ? characteristicTermBoost : 1
        }
        return sum / Double(tokens.count).squareRoot()
    }

    private static func recencyRange(_ profile: StyleProfile) -> ClosedRange<Int>? {
        let stamps = profile.exemplars.map(\.capturedAt)
        guard let low = stamps.min(), let high = stamps.max(), low < high else { return nil }
        return low...high
    }

    /// 0 (oldest) … 1 (newest). A single-batch profile has no spread, so everything scores 1.
    static func recency(_ capturedAt: Int, in range: ClosedRange<Int>?) -> Double {
        guard let range else { return 1 }
        return Double(capturedAt - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    static func termLineText(profile: StyleProfile, format: TermLineFormat) -> String? {
        guard format != .none else { return nil }
        let terms = Array(profile.characteristicTerms.prefix(termLineLength))
        guard !terms.isEmpty else { return nil }
        switch format {
        case .none:        return nil
        case .spaceJoined: return terms.joined(separator: " ") + " "
        case .commaJoined: return terms.joined(separator: ", ") + " "
        }
    }
}

/// **When** retrieval runs. Split out as a pure decision because getting it wrong is
/// what would forfeit prefix-KV-reuse: a front segment that changes per keystroke invalidates the cache
/// from the change point onward — the ~356 ms re-prefill death-spiral that commit-after-prefill avoids.
///
/// So: at most **one** selection per context switch, fired when the ambient harvest lands (not on the
/// bare switch instant, where the async harvest hasn't produced anything yet), then frozen.
public enum PersonalizationCadence {
    public enum Decision: Equatable, Sendable {
        /// Keep this burst's already-decided segment — the front must not move. Note this covers a
        /// selection that resolved to **nothing**: "nothing to inject" is a decision, and re-deciding it
        /// per keystroke would re-run the whole scan for every user whose profile is still too small.
        case keepFrozen
        /// The harvest landed: select against the ambient query and freeze.
        case selectWithQuery
        /// No harvestable context on this surface: prime with current voice and freeze.
        case selectRecencyOnly
        /// The harvest may still land — inject nothing this predict.
        case wait
    }

    /// Predicts to wait for the harvest before falling back to recency. Small: a couple of keystrokes,
    /// so a surface with no harvestable context still gets primed almost immediately.
    public static let maxWaitedPredicts = 3

    /// - Parameter selectionResolved: whether this burst has already run its selection — **including** a
    ///   selection that returned `nil`. Keying on "is a segment present" instead would make the empty
    ///   verdict re-fire on every predict.
    public static func decide(
        selectionResolved: Bool,
        ambientQueryAvailable: Bool,
        predictsSinceSwitch: Int
    ) -> Decision {
        if selectionResolved { return .keepFrozen }
        if ambientQueryAvailable { return .selectWithQuery }
        return predictsSinceSwitch >= maxWaitedPredicts ? .selectRecencyOnly : .wait
    }
}
