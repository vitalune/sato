//
//  ChatSidebarView.swift
//  leanring-buddy
//
//  A responsive chat surface that can dock to either screen edge or detach
//  into a compact, movable window.
//

import AppKit
import Combine
import SwiftUI

enum ChatWindowDockSide: String, Equatable {
    case left
    case right
}

enum ChatWindowPresentationMode: Equatable {
    case docked(ChatWindowDockSide)
    case floating

    var isFloating: Bool {
        self == .floating
    }
}

@MainActor
final class ChatWindowViewState: ObservableObject {
    @Published var presentationMode: ChatWindowPresentationMode

    init(presentationMode: ChatWindowPresentationMode) {
        self.presentationMode = presentationMode
    }
}

struct ChatSidebarView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var windowViewState: ChatWindowViewState
    let onMinimize: () -> Void
    let onWindowDragEnded: (CGPoint) -> Void
    let onClose: () -> Void

    @State private var followUpInputText: String = ""
    @FocusState private var isInputFieldFocused: Bool

    var body: some View {
        GeometryReader { geometryProxy in
            let shouldShowCompactContent = windowViewState.presentationMode.isFloating
                && geometryProxy.size.height < 420
            let messageMaximumWidth = max(180, geometryProxy.size.width - 64)

            VStack(spacing: 0) {
                sidebarHeader
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                Divider()
                    .background(DS.Colors.borderSubtle)

                if shouldShowCompactContent {
                    latestAssistantResponsePreview
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else {
                    conversationMessages(
                        messageMaximumWidth: messageMaximumWidth
                    )
                }

                Divider()
                    .background(DS.Colors.borderSubtle)

                chatInputArea
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .background(
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(chatWindowShape)
            )
            .overlay {
                chatWindowShape
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(0.35),
                radius: windowViewState.presentationMode.isFloating ? 18 : 16,
                x: shadowHorizontalOffset,
                y: windowViewState.presentationMode.isFloating ? 7 : 0
            )
        }
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
        HStack(spacing: 10) {
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

            if windowViewState.presentationMode.isFloating {
                WindowDragHandle(onDragEnded: onWindowDragEnded)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .accessibilityLabel("Move chat window")
            } else {
                Spacer()

                Button(action: onMinimize) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Detach chat")
            }

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
            .help("Close chat")
        }
    }

    // MARK: - Conversation Content

    private func conversationMessages(messageMaximumWidth: CGFloat) -> some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(companionManager.chatSidebarMessages) { message in
                        chatMessageRow(
                            message: message,
                            messageMaximumWidth: messageMaximumWidth
                        )
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
    }

    private var latestAssistantResponsePreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Text("Latest response")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .textCase(.uppercase)

                if let latestAssistantMessage = companionManager.chatSidebarMessages.last(where: {
                    $0.role == .assistant
                }) {
                    Group {
                        if isAssistantMessageCurrentlyStreaming(message: latestAssistantMessage) {
                            Text(latestAssistantMessage.text)
                                .font(.system(size: 13))
                                .foregroundColor(DS.Colors.textPrimary)
                        } else {
                            Text(MarkdownRenderer.render(latestAssistantMessage.text))
                        }
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("No response yet.")
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Message Row

    @ViewBuilder
    private func chatMessageRow(
        message: ChatSidebarMessage,
        messageMaximumWidth: CGFloat
    ) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if let imageData = message.imageData, let nsImage = NSImage(data: imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: messageMaximumWidth, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            }

            if !message.text.isEmpty {
                Group {
                    if message.role == .assistant && !isAssistantMessageCurrentlyStreaming(message: message) {
                        Text(MarkdownRenderer.render(message.text))
                    } else {
                        Text(message.text)
                            .font(.system(size: 13))
                            .foregroundColor(message.role == .user ? .white : DS.Colors.textPrimary)
                    }
                }
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(message.role == .user ? DS.Colors.accent : DS.Colors.surface2)
                    )
                    .frame(
                        maxWidth: messageMaximumWidth,
                        alignment: message.role == .user ? .trailing : .leading
                    )
            } else if message.role == .assistant && companionManager.chatSidebarIsStreaming {
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
                .fixedSize(horizontal: false, vertical: true)
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

    private var chatWindowShape: UnevenRoundedRectangle {
        switch windowViewState.presentationMode {
        case .docked(.left):
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: DS.CornerRadius.extraLarge,
                topTrailingRadius: DS.CornerRadius.extraLarge
            )
        case .docked(.right):
            UnevenRoundedRectangle(
                topLeadingRadius: DS.CornerRadius.extraLarge,
                bottomLeadingRadius: DS.CornerRadius.extraLarge,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0
            )
        case .floating:
            UnevenRoundedRectangle(
                topLeadingRadius: DS.CornerRadius.extraLarge,
                bottomLeadingRadius: DS.CornerRadius.extraLarge,
                bottomTrailingRadius: DS.CornerRadius.extraLarge,
                topTrailingRadius: DS.CornerRadius.extraLarge
            )
        }
    }

    private var shadowHorizontalOffset: CGFloat {
        switch windowViewState.presentationMode {
        case .docked(.left):
            6
        case .docked(.right):
            -6
        case .floating:
            0
        }
    }

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

// MARK: - Window Drag Handle

private struct WindowDragHandle: NSViewRepresentable {
    let onDragEnded: (CGPoint) -> Void

    func makeNSView(context: Context) -> DraggableWindowRegionView {
        DraggableWindowRegionView(onDragEnded: onDragEnded)
    }

    func updateNSView(_ nsView: DraggableWindowRegionView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }
}

private final class DraggableWindowRegionView: NSView {
    var onDragEnded: (CGPoint) -> Void

    init(onDragEnded: @escaping (CGPoint) -> Void) {
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let handleWidth: CGFloat = 30
        let handleHeight: CGFloat = 4
        let handleRect = NSRect(
            x: bounds.midX - (handleWidth / 2),
            y: bounds.midY - (handleHeight / 2),
            width: handleWidth,
            height: handleHeight
        )
        NSColor.white.withAlphaComponent(0.16).setFill()
        NSBezierPath(
            roundedRect: handleRect,
            xRadius: handleHeight / 2,
            yRadius: handleHeight / 2
        ).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        window?.performDrag(with: event)
        NSCursor.pop()
        onDragEnded(NSEvent.mouseLocation)
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
