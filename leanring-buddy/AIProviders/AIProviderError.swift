//
//  AIProviderError.swift
//  leanring-buddy
//
//  Shared error types for all AI providers.
//

import Foundation

enum AIProviderError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidResponse
    case apiError(provider: String, statusCode: Int, message: String)
    case providerUnavailable(provider: String, reason: String)
    case modelDoesNotSupportVision(modelName: String)
    case quotaExceeded(provider: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key configured for \(provider). Open the menu bar panel to add one."
        case .invalidResponse:
            return "Invalid HTTP response from the AI provider."
        case .apiError(let provider, let statusCode, let message):
            var guidance = "\(provider) API error (\(statusCode)): \(message)"
            if provider == "OpenAI" && (statusCode == 401 || statusCode == 403) {
                guidance += "\n\nCheck your API key at platform.openai.com/api-keys"
            } else if provider == "Ollama Cloud" && (statusCode == 401 || statusCode == 403) {
                guidance += "\n\nCheck your API key at ollama.com/settings/keys"
            }
            return guidance
        case .providerUnavailable(let provider, let reason):
            return "\(provider) is unavailable: \(reason)"
        case .modelDoesNotSupportVision(let modelName):
            return "\(modelName) does not support vision. Text-only responses will be used."
        case .quotaExceeded(let provider):
            if provider == "OpenAI" {
                return "OpenAI account has no credits remaining — add funds at platform.openai.com/billing"
            }
            return "\(provider) account has no credits remaining."
        }
    }
}
