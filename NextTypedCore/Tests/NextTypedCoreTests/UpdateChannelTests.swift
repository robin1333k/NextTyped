import Testing
@testable import NextTypedCore

@Suite struct UpdateChannelTests {
    @Test func stableAllowsOnlyTheDefaultChannel() {
        #expect(UpdateChannel.stable.allowedSparkleChannels == [])
    }

    @Test func betaAllowsTheDefaultChannelAndBeta() {
        #expect(UpdateChannel.beta.allowedSparkleChannels == ["beta"])
    }

    @Test func storedValueRoundTrips() {
        #expect(UpdateChannel(storedValue: "beta") == .beta)
        #expect(UpdateChannel(storedValue: "stable") == .stable)
    }

    @Test func unknownOrMissingStoredValueIsStable() {
        #expect(UpdateChannel(storedValue: nil) == .stable)
        #expect(UpdateChannel(storedValue: "nightly") == .stable)
    }
}

@Suite struct UpdaterStartPolicyTests {
    @Test func startsInANormalLaunch() {
        #expect(UpdaterStartPolicy.decision(environment: [:]) == .start)
    }

    @Test func skipsUnderTheHarnessSocket() {
        #expect(UpdaterStartPolicy.decision(environment: ["NEXTTYPED_HARNESS_SOCKET": "/tmp/s.sock"])
                == .skip(reason: "harness"))
    }

    @Test func skipsWithTheFakeEngine() {
        #expect(UpdaterStartPolicy.decision(environment: ["NEXTTYPED_ENGINE": "fake"])
                == .skip(reason: "harness"))
    }

    @Test func startsWithTheRealEngineAndNoSocket() {
        #expect(UpdaterStartPolicy.decision(environment: ["NEXTTYPED_ENGINE": "real"]) == .start)
    }

    @Test func anEmptySocketVariableDoesNotCount() {
        #expect(UpdaterStartPolicy.decision(environment: ["NEXTTYPED_HARNESS_SOCKET": ""]) == .start)
    }
}
