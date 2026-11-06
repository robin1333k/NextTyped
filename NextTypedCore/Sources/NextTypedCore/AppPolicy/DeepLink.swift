import Foundation

/// A Settings pane a deep link can name. Raw values are the URL path segments.
public enum DeepLinkPane: String, CaseIterable, Sendable {
    case setup, general, shortcuts, privacy, apps, statistics, about
}

/// What a valid deep link asks for. Only opening a pane exists: it reads and writes nothing, so it
/// needs no confirmation. A link that writes state is a separate command and a separate decision.
public enum DeepLinkCommand: Equatable, Sendable {
    /// `pane == nil` means "the pane that was last selected" (Setup on a fresh launch).
    case openSettings(pane: DeepLinkPane?)
}

/// Why a link was refused. Raw values are the `[deeplink]: rejected reason=` log tokens.
public enum DeepLinkRejection: String, Error, Equatable, Sendable {
    case unknownScheme = "unknown-scheme"
    case unknownHost = "unknown-host"
    case unknownPane = "unknown-pane"
    case hasQuery = "has-query"
    case hasFragment = "has-fragment"
}

/// Parses `nexttyped://settings` and `nexttyped://settings/<pane>`. Pure.
public enum DeepLink {
    public static let scheme = "nexttyped"

    public static func parse(_ url: URL) -> Result<DeepLinkCommand, DeepLinkRejection> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme else {
            return .failure(.unknownScheme)
        }
        guard components.host?.lowercased() == "settings" else { return .failure(.unknownHost) }
        guard components.query == nil else { return .failure(.hasQuery) }
        guard components.fragment == nil else { return .failure(.hasFragment) }

        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        switch segments.count {
        case 0:
            return .success(.openSettings(pane: nil))
        case 1:
            guard let pane = DeepLinkPane(rawValue: segments[0].lowercased()) else {
                return .failure(.unknownPane)
            }
            return .success(.openSettings(pane: pane))
        default:
            return .failure(.unknownPane)
        }
    }
}
