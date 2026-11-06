import Testing
@testable import NextTypedCore

@Suite("WindowFronting — what counts as 'the window is in front of the user'")
struct WindowFrontingTests {
    private func state(
        active: Bool = true,
        visible: Bool = true,
        key: Bool = true,
        unoccluded: Bool = true,
        aboveOtherApps: Bool = true
    ) -> WindowFrontingState {
        WindowFrontingState(
            appIsActive: active,
            windowIsVisible: visible,
            windowIsKey: key,
            windowIsUnoccluded: unoccluded,
            windowIsAboveOtherApps: aboveOtherApps)
    }

    @Test("All four facts true is the only success")
    func allFourIsFronted() {
        #expect(WindowFronting.verdict(state()) == .fronted)
        #expect(!WindowFronting.needsEscalation(state()))
    }

    @Test("An invisible window is hidden, whatever else holds")
    func invisibleIsHidden() {
        #expect(WindowFronting.verdict(state(visible: false)) == .hidden)
        // Worst-first ordering: not-visible outranks the not-key it implies.
        #expect(WindowFronting.verdict(state(visible: false, key: false, unoccluded: false)) == .hidden)
    }

    @Test("A fully covered window is occluded even though the app is active and it is key")
    func coveredIsOccluded() {
        // This is the silent failure: the old guard read `NSApp.isActive` only, saw
        // true, and reported success on precisely this state.
        let covered = state(active: true, key: true, unoccluded: false)
        #expect(WindowFronting.verdict(covered) == .occluded)
        #expect(WindowFronting.needsEscalation(covered))
    }

    @Test("An inactive process is app-inactive, not fronted")
    func inactiveAppIsNotFronted() {
        #expect(WindowFronting.verdict(state(active: false)) == .appInactive)
        #expect(WindowFronting.needsEscalation(state(active: false)))
    }

    @Test("Visible, unobscured and active but not key is not-key")
    func notKeyIsReported() {
        #expect(WindowFronting.verdict(state(key: false)) == .notKey)
        #expect(WindowFronting.needsEscalation(state(key: false)))
    }

    @Test("Escalation is needed for every non-fronted verdict")
    func everyFailureEscalates() {
        let failures: [WindowFrontingState] = [
            state(visible: false), state(unoccluded: false), state(active: false), state(key: false),
            state(aboveOtherApps: false),
        ]
        for s in failures {
            #expect(WindowFronting.verdict(s) != .fronted)
            #expect(WindowFronting.needsEscalation(s))
        }
    }

    @Test("A window another app is drawn over is behind-app, however active and key it is")
    func sandwichedBetweenTwoAppsIsReported() {
        // The 2026-08-31 repro, as a state: Claude Desktop open, a Finder window raised over it, our
        // Settings window ordered in between. Everything the four older facts can see is true —
        // the process IS active, the window IS key, and a corner of it IS on screen, so
        // `occlusionState.visible` holds — and the user is still looking at Finder.
        let sandwiched = state(active: true, visible: true, key: true, unoccluded: true,
                               aboveOtherApps: false)
        #expect(WindowFronting.verdict(sandwiched) == .behindAnotherApp)
        #expect(WindowFronting.needsEscalation(sandwiched))
    }

    @Test("Full burial still outranks the z-order fact")
    func occlusionOutranksZOrder() {
        // Worst-first ordering again: a window nobody can see at all is `occluded`, not `behind-app`,
        // so the token names the most upstream failure rather than a consequence of it.
        #expect(WindowFronting.verdict(state(unoccluded: false, aboveOtherApps: false)) == .occluded)
    }

    @Test("The z-order fact defaults to true, so every existing call site keeps its meaning")
    func defaultKeepsOldCallSites() {
        let old = WindowFrontingState(appIsActive: true, windowIsVisible: true,
                                      windowIsKey: true, windowIsUnoccluded: true)
        #expect(WindowFronting.verdict(old) == .fronted)
    }

    @Test("The verdict raw values are the greppable log tokens")
    func rawValuesAreLogTokens() {
        #expect(WindowFrontingVerdict.fronted.rawValue == "fronted")
        #expect(WindowFrontingVerdict.hidden.rawValue == "hidden")
        #expect(WindowFrontingVerdict.occluded.rawValue == "occluded")
        #expect(WindowFrontingVerdict.appInactive.rawValue == "app-inactive")
        #expect(WindowFrontingVerdict.notKey.rawValue == "not-key")
        #expect(WindowFrontingVerdict.behindAnotherApp.rawValue == "behind-app")
        // No two tokens collide, so a grep counts what it names.
        #expect(Set(WindowFrontingVerdict.allCases.map(\.rawValue)).count
                == WindowFrontingVerdict.allCases.count)
    }
}
