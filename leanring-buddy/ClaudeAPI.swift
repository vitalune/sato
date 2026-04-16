//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

/// Claude API helper with streaming for progressive text display.
enum ClaudeAPI {

    /// Sends a text prompt + optional image directly to the Anthropic API.
    /// Streams the response via SSE and calls `onTextChunk` with accumulated
    /// text so the speech bubble updates progressively.
    static func analyzeImageDirectStreaming(
        apiKey: String,
        imageData: Data?,
        systemPrompt: String,
        conversationHistory: [(userText: String, assistantResponse: String)] = [],
        userPrompt: String,
        model: String = "claude-sonnet-4-20250514",
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Build messages array
        var messages: [[String: Any]] = []

        for (userText, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userText])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current user message with optional image + text
        var contentBlocks: [[String: Any]] = []
        if let imageData {
            // Detect MIME type
            let mediaType: String
            if imageData.count >= 4 {
                let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
                let firstFourBytes = [UInt8](imageData.prefix(4))
                mediaType = (firstFourBytes == pngSignature) ? "image/png" : "image/jpeg"
            } else {
                mediaType = "image/jpeg"
            }

            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType,
                    "data": imageData.base64EncodedString()
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude direct streaming request: \(String(format: "%.1f", payloadMB))MB")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.urlCache = nil
        let session = URLSession(configuration: config)

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ClaudeAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(domain: "ClaudeAPI", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"])
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6))
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                let currentText = accumulatedResponseText
                await onTextChunk(currentText)
            }
        }

        return accumulatedResponseText
    }
}
