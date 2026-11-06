import AppKit
import NextTypedCore
import KeyboardShortcuts
import SwiftUI

/// Shortcuts pane, the one place keyboard shortcuts live.
///
/// The pause hotkey **moved here out of General** deliberately: keyboard shortcuts in two panes is the
/// confusion this Settings window already produced once, when the master "Learn my writing style"
/// switch (Privacy) and the per-app "Learn" switch (Apps) shared a name across two panes and the user
/// could not find the one being asked for.
///
/// The accept and dismiss keys are **rebindable**: `Tab`,
/// `⌥Tab` and `Esc` are only defaults. What stays fixed is the posture: they are taken only while a
/// completion is visible, and a chord another of ours, typing, navigation or macOS needs is refused
/// (`InterceptBindings.rebinding`).
struct ShortcutsSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                InterceptKeyRow(action: .acceptWord, title: "Accept the next word")
                InterceptKeyRow(action: .acceptAll, title: "Accept the whole completion")
                InterceptKeyRow(action: .dismiss, title: "Dismiss the completion")
                Picker("When dismissing", selection: Binding(
                    get: { coordinator.escBehaviour },
                    set: { coordinator.setEscBehaviour($0) })) {
                        Text("Dismiss only").tag(EscBehaviour.dismissOnly)
                        Text("Dismiss and pause this field briefly").tag(EscBehaviour.dismissAndPauseField)
                    }
            } header: {
                Text("While a completion is showing")
            } footer: {
                Text("These keys are only taken while a completion is visible. Otherwise the key does "
                     + "what the app does. Pausing keeps the field quiet for "
                     + "\(EscBehaviour.fieldPauseSeconds) seconds or until you switch fields.")
            }

            Section {
                Picker("Trailing punctuation", selection: Binding(
                    get: { coordinator.trailingPunctuation },
                    set: { coordinator.setTrailingPunctuation($0) })) {
                        Text("With both shortcuts").tag(TrailingPunctuation.bothShortcuts)
                        Text("Only with the whole completion").tag(TrailingPunctuation.fullAcceptOnly)
                        Text("With neither").tag(TrailingPunctuation.neither)
                    }
            } header: {
                Text("When accepting")
            } footer: {
                Text("Punctuation a key leaves out stays in the completion. Pressing either key again "
                     + "inserts it. To end without it, press Return or keep typing.")
            }

            Section {
                // All three ship UNASSIGNED (no default key), so nothing collides with an app shortcut
                // on any keyboard layout, as for the pause key.
                RecorderRow(name: .togglePause, title: "Pause or resume",
                            subtitle: "Turns completions off everywhere until you press it again.")
                RecorderRow(name: .forceActivate, title: "Suggest something here",
                            subtitle: "Asks for a completion where NextTyped would stay quiet, "
                                + "such as a search field. Apps you turned off stay off.")
                RecorderRow(name: .temporaryQuiet, title: "Quiet the current app",
                            subtitle: "Stops completions in the frontmost app for "
                                + "\(TemporaryQuietDuration.hotkeyDefault.minutes) minutes. "
                                + "Press again to resume.")
            } header: {
                Text("Global")
            }
        }
        .formStyle(.grouped)
    }
}

/// A recorder with a body-weight title and a one-line secondary subtitle. A recording that lands on
/// one of the three intercept keys is cleared again, the other half of the collision rule.
private struct RecorderRow: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let name: KeyboardShortcuts.Name
    let title: String
    let subtitle: String
    @State private var refusal: String?

    var body: some View {
        KeyboardShortcuts.Recorder(for: name, onChange: { shortcut in
            guard let shortcut,
                  let taken = coordinator.interceptBindings.collidesWithIntercept(KeyChord(shortcut: shortcut))
            else {
                refusal = nil
                return
            }
            KeyboardShortcuts.setShortcut(nil, for: name)
            refusal = "That key already does \(taken.settingsTitle.lowercased())."
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(refusal ?? subtitle)
                    .font(.subheadline)
                    .foregroundStyle(refusal == nil ? .secondary : Color.red)
            }
        }
    }
}

/// One intercept key: its current chord, a button that records the next key press, and a reset to
/// our default. Recording reads a local `keyDown` monitor, so any key works, `Tab` and `Esc` included,
/// which `KeyboardShortcuts.Recorder` refuses without a modifier.
private struct InterceptKeyRow: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let action: InterceptAction
    let title: String
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refusal: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                if recording {
                    Text("Press a key")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { stopRecording() }
                } else {
                    // No `.accessibilityLabel` here: a label modifier on a control inside `LabeledContent`
                    // made SwiftUI's AX label resolution recurse until the stack overflowed.
                    Button(coordinator.interceptBindings[action].label) { startRecording() }
                    if coordinator.interceptBindings[action] != InterceptBindings.defaults[action] {
                        Button("Reset") { refusal = coordinator.resetBinding(action).map(Self.message) }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let refusal {
                    Text(refusal)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        refusal = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chord = KeyChord(keyCode: Int(event.keyCode), modifiers: KeyModifiers(event.modifierFlags))
            refusal = coordinator.rebind(action, to: chord).map(Self.message)
            stopRecording()
            return nil   // the recorded key goes nowhere else
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private static func message(_ refusal: BindingRefusal) -> String {
        switch refusal {
        case .collides(let other): return "That key already does \(other.settingsTitle.lowercased())."
        case .collidesWithGlobalShortcut: return "That key is already a global shortcut below."
        case .typesCharacter: return "That key types text. Add Command or Control, or pick Tab, Esc or a function key."
        case .movesCaret: return "That key moves the cursor or deletes text."
        case .systemShortcut: return "macOS already uses that key."
        }
    }
}

extension InterceptAction {
    /// The action's name in the Shortcuts pane and in refusal messages.
    var settingsTitle: String {
        switch self {
        case .acceptWord: return "Accept the next word"
        case .acceptAll: return "Accept the whole completion"
        case .dismiss: return "Dismiss the completion"
        }
    }
}
