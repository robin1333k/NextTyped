import Testing
@testable import NextTypedCore

@Suite("Site rule list")
struct SiteRuleListTests {
    private func rule(_ pattern: String, _ enabled: Bool = true) -> SiteRule {
        SiteRule(pattern: pattern, enabled: enabled)!
    }

    @Test("a pasted URL is stored as its host")
    func addUrl() throws {
        let list = try SiteRuleList(rules: []).adding("https://www.example.com/a?b").get()
        #expect(list.rules == [rule("example.com")])
    }

    @Test("a wildcard is stored as typed")
    func addWildcard() throws {
        let list = try SiteRuleList(rules: []).adding("*.example.com").get()
        #expect(list.rules.map(\.pattern) == ["*.example.com"])
    }

    @Test("an input with a space is refused and nothing is stored")
    func addInvalid() {
        let start = SiteRuleList(rules: [rule("a.com")])
        let result = start.adding("exa mple.com")
        #expect(result == .failure(.invalid))
        #expect(start.rules == [rule("a.com")])
    }

    @Test("an empty input is refused")
    func addEmpty() {
        #expect(SiteRuleList(rules: []).adding("   ") == .failure(.invalid))
    }

    @Test("adding an existing pattern switches it on and keeps one entry")
    func addDuplicate() throws {
        let list = try SiteRuleList(rules: [rule("example.com", false)]).adding("www.example.com").get()
        #expect(list.rules == [rule("example.com", true)])
    }

    @Test("removing drops the rule by pattern")
    func remove() {
        let list = SiteRuleList(rules: [rule("a.com"), rule("b.com")]).removing(pattern: "a.com")
        #expect(list.rules == [rule("b.com")])
    }

    @Test("setting a rule on or off keeps its place")
    func setEnabled() {
        let list = SiteRuleList(rules: [rule("a.com"), rule("b.com")]).setting(pattern: "a.com", enabled: false)
        #expect(list.rules == [rule("a.com", false), rule("b.com")])
    }

    @Test("the menu toggle writes an exact rule for the host")
    func menuWrites() {
        let list = SiteRuleList(rules: [rule("*.example.com")]).settingExact(host: "docs.example.com", enabled: false)
        #expect(list.rules == [rule("*.example.com"), rule("docs.example.com", false)])
    }

    @Test("the menu toggle updates an existing exact rule instead of adding a second")
    func menuUpdates() {
        let list = SiteRuleList(rules: [rule("example.com", false)]).settingExact(host: "example.com", enabled: true)
        #expect(list.rules == [rule("example.com", true)])
    }

    @Test("the stored form round-trips through SiteRule.decode")
    func storedRoundTrip() {
        let list = SiteRuleList(rules: [rule("a.com"), rule("*.b.com", false)])
        #expect(SiteRule.decode(list.stored) == list.rules)
    }

    @Test("hasRule is true when any rule covers the host")
    func hasRule() {
        let list = SiteRuleList(rules: [rule("*.example.com")])
        #expect(list.hasRule(for: "docs.example.com"))
        #expect(!list.hasRule(for: "example.com"))
    }
}
