//
//  AIProvider.swift
//  leanring-buddy
//
//  Unified interface for AI providers (Anthropic, OpenAI, Ollama).
//  Each provider implements this protocol so the rest of the app
//  can swap providers without changing call sites.
//

import Foundation

enum AIProviderChunk {
    case textDelta(String)
    case done
    case error(Error)
}

struct AIProviderMessage {
    enum Role {
        case user
        case assistant
        case system
    }

    let role: Role
    let text: String
    let images: [Data]?
}

protocol AIProvider {
    var id: String { get }
    var displayName: String { get }
    var supportsVision: Bool { get }

    func isConfigured() async -> Bool

    func streamChat(
        messages: [AIProviderMessage],
        systemPrompt: String?,
        model: String
    ) -> AsyncThrowingStream<AIProviderChunk, Error>
}
