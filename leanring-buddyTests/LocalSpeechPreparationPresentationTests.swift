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

    @Test func selectedReadyModelRequestsUndeterminedMicrophonePermission() {
        #expect(
            LocalSpeechTranscriptionManager.shouldRequestMicrophonePermissionAfterModelPreparation(
                preparedSpeechModel: .fast,
                selectedSpeechModel: .fast,
                microphonePermission: .notDetermined
            )
        )
        #expect(
            !LocalSpeechTranscriptionManager.shouldRequestMicrophonePermissionAfterModelPreparation(
                preparedSpeechModel: .fast,
                selectedSpeechModel: .accurate,
                microphonePermission: .notDetermined
            )
        )
        #expect(
            !LocalSpeechTranscriptionManager.shouldRequestMicrophonePermissionAfterModelPreparation(
                preparedSpeechModel: .fast,
                selectedSpeechModel: .fast,
                microphonePermission: .authorized
            )
        )
    }

    @Test func readyModelStatusExplainsMicrophonePermissionRecovery() {
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionStatusMessage(
                for: .notDetermined
            ) == "Allow microphone access to use Sato Local."
        )
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionStatusMessage(
                for: .authorized
            ) == nil
        )
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionStatusMessage(
                for: .denied
            ) == "Microphone access is off. Enable it in System Settings."
        )
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionStatusMessage(
                for: .restricted
            ) == "Microphone access is restricted on this Mac."
        )
    }

    @Test func unresolvedMicrophoneRequestHasVisibleRecoveryMessage() {
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionRequestFailureMessage(
                accessWasGranted: false,
                microphonePermissionAfterRequest: .notDetermined
            ) == "macOS couldn’t open the microphone permission prompt. Quit and reopen Sato, then try again."
        )
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionRequestFailureMessage(
                accessWasGranted: false,
                microphonePermissionAfterRequest: .denied
            ) == nil
        )
        #expect(
            LocalSpeechTranscriptionManager.microphonePermissionRequestFailureMessage(
                accessWasGranted: true,
                microphonePermissionAfterRequest: .authorized
            ) == nil
        )
    }

    @Test func hardenedRuntimeBuildDeclaresAudioInputEntitlement() throws {
        let repositoryRootURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = repositoryRootURL
            .appendingPathComponent("leanring-buddy", isDirectory: true)
            .appendingPathComponent("leanring-buddy.entitlements")
        let entitlementsData = try Data(contentsOf: entitlementsURL)
        let entitlements = try PropertyListSerialization.propertyList(
            from: entitlementsData,
            format: nil
        ) as? [String: Any]

        #expect(entitlements?["com.apple.security.device.audio-input"] as? Bool == true)
    }
}
