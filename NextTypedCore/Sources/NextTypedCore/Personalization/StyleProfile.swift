import Foundation

/// One stored sentence of the user's own writing — the channel that transfers **voice** into a base
/// completion model (the `windowContext` eval showed prose lifts acceptance where word-bags
/// do not).
public struct StyleExemplar: Codable, Equatable, Sendable {
    /// The sentence as the user wrote it (own-inserted text only).
    public var text: String
    /// Monotonic **capture ordinal**, not a wall-clock date: Core stays time-free, and
    /// LRU eviction plus the retrieval recency term only ever need an *order*.
    public var capturedAt: Int
    /// Dominant language tag, set by the App at capture (`NLLanguageRecognizer`). Stored now so a
    /// **language-selective ship** (plausibly EN-GO / DE-no-GO) needs no re-learn; nothing
    /// filters on it yet.
    public var language: String?

    public init(text: String, capturedAt: Int, language: String? = nil) {
        self.text = text
        self.capturedAt = capturedAt
        self.language = language
    }
}

/// A characteristic term's running weight. `score` is recency-decayed frequency, `lastSeenAt` the capture
/// ordinal of its most recent occurrence (the eviction tie-break).
public struct TermStat: Codable, Equatable, Sendable {
    public var score: Double
    public var lastSeenAt: Int

    public init(score: Double, lastSeenAt: Int) {
        self.score = score
        self.lastSeenAt = lastSeenAt
    }
}

/// The **style profile**: what NextTyped has learned from the user's own text, as two
/// blended signals — sentence **exemplars** (voice, §5) and a **characteristic-term table**
/// (vocabulary, §6) — plus the capture ordinal that orders both.
///
/// Pure, `Codable`, and time-free. The App owns everything this deliberately does not know about:
/// *where* the text came from (own-inserted capture only — the trust invariant lives at the capture
/// site), when it is committed, and how the file is encrypted at rest.
///
/// The one behaviour worth stating twice: a **deduplicated sentence still counts its terms**. Repeated
/// greetings and sign-offs must not flood the exemplar store — their voice signal is captured once — but
/// their *frequency* signal is exactly what makes their vocabulary characteristic (§5).
public struct StyleProfile: Codable, Equatable, Sendable {
    /// Sentence exemplars, oldest first (so eviction is `removeFirst`).
    public var exemplars: [StyleExemplar] = []
    /// Characteristic terms → recency-decayed weight, keyed lowercased.
    public var terms: [String: TermStat] = [:]
    /// The capture ordinal. Advanced once per `ingest`, i.e. once per committed field.
    public var clock: Int = 0

    /// True while nothing has been learned: no sentence and no term. The Privacy pane disables its delete
    /// row on this.
    public var isEmpty: Bool { exemplars.isEmpty && terms.isEmpty }

    // MARK: Tunables (at the lower/middle end of the design ranges)

    /// ~1000–2000 exemplars. At ~50–100 B each this is a few hundred KB — negligible on disk and
    /// against the RAM budget.
    public static let exemplarCap = 1500
    /// ~500–1000 terms.
    public static let termCap = 800
    /// Below this the profile injects **nothing** (§9): a single sentence would skew rather than prime,
    /// so first-run is a clean no-op instead of a wrong guess.
    public static let minimumExemplars = 3
    /// Shortest clause worth keeping as a voice sample. "Danke!" is a reflex, not a style signal.
    static let minimumExemplarWords = 3
    /// Per-commit multiplicative decay on every term score. Keeps *current* vocabulary dominant as style
    /// drifts, which is why §5 needs no hard staleness cutoff.
    static let decayPerCommit = 0.99
    /// Token-set Jaccard at or above which an incoming exemplar is a near-duplicate (§5).
    static let duplicateJaccard = 0.85
    /// A shorter exemplar that is a word-prefix of a longer one is a duplicate once it is at least this
    /// many words (below it, a shared opening is coincidence, not repetition).
    static let prefixDuplicateWords = 5

    public init() {}

    /// True once the store holds enough to be worth injecting (§9). Below it the provider returns `nil`
    /// and the prompt is byte-identical to the no-personalization path.
    public var hasEnoughToInject: Bool { exemplars.count >= Self.minimumExemplars }

    /// The characteristic terms, strongest first.
    public var characteristicTerms: [String] {
        terms.sorted {
            $0.value.score != $1.value.score ? $0.value.score > $1.value.score : $0.key < $1.key
        }.map(\.key)
    }

    /// Learn from one field's worth of **own-inserted** text: segment it into clauses, add the new
    /// exemplars, and count every clause's terms (deduped sentences included).
    ///
    /// - Parameter language: the App's `NLLanguageRecognizer` verdict for the whole buffer, stamped onto
    ///   each exemplar for the future language-selective gate.
    public mutating func ingest(ownText: String, language: String? = nil) {
        let clauses = Self.segment(ownText)
        guard !clauses.isEmpty else { return }
        clock += 1
        decayTerms()
        // Tokenize the stored exemplars ONCE per commit, not once per candidate clause: the dedup test is
        // a scan over the whole store, and re-tokenizing 1500 sentences per clause turned a
        // few-milliseconds off-path commit into a visible one.
        var storedTokens = exemplars.map { Self.tokens($0.text) }
        for clause in clauses {
            countTerms(in: clause)
            insert(clause, language: language, storedTokens: &storedTokens)
        }
        evictTerms()
        evictExemplars()
    }

