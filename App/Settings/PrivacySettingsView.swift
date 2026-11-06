import AppKit
import NextTypedCore
import SwiftUI

/// Privacy pane: the canonical disclosure home for the context sources and the enable
/// surface for screen-context OCR.
///
/// Two principles shape this screen:
///   - Off by default, granted explicitly. The OCR toggle ships off. Turning it on shows a
///     pre-permission explainer first (what is captured, what is excluded, what is never stored), and
///     only then triggers the OS dialog. A denial reverts the switch, so the UI never claims a
///     capability the OS did not grant.
///   - Disclose the residuals, do not bury them. The scrub chain has real, documented holes (background
///     secure rects, browser-rendered credentials). They sit in a visible "Not guaranteed" fact, never
///     in a collapsed group.
struct PrivacySettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var showingExplainer = false
    @ObservedObject private var updater = UpdateController.shared
    @State private var showingLearned = false
    @State private var confirmingRepairReset = false
    /// Whether the learned profile holds nothing. Starts true so the delete row is never enabled for a
    /// profile that has not been read yet; `refreshProfileState()` corrects it.
    @State private var profileIsEmpty = true
    /// macOS blocks pasteboard reading ("Paste from Other Apps"). Re-read when the pane appears and when
    /// the app becomes active again, which is where the user returns from System Settings.
    @State private var clipboardOSDenied = false

    var body: some View {
        Form {
            Section {
                SettingsStatusRow(
                    symbol: "lock.shield", title: "Everything runs on this Mac",
                    subtitle: "What you type, the apps you use and your screen stay on this Mac. There is no telemetry; "
                        + "the update check below is the only network use.",
                    badge: StatusBadge(kind: .ok, label: "No telemetry"))
            }

            cursorSection
            windowSection
            replySection
            clipboardSection
            screenTextSection
            writingStyleSection
            updateCheckSection
            deleteSection
        }
        .formStyle(.grouped)
        .task { await refreshProfileState() }
        .onAppear {
            updater.refreshAutomaticChecks()
            clipboardOSDenied = PasteboardReader.accessIsDenied(NSPasteboard.general)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            clipboardOSDenied = PasteboardReader.accessIsDenied(NSPasteboard.general)
        }
        .sheet(isPresented: $showingExplainer) {
            ScreenRecordingExplainer(
                onContinue: {
                    showingExplainer = false
                    coordinator.setScreenOCREnabled(true)
                },
                onCancel: { showingExplainer = false })
        }
        .sheet(isPresented: $showingLearned, onDismiss: { Task { await refreshProfileState() } }) {
            LearnedProfileView(onClose: { showingLearned = false })
                .environmentObject(coordinator)
        }
        .confirmationDialog(Self.resetTitle, isPresented: $confirmingRepairReset, titleVisibility: .visible) {
            Button("Delete and start over", role: .destructive) { resetProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.resetMessage)
        }
    }

    // MARK: One card per source
    //
    // Each source is its own section: the header names the source, the first row is its switch (or its
    // fixed state), and the disclosure facts sit in a "What this reads and keeps" group under it. The
    // facts stay word for word. A non-guarantee is never inside a group.

    private static let keptTransient = "Used for the current completion, then discarded. Never saved, "
        + "never learned from."

    private var cursorSection: some View {
        Section {
            SettingsStatusRow(
                symbol: "text.cursor", title: "Cannot be turned off",
                subtitle: "Completions cannot work without the text you are typing.",
                badge: StatusBadge(kind: .ok, label: "Always on"))
            factsGroup([
                ("Reads", "The text of the field you are typing in, through Accessibility, only while "
                          + "you type. Password and secure fields are never read."),
                ("Kept", Self.keptTransient),
            ])
        } header: {
            Text("Text around your cursor")
        }
    }

    private var windowSection: some View {
        Section {
            SettingsToggleRow(
                title: "Use window text",
                subtitle: "Other text in this window, such as earlier parts of a long document.",
                isOn: Binding(
                    get: { coordinator.isWindowContextEnabled },
                    set: { coordinator.setWindowContextEnabled($0) }))
            factsGroup([
                ("Reads", "Other text in the same window, such as the earlier part of a long document, "
                          + "through Accessibility, only while you type."),
                ("Kept", Self.keptTransient),
            ])
        } header: {
            Text("Visible text in the current window")
        }
    }

    private var replySection: some View {
        Section {
            SettingsToggleRow(
                title: "Use reply context",
                subtitle: "On chat surfaces, the other person's last message. Your own messages are never used.",
                isOn: Binding(
                    get: { coordinator.isReplyContextEnabled },
                    set: { coordinator.setReplyContextEnabled($0) }))
            factsGroup([
                ("Reads", "On chat surfaces, the other person's last message, through Accessibility, "
                          + "only while you type. Your own messages are never fed back."),
                ("Kept", Self.keptTransient),
            ])
        } header: {
            Text("The message you are replying to")
        }
        // An appearance probe source section can go after the clipboard one.
    }

    private var clipboardState: ClipboardRowState {
        ClipboardRowState.resolve(enabled: coordinator.isClipboardContextEnabled, osDenied: clipboardOSDenied)
    }

    private var clipboardSection: some View {
        Section {
            HStack(alignment: .top) {
                SettingsToggleRow(
                    title: "Use what I copied as context",
                    subtitle: "Off by default. Text you copied a moment ago can help the next words fit.",
                    isOn: Binding(
                        get: { coordinator.isClipboardContextEnabled },
                        set: { coordinator.setClipboardContextEnabled($0) }))
                switch clipboardState {
                case .off: StatusBadge(kind: .off, label: "Off")
                case .on: StatusBadge(kind: .ok, label: "On")
                case .blockedByOS: StatusBadge(kind: .attention, label: "Blocked by macOS")
                }
            }
            if clipboardState == .blockedByOS {
                SettingsNotice(
                    kind: .attention, title: "macOS blocks clipboard reading for NextTyped",
                    message: "The switch is on, but nothing is read. Allow NextTyped under Paste from Other "
                             + "Apps in System Settings, in the Privacy & Security section.") {
                    Button("Open Settings") { Permissions.openSettings(for: .pasteboard) }
                }
            }
            factsGroup(ClipboardRowState.disclosure)
        } header: {
            Text("What you copied")
        }
    }

    private var screenTextSection: some View {
        Section {
            HStack(alignment: .top) {
                SettingsToggleRow(
                    title: "Read on-screen text",
                    subtitle: "Off by default. macOS asks for Screen Recording permission when you turn it on.",
                    isOn: Binding(
                        get: { coordinator.isScreenOCREnabled },
                        set: { wantsOn in
                            // The explainer comes before the OS dialog: the user should know what they are
                            // granting while they still have a choice about it.
                            if wantsOn { showingExplainer = true } else { coordinator.setScreenOCREnabled(false) }
                        }))
                if coordinator.screenOCRNeedsPermission { screenTextBadge }
            }

            if coordinator.screenOCRNeedsPermission {
                // macOS reports a first grant only after a relaunch, so "granted but still off" is a real,
                // expected state. The notice says so instead of looking broken.
                SettingsNotice(
                    kind: .attention, title: "Waiting for Screen Recording permission",
                    message: "The switch shows off because nothing is read yet. Allow NextTyped under Screen "
                             + "Recording in System Settings, then quit and reopen it.") {
                    Button("Open Settings") { Permissions.openSettings(for: .screenRecording) }
                    Button("Turn off") { coordinator.setScreenOCREnabled(false) }
                }
            }

            // The residual stays visible, outside the group.
            SettingsFacts(rows: [
                ("Not guaranteed", "Passwords or codes rendered inside a browser tab, or in a background "
                                   + "window, may not be detectable."),
            ])

            factsGroup([
                ("Reads", "Text you can see on screen, such as a reference document in another window or "
                          + "an app that does not expose its text to Accessibility, like Mail's message "
                          + "body. Needs the Screen Recording permission."),
                ("Never captured", "Password managers and banking apps. Capture stops while a password "
                                   + "field is focused and while the screen is locked or asleep. Card "
                                   + "numbers, IBANs, one-time codes, passwords typed after \"password:\" or "
                                   + "\"token=\", private keys, API keys from well-known services, login "
                                   + "tokens (JWTs) and passwords inside links are removed from recognised text. "
                                   + "Any app switched off in the Apps pane is excluded entirely. The \"Only apps I turn "
                                   + "on\" mode does not apply here: apps you did not switch on are still read."),
                ("Kept", "Recognised on this Mac and used for the current completion only. Never saved to "
                         + "disk, never leaves your Mac."),
            ])
        } header: {
            Text("Screen text (OCR)")
        }
    }

    private var screenTextBadge: StatusBadge {
        if coordinator.screenOCRNeedsPermission { return StatusBadge(kind: .attention, label: "Waiting for permission") }
        if coordinator.isScreenOCREnabled { return StatusBadge(kind: .ok, label: "On") }
        return StatusBadge(kind: .off, label: "Off")
    }

    // MARK: Update check

    /// The update check is the one network use the app has. It reads
    /// nothing from the Mac, so it sits beside the context sources as a disclosure, not a switch.
    private var updateCheckSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                SettingsStatusRow(
                    symbol: "arrow.triangle.2.circlepath", title: "Update check",
                    badge: updater.automaticChecks
                        ? StatusBadge(kind: .ok, label: "Automatic")
                        : StatusBadge(kind: .off, label: "Manual only"))
                SettingsFacts(rows: Self.updateCheckFacts)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Updates")
        }
    }

    static let updateCheckFacts: [(label: String, text: String)] = [
        ("Reads", "Nothing on this Mac. Not your text, your apps or your files."),
        ("Sends", "One request for the update list. The server sees your IP address and the app version, "
                  + "nothing else. It happens once a day while automatic checks are on, and each time you "
                  + "choose Check for Updates. Switch it in Settings → About."),
    ]

    // MARK: Writing style

    private var writingStyleSection: some View {
        Section {
            HStack(alignment: .top) {
                SettingsToggleRow(
                    title: "Learn my writing style",
                    subtitle: "Off by default.",
                    isOn: Binding(
                        get: { coordinator.isPersonalizationEnabled },
                        set: { coordinator.setPersonalizationEnabled($0) }))
                if coordinator.isPersonalizationEnabled {
                    StatusBadge(kind: .attention, label: "Experimental")
                }
            }

            if coordinator.learnedProfileIsUnreadable {
                ProfileNotSavingNotice(title: "Nothing is being saved") {
                    Button("Delete and start over", role: .destructive) { confirmingRepairReset = true }
                }
            }

            LabeledContent("What was learned") {
                Button("Show what was learned…") { showingLearned = true }
            }

            factsGroup([
                ("Learns", "Only text you typed or accepted in this app's completions. Pasted text, "
                           + "quoted replies and anything already in a document are never learned, "
                           + "because they never pass through the keyboard. Password and secure fields "
                           + "are excluded. You can turn learning off per app in the Apps pane."),
                ("Stored", "Encrypted on this Mac, in your own Application Support folder. Never sent "
                           + "anywhere, never used to train a model. It is only quoted back to the "
                           + "local model as context. Deleting it removes the file and its key."),
            ])

            DisclosureGroup("How this works") {
                // The honest reason this ships off: the privacy question is settled, the quality
                // question is not measured yet.
                Text("NextTyped can learn how you write, from a few of your own sentences and the "
                     + "words you use often, and use them as context so completions sound like you. It "
                     + "ships off because it is still being measured. Until it demonstrably improves "
                     + "completions, it is not worth the context it takes up.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Writing style")
        }
        .onChange(of: coordinator.isPersonalizationEnabled) { _, _ in
            Task { await refreshProfileState() }
        }
    }

    /// The destructive action sits in a section of its own, apart from the switches above it.
    private var deleteSection: some View {
        Section {
            SettingsDestructiveRow(
                title: "Delete learned profile",
                // An unreadable profile counts as present: deleting it is the repair.
                isEnabled: !profileIsEmpty || coordinator.learnedProfileIsUnreadable,
                confirmTitle: Self.resetTitle,
                confirmMessage: Self.resetMessage,
                action: resetProfile)
        } header: {
            Text("Delete")
        } footer: {
            Text("Removes the encrypted writing-style profile and its key.")
        }
    }

    private func factsGroup(_ rows: [(label: String, text: String)]) -> some View {
        DisclosureGroup("What this reads and keeps") {
            SettingsFacts(rows: rows)
                .padding(.top, 4)
        }
    }

    private static let resetTitle = "Delete everything NextTyped has learned about your writing?"
    private static let resetMessage = "The encrypted profile and its key are removed. NextTyped starts "
        + "learning again from scratch if the setting stays on."

    private func resetProfile() {
        Task {
            await coordinator.resetLearnedProfile()
            await refreshProfileState()
        }
    }

    private func refreshProfileState() async {
        profileIsEmpty = await coordinator.learnedProfile().isEmpty
    }
}

