/// Where `MLXPredictionEngine` should load the model weights from.
///
/// Two sources: the developer's local `~/Models/…` directory (offline dev loop, no download) and a
/// Hugging Face repo the app downloads on first run. Kept as a **pure decision** in Core so the
/// dev-override precedence is unit-testable with no filesystem or MLX — the engine only
/// executes the choice.
public enum ModelSource: Equatable, Sendable {
    /// Load from the hard-coded local `~/Models/…` directory (developer machine).
    case localDirectory
    /// Download + load from the given Hugging Face repo id at the given revision
    /// (`ModelConfiguration(id:revision:)`). The revision is a full commit SHA for the shipping models
    /// and `main` for a developer override.
    case hubDownload(repoId: String, revision: String)
}

public enum ModelSourceResolver {
    /// Decide the model source for this launch.
    ///
    /// - Rule: **prefer the local directory when it exists** so the developer's offline loop never
    ///   re-downloads; otherwise download from the Hub (the path every
    ///   non-developer takes on first run).
    /// - `forceDownload` is a developer escape hatch (a `UserDefaults` flag) to exercise the first-run
    ///   download UX **without** deleting `~/Models/`: when set, download wins even if the local dir
    ///   is present.
    public static func resolve(
        localDirectoryExists: Bool,
        forceDownload: Bool,
        repoId: String,
        revision: String
    ) -> ModelSource {
        if localDirectoryExists && !forceDownload { return .localDirectory }
        return .hubDownload(repoId: repoId, revision: revision)
    }
}

extension ModelSourceResolver {
    /// The first candidate directory that exists, or `nil` when none does (then the Hub path runs).
    /// `exists` is the file-system boundary; the App passes a home-relative `fileExists` check.
    public static func firstExistingDirectory(
        _ candidates: [String], exists: (String) -> Bool
    ) -> String? {
        candidates.first(where: exists)
    }
}

/// The forward model the app ships with.
///
/// The default is **Qwen3.5-4B-Base**, self-quantized to MLX 6-bit, loaded from `~/Models/` when that
/// copy exists. A machine that has only the 2B copy loads the 2B and does not download the 4B.
/// A machine with no local copy downloads the **4B** from the Hub.
public enum ShippingModel {
    /// Local model folders, tried in order. Home-relative, or absolute when they start with `/`.
    public static let localDirectories = [
        "Models/Qwen3.5-4B-Base-MLX-6bit",
        "Models/Qwen3.5-2B-Base-MLX-6bit",
    ]

    /// The Hugging Face repo a machine without a local copy downloads from on first run: the 4B,
    /// hosted since 2026-10-28.
    public static let hubRepoId = "Robin1333k/Qwen3.5-4B-Base-MLX-6bit"

    /// The commit of ``hubRepoId`` that new installs download (full 40-character SHA, read from the Hub
    /// API field `sha` on 2026-10-28). A push to the repo does not change what a new install runs.
    /// **Moving the pin is a code change in a PR**: re-read the SHA,
    /// change this constant, and say why in the PR.
    public static let hubRevision = "dd2480929d3e6ed72fc4f48f10b1ed05122e6489"

    /// The FIM model repo (default-off). It is **not hosted yet**: the Hub returns no `sha`
    /// for it, so there is nothing to pin and the revision stays `main`. Pin it in the PR that uploads
    /// the weights.
    public static let fimHubRepoId = "Robin1333k/Qwen3-1.7B-MLX-6bit"
    public static let fimHubRevision = "main"

    /// The Hub repo and revision for a launch, from the shipping pair and the two developer keys
    /// (`modelRepoId`, `modelRevision`). No key: the pinned pair. A `modelRepoId` override without a
    /// `modelRevision` reads `main`, because the pin belongs to the shipping repo only. A
    /// `modelRevision` alone pins the shipping repo to that revision. Empty strings count as unset.
    public static func hubSource(
        repoIdOverride: String?, revisionOverride: String?,
        defaultRepoId: String = hubRepoId, defaultRevision: String = hubRevision
    ) -> (repoId: String, revision: String) {
        let repo = repoIdOverride.flatMap { $0.isEmpty ? nil : $0 }
        let revision = revisionOverride.flatMap { $0.isEmpty ? nil : $0 }
        if let repo { return (repo, revision ?? "main") }
        return (defaultRepoId, revision ?? defaultRevision)
    }

    /// The log line for a Hub download: `<repo>@<first 7 of the revision>`; a branch name stays whole.
    public static func hubDownloadLabel(repoId: String, revision: String) -> String {
        let isCommit = revision.count == 40 && revision.allSatisfy { $0.isHexDigit }
        return "\(repoId)@\(isCommit ? String(revision.prefix(7)) : revision)"
    }

    /// The folders to try for this launch. A non-empty `modelDirectory` override replaces the list,
    /// so `defaults write com.robinklotz.NextTyped modelDirectory Models/Qwen3.5-2B-Base-MLX-6bit`
    /// loads the 2B even where the 4B exists.
    public static func localDirectoryCandidates(override: String?) -> [String] {
        if let override, !override.isEmpty { return [override] }
        return localDirectories
    }

    /// The model line in Settings → General for the folder this launch loads (`nil`: the Hub path,
    /// which is the 4B). A `modelDirectory` override outside the two shipping folders shows its
    /// folder name.
    public static func settingsLabel(localDirectory: String?) -> String {
        guard let localDirectory else { return label4B }
        let name = localDirectory.split(separator: "/").last.map(String.init) ?? localDirectory
        switch name {
        case "Qwen3.5-4B-Base-MLX-6bit": return label4B
        case "Qwen3.5-2B-Base-MLX-6bit": return "Qwen3.5-2B-Base · 6-bit (~1.5 GB)"
        default: return name
        }
    }

