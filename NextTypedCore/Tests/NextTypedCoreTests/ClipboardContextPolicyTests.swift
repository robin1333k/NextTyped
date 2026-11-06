import Testing
@testable import NextTypedCore

@Suite("ClipboardContextPolicy")
struct ClipboardContextPolicyTests {
    private func snap(
        enabled: Bool = true, osDenied: Bool = false, age: Int = 5_000, concealed: Bool = false,
        transient: Bool = false, hasText: Bool = true, text: String = "Musterstrasse 12, 10115 Berlin"
    ) -> ClipboardSnapshot {
        ClipboardSnapshot(enabled: enabled, osAccessDenied: osDenied, changeCount: 7,
                          firstSeenAgeMs: age, isConcealed: concealed, isTransient: transient,
                          hasText: hasText, text: text)
    }

    private func verdict(_ s: ClipboardSnapshot, prefix: String = "Meine Adresse ist",
                         window: String? = nil) -> ClipboardVerdict {
        ClipboardContextPolicy.verdict(snapshot: s, prefix: prefix, windowContext: window)
    }

    @Test func aFreshCopiedTextIsInjected() {
        #expect(verdict(snap()) == .inject("Musterstrasse 12, 10115 Berlin"))
    }

    @Test func aPastedAWSKeyIsRedactedBeforeItIsInjected() {
        // AKIAIOSFODNN7EXAMPLE is the example access key id in AWS's own documentation.
        #expect(verdict(snap(text: "aws key AKIAIOSFODNN7EXAMPLE for staging"))
                == .inject("aws key … for staging"))
    }

    @Test func eachSkipReasonIsReturnedForItsInput() {
        #expect(verdict(snap(enabled: false)) == .skip(.off))
        #expect(verdict(snap(osDenied: true)) == .skip(.osDenied))
        #expect(verdict(snap(concealed: true)) == .skip(.concealed))
        #expect(verdict(snap(transient: true)) == .skip(.transient))
        #expect(verdict(snap(hasText: false)) == .skip(.nonText))
        #expect(verdict(snap(text: "  \n\t ")) == .skip(.empty))
        #expect(verdict(snap(age: 120_000)) == .skip(.stale))
        #expect(verdict(snap(), prefix: "Adresse: Musterstrasse 12, 10115 Berlin") == .skip(.inDocument))
        #expect(verdict(snap(), window: "Brief an Musterstrasse 12, 10115 Berlin, bitte") == .skip(.inDocument))
    }

    @Test func theFirstReasonInTheStatedOrderWins() {
        // Everything applies at once: off wins.
        let all = snap(enabled: false, osDenied: true, age: 999_999, concealed: true,
                       transient: true, hasText: false, text: "")
        #expect(verdict(all) == .skip(.off))
        #expect(verdict(snap(osDenied: true, concealed: true, transient: true)) == .skip(.osDenied))
        #expect(verdict(snap(concealed: true, transient: true, hasText: false)) == .skip(.concealed))
        #expect(verdict(snap(transient: true, hasText: false, text: "")) == .skip(.transient))
        #expect(verdict(snap(hasText: false, text: "")) == .skip(.nonText))
        #expect(verdict(snap(age: 999_999, text: " ")) == .skip(.stale))
        #expect(verdict(snap(age: 999_999, hasText: false, text: "")) == .skip(.stale))
        #expect(verdict(snap(age: 999_999), prefix: "Musterstrasse 12, 10115 Berlin") == .skip(.stale))
    }

    @Test func aStaleCopyTheAdapterDidNotReadLogsStaleNotEmpty() {
        // PasteboardReader skips the content read once the copy is stale and passes hasText:true, text:"".
        #expect(verdict(snap(age: 120_000, hasText: true, text: "")) == .skip(.stale))
    }

    @Test func theAgeBoundaryIsExactly120000Ms() {
        #expect(verdict(snap(age: 119_999)) == .inject("Musterstrasse 12, 10115 Berlin"))
        #expect(verdict(snap(age: 120_000)) == .skip(.stale))
    }

    @Test func injectedTextIsScrubbed() {
        let v = verdict(snap(text: "Your verification code is 482913\nSee you Friday"))
        #expect(v == .inject("Your verification code is …\nSee you Friday"))
    }

    @Test func injectedTextIsTrimmedAndHeadCapped() {
        let long = "  " + String(repeating: "x", count: 900) + "\n"
        #expect(ClipboardContextPolicy.headCapChars == 600)
        #expect(verdict(snap(text: long)) == .inject(String(repeating: "x", count: 600)))
    }

    @Test func aVeryLongClipboardYieldsItsLiteralHead() {
        let line = "abcdefghij" // 10 chars, so 600 chars is exactly 60 repeats
        let huge = "\n\n  " + String(repeating: line, count: 2_000_000) // 20 MB
        let expected = String(repeating: line, count: 60)
        #expect(verdict(snap(text: huge)) == .inject(expected))
    }

    @Test func inDocumentComparesTheBoundedHead() {
        let head = String(repeating: "abcdefghij", count: 240) // exactly boundedHeadChars
        let huge = head + String(repeating: "z", count: 5_000)
        #expect(verdict(snap(text: huge), prefix: "x " + head + " y") == .skip(.inDocument))
    }

    @Test func debugTokensMatchTheSpec() {
        #expect(ClipboardVerdict.Reason.allCases.map(\.rawValue)
            == ["off", "os-denied", "concealed", "transient", "stale", "non-text", "empty", "in-document"])
    }
}
