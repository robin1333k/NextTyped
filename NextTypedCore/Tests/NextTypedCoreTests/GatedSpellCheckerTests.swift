import Foundation
import Testing
@testable import NextTypedCore

private final class RecordingChecker: SpellChecker, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    func verdict(for context: TypingContext) async -> SpellVerdict {
        lock.withLock { _calls += 1 }
        return .clean(Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7))
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ s: String) { lock.withLock { _lines.append(s) } }
}

@Suite struct GatedSpellCheckerTests {
    private let context = TypingContext(textBeforeCaret: "I left becuase")

    @Test func enabledForwardsTheBaseCorrection() async {
        let base = RecordingChecker()
        let gate = GatedSpellChecker(base: base, isEnabled: { true }, log: { _ in })
        let result = await gate.correction(for: context)
        #expect(result == Correction(original: "becuase", replacement: "because", charactersBackFromCaret: 7))
        #expect(base.calls == 1)
    }

    @Test func disabledReturnsNilWithoutCallingTheBase() async {
        let base = RecordingChecker()
        let log = LogBox()
        let gate = GatedSpellChecker(base: base, isEnabled: { false }, log: log.add)
        let result = await gate.correction(for: context)
        #expect(result == nil)
        #expect(base.calls == 0)
        #expect(log.lines == ["[gate]: spelling-fix off reason=user"])
    }

    @Test func theSwitchIsReadOnEveryCall() async {
        let base = RecordingChecker()
        let flag = LogBox()   // non-empty means enabled
        let gate = GatedSpellChecker(base: base, isEnabled: { !flag.lines.isEmpty }, log: { _ in })
        #expect(await gate.correction(for: context) == nil)
        flag.add("on")
        #expect(await gate.correction(for: context)?.replacement == "because")
        #expect(base.calls == 1)
    }
}
