//
//  OllamaCloudProvider.swift
//  leanring-buddy
//
//  AIProvider implementation for Ollama Cloud (https://ollama.com).
//  Same API shape as local Ollama but requires Bearer token auth.
//

import Foundation

final class OllamaCloudProvider: AIProvider {
    let id = "ollama-cloud"
    let displayName = "Ollama (Cloud)"
    let supportsVision = true

    struct CloudModel {
        let id: String
        let displayName: String
    }

    static let availableModels = [
        CloudModel(id: "qwen3-vl:235b-cloud", displayName: "Qwen3-VL 235B (Cloud)"),
    ]

    static let defaultModelID = "qwen3-vl:235b-cloud"

    private let baseURL = URL(string: "https://ollama.com")!

    func isConfigured() async -> Bool {
        guard let key = KeychainHelper.loadAPIKey(for: .ollamaCloud) else { return false }
        return !key.isEmpty
    }

    func streamChat(
        messages: [AIProviderMessage],
        systemPrompt: String?,
        model: String
    ) -> AsyncThrowingStream<AIProviderChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.loadAPIKey(for: .ollamaCloud), !apiKey.isEmpty else {
                        continuation.yield(.error(AIProviderError.missingAPIKey(provider: "Ollama Cloud")))
                        continuation.finish()
                        return
                    }

                    let url = self.baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var ollamaMessages: [[String: Any]] = []

                    if let systemPrompt, !systemPrompt.isEmpty {
                        ollamaMessages.append(["role": "system", "content": systemPrompt])
                    }

                    for message in messages {
                        switch message.role {
                        case .system:
                            ollamaMessages.append(["role": "system", "content": message.text])
                        case .user:
                            var messageDict: [String: Any] = ["role": "user", "content": message.text]
                            if let images = message.images, !images.isEmpty {
                                messageDict["images"] = images.map { $0.base64EncodedString() }
                            }
                            ollamaMessages.append(messageDict)
                        case .assistant:
                            ollamaMessages.append(["role": "assistant", "content": message.text])
                        }
                    }

                    let modelToUse = model.isEmpty ? Self.defaultModelID : model
                    let body: [String: Any] = [
                        "model": modelToUse,
                        "messages": ollamaMessages,
                        "stream": true,
                    ]

                    let bodyData = try JSONSerialization.data(withJSONObject: body)
                    request.httpBody = bodyData

                    print("🌐 Ollama Cloud streaming request, model: \(modelToUse)")

                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 120
                    config.timeoutIntervalForResource = 300
                    config.urlCache = nil
                    let session = URLSession(configuration: config)

                    let (byteStream, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.yield(.error(AIProviderError.invalidResponse))
                        continuation.finish()
                        return
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        var errorBodyChunks: [String] = []
                        for try await line in byteStream.lines {
                            errorBodyChunks.append(line)
                        }
                        let errorBody = errorBodyChunks.joined(separator: "\n")
                        continuation.yield(.error(AIProviderError.apiError(
                            provider: "Ollama Cloud",
                            statusCode: httpResponse.statusCode,
                            message: errorBody
                        )))
                        continuation.finish()
                        return
                    }

                    // NDJSON streaming — same format as local Ollama
                    for try await line in byteStream.lines {
                        guard !line.isEmpty,
                              let lineData = line.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                        else {
                            continue
                        }

                        if let messageDict = chunk["message"] as? [String: Any],
                           let content = messageDict["content"] as? String,
                           !content.isEmpty
                        {
                            continuation.yield(.textDelta(content))
                        }

                        if let done = chunk["done"] as? Bool, done {
                            break
                        }
                    }

                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error))
                    continuation.finish()
                }
            }
        }
    }
}
