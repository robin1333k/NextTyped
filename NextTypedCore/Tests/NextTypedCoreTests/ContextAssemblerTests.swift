import Testing
@testable import NextTypedCore

/// The assembler is the predict path's ONE question: "may this surface produce a context, and if so,
/// here is the complete one." The cases below are the three ways the answer is `nil` and the ordering
/// rule the module now owns.
///
/// Two of the three rejections — a secure field and window chrome — are decided by the
/// `ContextProvider` at the earliest trust boundary and reach the assembler as its `nil`; the third,
/// per-app disabled, is the assembler's own. They are separate cases here because they are
/// separate *reasons*: a reader looking for "what stops a password field" should find it by name.
@Suite("ContextAssembler — one complete TypingContext, or nil")
@MainActor
struct ContextAssemblerTests {

    // MARK: fakes

    /// Records what the assembler asked for, and answers with whatever the test set.
    final class FakeProvider: ContextProvider, @unchecked Sendable {
        var answer: TypingContext?
        /// What the provider says when `answer` is nil.
        var rejection: ContextRejection
        var calls = 0
        /// Runs inside the assembly, so a test can cancel the enclosing Task mid-run.
        var onCall: (@Sendable () -> Void)?
        init(answer: TypingContext?, rejection: ContextRejection = .noFocus) {
            self.answer = answer
            self.rejection = rejection
        }
        func currentContext() async -> ContextOutcome {
            calls += 1
            onCall?()
            return answer.map(ContextOutcome.context) ?? .rejected(rejection)
        }
    }

    /// The capture side. `eligibleSurfaces` is the fail-closed proof: a surface that
    /// never appears here has its own-text buffer discarded rather than learned.
    @MainActor
    final class FakePersonalization: ContextPersonalizing {
        var eligibleSurfaces: [String?] = []
        var segmentQueries: [TypingContext] = []
        var segment: String?
        /// The order the two calls arrived in, so "eligibility proof, then segment" is observable.
        var callLog: [String] = []

        func noteEligibleSurface(bundleID: String?) {
            eligibleSurfaces.append(bundleID)
            callLog.append("noteEligibleSurface")
        }

        /// Runs inside the assembly, after the eligibility proof — the second cancel point.
        var onSegment: (() -> Void)?

        func segment(for context: TypingContext) async -> String? {
            segmentQueries.append(context)
            callLog.append("segment")
            onSegment?()
            return segment
        }
    }

    private func assembler(
        provider: FakeProvider,
        personalization: FakePersonalization,
        isEnabled: @escaping (String) -> Bool = { _ in true },
        verdict: ((SurfaceIdentity) -> EnablementVerdict)? = nil,
        log: @escaping (String) -> Void = { _ in },
        clipboard: ((TypingContext) async -> String?)? = nil
    ) -> ContextAssembler {
        ContextAssembler(
            provider: provider,
            verdict: verdict ?? { isEnabled($0.bundleID) ? .enabled : .disabled(.override) },
            log: log,
            personalization: personalization,
            clipboard: clipboard)
    }

    // MARK: the three rejections

    @Test("A secure field or window chrome produces no context — the provider's nil is the assembler's nil")
    func providerRejectionIsTheAssemblersRejection() async {
        // ONE case, not two, and deliberately so: a secure field and window chrome
        // are different *reasons* decided inside `AXContextProvider`, but they reach the assembler as the
        // same `nil`. A second case would assert the same branch twice and pretend to coverage the
        // assembler cannot have — the tests for those two reasons belong where the reasons are decided.
        let provider = FakeProvider(answer: nil)
        let personalization = FakePersonalization()

        let context = await assembler(provider: provider, personalization: personalization)
            .assembledContext()?.context

        #expect(context == nil)
        // The privacy half: no eligibility proof, so a password typed into that field is discarded.
        #expect(personalization.eligibleSurfaces.isEmpty)
        #expect(personalization.segmentQueries.isEmpty)
    }

