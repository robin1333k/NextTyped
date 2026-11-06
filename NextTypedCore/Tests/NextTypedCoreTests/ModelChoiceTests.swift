import Testing
@testable import NextTypedCore

@Suite struct ModelChoiceTests {
    private let dir4B = "Models/Qwen3.5-4B-Base-MLX-6bit"
    private let dir2B = "Models/Qwen3.5-2B-Base-MLX-6bit"

    // MARK: Stored value

    @Test func absentOrUnknownStoredValueReadsAsAutomatic() {
        #expect(ModelChoice(stored: nil) == .automatic)
        #expect(ModelChoice(stored: "") == .automatic)
        #expect(ModelChoice(stored: "8b") == .automatic)
    }

    @Test func storedValuesRoundTrip() {
        #expect(ModelChoice(stored: ModelChoice.qwen4B.rawValue) == .qwen4B)
        #expect(ModelChoice(stored: ModelChoice.qwen2B.rawValue) == .qwen2B)
        #expect(ModelChoice.qwen4B.rawValue == "4b")
        #expect(ModelChoice.qwen2B.rawValue == "2b")
    }

    // MARK: Plan (what loads)

    @Test func automaticKeepsTodaysFolderRuleAndThe4BHubDefault() {
        let plan = ShippingModel.plan(choice: .automatic)
        #expect(plan.candidates == [dir4B, dir2B])
        #expect(plan.hubRepoId == "Robin1333k/Qwen3.5-4B-Base-MLX-6bit")
        #expect(plan.hubRevision == "dd2480929d3e6ed72fc4f48f10b1ed05122e6489")
    }

    @Test func choosing4BTriesOnlyTheFolderOf4BThenDownloadsThe4B() {
        let plan = ShippingModel.plan(choice: .qwen4B)
        #expect(plan.candidates == [dir4B])
        #expect(plan.hubRepoId == "Robin1333k/Qwen3.5-4B-Base-MLX-6bit")
        #expect(plan.hubRevision == ShippingModel.hubRevision)
    }

    @Test func choosing2BTriesOnlyTheFolderOf2BThenDownloadsThePinned2B() {
        let plan = ShippingModel.plan(choice: .qwen2B)
        #expect(plan.candidates == [dir2B])
        #expect(plan.hubRepoId == "Robin1333k/Qwen3.5-2B-Base-MLX-6bit")
        #expect(plan.hubRevision == "608e41eb06e9e75a982944ffa843323c266e32a3")
    }

    @Test func modelDirectoryDeveloperKeyBeatsTheChoice() {
        let plan = ShippingModel.plan(choice: .qwen2B, directoryOverride: "/tmp/other")
        #expect(plan.candidates == ["/tmp/other"])
    }

    @Test func emptyDirectoryOverrideCountsAsUnset() {
        #expect(ShippingModel.plan(choice: .qwen2B, directoryOverride: "").candidates == [dir2B])
    }

    @Test func repoOverrideReadsMainOfThatRepoWhateverTheChoice() {
        let plan = ShippingModel.plan(choice: .qwen2B, repoIdOverride: "me/model")
        #expect(plan.hubRepoId == "me/model")
        #expect(plan.hubRevision == "main")
    }

    @Test func revisionOverrideAppliesToTheChosenRepo() {
        let plan = ShippingModel.plan(choice: .qwen2B, revisionOverride: "abc")
        #expect(plan.hubRepoId == "Robin1333k/Qwen3.5-2B-Base-MLX-6bit")
        #expect(plan.hubRevision == "abc")
    }

    // MARK: Labels follow the choice on the Hub path

