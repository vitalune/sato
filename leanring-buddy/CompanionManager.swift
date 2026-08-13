//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion. Owns the global shortcut monitor,
//  overlay, sprite system, and text-based AI assist pipeline.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

/// Phases of the text-based assist interaction flow.
/// Drives the overlay UI: screenshot selection → text input → speech bubble.
enum AssistFlowPhase: Equatable {
    /// No assist flow in progress.
    case inactive
    /// Screenshot selection overlay is showing — user is drawing a region.
    case selectingScreenshot
    /// Text input is showing — user is typing their question.
    case typingQuestion
    /// Claude is streaming a response — speech bubble is visible.
    case showingResponse
    /// Chat sidebar is open — full conversation view with follow-up input.
    case chatSidebar
}

/// A single message in the chat sidebar conversation.
struct ChatSidebarMessage: Identifiable, Equatable {
    let id: UUID
    let role: ChatSidebarMessageRole
    var text: String
    let imageData: Data?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        role: ChatSidebarMessageRole,
        text: String,
        imageData: Data?,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imageData = imageData
        self.timestamp = timestamp
    }
}

enum ChatSidebarMessageRole: String, Codable {
    case user
    case assistant
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Assist Flow State (Text-based AI pipeline)

    /// Current phase of the text-based assist flow.
    @Published var assistFlowPhase: AssistFlowPhase = .inactive

    /// The frozen screenshot NSImage for the selection overlay.
    @Published var assistScreenshotImage: NSImage?

    /// The cropped screenshot JPEG data from the user's selection.
    @Published var assistCroppedImageData: Data?

    /// Screenshot captured while an existing chat sidebar conversation is open.
    /// Injected into the next follow-up turn once the user sends a reply.
    @Published var pendingFollowUpScreenshotData: Data?

    /// True while Ctrl+Option is capturing a screenshot for the open sidebar conversation.
    private var isCapturingFollowUpScreenshot = false

    /// Assist-screen frame to restore after a follow-up screenshot capture finishes,
    /// so the open chat sidebar stays on its original display.
    private var chatSidebarScreenFrameBeforeFollowUpCapture: CGRect?

    /// Claude's streaming response text, updated progressively.
    @Published var assistResponseText: String = ""

    /// Whether Claude is still streaming the response.
    @Published var assistResponseIsStreaming: Bool = false

    /// The screen frame the assist flow is happening on (for overlay).
    @Published var assistScreenFrame: CGRect = .zero

    // MARK: - Chat Sidebar State

    /// Messages displayed in the chat sidebar. Built from the current assist
    /// flow's screenshot + question + response, plus any follow-ups.
    @Published var chatSidebarMessages: [ChatSidebarMessage] = []

    /// Whether the chat sidebar is currently streaming a follow-up response.
    @Published var chatSidebarIsStreaming: Bool = false

    /// The persisted conversation currently displayed in the chat window.
    @Published private(set) var activeConversationID: UUID?

    /// When ON, skip the speech bubble and go straight to the chat sidebar.
    @Published var alwaysOpenChatSidebar: Bool = UserDefaults.standard.bool(forKey: "alwaysOpenChatSidebar")

    func setAlwaysOpenChatSidebar(_ enabled: Bool) {
        alwaysOpenChatSidebar = enabled
        UserDefaults.standard.set(enabled, forKey: "alwaysOpenChatSidebar")
    }

    /// Opens the chat sidebar from the speech bubble, carrying over the current
    /// response and conversation context.
    func openChatSidebar() {
        guard assistFlowPhase == .showingResponse else { return }
        guard !chatSidebarMessages.isEmpty else { return }
        assistFlowPhase = .chatSidebar
        print("💬 Chat sidebar opened with \(chatSidebarMessages.count) messages")
    }

