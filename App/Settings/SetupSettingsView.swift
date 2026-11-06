import NextTypedCore
import SwiftUI

/// Setup pane: the onboarding checklist, mirrored into Settings. A summary row, the requirements
/// (Accessibility, the on-device model), an Optional section that lists the sources that ship off
/// (screen text, writing style), the macOS inline-prediction advisory and the Support list.
/// Everything here reads live state; the only actions are grant and retry affordances. The counting and the wording
/// of the summary live in Core (`SetupChecklist`).
struct SetupSettingsView: View {
    /// Remembers that the system Accessibility prompt was shown, so the row offers "Open System Settings"
    /// afterwards: the prompt appears once per binary and a second request does nothing visible.
    static let promptShownKey = Permissions.accessibilityPromptShownKey

    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var permissions = PermissionsModel()
    @AppStorage(SetupSettingsView.promptShownKey) private var promptShown = false
    /// Polls the OS inline-prediction key while this pane is on screen: the row
    /// advises about a checkbox in System Settings, so it has to track it with our window in the
    /// background.
    @StateObject private var inlinePrediction = InlinePredictionStatusModel()
    @State private var showingScreenExplainer = false

    private var checklist: SetupChecklist {
        SetupChecklist(accessibilityGranted: permissions.hasAccessibility,
                       modelReady: coordinator.modelLoadState.canPredict,
                       accessibilityPromptShown: promptShown)
    }

    var body: some View {
        Form {
            Section {
                SettingsStatusRow(
                    symbol: checklist.isReady ? "checkmark.seal" : "checklist",
                    title: checklist.summaryTitle,
                    subtitle: checklist.isReady ? "Start typing in any app." : "Complete the steps below.",
                    badge: StatusBadge(kind: checklist.isReady ? .ok : .attention, label: checklist.summaryBadge))
            }

            Section {
                // Accessibility is the one hard requirement (active CGEventTap).
                SettingsStatusRow(
                    symbol: "hand.raised",
                    title: Permissions.accessibilityListTitle,
                    subtitle: "Lets NextTyped read the text around your cursor. Nothing you type leaves your Mac. "
                        + Permissions.accessibilityFindHint,
                    badge: permissions.hasAccessibility
                        ? StatusBadge(kind: .ok, label: "Granted")
                        : StatusBadge(kind: .attention, label: "Not granted"),
                    action: accessibilityAction)
                modelRow
            } header: {
                Text("Requirements")
            } footer: {
                // The A/B disclosure: an
                // accepted limit that is not stated is a hidden one, and running trust-first is a
                // deliberate differentiator. It sits here, under the model status, because that is the
                // object it makes a claim about, and deliberately NOT in onboarding, where the user has not
                // yet seen a single ghost and the warning would collide with the permission prompt.
                //
                // The wording is bounded by what was actually measured, and the boundary is load-bearing:
                // only the German-specific classes may be named as German. Class A (hard DE grammar) and
                // B (English calques/collocations) are the accepted v1 limit; the fabrication, repetition
                // and verbatim-copying classes were measured at EN/DE **parity**
                // , so calling them German would be false.
                // Second half is non-negotiable per the ticket: nothing is ever inserted unasked.
                // Model-neutral on purpose: the 4B loads where its folder exists, else the 2B;
                // Settings → General names the one that loaded.
                Text("Completions come from a model with a few billion parameters, running entirely on your Mac. "
                     + "It is small by design: private and fast, but less accurate than a cloud "
                     + "assistant. In German especially, a completion can be grammatically wrong or read "
                     + "like literal English. Nothing is ever inserted on its own. A completion becomes "
                     + "text only when you press Tab. Right-to-left text (Hebrew, Arabic and similar) is "
                     + "not supported: in a paragraph with such text nothing is suggested. "
                     + "General → Languages can switch German off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Optional sources are listed whether they are on or not, and they never count as missing
            // (`SetupOptionalSource`): no attention badge for an off switch, and nothing here
            // feeds the summary row or the sidebar badge.
            Section {
                screenTextRow
                writingStyleRow
            } header: {
                Text("Optional")
            } footer: {
                Text("Both ship off. NextTyped works fully without them.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Shown for an absent key too (neutral badge): the button is the only way to clear it.
            if inlinePrediction.advisory != .hidden {
                Section("Recommended") { inlinePredictionRow }
            }

            SupportListSection()
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            inlinePrediction.startPolling()
        }
        .onDisappear { inlinePrediction.stopPolling() }
        .sheet(isPresented: $showingScreenExplainer) {
            ScreenRecordingExplainer(
                onContinue: {
                    showingScreenExplainer = false
                    coordinator.setScreenOCREnabled(true)
                },
                onCancel: { showingScreenExplainer = false })
        }
    }

    // MARK: Optional sources

    private func optionalBadge(_ state: SetupOptionalSource.State) -> StatusBadge {
        switch state {
        case .off: StatusBadge(kind: .off, label: "Off")
        case .on: StatusBadge(kind: .ok, label: "On")
        case .waitingForPermission: StatusBadge(kind: .attention, label: "Waiting for permission")
        }
    }

    private var screenTextRow: some View {
        let state = SetupOptionalSource.screenText.state(
            isOn: coordinator.screenOCRRequested, needsPermission: coordinator.screenOCRNeedsPermission)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                SettingsToggleRow(
                    title: "Screen text",
                    subtitle: "Reads the text visible on your screen, such as a document in another window. "
                        + "Needs the Screen Recording permission.",
                    isOn: Binding(
                        get: { coordinator.screenOCRRequested },
                        set: { wantsOn in
                            // The explainer comes before the OS dialog, as in the Privacy pane.
                            if wantsOn { showingScreenExplainer = true } else { coordinator.setScreenOCREnabled(false) }
                        }))
                optionalBadge(state)
            }
            HStack(spacing: 12) {
                if state == .waitingForPermission {
                    Button("Open System Settings") { Permissions.openSettings(for: .screenRecording) }
                }
                privacyLink
            }
            .padding(.leading, 2)
        }
    }

    private var writingStyleRow: some View {
        let state = SetupOptionalSource.writingStyle.state(
            isOn: coordinator.isPersonalizationEnabled, needsPermission: false)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                SettingsToggleRow(
                    title: "Writing style",
                    subtitle: "Learns only from text you typed or accepted in this app's completions, so they sound like you. "
                        + "Experimental.",
                    isOn: Binding(
                        get: { coordinator.isPersonalizationEnabled },
                        set: { coordinator.setPersonalizationEnabled($0) }))
                optionalBadge(state)
            }
            privacyLink.padding(.leading, 2)
        }
    }

