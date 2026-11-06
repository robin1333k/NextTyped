import SwiftUI

/// A switch row: body-weight title, optional one-line secondary subtitle, trailing switch.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A requirement or state: leading symbol, title, subtitle, trailing badge, optional action under the badge.
struct SettingsStatusRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let badge: StatusBadge
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                badge
                if let action {
                    Button(action.title, action: action.perform)
                }
            }
        }
    }
}

/// A read-only label and value. A numeric value uses monospaced digits.
struct SettingsValueRow: View {
    let title: String
    let value: String
    /// Forces monospaced digits for a value with a unit, such as "89 keystrokes per minute".
    var monospacesDigits = false

    private var isNumeric: Bool {
        monospacesDigits || !value.isEmpty && value.allSatisfy { $0.isNumber || ",.%+-: ".contains($0) }
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(isNumeric ? .body.monospacedDigit() : .body)
                .foregroundStyle(.secondary)
        }
    }
}

/// A destructive action in its own row: trailing bordered button, its own confirmation, disabled when there is nothing to delete.
struct SettingsDestructiveRow: View {
    let title: String
    var isEnabled = true
    let confirmTitle: String
    let confirmMessage: String
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        HStack {
            Spacer()
            Button(title, role: .destructive) { isConfirming = true }
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .confirmationDialog(confirmTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(title, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }
}

/// A row that opens a URL: About and help links. `value` is an optional trailing word, such as a licence name.
struct SettingsLinkRow: View {
    let title: String
    let symbol: String
    var value: String? = nil
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let value {
                    Text(value).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }
}