    @Test("A per-app-disabled surface produces no context — and no eligibility proof")
    func perAppDisabledRejected() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "geheim", bundleID: "com.apple.Terminal"))
        let personalization = FakePersonalization()

        let context = await assembler(
            provider: provider, personalization: personalization, isEnabled: { _ in false }
        ).assembledContext()?.context

        #expect(context == nil)
        // the rejection is why a disabled app's buffer is discarded rather than learned. If
        // this ever records a surface, per-app "off" has quietly stopped meaning "learns nothing".
        #expect(personalization.eligibleSurfaces.isEmpty)
        #expect(personalization.segmentQueries.isEmpty)
    }

    @Test("A disabled app gets no clipboard decision; an enabled app gets the injected text")
    func clipboardDecidedOnlyForEnabledApp() async {
        var decided: [String?] = []
        let clip: (TypingContext) async -> String? = { decided.append($0.bundleID); return "copied" }
        let terminal = TypingContext(textBeforeCaret: "geheim", bundleID: "com.apple.Terminal")
        let textEdit = TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit")

        let disabled = await assembler(
            provider: FakeProvider(answer: terminal), personalization: FakePersonalization(),
            isEnabled: { $0 != "com.apple.Terminal" }, clipboard: clip
        ).assembledContext()
        #expect(disabled?.context == nil)
        #expect(decided.isEmpty)

        let enabled = await assembler(
            provider: FakeProvider(answer: textEdit), personalization: FakePersonalization(),
            isEnabled: { $0 != "com.apple.Terminal" }, clipboard: clip
        ).assembledContext()
        #expect(enabled?.context?.clipboardContext == "copied")
        #expect(decided == ["com.apple.TextEdit"])
    }

    @Test("The policy is asked about the focused app")
    func policyAskedAboutFocusedApp() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        var asked: [String] = []

        _ = await assembler(provider: provider, personalization: personalization, isEnabled: { id in
            asked.append(id)
            return true
        }).assembledContext()

        #expect(asked == ["com.apple.TextEdit"])
    }

    @Test("A context with no bundle ID asks the policy about the empty string, as today")
    func missingBundleIDAsksEmptyString() async {
        // Verbatim from the App: `isEnabled(forBundleID: raw?.bundleID ?? "")`. An unknown app is not
        // silently exempt from the policy — it is judged as "".
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: nil))
        let personalization = FakePersonalization()
        var asked: [String] = []

        _ = await assembler(provider: provider, personalization: personalization, isEnabled: { id in
            asked.append(id)
            return true
        }).assembledContext()

        #expect(asked == [""])
    }

    @Test("The policy is re-read on every call, so the Apps-pane switch needs no relaunch")
    func policyReadFreshPerCall() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        var enabled = true
        let subject = assembler(provider: provider, personalization: personalization, isEnabled: { _ in enabled })

        #expect(await subject.assembledContext()?.context != nil)
        enabled = false
        #expect(await subject.assembledContext()?.context == nil)
        enabled = true
        #expect(await subject.assembledContext()?.context != nil)
    }

    // MARK: the complete context

    @Test("An eligible surface returns a context whose personalization is already resolved")
    func personalizationResolvedBeforeReturn() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "Der Zug", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        personalization.segment = "Ich schreibe knapp."

        let context = await assembler(provider: provider, personalization: personalization)
            .assembledContext()?.context

        // the caller must never see a context whose style segment is still missing — the first
        // primed predict would be judged redundant and would replay the un-primed suggestion.
        #expect(context?.personalization == "Ich schreibe knapp.")
        #expect(context?.textBeforeCaret == "Der Zug")
    }

    @Test("The eligibility proof comes before the segment is selected")
    func eligibilityProofPrecedesSelection() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()

        _ = await assembler(provider: provider, personalization: personalization).assembledContext()

        #expect(personalization.callLog == ["noteEligibleSurface", "segment"])
        #expect(personalization.eligibleSurfaces == ["com.apple.TextEdit"])
    }

    @Test("The segment is selected against the surface's own context")
    func segmentSelectedAgainstThisContext() async {
        let provider = FakeProvider(
            answer: TypingContext(textBeforeCaret: "Der Zug", windowContext: "Fahrplan",
                                  bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()

        _ = await assembler(provider: provider, personalization: personalization).assembledContext()

        #expect(personalization.segmentQueries.count == 1)
        #expect(personalization.segmentQueries.first?.windowContext == "Fahrplan")
    }

    @Test("A profile too small to prime with leaves the rest of the context intact")
    func nilSegmentStillReturnsContext() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        personalization.segment = nil

        let context = await assembler(provider: provider, personalization: personalization)
            .assembledContext()?.context

        #expect(context != nil)
        #expect(context?.personalization == nil)
    }

    @Test("The provider is asked exactly once per assembly")
    func providerAskedOnce() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()

        _ = await assembler(provider: provider, personalization: personalization).assembledContext()

        #expect(provider.calls == 1)
    }

    // MARK: cancellation — nil ALSO means "this run was superseded"

    @Test("A run cancelled before the context read answers nil, and proves no surface eligible")
    func cancelledBeforeContextReadProvesNothing() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        let subject = assembler(provider: provider, personalization: personalization)

        // The Task inherits this actor, so it cannot begin until this synchronous region suspends —
        // cancelling here is deterministic, not a race.
        let run = Task { await subject.assembledContext() }
        run.cancel()
        let context = await run.value

        #expect(context == nil)
        // The point of keeping this check INSIDE the assembler: a superseded run must not hand the
        // capture buffer a positive eligibility proof. Hoisting it to the caller — the
        // obvious simplification — would make this expectation fail.
        #expect(personalization.eligibleSurfaces.isEmpty)
        #expect(personalization.segmentQueries.isEmpty)
    }

    @Test("A run cancelled during the segment selection answers nil rather than a half-built context")
    func cancelledDuringSelectionReturnsNil() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        let personalization = FakePersonalization()
        personalization.segment = "Ich schreibe knapp."
        let subject = assembler(provider: provider, personalization: personalization)

        let box = TaskBox()
        personalization.onSegment = { box.task?.cancel() }
        let run = Task { await subject.assembledContext() }
        box.task = run

        #expect(await run.value == nil)
        // Cancellation arrived AFTER the surface was legitimately accepted, so the proof stands — what
        // must not happen is the caller receiving a context from a run it already superseded.
        #expect(personalization.callLog == ["noteEligibleSurface", "segment"])
    }

    // MARK: typed rejections

    @Test("Each provider rejection reaches the caller as its own typed reason, with no eligibility proof",
          arguments: [ContextRejection.noFocus, .secure, .chrome, .noText])
    func providerRejectionKeepsItsReason(reason: ContextRejection) async {
        let provider = FakeProvider(answer: nil, rejection: reason)
        let personalization = FakePersonalization()

        let outcome = await assembler(provider: provider, personalization: personalization)
            .assembledContext()

        #expect(outcome == .rejected(reason))
        #expect(personalization.eligibleSurfaces.isEmpty)
        #expect(personalization.segmentQueries.isEmpty)
    }

    @Test("A policy rejection never proves the surface eligible, for either policy reason")
    func policyRejectionProvesNothing() async {
        for (verdict, expected) in [
            (EnablementVerdict.disabled(.override), ContextRejection.appOff),
            (.disabled(.pause), .globalOff),
        ] {
            let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "geheim", bundleID: "com.apple.TextEdit"))
            let personalization = FakePersonalization()
            let outcome = await assembler(
                provider: provider, personalization: personalization, verdict: { _ in verdict }
            ).assembledContext()
            #expect(outcome == .rejected(expected))
            #expect(personalization.eligibleSurfaces.isEmpty)
            #expect(personalization.segmentQueries.isEmpty)
        }
    }

    @Test("A cancelled assembly is nil, never a rejection")
    func cancelledIsNotARejection() async {
        let provider = FakeProvider(answer: nil, rejection: .secure)
        let subject = assembler(provider: provider, personalization: FakePersonalization())
        let run = Task { await subject.assembledContext() }
        run.cancel()
        #expect(await run.value == nil)
    }

    // MARK: the app-off gate token

    @Test("A rejected surface emits exactly one app-off token with the verdict's reason")
    func appOffTokenPerReason() async {
        let cases: [(DisabledReason, String)] = [
            (.override, "override"), (.blocklist, "blocklist"), (.defaultOff, "default-off"),
        ]
        for (reason, text) in cases {
            let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
            let personalization = FakePersonalization()
            var lines: [String] = []
            let outcome = await assembler(
                provider: provider, personalization: personalization,
                verdict: { _ in .disabled(reason) }, log: { lines.append($0) }
            ).assembledContext()
            #expect(outcome == .rejected(.appOff))
            #expect(lines == ["[gate]: app-off app=com.apple.TextEdit reason=\(text)"])
            #expect(personalization.eligibleSurfaces.isEmpty)
        }
    }

    @Test("A site-rule rejection emits site-off, not app-off, and never proves the surface eligible")
    func siteOffToken() async {
        let provider = FakeProvider(answer: TypingContext(
            textBeforeCaret: "x", bundleID: "com.apple.Safari", siteHost: "mail.example.com"))
        let personalization = FakePersonalization()
        var lines: [String] = []
        var seen: [SurfaceIdentity] = []
        let outcome = await assembler(
            provider: provider, personalization: personalization,
            verdict: { seen.append($0); return .disabled(.siteRule) }, log: { lines.append($0) }
        ).assembledContext()
        #expect(outcome == .rejected(.appOff))
        #expect(lines == ["[gate]: site-off host=mail.example.com app=com.apple.Safari"])
        #expect(seen == [SurfaceIdentity(bundleID: "com.apple.Safari", host: "mail.example.com")])
        #expect(personalization.eligibleSurfaces.isEmpty)
    }

    @Test("A pause is not an app-off token, and still yields no context")
    func pauseEmitsNoAppOffToken() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        var lines: [String] = []
        let outcome = await assembler(
            provider: provider, personalization: FakePersonalization(),
            verdict: { _ in .disabled(.pause) }, log: { lines.append($0) }
        ).assembledContext()
        #expect(outcome == .rejected(.globalOff))
        #expect(lines.isEmpty)
    }

    @Test("An enabled surface emits no token")
    func enabledEmitsNoToken() async {
        let provider = FakeProvider(answer: TypingContext(textBeforeCaret: "x", bundleID: "com.apple.TextEdit"))
        var lines: [String] = []
        let context = await assembler(
            provider: provider, personalization: FakePersonalization(), log: { lines.append($0) }
        ).assembledContext()?.context
        #expect(context != nil)
        #expect(lines.isEmpty)
    }
}

