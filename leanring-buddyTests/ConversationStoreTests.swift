import Foundation
import Testing
@testable import leanring_buddy

@MainActor
struct ConversationStoreTests {
    @Test
    func retainsOnlyFiveRecentUnpinnedConversations() throws {
        let storageDirectoryURL = temporaryStorageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let conversationStore = ConversationStore(
            storageDirectoryURL: storageDirectoryURL
        )

        var createdConversationIDs: [UUID] = []
        for conversationIndex in 0..<6 {
            let messageDate = Date(timeIntervalSince1970: Double(conversationIndex + 1))
            let conversationID = conversationStore.createConversation(
                userMessage: userMessage(
                    text: "Question \(conversationIndex)",
                    timestamp: messageDate
                ),
                screenshotData: nil
            )
            conversationStore.appendMessage(
                conversationID: conversationID,
                message: assistantMessage(
                    text: "Answer \(conversationIndex)",
                    timestamp: messageDate
                )
            )
            createdConversationIDs.append(conversationID)
        }

        #expect(conversationStore.conversationsForMenu.count == 5)
        #expect(
            conversationStore.conversation(
                conversationID: createdConversationIDs[0]
            ) == nil
        )
        #expect(
            conversationStore.conversation(
                conversationID: createdConversationIDs[5]
            ) != nil
        )
    }

    @Test
    func pinnedConversationSurvivesRecentConversationPruning() throws {
        let storageDirectoryURL = temporaryStorageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let conversationStore = ConversationStore(
            storageDirectoryURL: storageDirectoryURL
        )
        let pinnedConversationID = conversationStore.createConversation(
            userMessage: userMessage(text: "Keep me", timestamp: .distantPast),
            screenshotData: Data([1, 2, 3])
        )
        conversationStore.appendMessage(
            conversationID: pinnedConversationID,
            message: assistantMessage(text: "Pinned", timestamp: .distantPast)
        )
        conversationStore.setConversationPinned(
            conversationID: pinnedConversationID,
            isPinned: true
        )

        for conversationIndex in 0..<6 {
            let messageDate = Date(timeIntervalSince1970: Double(conversationIndex + 1))
            let conversationID = conversationStore.createConversation(
                userMessage: userMessage(
                    text: "Recent \(conversationIndex)",
                    timestamp: messageDate
                ),
                screenshotData: nil
            )
            conversationStore.appendMessage(
                conversationID: conversationID,
                message: assistantMessage(
                    text: "Answer \(conversationIndex)",
                    timestamp: messageDate
                )
            )
        }

        #expect(conversationStore.conversationsForMenu.count == 6)
        #expect(conversationStore.conversationsForMenu.first?.id == pinnedConversationID)
        #expect(
            conversationStore.screenshotData(
                conversationID: pinnedConversationID
            ) == Data([1, 2, 3])
        )
    }

    @Test
    func conversationsAndScreenshotsPersistAcrossStoreInstances() throws {
        let storageDirectoryURL = temporaryStorageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let firstConversationStore = ConversationStore(
            storageDirectoryURL: storageDirectoryURL
        )
        let conversationID = firstConversationStore.createConversation(
            userMessage: userMessage(text: "Persist this", timestamp: .now),
            screenshotData: Data([4, 5, 6])
        )
        firstConversationStore.appendMessage(
            conversationID: conversationID,
            message: assistantMessage(text: "Saved", timestamp: .now)
        )
        firstConversationStore.setConversationPinned(
            conversationID: conversationID,
            isPinned: true
        )

        let reloadedConversationStore = ConversationStore(
            storageDirectoryURL: storageDirectoryURL
        )

        #expect(
            reloadedConversationStore.conversation(
                conversationID: conversationID
            )?.isPinned == true
        )
        #expect(
            reloadedConversationStore.screenshotData(
                conversationID: conversationID
            ) == Data([4, 5, 6])
        )
    }

    @Test
    func activeConversationIsProtectedWhenAnOldPinIsRemoved() throws {
        let storageDirectoryURL = temporaryStorageDirectoryURL()
        defer { try? FileManager.default.removeItem(at: storageDirectoryURL) }
        let conversationStore = ConversationStore(
            storageDirectoryURL: storageDirectoryURL
        )
        let protectedConversationID = conversationStore.createConversation(
            userMessage: userMessage(text: "Old pinned thread", timestamp: .distantPast),
            screenshotData: nil
        )
        conversationStore.setConversationPinned(
            conversationID: protectedConversationID,
            isPinned: true
        )

        for conversationIndex in 0..<6 {
            let messageDate = Date(timeIntervalSince1970: Double(conversationIndex + 1))
            conversationStore.createConversation(
                userMessage: userMessage(
                    text: "New thread \(conversationIndex)",
                    timestamp: messageDate
                ),
                screenshotData: nil
            )
        }

        conversationStore.setProtectedConversation(
            conversationID: protectedConversationID
        )
        conversationStore.setConversationPinned(
            conversationID: protectedConversationID,
            isPinned: false
        )
        #expect(
            conversationStore.conversation(
                conversationID: protectedConversationID
            ) != nil
        )
        #expect(
            conversationStore.conversations.filter { !$0.isPinned }.count
                == ConversationStore.recentUnpinnedConversationLimit
        )

        conversationStore.setProtectedConversation(conversationID: nil)
        #expect(
            conversationStore.conversation(
                conversationID: protectedConversationID
            ) != nil
        )
    }

    @Test
    func chatWindowGeometryDocksAndClampsAcrossScreenEdges() {
        let visibleScreenFrame = CGRect(x: 0, y: 24, width: 1440, height: 876)
        let rightDockedFrame = ChatWindowGeometry.dockedFrame(
            visibleScreenFrame: visibleScreenFrame,
            dockSide: .right,
            requestedWidth: 420
        )
        let leftDockedFrame = ChatWindowGeometry.dockedFrame(
            visibleScreenFrame: visibleScreenFrame,
            dockSide: .left,
            requestedWidth: 420
        )

        #expect(rightDockedFrame.maxX == visibleScreenFrame.maxX)
        #expect(leftDockedFrame.minX == visibleScreenFrame.minX)
        #expect(
            ChatWindowGeometry.dockingSide(
                floatingFrame: CGRect(x: 10, y: 200, width: 380, height: 300),
                visibleScreenFrame: visibleScreenFrame
            ) == .left
        )
        #expect(
            ChatWindowGeometry.dockingSide(
                floatingFrame: CGRect(x: 1050, y: 200, width: 380, height: 300),
                visibleScreenFrame: visibleScreenFrame
            ) == .right
        )

        let clampedFrame = ChatWindowGeometry.clampedFloatingFrame(
            floatingFrame: CGRect(x: 1300, y: 850, width: 400, height: 300),
            visibleScreenFrame: visibleScreenFrame
        )
        #expect(clampedFrame.maxX == visibleScreenFrame.maxX)
        #expect(clampedFrame.maxY == visibleScreenFrame.maxY)

        let translatedFrame = ChatWindowGeometry.translatedFloatingFrame(
            floatingFrame: CGRect(x: 720, y: 300, width: 400, height: 300),
            sourceVisibleScreenFrame: visibleScreenFrame,
            targetVisibleScreenFrame: CGRect(
                x: 1440,
                y: 24,
                width: 1920,
                height: 1056
            )
        )
        #expect(translatedFrame.minX >= 1440)
        #expect(translatedFrame.maxX <= 3360)
    }

    private func temporaryStorageDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func userMessage(
        text: String,
        timestamp: Date
    ) -> ChatSidebarMessage {
        ChatSidebarMessage(
            role: .user,
            text: text,
            imageData: nil,
            timestamp: timestamp
        )
    }

    private func assistantMessage(
        text: String,
        timestamp: Date
    ) -> ChatSidebarMessage {
        ChatSidebarMessage(
            role: .assistant,
            text: text,
            imageData: nil,
            timestamp: timestamp
        )
    }
}
