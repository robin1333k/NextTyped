import AppKit
import NextTypedCore
import SwiftUI

/// One third-party component that ships in the app, with the licence its checkout or model card states.
/// The full texts are bundled as `Acknowledgements.txt`; `licenceURL` is the upstream copy.
struct Acknowledgement: Identifiable {
    let name: String
    let licence: String
    let licenceLink: String
    var id: String { name }

    /// `nil` only if a link string in `all` is malformed; `scripts/check-acknowledgements.sh` checks every link.
    var licenceURL: URL? { URL(string: licenceLink) }

    /// Every package in `project.yml` that is linked into the app target, plus the model weights.
    /// Indirect packages and vendored components have no row; their licence texts are in `Acknowledgements.txt`.
    /// Sparkle stays listed only while `project.yml` links it.
    static let all: [Acknowledgement] = [
        Acknowledgement(name: "Qwen3.5-4B-Base weights", licence: "Apache-2.0",
                        licenceLink: "https://huggingface.co/Qwen/Qwen3.5-4B-Base/blob/main/LICENSE"),
        Acknowledgement(name: "Qwen3.5-2B-Base weights", licence: "Apache-2.0",
                        licenceLink: "https://huggingface.co/Qwen/Qwen3.5-2B-Base/blob/main/LICENSE"),
        Acknowledgement(name: "mlx-swift", licence: "MIT",
                        licenceLink: "https://github.com/ml-explore/mlx-swift/blob/main/LICENSE"),
        Acknowledgement(name: "mlx-swift-lm", licence: "MIT",
                        licenceLink: "https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE"),
        Acknowledgement(name: "swift-transformers", licence: "Apache-2.0",
                        licenceLink: "https://github.com/huggingface/swift-transformers/blob/main/LICENSE"),
        Acknowledgement(name: "swift-huggingface", licence: "Apache-2.0",
                        licenceLink: "https://github.com/huggingface/swift-huggingface/blob/main/LICENSE"),
        Acknowledgement(name: "KeyboardShortcuts", licence: "MIT",
                        licenceLink: "https://github.com/sindresorhus/KeyboardShortcuts/blob/main/license"),
        Acknowledgement(name: "Sparkle", licence: "MIT",
                        licenceLink: "https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE"),
        Acknowledgement(name: "Unicode CLDR emoji names", licence: "Unicode-3.0",
                        licenceLink: "https://github.com/unicode-org/cldr/blob/main/LICENSE"),
    ]
}

/// About pane: identity, the positioning facts (fully on-device, zero telemetry, no subscription)
/// and the acknowledgements the app owes.
struct AboutSettingsView: View {
    @State private var showingLicences = false
    @ObservedObject private var updater = UpdateController.shared

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NextTyped").font(.title2.bold())
                        Text(version).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                fact("lock.fill", "Runs entirely on your Mac")
                fact("eye.slash.fill", "No telemetry. Your writing never leaves the device.")
                fact("checkmark.seal", "Free, with no subscription")
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Latest version")
                    Spacer(minLength: 8)
                    Button("Check for Updates...") { updater.checkForUpdates() }
                        .disabled(!updater.isRunning)
                }
                SettingsToggleRow(
                    title: "Check for updates automatically",
                    subtitle: "Once a day, if on. Each check asks the update server for one file and sends "
                        + "only your IP address and the app version.",
                    isOn: Binding(
                        get: { updater.automaticChecks },
                        set: { updater.setAutomaticChecks($0) }))
                    .disabled(!updater.isRunning)
                Picker("Update channel", selection: Binding(
                    get: { updater.channel }, set: { updater.setChannel($0) })) {
                    Text("Stable").tag(UpdateChannel.stable)
                    Text("Beta").tag(UpdateChannel.beta)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Beta offers test versions before they reach Stable.")
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostics report")
                        Text("Versions, settings and status counts. No text you typed.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Export...") { DiagnosticsExporter.exportWithSavePanel() }
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Open the file and read it before you send it.")
            }

            Section {
                ForEach(Acknowledgement.all) { item in
                    if let url = item.licenceURL {
                        SettingsLinkRow(title: item.name, symbol: "doc.text", value: item.licence, url: url)
                    } else {
                        SettingsValueRow(title: item.name, value: item.licence)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show licences") { showingLicences = true }
                }
            } header: {
                Text("Acknowledgements")
            } footer: {
                Text("NextTyped runs on these open-source projects, the Qwen model weights and the Unicode CLDR emoji names. \"Show licences\" lists the full texts, including indirect dependencies.")
            }

            // Slot: the CLDR row goes here.
            Section("Help") {
                // Both guides are bundled because the repository is private.
                Button("Which apps NextTyped works in") { BundledGuide.compatibility.openOrAlert() }
                    .buttonStyle(.link)
                Button("How to uninstall NextTyped") { BundledGuide.uninstall.openOrAlert() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .onAppear { updater.refreshAutomaticChecks() }
        .sheet(isPresented: $showingLicences) {
            LicencesSheet(isPresented: $showingLicences)
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
    }
}

/// The bundled `Acknowledgements.txt` in a scrolling monospaced text view.
struct LicencesSheet: View {
    @Binding var isPresented: Bool
    var text: String = LicencesSheet.bundledText()

    static func bundledText(in bundle: Bundle = .main) -> String {
        guard let url = bundle.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "The licence texts are missing from this build."
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Licences").font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 560, height: 460)
    }
}
