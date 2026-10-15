//
//  AnthropicProvider.swift
//  leanring-buddy
//
//  AIProvider implementation for Anthropic's Claude API.
//  Wraps the existing streaming logic from ClaudeAPI.swift behind
//  the unified AIProvider protocol.
//

import Foundation

struct AnthropicModel {
    let id: String
    let displayName: String
    let effortOptions: ReasoningEffortOptions
}

final class AnthropicProvider: AIProvider {
    let id = "anthropic"
    let displayName = "Anthropic"
    let supportsVision = true

    // Effort levels follow Anthropic's per-model support: `xhigh` exists on
    // Opus 4.7 and Haiku 5.5 but not on Sonnet 4.6. Medium is the default so
    // quick screen questions stay fast until the user asks for more effort.
    static let availableModels = [
        AnthropicModel(
            id: "claude-opus-4-7",
            displayName: "Claude Opus 4.7",
            effortOptions: ReasoningEffortOptions(
                levels: [.low, .medium, .high, .extraHigh, .max],
                defaultLevel: .medium
            )
        ),
        AnthropicModel(
            id: "claude-sonnet-4-6",
            displayName: "Claude Sonnet 4.6",
            effortOptions: ReasoningEffortOptions(
                levels: [.low, .medium, .high, .max],
                defaultLevel: .medium
            )
        ),
        AnthropicModel(
            id: "claude-haiku-5-5",
            displayName: "Claude Haiku 5.5",
            effortOptions: ReasoningEffortOptions(
                levels: [.low, .medium, .high, .extraHigh, .max],
                defaultLevel: .medium
            )
        ),
    ]

    static let defaultModelID = "claude-sonnet-4-6"

    /// Models that were removed from the picker and the model that replaces them.
    private static let replacementModelIDsForRemovedModels = [
        "claude-haiku-4-5": "claude-haiku-5-5",
    ]

    /// Maps saved selections (including removed models such as Haiku 4.5) to a
    /// model that is still offered, so existing settings and context profile
    /// overrides keep working after an update.
    static func resolvedModelID(_ requestedModelID: String?) -> String {
        guard let requestedModelID else { return defaultModelID }

        if availableModels.contains(where: { $0.id == requestedModelID }) {
            return requestedModelID
        }
        return replacementModelIDsForRemovedModels[requestedModelID] ?? defaultModelID
    }

    /// Thinking tokens count toward `max_tokens`, so the cap leaves room for
    /// high-effort reasoning before the visible answer.
    private static let maximumOutputTokens = 64_000

    func isConfigured() async -> Bool {
        guard let key = KeychainHelper.loadAPIKey(for: .anthropic) else { return false }
        return !key.isEmpty
    }

    func streamChat(
        messages: [AIProviderMessage],
        systemPrompt: String?,
        model: String,
        reasoningEffort: String?
    ) -> AsyncThrowingStream<AIProviderChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let apiKey = KeychainHelper.loadAPIKey(for: .anthropic), !apiKey.isEmpty else {
                        continuation.yield(.error(AIProviderError.missingAPIKey(provider: "Anthropic")))
                        continuation.finish()
                        return
                    }

                    let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

                    var request = URLRequest(url: apiURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

                    var apiMessages: [[String: Any]] = []

                    for message in messages {
                        switch message.role {
                        case .system:
                            continue
                        case .user:
                            var contentBlocks: [[String: Any]] = []
                            if let images = message.images {
                                for imageData in images {
                                    let mediaType = Self.detectMIMEType(imageData)
                                    contentBlocks.append([
                                        "type": "image",
                                        "source": [
                                            "type": "base64",
                                            "media_type": mediaType,
                                            "data": imageData.base64EncodedString(),
                                        ],
                                    ])
                                }
                            }
                            contentBlocks.append([
                                "type": "text",
                                "text": message.text,
                            ])
                            apiMessages.append(["role": "user", "content": contentBlocks])

                        case .assistant:
                            apiMessages.append(["role": "assistant", "content": message.text])
                        }
                    }

                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": Self.maximumOutputTokens,
                        "stream": true,
                        "messages": apiMessages,
                    ]
                    if let systemPrompt, !systemPrompt.isEmpty {
                        body["system"] = systemPrompt
                    }
                    if let reasoningEffort {
                        // Adaptive thinking lets the model decide how much to
                        // think, and effort sets how deep it goes. Opus 4.7
                        // and Sonnet 4.6 only think when adaptive is explicit.
                        body["thinking"] = ["type": "adaptive"]
                        body["output_config"] = ["effort": reasoningEffort]
                    }

                    let bodyData = try JSONSerialization.data(withJSONObject: body)
                    request.httpBody = bodyData

                    let payloadMB = Double(bodyData.count) / 1_048_576.0
                    print("🌐 Anthropic streaming request: \(String(format: "%.1f", payloadMB))MB, model: \(model), effort: \(reasoningEffort ?? "default")")

                    // High effort can think for several minutes before the
                    // first visible text, so the overall limit is generous.
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 300
                    config.timeoutIntervalForResource = 900
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
                            provider: "Anthropic",
                            statusCode: httpResponse.statusCode,
                            message: errorBody
                        )))
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

                        // Thinking blocks stream as `thinking_delta` events and
                        // are skipped; only the visible answer is shown.
                        if eventType == "content_block_delta",
                           let delta = eventPayload["delta"] as? [String: Any],
                           let deltaType = delta["type"] as? String,
                           deltaType == "text_delta",
                           let textChunk = delta["text"] as? String
                        {
                            continuation.yield(.textDelta(textChunk))
                        } else if eventType == "message_delta",
                                  let delta = eventPayload["delta"] as? [String: Any],
                                  delta["stop_reason"] as? String == "refusal"
                        {
                            // Newer models can decline through safety
                            // classifiers; without this the bubble stays empty.
                            continuation.yield(.error(AIProviderError.responseDeclined(provider: "Claude")))
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
