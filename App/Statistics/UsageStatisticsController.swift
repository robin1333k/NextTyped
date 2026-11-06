import NextTypedCore
import Foundation

/// The App-side collector for local usage statistics: it accumulates one
/// surface's worth of counters and commits them against the **same fail-closed eligibility proof** the
/// style profile's capture uses. Every arithmetic decision is pure Core (`UsageStatistics`,
/// `TypingRate`, `AcceptedWordCount`); this class is timing, gating and IO.
///
/// **Fail-closed, for the same reason and by the same mechanism.** Keystrokes reach the tap before
/// anything knows what field they landed in, so the batch accumulates optimistically and is committed
/// only once `noteEligibleSurface` — called from the predict path, which is reached only when
/// `AXContextProvider.currentContext()` returned a context *and* the app is enabled — has proved the
/// surface. A password field, window chrome, a disabled app and a paused session never produce that
/// proof, so their keystrokes are **discarded** at the next context switch rather than counted. That is
/// also what makes the figures interpretable: they describe writing on surfaces NextTyped actually
/// works on, which is the only place "keystrokes per minute" and "words accepted" mean the same thing.
///
/// **It does not obey the learning denylist** (`personalizationLearningDisabledBundleIDs`), and that is
/// a decision rather than an oversight. The denylist is
/// the *learning-source* control — a statement about not storing an app's **content** — and this
/// store holds no content: a bundle ID and a count. The surprising case the question raises (a password
/// manager appearing in a usage chart) is closed one layer earlier and more strongly: a secure field
/// yields no context, so it never proves eligible and is never recorded at all.
///
/// **There is no on/off switch**, deliberately: the controls the user asked for are *viewable* and
/// *deletable*, both of which the Statistics pane provides, and a per-app row exists only for apps where
/// completions are enabled in the first place.
@MainActor
final class UsageStatisticsController {
    private let store: UsageStatisticsStore

    /// Counters for the field we are in, not yet committed.
    private var pending = UsageBatch()
    /// Set once the predict path proved the current surface produces a real `TypingContext`.
    private var surfaceProvenEligible = false

    /// Monotonic — a wall clock that steps (DST, an NTP correction) must not be able to inflate measured
    /// typing time. The day the batch lands on still comes from the calendar; a rate must not.
    private let clock = ContinuousClock()
    private var lastKeystrokeAt: ContinuousClock.Instant?

    /// Today's accepted words for the menu bar. The ledger mirrors the store's figure for
    /// today so an accept shows at once and is never counted again when its batch commits.
    private var ledger = TodayAcceptedWords()
    private var lastPublishedWords: Int?
    /// Called on the main actor with the figure whenever it changes.
    var onTodayWordsChange: ((Int) -> Void)?

    init(store: UsageStatisticsStore) {
        self.store = store
    }

    /// Read the file at app start so the first flush pays no decode.
    func preload() {
        Task { [store] in
            await store.preload()
            let stored = await store.snapshot().acceptedWords(on: UsageDay.today())
            ledger.seed(storedToday: stored)
            publishWords()
        }
    }

    /// Today's accepted words as the menu bar shows them.
    var todayWords: Int { ledger.displayed }

    /// Emits the figure if it changed (or has never been emitted).
    func publishWords() {
        let words = ledger.displayed
        guard words != lastPublishedWords else { return }
        lastPublishedWords = words
        onTodayWordsChange?(words)
    }

    /// `NSCalendarDayChanged`: a new day starts at 0.
    func dayChanged() {
        ledger.startNewDay()
        publishWords()
    }

    // MARK: Collection

    /// A character-producing keystroke seen at the tap. Navigation, deletes and shortcuts are not typing
    /// and are not counted — the rate is meant to describe writing.
    func noteTyped() {
        let now = clock.now
        let gap = lastKeystrokeAt.map { last -> Double in
            let elapsed = last.duration(to: now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        }
        lastKeystrokeAt = now
        pending.keystrokes += 1
        pending.activeSeconds += TypingRate.activeSeconds(sincePreviousKeystroke: gap)
    }

    /// Words an accept actually inserted (`AcceptedWordCount`, counted at the intercept site so a
    /// correction and a type-along advance cannot be mistaken for one).
    func noteAccepted(words: Int) {
        guard words > 0 else { return }
        pending.acceptedWords += words
        ledger.noteAccepted(words: words)
        publishWords()
    }

    /// The predict path produced a real context for this surface — the positive eligibility proof, and
    /// the only place a bundle ID enters the statistics.
    func noteEligibleSurface(bundleID: String?) {
        surfaceProvenEligible = true
        ledger.noteEligibleSurface()
        if let bundleID { pending.bundleID = bundleID }
        // Commit here rather than on a keystroke threshold. A predict runs per keystroke anyway, so this
        // is one actor hop against an inference — and it means a quit can only ever lose what has not
        // been typed *and* predicted on, instead of up to a sentence of it.
        flush(force: false)
    }

    /// A context switch (focus change): commit what was written in the field we just left, or discard it
    /// if that field never proved eligible.
    func contextSwitch() {
        flush(force: true)
        surfaceProvenEligible = false
        pending.clear()
        lastKeystrokeAt = nil
        ledger.contextSwitch()
        publishWords()
    }

    /// Ask for a write-through at shutdown. Stated honestly because it is easy to over-trust: nothing
    /// asynchronous is guaranteed to run out of `applicationWillTerminate`, so this is best-effort and
    /// the real protection is the store's short debounce — a quit costs at most the last couple of
    /// seconds of counters, which for a usage counter is the right trade against a write per keystroke.
    func shutdown() {
        flush(force: true)
        Task { [store] in await store.flush() }
    }

    private func flush(force: Bool) {
        guard !pending.isEmpty else { return }
        guard surfaceProvenEligible else {
            // No proof (yet) that this surface is an eligible editable field. Keep accumulating — the
            // proof arrives one predict later and those keystrokes are genuinely this surface's. Only a
            // context switch, which ends the surface's chance to prove itself, discards them.
            guard force else { return }
            #if DEBUG
            acLog("[stats]: discard %d keystrokes (surface never proven eligible)", pending.keystrokes)
            #endif
            pending.clear()
            return
        }
        let batch = pending
        pending.clear()
        // The bundle ID survives the flush: the surface has not changed, only the batch boundary.
        pending.bundleID = batch.bundleID
        let day = UsageDay.today()
        #if DEBUG
        // Not on every batch: with a flush per predict that would be a line per keystroke. An accept is
        // the event worth seeing (it is the figure whose definition is contestable), and a context
        // switch is where a whole field's keystrokes land.
        if batch.acceptedWords > 0 || force {
            acLog("[stats]: record words=%d keys=%d active=%.1fs app=%@",
                  batch.acceptedWords, batch.keystrokes, batch.activeSeconds, batch.bundleID ?? "?")
        }
        #endif
        Task { [store] in await store.record(batch, on: day) }
        ledger.commit()
        publishWords()
    }

    // MARK: The Statistics pane

    func statistics() async -> UsageStatistics {
        await store.snapshot()
    }

    /// Forget everything: the pending batch, the resident copy and the file.
    func reset() async {
        pending.clear()
        surfaceProvenEligible = false
        lastKeystrokeAt = nil
        ledger.reset()
        publishWords()
        await store.reset()
    }
}
