import Foundation
import NaturalLanguage

/// The English spelling variant the user wants painted: off (as the model wrote it, American),
/// British, or Canadian (CT-20).
///
/// ## Why a post-decode map
///
/// A base model cannot be steered to a locale by prompt (that was the conflict in the catalog).
/// But no steering is needed: the decode is American-leaning English, and a whole-word map from
/// the American form to the target form turns it into the requested variant. It runs on the
/// finished continuation, after the rest of the output shaping, so it never
/// influences the decode, the gates or the copy guard.
///
/// ## What it touches
///
/// - Whole words only. A run of letters is looked up in a table, so `prize` and `size` are safe
///   next to `organize`.
/// - The case pattern of the source word is kept (`Color` becomes `Colour`, `COLOR` becomes
///   `COLOUR`). A mixed-case word such as `iPhone` is left alone.
/// - Never the prefix. The first letter run of the continuation is skipped when it is glued onto
///   a word the user is still typing (`col` + `or`), because that run is a fragment, not a word.
/// - English only. `NLLanguageRecognizer` runs on the last 200 characters of the prefix plus the
///   continuation. The map applies when the verdict is English or "unknown" (very short text) and
///   returns the text unchanged for any other language. This matters because several table
///   stems are also Spanish or Portuguese words (`color`, `honor`, `valor`), and a false
///   positive there would corrupt the text.
///
/// ## Word table
///
/// Written by hand for this project from the regular spelling classes (-or/-our, -ize/-ise,
/// -yze/-yse, -er/-re, doubled l, -og/-ogue, -ense/-ence) plus a short list of irregulars. It is
/// not copied from another product, and no third-party word list is bundled, so there is no
/// licence to acknowledge. Canadian takes -our, -re, doubled l, -ogue, -ence and the Canadian
/// irregulars, and keeps -ize, -yze, `aluminum` and `mom`.
///
/// The map can change the length of the text, so it runs after every step that measures length
/// (the copy guard, the boundary join, `SentenceStartCase`). The display window counts words, not
/// characters, so it is unaffected.
public enum SpellingVariant: String, CaseIterable, Sendable {
    case off
    case british
    case canadian

    public static let `default` = SpellingVariant.off

    /// Read a persisted value fail-safe: an absent or unknown value is `.off`, the behaviour
    /// before this setting existed.
    public init(stored: String?) {
        self = stored.flatMap(SpellingVariant.init(rawValue:)) ?? .default
    }

    /// Rewrite `text`, the decoded continuation, into this variant. Returns `text` itself for
    /// `.off`, for any language other than English, and when no word is in the table.
    public func apply(to text: String, textBeforeCaret: String) -> String {
        guard self != .off, !text.isEmpty else { return text }
        let table = SpellingVariantTable.table(for: self)
        // Cheap pre-check before the language recognizer: most continuations hold no listed word.
        guard Self.containsListedWord(text, table: table, textBeforeCaret: textBeforeCaret) else { return text }
        if !Self.looksEnglish(text: text, textBeforeCaret: textBeforeCaret) { return text }
        return Self.rewrite(text, table: table, textBeforeCaret: textBeforeCaret)
    }

    // MARK: Internals

    private static func looksEnglish(text: String, textBeforeCaret: String) -> Bool {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(textBeforeCaret.suffix(200)) + text)
        let language = recognizer.dominantLanguage
        return language == nil || language == .english
    }

    /// Letter runs of `text` as (range, isFirstRunGluedToPrefix) pairs.
    private static func letterRuns(_ text: String, textBeforeCaret: String) -> [Range<String.Index>] {
        var runs: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isLetter {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(s..<i)
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { runs.append(s..<text.endIndex) }
        // A first run that starts at index 0 while the prefix ends in a letter continues the
        // word the user is typing, so it is a fragment.
        if let first = runs.first, first.lowerBound == text.startIndex,
           textBeforeCaret.last?.isLetter == true {
            runs.removeFirst()
        }
        return runs
    }

    private static func containsListedWord(_ text: String, table: [String: String],
                                           textBeforeCaret: String) -> Bool {
        letterRuns(text, textBeforeCaret: textBeforeCaret).contains { table[String(text[$0]).lowercased()] != nil }
    }

    private static func rewrite(_ text: String, table: [String: String], textBeforeCaret: String) -> String {
        var out = text
        // Back to front so earlier ranges stay valid while lengths change.
        for run in letterRuns(text, textBeforeCaret: textBeforeCaret).reversed() {
            let word = String(text[run])
            guard let target = table[word.lowercased()],
                  let cased = matchCase(of: word, applyTo: target) else { continue }
            out.replaceSubrange(run, with: cased)
        }
        return out
    }

    /// nil for a mixed-case word, which the map leaves alone.
    private static func matchCase(of source: String, applyTo target: String) -> String? {
        if source == source.lowercased() { return target }
        if source.count > 1, source == source.uppercased() { return target.uppercased() }
        if let first = source.first, first.isUppercase, source.dropFirst() == source.dropFirst().lowercased() {
            return target.prefix(1).uppercased() + target.dropFirst()
        }
        return nil
    }
}
