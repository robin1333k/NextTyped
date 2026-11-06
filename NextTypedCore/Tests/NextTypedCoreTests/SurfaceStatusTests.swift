import Testing
@testable import NextTypedCore

/// the surface verdict a predict run emits, and the order the menu-bar status line composes in.
struct SurfaceStatusTests {

    // MARK: compose order (spec: paused, Accessibility, model, global off, app off, quiet, secure, chrome,
    // no text, no caret, small field, on, no typing yet)

    private func compose(
        paused: Bool = false, accessibility: Bool = true, model: Bool = true, _ verdict: SurfaceVerdict?
    ) -> SurfaceStatus {
        SurfaceStatus.compose(paused: paused, accessibilityGranted: accessibility,
                              modelReady: model, lastVerdict: verdict)
    }

    @Test func pausedWinsOverEverything() {
        #expect(compose(paused: true, accessibility: false, model: false, .rejected(.secure)) == .paused)
    }

    @Test func missingAccessibilityWinsOverModelAndVerdict() {
        #expect(compose(accessibility: false, model: false, .on) == .accessibilityMissing)
    }

    @Test func modelNotReadyWinsOverVerdict() {
        #expect(compose(model: false, .rejected(.appOff)) == .modelNotReady)
    }

    @Test func eachVerdictHasItsOwnStatus() {
        #expect(compose(.rejected(.globalOff)) == .globalOff)
        #expect(compose(.rejected(.appOff)) == .appOff)
        #expect(compose(.temporaryQuiet) == .temporaryQuiet)
        #expect(compose(.rejected(.secure)) == .secure)
        #expect(compose(.rejected(.chrome)) == .chrome)
        #expect(compose(.rejected(.noText)) == .noText)
        #expect(compose(.noCaretGeometry) == .noCaretGeometry)
        #expect(compose(.smallField) == .smallField)
        #expect(compose(.on) == .on)
    }

    @Test func noVerdictAndNoFocusReadAsNoTypingYet() {
        #expect(compose(nil) == .noTypingYet)
        #expect(compose(.rejected(.noFocus)) == .noTypingYet)
    }

    @Test func tokensAreTheKebabNamesTheHarnessGreps() {
        #expect(SurfaceStatus.allCases.map(\.token) == [
            "paused", "accessibility-missing", "model-not-ready", "global-off", "app-off",
            "temporary-quiet", "secure", "chrome", "no-text", "no-caret", "small-field", "on",
            "no-typing-yet",
        ])
    }

    // MARK: the reducer emits exactly one verdict per run

    private func verdicts(_ effects: [Effect]) -> [SurfaceVerdict] {
        effects.compactMap { if case .surfaceVerdict(let v) = $0 { return v } else { return nil } }
    }

    private let noCaretTrouble = CaretFacts(hasTextToRight: false)

    @Test func aRunBlockedOnlyByRunningThoughtArmOneIsOn() {
        var s = SuggestionSession()
        let thin = TypingContext(textBeforeCaret: "Hallo", textAfterCaret: "", bundleID: "com.test")
        let effects = s.handle(.contextReady(thin, caret: noCaretTrouble, trigger: .typing))
        #expect(effects.contains(.logGate("running-thought absent")))
        #expect(verdicts(effects) == [.on])
        #expect(effects.first == .surfaceVerdict(.on))
    }

    @Test func aRejectionIsTheVerdictAndLogsItsReason() {
        for reason in [ContextRejection.noFocus, .secure, .chrome, .noText, .globalOff] {
            var s = SuggestionSession()
            let effects = s.handle(.contextReady(nil, caret: nil, trigger: .typing, rejection: reason))
            #expect(effects == [.surfaceVerdict(.rejected(reason)),
                                .logGate("no-context reason=\(reason.rawValue)"), .present(.none)])
        }
    }

    @Test func appOffIsAVerdictButItsTokenStaysWithTheAssembler() {
        var s = SuggestionSession()
        let effects = s.handle(.contextReady(nil, caret: nil, trigger: .typing, rejection: .appOff))
        #expect(effects == [.surfaceVerdict(.rejected(.appOff)), .present(.none)])
    }

    @Test func forceActivateKeepsItsOwnNoContextToken() {
        var s = SuggestionSession()
        let effects = s.handle(.contextReady(nil, caret: nil, trigger: .forceActivate, rejection: .secure))
        #expect(effects == [.surfaceVerdict(.rejected(.secure)),
                            .logGate("force-activate no-context"),
                            .logGate("no-context reason=secure"), .present(.none)])
    }

    @Test func aSmallFieldIsSmallField() {
        var s = SuggestionSession()
        let search = TypingContext(
            textBeforeCaret: "que", textAfterCaret: "", bundleID: "com.test",
            field: FieldDescriptor(role: "AXTextField", subrole: "AXSearchField"))
        let effects = s.handle(.contextReady(search, caret: noCaretTrouble, trigger: .typing))
        #expect(verdicts(effects) == [.smallField])
    }

    @Test func aTemporaryQuietIsTemporaryQuiet() {
        var s = SuggestionSession()
        _ = s.handle(.temporaryQuietStarted(bundleID: "com.test"))
        let ctx = TypingContext(textBeforeCaret: "Der Hund laeuft", textAfterCaret: "", bundleID: "com.test")
        let effects = s.handle(.contextReady(ctx, caret: noCaretTrouble, trigger: .typing))
        #expect(verdicts(effects) == [.temporaryQuiet])
    }

    @Test func aMissingCaretReadoutIsNoCaretGeometry() {
        var s = SuggestionSession()
        let ctx = TypingContext(textBeforeCaret: "Der Hund laeuft", textAfterCaret: "", bundleID: "com.test")
        let effects = s.handle(.contextReady(ctx, caret: nil, trigger: .typing))
        #expect(verdicts(effects) == [.noCaretGeometry])
    }

    @Test func aPassedSurfaceIsOnAndEmitsExactlyOneVerdict() {
        var s = SuggestionSession()
        let ctx = TypingContext(textBeforeCaret: "Der Hund laeuft", textAfterCaret: "", bundleID: "com.test")
        let effects = s.handle(.contextReady(ctx, caret: noCaretTrouble, trigger: .typing))
        #expect(verdicts(effects) == [.on])
    }
}