/// Lets a fake cancel the very Task it is running inside: the handle exists only after `Task { … }`
/// returns, and the body cannot start before then, so the assignment always wins the race.
@MainActor
final class TaskBox {
    var task: Task<ContextOutcome?, Never>?
}

extension ContextOutcome {
    /// The context, or nil for a rejection.
    var context: TypingContext? {
        if case .context(let context) = self { return context }
        return nil
    }
}

// MARK: language off switch

@MainActor
extension ContextAssemblerTests {
    final class SpyIdentifier: LanguageIdentifying, @unchecked Sendable {
        var texts: [String] = []
        var answer: LanguageReading?
        init(_ answer: LanguageReading?) { self.answer = answer }
        func reading(of text: String) -> LanguageReading? {
            texts.append(text)
            return answer
        }
    }

    private func languageAssembler(
        disabled: Set<LanguageSelector>, spy: SpyIdentifier, prefix: String
    ) -> ContextAssembler {
        ContextAssembler(
            provider: FakeProvider(answer: TypingContext(textBeforeCaret: prefix, bundleID: "com.test")),
            verdict: { _ in .enabled },
            log: { _ in },
            personalization: FakePersonalization(),
            languagePolicy: { LanguagePolicy(disabled: disabled) },
            languageIdentifier: spy, clipboard: nil)
    }

