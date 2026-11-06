import Testing
@testable import NextTypedCore

@Suite("ClipboardAgeTracker and read plan")
struct ClipboardReadPlanTests {
    @Test func aNewChangeCountStartsAtAgeZero() {
        var tracker = ClipboardAgeTracker()
        #expect(tracker.firstSeenAgeMs(changeCount: 4, nowMs: 10_000) == 0)
    }

    @Test func theSameChangeCountAgesFromItsFirstSighting() {
        var tracker = ClipboardAgeTracker()
        _ = tracker.firstSeenAgeMs(changeCount: 4, nowMs: 10_000)
        #expect(tracker.firstSeenAgeMs(changeCount: 4, nowMs: 15_000) == 5_000)
        #expect(tracker.firstSeenAgeMs(changeCount: 4, nowMs: 130_000) == 120_000)
    }

    @Test func aNewChangeCountResetsTheAge() {
        var tracker = ClipboardAgeTracker()
        _ = tracker.firstSeenAgeMs(changeCount: 4, nowMs: 10_000)
        _ = tracker.firstSeenAgeMs(changeCount: 4, nowMs: 200_000)
        #expect(tracker.firstSeenAgeMs(changeCount: 5, nowMs: 200_500) == 0)
        #expect(tracker.firstSeenAgeMs(changeCount: 5, nowMs: 201_000) == 500)
    }

    @Test func contentMayBeReadOnlyWhileTheVerdictCouldStillInject() {
        func may(enabled: Bool = true, denied: Bool = false, concealed: Bool = false,
                 transient: Bool = false, age: Int = 5_000) -> Bool {
            ClipboardContextPolicy.mayReadContent(
                enabled: enabled, osAccessDenied: denied, isConcealed: concealed,
                isTransient: transient, firstSeenAgeMs: age)
        }
        #expect(may())
        #expect(!may(enabled: false))
        #expect(!may(denied: true))
        #expect(!may(concealed: true))
        #expect(!may(transient: true))
        #expect(may(age: 119_999))
        #expect(!may(age: 120_000))
    }

    @Test func logLinesNameTheReasonAndNeverTheText() {
        #expect(ClipboardVerdict.inject("Musterstrasse 12").logLine(ageMs: 5_200)
                == "[clip]: inject chars=16 age=5200")
        #expect(ClipboardVerdict.skip(.concealed).logLine(ageMs: 0) == "[clip]: skip reason=concealed")
        #expect(ClipboardVerdict.skip(.inDocument).logLine(ageMs: 900) == "[clip]: skip reason=in-document")
        #expect(ClipboardVerdict.skip(.off).logLine(ageMs: 0) == "[clip]: skip reason=off")
    }
}
