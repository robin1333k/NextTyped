import NextTypedCore
import Foundation

/// The App-side effect interpreter for personalization: it owns the **own-inserted capture buffer**, the
/// **frozen selection** for the current typing burst, and the eligibility proof that makes capture
/// fail-closed. Every actual decision is pure Core (`StyleProfile`, `PersonalizationRetrieval`,
/// `PersonalizationCadence`, `OwnInsertBuffer`); this class is timing, IO and gating.
///
/// **Fail-closed capture.** Keystrokes reach the tap before anything knows what field they landed in, so
/// the buffer accumulates optimistically and commits only against a *positive* eligibility proof:
/// `noteEligibleSurface` is called by `ContextAssembler`, and only for a surface it accepted —
/// which rules out a secure field and window chrome (`AXContextProvider.currentContext()` answers `nil`
/// for both) *and* an app disabled by policy. A password field therefore never
/// produces the proof, so its buffer is **discarded** at the next context switch rather than committed.
/// Same shape as the fail-closed speaker separation: no positive match ⇒ store nothing.
///
/// It is the App side of Core's `ContextPersonalizing` — the two calls the context assembler
/// makes: the eligibility proof, then the frozen segment.
@MainActor
final class PersonalizationController: ContextPersonalizing {
    private let store: StyleProfileStore
    private let settings: @Sendable () -> PersonalizationSettings

    // MARK: capture state (one field's worth)

    private var buffer = OwnInsertBuffer()
    /// Set once the predict path proves the current surface produces a real `TypingContext`.
    private var surfaceProvenEligible = false
    /// Set when the focused app is on the learning denylist — the buffer is dropped immediately, not held.
    private var learningBlocked = false

    // MARK: burst state (the frozen segment)

    private var frozen: PersonalizationSelection?
    /// Whether this burst has already run its selection — **including** one that resolved to `nil`. Keying
    /// the cadence on `frozen != nil` instead would re-run the whole store scan on every predict for any
    /// user whose profile is still below the injection minimum.
    private var selectionResolved = false
    private var predictsSinceSwitch = 0
    /// Identifies the current burst. A selection that comes back after its switch is over must not be
    /// installed into the *next* field's front (which is frozen against a different context).
    private var burstID = 0

    /// Called whenever the store's "can it save?" answer changes. The state's real
    /// transitions happen on the store actor — it is *entered* by a failed load at preload and *left* by
    /// the retry inside `ingest` — so it has to be **pushed**. Refreshing it only when a settings view
    /// appears would leave the warning standing after a retry had already fixed it: the same invisibility
    /// this ticket is about, inverted into a false alarm.
    var onProfileSaveabilityChanged: ((Bool) -> Void)?
    private var lastReportedUnreadable = false

    init(store: StyleProfileStore, settings: @escaping @Sendable () -> PersonalizationSettings) {
        self.store = store
        self.settings = settings
    }

    /// Warm the encrypted store at app start so the first context switch pays no decrypt+parse.
    func preload() {
        guard settings().enabled else { return }
        Task { [store] in
            await store.preload()
            await reportSaveability()
        }
    }

    /// Re-read the stall latch and push it if it moved, without touching the store's contents. The one
    /// transition `preload()` cannot cover: switching the feature **off** ends the stall by the user's own
    /// choice (`reportSaveability` already reads a disabled feature as not-unreadable), but every other
    /// call site lives in `ingest`/`commit`/`reset`, none of which run once capture is off — so the
    /// warning would stand until the next launch.
    func refreshSaveability() {
        Task { await reportSaveability() }
    }

    /// Read the stall latch off the store and push it on if it moved.
    private func reportSaveability() async {
        let unreadable = settings().enabled ? await store.isUnreadable() : false
        guard unreadable != lastReportedUnreadable else { return }
        lastReportedUnreadable = unreadable
        onProfileSaveabilityChanged?(unreadable)
    }

    // MARK: Capture (own-inserted text only)

    /// A typed character seen at the event tap.
    func noteTyped(_ text: String) {
        guard isCapturing else { return }
        buffer.insert(text)
    }

    /// Text WE inserted: an accepted ghost or an applied correction, via the synthetic-key path
    /// . Accepted text is own text — the style-forming source is "typed **+** accepted".
    func noteOwnInsert(_ text: String) {
        guard isCapturing else { return }
        buffer.insert(text)
    }

    /// A delete key shrank the text: shrink the buffer with it, so the profile never learns characters the
    /// user removed.
    func noteDeletion(_ kind: TextDeletion) {
        guard isCapturing else { return }
        #if DEBUG
        // An undo empties the whole capture run (`OwnInsertBuffer.delete(.undone)`); say so, because the
        // discard is otherwise invisible in the log (standing rule: a suppression must be greppable).
        if kind == .undone, !buffer.isEmpty {
            acLog("[style]: discard reason=undo (%d chars)", buffer.text.count)
        }
        #endif
        buffer.delete(kind)
    }

    /// The predict path produced a real context for this surface — the positive eligibility proof. Also
    /// where the learning denylist is applied, dropping (not merely refusing to commit) what was buffered.
    func noteEligibleSurface(bundleID: String?) {
        guard settings().enabled else { return }
        if let bundleID, settings().learningDisabledBundleIDs.contains(bundleID) {
            // Log on the TRANSITION, not on every predict: `learningBlocked` is reset at each
            // `contextSwitch`, so this is exactly once per surface. A gate that changes behaviour must be
            // greppable (the `Effect.logGate` argument) — without it the denylist is
            // invisible, because with capture never started `commit()` finds an empty buffer and skips
            // even the `[style]: discard` line.
            #if DEBUG
            if !learningBlocked { acLog("[style]: capture blocked (app denylisted) app=%@", bundleID) }
            #endif
            learningBlocked = true
            buffer.clear()
            return
        }
        surfaceProvenEligible = true
    }

