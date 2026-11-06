import Foundation

/// One run of inline text in a guide. Markers (`**`, backticks, brackets) are gone.
public enum GuideSpan: Equatable, Sendable {
    case text(String)
    case bold(String)
    case code(String)
    case link(text: String, destination: String)

    /// The visible characters.
    public var plainText: String {
        switch self {
        case .text(let s), .bold(let s), .code(let s): s
        case .link(let text, _): text
        }
    }
}

/// One block of a guide.
public enum GuideBlock: Equatable, Sendable {
    case heading(level: Int, spans: [GuideSpan])
    case paragraph([GuideSpan])
    case bullets([[GuideSpan]])
    case numbered([[GuideSpan]])
    /// A fenced block: lines verbatim, fence and language dropped.
    case code(String)
    /// `header` and every row have the same number of cells; the separator row is dropped.
    case table(header: [[GuideSpan]], rows: [[[GuideSpan]]])

    /// Everything the reader sees, joined with spaces. Used to check that no syntax is left.
    public var plainText: String {
        func join(_ spans: [GuideSpan]) -> String { spans.map(\.plainText).joined() }
        switch self {
        case .heading(_, let spans), .paragraph(let spans): return join(spans)
        case .bullets(let items), .numbered(let items): return items.map(join).joined(separator: " ")
        case .code(let text): return text
        case .table(let header, let rows):
            return (([header] + rows).flatMap { $0 }).map(join).joined(separator: " ")
        }
    }
}

/// The Markdown subset used by `docs/compatibility.md` and `docs/uninstall.md`: headings, paragraphs, dash
/// bullets, numbered lists, fenced code, pipe tables, and the inline forms bold, code and link. It is not
/// a general Markdown engine; a construct outside the subset shows as plain text. The Settings guide
/// window draws these blocks (`App/Settings/GuideView.swift`).
public struct GuideDocument: Equatable, Sendable {
    public let blocks: [GuideBlock]

    public init(markdown: String) {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [GuideBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { index += 1; continue }

            if trimmed.hasPrefix("```") {
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index]); index += 1
                }
                index += 1 // the closing fence
                blocks.append(.code(body.joined(separator: "\n")))
            } else if let heading = Self.heading(trimmed) {
                blocks.append(heading); index += 1
            } else if trimmed.hasPrefix("|") {
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(Self.cells(lines[index])); index += 1
                }
                blocks.append(Self.table(rows))
            } else if Self.bulletText(trimmed) != nil {
                var items: [[GuideSpan]] = []
                while index < lines.count, let text = Self.bulletText(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(Self.spans(text)); index += 1
                }
                blocks.append(.bullets(items))
            } else if Self.numberedText(trimmed) != nil {
                var items: [[GuideSpan]] = []
                while index < lines.count, let text = Self.numberedText(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(Self.spans(text)); index += 1
                }
                blocks.append(.numbered(items))
            } else {
                var parts: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("|") || t.hasPrefix("#")
                        || Self.bulletText(t) != nil || Self.numberedText(t) != nil { break }
                    parts.append(t); index += 1
                }
                blocks.append(.paragraph(Self.spans(parts.joined(separator: " "))))
            }
        }
        self.blocks = blocks
    }

    // MARK: Blocks

    private static func heading(_ line: String) -> GuideBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, spans: spans(String(line.dropFirst(hashes + 1))))
    }

    private static func bulletText(_ line: String) -> String? {
        line.hasPrefix("- ") ? String(line.dropFirst(2)) : nil
    }

    private static func numberedText(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.dropFirst(digits.count + 2))
    }

    /// Splits a table line on pipes that are outside inline code.
    private static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        for ch in line.trimmingCharacters(in: .whitespaces) {
            if ch == "`" { inCode.toggle() }
            if ch == "|", !inCode { cells.append(current); current = "" } else { current.append(ch) }
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces) == "" { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces) == "" { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func table(_ rows: [[String]]) -> GuideBlock {
        let isSeparator: ([String]) -> Bool = { row in
            !row.isEmpty && row.allSatisfy { !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }
        }
        let body = rows.filter { !isSeparator($0) }
        guard let head = body.first else { return .table(header: [], rows: []) }
        let width = head.count
        let pad: ([String]) -> [[GuideSpan]] = { row in
            (0..<width).map { $0 < row.count ? spans(row[$0]) : [] }
        }
        return .table(header: pad(head), rows: body.dropFirst().map(pad))
    }

    // MARK: Inline

    /// Bold (`**x**`), code (`` `x` ``) and link (`[x](y)`). Code is matched first, so markers inside it stay.
    static func spans(_ text: String) -> [GuideSpan] {
        var spans: [GuideSpan] = []
        var plain = ""
        let chars = Array(text)
        var i = 0
        func flush() { if !plain.isEmpty { spans.append(.text(plain)); plain = "" } }
        func find(_ marker: [Character], from start: Int) -> Int? {
            guard start + marker.count <= chars.count else { return nil }
            for j in start...(chars.count - marker.count) where Array(chars[j..<(j + marker.count)]) == marker { return j }
            return nil
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "`", let end = find(["`"], from: i + 1) {
                flush(); spans.append(.code(String(chars[(i + 1)..<end]))); i = end + 1
            } else if ch == "*", i + 1 < chars.count, chars[i + 1] == "*", let end = find(["*", "*"], from: i + 2), end > i + 2 {
                flush(); spans.append(.bold(String(chars[(i + 2)..<end]))); i = end + 2
            } else if ch == "[", let close = find(["]", "("], from: i + 1), let paren = find([")"], from: close + 2) {
                flush()
                spans.append(.link(text: String(chars[(i + 1)..<close]), destination: String(chars[(close + 2)..<paren])))
                i = paren + 1
            } else {
                plain.append(ch); i += 1
            }
        }
        flush()
        return spans
    }
}