    @Test func hubPathLabelNamesTheChosenModel() {
        #expect(ShippingModel.settingsLabel(localDirectory: nil, choice: .qwen2B)
                == "Qwen3.5-2B-Base · 6-bit (~1.5 GB)")
        #expect(ShippingModel.settingsLabel(localDirectory: nil, choice: .qwen4B)
                == "Qwen3.5-4B-Base · 6-bit (~3.2 GB)")
        #expect(ShippingModel.settingsLabel(localDirectory: nil, choice: .automatic)
                == "Qwen3.5-4B-Base · 6-bit (~3.2 GB)")
    }

    @Test func memoryFiguresOnTheHubPathFollowTheChoice() {
        #expect(ShippingModel.memoryFigures(localDirectory: nil, choice: .qwen2B).loaded == "1.6 GB")
        #expect(ShippingModel.memoryFigures(localDirectory: nil, choice: .qwen4B).loaded == "3.4 GB")
    }

    // MARK: Recommendation from installed RAM

    private let gb: UInt64 = 1_073_741_824

    @Test func recommends2BBelow16GB() {
        #expect(ModelChoice.recommended(physicalMemoryBytes: 8 * gb) == .qwen2B)
        #expect(ModelChoice.recommended(physicalMemoryBytes: 15 * gb) == .qwen2B)
    }

    @Test func recommends4BFrom16GB() {
        #expect(ModelChoice.recommended(physicalMemoryBytes: 16 * gb) == .qwen4B)
        #expect(ModelChoice.recommended(physicalMemoryBytes: 64 * gb) == .qwen4B)
    }

    @Test func recommendationLineNamesTheModelAndTheRam() {
        #expect(ModelChoice.recommendationLine(physicalMemoryBytes: 8 * gb)
                == "Recommended for this Mac (8 GB memory): Qwen3.5-2B-Base.")
        #expect(ModelChoice.recommendationLine(physicalMemoryBytes: 32 * gb)
                == "Recommended for this Mac (32 GB memory): Qwen3.5-4B-Base.")
    }

    @Test func pickerLabelsCarrySizes() {
        #expect(ModelChoice.automatic.pickerLabel == "Automatic")
        #expect(ModelChoice.qwen4B.pickerLabel == "Qwen3.5-4B-Base (3.2 GB download, 3.4 GB memory)")
        #expect(ModelChoice.qwen2B.pickerLabel == "Qwen3.5-2B-Base (1.5 GB download, 1.6 GB memory)")
    }
}

@Suite struct SingleFlightTests {
    actor Counter {
        var starts = 0
        func start() -> Int { starts += 1; return starts }
    }

    @Test func twoQuickCallersShareOneJob() async {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        let work: @Sendable () async -> Int = {
            let n = await counter.start()
            try? await Task.sleep(for: .milliseconds(100))
            return n
        }
        async let a = flight.run(work)
        async let b = flight.run(work)
        let (first, second) = await (a, b)
        #expect(first == 1)
        #expect(second == 1)
        #expect(await counter.starts == 1)
        #expect(await flight.isRunning == false)
    }

    @Test func aCallerAfterForgetStartsANewJob() async {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        let work: @Sendable () async -> Int = {
            let n = await counter.start()
            try? await Task.sleep(for: .milliseconds(100))
            return n
        }
        async let old = flight.run(work)
        try? await Task.sleep(for: .milliseconds(20))
        await flight.forget()
        async let fresh = flight.run(work)
        let (o, f) = await (old, fresh)
        #expect(o == 1)
        #expect(f == 2)
        #expect(await counter.starts == 2)
    }

    @Test func forgetCancelsTheJobInFlight() async {
        let flight = SingleFlight<Bool>()
        let work: @Sendable () async -> Bool = {
            // True when the sleep ran to the end, false when cancellation cut it short.
            (try? await Task.sleep(for: .seconds(5))) != nil
        }
        async let old = flight.run(work)
        try? await Task.sleep(for: .milliseconds(50))
        await flight.forget()
        #expect(await old == false)
    }

    @Test func aFinishedJobDoesNotBlockTheNextOne() async {
        let flight = SingleFlight<Int>()
        let counter = Counter()
        let work: @Sendable () async -> Int = { await counter.start() }
        #expect(await flight.run(work) == 1)
        #expect(await flight.run(work) == 2)
    }
}
