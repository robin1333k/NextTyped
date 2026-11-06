import Foundation

/// A string that passed a character-set and length check. A value that fails renders as `invalid`,
/// never as its raw text.
public struct DiagnosticsSafeString: Sendable, Equatable {
    public let rendered: String

    /// `[0-9.() -]{1,40}`, for the app version, the build and the macOS version. Digits only, so a
    /// letter-bearing string such as a typed word cannot pass.
    public static func version(_ raw: String) -> DiagnosticsSafeString {
        validated(raw, allowed: { $0.isASCII && ($0.isNumber || ".() -".contains($0)) }, max: 40)
    }

    /// `[0-9A-Za-z.-]{1,40}` that starts with `Apple M` or `Intel`, the only chip families the app
    /// runs on. Any other string renders as `invalid`.
    public static func chip(_ raw: String) -> DiagnosticsSafeString {
        let safe = validated(raw, allowed: { $0.isASCII && ($0.isLetter || $0.isNumber || ". -".contains($0)) }, max: 40)
        if safe.rendered == "invalid" { return safe }
        return raw.hasPrefix("Apple M") || raw.hasPrefix("Intel") ? safe : DiagnosticsSafeString(rendered: "invalid")
    }

    /// `[A-Za-z0-9._-]{1,80}`, the last path component only, and only a shipped model family. A folder
    /// name the user picked for another model renders as `custom`, so a private folder name cannot
    /// reach the report through `modelDirectory`.
    public static func modelName(_ raw: String) -> DiagnosticsSafeString {
        let last = raw.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        let safe = validated(last, allowed: { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }, max: 80)
        if safe.rendered == "invalid" { return safe }
        return last.hasPrefix("Qwen") ? safe : DiagnosticsSafeString(rendered: "custom")
    }

    private static func validated(_ raw: String, allowed: (Character) -> Bool, max: Int) -> DiagnosticsSafeString {
        guard !raw.isEmpty, raw.count <= max, raw.allSatisfy(allowed) else {
            return DiagnosticsSafeString(rendered: "invalid")
        }
        return DiagnosticsSafeString(rendered: raw)
    }

    private init(rendered: String) { self.rendered = rendered }
}

/// The diagnostics report: a value built only from typed fields and
/// closed-set values, rendered to plain text by ``render()``. No field takes free text from the typing
/// path. The builder takes no `TypingContext`, no prediction inputs and no raw log line other than
/// through ``DiagnosticsTagTally``.
public struct DiagnosticsReport: Sendable, Equatable {
    public enum SigningKind: String, Sendable { case developer, adhoc, developerID, unknown }
    public enum PermissionState: String, Sendable {
        case granted, denied
        case notAsked = "not asked"
    }
    public enum ModelSource: String, Sendable { case local, downloaded }
    public enum ModelLoad: String, Sendable {
        case loaded, loading, failed
        case notLoaded = "not loaded"
    }
    public enum ResidencyTier: String, Sendable { case active, flushed, unloaded }

    public struct System: Sendable, Equatable {
        public var macOSVersion: DiagnosticsSafeString
        public var chip: DiagnosticsSafeString
        public var memoryGB: Int
        public var freeDiskGB: Int
        public init(macOSVersion: DiagnosticsSafeString, chip: DiagnosticsSafeString, memoryGB: Int, freeDiskGB: Int) {
            self.macOSVersion = macOSVersion; self.chip = chip
            self.memoryGB = memoryGB; self.freeDiskGB = freeDiskGB
        }
    }

    public struct Model: Sendable, Equatable {
        public var name: DiagnosticsSafeString
        public var source: ModelSource
        public var load: ModelLoad
        public var tier: ResidencyTier
        public var unloadAfterIdle: ModelUnloadSetting
        public init(name: DiagnosticsSafeString, source: ModelSource, load: ModelLoad,
                    tier: ResidencyTier, unloadAfterIdle: ModelUnloadSetting) {
            self.name = name; self.source = source; self.load = load
            self.tier = tier; self.unloadAfterIdle = unloadAfterIdle
        }
    }

    /// The settings that change behaviour. `appOverrideCount` is a count, never the bundle IDs.
    public struct Settings: Sendable, Equatable {
        public var globallyEnabled = true
        public var appOverrideCount = 0
        public var appDefaultMode = DefaultMode.everywhere
        public var showMenuBarIcon = true
        public var completionLength = CompletionLength.medium
        public var trailingPunctuation = TrailingPunctuation.bothShortcuts
        public var windowContextEnabled = true
        public var screenOCREnabled = false
        public var personalizationEnabled = false
        public var snapshotReuseEnabled = true  // on when the key is absent
        public var midTextCompletionEnabled = false
        public var spellingVariant = SpellingVariant.off
        public var launchAtLogin = false
        public init() {}
    }

    public struct LastCrash: Sendable, Equatable {
        /// `yyyy-MM-dd`.
        public var date: String
        /// An exception type such as `EXC_BAD_ACCESS`.
        public var exceptionType: String
        public init(date: String, exceptionType: String) {
            let isDate = date.count == 10 && date.enumerated().allSatisfy { i, c in
                (i == 4 || i == 7) ? c == "-" : (c.isASCII && c.isNumber)
            }
            self.date = isDate ? date : "invalid"
            self.exceptionType = DiagnosticsReport.crashException(exceptionType)
        }
    }