    @Test("With nothing switched off the identifier is never called and the verdict is nil")
    func emptyDisabledSetDoesNothing() async {
        let spy = SpyIdentifier(nil)
        let outcome = await languageAssembler(disabled: [], spy: spy, prefix: "Hallo Welt").assembledContext()
        guard case .context(let context)? = outcome else { Issue.record("no context"); return }
        #expect(spy.texts.isEmpty)
        #expect(context.languageVerdict == nil)
    }

    @Test("The identifier reads the paragraph tail and the verdict lands on the context")
    func readsTheParagraphTail() async {
        let spy = SpyIdentifier(LanguageReading(tag: "de", probability: 0.95, runnerUpProbability: 0.02, letterCount: 120))
        let outcome = await languageAssembler(disabled: [.tag("de")], spy: spy, prefix: "Erster Absatz.\nZweiter Absatz ").assembledContext()
        guard case .context(let context)? = outcome else { Issue.record("no context"); return }
        #expect(spy.texts == ["Zweiter Absatz "])
        #expect(context.languageVerdict == .off("de"))
    }

    @Test("The language check runs after the eligibility proof")
    func runsAfterTheEligibilityProof() async {
        let spy = SpyIdentifier(LanguageReading(tag: "de", probability: 0.95, runnerUpProbability: 0.02, letterCount: 120))
        let personalization = FakePersonalization()
        let assembler = ContextAssembler(
            provider: FakeProvider(answer: TypingContext(textBeforeCaret: "Hallo", bundleID: "com.test")),
            verdict: { _ in .enabled }, log: { _ in }, personalization: personalization,
            languagePolicy: { LanguagePolicy(disabled: [.tag("de")]) }, languageIdentifier: spy,
            clipboard: nil)
        _ = await assembler.assembledContext()
        #expect(personalization.eligibleSurfaces == ["com.test"])
    }

