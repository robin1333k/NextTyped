import AppKit
import NextTypedCore
import SwiftUI

/// The paged onboarding window: Try Tab, Permission, Model, Practice, with page dots and Back.
/// Which page shows is the pure-Core `OnboardingFlow`; this view feeds it buttons and the Accessibility
/// state, which it polls once a second while the Permission page shows.
struct OnboardingView: View {
    @StateObject private var permissions = PermissionsModel()
    @ObservedObject var coordinator: AppCoordinator
    @State private var flow: OnboardingFlow

    init(coordinator: AppCoordinator, startPage: OnboardingPage = .tryTab) {
        self.coordinator = coordinator
        _flow = State(initialValue: OnboardingFlow(accessibilityGranted: Permissions.hasAccessibility,
                                                   page: startPage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch flow.page {
                case .tryTab: TryTabPage()
                case .permission: PermissionPage(granted: permissions.hasAccessibility)
                case .model: ModelPage(coordinator: coordinator)
                case .practice: PracticePage(coordinator: coordinator, permissions: permissions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(24)
        .frame(width: 480, height: 440)
        .onAppear {
            permissions.refresh()
            flow.apply(.accessibilityChanged(permissions.hasAccessibility))
        }
        .onChange(of: permissions.hasAccessibility) { _, granted in
            let before = flow.page
            flow.apply(.accessibilityChanged(granted))
            if before != flow.page { logPage(reason: "accessibility-granted") }
        }
        // Returning from System Settings does not always activate us, so poll while the page shows.
        .task(id: flow.page) {
            guard flow.page == .permission else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                permissions.refresh()
            }
        }
    }

    private var footer: some View {
        HStack {
            if flow.canGoBack {
                Button("Back") { go(.back) }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(OnboardingPage.allCases, id: \.self) { page in
                    Circle()
                        .fill(page == flow.page ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(flow.page.rawValue + 1) of \(OnboardingPage.allCases.count)")
            Spacer()
            if flow.page == .practice {
                Button("Close") { NSApp.keyWindow?.close() }
            } else {
                Button("Next") { go(.next) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!flow.canGoNext)
            }
        }
    }

    private func go(_ event: OnboardingFlow.Event) {
        flow.apply(event)
        logPage(reason: event == .back ? "back" : "next")
    }

    private func logPage(reason: String) {
        #if DEBUG
        acLog("[onboarding]: page=%@ reason=%@", String(describing: flow.page), reason)
        #endif
    }
}

// MARK: - Try Tab

/// A canned completion drawn in our own window. No model runs and no permission is needed: a
/// local key monitor maps the pressed chord through the user's bindings and steps the Core `TabDemo`.
/// The demo is plain text, not an editable field, so the loop never reads or harvests it.
struct TryTabPage: View {
    @State private var demo = TabDemo()
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("See how it works").font(.title2.bold())
            Text("NextTyped shows the rest of your sentence in gray, right where you type. "
                 + "Press \(keys.word) to take one word or \(keys.all) to take the rest.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            (Text(demo.typed) + Text(demo.ghost).foregroundColor(.secondary))
                .font(.system(size: 15))
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                // One static-text element whose label is the accepted text only, so VoiceOver and the
                // harness read how far the demo has advanced. A bare `.accessibilityElement()` came out
                // as `AXUnknown` with no `AXValue` (VM run 2026-11-04T17-45-56Z); a static-text element
                // publishes its label as `AXValue`, like the page's other `Text` rows.
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityLabel(demo.typed)
                .accessibilityIdentifier("onboarding-tab-demo")
            if demo.isDone {
                HStack {
                    Label("That is all there is to it.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Try again") { demo.restart() }
                }
            } else {
                Text("This is a demo with a fixed sentence. Next, NextTyped asks for the permission "
                     + "it needs in your other apps.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
    }

    private var keys: (word: String, all: String) {
        let bindings = AppSettingsStore().interceptBindings
        return (bindings[.acceptWord].label, bindings[.acceptAll].label)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        let bindings = AppSettingsStore().interceptBindings
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let chord = KeyChord(keyCode: Int(event.keyCode), modifiers: KeyModifiers(event.modifierFlags))
            let action = bindings.action(for: chord)
            guard let action, action == .acceptWord || action == .acceptAll else { return event }
            let finished = MainActor.assumeIsolated { () -> Bool in
                guard !demo.isDone else { return true }
                demo.apply(action)
                #if DEBUG
                acLog("[onboarding]: tab-demo action=%@ done=%d", action == .acceptWord ? "acceptWord" : "acceptAll",
                      demo.isDone ? 1 : 0)
                #endif
                return false
            }
            // Once the demo is done, Tab moves the focus again as usual.
            return finished ? event : nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - Permission

/// The one permission, with our own drawing of the switch to turn on. The view advances by itself
/// through `OnboardingFlow` when `PermissionsModel` sees the grant.
struct PermissionPage: View {
    let granted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Allow \(Permissions.accessibilityListTitle)").font(.title2.bold())
            Text("To read the text around your cursor and accept completions with Tab in other apps, "
                 + "NextTyped needs the \(Permissions.accessibilityListTitle) permission. Nothing you "
                 + "type ever leaves your Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PermissionSwitchDrawing(listTitle: Permissions.accessibilityListTitle, on: granted)
            PermissionRow(title: Permissions.accessibilityListTitle,
                          subtitle: granted
                            ? "Granted. Continuing to the model."
                            : "Press Request, then turn on NextTyped in System Settings. This page moves on by itself.",
                          granted: granted)
        }
    }
}

/// A plain drawing of the System Settings row: our app's name beside a switch. Off, the knob slides on
/// and back to show the move; once granted it stays on. Drawn with shapes, no screenshot or asset.
struct PermissionSwitchDrawing: View {
    let listTitle: String
    let on: Bool
    @State private var demoOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Privacy & Security  ›  \(listTitle)")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.6)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 22, height: 22)
                    .overlay(Text("A").font(.system(size: 13, weight: .bold)).foregroundStyle(.white))
                Text("NextTyped").font(.body)
                Spacer()
                switchShape(isOn: on || demoOn)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        }
        .accessibilityElement()
        .accessibilityLabel("Drawing: the NextTyped switch in \(listTitle), turned \(on ? "on" : "off")")
        .task(id: on) {
            guard !on else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeInOut(duration: 0.35)) { demoOn.toggle() }
            }
        }
    }

    private func switchShape(isOn: Bool) -> some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: 38, height: 22)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).shadow(radius: 0.5).padding(2)
            }
    }
}

// MARK: - Model

/// Size and source of the model, download progress in MB, the free-disk refusal and the licence line
/// . The download itself is the engine's launch preload; this page only shows it.
struct ModelPage: View {
    @ObservedObject var coordinator: AppCoordinator

#if DEBUG
    /// Snapshot fixtures draw the download path even on a Mac that holds a local model folder.
    static var debugForceHubSource = false
#endif

