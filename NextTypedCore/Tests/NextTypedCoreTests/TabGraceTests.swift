import Testing
@testable import NextTypedCore

/// The `tabGraceMs` knob: absent means the shipping 150 ms, a stored value is clamped to
/// 0…1000, and 0 turns the grace window off.
@Suite struct TabGraceTests {
    @Test func anAbsentKeyIsTheShippingValue() {
        #expect(TabGrace.milliseconds(stored: nil) == 150)
    }

    @Test func aStoredValueIsClampedToZeroThroughOneThousand() {
        #expect(TabGrace.milliseconds(stored: 1500) == 1000)
        #expect(TabGrace.milliseconds(stored: -5) == 0)
        #expect(TabGrace.milliseconds(stored: 400) == 400)
    }

    @Test func zeroTurnsTheGraceOff() {
        #expect(TabGrace.isEnabled(milliseconds: 0) == false)
        #expect(TabGrace.isEnabled(milliseconds: 150) == true)
    }

    /// A correction ghost (two awaits) can finish its paint after a newer continuation
    /// ghost (one await). Its clock must not replace the newer one, or the newer ghost never settles.
    @Test func anOlderGenerationCannotClaimTheClockFromANewerOne() {
        var slot = SettleClockSlot()
        #expect(slot.claim(generation: 2) == true)
        #expect(slot.claim(generation: 1) == false)
        #expect(slot.claim(generation: 3) == true)
    }

    @Test func aResetSlotAcceptsTheFirstGenerationAgain() {
        var slot = SettleClockSlot()
        #expect(slot.claim(generation: 5) == true)
        slot = SettleClockSlot()
        #expect(slot.claim(generation: 1) == true)
    }
}