/// The pre-permission explainer. macOS gives one blunt Screen Recording prompt
/// with no room to explain; this sheet is where the user finds out what is captured and what protects
/// them, *before* that dialog appears — and where "No thanks" costs nothing.
struct ScreenRecordingExplainer: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.largeTitle).foregroundStyle(.tint)
                Text("Use on-screen text as context").font(.title3.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet("macOS will ask for Screen Recording permission. NextTyped uses it to read "
                       + "text that's already visible on your screen.")
                bullet("Text is recognised on your Mac, used for the current completion, and discarded. "
                       + "It is never saved to disk, never learned from, and never sent anywhere.")
                bullet("Password managers and banking apps are never captured. Capture stops while a "
                       + "password field is focused, and while the screen is locked or asleep.")
                bullet("Card numbers, IBANs, one-time codes, password and token values after a label like "
                       + "\"password:\", private keys, API keys from well-known services, login tokens "
                       + "(JWTs) and passwords inside links are stripped from recognised text.")
                bullet("You can turn this off at any time, and exclude individual apps in the Apps pane.")
            }

            HStack {
                Spacer()
                Button("Not now", action: onCancel)
                Button("Continue", action: onContinue).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The one place the RAM-only stall is worded, shown by both the Privacy pane and
/// the transparency view.
///
/// It exists as one type because the sentence is a promise ("we are not saving this"), and two
/// hand-written copies of a promise drift apart. It states a consequence, never a cause: from inside the
/// app the cause is unknowable (a keychain still locked at login, a restored backup, a re-signed binary)
/// and the repair is the same either way.
struct ProfileNotSavingNotice<Action: View>: View {
    /// The lead line, which differs by surface: a settings row states the condition, the transparency
    /// view has to say it about the list right underneath it.
    let title: String
    @ViewBuilder let action: Action

    var body: some View {
        SettingsNotice(
            kind: .attention, title: title,
            message: "The profile stored on this Mac can't be read, so NextTyped is keeping what it "
                + "learns in memory only. It will be gone when you quit. Deleting the profile starts a "
                + "fresh one that saves normally.") { action }
    }
}

extension ProfileNotSavingNotice where Action == EmptyView {
    init(title: String) {
        self.init(title: title, action: { EmptyView() })
    }
}
