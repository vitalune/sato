//
//  ConversationStore.swift
//  leanring-buddy
//
//  Persists recent and pinned chat conversations without embedding screenshots
//  in the JSON metadata file.
//

import Combine
import Foundation

struct SavedConversationMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatSidebarMessageRole
    var text: String
    let timestamp: Date
    /// Optional screenshot file for this specific message turn.
    var screenshotFileName: String?

    init(
        id: UUID = UUID(),
        role: ChatSidebarMessageRole,
        text: String,
        timestamp: Date = Date(),
        screenshotFileName: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.screenshotFileName = screenshotFileName
    }

    init(chatSidebarMessage: ChatSidebarMessage, screenshotFileName: String? = nil) {
        id = chatSidebarMessage.id
        role = chatSidebarMessage.role
        text = chatSidebarMessage.text
        timestamp = chatSidebarMessage.timestamp
        self.screenshotFileName = screenshotFileName
    }

    func chatSidebarMessage(imageData: Data? = nil) -> ChatSidebarMessage {
        ChatSidebarMessage(
            id: id,
            role: role,
            text: text,
            imageData: imageData,
            timestamp: timestamp
        )
    }
}

struct SavedConversation: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var messages: [SavedConversationMessage]
    /// Legacy single-screenshot field kept for conversations created before
    /// per-message screenshot filenames existed.
    var screenshotFileName: String?
    var isPinned: Bool
    let createdAt: Date
    var updatedAt: Date

    var latestAssistantResponse: String? {
        messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    static let recentUnpinnedConversationLimit = 5

    @Published private(set) var conversations: [SavedConversation] = []

    private let fileManager: FileManager
    private let storageDirectoryURL: URL
    private let conversationsFileURL: URL
    private let screenshotsDirectoryURL: URL
    private var protectedConversationID: UUID?

    init(
        storageDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let resolvedStorageDirectoryURL = storageDirectoryURL
            ?? ConversationStore.defaultStorageDirectoryURL
        self.fileManager = fileManager
        self.storageDirectoryURL = resolvedStorageDirectoryURL
        conversationsFileURL = resolvedStorageDirectoryURL.appendingPathComponent("conversations.json")
        screenshotsDirectoryURL = resolvedStorageDirectoryURL.appendingPathComponent(
            "conversation-screenshots",
            isDirectory: true
        )
        loadConversations()
    }

    var conversationsForMenu: [SavedConversation] {
        let pinnedConversations = conversations
            .filter(\.isPinned)
            .sorted { $0.updatedAt > $1.updatedAt }
        let recentUnpinnedConversations = conversations
            .filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(Self.recentUnpinnedConversationLimit)

        return pinnedConversations + Array(recentUnpinnedConversations)
    }

    @discardableResult
    func createConversation(
        userMessage: ChatSidebarMessage,
        screenshotData: Data?
    ) -> UUID {
        let conversationID = UUID()
        let screenshotFileName = saveScreenshot(
            screenshotData,
            conversationID: conversationID,
            messageID: userMessage.id
        )
        let conversation = SavedConversation(
            id: conversationID,
            title: Self.conversationTitle(from: userMessage.text),
            messages: [
                SavedConversationMessage(
                    chatSidebarMessage: userMessage,
                    screenshotFileName: screenshotFileName
                )
            ],
            screenshotFileName: screenshotFileName,
            isPinned: false,
            createdAt: userMessage.timestamp,
            updatedAt: userMessage.timestamp
        )

        conversations.append(conversation)
        pruneExcessUnpinnedConversations()
        saveConversations()
        return conversationID
    }

    func appendMessage(
        conversationID: UUID,
        message: ChatSidebarMessage,
        screenshotData: Data? = nil
    ) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        let screenshotFileName = saveScreenshot(
            screenshotData,
            conversationID: conversationID,
            messageID: message.id
        )
        conversations[conversationIndex].messages.append(
            SavedConversationMessage(
                chatSidebarMessage: message,
                screenshotFileName: screenshotFileName
            )
        )
        conversations[conversationIndex].updatedAt = max(
            conversations[conversationIndex].updatedAt,
            message.timestamp
        )
        pruneExcessUnpinnedConversations()
        saveConversations()
    }

    func conversation(conversationID: UUID) -> SavedConversation? {
        conversations.first(where: { $0.id == conversationID })
    }

    /// Loads screenshot bytes for a message, falling back to the conversation's
    /// legacy single screenshot for the first user message when needed.
    func screenshotData(
        conversationID: UUID,
        messageID: UUID
    ) -> Data? {
        guard let conversation = conversation(conversationID: conversationID),
              let message = conversation.messages.first(where: { $0.id == messageID })
        else {
            return nil
        }

        if let screenshotFileName = message.screenshotFileName {
            return loadScreenshotData(fileName: screenshotFileName)
        }

        let isLegacyFirstUserMessage = message.role == .user
            && conversation.messages.first?.id == messageID
        if isLegacyFirstUserMessage {
            return screenshotData(conversationID: conversationID)
        }

        return nil
    }

    func screenshotData(conversationID: UUID) -> Data? {
        guard let conversation = conversation(conversationID: conversationID) else {
            return nil
        }

        if let screenshotFileName = conversation.screenshotFileName {
            return loadScreenshotData(fileName: screenshotFileName)
        }

        if let firstMessageScreenshotFileName = conversation.messages
            .first(where: { $0.role == .user })?
            .screenshotFileName
        {
            return loadScreenshotData(fileName: firstMessageScreenshotFileName)
        }

        return nil
    }

    func setConversationPinned(conversationID: UUID, isPinned: Bool) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        conversations[conversationIndex].isPinned = isPinned
        pruneExcessUnpinnedConversations()
        saveConversations()
    }

    /// Prevents the open conversation from being removed if an old pinned
    /// thread is unpinned while the user is still replying to it.
    func setProtectedConversation(conversationID: UUID?) {
        protectedConversationID = conversationID
        if let conversationID,
           let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) {
            conversations[conversationIndex].updatedAt = Date()
        }
        pruneExcessUnpinnedConversations()
        saveConversations()
    }

    func deleteConversation(conversationID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        let removedConversation = conversations.remove(at: conversationIndex)
        deleteScreenshots(for: removedConversation)
        saveConversations()
    }

    private static var defaultStorageDirectoryURL: URL {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return applicationSupportDirectory.appendingPathComponent("Sato", isDirectory: true)
    }

    private static func conversationTitle(from initialPrompt: String) -> String {
        let singleLinePrompt = initialPrompt
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard singleLinePrompt.count > 60 else {
            return singleLinePrompt.isEmpty ? "Untitled conversation" : singleLinePrompt
        }

        return String(singleLinePrompt.prefix(57)).trimmingCharacters(in: .whitespaces) + "..."
    }

    private func loadConversations() {
        guard fileManager.fileExists(atPath: conversationsFileURL.path) else {
            conversations = []
            return
        }

        do {
            let data = try Data(contentsOf: conversationsFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            conversations = try decoder.decode([SavedConversation].self, from: data)
            if pruneExcessUnpinnedConversations() {
                saveConversations()
            }
        } catch {
            // Keep the unreadable file intact so a future recovery can inspect it.
            conversations = []
            print("⚠️ Sato: Failed to load conversations.json: \(error)")
        }
    }

    private func saveConversations() {
        do {
            try ensureStorageDirectoriesExist()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(conversations)
            try data.write(to: conversationsFileURL, options: .atomic)
        } catch {
            print("⚠️ Sato: Failed to save conversations.json: \(error)")
        }
    }

    private func saveScreenshot(
        _ screenshotData: Data?,
        conversationID: UUID,
        messageID: UUID
    ) -> String? {
        guard let screenshotData else { return nil }

        do {
            try ensureStorageDirectoriesExist()
            let screenshotFileName = "\(conversationID.uuidString)-\(messageID.uuidString).jpg"
            let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
            try screenshotData.write(to: screenshotURL, options: .atomic)
            return screenshotFileName
        } catch {
            print("⚠️ Sato: Failed to save conversation screenshot: \(error)")
            return nil
        }
    }

    private func loadScreenshotData(fileName: String) -> Data? {
        let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(fileName)
        return try? Data(contentsOf: screenshotURL)
    }

    private func ensureStorageDirectoriesExist() throws {
        try fileManager.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: screenshotsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    @discardableResult
    private func pruneExcessUnpinnedConversations() -> Bool {
        let unpinnedConversationsByRecency = conversations
            .filter { !$0.isPinned }
            .sorted { firstConversation, secondConversation in
                if firstConversation.id == protectedConversationID {
                    return true
                }
                if secondConversation.id == protectedConversationID {
                    return false
                }
                return firstConversation.updatedAt > secondConversation.updatedAt
            }
        let conversationIDsToKeep = Set(
            unpinnedConversationsByRecency
                .prefix(Self.recentUnpinnedConversationLimit)
                .map(\.id)
        )
        let conversationIDsToRemove = Set(
            unpinnedConversationsByRecency
                .filter { !conversationIDsToKeep.contains($0.id) }
                .map(\.id)
        )

        guard !conversationIDsToRemove.isEmpty else { return false }

        let removedConversations = conversations.filter {
            conversationIDsToRemove.contains($0.id)
        }
        conversations.removeAll {
            conversationIDsToRemove.contains($0.id)
        }
        removedConversations.forEach(deleteScreenshots)
        return true
    }

    private func deleteScreenshots(for conversation: SavedConversation) {
        var screenshotFileNames = Set(conversation.messages.compactMap(\.screenshotFileName))
        if let conversationScreenshotFileName = conversation.screenshotFileName {
            screenshotFileNames.insert(conversationScreenshotFileName)
        }

        for screenshotFileName in screenshotFileNames {
            let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
            try? fileManager.removeItem(at: screenshotURL)
        }
    }
}
