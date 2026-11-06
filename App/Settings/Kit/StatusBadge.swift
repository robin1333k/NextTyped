import SwiftUI

/// The one status vocabulary of the Settings window: an icon and a word in a capsule, never colour alone.
/// See `docs/design/settings.md`.
struct StatusBadge: View {
    enum Kind: CaseIterable {
        case ok, attention, error, off

        var symbol: String {
            switch self {
            case .ok: "checkmark.circle.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            case .off: "minus.circle"
            }
        }

        var color: Color {
            switch self {
            case .ok: .green
            case .attention: .orange
            case .error: .red
            case .off: .secondary
            }
        }
    }

    let kind: Kind
    let label: String

    var body: some View {
        // The icon carries the kind's colour; the word stays `.primary` so it keeps text contrast
        // on the tinted fill in light mode.
        Label {
            Text(label).foregroundStyle(.primary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(kind.color)
        }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(kind.color.quaternary, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}
