import Testing
@testable import NextTypedCore

@Suite("InlinePredictionAdvisory — one key, two readings, deliberately different defaults")
struct InlinePredictionAdvisoryTests {
    @Test("A present Boolean reads as itself")
    func presentBoolean() {
        #expect(OSInlinePredictionReading.reading(of: true) == .on)
        #expect(OSInlinePredictionReading.reading(of: false) == .off)
    }

    @Test("Absent — and anything that is not a Boolean — reads as unknown")
    func absentIsUnknown() {
        // The App bridges at the CFPreferences boundary, so a renamed key and a value of the wrong
        // type arrive here identically. Neither is an error; neither may drive behaviour.
        #expect(OSInlinePredictionReading.reading(of: nil) == .unknown)
    }

    @Test("An unknown key shows the row with the turn-off button, not an Action needed claim")
    func unknownOffersTheSwitch() {
        // A stock Mac has no key. The row must be reachable there, and must not claim a state we
        // did not read.
        #expect(InlinePredictionStatus.advisory(for: .unknown) == .offerTurnOff)
        #expect(InlinePredictionStatus.toggleAction(for: .unknown) == .turnOff)
    }

    @Test("The persistent row is unsatisfied only while the OS feature is provably on")
    func rowTracksTheReading() {
        #expect(InlinePredictionStatus.advisory(for: .on) == .actionNeeded)
        #expect(InlinePredictionStatus.advisory(for: .off) == .satisfied)
    }

    @Test("The nudge keeps ADR-0037's absent-means-enabled default")
    func nudgeDefaultsToPresenting() {
        #expect(InlinePredictionStatus.nudgeShouldPresent(for: .unknown))
        #expect(InlinePredictionStatus.nudgeShouldPresent(for: .on))
    }

    @Test("The nudge stays silent once the user has turned the OS feature off")
    func nudgeSilentWhenOff() {
        #expect(!InlinePredictionStatus.nudgeShouldPresent(for: .off))
    }

    @Test("Row and nudge never disagree about a key they can both read")
    func theTwoAgreeWhereverTheKeyIsReadable() {
        // The acceptance criterion "the pill and the one-time nudge never disagree about the same key",
        // stated as the invariant it actually is: wherever the key is readable, an "Action needed" row
        // and a presenting nudge coincide. `.unknown` is the one deliberate exception, pinned above (neutral row, nudge presents).
        for reading in [OSInlinePredictionReading.on, .off] {
            #expect((InlinePredictionStatus.advisory(for: reading) == .actionNeeded)
                    == InlinePredictionStatus.nudgeShouldPresent(for: reading))
        }
    }

    @Test("Every case has a distinct greppable log token")
    func rawValuesAreDistinctAndGreppable() {
        let readings = Set(OSInlinePredictionReading.allCases.map(\.rawValue))
        #expect(readings == ["on", "off", "unknown"])
        let advisories = Set(InlinePredictionAdvisory.allCases.map(\.rawValue))
        #expect(advisories == ["action-needed", "satisfied", "offer-turn-off", "hidden"])
    }
}
