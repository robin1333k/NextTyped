import Testing
@testable import NextTypedCore

/// Token budgeting for the prompt front (option 1).
///
/// The regression these pin down: the front must never again be specified in a unit that cannot see the
/// token window it competes for. Every case below is stated in tokens against a `windowMax`.
@Suite("PromptFrontBudget")
struct PromptFrontBudgetTests {

    private typealias Segment = PromptFrontBudget.Segment

    /// A prefix that wants the whole window — the long-document case, where the reserve is the binding
    /// ceiling. Every case below that is about *scarcity* states it, because with a short prefix the
    /// reserve is a floor the front may exceed (see the floor-not-ceiling suite at the end).
    private let longPrefix = 10_000

    // MARK: - The reserve

    @Test("The reserve is a share of windowMax, and the prefix gets the rest")
    func reserveIsAShareOfWindowMax() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512, segmentTokens: [:], prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.reserve == 154)                 // round(512 × 0.30)
        #expect(a.frontTokens == 0)               // nothing to spend it on
        #expect(a.prefixAllowance == 512)         // an empty front costs the prefix nothing
    }

    @Test("An empty front is byte-identical to the no-context path")
    func allSegmentsEmpty() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 0, .reply: 0, .personalization: 0, .ocrAmbient: 0],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.allowances.isEmpty)
        #expect(a.requestedTokens == 0)
        #expect(a.frontTokens == 0)
        #expect(a.isTrimmed == false)
        #expect(a.prefixAllowance == 512)
    }

    @Test("The reserve fraction is clamped, and an absent/garbage value falls back to the default")
    func reserveFractionClamping() {
        #expect(PromptFrontBudget.clampReserveFraction(0) == PromptFrontBudget.defaultReserveFraction)
        #expect(PromptFrontBudget.clampReserveFraction(-1) == PromptFrontBudget.defaultReserveFraction)
        #expect(PromptFrontBudget.clampReserveFraction(.nan) == PromptFrontBudget.defaultReserveFraction)
        #expect(PromptFrontBudget.clampReserveFraction(0.001) == 0.05)
        #expect(PromptFrontBudget.clampReserveFraction(0.99) == 0.60)
        #expect(PromptFrontBudget.clampReserveFraction(0.25) == 0.25)

        // …and the clamp actually reaches the reserve.
        let a = PromptFrontBudget.allocate(
            windowMax: 1000, reserveFraction: 5.0,
            segmentTokens: [.focusedDoc: 10_000], prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.reserve == 600)
        #expect(a.allowance(for: .focusedDoc) == 599)   // 600 − one separator
    }

    // MARK: - Fitting

    @Test("A front that fits is granted in full and nothing is trimmed")
    func fullFit() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 60, .reply: 40, .personalization: 35, .ocrAmbient: 0],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.allowance(for: .focusedDoc) == 60)
        #expect(a.allowance(for: .reply) == 40)
        #expect(a.allowance(for: .personalization) == 35)
        #expect(a.allowance(for: .ocrAmbient) == 0)
        #expect(a.frontTokens == 60 + 40 + 35 + 3)      // three separators
        #expect(a.requestedTokens == a.frontTokens)
        #expect(a.isTrimmed == false)
        #expect(a.prefixAllowance == 512 - 138)
    }

    @Test("An over-budget front is capped at the reserve, never beyond it")
    func overBudgetIsCappedAtTheReserve() {
        // The measured pathology: 392–571 tokens of front against a 512-token window.
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 380, .reply: 120, .personalization: 60, .ocrAmbient: 90],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.requestedTokens == 380 + 120 + 60 + 90 + 4)
        #expect(a.frontTokens <= a.reserve)
        #expect(a.isTrimmed)
        // focusedDoc is first in priority, so it absorbs the whole reserve minus its separator…
        #expect(a.allowance(for: .focusedDoc) == 153)
        // …and everything below it is dropped whole rather than fragmented.
        #expect(a.allowance(for: .reply) == 0)
        #expect(a.allowance(for: .personalization) == 0)
        #expect(a.allowance(for: .ocrAmbient) == 0)
        #expect(a.frontTokens == 154)
        #expect(a.prefixAllowance == 512 - 154)
    }

    // MARK: - Priority

    @Test("Allocation follows the measurement's priority, not the positional order")
    func priorityOrder() {
        // Positionally personalization is front-MOST; by value it ranks third. With room for exactly
        // two segments, focusedDoc and reply must win.
        let a = PromptFrontBudget.allocate(
            windowMax: 400,                                   // reserve 120
            segmentTokens: [.focusedDoc: 50, .reply: 50, .personalization: 50, .ocrAmbient: 50],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.reserve == 120)
        #expect(a.allowance(for: .focusedDoc) == 50)
        #expect(a.allowance(for: .reply) == 50)
        #expect(a.allowance(for: .personalization) == 0)      // 120 − 51 − 51 = 18 room left ⇒ dropped
        #expect(a.allowance(for: .ocrAmbient) == 0)
        #expect(PromptFrontBudget.priority
            == [.focusedDoc, .reply, .clipboard, .personalization, .ocrAmbient])
    }

    @Test("Under scarcity personalization and ocrAmbient drop before clipboard, clipboard before reply and focusedDoc")
    func clipboardPriority() {
        // windowMax 400, reserve 120, separator 1: focusedDoc 50 + reply 50 leave 18, so clipboard drops.
        let tight = PromptFrontBudget.allocate(
            windowMax: 400,
            segmentTokens: [.focusedDoc: 50, .reply: 50, .clipboard: 50, .personalization: 50, .ocrAmbient: 50],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(tight.allowance(for: .focusedDoc) == 50)
        #expect(tight.allowance(for: .reply) == 50)
        #expect(tight.allowance(for: .clipboard) == 0)
        // Room for three segments: clipboard is the third, personalization and ocrAmbient are out.
        let three = PromptFrontBudget.allocate(
            windowMax: 600,                                   // reserve 180; 3 x 51 = 153, 27 left
            segmentTokens: [.focusedDoc: 50, .reply: 50, .clipboard: 50, .personalization: 50, .ocrAmbient: 50],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(three.allowance(for: .clipboard) == 50)
        #expect(three.allowance(for: .personalization) == 0)
        #expect(three.allowance(for: .ocrAmbient) == 0)
        #expect(PromptFrontBudget.Segment.clipboard.rawValue == "clip")
    }

    @Test("A segment that cannot fit is skipped, not a stop — a smaller one below it still gets in")
    func skippingIsNotStopping() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,                                   // reserve 154
            segmentTokens: [.focusedDoc: 500, .reply: 40],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.allowance(for: .focusedDoc) == 153)         // truncated to the reserve
        #expect(a.allowance(for: .reply) == 0)                // genuinely no room left
        // Now the same shape but with a focusedDoc that leaves usable room behind it.
        let b = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 100, .reply: 40, .ocrAmbient: 300],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(b.allowance(for: .focusedDoc) == 100)
        #expect(b.allowance(for: .reply) == 40)
        // Only 11 tokens of room are left for ocrAmbient, which is below the minimum ⇒ dropped whole.
        #expect(b.allowance(for: .ocrAmbient) == 0)
        #expect(b.allowances[.ocrAmbient] == nil)
    }

    // MARK: - Drop whole, never a fragment

    @Test("A segment that fits whole is admitted however short it is")
    func shortButCompleteSegmentsAreAdmitted() {
        // The minimum guards against fragments, not against small sources: a 15-token reply turn is a
        // complete document and must not be dropped just for being short.
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 40, .reply: 15], prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.allowance(for: .reply) == 15)
        #expect(a.isTrimmed == false)
    }

    @Test("A segment that would have to be truncated below the minimum is dropped whole")
    func droppedWholeNotFragmented() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 120, .reply: 200],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.allowance(for: .focusedDoc) == 120)
        // Room after focusedDoc: 154 − 121 − 1 = 32 ⇒ exactly the minimum, so reply is truncated in.
        #expect(a.allowance(for: .reply) == 32)

        let b = PromptFrontBudget.allocate(
            windowMax: 510,                                   // reserve 153 ⇒ one token less room
            segmentTokens: [.focusedDoc: 120, .reply: 200],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(b.allowance(for: .focusedDoc) == 120)
        #expect(b.allowances[.reply] == nil)                  // 31 < 32 ⇒ dropped, not a fragment
        #expect(b.frontTokens == 121)
    }

    @Test("The minimum is a parameter, and raising it drops more")
    func minimumIsAParameter() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 120, .reply: 200],
            prefixTokens: longPrefix, separatorTokens: 1,
            minimumSegmentTokens: 64)
        #expect(a.allowances[.reply] == nil)
        #expect(a.frontTokens == 121)
    }

    // MARK: - Separators

    @Test("Separator tokens are charged against the reserve")
    func separatorsAreCounted() {
        let one = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 500, .reply: 500],
            prefixTokens: longPrefix, separatorTokens: 1)
        let five = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 500, .reply: 500],
            prefixTokens: longPrefix, separatorTokens: 5)
        #expect(one.allowance(for: .focusedDoc) == 153)
        #expect(five.allowance(for: .focusedDoc) == 149)
        #expect(one.frontTokens == 154)
        #expect(five.frontTokens == 154)
        // requestedTokens carries the separators too, so `isTrimmed` compares like with like.
        #expect(one.requestedTokens == 1002)
        #expect(five.requestedTokens == 1010)
    }

    @Test("A zero-length segment costs no separator and is not emitted")
    func zeroLengthSegmentsCostNothing() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 60, .reply: 0],
            prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.frontTokens == 61)
        #expect(a.requested[.reply] == nil)
    }

    // MARK: - The prefix allowance

    @Test("The prefix allowance is windowMax minus the granted front, and is never starved")
    func prefixAllowance() {
        for want in [0, 10, 100, 400, 5000] {
            let a = PromptFrontBudget.allocate(
                windowMax: 512,
                segmentTokens: [.focusedDoc: want], prefixTokens: longPrefix, separatorTokens: 1)
            #expect(a.prefixAllowance == max(1, 512 - a.frontTokens))
            // The reserve bounds the front, so the prefix keeps at least (1 − maxFraction) of the window.
            #expect(a.prefixAllowance >= 512 - a.reserve)
            #expect(a.prefixAllowance >= 1)
        }
    }

    // MARK: - Floor, not ceiling

    @Test("Everything fits: no clamping, no drops — byte-identical to the pre-budget prompt")
    func everythingFitsIsUnchanged() {
        // The regression this correction exists to prevent. A chat compose box: a whole front that used
        // to fit (`front=419/419tok` is on record) and a short prefix. Nothing may be trimmed, nothing
        // dropped, and the prefix must get an allowance ≥ what it wants so its window returns it whole.
        let front = [Segment.focusedDoc: 40, .reply: 300, .personalization: 60, .ocrAmbient: 15]
        let a = PromptFrontBudget.allocate(
            windowMax: 512, segmentTokens: front, prefixTokens: 60, separatorTokens: 1)
        for (segment, want) in front {
            #expect(a.allowance(for: segment) == want)
        }
        #expect(a.isTrimmed == false)
        #expect(a.frontTokens == 415 + 4)
        #expect(a.prefixAllowance == 512 - 419)
        #expect(a.prefixAllowance >= 60)               // the prefix window returns the prefix untouched
        #expect(a.frontTokens + 60 <= 512)             // …and the whole prompt still fits the window
    }

    @Test("A short prefix lets the front exceed its reserve — the reserve is a floor")
    func shortPrefixLetsTheFrontExceedTheReserve() {
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 419], prefixTokens: 60, separatorTokens: 1)
        #expect(a.reserve == 154)
        // Bounded by what the front actually wants (420 = 419 + its separator), which is itself far
        // above the 154-token reserve — the reserve is not the ceiling here.
        #expect(a.frontAllowance == 420)
        #expect(a.allowance(for: .focusedDoc) == 419)  // …so the whole front gets through
        #expect(a.isTrimmed == false)
    }

    @Test("A long prefix pushes the front back to exactly its reserve — but never below")
    func longPrefixFallsBackToTheReserve() {
        for prefixWant in [359, 500, 1000, 10_000] {
            let a = PromptFrontBudget.allocate(
                windowMax: 512,
                segmentTokens: [.focusedDoc: 419], prefixTokens: prefixWant, separatorTokens: 1)
            #expect(a.frontAllowance == 154)           // the floor holds however greedy the prefix is
            #expect(a.allowance(for: .focusedDoc) == 153)
            #expect(a.frontTokens == 154)
            #expect(a.prefixAllowance == 358)
        }
    }

    @Test("The front never reserves tokens it has no use for")
    func frontNeverOverReserves() {
        // A tiny front + a long prefix: the front takes what it needs, the prefix keeps the rest —
        // the reserve is not a tax on the prefix.
        let a = PromptFrontBudget.allocate(
            windowMax: 512,
            segmentTokens: [.focusedDoc: 40], prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.frontAllowance == 41)
        #expect(a.frontTokens == 41)
        #expect(a.prefixAllowance == 471)
    }

    @Test("frontAllowance is never below the reserve and never above windowMax")
    func allowanceIsBounded() {
        for prefixWant in [0, 1, 100, 358, 359, 512, 10_000] {
            let a = PromptFrontBudget.allocate(
                windowMax: 512,
                segmentTokens: [.focusedDoc: 10_000], prefixTokens: prefixWant, separatorTokens: 1)
            #expect(a.frontAllowance >= a.reserve)
            #expect(a.frontAllowance <= 512)
            #expect(a.prefixAllowance == max(1, 512 - a.frontTokens))
        }
    }

    @Test("A tiny window still yields a usable prefix allowance")
    func tinyWindow() {
        let a = PromptFrontBudget.allocate(
            windowMax: 128, reserveFraction: 0.60,
            segmentTokens: [.focusedDoc: 10_000], prefixTokens: longPrefix, separatorTokens: 1)
        #expect(a.reserve == 77)
        #expect(a.allowance(for: .focusedDoc) == 76)
        #expect(a.prefixAllowance == 51)
    }
}
