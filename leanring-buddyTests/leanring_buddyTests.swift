//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func removedOpenAIModelsMigrateToLuna() {
        #expect(
            OpenAIProvider.resolvedModelID("gpt-5.4-2026-03-05")
                == "gpt-6-luna"
        )
        #expect(
            OpenAIProvider.resolvedModelID("gpt-5.6-luna")
                == "gpt-6-luna"
        )
        #expect(
            OpenAIProvider.resolvedModelID("gpt-5.6-terra")
                == "gpt-5.6-terra"
        )
    }

    @Test func removedAnthropicModelsMigrateToTheirReplacements() {
        #expect(AnthropicProvider.resolvedModelID("claude-haiku-4-5") == "claude-haiku-5-5")
        #expect(AnthropicProvider.resolvedModelID("claude-opus-4-7") == "claude-opus-4-7")
        #expect(AnthropicProvider.resolvedModelID("claude-unknown-model") == AnthropicProvider.defaultModelID)
        #expect(AnthropicProvider.resolvedModelID(nil) == AnthropicProvider.defaultModelID)
    }

    @Test func effortLevelsMatchEachModel() {
        let providerManager = ProviderManager()

        let sonnetEffortLevels = providerManager
            .reasoningEffortOptions(providerID: "anthropic", modelID: "claude-sonnet-4-6")?
            .levels
            .map(\.apiValue)
        #expect(sonnetEffortLevels == ["low", "medium", "high", "max"])

        let haikuEffortLevels = providerManager
            .reasoningEffortOptions(providerID: "anthropic", modelID: "claude-haiku-5-5")?
            .levels
            .map(\.apiValue)
        #expect(haikuEffortLevels == ["low", "medium", "high", "xhigh", "max"])

        let lunaEffortLevels = providerManager
            .reasoningEffortOptions(providerID: "openai", modelID: "gpt-6-luna")?
            .levels
            .map(\.apiValue)
        #expect(lunaEffortLevels == ["none", "low", "medium", "high", "xhigh", "max"])
    }

    @Test func ollamaThinkingModelsGetMatchingEffortControls() {
        let gptOSSModel = OllamaModelInfo(name: "gpt-oss:20b", sizeInBytes: 0, supportsVision: false, supportsThinking: true)
        let qwenThinkingModel = OllamaModelInfo(name: "qwen3:8b", sizeInBytes: 0, supportsVision: false, supportsThinking: true)
        let nonThinkingModel = OllamaModelInfo(name: "llava:7b", sizeInBytes: 0, supportsVision: true, supportsThinking: false)

        #expect(OllamaLocalProvider.effortOptions(for: gptOSSModel)?.levels.map(\.apiValue) == ["low", "medium", "high"])
        #expect(OllamaLocalProvider.effortOptions(for: qwenThinkingModel)?.levels.map(\.apiValue) == ["off", "on"])
        #expect(OllamaLocalProvider.effortOptions(for: nonThinkingModel) == nil)
        #expect(OllamaLocalProvider.thinkParameterValue(forReasoningEffort: "off") as? Bool == false)
        #expect(OllamaLocalProvider.thinkParameterValue(forReasoningEffort: "high") as? String == "high")
    }

}
