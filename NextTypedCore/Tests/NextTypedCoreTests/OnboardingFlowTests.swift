import Testing
@testable import NextTypedCore

@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    @Test func aFreshFlowOpensOnTheTabDemoWithNoBack() {
        let flow = OnboardingFlow(accessibilityGranted: false)
        #expect(flow.page == .tryTab)
        #expect(!flow.canGoBack)
        #expect(OnboardingPage.allCases == [.tryTab, .permission, .model, .practice])
    }

    @Test func nextWalksThePagesInOrderAndStopsAtPractice() {
        var flow = OnboardingFlow(accessibilityGranted: true)
        flow.apply(.next); #expect(flow.page == .permission)
        flow.apply(.next); #expect(flow.page == .model)
        flow.apply(.next); #expect(flow.page == .practice)
        flow.apply(.next); #expect(flow.page == .practice)
    }

    @Test func backReturnsOnePageAndStopsAtTheDemo() {
        var flow = OnboardingFlow(accessibilityGranted: true)
        flow.apply(.next); flow.apply(.next)
        flow.apply(.back); #expect(flow.page == .permission)
        flow.apply(.back); #expect(flow.page == .tryTab)
        flow.apply(.back); #expect(flow.page == .tryTab)
    }

    @Test func thePermissionPageHoldsUntilAccessibilityIsGranted() {
        var flow = OnboardingFlow(accessibilityGranted: false)
        flow.apply(.next)
        #expect(!flow.canGoNext)
        flow.apply(.next)
        #expect(flow.page == .permission)
    }

    @Test func grantingAccessibilityOnThePermissionPageAdvancesToTheModel() {
        var flow = OnboardingFlow(accessibilityGranted: false)
        flow.apply(.next)
        flow.apply(.accessibilityChanged(true))
        #expect(flow.page == .model)
    }

    @Test func aGrantSeenOnAnotherPageMovesNothing() {
        var flow = OnboardingFlow(accessibilityGranted: false)
        flow.apply(.accessibilityChanged(true))
        #expect(flow.page == .tryTab)
        flow.apply(.next)
        #expect(flow.page == .permission)
        #expect(flow.canGoNext)
    }

    @Test func aRepeatedGrantDoesNotSkipTheModelPageAfterBack() {
        var flow = OnboardingFlow(accessibilityGranted: false)
        flow.apply(.next)
        flow.apply(.accessibilityChanged(true))
        flow.apply(.back)
        #expect(flow.page == .permission)
        flow.apply(.accessibilityChanged(true))
        #expect(flow.page == .permission)
    }

    @Test func losingAccessibilityOnLaterPagesKeepsThePage() {
        var flow = OnboardingFlow(accessibilityGranted: true)
        flow.apply(.next); flow.apply(.next)
        flow.apply(.accessibilityChanged(false))
        #expect(flow.page == .model)
    }
}

@Suite("TabDemo")
struct TabDemoTests {
    @Test func startsWithTheWholeCannedGhostShown() {
        let demo = TabDemo()
        #expect(demo.typed == "Thanks for the update. I will send the")
        #expect(demo.ghost == " report by Friday.")
        #expect(!demo.isDone)
    }

    @Test func acceptWordTakesOneWordAtATime() {
        var demo = TabDemo()
        demo.apply(.acceptWord)
        #expect(demo.typed == "Thanks for the update. I will send the report")
        #expect(demo.ghost == " by Friday.")
        demo.apply(.acceptWord); demo.apply(.acceptWord)
        #expect(demo.typed == "Thanks for the update. I will send the report by Friday.")
        #expect(demo.ghost == "")
        #expect(demo.isDone)
    }

    @Test func acceptAllTakesTheRest() {
        var demo = TabDemo()
        demo.apply(.acceptWord)
        demo.apply(.acceptAll)
        #expect(demo.ghost == "")
        #expect(demo.isDone)
    }

