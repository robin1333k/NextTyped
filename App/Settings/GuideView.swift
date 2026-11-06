import AppKit
import NextTypedCore
import SwiftUI

/// Draws a `GuideDocument` with the Settings window's type and colours (`docs/design/settings.md`): system
/// text styles, semantic colours, `.quaternary` fills. Text is selectable and read-only; only absolute
/// http and https links are clickable (a relative path such as `adr/0003.md` does not exist in the bundle).
struct GuideView: View {
    let document: GuideDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    GuideBlockView(block: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct GuideBlockView: View {
    let block: GuideBlock

    var body: some View {
        switch block {
        case .heading(let level, let spans):
            Text(GuideText.attributed(spans))
                .font(Self.headingFont(level))
                .fontWeight(level <= 2 ? .semibold : .medium)
                .padding(.top, level == 1 ? 0 : 10)
        case .paragraph(let spans):
            Text(GuideText.attributed(spans))
                .fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            list(items) { _ in "•" }
        case .numbered(let items):
            list(items) { "\($0 + 1)." }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .table(let header, let rows):
            GuideTable(header: header, rows: rows)
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        default: .headline
        }
    }

    private func list(_ items: [[GuideSpan]], marker: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, spans in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)
                    Text(GuideText.attributed(spans)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct GuideTable: View {
    let header: [[GuideSpan]]
    let rows: [[[GuideSpan]]]

    var body: some View {
        VStack(spacing: 0) {
            row(header, isHeader: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Divider()
                row(cells, isHeader: false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ cells: [[GuideSpan]], isHeader: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, spans in
                Text(GuideText.attributed(spans))
                    .font(isHeader ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(isHeader ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHeader ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
    }
}

/// Spans to `AttributedString`.
enum GuideText {
    static func attributed(_ spans: [GuideSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            switch span {
            case .text(let s):
                result += AttributedString(s)
            case .bold(let s):
                var part = AttributedString(s)
                part.inlinePresentationIntent = .stronglyEmphasized
                result += part
            case .code(let s):
                var part = AttributedString(s)
                part.inlinePresentationIntent = .code
                result += part
            case .link(let text, let destination):
                var part = AttributedString(text)
                if let url = URL(string: destination), let scheme = url.scheme?.lowercased(),
                   scheme == "http" || scheme == "https" {
                    part.link = url
                }
                result += part
            }
        }
        return result
    }
}