    private var privacyLink: some View {
        Button("What it reads and keeps") { SettingsNavigation.shared.selection = .privacy }
            .buttonStyle(.link)
    }

    private var accessibilityAction: (title: String, perform: () -> Void)? {
        switch checklist.accessibilityAction {
        case .requestAccess:
            return (title: "Request access", perform: {
                Permissions.requestAccessibilityPrompt()
            })
        case .openSystemSettings:
            return (title: "Open System Settings", perform: { Permissions.openSettings(for: .accessibility) })
        case nil:
            return nil
        }
    }

    private var modelRow: some View {
        let state = coordinator.modelLoadState
        let badge: StatusBadge
        let subtitle: String
        switch state {
        case .ready:
            badge = StatusBadge(kind: .ok, label: "Ready")
            subtitle = "The on-device model that generates completions."
        case .loading:
            badge = StatusBadge(kind: .attention, label: "Loading")
            subtitle = "The on-device model that generates completions."
        case .downloading(let fraction):
            badge = StatusBadge(kind: .attention, label: "Downloading \(Int((fraction * 100).rounded())) %")
            subtitle = "The first start downloads the model once."
        case .unloaded:
            badge = StatusBadge(kind: .off, label: "Unloaded")
            subtitle = "Released to save memory. It reloads in a few seconds when you type again."
        case .failed:
            badge = StatusBadge(kind: .error, label: "Failed")
            subtitle = "\(state.menuLabel). Check your connection and free disk space."
        }
        return SettingsStatusRow(
            symbol: "cpu", title: "AI model", subtitle: subtitle, badge: badge,
            action: state.isFailed ? (title: "Retry", perform: { coordinator.retryModelLoad() }) : nil)
    }

    /// macOS's own inline prediction collides visually with our ghost. One button writes the
    /// global key, only on click, and a second one undoes it. The manual steps stay as the fallback.
    private var inlinePredictionRow: some View {
        let toggle = inlinePrediction.toggle
        let badge: StatusBadge
        switch inlinePrediction.advisory {
        case .actionNeeded: badge = StatusBadge(kind: .attention, label: "Action needed")
        case .satisfied: badge = StatusBadge(kind: .ok, label: "Off")
        case .offerTurnOff, .hidden: badge = StatusBadge(kind: .off, label: "Not set")
        }
        return VStack(alignment: .leading, spacing: 8) {
            SettingsStatusRow(
                symbol: "text.insert",
                title: "Turn off macOS inline predictions",
                subtitle: "macOS shows its own predictions, also accepted with Tab, so you would see two.",
                badge: badge,
                action: (title: toggle == .turnOff ? "Turn off for me" : "Turn back on",
                         perform: { inlinePrediction.perform(toggle) }))
            Text("Apps already open may keep showing predictions until you reopen them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
            if inlinePrediction.lastClickFailed {
                Text("macOS did not accept the change. Use the steps below instead.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Or do it by hand:")
                Text("1. Open System Settings, then Keyboard.")
                Text("2. Next to \"Input Sources\" (or \"Text Input\"), click Edit.")
                Text("3. Turn off \"Show inline predictive text\".")
                Button("Open Keyboard Settings") { InlinePredictionNudge.openKeyboardSettings() }
                    .buttonStyle(.link)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
        }
    }
}
