import Testing
@testable import NextTypedCore

@Suite("ClipboardRowState")
struct ClipboardRowStateTests {
    @Test func switchedOffShowsOffEvenWhenMacOSBlocks() {
        #expect(ClipboardRowState.resolve(enabled: false, osDenied: false) == .off)
        #expect(ClipboardRowState.resolve(enabled: false, osDenied: true) == .off)
    }

    @Test func switchedOnShowsOnWhenMacOSAllows() {
        #expect(ClipboardRowState.resolve(enabled: true, osDenied: false) == .on)
    }

    @Test func switchedOnButBlockedShowsBlocked() {
        #expect(ClipboardRowState.resolve(enabled: true, osDenied: true) == .blockedByOS)
    }

    @Test func disclosureNamesAllFiveFacts() {
        let text = ClipboardRowState.disclosure.map(\.text).joined(separator: " ")
        for fact in ["while you type", "last 2 minutes", "password manager", "never stored", "never learned"] {
            #expect(text.lowercased().contains(fact), "missing: \(fact)")
        }
    }
}
