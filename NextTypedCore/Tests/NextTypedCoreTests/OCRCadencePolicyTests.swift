import Testing
@testable import NextTypedCore

/// The proactive-gated OCR cadence and the perceptual pre-diff.
@Suite struct OCRCadencePolicyTests {

    private func input(
        enabled: Bool = true,
        appAllowed: Bool = true,
        secure: Bool = false,
        power: OCRCadencePolicy.PowerState = .normal,
        lastActivityAt: Double? = 100,
        lastPassAt: Double? = nil,
        isNewSurface: Bool = false,
        now: Double = 200
    ) -> OCRCadencePolicy.Input {
        OCRCadencePolicy.Input(
            enabled: enabled, appAllowed: appAllowed, focusedFieldIsSecure: secure, power: power,
            lastActivityAt: lastActivityAt, lastPassAt: lastPassAt,
            isNewSurface: isNewSurface, now: now)
    }

    // MARK: the hard offs

    @Test func disabledNeverRuns() {
        #expect(OCRCadencePolicy.decide(input(enabled: false, isNewSurface: true)) == .skipDisabled)
    }

    @Test func perAppOffNeverRuns() {
        // The (a) half of the coupled per-app switch: no OCR while that app is focused.
        #expect(OCRCadencePolicy.decide(input(appAllowed: false, isNewSurface: true)) == .skipAppOff)
    }

    @Test func focusedSecureFieldSuppressesTheWholeCapture() {
        // Scrub-chain guard (ii) — a password field anywhere in focus kills the pass, not just that window.
        #expect(OCRCadencePolicy.decide(input(secure: true, isNewSurface: true)) == .skipSecureField)
    }

    @Test func lockedOrSleepingScreenIsHardOff() {
        #expect(OCRCadencePolicy.decide(input(power: .off, isNewSurface: true)) == .skipPowerOff)
    }

    @Test func hardOffsOutrankANewSurface() {
        // A focus change must not be able to sneak a pass past the privacy/power gates.
        #expect(OCRCadencePolicy.decide(
            input(enabled: false, secure: true, power: .off, isNewSurface: true)) == .skipDisabled)
    }

    // MARK: proactive gating

    @Test func newWritingSurfaceRunsImmediately() {
        // Without this the first prediction in every new context lacks OCR context entirely — the
        // reason the lazy serve-stale cadence was rejected.
        #expect(OCRCadencePolicy.decide(input(isNewSurface: true)) == .runNewSurface)
    }

    @Test func noWritingActivityMeansNoPass() {
        // Gaming / watching a film: no prediction-relevant activity, so OCR costs nothing.
        #expect(OCRCadencePolicy.decide(input(lastActivityAt: nil)) == .skipNoActivity)
    }

    @Test func midBurstTypingIsDebounced() {
        // A keystroke 0.1 s ago: the idle debounce keeps OCR out of the first-paint budget.
        #expect(OCRCadencePolicy.decide(input(lastActivityAt: 199.9, now: 200)) == .skipTyping)
    }

    @Test func idleAfterTypingRunsWhenNothingIsCached() {
        #expect(OCRCadencePolicy.decide(input(lastActivityAt: 195, lastPassAt: nil, now: 200)) == .runIdle)
    }

    // MARK: throttle + TTL

    @Test func throttleBlocksARapidSecondPass() {
        #expect(OCRCadencePolicy.decide(
            input(lastActivityAt: 195, lastPassAt: 195, now: 200)) == .skipThrottled)
    }

    @Test func throttleAlsoBoundsANewSurface() {
        // Alt-tabbing between two windows must not turn into a pass per switch.
        #expect(OCRCadencePolicy.decide(
            input(lastPassAt: 198, isNewSurface: true, now: 200)) == .skipThrottled)
    }

    @Test func passRunsOnceTheThrottleWindowElapses() {
        #expect(OCRCadencePolicy.decide(
            input(lastActivityAt: 195, lastPassAt: 180, now: 200)) == .runIdle)
    }

    @Test func ttlBackstopRefreshesAStaleCapture() {
        // Scrolling a reference doc fires no focus event; only the TTL catches it.
        #expect(OCRCadencePolicy.decide(
            input(lastActivityAt: 995, lastPassAt: 900, now: 1000)) == .runStale)
    }

    @Test func constrainedPowerLengthensTheThrottle() {
        // Low Power / thermal serious: a pass that would be allowed at 20 s is not.
        #expect(OCRCadencePolicy.decide(
            input(power: .constrained, lastActivityAt: 195, lastPassAt: 180, now: 200)) == .skipThrottled)
    }

    @Test func decisionsCarryTheirRunFlag() {
        #expect(OCRCadencePolicy.Decision.runNewSurface.shouldRun == true)
        #expect(OCRCadencePolicy.Decision.runStale.shouldRun == true)
        #expect(OCRCadencePolicy.Decision.skipThrottled.shouldRun == false)
        #expect(OCRCadencePolicy.Decision.skipSecureField.shouldRun == false)
    }

    // MARK: expiry of cached text

    @Test func cachedTextExpiresAtTheTTL() {
        #expect(OCRCadencePolicy.isExpired(lastPassAt: nil, now: 100) == true)
        #expect(OCRCadencePolicy.isExpired(lastPassAt: 100, now: 120) == false)
        #expect(OCRCadencePolicy.isExpired(lastPassAt: 100, now: 200) == true)
    }
}

