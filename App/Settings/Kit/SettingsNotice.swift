import SwiftUI

/// The one inline warning layout. It sits inside the section it concerns.
struct SettingsNotice<Actions: View>: View {
    enum Kind {
        case info, attention, error

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .attention: "exclamationmark.triangle.fill"
            case .error: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: .secondary
            case .attention: .orange
            case .error: .red
            }
        }

        var word: String {
            switch self {
            case .info: "Note"
            case .attention: "Warning"
            case .error: "Error"
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityLabel(kind.word)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .fontWeight(.medium)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { actions() }
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }
}

extension SettingsNotice where Actions == EmptyView {
    init(kind: Kind, title: String, message: String) {
        self.init(kind: kind, title: title, message: message) { EmptyView() }
    }
}
