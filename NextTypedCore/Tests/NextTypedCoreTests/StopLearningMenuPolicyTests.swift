import Testing
@testable import NextTypedCore

@Suite struct StopLearningMenuPolicyTests {
    @Test func hiddenWhenLearningIsOffAndNoProfileFileExists() {
        #expect(!StopLearningMenuPolicy.isVisible(personalizationEnabled: false, profileFileExists: false))
    }

    @Test func shownWhileLearningIsOnBeforeAnyFileExists() {
        #expect(StopLearningMenuPolicy.isVisible(personalizationEnabled: true, profileFileExists: false))
    }

    /// The file may be undecryptable (lost key). The App passes only file existence, so such a profile
    /// is offered for deletion too.
    @Test func shownForAProfileFileAfterLearningWasSwitchedOff() {
        #expect(StopLearningMenuPolicy.isVisible(personalizationEnabled: false, profileFileExists: true))
    }

    @Test func shownWhenLearningIsOnAndAFileExists() {
        #expect(StopLearningMenuPolicy.isVisible(personalizationEnabled: true, profileFileExists: true))
    }
}
