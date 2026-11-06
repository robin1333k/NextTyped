import AppKit
import NextTypedCore
import SwiftUI

/// Apps pane: per-app on/off overrides. NextTyped is on by default with a shipped
/// blocklist (terminals, password managers, code editors, some chat apps); the user can force any app on or off, and an
/// override always beats the blocklist.
///
/// The list is running regular apps, apps with an override, installed apps from the default blocklist
/// and apps added with "Add app..." since launch (`AppListing`, Core). It rebuilds on appear and when an
/// app launches or quits.
struct AppsSettingsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var entries: [AppEntry] = []
    @State private var query: String = ""
    @StateObject private var ticker = MinuteTicker()

    private var filtered: [AppEntry] {
        let ids = Set(AppListing.filter(entries.map(\.asListing), query: query).map(\.bundleID))
        return entries.filter { ids.contains($0.bundleID) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Complete in", selection: Binding(
                    get: { coordinator.appDefaultMode },
                    set: { coordinator.setAppDefaultMode($0) })) {
                        Text(DefaultMode.everywhere.pickerLabel).tag(DefaultMode.everywhere)
                        Text(DefaultMode.onlySwitchedOn.pickerLabel).tag(DefaultMode.onlySwitchedOn)
                    }
            } footer: {
                Text(coordinator.appDefaultMode.pickerFooter)
            }
            WebsitesSection()
            // Slot: a Terminals section can go after Websites.
            Section {
                TextField("Search apps", text: $query, prompt: Text("Search apps"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                ForEach(filtered) { entry in
                    AppRow(entry: entry,
                           choice: choiceBinding(for: entry.bundleID),
                           learning: learningBinding(for: entry.bundleID),
                           showsLearning: coordinator.isPersonalizationEnabled,
                           quietCaption: coordinator.quiet(forBundleID: entry.bundleID).map {
                               SettingsStatusSummary.rowCaption(for: $0, now: ticker.now)
                           },
                           mode: coordinator.appDefaultMode,
                           limit: AppCoverageLimits.limit(forBundleID: entry.bundleID))
                }
                if filtered.isEmpty {
                    Text(query.isEmpty ? "No apps found." : AppListing.noMatchText(query: query))
                        .foregroundStyle(.secondary)
                }
                Button("Add app\u{2026}", action: addApp)
            } header: {
                Text("Apps")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Terminals, password managers, code editors and some chat apps start off. Choose On to override.")
                    if coordinator.isPersonalizationEnabled {
                        // The learning-source denylist is deliberately separate from the on/off override:
                        // "don't complete in Terminal" and "don't learn my style from this app" are
                        // different questions.
                        Text("Learn feeds your style profile. Off keeps completions on.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { rebuild(); ticker.start() }
        .onDisappear { ticker.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in rebuild() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in rebuild() }
    }

    private func choiceBinding(for bundleID: String) -> Binding<OverrideChoice> {
        Binding(
            get: { OverrideChoice(coordinator.appOverride(forBundleID: bundleID)) },
            set: { coordinator.setAppOverride($0.overrideValue, forBundleID: bundleID) })
    }

    /// Two-way binding for the row's learning switch (learning-source denylist).
    private func learningBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { coordinator.isLearningEnabled(forBundleID: bundleID) },
            set: { coordinator.setLearningEnabled($0, forBundleID: bundleID) })
    }

    /// Opens a panel on the application folders. Choosing an app lists it with Default and writes nothing.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "Choose an app to list."
        guard panel.runModal() == .OK, let url = panel.url,
              let id = Bundle(url: url)?.bundleIdentifier else { return }
        coordinator.addedAppSources.append(AppListing.Source(bundleID: id, name: Self.displayName(of: url)))
        rebuild()
    }

    private func rebuild() {
        var icons: [String: NSImage] = [:]
        var running: [AppListing.Source] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier else { continue }
            running.append(AppListing.Source(bundleID: id, name: app.localizedName ?? id))
            if let icon = app.icon { icons[id] = icon }
        }
        let overridden = coordinator.perAppOverrides.keys.map { resolve($0, icons: &icons) }
        let installedBlocklisted = AppEnablementPolicy.defaultBlocklist.compactMap { id -> AppListing.Source? in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { return nil }
            return resolve(id, icons: &icons)
        }
        for source in coordinator.addedAppSources where icons[source.bundleID] == nil {
            _ = resolve(source.bundleID, icons: &icons)
        }
        entries = AppListing.entries(running: running, overridden: overridden,
                                     installedBlocklisted: installedBlocklisted, added: coordinator.addedAppSources)
            .map { AppEntry(listing: $0, icon: icons[$0.bundleID]) }
    }

    /// Name and icon for a bundle ID, best effort. Falls back to the bundle ID.
    private func resolve(_ id: String, icons: inout [String: NSImage]) -> AppListing.Source {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return AppListing.Source(bundleID: id, name: id)
        }
        icons[id] = NSWorkspace.shared.icon(forFile: url.path)
        return AppListing.Source(bundleID: id, name: Self.displayName(of: url))
    }

    private static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// A single app row: icon, name, effective-state caption, a trailing Learn checkbox and the override menu.
