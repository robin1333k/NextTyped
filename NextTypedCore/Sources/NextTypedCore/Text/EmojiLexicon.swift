import Foundation

/// Emoji names and keywords in English and German, from the Unicode CLDR annotations (Unicode-3.0
/// licence, listed in About). Built by `scripts/generate-emoji-lexicon.sh` into one lzfse resource.
public struct EmojiLexicon: Sendable {
    private struct Entry: Sendable {
        let emoji: String
        /// Folded names (English, German) and folded keywords of both languages.
        let names: [String]
        let keywords: [String]
    }

    private let entries: [Entry]

    /// `rows` are `emoji TAB en-name TAB en-keywords TAB de-name TAB de-keywords`, keywords joined by `|`.
    public init(rows: [String]) {
        entries = rows.compactMap { row in
            let f = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5, !f[0].isEmpty else { return nil }
            return Entry(
                emoji: f[0],
                names: [f[1], f[3]].filter { !$0.isEmpty }.map(Self.fold),
                keywords: (f[2].split(separator: "|") + f[4].split(separator: "|")).map { Self.fold(String($0)) })
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The bundled lexicon. Empty when the resource is missing, which makes every trigger log
    /// `[gate]: emoji-no-match`; a test pins that it is not empty.
    public static let bundled: EmojiLexicon = {
        guard let url = Bundle.module.url(forResource: "emoji-lexicon", withExtension: "lzfse"),
              let packed = try? Data(contentsOf: url),
              let plain = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let text = String(data: plain, encoding: .utf8) else { return EmojiLexicon(rows: []) }
        return EmojiLexicon(rows: text.split(separator: "\n").map(String.init))
    }()

    /// The best emoji for what the user typed after the colon, or `nil`. A name that starts with the
    /// fragment or a word of it beats a keyword; ties go to the shorter English name, the generic one (":herz"
    /// gives "red heart", not "purple heart"), then to the lower code point.
    public func bestMatch(for fragment: String) -> String? {
        let query = Self.fold(fragment)
        guard !query.isEmpty else { return nil }
        var best: (score: Int, nameLength: Int, emoji: String)?
        for entry in entries {
            let (score, nameLength) = Self.score(entry, query)
            guard score > 0 else { continue }
            if let b = best, (score, -nameLength) <= (b.score, -b.nameLength) { continue }
            best = (score, nameLength, entry.emoji)
        }
        return best?.emoji
    }

    /// Score 2 for a name (or a word of one) that starts with the query, 1 for a keyword; the second
    /// value is the length of the entry's English name (the first name), the tie-break.
    private static func score(_ entry: Entry, _ query: String) -> (Int, Int) {
        var score = 0
        let nameLength = entry.names.first?.count ?? Int.max
        for name in entry.names where name.hasPrefix(query) || wordPrefix(name, query) { score = 2 }
        if score == 0 {
            for keyword in entry.keywords where keyword.hasPrefix(query) || wordPrefix(keyword, query) { score = 1 }
        }
        return (score, nameLength)
    }

    private static func wordPrefix(_ text: String, _ query: String) -> Bool {
        text.split(separator: " ").contains { $0.hasPrefix(query) }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
