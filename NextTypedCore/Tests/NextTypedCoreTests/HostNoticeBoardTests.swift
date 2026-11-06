import Testing
@testable import NextTypedCore

@Suite("HostNoticeBoard: one notice out of the active set")
struct HostNoticeBoardTests {
    @Test("An empty board has no notice")
    func empty() {
        #expect(HostNoticeBoard().current == nil)
    }

    @Test("Secure Input beats a tap leak, which beats a setup hint")
    func priority() {
        var board = HostNoticeBoard()
        board.raise(.setupHint)
        #expect(board.current == .setupHint)
        board.raise(.eventTapLeak(ownerName: "Karabiner"))
        #expect(board.current == .eventTapLeak(ownerName: "Karabiner"))
        board.raise(.secureInputBlocked(holderName: "Terminal"))
        #expect(board.current == .secureInputBlocked(holderName: "Terminal"))
        board.clear(.secureInputBlocked)
        #expect(board.current == .eventTapLeak(ownerName: "Karabiner"))
        board.clear(.eventTapLeak)
        board.clear(.setupHint)
        #expect(board.current == nil)
    }

    @Test("The Secure Input line names the holder, or says another app")
    func menuText() {
        #expect(HostNotice.secureInputBlocked(holderName: "Terminal").menuText
            == "Terminal has turned on Secure Input, so NextTyped cannot see your typing. Quit Terminal, or lock and unlock your Mac.")
        #expect(HostNotice.secureInputBlocked(holderName: nil).menuText
            == "Another app has turned on Secure Input, so NextTyped cannot see your typing. Quit it, or lock and unlock your Mac.")
    }

    @Test("Blocking notices force a hidden icon, a setup hint does not")
    func blocking() {
        #expect(HostNotice.secureInputBlocked(holderName: nil).isBlocking)
        #expect(HostNotice.eventTapLeak(ownerName: nil).isBlocking)
        #expect(!HostNotice.setupHint.isBlocking)
    }
}