    @Test("A language-off surface never calls the clipboard port; an allowed language does")
    func languageOffSkipsClipboard() async {
        var calls = 0
        let clip: (TypingContext) async -> String? = { _ in calls += 1; return "copied" }
        let reading = LanguageReading(tag: "de", probability: 0.95, runnerUpProbability: 0.02, letterCount: 120)
        func make(disabled: Set<LanguageSelector>) -> ContextAssembler {
            ContextAssembler(
                provider: FakeProvider(answer: TypingContext(textBeforeCaret: "Hallo Welt", bundleID: "com.test")),
                verdict: { _ in .enabled }, log: { _ in }, personalization: FakePersonalization(),
                languagePolicy: { LanguagePolicy(disabled: disabled) },
                languageIdentifier: SpyIdentifier(reading), clipboard: clip)
        }
        let off = await make(disabled: [.tag("de")]).assembledContext()
        #expect(off?.context?.languageVerdict == .off("de"))
        #expect(off?.context?.clipboardContext == nil)
        #expect(calls == 0)

        let allowed = await make(disabled: [.tag("fr")]).assembledContext()
        #expect(allowed?.context?.clipboardContext == "copied")
        #expect(calls == 1)
    }

    @Test("A secure field, window chrome and a missing text never call the clipboard port")
    func rejectedSurfacesSkipClipboard() async {
        for rejection in [ContextRejection.secure, .chrome, .noText, .noFocus] {
            var calls = 0
            let clip: (TypingContext) async -> String? = { _ in calls += 1; return "copied" }
            let outcome = await ContextAssembler(
                provider: FakeProvider(answer: nil, rejection: rejection),
                verdict: { _ in .enabled }, log: { _ in }, personalization: FakePersonalization(),
                clipboard: clip).assembledContext()
            #expect(outcome?.context == nil)
            #expect(calls == 0)
        }
    }
}