private struct AppRow: View {
    let entry: AppEntry
    @Binding var choice: OverrideChoice
    @Binding var learning: Bool
    /// The learning switch only appears while the style profile is on. An inert control for a disabled
    /// feature is the "dead panel" this Settings UI avoids.
    let showsLearning: Bool
    /// "Paused for 12 more minutes" while the app is quiet (from `SettingsStatusSummary`), else `nil`.
    var quietCaption: String?
    /// The default mode from the picker at the top of the pane; it decides what "no choice" means.
    let mode: DefaultMode
    /// Why the app cannot fully work, from the table Setup's "Where it works" list also reads.
    var limit: CoverageLimit?

    var body: some View {
        HStack(spacing: 10) {
            appIcon
                .resizable().frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                Text(quietCaption ?? AppListing.caption(override: choice.overrideValue, blocklisted: entry.blocklisted, mode: mode))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let limit {
                    Text(limit.statement)
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if showsLearning {
                Toggle("Learn", isOn: $learning)
                    .toggleStyle(.checkbox)
                    .help("Add what you type in \(entry.name) to your writing style profile")
            }
            Picker("Completions in \(entry.name)", selection: $choice) {
                Text(AppListing.defaultLabel(blocklisted: entry.blocklisted, mode: mode)).tag(OverrideChoice.default)
                Text("On").tag(OverrideChoice.on)
                Text("Off").tag(OverrideChoice.off)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var appIcon: Image {
        if let icon = entry.icon { Image(nsImage: icon) } else { Image(systemName: "app.dashed") }
    }
}

/// A displayable app + its default-blocklist status.
struct AppEntry: Identifiable {
    let listing: AppListing.Entry
    let icon: NSImage?
    var bundleID: String { listing.bundleID }
    var name: String { listing.name }
    var blocklisted: Bool { listing.blocklisted }
    var id: String { listing.bundleID }
}

extension AppEntry {
    var asListing: AppListing.Entry { listing }
}

/// The tri-state a row can be in, mapped to the store's `Bool?` override.
enum OverrideChoice: String, CaseIterable, Identifiable {
    case `default`, on, off
    var id: String { rawValue }

    init(_ override: Bool?) {
        switch override {
        case .none:        self = .default
        case .some(true):  self = .on
        case .some(false): self = .off
        }
    }

    var overrideValue: Bool? {
        switch self {
        case .default: nil
        case .on:      true
        case .off:     false
        }
    }
}

/// Websites section: site rules with a switch each, plus an add field. Parsing is `SiteRuleList`
/// (Core, `SiteRule.init?`); this view adds none of its own.
private struct WebsitesSection: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var input = ""
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(coordinator.siteRules, id: \.pattern) { rule in
                HStack {
                    Text(rule.pattern)
                    Spacer()
                    Toggle("Completions on \(rule.pattern)", isOn: Binding(
                        get: { rule.enabled },
                        set: { coordinator.setSiteRule(pattern: rule.pattern, enabled: $0) }))
                        .labelsHidden()
                    Button {
                        coordinator.removeSiteRule(pattern: rule.pattern)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(rule.pattern)")
                    .accessibilityLabel("Remove \(rule.pattern)")
                }
            }
            if coordinator.siteRules.isEmpty {
                Text("No website rules.").foregroundStyle(.secondary)
            }
            HStack {
                TextField("Add website", text: $input, prompt: Text("example.com or *.example.com"))
                    .labelsHidden()
                    .onSubmit(add)
                    .onChange(of: input) { _, _ in error = nil }
                Button("Add", action: add)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.subheadline)
            }
        } header: {
            Text("Websites")
        } footer: {
            Text("Rules apply in browsers whose page address NextTyped can read (Safari, Chromium browsers). Elsewhere the app setting applies. A website rule wins over the app setting.")
        }
    }

    private func add() {
        switch coordinator.addSiteRule(input) {
        case .success: input = ""; error = nil
        case .failure(let failure): error = failure.message
        }
    }
}
