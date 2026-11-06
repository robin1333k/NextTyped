import AppKit
import NextTypedCore

/// `NSSpellChecker` behind the `WordSpelling` seam. The language is always passed
/// explicitly; `language: nil` made the shared checker answer in English.
final class SystemWordSpelling: WordSpelling {
    func isMisspelled(_ word: String, language: String) async -> Bool {
        await MainActor.run {
            let range = NSSpellChecker.shared.checkSpelling(
                of: word, startingAt: 0, language: language, wrap: false,
                inSpellDocumentWithTag: 0, wordCount: nil)
            return range.location != NSNotFound && range.length > 0
        }
    }

    func guesses(for word: String, language: String) async -> [String] {
        await MainActor.run {
            NSSpellChecker.shared.guesses(
                forWordRange: NSRange(location: 0, length: (word as NSString).length),
                in: word, language: language, inSpellDocumentWithTag: 0) ?? []
        }
    }

    func hasCompletions(for word: String, in context: String, language: String) async -> Bool {
        await MainActor.run {
            let length = (word as NSString).length
            let completions = NSSpellChecker.shared.completions(
                forPartialWordRange: NSRange(location: (context as NSString).length - length, length: length),
                in: context, language: language, inSpellDocumentWithTag: 0)
            return !(completions ?? []).isEmpty
        }
    }
}