    /// The resident sizes shown in the unload footer, for the folder this launch loads (`nil`: the Hub
    /// path, which is the 4B). Measured.
    public static func memoryFigures(localDirectory: String?) -> (loaded: String, unloaded: String) {
        let name = localDirectory?.split(separator: "/").last.map(String.init)
        if name == "Qwen3.5-2B-Base-MLX-6bit" { return ("1.6 GB", "140 MB") }
        return ("3.4 GB", "140 MB")
    }

    private static let label4B = "Qwen3.5-4B-Base · 6-bit (~3.2 GB)"
}

// MARK: - Explicit model choice

/// The model the user picked in Settings → General. `automatic` is the folder rule that predates the
/// picker: the 4B folder, then the 2B folder, then the Hub 4B. A pick names one model; the app loads its
/// local folder when it exists and downloads that model otherwise.
public enum ModelChoice: String, CaseIterable, Sendable {
    case automatic
    case qwen4B = "4b"
    case qwen2B = "2b"

    /// An absent, empty or unknown stored value reads as `automatic`.
    public init(stored: String?) {
        self = stored.flatMap(ModelChoice.init(rawValue:)) ?? .automatic
    }

    /// The row text in the picker: the model with its download size and its resident size.
    public var pickerLabel: String {
        switch self {
        case .automatic: "Automatic"
        case .qwen4B: "Qwen3.5-4B-Base (3.2 GB download, 3.4 GB memory)"
        case .qwen2B: "Qwen3.5-2B-Base (1.5 GB download, 1.6 GB memory)"
        }
    }

    /// 16 GB is the line. The 4B holds about 3.4 GB resident and an 8 GB Mac is untested.
    public static let fourBMinimumMemoryBytes: UInt64 = 16 * 1_073_741_824

    public static func recommended(physicalMemoryBytes: UInt64) -> ModelChoice {
        physicalMemoryBytes >= fourBMinimumMemoryBytes ? .qwen4B : .qwen2B
    }

    /// The sentence under the picker. The memory figure is rounded to whole GB.
    public static func recommendationLine(physicalMemoryBytes: UInt64) -> String {
        let gigabytes = Int((Double(physicalMemoryBytes) / 1_073_741_824).rounded())
        let name = recommended(physicalMemoryBytes: physicalMemoryBytes) == .qwen4B
            ? "Qwen3.5-4B-Base" : "Qwen3.5-2B-Base"
        return "Recommended for this Mac (\(gigabytes) GB memory): \(name)."
    }
}

/// Where one launch loads the base model from: local folders in order, then a pinned Hub repo.
public struct ModelPlan: Equatable, Sendable {
    public let candidates: [String]
    public let hubRepoId: String
    public let hubRevision: String
}

extension ShippingModel {
    /// The 2B repo and its commit (Hub API field `sha`, read 2026-11-04). Pinned for the same reason as
    /// the 4B. Moving the pin is a code change in a PR.
    public static let hub2BRepoId = "Robin1333k/Qwen3.5-2B-Base-MLX-6bit"
    public static let hub2BRevision = "608e41eb06e9e75a982944ffa843323c266e32a3"

    /// The plan for this launch. Precedence: the developer key `modelDirectory` replaces the folder
    /// list, then the choice. `modelRepoId` and `modelRevision` apply as in ``hubSource``.
    public static func plan(
        choice: ModelChoice,
        directoryOverride: String? = nil,
        repoIdOverride: String? = nil,
        revisionOverride: String? = nil
    ) -> ModelPlan {
        let folders: [String]
        let defaults: (repo: String, revision: String)
        switch choice {
        case .automatic: folders = localDirectories; defaults = (hubRepoId, hubRevision)
        case .qwen4B: folders = [localDirectories[0]]; defaults = (hubRepoId, hubRevision)
        case .qwen2B: folders = [localDirectories[1]]; defaults = (hub2BRepoId, hub2BRevision)
        }
        let hub = hubSource(
            repoIdOverride: repoIdOverride, revisionOverride: revisionOverride,
            defaultRepoId: defaults.repo, defaultRevision: defaults.revision)
        return ModelPlan(
            candidates: localDirectoryCandidates(override: directoryOverride, default: folders),
            hubRepoId: hub.repoId, hubRevision: hub.revision)
    }

    /// Like ``localDirectoryCandidates(override:)`` with the fallback list passed in.
    static func localDirectoryCandidates(override: String?, default folders: [String]) -> [String] {
        if let override, !override.isEmpty { return [override] }
        return folders
    }

    /// The label for the folder that loads, or on the Hub path (`nil`) for the model the choice names.
    public static func settingsLabel(localDirectory: String?, choice: ModelChoice) -> String {
        if localDirectory == nil, choice == .qwen2B { return settingsLabel(localDirectory: localDirectories[1]) }
        return settingsLabel(localDirectory: localDirectory)
    }

    public static func memoryFigures(localDirectory: String?, choice: ModelChoice) -> (loaded: String, unloaded: String) {
        if localDirectory == nil, choice == .qwen2B { return memoryFigures(localDirectory: localDirectories[1]) }
        return memoryFigures(localDirectory: localDirectory)
    }
}
