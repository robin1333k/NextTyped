import Foundation
import Testing
@testable import NextTypedCore

@Suite("GuideDocument: the Markdown subset of the two bundled guides")
struct GuideDocumentTests {
    @Test("A heading carries its level and loses the hashes")
    func heading() {
        let doc = GuideDocument(markdown: "# Uninstall NextTyped\n\n## 1. Turn off Launch at login")
        #expect(doc.blocks == [
            .heading(level: 1, spans: [.text("Uninstall NextTyped")]),
            .heading(level: 2, spans: [.text("1. Turn off Launch at login")]),
        ])
    }

    @Test("Bold, inline code and a link become spans without their markers")
    func inline() {
        let doc = GuideDocument(markdown: "Switch **Launch at login** off, run `rm -r x`, see [ADR-0003](adr/0003.md).")
        #expect(doc.blocks == [
            .paragraph([
                .text("Switch "), .bold("Launch at login"), .text(" off, run "), .code("rm -r x"),
                .text(", see "), .link(text: "ADR-0003", destination: "adr/0003.md"), .text("."),
            ])
        ])
    }

    @Test("An asterisk inside inline code is not bold")
    func asteriskInCode() {
        let doc = GuideDocument(markdown: "Delete `models--Robin1333k--*` and `*x*` folders.")
        #expect(doc.blocks == [
            .paragraph([.text("Delete "), .code("models--Robin1333k--*"), .text(" and "), .code("*x*"), .text(" folders.")])
        ])
    }

    @Test("Consecutive lines of one paragraph join with a space")
    func paragraphJoin() {
        let doc = GuideDocument(markdown: "first line\nsecond line\n\nnext")
        #expect(doc.blocks == [.paragraph([.text("first line second line")]), .paragraph([.text("next")])])
    }

    @Test("Dash lines form one bullet list")
    func bullets() {
        let doc = GuideDocument(markdown: "- Google Chrome. Flag.\n- Dia.\n\nafter")
        #expect(doc.blocks == [
            .bullets([[.text("Google Chrome. Flag.")], [.text("Dia.")]]),
            .paragraph([.text("after")]),
        ])
    }

    @Test("Numbered lines form one numbered list")
    func numbered() {
        let doc = GuideDocument(markdown: "1. One\n2. Two **bold**")
        #expect(doc.blocks == [.numbered([[.text("One")], [.text("Two "), .bold("bold")]])])
    }

    @Test("A fenced block keeps its lines verbatim and drops the fence")
    func fenced() {
        let doc = GuideDocument(markdown: "Run:\n\n```bash\nrm -r ~/a\\ b\n# comment | pipe\n```\n\nDone")
        #expect(doc.blocks == [
            .paragraph([.text("Run:")]),
            .code("rm -r ~/a\\ b\n# comment | pipe"),
            .paragraph([.text("Done")]),
        ])
    }

    @Test("A table has a header row, no separator row, and cells with spans")
    func table() {
        let md = """
        | Mode | What you see |
        | --- | --- |
        | Inline | The ghost sits at the `caret`. |
        | Bubble | Below the line. |
        """
        let doc = GuideDocument(markdown: md)
        #expect(doc.blocks == [
            .table(header: [[.text("Mode")], [.text("What you see")]],
                   rows: [
                    [[.text("Inline")], [.text("The ghost sits at the "), .code("caret"), .text(".")]],
                    [[.text("Bubble")], [.text("Below the line.")]],
                   ])
        ])
    }

    @Test("A cell may hold a link with a pipe-free destination")
    func tableLink() {
        let doc = GuideDocument(markdown: "| A | B |\n| --- | --- |\n| x | [ADR-0003](adr/0003.md). |")
        guard case .table(_, let rows) = doc.blocks.first else { Issue.record("no table"); return }
        #expect(rows == [[[.text("x")], [.link(text: "ADR-0003", destination: "adr/0003.md"), .text(".")]]])
    }

    @Test("No block keeps Markdown syntax in its text")
    func noSyntaxLeft() {
        let md = "# T\n\nA **b** `c` [d](e).\n\n- x\n\n| h | i |\n| --- | --- |\n| 1 | 2 |"
        for block in GuideDocument(markdown: md).blocks {
            #expect(!block.plainText.contains("**"))
            #expect(!block.plainText.contains("|"))
            #expect(!block.plainText.contains("#"))
            #expect(!block.plainText.contains("]("))
        }
    }

    @Test("The shipped guides parse: the 25 table lines of compatibility.md become tables and no block keeps raw syntax")
    func shippedGuides() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs")
        let compat = GuideDocument(markdown: try String(contentsOf: root.appendingPathComponent("compatibility.md"), encoding: .utf8))
        let uninstall = GuideDocument(markdown: try String(contentsOf: root.appendingPathComponent("uninstall.md"), encoding: .utf8))
        let rowCount = compat.blocks.reduce(0) { total, block in
            if case .table(_, let rows) = block { return total + rows.count + 2 } else { return total }
        }
        // 25 raw table lines: each table is one header line, one separator line and its body rows.
        #expect(rowCount == 25)
        for block in compat.blocks + uninstall.blocks {
            if case .code = block { continue }
            #expect(!block.plainText.contains("**"))
            #expect(!block.plainText.hasPrefix("#"))
            #expect(!block.plainText.contains("]("))
        }
    }
}