    /// `yyyy-MM-dd HH:mm`, built by the caller from a `Date`.
    public var exportedAt: String
    public var appVersion: DiagnosticsSafeString
    public var appBuild: DiagnosticsSafeString
    public var system: System
    public var signing: SigningKind
    public var accessibility: PermissionState
    public var screenRecording: PermissionState
    public var model: Model
    public var settings: Settings
    public var lastCrash: LastCrash?
    public var tally: [DiagnosticsTagTally.Entry]

    public init(exportedAt: String, appVersion: DiagnosticsSafeString, appBuild: DiagnosticsSafeString,
                system: System, signing: SigningKind, accessibility: PermissionState,
                screenRecording: PermissionState, model: Model, settings: Settings,
                lastCrash: LastCrash?, tally: [DiagnosticsTagTally.Entry]) {
        self.exportedAt = exportedAt; self.appVersion = appVersion; self.appBuild = appBuild
        self.system = system; self.signing = signing; self.accessibility = accessibility
        self.screenRecording = screenRecording; self.model = model; self.settings = settings
        self.lastCrash = lastCrash; self.tally = tally
    }

    public static let footer = "This report holds no text you typed and no personalization data."

    /// Plain UTF-8 text, one `key: value` per line under short headers.
    public func render() -> String {
        let d = Settings()
        func on(_ b: Bool) -> String { b ? "on" : "off" }
        func line<T: Equatable>(_ key: String, _ shown: String, _ value: T, _ shipping: T) -> String {
            "\(key): \(shown)" + (value == shipping ? "" : " (changed)")
        }
        var out: [String] = []
        let stamp = exportedAt.count <= 20 && exportedAt.allSatisfy { $0.isASCII && ($0.isNumber || "-: T".contains($0)) }
            ? exportedAt : "invalid"
        out.append("NextTyped diagnostics report, exported \(stamp)")
        out.append("")
        out.append("App")
        out.append("App version: \(appVersion.rendered)")
        out.append("Build: \(appBuild.rendered)")
        out.append("Signing: \(signing.rawValue)")
        out.append("")
        out.append("System")
        out.append("macOS: \(system.macOSVersion.rendered)")
        out.append("Chip: \(system.chip.rendered)")
        out.append("Memory: \(system.memoryGB) GB")
        out.append("Free disk: \(system.freeDiskGB) GB")
        out.append("")
        out.append("Permissions")
        out.append("Accessibility: \(accessibility.rawValue)")
        out.append("Screen Recording: \(screenRecording.rawValue)")
        out.append("")
        out.append("Model")
        out.append("Name: \(model.name.rendered)")
        out.append("Source: \(model.source.rawValue)")
        out.append("Load state: \(model.load.rawValue)")
        out.append("Residency: \(model.tier.rawValue)")
        out.append(line("modelUnloadAfterIdle", model.unloadAfterIdle.rawValue, model.unloadAfterIdle, .automatic))
        out.append("")
        out.append("Settings")
        let s = settings
        out.append(line("globallyEnabled", on(s.globallyEnabled), s.globallyEnabled, d.globallyEnabled))
        out.append(line("appOverrides", "\(s.appOverrideCount)", s.appOverrideCount, d.appOverrideCount))
        out.append(line("appDefaultMode", s.appDefaultMode.rawValue, s.appDefaultMode, d.appDefaultMode))
        out.append(line("showMenuBarIcon", on(s.showMenuBarIcon), s.showMenuBarIcon, d.showMenuBarIcon))
        out.append(line("completionLength", s.completionLength.rawValue, s.completionLength, d.completionLength))
        out.append(line("trailingPunctuation", s.trailingPunctuation.rawValue, s.trailingPunctuation, d.trailingPunctuation))
        out.append(line("windowContextEnabled", on(s.windowContextEnabled), s.windowContextEnabled, d.windowContextEnabled))
        out.append(line("screenOCREnabled", on(s.screenOCREnabled), s.screenOCREnabled, d.screenOCREnabled))
        out.append(line("personalization", on(s.personalizationEnabled), s.personalizationEnabled, d.personalizationEnabled))
        out.append(line("snapshotReuseEnabled", on(s.snapshotReuseEnabled), s.snapshotReuseEnabled, d.snapshotReuseEnabled))
        out.append(line("midTextCompletionEnabled", on(s.midTextCompletionEnabled), s.midTextCompletionEnabled, d.midTextCompletionEnabled))
        out.append(line("spellingVariant", s.spellingVariant.rawValue, s.spellingVariant, d.spellingVariant))
        out.append(line("launchAtLogin", on(s.launchAtLogin), s.launchAtLogin, d.launchAtLogin))
        out.append("")
        out.append("Last crash")
        if let c = lastCrash {
            out.append("Date: \(c.date)")
            out.append("Exception: \(c.exceptionType)")
        } else {
            out.append("none")
        }
        out.append("")
        out.append("Status counts")
        if tally.isEmpty {
            out.append("none")
        } else {
            for e in tally {
                switch e.event {
                case .known(let tag, let token): out.append("\(tag.rawValue) \(token) \(e.count)")
                case .other: out.append("other \(e.count)")
                }
            }
        }
        out.append("")
        out.append(Self.footer)
        return out.joined(separator: "\n") + "\n"
    }

    /// Whole GB, rounded to nearest, for memory and disk figures.
    public static func wholeGB(bytes: Int64) -> Int {
        Int((Double(bytes) / 1_000_000_000).rounded())
    }

    /// A crash exception type is kept only when it is one `EXC_*`/`SIG*` style identifier.
    public static func crashException(_ raw: String) -> String {
        let ok = !raw.isEmpty && raw.count <= 40 && raw.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }
        return ok ? raw : "invalid"
    }
}