    /// Restores a persisted conversation and opens it on the display containing
    /// the pointer, which is also the display containing the menu panel click.
    func openSavedConversation(conversationID: UUID) {
        guard let conversation = conversationStore.conversation(conversationID: conversationID) else {
            return
        }

        currentResponseTask?.cancel()
        currentResponseTask = nil
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        chatSidebarMessages = conversation.messages.map { message in
            let messageImageData = conversationStore.screenshotData(
                conversationID: conversationID,
                messageID: message.id
            )
            return message.chatSidebarMessage(imageData: messageImageData)
        }
        activeConversationID = conversationID
        conversationStore.setProtectedConversation(conversationID: conversationID)
        assistCroppedImageData = chatSidebarMessages.first(where: {
            $0.role == .user && $0.imageData != nil
        })?.imageData
        pendingFollowUpScreenshotData = nil
        isCapturingFollowUpScreenshot = false
        chatSidebarScreenFrameBeforeFollowUpCapture = nil
        assistResponseText = ""
        assistResponseIsStreaming = false
        chatSidebarIsStreaming = false

        let pointerScreenPosition = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first {
            $0.frame.contains(pointerScreenPosition)
        } ?? NSScreen.main
        guard let pointerScreen else { return }
        assistScreenFrame = pointerScreen.frame
        overlayWindowManager.retargetChatSidebar(to: pointerScreen)

        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        assistFlowPhase = .chatSidebar
    }

    func setConversationPinned(conversationID: UUID, isPinned: Bool) {
        conversationStore.setConversationPinned(
            conversationID: conversationID,
            isPinned: isPinned
        )
    }

