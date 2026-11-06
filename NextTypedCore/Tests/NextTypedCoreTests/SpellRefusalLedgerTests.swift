import Testing
@testable import NextTypedCore

@Suite struct SpellRefusalLedgerTests {
    @Test func thirdRefusalIgnoresTheWord() {
        var l = SpellRefusalLedger()
        #expect(l.recordRefusal(of: "becuase") == false)
        #expect(l.recordRefusal(of: "becuase") == false)
        #expect(l.isIgnored("becuase") == false)
        #expect(l.recordRefusal(of: "becuase") == true)
        #expect(l.isIgnored("becuase") == true)
    }

    @Test func armingFiresOnlyAtTheTransition() {
        var l = SpellRefusalLedger()
        for _ in 0..<3 { l.recordRefusal(of: "becuase") }
        #expect(l.recordRefusal(of: "becuase") == false)
    }

    @Test func keyIsCaseFolded() {
        var l = SpellRefusalLedger()
        l.recordRefusal(of: "Qwen"); l.recordRefusal(of: "QWEN"); l.recordRefusal(of: "Qwen")
        #expect(l.isIgnored("qwen") == true)
    }

    @Test func otherWordsAreUnaffected() {
        var l = SpellRefusalLedger()
        for _ in 0..<3 { l.recordRefusal(of: "becuase") }
        #expect(l.isIgnored("recieve") == false)
    }
}
