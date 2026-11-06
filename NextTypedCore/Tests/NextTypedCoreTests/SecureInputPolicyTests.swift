import Testing
@testable import NextTypedCore

@Suite("SecureInputPolicy: when Secure Input blinds the tap")
struct SecureInputPolicyTests {
    private let terminal = SecureInputHolder(bundleID: "com.apple.Terminal", name: "Terminal")

    private func facts(enabled: Bool = true, pid: Int32? = 500, holder: SecureInputHolder? = nil,
                       front: Int32? = 700, secure: Bool = false, since: Double? = 10,
                       now: Double) -> SecureInputFacts {
        SecureInputFacts(enabled: enabled, holderPID: pid, holder: holder ?? terminal, frontmostPID: front,
                         focusedIsSecureField: secure, heldSince: since, now: now)
    }

    @Test("Another app's hold of 2 s is blocked and names the holder")
    func blockedAfterTwoSeconds() {
        #expect(SecureInputPolicy.verdict(facts(now: 12)) == .blocked(holder: terminal))
    }

    @Test("Another app's hold of 1.9 s is still clear")
    func clearBeforeTwoSeconds() {
        #expect(SecureInputPolicy.verdict(facts(now: 11.9)) == .clear)
    }

    @Test("The flag off is clear, whatever else is set")
    func flagOff() {
        #expect(SecureInputPolicy.verdict(facts(enabled: false, now: 99)) == .clear)
    }

    @Test("The frontmost app holds it in a secure field: expected, at once and after a minute")
    func expectedSecureField() {
        #expect(SecureInputPolicy.verdict(facts(front: 500, secure: true, now: 10)) == .expectedSecureField)
        #expect(SecureInputPolicy.verdict(facts(front: 500, secure: true, now: 70)) == .expectedSecureField)
    }

    @Test("The frontmost app holds it but the field is not secure: blocked")
    func frontmostHolderPlainField() {
        #expect(SecureInputPolicy.verdict(facts(front: 500, secure: false, now: 13)) == .blocked(holder: terminal))
    }

    @Test("A secure field in the frontmost app while another app holds it: blocked")
    func secureFieldOtherHolder() {
        #expect(SecureInputPolicy.verdict(facts(front: 700, secure: true, now: 13)) == .blocked(holder: terminal))
    }

    @Test("An unknown or dead holder gives a nameless block")
    func unknownHolder() {
        #expect(SecureInputPolicy.verdict(facts(pid: nil, now: 13)) == .blocked(holder: nil))
        let dead = SecureInputFacts(enabled: true, holderPID: 500, holder: nil, frontmostPID: 700,
                                    focusedIsSecureField: false, heldSince: 10, now: 13)
        #expect(SecureInputPolicy.verdict(dead) == .blocked(holder: nil))
    }

    @Test("Holder unknown and the frontmost field secure: expected, not the nameless notice")
    func unknownHolderSecureFrontmostField() {
        #expect(SecureInputPolicy.verdict(facts(pid: nil, secure: true, now: 13)) == .expectedSecureField)
        #expect(SecureInputPolicy.verdict(facts(pid: nil, secure: false, now: 13)) == .blocked(holder: nil))
    }

    @Test("A holder identity without a PID is never named")
    func identityWithoutPID() {
        #expect(SecureInputPolicy.verdict(facts(pid: nil, holder: terminal, now: 13)) == .blocked(holder: nil))
    }
}

@Suite("SecureInputTracker: transitions and the no-read-while-off rule")
struct SecureInputTrackerTests {
    private let terminal = SecureInputHolder(bundleID: "com.apple.Terminal", name: "Terminal")

    private func step(_ t: inout SecureInputTracker, enabled: Bool, now: Double, front: Int32 = 700,
                      secure: Bool = false, reads: Reads? = nil) -> [SecureInputTransition] {
        t.observe(enabled: enabled, now: now, frontmostPID: front,
                  holderPID: { reads?.count += 1; return 500 },
                  resolve: { _ in terminal },
                  focusedIsSecureField: { _ in secure })
    }

    @Test("The tracker asks for the secure-field read when the holder PID is nil")
    func trackerReadsWithNilHolder() {
        var t = SecureInputTracker()
        var asked: [Int32?] = []
        let out = t.observe(enabled: true, now: 1, frontmostPID: 700, holderPID: { nil }, resolve: { _ in nil },
                            focusedIsSecureField: { asked.append($0); return true })
        #expect(asked.count == 1 && asked[0] == nil)
        #expect(out == [.enteredExpectedSecureField])
    }

    final class Reads { var count = 0 }

    @Test("A hold by Terminal enters blocked after 2 s and leaves when it ends")
    func blockedLifecycle() {
        var t = SecureInputTracker()
        #expect(step(&t, enabled: true, now: 100).isEmpty)
        #expect(step(&t, enabled: true, now: 101).isEmpty)
        #expect(step(&t, enabled: true, now: 102) == [.enteredBlocked(holder: terminal)])
        #expect(step(&t, enabled: true, now: 103).isEmpty)
        #expect(step(&t, enabled: false, now: 104) == [.leftBlocked])
        #expect(step(&t, enabled: false, now: 105).isEmpty)
    }

    @Test("An expected secure field reports once per hold")
    func expectedOncePerHold() {
        var t = SecureInputTracker()
        #expect(step(&t, enabled: true, now: 1, front: 500, secure: true) == [.enteredExpectedSecureField])
        #expect(step(&t, enabled: true, now: 2, front: 500, secure: true).isEmpty)
        #expect(step(&t, enabled: false, now: 3).isEmpty)
        #expect(step(&t, enabled: true, now: 4, front: 500, secure: true) == [.enteredExpectedSecureField])
    }

    @Test("A new hold starts its 2 s from its own first sight")
    func holdStartResets() {
        var t = SecureInputTracker()
        _ = step(&t, enabled: true, now: 0)
        _ = step(&t, enabled: false, now: 1)
        #expect(step(&t, enabled: true, now: 50).isEmpty)
        #expect(step(&t, enabled: true, now: 51).isEmpty)
    }

    @Test("Nothing is read while the flag is off")
    func noReadWhileOff() {
        var t = SecureInputTracker()
        let reads = Reads()
        _ = step(&t, enabled: false, now: 1, reads: reads)
        _ = step(&t, enabled: false, now: 2, reads: reads)
        #expect(reads.count == 0)
        _ = step(&t, enabled: true, now: 3, reads: reads)
        #expect(reads.count == 1)
    }
}
