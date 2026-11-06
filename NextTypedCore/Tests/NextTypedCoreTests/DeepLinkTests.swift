import Foundation
import Testing
@testable import NextTypedCore

@Suite("DeepLink — nexttyped://settings[/<pane>] opens a Settings pane, everything else is rejected")
struct DeepLinkTests {
    private func parse(_ s: String) throws -> Result<DeepLinkCommand, DeepLinkRejection> {
        let url = try #require(URL(string: s))
        return DeepLink.parse(url)
    }

    @Test("Each pane name opens that pane", arguments: [
        ("nexttyped://settings/setup", DeepLinkPane.setup),
        ("nexttyped://settings/general", .general),
        ("nexttyped://settings/shortcuts", .shortcuts),
        ("nexttyped://settings/privacy", .privacy),
        ("nexttyped://settings/apps", .apps),
        ("nexttyped://settings/statistics", .statistics),
        ("nexttyped://settings/about", .about),
    ])
    func everyPane(link: String, pane: DeepLinkPane) throws {
        #expect(try parse(link) == .success(.openSettings(pane: pane)))
    }

    @Test("Scheme, host and pane are case-insensitive")
    func caseVariants() throws {
        #expect(try parse("nexttyped://settings/APPS") == .success(.openSettings(pane: .apps)))
        #expect(try parse("NextTyped://Settings/Privacy") == .success(.openSettings(pane: .privacy)))
    }

    @Test("No pane means the last selected one")
    func noPane() throws {
        #expect(try parse("nexttyped://settings") == .success(.openSettings(pane: nil)))
        #expect(try parse("nexttyped://settings/") == .success(.openSettings(pane: nil)))
    }

    @Test("An unknown host is rejected")
    func unknownHost() throws {
        #expect(try parse("nexttyped://pause") == .failure(.unknownHost))
        #expect(try parse("nexttyped://settings.evil/apps") == .failure(.unknownHost))
        #expect(try parse("nexttyped:///apps") == .failure(.unknownHost))
    }

    @Test("A foreign scheme is rejected")
    func unknownScheme() throws {
        #expect(try parse("https://settings/apps") == .failure(.unknownScheme))
    }

    @Test("An unknown pane, or extra path segments, is rejected")
    func unknownPane() throws {
        #expect(try parse("nexttyped://settings/personalization") == .failure(.unknownPane))
        #expect(try parse("nexttyped://settings/apps/extra") == .failure(.unknownPane))
    }

    @Test("Any query string is rejected, even an empty one")
    func hasQuery() throws {
        #expect(try parse("nexttyped://settings/apps?enable=1") == .failure(.hasQuery))
        #expect(try parse("nexttyped://settings?x=y") == .failure(.hasQuery))
        #expect(try parse("nexttyped://settings/apps?") == .failure(.hasQuery))
        #expect(try parse("nexttyped://settings/apps#frag") == .failure(.hasFragment))
    }

    @Test("A query on an unknown host reports the host first")
    func hostBeatsQuery() throws {
        #expect(try parse("nexttyped://nope?x=1") == .failure(.unknownHost))
    }

    @Test("The log reasons are the greppable tokens")
    func logTokens() throws {
        #expect(DeepLinkRejection.unknownHost.rawValue == "unknown-host")
        #expect(DeepLinkRejection.unknownPane.rawValue == "unknown-pane")
        #expect(DeepLinkRejection.hasQuery.rawValue == "has-query")
        #expect(DeepLinkRejection.unknownScheme.rawValue == "unknown-scheme")
        #expect(DeepLinkRejection.hasFragment.rawValue == "has-fragment")
    }
}
