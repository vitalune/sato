//
//  ChatSidebarView.swift
//  leanring-buddy
//
//  A slide-in chat sidebar for reading full responses and sending follow-up
//  messages. Anchored to the right edge of the screen. Shows the full
//  conversation with the original screenshot, user questions, and Sato's
//  responses. Follow-ups use the existing conversation history + original
//  screenshot context without requiring a new screenshot.
//

import SwiftUI

struct ChatSidebarView: View {
    @ObservedObject var companionManager: CompanionManager
    let onClose: () -> Void

    @State private var followUpInputText: String = ""
    @FocusState private var isInputFieldFocused: Bool

    private static let sidebarWidth: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider()
                .background(DS.Colors.borderSubtle)

            // Messages area
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(companionManager.chatSidebarMessages) { message in
                            chatMessageRow(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: companionManager.chatSidebarMessages.count) { _, _ in
                    scrollToBottom(scrollProxy: scrollProxy)
                }
                .onChange(of: companionManager.chatSidebarMessages.last?.text) { _, _ in
                    scrollToBottom(scrollProxy: scrollProxy)
                }
                .onAppear {
                    scrollToBottom(scrollProxy: scrollProxy)
                }
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            // Input area
            chatInputArea
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: Self.sidebarWidth)
        .background(
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: -6, y: 0)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                isInputFieldFocused = true
            }
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sato")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                if let profileName = companionManager.activeContextProfileName {
                    Text(profileName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func chatMessageRow(message: ChatSidebarMessage) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            // Screenshot thumbnail for the first user message
            if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 260, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }

            // Message bubble
            if !message.text.isEmpty {
                Group {
                    if message.role == .assistant && !isAssistantMessageCurrentlyStreaming(message: message) {
                        Text(MarkdownRenderer.render(message.text))
                    } else {
                        Text(message.text)
                    }
                }
                    .font(.system(size: 13))
                    .foregroundColor(message.role == .user ? .white : DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(message.role == .user ? DS.Colors.accent : DS.Colors.surface2)
                    )
                    .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)
            } else if message.role == .assistant && companionManager.chatSidebarIsStreaming {
                // Streaming placeholder
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Thinking...")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DS.Colors.surface2)
                )
            }

            // Timestamp
            Text(formatTimestamp(message.timestamp))
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    // MARK: - Input Area

    private var chatInputArea: some View {
        HStack(spacing: 8) {
            TextField("Reply to Sato...", text: $followUpInputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .focused($isInputFieldFocused)
                .onSubmit {
                    submitFollowUp()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )

            Button(action: submitFollowUp) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(
                        followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? DS.Colors.textTertiary
                            : DS.Colors.accent
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || companionManager.chatSidebarIsStreaming)
        }
    }

    // MARK: - Helpers

    private func isAssistantMessageCurrentlyStreaming(message: ChatSidebarMessage) -> Bool {
        guard companionManager.chatSidebarIsStreaming else { return false }
        return message.id == companionManager.chatSidebarMessages.last?.id
    }

    private func submitFollowUp() {
        let trimmedText = followUpInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !companionManager.chatSidebarIsStreaming else { return }
        companionManager.sendChatSidebarFollowUp(messageText: trimmedText)
        followUpInputText = ""
    }

    private func scrollToBottom(scrollProxy: ScrollViewProxy) {
        guard let lastMessage = companionManager.chatSidebarMessages.last else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            scrollProxy.scrollTo(lastMessage.id, anchor: .bottom)
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - NSVisualEffectView Wrapper

/// Wraps NSVisualEffectView for use in SwiftUI to get the macOS blur material.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
