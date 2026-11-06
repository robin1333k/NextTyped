import Testing
@testable import NextTypedCore

@Suite struct ModelSourceResolverTests {
    // The real shipping repo id. The resolver never validates it — any string would exercise the same
    // branches — but keeping a dead namespace here invites someone to copy it into the App default,
    // which is exactly the bug that shipped: `robinklotz` never existed as an HF account.
    private let repo = "Robin1333k/Qwen3.5-2B-Base-MLX-6bit"

    // MARK: Dev-local preference (the offline dev loop stays intact)

    @Test func prefersLocalDirectoryWhenPresent() {
        // The developer's ~/Models copy exists → load from disk, no download.
        #expect(
            ModelSourceResolver.resolve(localDirectoryExists: true, forceDownload: false, repoId: repo, revision: "main")
                == .localDirectory)
    }

    // MARK: Hub download (any user without the local copy)

    @Test func downloadsFromHubWhenLocalMissing() {
        // Fresh machine: no local dir → download by repo id (the shipping path).
        #expect(
            ModelSourceResolver.resolve(localDirectoryExists: false, forceDownload: false, repoId: repo, revision: "main")
                == .hubDownload(repoId: repo, revision: "main"))
    }

    // MARK: forceDownload escape hatch (exercise the download path even in the dev loop)

    @Test func forceDownloadOverridesPresentLocalDirectory() {
        // The developer flips the UserDefaults escape hatch to test the first-run download UX
        // without wiping ~/Models: download wins even though the local dir is present.
        #expect(
            ModelSourceResolver.resolve(localDirectoryExists: true, forceDownload: true, repoId: repo, revision: "main")
                == .hubDownload(repoId: repo, revision: "main"))
    }

    @Test func forceDownloadWithMissingLocalStillDownloads() {
        // forceDownload + no local dir is just the normal download path (no contradiction).
        #expect(
            ModelSourceResolver.resolve(localDirectoryExists: false, forceDownload: true, repoId: repo, revision: "main")
                == .hubDownload(repoId: repo, revision: "main"))
    }
}

