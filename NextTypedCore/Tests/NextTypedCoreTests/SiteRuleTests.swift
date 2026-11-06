import Testing
@testable import NextTypedCore

@Suite("Site rules")
struct SiteRuleTests {
    @Test("normalize keeps only the lowercase host without www")
    func normalize() {
        #expect(SiteHost.normalize("https://www.Example.com/path?q=1#x") == "example.com")
        #expect(SiteHost.normalize("http://localhost:8080/") == "localhost")
        #expect(SiteHost.normalize("file:///tmp/a.html") == nil)
        #expect(SiteHost.normalize("not a url") == nil)
        #expect(SiteHost.normalize("about:blank") == nil)
        #expect(SiteHost.normalize("data:text/plain,hi") == nil)
    }

    @Test("a pattern is normalized when saved")
    func patternNormalized() {
        #expect(SiteRule(pattern: "WWW.Docs.Google.com", enabled: true)?.pattern == "docs.google.com")
        #expect(SiteRule(pattern: "https://www.Example.com/a?b=1", enabled: false)?.pattern == "example.com")
        #expect(SiteRule(pattern: "*.Example.com", enabled: true)?.pattern == "*.example.com")
    }

    @Test("invalid patterns are rejected")
    func invalid() {
        for bad in ["", "  ", "a b.com", "foo.*.com", "*example.com", "*.*.com", "exa*mple.com", "*."] {
            #expect(SiteRule(pattern: bad, enabled: true) == nil, "\(bad)")
        }
    }

    @Test("wildcard matches subdomains, not the bare domain or a lookalike")
    func wildcard() throws {
        let rule = try #require(SiteRule(pattern: "*.example.com", enabled: true))
        #expect(rule.matches(host: "a.example.com"))
        #expect(rule.matches(host: "a.b.example.com"))
        #expect(!rule.matches(host: "example.com"))
        #expect(!rule.matches(host: "badexample.com"))
    }

    @Test("exact matches that host only")
    func exact() throws {
        let rule = try #require(SiteRule(pattern: "docs.google.com", enabled: true))
        #expect(rule.matches(host: "docs.google.com"))
        #expect(rule.matches(host: "DOCS.google.com"))
        #expect(!rule.matches(host: "a.docs.google.com"))
        #expect(!rule.matches(host: "google.com"))
    }

    @Test("exact beats wildcard, longer wildcard beats shorter")
    func specificity() throws {
        let short = try #require(SiteRule(pattern: "*.example.com", enabled: false))
        let long = try #require(SiteRule(pattern: "*.mail.example.com", enabled: true))
        let exact = try #require(SiteRule(pattern: "x.mail.example.com", enabled: false))
        #expect(SiteRule.mostSpecific(in: [short, long], for: "x.mail.example.com") == long)
        #expect(SiteRule.mostSpecific(in: [long, short], for: "x.mail.example.com") == long)
        #expect(SiteRule.mostSpecific(in: [short, long, exact], for: "x.mail.example.com") == exact)
        #expect(SiteRule.mostSpecific(in: [short, long], for: "b.example.com") == short)
        #expect(SiteRule.mostSpecific(in: [short, long], for: "other.org") == nil)
    }

    @Test("stored rules decode, and a malformed entry is dropped")
    func decodeStored() {
        let stored: [[String: Any]] = [
            ["pattern": "localhost", "enabled": false],
            ["pattern": "*.Example.com", "enabled": true],
            ["pattern": "a b.com", "enabled": true],      // invalid pattern
            ["pattern": "x.com"],                          // no enabled flag
            ["pattern": 7, "enabled": true],               // wrong type
            ["enabled": true],                             // no pattern
        ]
        #expect(SiteRule.decode(stored) == [
            SiteRule(pattern: "localhost", enabled: false),
            SiteRule(pattern: "*.example.com", enabled: true),
        ].compactMap { $0 })
        #expect(SiteRule.decode(nil).isEmpty)
        #expect(SiteRule.decode("not an array").isEmpty)
    }
}