    private let plan = MLXPredictionEngine.currentPlan()
    private let localFolder: String? = {
#if DEBUG
        if ModelPage.debugForceHubSource { return nil }
#endif
        return MLXPredictionEngine.existingLocalModelDirectory()
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The on-device model").font(.title2.bold())
            Text(source).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            status
            Spacer()
            Text("Model weights: Qwen3.5 Base by the Qwen team, Apache-2.0 licence. Full texts are in "
                 + "Settings, About.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)
        }
    }

    private var totalBytes: Int64? { ShippingModel.downloadBytes(repoId: plan.hubRepoId) }

    private var source: String {
        if let localFolder {
            return "Found on this Mac in \(localFolder). Nothing to download."
        }
        let size = totalBytes.map(ModelDownloadProgressLine.sizeLabel(totalBytes:)) ?? "a few GB"
        return "NextTyped downloads the model \(plan.hubRepoId) "
            + "(\(size)) from Hugging Face once. After that it runs on your Mac, with no network."
    }

    @ViewBuilder private var status: some View {
        switch coordinator.modelLoadState {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: min(max(fraction, 0), 1))
                if let totalBytes {
                    Text(ModelDownloadProgressLine.line(fraction: fraction, totalBytes: totalBytes))
                        .font(.subheadline).monospacedDigit()
                }
                Text("You can press Next and keep going while it downloads.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(coordinator.modelLoadState.menuLabel).font(.subheadline)
            }
        case .ready, .unloaded:
            Label("Model ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Text(coordinator.modelDiskShortfall?.message
                     ?? "The model could not load. Check your connection and free disk space, then press Retry.")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { coordinator.retryModelLoad() }
            }
        }
    }
}

// MARK: - Practice

/// The real loop in a practice field (`TabPracticeStepView`), last. It needs the permission and a
/// model that can predict, or no ghost can appear.
struct PracticePage: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it for real").font(.title2.bold())
            if permissions.isReady, coordinator.modelLoadState.canPredict {
                TabPracticeStepView(practice: coordinator.tabPractice)
            } else if permissions.isReady, coordinator.modelLoadState == .failed {
                HStack {
                    Text(coordinator.modelLoadState.menuLabel).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Button("Skip") {
                        TabPracticeModel.markFinished()
                        NSApp.keyWindow?.close()
                    }
                }
            } else if permissions.isReady {
                Text("The practice field opens once the model is ready. \(coordinator.modelLoadState.menuLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("The practice field needs \(Permissions.accessibilityListTitle) access. Go Back to grant it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if permissions.isReady {
                Label("All set. Start typing in any app.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
