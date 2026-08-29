import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct CompanionSleepPolicyTests {
    @Test
    func automaticSleepStartsAtTheConfiguredThreshold() {
        let inactivityDuration: TimeInterval = 900

        #expect(
            !CompanionSleepPolicy.shouldRequestAutomaticSleep(
                isEnabled: true,
                systemIdleDuration: inactivityDuration - 0.01,
                inactivityDuration: inactivityDuration
            )
        )
        #expect(
            CompanionSleepPolicy.shouldRequestAutomaticSleep(
                isEnabled: true,
                systemIdleDuration: inactivityDuration,
                inactivityDuration: inactivityDuration
            )
        )
    }

    @Test
    func disabledAutomaticSleepNeverRequestsSuspension() {
        #expect(
            !CompanionSleepPolicy.shouldRequestAutomaticSleep(
                isEnabled: false,
                systemIdleDuration: 10_000,
                inactivityDuration: 900
            )
        )
    }

    @Test
    func dozeStartsAtTheConfiguredMeaningfulActivityThreshold() {
        let dozeInactivityDuration: TimeInterval = 60

        #expect(
            !CompanionSleepPolicy.hasReachedDozeThreshold(
                meaningfulSatoInactivityDuration: dozeInactivityDuration - 0.01,
                dozeInactivityDuration: dozeInactivityDuration
            )
        )
        #expect(
            CompanionSleepPolicy.hasReachedDozeThreshold(
                meaningfulSatoInactivityDuration: dozeInactivityDuration,
                dozeInactivityDuration: dozeInactivityDuration
            )
        )
    }

    @Test
    func dozeEvaluationWaitsForTheRemainingInactivityDuration() {
        #expect(
            CompanionSleepPolicy.nextDozeEvaluationDelay(
                meaningfulSatoInactivityDuration: 25,
                dozeInactivityDuration: 60,
                canDozeNow: false,
                blockedRetryDuration: 30
            ) == 35
        )
    }

    @Test
    func blockedDozeEvaluationRetriesAfterTheThreshold() {
        #expect(
            CompanionSleepPolicy.nextDozeEvaluationDelay(
                meaningfulSatoInactivityDuration: 60,
                dozeInactivityDuration: 60,
                canDozeNow: false,
                blockedRetryDuration: 30
            ) == 30
        )
    }

    @Test
    func eligibleDozeEvaluationRunsImmediatelyAfterTheThreshold() {
        #expect(
            CompanionSleepPolicy.nextDozeEvaluationDelay(
                meaningfulSatoInactivityDuration: 75,
                dozeInactivityDuration: 60,
                canDozeNow: true,
                blockedRetryDuration: 30
            ) == nil
        )
    }

    @Test
    func quiescentNormalOverlayCanDoze() {
        #expect(canDozeVisualRuntime())
    }

    @Test
    func activeOrUnavailableVisualRuntimeCannotDoze() {
        #expect(!canDozeVisualRuntime(isAutomaticSleepEnabled: false))
        #expect(!canDozeVisualRuntime(isNormalOverlayVisible: false))
        #expect(!canDozeVisualRuntime(isVisualRuntimePaused: true))
        #expect(!canDozeVisualRuntime(isMenuBarPanelVisible: true))
        #expect(!canDozeVisualRuntime(assistFlowIsInactive: false))
        #expect(!canDozeVisualRuntime(isResponseStreaming: true))
        #expect(!canDozeVisualRuntime(isChatStreaming: true))
        #expect(!canDozeVisualRuntime(isCapturingScreenshot: true))
        #expect(!canDozeVisualRuntime(isRequestingScreenContent: true))
        #expect(!canDozeVisualRuntime(isSpeechInputBusy: true))
        #expect(!canDozeVisualRuntime(isOnboardingVisible: true))
        #expect(!canDozeVisualRuntime(isOnboardingAudioPlaying: true))
        #expect(!canDozeVisualRuntime(isSpriteResting: false))
    }

    @Test
    func lifecyclePauseRemainsUntilTheLastReasonIsRemoved() {
        #expect(
            CompanionSleepPolicy.shouldRemainPausedForLifecycle(
                activeLifecycleSuspensionReasonCount: 2
            )
        )
        #expect(
            CompanionSleepPolicy.shouldRemainPausedForLifecycle(
                activeLifecycleSuspensionReasonCount: 1
            )
        )
        #expect(
            !CompanionSleepPolicy.shouldRemainPausedForLifecycle(
                activeLifecycleSuspensionReasonCount: 0
            )
        )
    }

    @Test
    func fullyGrantedPermissionsRestoreTheOverlayOnlyAfterManagerStartup() {
        #expect(
            CompanionSleepPolicy.shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(
                managerHasFinishedStarting: true,
                previouslyHadAllPermissions: false,
                hasCompletedOnboarding: true,
                allPermissionsGranted: true,
                isOverlayVisible: false,
                isStealthModeEnabled: false,
                isSleeping: false
            )
        )
        #expect(
            !CompanionSleepPolicy.shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(
                managerHasFinishedStarting: false,
                previouslyHadAllPermissions: false,
                hasCompletedOnboarding: true,
                allPermissionsGranted: true,
                isOverlayVisible: false,
                isStealthModeEnabled: false,
                isSleeping: false
            )
        )
    }

    @Test
    func unavailableOrExistingRuntimeDoesNotRestoreAfterPermissionGrant() {
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(hasCompletedOnboarding: false))
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(previouslyHadAllPermissions: true))
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(allPermissionsGranted: false))
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(isOverlayVisible: true))
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(isStealthModeEnabled: true))
        #expect(!shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(isSleeping: true))
    }

    @Test
    func quiescentVisualRuntimeCanSleep() {
        #expect(canSuspendVisualRuntime())
    }

    @Test
    func pendingLifecycleResumeIntentBlocksAutomaticDeepSleep() {
        #expect(!canSuspendVisualRuntime(hasPendingLifecycleResumeIntent: true))
    }

    @Test
    func userActivitySurfacesBlockSleep() {
        #expect(!canSuspendVisualRuntime(isMenuBarPanelVisible: true))
        #expect(!canSuspendVisualRuntime(assistFlowIsInactive: false))
        #expect(!canSuspendVisualRuntime(isResponseStreaming: true))
        #expect(!canSuspendVisualRuntime(isChatStreaming: true))
        #expect(!canSuspendVisualRuntime(isCapturingScreenshot: true))
        #expect(!canSuspendVisualRuntime(isRequestingScreenContent: true))
        #expect(!canSuspendVisualRuntime(isSpeechInputBusy: true))
        #expect(!canSuspendVisualRuntime(isOnboardingVisible: true))
        #expect(!canSuspendVisualRuntime(isOnboardingAudioPlaying: true))
        #expect(!canSuspendVisualRuntime(isSpriteResting: false))
    }

    private func canSuspendVisualRuntime(
        isMenuBarPanelVisible: Bool = false,
        assistFlowIsInactive: Bool = true,
        isResponseStreaming: Bool = false,
        isChatStreaming: Bool = false,
        isCapturingScreenshot: Bool = false,
        isRequestingScreenContent: Bool = false,
        isSpeechInputBusy: Bool = false,
        isOnboardingVisible: Bool = false,
        isOnboardingAudioPlaying: Bool = false,
        hasPendingLifecycleResumeIntent: Bool = false,
        isSpriteResting: Bool = true
    ) -> Bool {
        CompanionSleepPolicy.canSuspendVisualRuntime(
            hasCompletedOnboarding: true,
            allPermissionsGranted: true,
            isMenuBarPanelVisible: isMenuBarPanelVisible,
            assistFlowIsInactive: assistFlowIsInactive,
            isResponseStreaming: isResponseStreaming,
            isChatStreaming: isChatStreaming,
            isCapturingScreenshot: isCapturingScreenshot,
            isRequestingScreenContent: isRequestingScreenContent,
            isSpeechInputBusy: isSpeechInputBusy,
            isOnboardingVisible: isOnboardingVisible,
            isOnboardingAudioPlaying: isOnboardingAudioPlaying,
            hasPendingLifecycleResumeIntent: hasPendingLifecycleResumeIntent,
            isSpriteResting: isSpriteResting
        )
    }

    private func shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(
        previouslyHadAllPermissions: Bool = false,
        hasCompletedOnboarding: Bool = true,
        allPermissionsGranted: Bool = true,
        isOverlayVisible: Bool = false,
        isStealthModeEnabled: Bool = false,
        isSleeping: Bool = false
    ) -> Bool {
        CompanionSleepPolicy.shouldRestoreNormalOverlayAfterPermissionsBecomeFullyGranted(
            managerHasFinishedStarting: true,
            previouslyHadAllPermissions: previouslyHadAllPermissions,
            hasCompletedOnboarding: hasCompletedOnboarding,
            allPermissionsGranted: allPermissionsGranted,
            isOverlayVisible: isOverlayVisible,
            isStealthModeEnabled: isStealthModeEnabled,
            isSleeping: isSleeping
        )
    }

    private func canDozeVisualRuntime(
        isAutomaticSleepEnabled: Bool = true,
        isNormalOverlayVisible: Bool = true,
        isVisualRuntimePaused: Bool = false,
        isMenuBarPanelVisible: Bool = false,
        assistFlowIsInactive: Bool = true,
        isResponseStreaming: Bool = false,
        isChatStreaming: Bool = false,
        isCapturingScreenshot: Bool = false,
        isRequestingScreenContent: Bool = false,
        isSpeechInputBusy: Bool = false,
        isOnboardingVisible: Bool = false,
        isOnboardingAudioPlaying: Bool = false,
        isSpriteResting: Bool = true
    ) -> Bool {
        CompanionSleepPolicy.canDozeVisualRuntime(
            isAutomaticSleepEnabled: isAutomaticSleepEnabled,
            isNormalOverlayVisible: isNormalOverlayVisible,
            isVisualRuntimePaused: isVisualRuntimePaused,
            isMenuBarPanelVisible: isMenuBarPanelVisible,
            assistFlowIsInactive: assistFlowIsInactive,
            isResponseStreaming: isResponseStreaming,
            isChatStreaming: isChatStreaming,
            isCapturingScreenshot: isCapturingScreenshot,
            isRequestingScreenContent: isRequestingScreenContent,
            isSpeechInputBusy: isSpeechInputBusy,
            isOnboardingVisible: isOnboardingVisible,
            isOnboardingAudioPlaying: isOnboardingAudioPlaying,
            isSpriteResting: isSpriteResting
        )
    }
}
