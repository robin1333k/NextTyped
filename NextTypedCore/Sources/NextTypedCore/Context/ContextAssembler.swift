/// The predict path's **one** question about the surface under the caret: may it produce a context at
/// all, and if so, here is the **complete** one.
///
/// Before this seam existed, a `TypingContext` was written by three writers at three layers —
/// `AXContextProvider` filled seven fields, `CompositeContextProvider` added `ocrContext`, and the
/// *predict path itself* added `personalization` — so there was no point at which the struct was known
/// complete, and the App was the last writer. This is that point.
///
/// It sits **behind** the `ContextProvider` seam rather than replacing it: the provider still
/// gathers the text, this owns its *composition* — the rejections, the eligibility proof, and the
/// personalization segment.
@MainActor
public protocol ContextAssembling {
    /// A complete `TypingContext`, or the typed `ContextRejection` for a surface that may not produce one
    /// .
    ///
    /// `nil` means **cancelled**, and only that: the assembly awaits, so a caller that cancels mid-flight
    /// gets `nil` back and is expected to check `Task.isCancelled` itself. A rejection is never `nil`.
    func assembledContext() async -> ContextOutcome?
}

/// The capture side of the style profile, as the assembler needs it: a surface it accepted is
/// *proven eligible*, and a context it returns already carries the frozen style segment.
///
/// Two calls rather than one because they answer to different ADRs — the first is a privacy proof
/// , the second a prompt-front segment — and the order between them is what this
/// module now guarantees.
@MainActor
public protocol ContextPersonalizing {
    /// The predict path produced a real context for this surface: the **positive eligibility proof** that
    /// makes own-text capture fail-closed.
    func noteEligibleSurface(bundleID: String?)

    /// The style segment for this burst — selected once per context switch, then frozen.
    func segment(for context: TypingContext) async -> String?
}

/// Assembles the complete `TypingContext` the predict path consumes.
///
/// **Typed rejections, one verdict.** A surface produces no context when it is a secure field, when it is
/// window chrome (both decided by the `ContextProvider` at the earliest trust boundary and
/// arriving here as its `.rejected`), or when the app is **disabled by policy**. Each reason
/// is a `ContextRejection`. The third used to
/// live in the App, two statements deep in `runPredict`, where the other two could not be seen.
///
/// **That `nil` is a privacy guarantee, not a convenience filter.** Reaching `noteEligibleSurface` *is*
/// the fail-closed eligibility proof for own-text capture: keystrokes arrive at
/// the tap before anything knows what field they landed in, so the capture buffer fills optimistically
/// and commits only against that proof. A surface rejected here never produces it, so what was typed
/// into it is **discarded rather than learned**. Whoever moves the rejection below the proof moves a
/// password into the style profile.
///
/// **The policy is read fresh on every call.** `verdict` is a closure, not a stored value, precisely so
/// it cannot be cached into an `init`: today's per-keystroke `UserDefaults` read is what makes the
/// Apps-pane switch take effect on the next prediction with no relaunch and no extra wiring.
///
/// **Personalization is resolved before returning.** A context handed on without its style
/// segment makes the first primed predict look redundant to `SuggestionSession.isRedundant`, which then
/// replays the un-primed suggestion. That was App statement order plus a comment; here it is the module's
/// own invariant — there is no way to obtain a context that has not been through it.
@MainActor
public struct ContextAssembler: ContextAssembling {
    private let provider: ContextProvider
    private let verdict: (SurfaceIdentity) -> EnablementVerdict
    private let log: (String) -> Void
    private let personalization: ContextPersonalizing
    private let languagePolicy: () -> LanguagePolicy
    private let languageIdentifier: LanguageIdentifying?
    private let clipboard: ((TypingContext) async -> String?)?

