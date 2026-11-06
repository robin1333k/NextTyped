import AppKit
import NextTypedCore
import Security

/// Builds the diagnostics report from the live app and writes it where the user chooses.
/// Local only: no connection, no `mailto:`, no copy kept.
@MainActor
enum DiagnosticsExporter {
    /// Set by the coordinator at start: the model's load state and residency tier.
    static var modelState: () -> (ModelLoadState, ModelResidencyPolicy.ModelState) = { (.loading, .loaded) }

    static func makeReport(now: Date = Date()) -> DiagnosticsReport {
        let store = AppSettingsStore()
        let info = Bundle.main
        let (load, tier) = modelState()
        let localDir = MLXPredictionEngine.localModelDirectoryForThisLaunch()
        let repo = MLXPredictionEngine.currentPlan().hubRepoId
        let policy = store.policy

        var settings = DiagnosticsReport.Settings()
        settings.globallyEnabled = policy.globallyEnabled
        settings.appOverrideCount = policy.overrides.count
        settings.appDefaultMode = policy.defaultMode
        settings.showMenuBarIcon = store.showMenuBarIcon
        settings.completionLength = store.completionLength
        settings.trailingPunctuation = store.trailingPunctuation
        settings.windowContextEnabled = store.windowContextEnabled
        settings.screenOCREnabled = store.screenOCREnabled
        settings.personalizationEnabled = store.personalizationEnabled
        settings.snapshotReuseEnabled = PrefixReuse.snapshotReuseEnabled(
            stored: UserDefaults.standard.object(forKey: "snapshotReuseEnabled") == nil
                ? nil : UserDefaults.standard.bool(forKey: "snapshotReuseEnabled"))
        settings.midTextCompletionEnabled = store.midTextCompletionEnabled
        settings.spellingVariant = store.spellingVariant
        settings.launchAtLogin = LaunchAtLogin.isEnabled

        let os = ProcessInfo.processInfo.operatingSystemVersion
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        return DiagnosticsReport(
            exportedAt: stamp.string(from: now),
            appVersion: .version(info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
            appBuild: .version(info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            system: .init(macOSVersion: .version("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                          chip: .chip(chipName()),
                          memoryGB: DiagnosticsReport.wholeGB(bytes: Int64(ProcessInfo.processInfo.physicalMemory)),
                          freeDiskGB: DiagnosticsReport.wholeGB(bytes: freeDiskBytes())),
            signing: signingKind(),
            accessibility: Permissions.hasAccessibility ? .granted
                : (UserDefaults.standard.bool(forKey: Permissions.accessibilityPromptShownKey) ? .denied : .notAsked),
            screenRecording: Permissions.hasScreenRecording ? .granted
                : (store.screenOCREnabled ? .denied : .notAsked),
            model: .init(name: .modelName(localDir ?? repo),
                         source: localDir != nil ? .local : .downloaded,
                         load: modelLoad(load), tier: residencyTier(tier),
                         unloadAfterIdle: store.modelUnloadSetting),
            settings: settings, lastCrash: lastCrash(),
            tally: DiagnosticsTallyHub.shared.entries)
    }

    /// Harness command `diagnostics.export <path>`: the same report without the save panel.
    #if DEBUG
    static func exportForHarness(to path: String) -> [String: Any] {
        let text = makeReport().render()
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return ["error": "write failed"]
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        acLog("[diagnostics]: exported lines=%d", lines)
        return ["ok": true, "lines": lines]
    }
    #endif

    /// About → Support → Export...: a save panel on the Desktop, then the file is revealed in Finder.
    static func exportWithSavePanel() {
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "NextTyped-diagnostics-\(stamp.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            acLog("[diagnostics]: cancelled")
            return
        }
        let text = makeReport().render()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            acLog("[diagnostics]: write failed")
            let alert = NSAlert()
            alert.messageText = "The report could not be saved."
            alert.informativeText = "Choose another folder and try again."
            alert.runModal()
            return
        }
        acLog("[diagnostics]: exported lines=%d", text.split(separator: "\n", omittingEmptySubsequences: false).count - 1)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Facts

    private static func modelLoad(_ s: ModelLoadState) -> DiagnosticsReport.ModelLoad {
        switch s {
        case .ready: return .loaded
        case .loading, .downloading: return .loading
        case .failed: return .failed
        case .unloaded: return .notLoaded
        }
    }

    private static func residencyTier(_ s: ModelResidencyPolicy.ModelState) -> DiagnosticsReport.ResidencyTier {
        switch s {
        case .loaded: return .active
        case .flushed: return .flushed
        case .unloaded: return .unloaded
        }
    }

    private static func chipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private static func freeDiskBytes() -> Int64 {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func signingKind() -> DiagnosticsReport.SigningKind {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unknown }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return .unknown }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any] else { return .unknown }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        if flags & 0x2 != 0 { return .adhoc }   // kSecCodeSignatureAdhoc
        guard let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first,
              let name = SecCertificateCopySubjectSummary(leaf) as String? else { return .unknown }
        if name == "NextTyped Dev" { return .developer }
        if name.hasPrefix("Developer ID Application") { return .developerID }
        return .unknown
    }

    /// Date and exception type of the newest `NextTyped-*.ips`, nothing else from the file.
    private static func lastCrash() -> DiagnosticsReport.LastCrash? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("NextTyped-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                return (url, d)
            }
            .max { $0.1 < $1.1 }
        guard let (url, date) = newest else { return nil }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        var type = "unknown"
        if let data = try? Data(contentsOf: url), let nl = data.firstIndex(of: 0x0A),
           let body = try? JSONSerialization.jsonObject(with: data[data.index(after: nl)...]) as? [String: Any],
           let exc = (body["exception"] as? [String: Any])?["type"] as? String {
            type = exc
        }
        return .init(date: day.string(from: date), exceptionType: type)
    }
}
