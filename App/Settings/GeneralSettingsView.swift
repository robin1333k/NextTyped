import AppKit
import NextTypedCore
import SwiftUI

/// General pane: the everyday switches. Built from the shared style kit (`App/Settings/Kit/`).
///
/// Section plan. Only sections with a built control appear. Controls other tickets add go here:
///
///     Status        Pause, quiet, model unloaded (only while one is active)
///     Completions   Enable completions
///                   Completion length
///                   Suggest spelling fixes
///                   mid-line toggle (later)
///     Languages     English, German, All other languages
///     Battery
///     Spelling      English spelling
///     Model         Model (picker), Loaded, Status, Unload from memory, Model files
///     Menu bar      Show menu bar icon (before Startup)
///     Startup       Launch at login
///
/// The pause hotkey lives in Shortcuts with the other keyboard shortcuts.
struct GeneralSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var ticker = MinuteTicker()

    private func languageToggle(_ title: String, _ selector: LanguageSelector) -> some View {
        SettingsToggleRow(
            title: title,
            isOn: Binding(
                get: { coordinator.isLanguageOn(selector) },
                set: { coordinator.setLanguage(selector, on: $0) }))
    }

    var body: some View {
        Form {
            statusSection

            Section {
                // The loop reads `settingsStore.policy` per keystroke, so this takes effect at once.
                // Per-app exceptions live in the Apps pane.
                SettingsToggleRow(
                    title: "Enable completions",
                    subtitle: "When off, NextTyped stays in the menu bar and shows nothing.",
                    isOn: Binding(
                        get: { coordinator.isGloballyEnabled },
                        set: { coordinator.setGloballyEnabled($0) }))

                // Display only: the model already decodes an 8-word clause and this picks how
                // much of it is painted, so a change costs no inference and applies to the ghost on screen.
                Picker("Completion length", selection: Binding(
                    get: { coordinator.completionLength },
                    set: { coordinator.setCompletionLength($0) })) {
                        Text("Short (about 3 words)").tag(CompletionLength.short)
                        Text("Medium (about 5 words)").tag(CompletionLength.medium)
                        Text("Long (about 8 words)").tag(CompletionLength.long)
                        Text("Current word only").tag(CompletionLength.word)
                    }

                // The gate wraps the whole spell checker and is read per predict, so a flip
                // applies to the next keystroke. Continuation ghosts are not affected.
                SettingsToggleRow(
                    title: "Suggest spelling fixes",
                    subtitle: "Shows a likely correction for the word you are typing. Tab applies it.",
                    isOn: Binding(
                        get: { coordinator.isSpellingFixesEnabled },
                        set: { coordinator.setSpellingFixesEnabled($0) }))
            } header: {
                Text("Completions")
            } footer: {
                Text("A completion is at most this long, and shorter when the model offers less. "
                     + "Tab accepts one word at a time. "
                     + "Current word only finishes the word you are typing and never suggests the next one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                // Read per predict, so a flip applies to the next keystroke. Stored as the
                // list of switched-off languages under `disabledLanguages`.
                languageToggle("English", .tag("en"))
                languageToggle("German", .tag("de"))
                languageToggle("All other languages", .allOthers)
            } header: {
                Text("Languages")
            } footer: {
                Text("Short or mixed text always gets suggestions, because the language cannot be told reliably.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                // Post-decode word map: the model writes American-leaning English and the
                // map rewrites whole words in the suggestion. English only: suggestions in any
                // other detected language pass through unchanged. Never touches what you typed.
                Picker("English spelling", selection: Binding(
                    get: { coordinator.spellingVariant },
                    set: { coordinator.setSpellingVariant($0) })) {
                        Text("As written by the model").tag(SpellingVariant.off)
                        Text("British (colour, organise)").tag(SpellingVariant.british)
                        Text("Canadian (colour, organize)").tag(SpellingVariant.canadian)
                    }
            } header: {
                Text("Spelling")
            } footer: {
                Text("Rewrites whole words in English completions only. German completions and the text you typed are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Suggest only when I ask while on battery", isOn: Binding(
                    get: { coordinator.batterySuggestOnlyOnDemand },
                    set: { coordinator.setBatterySuggestOnlyOnDemand($0) }))
                    .disabled(coordinator.forceActivateShortcutDescription == nil)
                Toggle("Shorter suggestions on battery", isOn: Binding(
                    get: { coordinator.batteryShorterCompletions },
                    set: { coordinator.setBatteryShorterCompletions($0) }))
            } header: {
                Text("Battery")
            } footer: {
                Text((coordinator.forceActivateShortcutDescription == nil
                      ? "Assign the \"Suggest something here\" shortcut in Settings → Shortcuts first. "
                      : "On battery, a suggestion appears only when you press the shortcut. "
                        + "Spelling fixes keep working. ")
                     + "Shorter suggestions stop after 5 words on battery instead of 8.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Model", selection: Binding(
                    get: { coordinator.modelChoice },
                    set: { coordinator.setModelChoice($0) })) {
                        ForEach(ModelChoice.allCases, id: \.self) { Text($0.pickerLabel).tag($0) }
                    }
                SettingsValueRow(title: "Loaded", value: MLXPredictionEngine.displayName)
                LabeledContent("Status") { modelBadge }
                Picker("Unload from memory", selection: Binding(
                    get: { coordinator.modelUnloadSetting },
                    set: { coordinator.setModelUnloadSetting($0) })) {
                        ForEach(ModelUnloadSetting.pickerCases(
                            allowDebugValues: AppSettingsStore.allowsDebugUnloadValues), id: \.self) {
                            Text(Self.label(for: $0)).tag($0)
                        }
                    }
                modelFilesRow
            } header: {
                Text("Model")
            } footer: {
                Text(unloadFooter).font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show menu bar icon", isOn: Binding(
                    get: { coordinator.showMenuBarIcon },
                    set: { coordinator.setShowMenuBarIcon($0) }))
            } header: {
                Text("Menu bar")
            } footer: {
                Text("To get it back, open NextTyped again from Applications.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                SettingsToggleRow(
                    title: "Launch at login",
                    isOn: Binding(
                        get: { coordinator.launchAtLogin },
                        set: { coordinator.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .onAppear { ticker.start() }
        .onDisappear { ticker.stop() }
    }

    /// Pause, temporary quiet and the model's memory state, only while one of them is active. The lines
    /// come from `SettingsStatusSummary`; Resume calls the same coordinator paths as the menu.
    @ViewBuilder private var statusSection: some View {
        let lines = coordinator.settingsStatusLines(now: ticker.now)
        if !lines.isEmpty {
            Section {
                ForEach(lines, id: \.text) { line in
                    SettingsStatusRow(
                        symbol: line.action == nil ? "memorychip" : "pause.circle",
                        title: line.text,
                        badge: StatusBadge(kind: line.kind == .attention ? .attention : .off,
                                           label: line.action == .resumeAll ? "Paused" : (line.kind == .attention ? "Quiet" : "Unloaded")),
                        action: line.action.map { action in
                            (title: "Resume", perform: { coordinator.perform(action) })
                        })
                }
            } header: {
                Text("Status")
            }
        }
    }

    private static func label(for setting: ModelUnloadSetting) -> String {
        switch setting {
        case .automatic: "Automatically"
        case .min2: "After 2 minutes idle"
        case .min5: "After 5 minutes idle"
        case .min15: "After 15 minutes idle"
        case .hour1: "After 1 hour idle"
        case .never: "Never"
        case .sec15: "After 15 seconds idle (debug)"
        }
    }

    /// The figures follow the model that loaded (`ShippingModel.memoryFigures`).
    private var unloadFooter: String {
        let figures = ShippingModel.memoryFigures(
            localDirectory: MLXPredictionEngine.localModelDirectoryForThisLaunch(),
            choice: coordinator.modelChoice)
        return ModelChoice.recommendationLine(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
            + " Automatic loads the 4B from ~/Models, then the 2B from ~/Models, and otherwise downloads the 4B. "
            + "Picking a model loads it at once and downloads it when its folder is missing. "
            + "Idle means you have not typed in a field NextTyped completes. "
            + "While loaded, the model uses about \(figures.loaded); unloaded, the app uses about "
            + "\(figures.unloaded), and the model reloads in a few seconds when you type again. "
            + "Automatically unloads 2.5 minutes after you leave the app you were writing in, and when the "
            + "screen locks or the Mac sleeps. Low system memory always unloads it."
    }

    /// The Setup requirement row shows the same state with a Retry button; here it is a badge only.
    private var modelBadge: StatusBadge {
        switch coordinator.modelLoadState {
        case .ready: StatusBadge(kind: .ok, label: "Ready")
        case .loading: StatusBadge(kind: .attention, label: "Loading")
        case .downloading(let fraction):
            StatusBadge(kind: .attention, label: "Downloading \(Int((fraction * 100).rounded()))%")
        case .failed: StatusBadge(kind: .error, label: "Failed")
        case .unloaded: StatusBadge(kind: .off, label: "Unloaded")
        }
    }

    private var modelFilesRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model files")
                if coordinator.modelFolder == nil {
                    Text("Available after the model has loaded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Show in Finder") {
                if let folder = coordinator.modelFolder { reveal(folder) }
            }
            .disabled(coordinator.modelFolder == nil)
        }
    }

    /// Selects the folder in its parent, so Finder shows the directory that holds `config.json`.
    private func reveal(_ folder: URL) {
        #if DEBUG
        acLog("[settings]: model folder %@", folder.path)
        #endif
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
