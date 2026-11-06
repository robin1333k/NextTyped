#if DEBUG
import SwiftUI

/// Every component of the style kit in every state, in one grouped form. Rendered by the snapshot renderer
/// as the extra page `kit-gallery`.
struct SettingsKitGallery: View {
    @State private var on = true
    @State private var off = false

    var body: some View {
        Form {
            Section("Status badges") {
                ForEach(StatusBadge.Kind.allCases, id: \.self) { kind in
                    LabeledContent(String(describing: kind)) {
                        StatusBadge(kind: kind, label: Self.word(for: kind))
                    }
                }
            }
            Section("Toggle rows") {
                SettingsToggleRow(title: "Enable completions", subtitle: "Suggests words as you type.", isOn: $on)
                SettingsToggleRow(title: "Check spelling", isOn: $off)
            }
            Section("Status rows") {
                SettingsStatusRow(symbol: "hand.raised", title: "Accessibility",
                                  subtitle: "Lets NextTyped read the text field you type in.",
                                  badge: StatusBadge(kind: .ok, label: "Granted"))
                SettingsStatusRow(symbol: "cpu", title: "Model",
                                  subtitle: "The model could not be loaded.",
                                  badge: StatusBadge(kind: .error, label: "Failed"),
                                  action: (title: "Retry", perform: {}))
                SettingsStatusRow(symbol: "record.circle", title: "Screen Recording",
                                  badge: StatusBadge(kind: .off, label: "Off"))
            }
            Section("Value rows") {
                SettingsValueRow(title: "Words accepted", value: "1,284")
                SettingsValueRow(title: "Model", value: MLXPredictionEngine.displayName)
            }
            Section("Destructive rows") {
                SettingsDestructiveRow(title: "Delete learned profile", confirmTitle: "Delete the learned profile?",
                                       confirmMessage: "This cannot be undone.", action: {})
                SettingsDestructiveRow(title: "Reset statistics", isEnabled: false, confirmTitle: "Reset statistics?",
                                       confirmMessage: "This cannot be undone.", action: {})
            }
            Section("Link rows") {
                SettingsLinkRow(title: "Compatibility list", symbol: "list.bullet",
                                url: URL(fileURLWithPath: "/"))
            }
            Section("Notices") {
                SettingsNotice(kind: .info, title: "Profile is local",
                               message: "The style profile never leaves this Mac.")
                SettingsNotice(kind: .attention, title: "Profile is not saving",
                               message: "The key could not be read from the Keychain.") {
                    Button("Try again") {}
                }
                SettingsNotice(kind: .error, title: "Screen Recording is missing",
                               message: "Screen context stays off until you allow it.") {
                    Button("Open System Settings") {}
                    Button("Dismiss") {}
                }
            }
            Section("Key caps") {
                LabeledContent("Accept next word") { KeyCap("Tab") }
                LabeledContent("Accept all") { KeyCap("⌥Tab") }
            }
            Section("Facts") {
                SettingsFacts(rows: [
                    ("Reads", "The text before the caret in the focused field."),
                    ("Stored", "Nothing leaves this Mac. The style profile is encrypted on disk."),
                    ("Not guaranteed", "German completions are weaker than English ones, and a long completion can wander off topic."),
                ])
            }
        }
        .formStyle(.grouped)
    }

    private static func word(for kind: StatusBadge.Kind) -> String {
        switch kind {
        case .ok: "Ready"
        case .attention: "Needs attention"
        case .error: "Failed"
        case .off: "Off"
        }
    }
}
#endif
