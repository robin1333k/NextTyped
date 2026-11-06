import Testing
@testable import NextTypedCore

/// `ModelLoadStatus.apply` is the one rule for what the menu and General show about the model.
@Suite struct ModelLoadStatusTests {

    @Test func unloadMovesReadyToUnloaded() {
        #expect(ModelLoadStatus.apply(.unloaded, to: .ready) == .unloaded)
    }

    @Test func loadingStartedLeavesUnloaded() {
        #expect(ModelLoadStatus.apply(.loadingStarted, to: .unloaded) == .loading)
    }

    @Test func failureEndsALoad() {
        #expect(ModelLoadStatus.apply(.failed, to: .loading) == .failed)
    }

    @Test func readyEndsALoad() {
        #expect(ModelLoadStatus.apply(.ready, to: .downloading(0.9)) == .ready)
    }

    @Test func lateDownloadTickDoesNotOverwriteReady() {
        #expect(ModelLoadStatus.apply(.downloading(0.5), to: .ready) == .ready)
    }

    @Test func lateDownloadTickDoesNotOverwriteFailed() {
        #expect(ModelLoadStatus.apply(.downloading(0.5), to: .failed) == .failed)
    }

    @Test func downloadTickMovesLoadingToDownloading() {
        #expect(ModelLoadStatus.apply(.downloading(0.5), to: .loading) == .downloading(0.5))
    }

    @Test func unloadDoesNotHideAFailure() {
        #expect(ModelLoadStatus.apply(.unloaded, to: .failed) == .failed)
    }

    @Test func loadingWeightsGivesLoading() {
        #expect(ModelLoadStatus.apply(.loadingWeights, to: .downloading(1)) == .loading)
    }

    @Test func retryLeavesFailed() {
        #expect(ModelLoadStatus.apply(.loadingStarted, to: .failed) == .loading)
    }

    @Test func menuLabels() {
        #expect(ModelLoadState.unloaded.menuLabel == "Model unloaded to save memory")
        #expect(ModelLoadState.ready.menuLabel == "Model ready")
        #expect(ModelLoadState.failed.menuLabel == "Model could not load")
        #expect(ModelLoadState.downloading(0.42).menuLabel == "Downloading model… 42%")
        #expect(ModelLoadState.loading.menuLabel == "Loading model…")
    }

    @Test func onlyReadyOffersUnloadNow() {
        #expect(ModelLoadState.ready.offersUnloadNow)
        #expect(!ModelLoadState.unloaded.offersUnloadNow)
        #expect(!ModelLoadState.loading.offersUnloadNow)
        #expect(!ModelLoadState.failed.offersUnloadNow)
    }

    /// An engine with no load step (the fake) must reach `.ready` through the default stream, or the
    /// App's single consumer leaves the state at `.loading` forever.
    @Test func defaultEngineStreamReachesReady() async {
        struct NoLoadStepEngine: PredictionEngine {
            func predict(for context: TypingContext) async throws -> Suggestion { fatalError("unused") }
        }
        var state = ModelLoadState.loading
        for await event in await NoLoadStepEngine().loadEvents() {
            state = ModelLoadStatus.apply(event, to: state)
        }
        #expect(state == .ready)
    }

    @Test func aDiskTooSmallForTheDownloadIsAFailedLoad() {
        let shortfall = ModelDiskVerdict.tooSmall(neededBytes: 4_512_276_480, freeBytes: 1_000)
        #expect(ModelLoadStatus.apply(.diskTooSmall(shortfall), to: .loading) == .failed)
        #expect(ModelLoadStatus.apply(.diskTooSmall(shortfall), to: .downloading(0.2)) == .failed)
    }
}
