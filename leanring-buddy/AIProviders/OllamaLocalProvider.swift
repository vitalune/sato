//
//  OllamaLocalProvider.swift
//  leanring-buddy
//
//  AIProvider implementation for local Ollama daemon (http://localhost:11434).
//  Uses NDJSON streaming via /api/chat. Dynamically discovers installed models.
//

import Foundation

struct OllamaModelInfo: Identifiable {
    var id: String { name }
    let name: String
    let sizeInBytes: Int64
    var supportsVision: Bool
}

final class OllamaLocalProvider: AIProvider {
    let id = "ollama-local"
    let displayName = "Ollama (Local)"

    private let baseURL = URL(string: "http://localhost:11434")!

    private var selectedModelName: String = ""
    private var selectedModelSupportsVision: Bool = false

    var supportsVision: Bool {
        selectedModelSupportsVision
    }

    func updateSelectedModel(name: String, supportsVision: Bool) {
        selectedModelName = name
        selectedModelSupportsVision = supportsVision
    }

    func isConfigured() async -> Bool {
        guard !selectedModelName.isEmpty else { return false }
        return await isOllamaReachable()
    }

    func isOllamaReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func fetchInstalledModels() async throws -> [OllamaModelInfo] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: url)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]]
        else {
            return []
        }

        var models: [OllamaModelInfo] = []
        for modelDict in modelsArray {
            guard let name = modelDict["name"] as? String else { continue }
            let size = modelDict["size"] as? Int64 ?? 0
            let hasVision = await modelSupportsVision(name)
            models.append(OllamaModelInfo(name: name, sizeInBytes: size, supportsVision: hasVision))
        }
        return models
    }

    func modelSupportsVision(_ modelName: String) async -> Bool {
        let url = baseURL.appendingPathComponent("api/show")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": modelName])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let capabilities = json["capabilities"] as? [String]
            else {
                return false
            }
            return capabilities.contains("vision")
        } catch {
            return false
        }
    }

    func streamChat(
        messages: [AIProviderMessage],
        systemPrompt: String?,
        model: String
    ) -> AsyncThrowingStream<AIProviderChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let reachable = await self.isOllamaReachable()
                    guard reachable else {
                        continuation.yield(.error(AIProviderError.providerUnavailable(
                            provider: "Ollama (Local)",
                            reason: "Ollama is not running. Start Ollama to use local models."
                        )))
                        continuation.finish()
                        return
                    }

                    let url = self.baseURL.appendingPathComponent("api/chat")
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

                    let modelToUse = model.isEmpty ? self.selectedModelName : model
                    let body: [String: Any] = [
                        "model": modelToUse,
                        "messages": ollamaMessages,
                        "stream": true,
                    ]

                    let bodyData = try JSONSerialization.data(withJSONObject: body)
                    request.httpBody = bodyData

                    print("🌐 Ollama Local streaming request, model: \(modelToUse)")

                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 300
                    config.timeoutIntervalForResource = 600
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
                            provider: "Ollama (Local)",
                            statusCode: httpResponse.statusCode,
                            message: errorBody
                        )))
                        continuation.finish()
                        return
                    }

                    // NDJSON streaming — one JSON object per line
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
