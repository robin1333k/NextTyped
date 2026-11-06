import Foundation

/// Why the Websites section refused an input.
public enum SiteRuleInputError: Error, Equatable, Sendable {
    case invalid

    /// The inline message under the add field.
    public var message: String {
        "Enter a host such as example.com, a page address, or *.example.com."
    }
}

/// The ordered list of site rules behind Settings, Apps, Websites and the menu-bar site toggle.
/// All parsing goes through `SiteRule.init?`; the views add none of their own.
public struct SiteRuleList: Sendable, Equatable {
    public let rules: [SiteRule]

    public init(rules: [SiteRule]) { self.rules = rules }

    /// Adds `input` (a host, a pasted URL or `*.domain`) as an enabled rule. An existing rule with the
    /// same pattern is switched on instead of duplicated.
    public func adding(_ input: String) -> Result<SiteRuleList, SiteRuleInputError> {
        guard let rule = SiteRule(pattern: input, enabled: true) else { return .failure(.invalid) }
        return .success(setting(rule: rule))
    }

    public func removing(pattern: String) -> SiteRuleList {
        SiteRuleList(rules: rules.filter { $0.pattern != pattern })
    }

    public func setting(pattern: String, enabled: Bool) -> SiteRuleList {
        guard let rule = SiteRule(pattern: pattern, enabled: enabled) else { return self }
        return setting(rule: rule)
    }

    /// The menu-bar toggle: writes or updates the exact (non-wildcard) rule for `host`.
    public func settingExact(host: String, enabled: Bool) -> SiteRuleList {
        guard let rule = SiteRule(pattern: host, enabled: enabled), !rule.isWildcard else { return self }
        return setting(rule: rule)
    }

    /// Whether any rule, enabled or not, covers `host`.
    public func hasRule(for host: String) -> Bool {
        SiteRule.mostSpecific(in: rules, for: host) != nil
    }

    /// The `siteRules` preference value, the shape `SiteRule.decode` reads.
    public var stored: [[String: Any]] {
        rules.map { ["pattern": $0.pattern, "enabled": $0.enabled] }
    }

    private func setting(rule: SiteRule) -> SiteRuleList {
        var next = rules
        if let index = next.firstIndex(where: { $0.pattern == rule.pattern }) {
            next[index] = rule
        } else {
            next.append(rule)
        }
        return SiteRuleList(rules: next)
    }
}
