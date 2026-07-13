//
//  ProviderManager.swift
//  leanring-buddy
//
//  Centralized manager for the active AI provider and model selection.
//  Loads the user's choice from UserDefaults, instantiates the correct
//  provider, and exposes a single `currentProvider` + `currentModelID`
//  for the rest of the app.
//

import Combine
import Foundation

@MainActor
final class ProviderManager: ObservableObject {

    // MARK: - Published State

    @Published var selectedProviderID: String {
        didSet { UserDefaults.standard.set(selectedProviderID, forKey: "selectedProvider") }
    }

    @Published var anthropicModelID: String {
        didSet { UserDefaults.standard.set(anthropicModelID, forKey: "anthropicModel") }
    }

    @Published var openAIModelID: String {
        didSet { UserDefaults.standard.set(openAIModelID, forKey: "openAIModel") }
    }

    @Published var ollamaLocalModelName: String {
        didSet { UserDefaults.standard.set(ollamaLocalModelName, forKey: "ollamaLocalModel") }
    }

    @Published var ollamaCloudModelName: String {
        didSet { UserDefaults.standard.set(ollamaCloudModelName, forKey: "ollamaCloudModel") }
    }

    @Published var ollamaLocalModels: [OllamaModelInfo] = []
    @Published var ollamaLocalIsReachable: Bool = false

    // MARK: - Provider Instances

    let anthropicProvider = AnthropicProvider()
    let openAIProvider = OpenAIProvider()
    let ollamaLocalProvider = OllamaLocalProvider()
    let ollamaCloudProvider = OllamaCloudProvider()

    // MARK: - Computed

    var currentProvider: AIProvider {
        switch selectedProviderID {
        case "openai": return openAIProvider
        case "ollama-local": return ollamaLocalProvider
        case "ollama-cloud": return ollamaCloudProvider
        default: return anthropicProvider
        }
    }

    var currentModelID: String {
        switch selectedProviderID {
        case "openai": return openAIModelID
        case "ollama-local": return ollamaLocalModelName
        case "ollama-cloud": return ollamaCloudModelName
        default: return anthropicModelID
        }
    }

    var currentProviderSupportsVision: Bool {
        currentProvider.supportsVision
    }

    // MARK: - Init

    init() {
        let savedOpenAIModelID = UserDefaults.standard.string(forKey: "openAIModel")
        self.selectedProviderID = UserDefaults.standard.string(forKey: "selectedProvider") ?? "anthropic"
        self.anthropicModelID = UserDefaults.standard.string(forKey: "anthropicModel") ?? AnthropicProvider.defaultModelID
        self.openAIModelID = OpenAIProvider.resolvedModelID(savedOpenAIModelID)
        self.ollamaLocalModelName = UserDefaults.standard.string(forKey: "ollamaLocalModel") ?? ""
        self.ollamaCloudModelName = UserDefaults.standard.string(forKey: "ollamaCloudModel") ?? OllamaCloudProvider.defaultModelID

        // Migrate from the old single-model UserDefaults key if the user
        // has never picked a provider (first launch after update)
        if UserDefaults.standard.string(forKey: "selectedProvider") == nil {
            if let legacyModel = UserDefaults.standard.string(forKey: "selectedClaudeModel") {
                anthropicModelID = legacyModel
            }
        }

        if ollamaCloudModelName == "qwen3-vl-cloud" {
            ollamaCloudModelName = OllamaCloudProvider.defaultModelID
        }

        if savedOpenAIModelID != openAIModelID {
            UserDefaults.standard.set(openAIModelID, forKey: "openAIModel")
        }
    }

    // MARK: - Provider for Context Profile Overrides

    func provider(forProviderID providerID: String) -> AIProvider {
        switch providerID {
        case "openai": return openAIProvider
        case "ollama-local": return ollamaLocalProvider
        case "ollama-cloud": return ollamaCloudProvider
        default: return anthropicProvider
        }
    }

    func resolveProviderAndModel(overrideProviderID: String?, overrideModelID: String?) -> (provider: AIProvider, modelID: String) {
        guard let overrideProviderID, let overrideModelID else {
            return (currentProvider, currentModelID)
        }

        let overrideProvider = provider(forProviderID: overrideProviderID)
        let resolvedOverrideModelID = overrideProviderID == "openai"
            ? OpenAIProvider.resolvedModelID(overrideModelID)
            : overrideModelID
        return (overrideProvider, resolvedOverrideModelID)
    }

    // MARK: - Ollama Local Discovery

    func refreshOllamaLocalStatus() {
        Task {
            let reachable = await ollamaLocalProvider.isOllamaReachable()
            ollamaLocalIsReachable = reachable

            if reachable {
                do {
                    let models = try await ollamaLocalProvider.fetchInstalledModels()
                    ollamaLocalModels = models
                } catch {
                    print("⚠️ Failed to fetch Ollama models: \(error)")
                    ollamaLocalModels = []
                }
            } else {
                ollamaLocalModels = []
            }
        }
    }

    // MARK: - Streaming Helper

    func streamChat(
        messages: [AIProviderMessage],
        systemPrompt: String?,
        overrideProviderID: String? = nil,
        overrideModelID: String? = nil,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let (resolvedProvider, resolvedModelID) = resolveProviderAndModel(
            overrideProviderID: overrideProviderID,
            overrideModelID: overrideModelID
        )

        // Update OllamaLocalProvider's selected model if that's what we're using
        if let ollamaLocal = resolvedProvider as? OllamaLocalProvider {
            let supportsVision = ollamaLocalModels.first(where: { $0.name == resolvedModelID })?.supportsVision ?? false
            ollamaLocal.updateSelectedModel(name: resolvedModelID, supportsVision: supportsVision)
        }

        var accumulatedText = ""
        let stream = resolvedProvider.streamChat(
            messages: messages,
            systemPrompt: systemPrompt,
            model: resolvedModelID
        )

        for try await chunk in stream {
            switch chunk {
            case .textDelta(let delta):
                accumulatedText += delta
                let currentText = accumulatedText
                await onTextChunk(currentText)
            case .done:
                break
            case .error(let error):
                throw error
            }
        }

        return accumulatedText
    }
}