@Suite struct PerceptualScreenHashTests {

    /// A grid whose every row ramps upward — a stable, known input.
    private func rampGrid(offset: Double = 0) -> [[Double]] {
        (0..<PerceptualScreenHash.gridHeight).map { _ in
            (0...PerceptualScreenHash.gridWidth).map { Double($0) + offset }
        }
    }

    @Test func identicalGridsHashIdentically() {
        let a = PerceptualScreenHash.hash(grayscaleGrid: rampGrid())
        let b = PerceptualScreenHash.hash(grayscaleGrid: rampGrid())
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func uniformBrightnessShiftDoesNotChangeTheHash() {
        // dHash compares neighbours, so turning the display brightness up must not force a pass.
        let dim = PerceptualScreenHash.hash(grayscaleGrid: rampGrid())
        let bright = PerceptualScreenHash.hash(grayscaleGrid: rampGrid(offset: 50))
        #expect(dim == bright)
    }

    @Test func aChangedRegionFlipsBits() {
        var changed = rampGrid()
        changed[3] = changed[3].reversed()          // one row now ramps the other way
        let before = PerceptualScreenHash.hash(grayscaleGrid: rampGrid())!
        let after = PerceptualScreenHash.hash(grayscaleGrid: changed)!
        #expect(PerceptualScreenHash.distance(before, after) > PerceptualScreenHash.unchangedThreshold)
        #expect(PerceptualScreenHash.isUnchanged(previous: before, current: after) == false)
    }

    @Test func smallNoiseCountsAsUnchanged() {
        // A blinking caret or a ticking clock digit flips a bit or two — not worth a 0.3–1.0 s pass.
        let base = PerceptualScreenHash.hash(grayscaleGrid: rampGrid())!
        let noisy = base ^ 0b101                     // two bits differ
        #expect(PerceptualScreenHash.isUnchanged(previous: base, current: noisy) == true)
    }

    @Test func noPreviousHashAlwaysRunsThePass() {
        #expect(PerceptualScreenHash.isUnchanged(previous: nil, current: 12345) == false)
    }

    @Test func malformedGridYieldsNoHash() {
        // Degrades to "unknown ⇒ run", never to a false "unchanged" that would freeze the context.
        #expect(PerceptualScreenHash.hash(grayscaleGrid: []) == nil)
        #expect(PerceptualScreenHash.hash(grayscaleGrid: [[1, 2, 3]]) == nil)
    }
}