    /// A context switch (focus change): commit what the user wrote in the field we just left, then reset
    /// both the capture and the burst state. This is the ONE cadence at which the profile changes and the
    /// injected segment is re-selected — and it is free, because a context switch already
    /// invalidates the KV-cache.
    func contextSwitch() {
        commit()
        surfaceProvenEligible = false
        learningBlocked = false
        frozen = nil
        selectionResolved = false
        predictsSinceSwitch = 0
        burstID &+= 1
    }

    private func commit() {
        guard settings().enabled else { buffer.clear(); return }
        guard surfaceProvenEligible, !learningBlocked else {
            // No proof that this surface was an eligible, non-denylisted editable field → discard.
            #if DEBUG
            if !buffer.isEmpty {
                acLog("[style]: discard buffer (%d chars, surface never proven eligible)",
                      buffer.text.count)
            }
            #endif
            buffer.clear()
            return
        }
        guard let ownText = buffer.takeAll() else { return }
        Task { [store] in
            await store.ingest(ownText: ownText)
            // The commit is also where a stalled store retries its load, so this is where the answer to
            // "is anything being saved?" can change without any UI having asked.
            await reportSaveability()
        }
    }

    /// Buffering is pointless (and, for a denylisted app, wrong) when the feature is off — so don't even
    /// hold the text in memory.
    private var isCapturing: Bool { settings().enabled && !learningBlocked }

    // MARK: Injection (§11)

    /// The segment for this predict. Byte-stable across the burst once decided; `nil` while waiting for the
    /// ambient harvest, and `nil` for good if the profile is too small to prime with — in which case the
    /// prompt is byte-identical to the no-personalization path.
    ///
    /// The selection is **awaited inline** rather than kicked off as a background Task. It costs a few
    /// milliseconds on the store's executor, once per field, against a ~300 ms prefill — and awaiting buys
    /// the property that matters: the segment is present on the *same* predict that first carried the
    /// ambient context, so the prompt front changes **once** per context switch instead of twice. A
    /// fire-and-forget selection would land one predict later and force a second full re-prefill, which is
    /// precisely the per-keystroke front churn this design exists to avoid.
    func segment(for context: TypingContext) async -> String? {
        guard settings().enabled else { return nil }
        predictsSinceSwitch += 1

        let ambient = ambientQuery(context)
        switch PersonalizationCadence.decide(
            selectionResolved: selectionResolved,
            ambientQueryAvailable: !ambient.isEmpty,
            predictsSinceSwitch: predictsSinceSwitch
        ) {
        case .keepFrozen:
            return frozen?.text
        case .wait:
            return nil
        case .selectWithQuery:
            return await select(query: ambient + " " + context.textBeforeCaret)
        case .selectRecencyOnly:
            return await select(query: context.textBeforeCaret)
        }
    }

    /// The retrieval query: the ambient signals harvested at the switch. At a context
    /// switch the field is often empty, so these — not the prefix — are what answer "what is this about?"
    /// before the first keystroke.
    private func ambientQuery(_ context: TypingContext) -> String {
        [context.windowContext, context.replyContext, context.ocrContext?.ambient]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Run the selection once per switch on the store's executor (the scan tokenizes the whole store, which
    /// does not belong on the main actor). The result — `nil` included — is *frozen* for the burst, so the
    /// prompt front never moves again until the next context switch: the guardrail that keeps
    /// prefix-KV-reuse firing.
    private func select(query: String) async -> String? {
        let burst = burstID
        let selection = await store.select(
            query: query,
            budget: PersonalizationRetrieval.charBudget,
            termLine: Self.termLineFormat)
        // Focus changed (or the profile was reset) while we were selecting: this segment belongs to a field
        // that no longer exists, and the new burst freezes its own.
        guard burstID == burst else { return nil }
        frozen = selection
        selectionResolved = true
        #if DEBUG
        acLog("[style]: selected exemplars=%d chars=%d recencyOnly=%d",
              selection?.exemplarCount ?? 0, selection?.text.count ?? 0,
              (selection?.usedRecencyOnly ?? false) ? 1 : 0)
        #endif
        return selection?.text
    }

    /// The literal term-line arm stays **off** until the offline probe picks a format
    /// : on a base + raw-prefix model a word list is an unproven pseudo-instruction, and the
    /// vocabulary signal already reaches the model as prose through the selection bias.
    private static let termLineFormat = PersonalizationRetrieval.TermLineFormat.none

    // MARK: Transparency + reset (the Privacy pane)

    /// Key-free: does a learned-profile file exist on disk? See `StyleProfileStore.profileFileExists()`.
    func profileFileExists() -> Bool { store.profileFileExists() }

    func learnedProfile() async -> StyleProfile {
        await store.snapshot()
    }

    /// Forget everything: in-memory buffer, resident profile, the encrypted file and the Keychain key.
    ///
    /// The `burstID` bump is load-bearing: a selection made *before* the reset must not be installed
    /// afterwards — "delete my profile" cannot leave deleted sentences in the next prompt.
    func reset() async {
        buffer.clear()
        frozen = nil
        selectionResolved = false
        burstID &+= 1
        await store.reset()
        await reportSaveability()
    }
}
