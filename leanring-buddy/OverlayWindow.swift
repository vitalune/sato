//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import AppKit
import AVFoundation
import SwiftUI

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral)
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var spriteAnimationManager: SpriteAnimationManager

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager, spriteAnimationManager: SpriteAnimationManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager
        self.spriteAnimationManager = spriteAnimationManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: CGPoint(x: localX + 35, y: localY + 25))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var timer: Timer?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0


    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm clicky"

    private let navigationPointerPhrases = [
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!"
    ]

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — "press control + option and say hi" streamed after video ends
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                    .animation(.easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(
                                color: DS.Colors.overlayCursorBlue.opacity(0.5 + (1.0 - navigationBubbleScale) * 1.0),
                                radius: 6 + (1.0 - navigationBubbleScale) * 16,
                                x: 0, y: 0
                            )
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(
                        x: spriteAnimationManager.spriteScreenPosition.x + 78 + (navigationBubbleSize.width / 2),
                        y: spriteAnimationManager.spriteScreenPosition.y - 60
                    )
                    .animation(nil, value: spriteAnimationManager.spriteScreenPosition)
                    .animation(.spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(.easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Samoyed sprite — shown when idle or while TTS is playing (responding).
            // The sprite's position is driven at 60fps by SpriteAnimationManager,
            // so no implicit SwiftUI animation is applied to position changes.
            // Hidden during listening/processing so the waveform/spinner take over.
            SamoyedSpriteView(spriteAnimationManager: spriteAnimationManager)
                .opacity(spriteIsVisibleOnThisScreen && !companionManager.isStealthModeEnabled && (companionManager.voiceState == .idle || companionManager.voiceState == .responding || companionManager.assistFlowPhase != .inactive) ? cursorOpacity : 0)
                .position(spriteAnimationManager.spriteScreenPosition)
                .animation(nil, value: spriteAnimationManager.spriteScreenPosition)
                .animation(.easeIn(duration: 0.25), value: companionManager.voiceState)

            // Blue waveform — replaces the triangle while listening
            BlueCursorWaveformView(audioPowerLevel: companionManager.currentAudioPowerLevel)
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .listening ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Blue spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            BlueCursorSpinnerView()
                .opacity(buddyIsVisibleOnThisScreen && companionManager.voiceState == .processing ? cursorOpacity : 0)
                .position(cursorPosition)
                .animation(.spring(response: 0.2, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                .animation(.easeIn(duration: 0.15), value: companionManager.voiceState)

            // Speech bubble for text-mode assist responses.
            // In normal mode: positioned above the sprite.
            // In stealth mode: positioned near the cursor.
            if companionManager.assistFlowPhase == .showingResponse
                && !companionManager.assistResponseText.isEmpty
                && (spriteIsVisibleOnThisScreen || (companionManager.isStealthModeEnabled && isThisScreenTheAssistScreen)) {
                SpeechBubbleView(
                    responseText: companionManager.assistResponseText,
                    isStreaming: companionManager.assistResponseIsStreaming,
                    activeProfileName: companionManager.activeContextProfileName,
                    onDismiss: {
                        companionManager.dismissAssistResponseAndReturn()
                    }
                )
                .position(
                    x: companionManager.isStealthModeEnabled ? cursorPosition.x : spriteAnimationManager.spriteScreenPosition.x,
                    y: companionManager.isStealthModeEnabled ? max(cursorPosition.y - 120, 100) : spriteAnimationManager.spriteScreenPosition.y - 180
                )
                .animation(nil, value: spriteAnimationManager.spriteScreenPosition)
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: .opacity.combined(with: .scale(scale: 0.95)).animation(.easeIn(duration: 0.12))
                ))
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = CGPoint(x: swiftUIPosition.x + 35, y: swiftUIPosition.y + 25)

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                    startWelcomeAnimation()
                }
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            timer?.invalidate()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.detectedElementScreenLocation) { newLocation in
            // When a UI element location is detected, fly the sprite to
            // that position so it points at the element.
            guard let screenLocation = newLocation,
                  let displayFrame = companionManager.detectedElementDisplayFrame else {
                return
            }

            // Only navigate if the target is on THIS screen
            guard screenFrame.contains(CGPoint(x: displayFrame.midX, y: displayFrame.midY))
                  || displayFrame == screenFrame else {
                return
            }

            startNavigatingToElement(screenLocation: screenLocation)
        }
        .onChange(of: spriteAnimationManager.spriteState) { newState in
            // When the sprite arrives at an element (bark animation starts),
            // begin the speech bubble pointing animation.
            if newState == .pointingAtElement {
                startPointingBubble()
            }
            // When the sprite returns to resting, clean up navigation state.
            if newState == .resting && buddyNavigationMode != .followingCursor {
                finishNavigationAndResumeFollowing()
            }
            // When the sprite arrives at cursor during an assist flow,
            // trigger the screenshot capture after the bark plays.
            if newState == .assistingAtCursor && companionManager.assistFlowPhase == .inactive {
                // Brief delay so the bark animation plays before the selection overlay appears
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard self.companionManager.assistFlowPhase == .inactive,
                          self.spriteAnimationManager.spriteState == .assistingAtCursor else { return }
                    self.companionManager.startScreenshotSelectionAfterBark()
                }
            }
        }
        .onChange(of: companionManager.assistFlowPhase) { newPhase in
            handleAssistFlowPhaseChange(newPhase)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy
            if companionManager.detectedElementScreenLocation != nil {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    /// Whether this screen is where the current assist flow is happening.
    /// Used in stealth mode to show the speech bubble on the correct screen.
    private var isThisScreenTheAssistScreen: Bool {
        let assistFrame = companionManager.assistScreenFrame
        return abs(assistFrame.origin.x - screenFrame.origin.x) < 1
            && abs(assistFrame.origin.y - screenFrame.origin.y) < 1
            && abs(assistFrame.width - screenFrame.width) < 1
            && abs(assistFrame.height - screenFrame.height) < 1
    }

    /// Whether the Samoyed sprite should render on THIS screen.
    /// The sprite lives on whichever screen its currentScreenFrame matches.
    private var spriteIsVisibleOnThisScreen: Bool {
        // Check if the sprite's current screen matches this view's screen.
        // Compare origins and sizes with a small tolerance for floating point.
        let spriteFrame = spriteAnimationManager.currentScreenFrame
        return abs(spriteFrame.origin.x - screenFrame.origin.x) < 1
            && abs(spriteFrame.origin.y - screenFrame.origin.y) < 1
            && abs(spriteFrame.width - screenFrame.width) < 1
            && abs(spriteFrame.height - screenFrame.height) < 1
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            let mouseLocation = NSEvent.mouseLocation
            self.isCursorOnThisScreen = self.screenFrame.contains(mouseLocation)

            // Update cursorPosition for the waveform and spinner, which still
            // render at the mouse cursor location during listening/processing.
            let swiftUIPosition = self.convertScreenPointToSwiftUICoordinates(mouseLocation)
            let buddyX = swiftUIPosition.x + 35
            let buddyY = swiftUIPosition.y + 25
            self.cursorPosition = CGPoint(x: buddyX, y: buddyY)
        }
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts flying the sprite toward a detected UI element location.
    /// Movement is handled by SpriteAnimationManager; this method just
    /// triggers the state transition and sets up navigation mode.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }

        buddyNavigationMode = .navigatingToTarget

        // Tell the sprite to fly to the element. SpriteAnimationManager
        // handles the flight interpolation and auto-transitions to
        // .pointingAtElement on arrival (which triggers startPointingBubble
        // via the onChange observer).
        spriteAnimationManager.transitionTo(
            .flyingToElement,
            targetPosition: screenLocation,
            screenFrame: screenFrame
        )
    }

    /// Shows the speech bubble when the sprite arrives at a detected element.
    /// Called from the onChange(of: spriteState) observer when the sprite
    /// transitions to .pointingAtElement.
    private func startPointingBubble() {
        buddyNavigationMode = .pointingAtTarget

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = 0.5

        // Use custom bubble text from the companion manager (e.g. onboarding demo)
        // if available, otherwise fall back to a random pointer phrase
        let pointerPhrase = companionManager.detectedElementBubbleText
            ?? navigationPointerPhrases.randomElement()
            ?? "right here!"

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget else { return }
                    self.startFlyingBackToResting()
                }
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        guard buddyNavigationMode == .pointingAtTarget else { return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the sprite back to its resting position at the bottom of the
    /// screen after the pointing bubble is dismissed.
    private func startFlyingBackToResting() {
        buddyNavigationMode = .navigatingToTarget

        spriteAnimationManager.transitionTo(
            .flyingBackToResting,
            targetPosition: nil,
            screenFrame: screenFrame
        )
    }

    /// Resets navigation state after the sprite returns to resting.
    /// Called from the onChange(of: spriteState) observer when the sprite
    /// transitions back to .resting.
    private func finishNavigationAndResumeFollowing() {
        buddyNavigationMode = .followingCursor
        navigationBubbleText = ""
        navigationBubbleOpacity = 0.0
        navigationBubbleScale = 1.0
        companionManager.clearDetectedElementLocation()
    }

    // MARK: - Assist Flow Phase Handling

    /// Shows or hides interactive overlays in response to assist flow phase changes.
    /// Screenshot selection and text input use an InteractiveOverlayWindow because
    /// they need mouse/keyboard input, which the regular click-through overlay can't provide.
    private func handleAssistFlowPhaseChange(_ newPhase: AssistFlowPhase) {
        // In stealth mode, the sprite isn't on any screen, so check assistScreenFrame instead.
        guard spriteIsVisibleOnThisScreen || (companionManager.isStealthModeEnabled && isThisScreenTheAssistScreen) else { return }

        switch newPhase {
        case .inactive:
            companionManager.overlayWindowManager.removeSpeechBubbleKeyMonitor()
            companionManager.overlayWindowManager.hideInteractiveOverlay()
            companionManager.overlayWindowManager.hideChatSidebar()

        case .selectingScreenshot:
            companionManager.overlayWindowManager.removeSpeechBubbleKeyMonitor()
            guard let screenshotImage = companionManager.assistScreenshotImage else { return }
            let selectionView = ScreenshotSelectionView(
                screenshotImage: screenshotImage,
                screenFrame: screenFrame,
                onConfirm: { [weak companionManager] croppedData, selectionRect in
                    companionManager?.handleScreenshotSelectionConfirmed(croppedImageData: croppedData, selectionRect: selectionRect)
                },
                onCancel: { [weak companionManager] in
                    companionManager?.cancelAssistFlow()
                }
            )
            guard let screen = NSScreen.screens.first(where: {
                abs($0.frame.origin.x - screenFrame.origin.x) < 1
                && abs($0.frame.origin.y - screenFrame.origin.y) < 1
            }) else { return }
            companionManager.overlayWindowManager.showInteractiveOverlay(on: screen, contentView: selectionView)

        case .typingQuestion:
            companionManager.overlayWindowManager.removeSpeechBubbleKeyMonitor()
            companionManager.overlayWindowManager.hideInteractiveOverlay()

            // Show text input in an interactive overlay positioned near the sprite
            let textInputOverlayContent = ZStack {
                Color.black.opacity(0.001) // Fill to capture outside clicks for dismissal

                TextInputView(
                    onSubmit: { [weak companionManager] questionText in
                        companionManager?.handleTextQuestionSubmitted(questionText: questionText)
                    },
                    onCancel: { [weak companionManager] in
                        companionManager?.cancelAssistFlow()
                    }
                )
                .position(
                    x: companionManager.isStealthModeEnabled ? cursorPosition.x : spriteAnimationManager.spriteScreenPosition.x,
                    y: companionManager.isStealthModeEnabled ? cursorPosition.y - 60 : spriteAnimationManager.spriteScreenPosition.y - 100
                )
            }
            .frame(width: screenFrame.width, height: screenFrame.height)

            guard let screen = NSScreen.screens.first(where: {
                abs($0.frame.origin.x - screenFrame.origin.x) < 1
                && abs($0.frame.origin.y - screenFrame.origin.y) < 1
            }) else { return }
            companionManager.overlayWindowManager.showInteractiveOverlay(on: screen, contentView: textInputOverlayContent, installKeyMonitor: false)

        case .showingResponse:
            companionManager.overlayWindowManager.hideInteractiveOverlay()
            companionManager.overlayWindowManager.hideChatSidebar()
            // Install Tab/Escape key monitor so the user can expand into the
            // chat sidebar or dismiss the bubble via keyboard
            companionManager.overlayWindowManager.installSpeechBubbleKeyMonitor(
                onTab: { [weak companionManager] in
                    companionManager?.openChatSidebar()
                },
                onEscape: { [weak companionManager] in
                    companionManager?.dismissAssistResponseAndReturn()
                }
            )
            // Speech bubble is rendered in the main overlay's BlueCursorView body
            // Auto-dismiss after 15 seconds if not manually dismissed
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak companionManager] in
                guard let companionManager,
                      companionManager.assistFlowPhase == .showingResponse,
                      !companionManager.assistResponseIsStreaming else { return }
                companionManager.dismissAssistResponseAndReturn()
            }

        case .chatSidebar:
            companionManager.overlayWindowManager.removeSpeechBubbleKeyMonitor()
            companionManager.overlayWindowManager.hideInteractiveOverlay()
            // Show the chat sidebar on the assist screen
            guard let screen = NSScreen.screens.first(where: {
                abs($0.frame.origin.x - screenFrame.origin.x) < 1
                && abs($0.frame.origin.y - screenFrame.origin.y) < 1
            }) else { return }
            companionManager.overlayWindowManager.showChatSidebar(on: screen, companionManager: companionManager)
        }
    }

    // MARK: - Welcome Animation

    private func startWelcomeAnimation() {
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < self.fullWelcomeMessage.count else {
                timer.invalidate()
                // Hold the text for 2 seconds, then fade it out
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.bubbleOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.showWelcome = false
                    // Start the onboarding video right after the welcome text disappears
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(self.fullWelcomeMessage.startIndex, offsetBy: currentIndex)
            self.welcomeText.append(self.fullWelcomeMessage[index])
            currentIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat

    private let barCount = 5
    private let listeningBarProfile: [CGFloat] = [0.4, 0.7, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { barIndex in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                        .frame(
                            width: 2,
                            height: barHeight(
                                for: barIndex,
                                timelineDate: timelineContext.date
                            )
                        )
                }
            }
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private func barHeight(for barIndex: Int, timelineDate: Date) -> CGFloat {
        let animationPhase = CGFloat(timelineDate.timeIntervalSinceReferenceDate * 3.6) + CGFloat(barIndex) * 0.35
        let normalizedAudioPowerLevel = max(audioPowerLevel - 0.008, 0)
        let easedAudioPowerLevel = pow(min(normalizedAudioPowerLevel * 2.85, 1), 0.76)
        let reactiveHeight = easedAudioPowerLevel * 10 * listeningBarProfile[barIndex]
        let idlePulse = (sin(animationPhase) + 1) / 2 * 1.5
        return 3 + reactiveHeight + idlePulse
    }
}

// MARK: - Blue Cursor Spinner

/// A small blue spinning indicator that replaces the triangle cursor
/// while the AI is processing a voice input.
private struct BlueCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayCursorBlue.opacity(0.0),
                        DS.Colors.overlayCursorBlue
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}

// MARK: - Interactive Overlay Window

/// A full-screen overlay window that accepts mouse and keyboard events.
/// Used for the screenshot selection and text input phases of the assist flow.
/// Unlike the regular OverlayWindow, this window can become key and accepts clicks.
class InteractiveOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.ignoresMouseEvents = false // Accepts mouse events
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.setFrame(screen.frame, display: true)

        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Handle Enter and Escape key events and forward them via notifications
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Enter/Return
            NotificationCenter.default.post(name: .assistOverlayEnterPressed, object: nil)
        case 53: // Escape
            NotificationCenter.default.post(name: .assistOverlayCancelPressed, object: nil)
        default:
            super.keyDown(with: event)
        }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    private var interactiveOverlayWindow: InteractiveOverlayWindow?
    /// The chat sidebar window, shown when the user expands a response.
    private var chatSidebarWindow: InteractiveOverlayWindow?
    /// Local key event monitor installed while the interactive overlay is visible.
    /// Intercepts Enter and Escape at the app level so they reliably reach the
    /// screenshot selection and text input views — NSHostingView can otherwise
    /// consume key events before they reach the window's keyDown override.
    private var interactiveKeyEventMonitor: Any?
    /// Global key event monitor for Tab/Escape while the speech bubble is visible.
    /// Uses a global monitor so it works even when the app isn't active (menu bar
    /// apps typically aren't). Tab opens the chat sidebar; Escape dismisses.
    private var speechBubbleGlobalKeyMonitor: Any?
    /// Local fallback for the speech bubble key monitor — fires when the app
    /// happens to be active (e.g. user just interacted with the menu bar panel).
    private var speechBubbleLocalKeyMonitor: Any?
    var hasShownOverlayBefore = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        hasShownOverlayBefore = true

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager,
                spriteAnimationManager: companionManager.spriteAnimationManager
            )

            let hostingView = NSHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            overlayWindows.append(window)
            window.orderFrontRegardless()
        }
    }

    /// Shows an interactive overlay for the assist flow (screenshot selection, text input, speech bubble).
    /// This overlay accepts mouse and keyboard events. Placed above the regular overlay.
    /// Shows an interactive overlay for the assist flow (screenshot selection, text input).
    /// - Parameters:
    ///   - screen: The screen to cover with the overlay.
    ///   - contentView: The SwiftUI content to display.
    ///   - installKeyMonitor: Whether to install a local key event monitor for
    ///     Enter/Escape. True for screenshot selection (where SwiftUI has no focused
    ///     element to receive key events). False for text input (where the TextField's
    ///     `.onSubmit` and `.onKeyPress` handle Enter/Escape via SwiftUI).
    func showInteractiveOverlay(on screen: NSScreen, contentView: some View, installKeyMonitor: Bool = true) {
        hideInteractiveOverlay()

        let window = InteractiveOverlayWindow(screen: screen)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = screen.frame
        window.contentView = hostingView
        interactiveOverlayWindow = window
        window.orderFrontRegardless()

        // Activate the app so macOS grants keyboard focus to our window.
        // Without this, makeKey() is silently ignored when the app is
        // in the background (menu bar-only apps are often not "active").
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if installKeyMonitor {
            installInteractiveKeyEventMonitor()
        }
    }

    func hideInteractiveOverlay() {
        removeInteractiveKeyEventMonitor()
        interactiveOverlayWindow?.orderOut(nil)
        interactiveOverlayWindow?.contentView = nil
        interactiveOverlayWindow = nil
    }

    /// Installs a local key event monitor that intercepts Enter and Escape
    /// while the interactive overlay is visible. Posts notifications so
    /// ScreenshotSelectionView and TextInputView can respond. This is more
    /// reliable than the window's keyDown override because NSHostingView
    /// can consume key events before they reach the window.
    private func installInteractiveKeyEventMonitor() {
        removeInteractiveKeyEventMonitor()
        interactiveKeyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 36: // Enter/Return
                NotificationCenter.default.post(name: .assistOverlayEnterPressed, object: nil)
                return nil // Consume the event
            case 53: // Escape
                NotificationCenter.default.post(name: .assistOverlayCancelPressed, object: nil)
                return nil
            default:
                return event
            }
        }
    }

    private func removeInteractiveKeyEventMonitor() {
        if let monitor = interactiveKeyEventMonitor {
            NSEvent.removeMonitor(monitor)
            interactiveKeyEventMonitor = nil
        }
    }

    // MARK: - Speech Bubble Key Monitor

    /// Installs global and local key monitors for Tab (open sidebar) and Escape
    /// (dismiss bubble) while the speech bubble is visible. The global monitor
    /// catches keys even when the app isn't active; the local monitor catches
    /// keys when the app is active (and can consume them to prevent pass-through).
    func installSpeechBubbleKeyMonitor(onTab: @escaping () -> Void, onEscape: @escaping () -> Void) {
        removeSpeechBubbleKeyMonitor()

        speechBubbleGlobalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 48: // Tab
                onTab()
            case 53: // Escape
                onEscape()
            default:
                break
            }
        }

        speechBubbleLocalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 48: // Tab
                onTab()
                return nil // Consume the event
            case 53: // Escape
                onEscape()
                return nil
            default:
                return event
            }
        }
    }

    func removeSpeechBubbleKeyMonitor() {
        if let monitor = speechBubbleGlobalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            speechBubbleGlobalKeyMonitor = nil
        }
        if let monitor = speechBubbleLocalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            speechBubbleLocalKeyMonitor = nil
        }
    }

    // MARK: - Chat Sidebar

    /// Shows the chat sidebar anchored to the right edge of the given screen.
    /// The sidebar slides in with an animation.
    func showChatSidebar(on screen: NSScreen, companionManager: CompanionManager) {
        hideChatSidebar()

        let sidebarWidth: CGFloat = 380
        let verticalPadding: CGFloat = 40
        let sidebarHeight = screen.frame.height - (verticalPadding * 2)

        // Position at the right edge of the screen
        let sidebarFrame = NSRect(
            x: screen.frame.maxX - sidebarWidth,
            y: screen.frame.origin.y + verticalPadding,
            width: sidebarWidth,
            height: sidebarHeight
        )

        let window = InteractiveOverlayWindow(screen: screen)
        window.setFrame(sidebarFrame, display: true)
        window.isOpaque = false
        window.backgroundColor = .clear

        let sidebarView = ChatSidebarView(
            companionManager: companionManager,
            onClose: { [weak companionManager] in
                companionManager?.closeChatSidebar()
            }
        )
        .frame(width: sidebarWidth, height: sidebarHeight)

        let hostingView = NSHostingView(rootView: sidebarView)
        hostingView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: sidebarHeight)
        window.contentView = hostingView

        // Start off-screen to the right for slide-in animation
        let offScreenFrame = NSRect(
            x: screen.frame.maxX,
            y: sidebarFrame.origin.y,
            width: sidebarWidth,
            height: sidebarHeight
        )
        window.setFrame(offScreenFrame, display: false)
        window.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Animate slide-in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(sidebarFrame, display: true)
        }

        chatSidebarWindow = window
    }

    /// Hides the chat sidebar with a slide-out animation.
    func hideChatSidebar() {
        guard let window = chatSidebarWindow else { return }
        chatSidebarWindow = nil

        let currentFrame = window.frame
        let offScreenFrame = NSRect(
            x: currentFrame.maxX,
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: currentFrame.height
        )

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().setFrame(offScreenFrame, display: true)
        }, completionHandler: {
            window.orderOut(nil)
            window.contentView = nil
        })
    }

    func hideOverlay() {
        removeSpeechBubbleKeyMonitor()
        hideInteractiveOverlay()
        hideChatSidebar()
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        hideInteractiveOverlay()
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
