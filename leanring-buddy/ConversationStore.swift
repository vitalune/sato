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

    init(
        id: UUID = UUID(),
        role: ChatSidebarMessageRole,
        text: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }

    init(chatSidebarMessage: ChatSidebarMessage) {
        id = chatSidebarMessage.id
        role = chatSidebarMessage.role
        text = chatSidebarMessage.text
        timestamp = chatSidebarMessage.timestamp
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

    init(
        storageDirectoryURL: URL = ConversationStore.defaultStorageDirectoryURL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.storageDirectoryURL = storageDirectoryURL
        conversationsFileURL = storageDirectoryURL.appendingPathComponent("conversations.json")
        screenshotsDirectoryURL = storageDirectoryURL.appendingPathComponent(
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
        assistantMessage: ChatSidebarMessage,
        screenshotData: Data?
    ) -> UUID {
        let conversationID = UUID()
        let now = max(userMessage.timestamp, assistantMessage.timestamp)
        let screenshotFileName = saveScreenshot(
            screenshotData,
            conversationID: conversationID
        )
        let conversation = SavedConversation(
            id: conversationID,
            title: Self.conversationTitle(from: userMessage.text),
            messages: [
                SavedConversationMessage(chatSidebarMessage: userMessage),
                SavedConversationMessage(chatSidebarMessage: assistantMessage)
            ],
            screenshotFileName: screenshotFileName,
            isPinned: false,
            createdAt: userMessage.timestamp,
            updatedAt: now
        )

        conversations.append(conversation)
        pruneExcessUnpinnedConversations()
        saveConversations()
        return conversationID
    }

    func appendExchange(
        conversationID: UUID,
        userMessage: ChatSidebarMessage,
        assistantMessage: ChatSidebarMessage
    ) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        conversations[conversationIndex].messages.append(
            SavedConversationMessage(chatSidebarMessage: userMessage)
        )
        conversations[conversationIndex].messages.append(
            SavedConversationMessage(chatSidebarMessage: assistantMessage)
        )
        conversations[conversationIndex].updatedAt = max(
            userMessage.timestamp,
            assistantMessage.timestamp
        )
        pruneExcessUnpinnedConversations()
        saveConversations()
    }

    func conversation(conversationID: UUID) -> SavedConversation? {
        conversations.first(where: { $0.id == conversationID })
    }

    func screenshotData(conversationID: UUID) -> Data? {
        guard let conversation = conversation(conversationID: conversationID),
              let screenshotFileName = conversation.screenshotFileName
        else {
            return nil
        }

        let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
        return try? Data(contentsOf: screenshotURL)
    }

    func setConversationPinned(conversationID: UUID, isPinned: Bool) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        conversations[conversationIndex].isPinned = isPinned
        pruneExcessUnpinnedConversations()
        saveConversations()
    }

    func deleteConversation(conversationID: UUID) {
        guard let conversationIndex = conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }

        let removedConversation = conversations.remove(at: conversationIndex)
        deleteScreenshot(for: removedConversation)
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
            pruneExcessUnpinnedConversations()
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

    private func saveScreenshot(_ screenshotData: Data?, conversationID: UUID) -> String? {
        guard let screenshotData else { return nil }

        do {
            try ensureStorageDirectoriesExist()
            let screenshotFileName = "\(conversationID.uuidString).jpg"
            let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
            try screenshotData.write(to: screenshotURL, options: .atomic)
            return screenshotFileName
        } catch {
            print("⚠️ Sato: Failed to save conversation screenshot: \(error)")
            return nil
        }
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

    private func pruneExcessUnpinnedConversations() {
        let unpinnedConversationsByRecency = conversations
            .filter { !$0.isPinned }
            .sorted { $0.updatedAt > $1.updatedAt }
        let conversationIDsToRemove = Set(
            unpinnedConversationsByRecency
                .dropFirst(Self.recentUnpinnedConversationLimit)
                .map(\.id)
        )

        guard !conversationIDsToRemove.isEmpty else { return }

        let removedConversations = conversations.filter {
            conversationIDsToRemove.contains($0.id)
        }
        conversations.removeAll {
            conversationIDsToRemove.contains($0.id)
        }
        removedConversations.forEach(deleteScreenshot)
    }

    private func deleteScreenshot(for conversation: SavedConversation) {
        guard let screenshotFileName = conversation.screenshotFileName else { return }

        let screenshotURL = screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
        try? fileManager.removeItem(at: screenshotURL)
    }
}