    /// Forget everything (the Privacy-pane reset; the App additionally deletes the file and
    /// the Keychain key, which is what makes the reset irreversible).
    public mutating func reset() {
        exemplars = []
        terms = [:]
        clock = 0
    }

    // MARK: Segmentation

    /// Cut an own-inserted stream into exemplar-sized clauses with the **existing** `ClauseStop` boundary
    /// rule (one definition of "where does a sentence end" across the whole system).
    ///
    /// The trailing fragment with no boundary yet is **dropped**: focus left mid-sentence, and half a
    /// sentence is not a voice sample.
    public static func segment(_ text: String) -> [String] {
        var rest = Substring(text)
        var clauses: [String] = []
        while !rest.isEmpty {
            guard let clause = ClauseStop.firstClause(String(rest)) else { break }
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            if WordTokenizer.wordCount(trimmed) >= minimumExemplarWords {
                clauses.append(trimmed)
            }
            rest = rest.dropFirst(clause.count)
            // `firstClause` excludes the newline it stopped at, so skip the boundary run explicitly or
            // the next iteration would re-read the same (now content-free) prefix and never terminate.
            while let first = rest.first, first.isWhitespace || first.isNewline { rest = rest.dropFirst() }
        }
        return clauses
    }

    // MARK: Store A — exemplars

    private mutating func insert(_ clause: String, language: String?, storedTokens: inout [[String]]) {
        let incoming = Self.tokens(clause)
        guard !incoming.isEmpty else { return }
        let key = incoming.joined(separator: " ")
        for existing in storedTokens {
            if Self.isDuplicate(incoming: incoming, incomingKey: key, existing: existing) { return }
        }
        exemplars.append(StyleExemplar(text: clause, capturedAt: clock, language: language))
        storedTokens.append(incoming)
    }

    /// The §5 near-duplicate rule, in three tiers: normalized equality (case / whitespace / final
    /// punctuation), high token-set overlap, and word-prefix containment. The pre-existing
    /// exact-immediate-repeat check the harvest uses is insufficient — sign-offs vary by a word.
    static func isDuplicate(incoming: [String], incomingKey: String, existing: [String]) -> Bool {
        if incomingKey == existing.joined(separator: " ") { return true }

        let a = Set(incoming), b = Set(existing)
        let union = a.union(b).count
        if union > 0, Double(a.intersection(b).count) / Double(union) >= duplicateJaccard { return true }

        let (shorter, longer) = incoming.count <= existing.count ? (incoming, existing) : (existing, incoming)
        if shorter.count >= prefixDuplicateWords, longer.starts(with: shorter) { return true }

        return false
    }

    private mutating func evictExemplars() {
        guard exemplars.count > Self.exemplarCap else { return }
        // LRU by capture time. `exemplars` is append-ordered, so the head *is* the oldest.
        exemplars.removeFirst(exemplars.count - Self.exemplarCap)
    }

    // MARK: Store B — terms

    private mutating func decayTerms() {
        for (term, stat) in terms {
            terms[term] = TermStat(score: stat.score * Self.decayPerCommit, lastSeenAt: stat.lastSeenAt)
        }
    }

    private mutating func countTerms(in clause: String) {
        let tokens = Self.tokens(clause)
        for (index, token) in tokens.enumerated() {
            guard Self.isCharacteristic(token) else { continue }
            bump(token)
            // Bigrams catch multi-word names ("Claude Desktop"). Only when BOTH halves are
            // characteristic — pairing a function word with a term ("in Claude") is not a phrase.
            let next = index + 1
            if next < tokens.count, Self.isCharacteristic(tokens[next]) {
                bump(token + " " + tokens[next])
            }
        }
    }

    private mutating func bump(_ term: String) {
        let previous = terms[term]?.score ?? 0
        terms[term] = TermStat(score: previous + 1, lastSeenAt: clock)
    }

    /// Characteristic = long enough, not a bare number, and absent from the **union** EN+DE common-word
    /// denylist (§6).
    static func isCharacteristic(_ token: String) -> Bool {
        guard token.count >= CommonWords.minimumTermLength else { return false }
        guard token.contains(where: { $0.isLetter }) else { return false }
        return !CommonWords.union.contains(token)
    }

    private mutating func evictTerms() {
        guard terms.count > Self.termCap else { return }
        let ranked = terms.sorted {
            $0.value.score != $1.value.score
                ? $0.value.score < $1.value.score
                : $0.value.lastSeenAt < $1.value.lastSeenAt
        }
        for (term, _) in ranked.prefix(terms.count - Self.termCap) { terms.removeValue(forKey: term) }
    }

    // MARK: Tokenization

    /// Lowercased word tokens: letters and digits only, everything else a separator. Used for dedup,
    /// term extraction and retrieval scoring, so all three agree on what a "word" is. Deliberately not
    /// `WordTokenizer` (which splits on whitespace only, keeping punctuation glued on for `Tab`-accept).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }
}
