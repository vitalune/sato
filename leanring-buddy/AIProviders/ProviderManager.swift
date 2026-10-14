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

    /// The effort level the user picked for each model, keyed by
    /// `reasoningEffortKey(providerID:modelID:)`. Effort is remembered per
    /// model because each model supports different levels.
    @Published private var savedReasoningEffortByModelKey: [String: String] {
        didSet {
            UserDefaults.standard.set(
                savedReasoningEffortByModelKey,
                forKey: Self.reasoningEffortUserDefaultsKey
            )
        }
    }

    private static let reasoningEffortUserDefaultsKey = "reasoningEffortByModel"

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

    /// Effort levels for the model selected in the panel, or nil when that
    /// model has no effort control.
    var currentReasoningEffortOptions: ReasoningEffortOptions? {
        reasoningEffortOptions(providerID: selectedProviderID, modelID: currentModelID)
    }

    var currentReasoningEffortLevel: ReasoningEffortLevel? {
        selectedReasoningEffortLevel(providerID: selectedProviderID, modelID: currentModelID)
    }

    func setCurrentReasoningEffortLevel(_ reasoningEffortLevel: ReasoningEffortLevel) {
        savedReasoningEffortByModelKey[
            Self.reasoningEffortKey(providerID: selectedProviderID, modelID: currentModelID)
        ] = reasoningEffortLevel.apiValue
    }

    // MARK: - Init

    init() {
        let savedOpenAIModelID = UserDefaults.standard.string(forKey: "openAIModel")
        let savedAnthropicModelID = UserDefaults.standard.string(forKey: "anthropicModel")
        self.selectedProviderID = UserDefaults.standard.string(forKey: "selectedProvider") ?? "anthropic"
        self.anthropicModelID = AnthropicProvider.resolvedModelID(savedAnthropicModelID)
        self.openAIModelID = OpenAIProvider.resolvedModelID(savedOpenAIModelID)
        self.ollamaLocalModelName = UserDefaults.standard.string(forKey: "ollamaLocalModel") ?? ""
        self.ollamaCloudModelName = UserDefaults.standard.string(forKey: "ollamaCloudModel") ?? OllamaCloudProvider.defaultModelID
        self.savedReasoningEffortByModelKey = UserDefaults.standard.dictionary(
            forKey: Self.reasoningEffortUserDefaultsKey
        ) as? [String: String] ?? [:]

        // Migrate from the old single-model UserDefaults key if the user
        // has never picked a provider (first launch after update)
        if UserDefaults.standard.string(forKey: "selectedProvider") == nil {
            if let legacyModel = UserDefaults.standard.string(forKey: "selectedClaudeModel") {
                anthropicModelID = AnthropicProvider.resolvedModelID(legacyModel)
            }
        }

        if ollamaCloudModelName == "qwen3-vl-cloud" {
            ollamaCloudModelName = OllamaCloudProvider.defaultModelID
        }

        if savedOpenAIModelID != openAIModelID {
            UserDefaults.standard.set(openAIModelID, forKey: "openAIModel")
        }

        if savedAnthropicModelID != anthropicModelID {
            UserDefaults.standard.set(anthropicModelID, forKey: "anthropicModel")
        }
    }

    // MARK: - Reasoning Effort

    private static func reasoningEffortKey(providerID: String, modelID: String) -> String {
        "\(providerID)|\(modelID)"
    }

    /// The effort levels a specific model supports, or nil when the model
    /// has no effort control.
    func reasoningEffortOptions(providerID: String, modelID: String) -> ReasoningEffortOptions? {
        switch providerID {
        case "openai":
            let resolvedOpenAIModelID = OpenAIProvider.resolvedModelID(modelID)
            return OpenAIProvider.availableModels
                .first { $0.id == resolvedOpenAIModelID }?
                .effortOptions
        case "ollama-local":
            guard let installedModel = ollamaLocalModels.first(where: { $0.name == modelID }) else {
                return nil
            }
            return OllamaLocalProvider.effortOptions(for: installedModel)
        case "ollama-cloud":
            return nil
        default:
            let resolvedAnthropicModelID = AnthropicProvider.resolvedModelID(modelID)
            return AnthropicProvider.availableModels
                .first { $0.id == resolvedAnthropicModelID }?
                .effortOptions
        }
    }

    /// The saved effort level for a model, falling back to the model's
    /// default when the user has not picked one.
    func selectedReasoningEffortLevel(providerID: String, modelID: String) -> ReasoningEffortLevel? {
        guard let effortOptions = reasoningEffortOptions(providerID: providerID, modelID: modelID) else {
            return nil
        }
        let savedAPIValue = savedReasoningEffortByModelKey[
            Self.reasoningEffortKey(providerID: providerID, modelID: modelID)
        ]
        return effortOptions.level(forSavedAPIValue: savedAPIValue)
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
        let resolvedOverrideModelID: String
        switch overrideProviderID {
        case "openai":
            resolvedOverrideModelID = OpenAIProvider.resolvedModelID(overrideModelID)
        case "anthropic":
            resolvedOverrideModelID = AnthropicProvider.resolvedModelID(overrideModelID)
        default:
            resolvedOverrideModelID = overrideModelID
        }
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

        // Effort is looked up for the model that will actually answer, so a
        // context profile's model override uses that model's own effort.
        let reasoningEffortLevel = selectedReasoningEffortLevel(
            providerID: resolvedProvider.id,
            modelID: resolvedModelID
        )

        var accumulatedText = ""
        let stream = resolvedProvider.streamChat(
            messages: messages,
            systemPrompt: systemPrompt,
            model: resolvedModelID,
            reasoningEffort: reasoningEffortLevel?.apiValue
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
