import Foundation

/// Maps the detected base tag (`en`) onto the dictionaries this user writes in, not onto every
/// dictionary installed. The accepted set is the base dictionary, the installed variants that match
/// `Locale.preferredLanguages` (`en-GB` gives `en_GB`), and the one the `SpellingVariant` setting
/// names (British gives `en_GB`, Canadian `en_CA`). A British setup keeps `colour`, and a typo such
/// as `teh` is still flagged, which an unrelated dictionary like `en_SG` would accept.
/// Guesses come from the dictionary the spelling setting names, else the user's preferred variant.
public struct VariantAwareWordSpelling: WordSpelling {
    private let base: any WordSpelling
    private let installed: [String]
    private let preferred: [String]
    private let spellingVariant: @Sendable () -> SpellingVariant

    /// - Parameters:
    ///   - installed: dictionary tags the system spell checker offers (`NSSpellChecker.availableLanguages`).
    ///   - preferred: the user's preferred languages, best first (`Locale.preferredLanguages`).
    ///   - spellingVariant: reads the live `SpellingVariant` setting on each check.
    public init(base: any WordSpelling, installed: [String], preferred: [String],
                spellingVariant: @escaping @Sendable () -> SpellingVariant = { .off }) {
        self.base = base
        self.installed = installed
        self.preferred = preferred
        self.spellingVariant = spellingVariant
    }

    public func isMisspelled(_ word: String, language: String) async -> Bool {
        for variant in variants(of: language) where !(await base.isMisspelled(word, language: variant)) {
            return false
        }
        return true
    }

    public func guesses(for word: String, language: String) async -> [String] {
        await base.guesses(for: word, language: guessLanguage(for: language))
    }

    /// A completion in any accepted dictionary makes the word a viable prefix.
    public func hasCompletions(for word: String, in context: String, language: String) async -> Bool {
        for variant in variants(of: language) where await base.hasCompletions(for: word, in: context, language: variant) {
            return true
        }
        return false
    }

    /// The dictionaries that decide whether a word is correct: the base tag (or `language` itself),
    /// then the installed variants of the preferred languages and of the spelling setting.
    func variants(of language: String) -> [String] {
        let base = SpellLanguagePolicy.baseTag(of: language)
        var wanted: [String] = []
        for tag in preferred where SpellLanguagePolicy.baseTag(of: tag) == base {
            wanted.append(tag.replacingOccurrences(of: "-", with: "_"))
        }
        if base == "en" {
            switch spellingVariant() {
            case .british: wanted.append("en_GB")
            case .canadian: wanted.append("en_CA")
            case .off: break
            }
        }
        var result = [installedTag(base) ?? language]
        for tag in wanted {
            guard let match = installedTag(tag), !result.contains(match) else { continue }
            result.append(match)
        }
        return result
    }

    private func installedTag(_ tag: String) -> String? {
        installed.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// For English, the installed dictionary the `SpellingVariant` setting names. Otherwise the
    /// installed variant of the first preferred language that shares the base, else `language`.
    func guessLanguage(for language: String) -> String {
        let base = SpellLanguagePolicy.baseTag(of: language)
        if base == "en" {
            switch spellingVariant() {
            case .british: if let gb = installedTag("en_GB") { return gb }
            case .canadian: if let ca = installedTag("en_CA") { return ca }
            case .off: break
            }
        }
        let candidates = variants(of: language)
        for tag in preferred where SpellLanguagePolicy.baseTag(of: tag) == base {
            let underscored = tag.replacingOccurrences(of: "-", with: "_")
            if candidates.contains(underscored) { return underscored }
            if let sameRegion = candidates.first(where: { $0.caseInsensitiveCompare(underscored) == .orderedSame }) {
                return sameRegion
            }
            // `en-US` has no `en_US` entry on macOS; the plain `en` dictionary is the US one.
            if candidates.contains(base) { return base }
        }
        return language
    }
}
