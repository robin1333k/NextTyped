import Testing

// Placeholder app-target test so the NextTypedTests scheme exists.
// App-level AX/event-tap/overlay behavior can't be unit-tested meaningfully
// here; verify those manually. Real logic tests live in
// NextTypedCore/Tests. Add e.g. OverlayPositioningTests here as it solidifies.
@Suite struct SmokeTests {
    @Test func placeholder() {
        #expect(Bool(true))
    }
}