    /// Sends a follow-up message from the chat sidebar.
    /// Reuses prior screenshot context from conversation history, and attaches any
    /// pending follow-up screenshot captured with Ctrl+Option while the sidebar is open.
    func sendChatSidebarFollowUp(messageText: String) {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              let activeConversationID
        else {
            return
        }

        let previousConversationMessages = chatSidebarMessages
        let followUpScreenshotData = pendingFollowUpScreenshotData
        pendingFollowUpScreenshotData = nil

        // Add user message to sidebar
        let userMessage = ChatSidebarMessage(
            role: .user,
            text: trimmedText,
            imageData: followUpScreenshotData,
            timestamp: Date()
        )
        chatSidebarMessages.append(userMessage)
        conversationStore.appendMessage(
            conversationID: activeConversationID,
            message: userMessage,
            screenshotData: followUpScreenshotData
        )

        // Add placeholder assistant message that will be streamed into
        let assistantMessageIndex = chatSidebarMessages.count
        chatSidebarMessages.append(ChatSidebarMessage(
            role: .assistant,
            text: "",
            imageData: nil,
            timestamp: Date()
        ))
        chatSidebarIsStreaming = true

        // Start looping message-delivered animation while streaming (skip in stealth mode)
        if !isStealthModeEnabled {
            spriteAnimationManager.startMessageDeliveredLoop()
        }

        currentResponseTask?.cancel()
        currentResponseTask = Task {
            do {
                let systemPrompt = self.buildTextModeSystemPrompt()

                let messages = self.buildProviderMessages(
                    imageData: followUpScreenshotData,
                    conversationMessages: previousConversationMessages,
                    currentUserPrompt: trimmedText
                )

                let profileOverride = self.activeProfileOverride
                let responseText = try await self.providerManager.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    overrideProviderID: profileOverride?.providerID,
                    overrideModelID: profileOverride?.modelID,
                    onTextChunk: { [weak self] accumulatedText in
                        guard let self, assistantMessageIndex < self.chatSidebarMessages.count else { return }
                        self.chatSidebarMessages[assistantMessageIndex].text = accumulatedText
                    }
                )

                guard !Task.isCancelled else { return }

                if assistantMessageIndex < chatSidebarMessages.count {
                    chatSidebarMessages[assistantMessageIndex].text = responseText
                }
                chatSidebarIsStreaming = false

                // Stop the message-delivered loop (continues for 2s then returns to idle)
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }

                if assistantMessageIndex < chatSidebarMessages.count {
                    let assistantMessage = chatSidebarMessages[assistantMessageIndex]
                    conversationStore.appendMessage(
                        conversationID: activeConversationID,
                        message: assistantMessage
                    )
                }

                print("🧠 Chat sidebar follow-up complete (\(responseText.count) chars)")
            } catch is CancellationError {
                // Cancelled — stop animation immediately
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }
            } catch {
                print("⚠️ Chat sidebar error: \(error)")
                if assistantMessageIndex < chatSidebarMessages.count {
                    chatSidebarMessages[assistantMessageIndex].text = "Error: \(error.localizedDescription)"
                    conversationStore.appendMessage(
                        conversationID: activeConversationID,
                        message: chatSidebarMessages[assistantMessageIndex]
                    )
                }
                chatSidebarIsStreaming = false
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }
            }
        }
    }

    /// Removes a pending follow-up screenshot without sending a message.
    func clearPendingFollowUpScreenshot() {
        pendingFollowUpScreenshotData = nil
    }

    /// Closes the chat sidebar and returns the sprite to patrol.
    func closeChatSidebar() {
        localSpeechTranscriptionManager.cancelActiveSpeechOperation()
        assistFlowPhase = .inactive
        chatSidebarMessages = []
        chatSidebarIsStreaming = false
        activeConversationID = nil
        conversationStore.setProtectedConversation(conversationID: nil)
        assistResponseText = ""
        assistResponseIsStreaming = false
        pendingFollowUpScreenshotData = nil
        isCapturingFollowUpScreenshot = false
        chatSidebarScreenFrameBeforeFollowUpCapture = nil
        // Keep assistCroppedImageData so conversation history retains screenshot context
        // until the next Ctrl+Option interaction

        currentResponseTask?.cancel()
        currentResponseTask = nil

        if isStealthModeEnabled {
            return
        }

        let screenFrame = spriteAnimationManager.currentScreenFrame
        guard screenFrame.width > 0 else { return }

        if spriteAnimationManager.spriteState != .resting {
            spriteAnimationManager.transitionTo(
                .flyingBackToResting,
                targetPosition: nil,
                screenFrame: screenFrame
            )
        }
    }

    /// Whether the user has stored an Anthropic API key in the Keychain.
    @Published var hasAnthropicAPIKey: Bool = KeychainHelper.loadAnthropicAPIKey() != nil

    /// Whether the user has stored an OpenAI API key in the Keychain.
    @Published var hasOpenAIAPIKey: Bool = KeychainHelper.hasAPIKey(for: .openai)

    /// Whether the user has stored an Ollama Cloud API key in the Keychain.
    @Published var hasOllamaCloudAPIKey: Bool = KeychainHelper.hasAPIKey(for: .ollamaCloud)

    func saveAnthropicAPIKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            KeychainHelper.deleteAnthropicAPIKey()
            hasAnthropicAPIKey = false
        } else {
            KeychainHelper.saveAnthropicAPIKey(trimmedKey)
            hasAnthropicAPIKey = true
        }
    }

    func saveOpenAIAPIKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            KeychainHelper.deleteAPIKey(for: .openai)
            hasOpenAIAPIKey = false
        } else {
            KeychainHelper.saveAPIKey(trimmedKey, for: .openai)
            hasOpenAIAPIKey = true
        }
    }

    func saveOllamaCloudAPIKey(_ key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            KeychainHelper.deleteAPIKey(for: .ollamaCloud)
            hasOllamaCloudAPIKey = false
        } else {
            KeychainHelper.saveAPIKey(trimmedKey, for: .ollamaCloud)
            hasOllamaCloudAPIKey = true
        }
    }

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let spriteAnimationManager = SpriteAnimationManager()
    let contextManager = ContextManager()
    let conversationStore = ConversationStore()
    let providerManager = ProviderManager()
    let localSpeechTranscriptionManager = LocalSpeechTranscriptionManager()

    /// Name of the currently active context profile, for display in the speech bubble header.
    var activeContextProfileName: String? {
        contextManager.activeProfile?.name
    }

    /// Gives Whisper a small amount of vocabulary context without sending the
    /// profile anywhere. This is especially useful for science-heavy profiles.
    var localSpeechTranscriptionContextPrompt: String? {
        guard let activeProfile = contextManager.activeProfile else { return nil }
        return "\(activeProfile.name). \(activeProfile.description). \(activeProfile.instructions)"
    }
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all required permissions (accessibility, screen recording,
    /// screen content) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The model ID used for the current provider. Delegates to ProviderManager.
    var selectedModel: String {
        providerManager.currentModelID
    }

    /// When enabled, the Samoyed sprite is hidden but the AI assistant
    /// still works via Ctrl+Option. Persisted to UserDefaults.
    @Published var isStealthModeEnabled: Bool = UserDefaults.standard.bool(forKey: "stealthModeEnabled")

    func setStealthModeEnabled(_ enabled: Bool) {
        isStealthModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "stealthModeEnabled")

        if enabled {
            // Cancel any in-progress assist flow, then hide the sprite
            cancelAssistFlow()
            spriteAnimationManager.stopAnimationTimer()
            spriteAnimationManager.isVisible = false
        } else {
            // Show the sprite and start the walking patrol
            if isOverlayVisible {
                let mainScreenFrame = NSScreen.main?.frame ?? .zero
                spriteAnimationManager.transitionTo(.resting, targetPosition: nil, screenFrame: mainScreenFrame)
                spriteAnimationManager.startAnimationTimer()
            }
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        localSpeechTranscriptionManager.refreshMicrophonePermission()
        print("🔑 Sato start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindShortcutTransitions()

        // Preload all sprite GIF frames at launch so animation playback
        // never hitches waiting on disk I/O. Restore saved sprite preference.
        let savedSpriteDirectory = UserDefaults.standard.string(forKey: "activeSpriteDirectory") ?? "max-animations"
        if savedSpriteDirectory != "max-animations" {
            spriteAnimationManager.switchSpriteAssets(directoryName: savedSpriteDirectory)
        } else {
            spriteAnimationManager.preloadAllAnimations()
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true

            // In stealth mode the overlay is up (for speech bubbles etc.) but
            // the sprite itself stays hidden. Otherwise show it and patrol.
            if !isStealthModeEnabled {
                let mainScreenFrame = NSScreen.main?.frame ?? .zero
                spriteAnimationManager.transitionTo(.resting, targetPosition: nil, screenFrame: mainScreenFrame)
                spriteAnimationManager.startAnimationTimer()
            }
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        let mainScreenFrame = NSScreen.main?.frame ?? .zero
        spriteAnimationManager.transitionTo(.resting, targetPosition: nil, screenFrame: mainScreenFrame)
        spriteAnimationManager.startAnimationTimer()
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        let mainScreenFrame = NSScreen.main?.frame ?? .zero
        spriteAnimationManager.transitionTo(.resting, targetPosition: nil, screenFrame: mainScreenFrame)
        spriteAnimationManager.startAnimationTimer()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Sato: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Sato: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        localSpeechTranscriptionManager.stop()
        overlayWindowManager.hideOverlay()
        spriteAnimationManager.stopAnimationTimer()
        transientHideTask?.cancel()
        spriteReturnTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                        if !isStealthModeEnabled {
                            let mainScreenFrame = NSScreen.main?.frame ?? .zero
                            spriteAnimationManager.transitionTo(.resting, targetPosition: nil, screenFrame: mainScreenFrame)
                            spriteAnimationManager.startAnimationTimer()
                        }
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    // MARK: - Assist (Ctrl+Option)

    /// Starts the text-based assist flow.
    /// - Stealth mode OFF: sprite flies to cursor → bark → screenshot → text → response bubble → fly back
    /// - Stealth mode ON: screenshot selection appears immediately at cursor
    /// - Chat sidebar open: capture a screenshot for the next follow-up turn in the active conversation
    private func handleAssistHotkey() {
        if assistFlowPhase == .chatSidebar {
            startFollowUpScreenshotCapture()
            return
        }

        guard assistFlowPhase == .inactive else {
            print("🐕 Assist: already in assist flow, ignoring")
            return
        }

        // Dismiss the menu bar panel so it doesn't cover the screen
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Cancel any in-progress response
        currentResponseTask?.cancel()
        clearDetectedElementLocation()

        let cursorScreenPosition = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPosition) }) ?? NSScreen.main
        guard let screenFrame = cursorScreen?.frame else { return }

        assistScreenFrame = screenFrame

        // Make sure the overlay is visible for the assist flow UI
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        if isStealthModeEnabled {
            // Stealth: skip fly-to-cursor and bark, go straight to screenshot
            startScreenshotSelectionAfterBark()
        } else {
            // Normal: only start if sprite is resting (not mid-flight)
            guard spriteAnimationManager.spriteState == .resting else {
                print("🐕 Assist: sprite not resting (state: \(spriteAnimationManager.spriteState)), ignoring")
                return
            }

            // Fly the sprite to the cursor — it auto-transitions to
            // .assistingAtCursor on arrival, which triggers the bark and
            // then startScreenshotSelectionAfterBark().
            spriteAnimationManager.transitionTo(
                .flyingToCursor,
                targetPosition: cursorScreenPosition,
                screenFrame: screenFrame
            )
        }
    }

    /// Captures a screenshot for the next turn while keeping the current sidebar conversation open.
    private func startFollowUpScreenshotCapture() {
        guard activeConversationID != nil else { return }
        guard !chatSidebarIsStreaming else {
            print("🐕 Assist: ignoring follow-up screenshot while sidebar is streaming")
            return
        }
        guard !isCapturingFollowUpScreenshot else {
            print("🐕 Assist: follow-up screenshot capture already in progress")
            return
        }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        clearDetectedElementLocation()

        let cursorScreenPosition = NSEvent.mouseLocation
        let cursorScreen = NSScreen.screens.first(where: { $0.frame.contains(cursorScreenPosition) }) ?? NSScreen.main
        guard let screenFrame = cursorScreen?.frame else { return }

        // Keep the chat on its current display; temporarily retarget assist frame
        // so screenshot selection appears on the cursor's screen.
        chatSidebarScreenFrameBeforeFollowUpCapture = assistScreenFrame
        assistScreenFrame = screenFrame

        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        isCapturingFollowUpScreenshot = true
        captureScreenshotForSelectionOverlay()
    }

    private func restoreChatSidebarScreenFrameAfterFollowUpCaptureIfNeeded() {
        guard let chatSidebarScreenFrameBeforeFollowUpCapture else { return }
        assistScreenFrame = chatSidebarScreenFrameBeforeFollowUpCapture
        self.chatSidebarScreenFrameBeforeFollowUpCapture = nil
    }

    /// Called when the sprite arrives at cursor and starts barking (assistingAtCursor).
    /// Captures the screen and shows the screenshot selection overlay.
    func startScreenshotSelectionAfterBark() {
        guard assistFlowPhase == .inactive else { return }
        captureScreenshotForSelectionOverlay()
    }

    /// Captures the cursor screen and transitions into screenshot selection.
    private func captureScreenshotForSelectionOverlay() {
        Task {
            do {
                // Capture just the cursor screen for the selection overlay
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("⚠️ Assist: no cursor screen capture")
                    cancelScreenshotSelection()
                    return
                }

                // Convert JPEG data to NSImage for the selection overlay
                guard let screenshotNSImage = NSImage(data: cursorScreenCapture.imageData) else {
                    print("⚠️ Assist: failed to create NSImage from capture")
                    cancelScreenshotSelection()
                    return
                }

                assistScreenshotImage = screenshotNSImage
                assistFlowPhase = .selectingScreenshot
                print("📸 Assist: screenshot captured, showing selection overlay")
            } catch {
                print("⚠️ Assist: screenshot capture failed: \(error)")
                cancelScreenshotSelection()
            }
        }
    }

    /// Called when the user confirms a screenshot selection region.
    func handleScreenshotSelectionConfirmed(croppedImageData: Data, selectionRect: CGRect) {
        assistScreenshotImage = nil

        if isCapturingFollowUpScreenshot, activeConversationID != nil {
            pendingFollowUpScreenshotData = croppedImageData
            isCapturingFollowUpScreenshot = false
            restoreChatSidebarScreenFrameAfterFollowUpCaptureIfNeeded()
            assistFlowPhase = .chatSidebar
            print("✂️ Assist: follow-up screenshot ready (\(Int(selectionRect.width))×\(Int(selectionRect.height)))")
            return
        }

        assistCroppedImageData = croppedImageData
        assistFlowPhase = .typingQuestion
        print("✂️ Assist: selection confirmed (\(Int(selectionRect.width))×\(Int(selectionRect.height))), showing text input")
    }

    /// Cancels screenshot selection. Follow-up captures return to the open sidebar
    /// conversation instead of tearing down the active chat.
    func cancelScreenshotSelection() {
        if isCapturingFollowUpScreenshot {
            isCapturingFollowUpScreenshot = false
            assistScreenshotImage = nil
            restoreChatSidebarScreenFrameAfterFollowUpCaptureIfNeeded()
            assistFlowPhase = .chatSidebar
            print("✂️ Assist: follow-up screenshot capture cancelled")
            return
        }

        cancelAssistFlow()
    }

    /// Called when the user submits their text question.
    func handleTextQuestionSubmitted(questionText: String) {
        guard let imageData = assistCroppedImageData else {
            cancelAssistFlow()
            return
        }

        let userMessage = ChatSidebarMessage(
            role: .user,
            text: questionText,
            imageData: imageData,
            timestamp: Date()
        )
        chatSidebarMessages = [userMessage]
        let conversationID = conversationStore.createConversation(
            userMessage: userMessage,
            screenshotData: imageData
        )
        activeConversationID = conversationID
        conversationStore.setProtectedConversation(conversationID: conversationID)
        assistFlowPhase = .showingResponse
        assistResponseText = ""
        assistResponseIsStreaming = true

        // Start looping message-delivered animation while streaming (skip in stealth mode)
        if !isStealthModeEnabled {
            spriteAnimationManager.startMessageDeliveredLoop()
        }

        print("💬 Assist: sending question via \(providerManager.currentProvider.displayName): \(questionText)")

        currentResponseTask?.cancel()
        currentResponseTask = Task {
            do {
                let systemPrompt = self.buildTextModeSystemPrompt()

                let messages = self.buildProviderMessages(
                    imageData: imageData,
                    conversationMessages: [],
                    currentUserPrompt: questionText
                )

                let profileOverride = self.activeProfileOverride
                let responseText = try await self.providerManager.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    overrideProviderID: profileOverride?.providerID,
                    overrideModelID: profileOverride?.modelID,
                    onTextChunk: { [weak self] accumulatedText in
                        self?.assistResponseText = accumulatedText
                    }
                )

                guard !Task.isCancelled else { return }
                assistResponseText = responseText
                assistResponseIsStreaming = false

                let assistantMessage = ChatSidebarMessage(
                    role: .assistant,
                    text: responseText,
                    imageData: nil,
                    timestamp: Date()
                )
                chatSidebarMessages.append(assistantMessage)
                conversationStore.appendMessage(
                    conversationID: conversationID,
                    message: assistantMessage
                )

                print("🧠 Assist: response complete (\(responseText.count) chars)")

                // Stop the message-delivered loop (continues for 2s then returns to idle)
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }

                // If "always open chat sidebar" is enabled, skip the speech bubble
                // and go straight to the sidebar once streaming finishes
                if self.alwaysOpenChatSidebar {
                    self.openChatSidebar()
                }
            } catch is CancellationError {
                // Flow was cancelled — stop animation immediately
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }
            } catch {
                print("⚠️ Assist error: \(error)")
                let errorMessageText = "Error: \(error.localizedDescription)"
                assistResponseText = errorMessageText
                assistResponseIsStreaming = false
                let errorMessage = ChatSidebarMessage(
                    role: .assistant,
                    text: errorMessageText,
                    imageData: nil,
                    timestamp: Date()
                )
                chatSidebarMessages.append(errorMessage)
                conversationStore.appendMessage(
                    conversationID: conversationID,
                    message: errorMessage
                )
                if !self.isStealthModeEnabled {
                    self.spriteAnimationManager.stopMessageDeliveredLoop()
                }
            }
        }
    }

    /// Dismisses the speech bubble and flies the sprite back to resting.
    /// In stealth mode there's no sprite to fly back, so just reset state.
    func dismissAssistResponseAndReturn() {
        assistFlowPhase = .inactive
        assistResponseText = ""
        assistResponseIsStreaming = false
        assistCroppedImageData = nil
        assistScreenshotImage = nil
        pendingFollowUpScreenshotData = nil
        isCapturingFollowUpScreenshot = false
        chatSidebarScreenFrameBeforeFollowUpCapture = nil
        chatSidebarMessages = []
        chatSidebarIsStreaming = false
        activeConversationID = nil
        conversationStore.setProtectedConversation(conversationID: nil)

        if isStealthModeEnabled {
            return
        }

        let screenFrame = spriteAnimationManager.currentScreenFrame
        guard screenFrame.width > 0 else { return }

        spriteAnimationManager.transitionTo(
            .flyingBackToResting,
            targetPosition: nil,
            screenFrame: screenFrame
        )
    }

    /// Cancels the assist flow at any phase and returns the sprite to resting.
    func cancelAssistFlow() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        localSpeechTranscriptionManager.cancelActiveSpeechOperation()
        assistFlowPhase = .inactive
        assistResponseText = ""
        assistResponseIsStreaming = false
        assistCroppedImageData = nil
        assistScreenshotImage = nil
        pendingFollowUpScreenshotData = nil
        isCapturingFollowUpScreenshot = false
        chatSidebarScreenFrameBeforeFollowUpCapture = nil
        chatSidebarMessages = []
        chatSidebarIsStreaming = false
        activeConversationID = nil
        conversationStore.setProtectedConversation(conversationID: nil)

        if isStealthModeEnabled {
            return
        }

        let screenFrame = spriteAnimationManager.currentScreenFrame
        guard screenFrame.width > 0 else { return }

        if spriteAnimationManager.spriteState != .resting {
            spriteAnimationManager.transitionTo(
                .flyingBackToResting,
                targetPosition: nil,
                screenFrame: screenFrame
            )
        }
    }

    private func handleShortcutTransition(_ transition: ShortcutTransition) {
        switch transition {
        case .pressed:
            // Don't register while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }

            handleAssistHotkey()

        case .released, .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let textModeSystemPrompt = """
    You are Sato, a helpful AI desktop companion. The user has selected a specific region of their screen to show you — focus your response on what's in that selection.

    Your replies render in a small speech bubble above the user's sprite, so keep responses concise and skimmable. Aim for under 150 words unless the user explicitly asks for more detail or depth. Favor direct answers over preamble. Skip phrases like "I can see that..." or "Looking at your screen..." — just answer.

    When the user asks a follow-up in the chat sidebar, you have access to the full conversation history, including any screenshots attached to earlier turns and any new screenshot attached to the latest turn. Build on that context naturally instead of treating each message as a fresh start.

    If the user has set an active Context Profile (provided below), that describes how they want you to behave for this session. Follow it.
    """

    /// Appends the active context profile to a base system prompt, if one exists.
    private func appendActiveProfileContext(to basePrompt: String) -> String {
        guard let activeProfile = contextManager.activeProfile else {
            return basePrompt
        }
        return """
        \(basePrompt)

        The user has provided the following context for this session:

        Profile: \(activeProfile.name)
        \(activeProfile.instructions)
        """
    }

    /// Builds the full system prompt for text mode with active profile context.
    private func buildTextModeSystemPrompt() -> String {
        appendActiveProfileContext(to: Self.textModeSystemPrompt)
    }

    /// Returns the active profile's provider/model override, if set.
    private var activeProfileOverride: (providerID: String, modelID: String)? {
        guard let profile = contextManager.activeProfile,
              let providerID = profile.overrideProviderID,
              let modelID = profile.overrideModelID
        else {
            return nil
        }
        return (providerID, modelID)
    }

    /// Converts the active conversation and current user prompt into the
    /// unified AIProviderMessage array expected by all providers.
    /// Historical turns keep any attached screenshots so follow-ups can reference
    /// earlier images without reattaching them to the latest prompt.
    private func buildProviderMessages(
        imageData: Data?,
        conversationMessages: [ChatSidebarMessage],
        currentUserPrompt: String
    ) -> [AIProviderMessage] {
        var messages: [AIProviderMessage] = []

        for conversationMessage in conversationMessages.suffix(60) {
            let providerRole: AIProviderMessage.Role = conversationMessage.role == .user
                ? .user
                : .assistant
            let historicalImages = conversationMessage.imageData.map { [$0] }
            messages.append(
                AIProviderMessage(
                    role: providerRole,
                    text: conversationMessage.text,
                    images: historicalImages
                )
            )
        }

        let images: [Data]? = imageData.map { [$0] }
        messages.append(AIProviderMessage(role: .user, text: currentUserPrompt, images: images))

        return messages
    }

    /// In stealth mode, waits for any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another interaction.
    private func scheduleTransientHideIfNeeded() {
        guard isStealthModeEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// After an interaction finishes and there's no element to point at,
    /// waits for any pointing animation to finish, then sends the sprite
    /// back to its resting position. If element pointing IS happening,
    /// the sprite flies back after the pointing animation (handled in BlueCursorView).
    private var spriteReturnTask: Task<Void, Never>?

    private func scheduleSpriteReturnToRestingIfNeeded() {
        // Don't return if element pointing is about to happen — the pointing
        // flow in BlueCursorView handles the return-to-resting after the bubble.
        guard detectedElementScreenLocation == nil else { return }
        guard spriteAnimationManager.spriteState == .assistingAtCursor else { return }

        spriteReturnTask?.cancel()
        spriteReturnTask = Task {
            // Wait for any pointing animation to finish
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Brief pause after everything finishes so it doesn't feel abrupt
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }

            let mainScreenFrame = NSScreen.main?.frame ?? .zero
            spriteAnimationManager.transitionTo(
                .flyingBackToResting,
                targetPosition: nil,
                screenFrame: mainScreenFrame
            )
        }
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    /// The video plays in a dedicated floating window with playback controls
    /// and a close button (managed by OverlayWindowManager).
    func setupOnboardingVideo() {
        guard let videoURL = Bundle.main.url(forResource: "onboarding", withExtension: "mp4") else {
            print("⚠️ Sato: onboarding.mp4 not found in bundle")
            return
        }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true

        // Show the video in a dedicated floating window with playback controls
        overlayWindowManager.showOnboardingVideoWindow(player: player) { [weak self] in
            self?.dismissOnboardingVideo()
        }

        // Start playback and fade audio in over 2 seconds
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Sato flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Clean up when the video finishes playing naturally
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.dismissOnboardingVideo()
        }
    }

    /// Dismisses the onboarding video window and proceeds to the post-video prompt.
    /// Called when the user clicks the close button or the video finishes playing.
    /// Guards against double-calling since both events can fire.
    func dismissOnboardingVideo() {
        guard showOnboardingVideo else { return }
        overlayWindowManager.hideOnboardingVideoWindow()
        tearDownOnboardingVideo()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startOnboardingPromptStream()
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're sato, a friendly Samoyed dog buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let onboardingMessages = [
                    AIProviderMessage(
                        role: .user,
                        text: "look around my screen and find something interesting to point at (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)",
                        images: [cursorScreenCapture.imageData]
                    ),
                ]

                let fullResponseText = try await self.providerManager.streamChat(
                    messages: onboardingMessages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