    @Test func dismissAndAnUnboundKeyChangeNothing() {
        var demo = TabDemo()
        demo.apply(.dismiss)
        demo.apply(nil)
        #expect(demo.ghost == " report by Friday.")
    }

    @Test func restartShowsTheGhostAgain() {
        var demo = TabDemo()
        demo.apply(.acceptAll)
        demo.restart()
        #expect(demo.ghost == " report by Friday.")
    }
}

@Suite("ModelDiskCheck")
struct ModelDiskCheckTests {
    private let gib: Int64 = 1_073_741_824

    @Test func enoughWhenFreeSpaceCoversTheDownloadPlusOneGigabyte() {
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 0,
                                       freeBytes: 3_438_534_656 + gib) == .enough)
    }

    @Test func tooSmallOneByteShortOfTheHeadroom() {
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 0,
                                       freeBytes: 3_438_534_656 + gib - 1)
                == .tooSmall(neededBytes: 4_512_276_480, freeBytes: 4_512_276_479))
    }

    @Test func bytesAlreadyInTheCacheAreNotNeededAgain() {
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 3_438_534_656,
                                       freeBytes: 2 * gib) == .enough)
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 5_000_000_000,
                                       freeBytes: gib - 1) == .enough)
    }

    @Test func aFullyCachedModelLoadsWithNoFreeSpaceAtAll() {
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 3_438_534_656,
                                       freeBytes: 0) == .enough)
    }

    @Test func aPartlyCachedModelStillNeedsTheRestPlusHeadroom() {
        #expect(ModelDiskCheck.verdict(downloadBytes: 3_438_534_656, cachedBytes: 3_438_534_656 - 100,
                                       freeBytes: gib) == .tooSmall(neededBytes: gib + 100, freeBytes: gib))
    }

    @Test func theMessageNamesNeededAndFreeSpace() {
        let verdict = ModelDiskVerdict.tooSmall(neededBytes: 4_512_276_480, freeBytes: 2_254_857_830)
        #expect(verdict.message
                == "Not enough free disk space. The model needs 4.2 GB and this Mac has 2.1 GB free. Free up space, then press Retry.")
        #expect(ModelDiskVerdict.enough.message == nil)
    }

    @Test func theShippingModelsHaveAKnownDownloadSize() {
        #expect(ShippingModel.downloadBytes(repoId: "Robin1333k/Qwen3.5-4B-Base-MLX-6bit") == 3_438_534_656)
        #expect(ShippingModel.downloadBytes(repoId: "Robin1333k/Qwen3.5-2B-Base-MLX-6bit") == 1_549_799_424)
        #expect(ShippingModel.downloadBytes(repoId: "someone/other-model") == nil)
    }
}

@Suite("ModelDownloadProgressLine")
struct ModelDownloadProgressLineTests {
    @Test func belowOneGigabyteCountsWholeMegabytes() {
        #expect(ModelDownloadProgressLine.line(fraction: 0.25, totalBytes: 3_438_534_656) == "820 MB of 3.2 GB")
    }

    @Test func fromOneGigabyteUsesOneDecimal() {
        #expect(ModelDownloadProgressLine.line(fraction: 0.5, totalBytes: 3_438_534_656) == "1.6 GB of 3.2 GB")
        #expect(ModelDownloadProgressLine.line(fraction: 1, totalBytes: 3_438_534_656) == "3.2 GB of 3.2 GB")
    }

    @Test func theSizeLabelNamesTheDownloadAlone() {
        #expect(ModelDownloadProgressLine.sizeLabel(totalBytes: 3_438_534_656) == "3.2 GB")
    }

    @Test func aFractionOutsideZeroToOneIsClamped() {
        #expect(ModelDownloadProgressLine.line(fraction: -0.1, totalBytes: 3_438_534_656) == "0 MB of 3.2 GB")
        #expect(ModelDownloadProgressLine.line(fraction: 1.4, totalBytes: 3_438_534_656) == "3.2 GB of 3.2 GB")
    }
}
