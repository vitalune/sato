//
//  OpenAIProvider.swift
//  leanring-buddy
//
//  AIProvider implementation for OpenAI's Responses API (/v1/responses).
//  Uses SSE streaming, supports vision via base64 data URLs.
//

import Foundation

struct OpenAIModel {
    let id: String
    let displayName: String
}

final class OpenAIProvider: AIProvider {
    let id = "openai"
    let displayName = "OpenAI"
    let supportsVision = true

    static let availableModels = [
        OpenAIModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna"),
        OpenAIModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra"),
    ]

    static let defaultModelID = "gpt-5.6-luna"

    static func resolvedModelID(_ requestedModelID: String?) -> String {
        guard let requestedModelID,
              availableModels.contains(where: { $0.id == requestedModelID })
        else {
            return defaultModelID
        }
        return requestedModelID
    }

    private let baseURL = URL(string: "https://api.openai.com/v1/responses")!

    func isConfigured() async -> Bool {
        guard let key = KeychainHelper.loadAPIKey(for: .openai) else { return false }
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
                    guard let apiKey = KeychainHelper.loadAPIKey(for: .openai), !apiKey.isEmpty else {
                        continuation.yield(.error(AIProviderError.missingAPIKey(provider: "OpenAI")))
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: baseURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 120
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    var inputMessages: [[String: Any]] = []

                    for message in messages {
                        switch message.role {
                        case .system:
                            continue
                        case .user:
                            var contentBlocks: [[String: Any]] = []
                            if let images = message.images {
                                for imageData in images {
                                    let base64String = imageData.base64EncodedString()
                                    let mimeType = Self.detectMIMEType(imageData)
                                    contentBlocks.append([
                                        "type": "input_image",
                                        "image_url": "data:\(mimeType);base64,\(base64String)",
                                    ])
                                }
                            }
                            contentBlocks.append([
                                "type": "input_text",
                                "text": message.text,
                            ])
                            inputMessages.append(["role": "user", "content": contentBlocks])

                        case .assistant:
                            inputMessages.append([
                                "role": "assistant",
                                "content": [
                                    ["type": "output_text", "text": message.text]
                                ],
                            ])
                        }
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "input": inputMessages,
                        "stream": true,
                        "store": false,
                    ]
                    if let systemPrompt, !systemPrompt.isEmpty {
                        body["instructions"] = systemPrompt
                    }

                    let bodyData = try JSONSerialization.data(withJSONObject: body)
                    request.httpBody = bodyData

                    let payloadMB = Double(bodyData.count) / 1_048_576.0
                    print("🌐 OpenAI streaming request: \(String(format: "%.1f", payloadMB))MB, model: \(model)")

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

                        if httpResponse.statusCode == 429 && errorBody.contains("insufficient_quota") {
                            continuation.yield(.error(AIProviderError.quotaExceeded(provider: "OpenAI")))
                        } else {
                            continuation.yield(.error(AIProviderError.apiError(
                                provider: "OpenAI",
                                statusCode: httpResponse.statusCode,
                                message: errorBody
                            )))
                        }
                        continuation.finish()
                        return
                    }

                    for try await line in byteStream.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonString = String(line.dropFirst(6))
                        guard jsonString != "[DONE]" else { break }

                        guard let jsonData = jsonString.data(using: .utf8),
                              let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let eventType = eventPayload["type"] as? String
                        else {
                            continue
                        }

                        if eventType == "response.output_text.delta",
                           let delta = eventPayload["delta"] as? String
                        {
                            continuation.yield(.textDelta(delta))
                        } else if eventType == "response.completed" {
                            break
                        } else if eventType == "error" {
                            let errorMessage = (eventPayload["message"] as? String) ?? "Unknown OpenAI streaming error"
                            continuation.yield(.error(AIProviderError.apiError(
                                provider: "OpenAI",
                                statusCode: 0,
                                message: errorMessage
                            )))
                            continuation.finish()
                            return
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

    private static func detectMIMEType(_ imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            return (firstFourBytes == pngSignature) ? "image/png" : "image/jpeg"
        }
        return "image/jpeg"
    }
}
