import Foundation
import Testing
@testable import leanring_buddy

struct LocalSpeechPreparationPresentationTests {
    @Test func preparationStagesHaveStableVisibleOrder() {
        #expect(LocalSpeechModelPreparationStage.verifyingModel.rawValue == 1)
        #expect(LocalSpeechModelPreparationStage.optimizingForMac.rawValue == 2)
        #expect(LocalSpeechModelPreparationStage.loadingSpeechEngine.rawValue == 3)
        #expect(LocalSpeechModelPreparationStage.totalStageCount == 3)
        #expect(LocalSpeechModelPreparationStage.verifyingModel.completedStageCount == 0)
        #expect(LocalSpeechModelPreparationStage.optimizingForMac.completedStageCount == 1)
        #expect(LocalSpeechModelPreparationStage.loadingSpeechEngine.completedStageCount == 2)
    }

    @Test func elapsedPreparationTimeUsesSecondsBeforeOneMinute() {
        let preparationStartedAt = Date(timeIntervalSince1970: 1_000)
        let currentDate = preparationStartedAt.addingTimeInterval(42)

        #expect(
            LocalSpeechTranscriptionManager.elapsedPreparationTimeText(
                since: preparationStartedAt,
                currentDate: currentDate
            ) == "42s elapsed"
        )
    }

    @Test func elapsedPreparationTimeUsesMinutesAndPaddedSeconds() {
        let preparationStartedAt = Date(timeIntervalSince1970: 1_000)
        let currentDate = preparationStartedAt.addingTimeInterval(248)

        #expect(
            LocalSpeechTranscriptionManager.elapsedPreparationTimeText(
                since: preparationStartedAt,
                currentDate: currentDate
            ) == "4m 08s elapsed"
        )
    }

    @Test func elapsedPreparationTimeNeverDisplaysNegativeTime() {
        let preparationStartedAt = Date(timeIntervalSince1970: 1_000)
        let currentDate = preparationStartedAt.addingTimeInterval(-5)

        #expect(
            LocalSpeechTranscriptionManager.elapsedPreparationTimeText(
                since: preparationStartedAt,
                currentDate: currentDate
            ) == "0s elapsed"
        )
    }

    @Test func modelPreparationHasATenMinuteSafetyTimeout() {
        #expect(LocalSpeechTranscriptionManager.modelPreparationTimeoutDuration == 600)
    }
}