    /// - Parameters:
    ///   - provider: the seam that gathers the text (and rejects secure fields and chrome).
    ///   - verdict: the enablement policy, **re-read on every call** — see the
    ///     type's note. An app that exposes no bundle ID is judged as `""`, not silently exempted.
    ///   - log: the sink for the `[gate]: app-off` token. App: `acLog`.
    ///   - personalization: the capture side.
    ///   - languagePolicy: the language off switch, **re-read on every call**. With nothing
    ///     switched off the assembler does not touch `languageIdentifier`.
    ///   - languageIdentifier: the port that reads the paragraph tail. `nil` behaves like no policy.
    ///   - clipboard: decides the clipboard context for an accepted surface. Async so the
    ///     pasteboard read runs off the main actor, where the event tap lives. Called only after the
    ///     verdict check and never for a rejected surface, so a disabled app or a secure field never
    ///     reaches the pasteboard or logs a `[clip]` line. `nil` means the source is not wired.
    public init(
        provider: ContextProvider,
        verdict: @escaping (SurfaceIdentity) -> EnablementVerdict,
        log: @escaping (String) -> Void,
        personalization: ContextPersonalizing,
        languagePolicy: @escaping () -> LanguagePolicy = { LanguagePolicy() },
        languageIdentifier: LanguageIdentifying? = nil,
        clipboard: ((TypingContext) async -> String?)?
    ) {
        self.provider = provider
        self.verdict = verdict
        self.log = log
        self.personalization = personalization
        self.languagePolicy = languagePolicy
        self.languageIdentifier = languageIdentifier
        self.clipboard = clipboard
    }

    /// Both `Task.isCancelled` checks are the App's own, kept **here** rather than hoisted to the
    /// caller, and they are not equally load-bearing. The **first** is: it sits before
    /// `noteEligibleSurface`, so a superseded run cannot hand the capture buffer a positive eligibility
    /// proof. The **second** only declines to return a context the caller is about to discard anyway —
    /// hoisting it would be observationally identical, and it is kept because this move is verbatim, not
    /// because it protects anything the first does not.
    public func assembledContext() async -> ContextOutcome? {
        // Fetch context; a rejected surface, or a policy-disabled app, is a typed rejection.
        var outcome = await provider.currentContext()
        if case .context(let raw) = outcome {
            let bundleID = raw.bundleID ?? ""
            let decision = verdict(SurfaceIdentity(bundleID: bundleID, host: raw.siteHost))
            if case .disabled(let reason) = decision, reason != .pause {
                // The one app-off suppression line. `global-off` is logged by the reducer.
                if reason == .siteRule {
                    log("[gate]: site-off host=\(raw.siteHost ?? "") app=\(bundleID)")
                } else {
                    log("[gate]: app-off app=\(bundleID) reason=\(reason.rawValue)")
                }
            }
            if let rejection = decision.rejection { outcome = .rejected(rejection) }
        }
        if Task.isCancelled { return nil }

        // Personalization. Reaching here IS the fail-closed eligibility proof for capture:
        // the provider rejects secure fields and window chrome and the block above
        // turns a disabled app into a rejection too, so none of those surfaces ever proves eligible
        // and their buffer is discarded rather than learned. The injected segment is the one frozen at
        // this burst's context switch, never re-selected per keystroke.
        if case .context(var usable) = outcome {
            personalization.noteEligibleSurface(bundleID: usable.bundleID)
            // Language off switch: after the eligibility proof, so a switched-off
            // language suppresses suggestions but not learning. With nothing
            // switched off this does nothing, not even a port call.
            let policy = languagePolicy()
            if !policy.disabled.isEmpty, let languageIdentifier {
                let tail = LanguagePolicy.paragraphTail(of: usable.textBeforeCaret)
                usable.languageVerdict = policy.verdict(for: languageIdentifier.reading(of: tail))
            }
            // Clipboard context. Last of the verdicts: a surface rejected above,
            // or one whose language is switched off, gets no suggestion, so it must not read the
            // pasteboard (a content read can raise the macOS paste alert) or log a `[clip]` line.
            if let clipboard, !Self.isLanguageOff(usable.languageVerdict) {
                usable.clipboardContext = await clipboard(usable)
                if Task.isCancelled { return nil }
            }
            usable.personalization = await personalization.segment(for: usable)
            if Task.isCancelled { return nil }
            outcome = .context(usable)
        }
        return outcome
    }

    private static func isLanguageOff(_ verdict: LanguageVerdict?) -> Bool {
        if case .off? = verdict { return true }
        return false
    }
}