/// Which local directory the forward model loads from: the 4B is the default, the 2B is the
/// fallback on a machine that has only the 2B, and a machine with neither downloads the 4B from the Hub.
@Suite struct ShippingModelTests {
    @Test func defaultCandidatesTryThe4BBeforeThe2B() {
        #expect(
            ShippingModel.localDirectoryCandidates(override: nil)
                == ["Models/Qwen3.5-4B-Base-MLX-6bit", "Models/Qwen3.5-2B-Base-MLX-6bit"])
    }

    @Test func modelDirectoryOverrideReplacesTheDefaults() {
        // `defaults write … modelDirectory Models/Qwen3.5-2B-Base-MLX-6bit` keeps the 2B loadable
        // even where the 4B exists.
        #expect(
            ShippingModel.localDirectoryCandidates(override: "Models/Qwen3.5-2B-Base-MLX-6bit")
                == ["Models/Qwen3.5-2B-Base-MLX-6bit"])
    }

    @Test func emptyOverrideFallsBackToTheDefaults() {
        #expect(
            ShippingModel.localDirectoryCandidates(override: "")
                == ["Models/Qwen3.5-4B-Base-MLX-6bit", "Models/Qwen3.5-2B-Base-MLX-6bit"])
    }

    @Test func hubDownloadFetchesThe4BRepo() {
        // Hosted since 2026-10-28: a fresh machine downloads the 4B.
        #expect(ShippingModel.hubRepoId == "Robin1333k/Qwen3.5-4B-Base-MLX-6bit")
    }

    @Test func freshMachineWithNoLocalCopyDownloadsThe4B() {
        let local = ModelSourceResolver.firstExistingDirectory(
            ShippingModel.localDirectoryCandidates(override: nil), exists: { _ in false })
        #expect(
            ModelSourceResolver.resolve(
                localDirectoryExists: local != nil, forceDownload: false, repoId: ShippingModel.hubRepoId,
                revision: ShippingModel.hubRevision)
                == .hubDownload(
                    repoId: ShippingModel.hubRepoId, revision: ShippingModel.hubRevision))
    }

    @Test func aLocal2BFolderStillWinsOverDownloadingThe4B() {
        // a deliberate local copy is never replaced by a 3.2 GB download.
        let present: Set = ["Models/Qwen3.5-2B-Base-MLX-6bit"]
        let local = ModelSourceResolver.firstExistingDirectory(
            ShippingModel.localDirectoryCandidates(override: nil), exists: present.contains)
        #expect(local == "Models/Qwen3.5-2B-Base-MLX-6bit")
        #expect(
            ModelSourceResolver.resolve(
                localDirectoryExists: local != nil, forceDownload: false, repoId: ShippingModel.hubRepoId,
                revision: ShippingModel.hubRevision)
                == .localDirectory)
    }

    @Test func picksThe4BWhenBothExist() {
        let present: Set = ["Models/Qwen3.5-4B-Base-MLX-6bit", "Models/Qwen3.5-2B-Base-MLX-6bit"]
        #expect(
            ModelSourceResolver.firstExistingDirectory(
                ShippingModel.localDirectoryCandidates(override: nil), exists: present.contains)
                == "Models/Qwen3.5-4B-Base-MLX-6bit")
    }

    @Test func picksThe2BWhenOnlyThe2BExists() {
        let present: Set = ["Models/Qwen3.5-2B-Base-MLX-6bit"]
        #expect(
            ModelSourceResolver.firstExistingDirectory(
                ShippingModel.localDirectoryCandidates(override: nil), exists: present.contains)
                == "Models/Qwen3.5-2B-Base-MLX-6bit")
    }

    @Test func noLocalDirectoryMeansNone() {
        #expect(
            ModelSourceResolver.firstExistingDirectory(
                ShippingModel.localDirectoryCandidates(override: nil), exists: { _ in false })
                == nil)
    }

    // The General pane names the model that actually loads, not a hard-coded one.
    @Test func settingsLabelNamesThe4B() {
        #expect(
            ShippingModel.settingsLabel(localDirectory: "Models/Qwen3.5-4B-Base-MLX-6bit")
                == "Qwen3.5-4B-Base · 6-bit (~3.2 GB)")
    }

    @Test func settingsLabelNamesThe2BForTheLocal2B() {
        #expect(
            ShippingModel.settingsLabel(localDirectory: "Models/Qwen3.5-2B-Base-MLX-6bit")
                == "Qwen3.5-2B-Base · 6-bit (~1.5 GB)")
    }

    @Test func settingsLabelNamesThe4BForTheHubPath() {
        #expect(ShippingModel.settingsLabel(localDirectory: nil) == "Qwen3.5-4B-Base · 6-bit (~3.2 GB)")
    }

    @Test func settingsLabelNamesAnOverrideFolderByItsName() {
        #expect(
            ShippingModel.settingsLabel(localDirectory: "/Volumes/x/gemma-4-E4B-MLX-6bit/")
                == "gemma-4-E4B-MLX-6bit")
    }

    // MARK: Pinned revision (distribution: pin the Hub revision)

    @Test func shippingRevisionIsAFullCommitSha() {
        #expect(ShippingModel.hubRevision.count == 40)
        #expect(ShippingModel.hubRevision.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test func noOverrideUsesThePinnedPair() {
        let source = ShippingModel.hubSource(repoIdOverride: nil, revisionOverride: nil)
        #expect(source.repoId == "Robin1333k/Qwen3.5-4B-Base-MLX-6bit")
        #expect(source.revision == ShippingModel.hubRevision)
    }

    @Test func aRepoOverrideWithoutARevisionReadsMain() {
        let source = ShippingModel.hubSource(repoIdOverride: "someone/else", revisionOverride: nil)
        #expect(source.repoId == "someone/else")
        #expect(source.revision == "main")
    }

    @Test func aRepoOverrideWithARevisionUsesBoth() {
        let source = ShippingModel.hubSource(repoIdOverride: "someone/else", revisionOverride: "abc123")
        #expect(source.revision == "abc123")
    }

    @Test func aRevisionOverrideAlonePinsTheShippingRepo() {
        let source = ShippingModel.hubSource(repoIdOverride: nil, revisionOverride: "main")
        #expect(source.repoId == ShippingModel.hubRepoId)
        #expect(source.revision == "main")
    }

    @Test func emptyOverridesCountAsUnset() {
        let source = ShippingModel.hubSource(repoIdOverride: "", revisionOverride: "")
        #expect(source.repoId == ShippingModel.hubRepoId)
        #expect(source.revision == ShippingModel.hubRevision)
    }

    @Test func downloadLabelShortensACommitAndKeepsABranch() {
        #expect(
            ShippingModel.hubDownloadLabel(
                repoId: "Robin1333k/Qwen3.5-4B-Base-MLX-6bit", revision: ShippingModel.hubRevision)
                == "Robin1333k/Qwen3.5-4B-Base-MLX-6bit@dd24809")
        #expect(ShippingModel.hubDownloadLabel(repoId: "a/b", revision: "main") == "a/b@main")
    }

    /// The FIM repo is not hosted, so the Hub has no commit to pin. Whoever uploads
    /// the weights replaces this literal with the SHA and updates this test in the same PR.
    @Test func fimRevisionStaysMainUntilTheRepoIsHosted() {
        #expect(ShippingModel.fimHubRevision == "main")
    }
}
