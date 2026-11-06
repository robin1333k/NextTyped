import Foundation

/// Reduces a URL string to the host a site rule compares against. Nothing past the host is kept.
public enum SiteHost {
    /// Lowercased host with one leading `www.` removed, or `nil` when the string has no host
    /// (`file:`, `about:`, `data:`, malformed input).
    public static func normalize(_ urlString: String) -> String? {
        guard let host = URLComponents(string: urlString)?.host, !host.isEmpty else { return nil }
        return stripWWW(host.lowercased())
    }

    static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") && host.count > 4 ? String(host.dropFirst(4)) : host
    }
}

/// A per-website choice: a host pattern and whether completions are on there.
/// `docs.google.com` matches that host only; `*.example.com` matches every host ending in
/// `.example.com` with at least one more label, never `example.com` itself.
public struct SiteRule: Sendable, Equatable {
    /// The normalized pattern: lowercase, no `www.`, a pasted URL reduced to its host.
    public let pattern: String
    public let enabled: Bool

    /// `nil` for an empty pattern, a space, a `*` anywhere but the leading label, or a pattern with no host.
    public init?(pattern: String, enabled: Bool) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        var rest = trimmed
        var wildcard = false
        if rest.hasPrefix("*.") {
            wildcard = true
            rest = String(rest.dropFirst(2))
        }
        guard !rest.contains("*") else { return nil }
        let host: String?
        if rest.contains("://") {
            host = SiteHost.normalize(rest)
        } else {
            host = SiteHost.normalize("https://" + rest)
        }
        guard let host else { return nil }
        self.pattern = wildcard ? "*." + host : host
        self.enabled = enabled
    }

    /// Decodes the `siteRules` preference (an array of `{pattern, enabled}` dictionaries). Anything that
    /// is not an array yields no rules; an entry with a missing or mistyped field, or a pattern
    /// `init?` refuses, is dropped and never crashes.
    public static func decode(_ stored: Any?) -> [SiteRule] {
        guard let entries = stored as? [Any] else { return [] }
        return entries.compactMap { entry in
            guard let dict = entry as? [String: Any],
                  let pattern = dict["pattern"] as? String,
                  let enabled = dict["enabled"] as? Bool
            else { return nil }
            return SiteRule(pattern: pattern, enabled: enabled)
        }
    }

    public var isWildcard: Bool { pattern.hasPrefix("*.") }

    /// Whether this rule applies to `host` (already normalized, compared case-insensitively).
    public func matches(host: String) -> Bool {
        let host = SiteHost.stripWWW(host.lowercased())
        guard isWildcard else { return host == pattern }
        let suffix = String(pattern.dropFirst(1))   // ".example.com"
        return host.hasSuffix(suffix) && host.count > suffix.count
    }

    /// The most specific matching rule: an exact rule beats any wildcard, a longer wildcard suffix
    /// beats a shorter one, and the first of two equal patterns wins. `nil` when none matches.
    public static func mostSpecific(in rules: [SiteRule], for host: String) -> SiteRule? {
        var best: SiteRule?
        for rule in rules where rule.matches(host: host) {
            guard let current = best else { best = rule; continue }
            if rule.specificity > current.specificity { best = rule }
        }
        return best
    }

    private var specificity: Int { isWildcard ? pattern.count : Int.max }
}
