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
import AVKit
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
// triangle when it is.
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

    private let onboardingVideoPlayerWidth: CGFloat = 480
    private let onboardingVideoPlayerHeight: CGFloat = 270

    private let fullWelcomeMessage = "hey! i'm sato"

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

            // Onboarding video is now shown in a dedicated floating window
            // (managed by OverlayWindowManager) so it can have interactive
            // playback controls and a close button.

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

            // Samoyed sprite — position is driven at 60fps by SpriteAnimationManager,
            // so no implicit SwiftUI animation is applied to position changes.
            SamoyedSpriteView(spriteAnimationManager: spriteAnimationManager)
                .opacity(spriteIsVisibleOnThisScreen && !companionManager.isStealthModeEnabled ? cursorOpacity : 0)
                .position(spriteAnimationManager.spriteScreenPosition)
                .animation(nil, value: spriteAnimationManager.spriteScreenPosition)

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

            // Update cursorPosition for overlay elements that track the mouse.
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
        // Chat and follow-up screenshot capture are targeted to the assist screen,
        // including when a saved conversation is opened from the menu.
        if newPhase == .chatSidebar || newPhase == .selectingScreenshot {
            guard isThisScreenTheAssistScreen
                    || spriteIsVisibleOnThisScreen
                    || (companionManager.isStealthModeEnabled && isThisScreenTheAssistScreen)
            else {
                return
            }
        } else {
            // In stealth mode, the sprite isn't on any screen, so check the
            // assist frame for the typing and response phases.
            guard spriteIsVisibleOnThisScreen
                    || (companionManager.isStealthModeEnabled && isThisScreenTheAssistScreen)
            else {
                return
            }
        }

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
                    companionManager?.cancelScreenshotSelection()
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

// MARK: - Chat Window

enum ChatWindowGeometry {
    static let defaultSidebarWidth: CGFloat = 380
    static let minimumWidth: CGFloat = 320
    static let maximumWidth: CGFloat = 640
    static let minimumFloatingHeight: CGFloat = 240
    static let defaultFloatingHeight: CGFloat = 320
    static let verticalPadding: CGFloat = 40
    static let dockingThreshold: CGFloat = 24

    static func dockedFrame(
        visibleScreenFrame: CGRect,
        dockSide: ChatWindowDockSide,
        requestedWidth: CGFloat
    ) -> CGRect {
        let maximumAllowedWidth = min(maximumWidth, visibleScreenFrame.width * 0.55)
        let sidebarWidth = min(
            max(requestedWidth, minimumWidth),
            maximumAllowedWidth
        )
        let sidebarHeight = max(
            minimumFloatingHeight,
            visibleScreenFrame.height - (verticalPadding * 2)
        )
        let sidebarOriginX = dockSide == .left
            ? visibleScreenFrame.minX
            : visibleScreenFrame.maxX - sidebarWidth

        return CGRect(
            x: sidebarOriginX,
            y: visibleScreenFrame.minY + verticalPadding,
            width: sidebarWidth,
            height: sidebarHeight
        )
    }

    static func dockingSide(
        dropLocation: CGPoint,
        visibleScreenFrame: CGRect,
        threshold: CGFloat = dockingThreshold
    ) -> ChatWindowDockSide? {
        if dropLocation.x <= visibleScreenFrame.minX + threshold {
            return .left
        }
        if dropLocation.x >= visibleScreenFrame.maxX - threshold {
            return .right
        }
        return nil
    }

    static func clampedFloatingFrame(
        floatingFrame: CGRect,
        visibleScreenFrame: CGRect
    ) -> CGRect {
        let clampedWidth = min(
            max(floatingFrame.width, minimumWidth),
            visibleScreenFrame.width
        )
        let clampedHeight = min(
            max(floatingFrame.height, minimumFloatingHeight),
            visibleScreenFrame.height
        )
        let clampedOriginX = min(
            max(floatingFrame.minX, visibleScreenFrame.minX),
            visibleScreenFrame.maxX - clampedWidth
        )
        let clampedOriginY = min(
            max(floatingFrame.minY, visibleScreenFrame.minY),
            visibleScreenFrame.maxY - clampedHeight
        )

        return CGRect(
            x: clampedOriginX,
            y: clampedOriginY,
            width: clampedWidth,
            height: clampedHeight
        )
    }

    static func translatedFloatingFrame(
        floatingFrame: CGRect,
        sourceVisibleScreenFrame: CGRect,
        targetVisibleScreenFrame: CGRect
    ) -> CGRect {
        let sourceHorizontalTravel = max(
            1,
            sourceVisibleScreenFrame.width - floatingFrame.width
        )
        let sourceVerticalTravel = max(
            1,
            sourceVisibleScreenFrame.height - floatingFrame.height
        )
        let horizontalProgress = min(
            max(
                (floatingFrame.minX - sourceVisibleScreenFrame.minX)
                    / sourceHorizontalTravel,
                0
            ),
            1
        )
        let verticalProgress = min(
            max(
                (floatingFrame.minY - sourceVisibleScreenFrame.minY)
                    / sourceVerticalTravel,
                0
            ),
            1
        )
        let targetHorizontalTravel = max(
            0,
            targetVisibleScreenFrame.width - floatingFrame.width
        )
        let targetVerticalTravel = max(
            0,
            targetVisibleScreenFrame.height - floatingFrame.height
        )
        let translatedFrame = CGRect(
            x: targetVisibleScreenFrame.minX
                + (targetHorizontalTravel * horizontalProgress),
            y: targetVisibleScreenFrame.minY
                + (targetVerticalTravel * verticalProgress),
            width: floatingFrame.width,
            height: floatingFrame.height
        )

        return clampedFloatingFrame(
            floatingFrame: translatedFrame,
            visibleScreenFrame: targetVisibleScreenFrame
        )
    }
}

private final class ChatPanelWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        isMovable = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager: NSObject, NSWindowDelegate {
    private var overlayWindows: [OverlayWindow] = []
    private var interactiveOverlayWindow: InteractiveOverlayWindow?
    private var chatSidebarWindow: ChatPanelWindow?
    private var chatWindowViewState: ChatWindowViewState?
    /// Dedicated floating window for the onboarding video with playback controls.
    private var onboardingVideoWindow: NSPanel?
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

    // MARK: - Onboarding Video Window

    /// Shows the onboarding video in a dedicated floating window with playback
    /// controls and a close button. Positioned near the current mouse cursor,
    /// clamped to screen bounds so it doesn't go off-screen.
    func showOnboardingVideoWindow(player: AVPlayer, onDismiss: @escaping () -> Void) {
        hideOnboardingVideoWindow()

        let videoWidth: CGFloat = 480
        let videoHeight: CGFloat = 270

        // Position near the current mouse location, offset to the right and below
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        var windowX = mouseLocation.x + 30
        var windowY = mouseLocation.y - videoHeight - 30

        // Clamp to screen bounds — flip to left of cursor if overflowing right
        if windowX + videoWidth > screenFrame.maxX {
            windowX = mouseLocation.x - videoWidth - 30
        }
        if windowY < screenFrame.minY {
            windowY = screenFrame.minY + 10
        }
        if windowX < screenFrame.minX {
            windowX = screenFrame.minX + 10
        }

        let windowFrame = NSRect(x: windowX, y: windowY, width: videoWidth, height: videoHeight)

        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let contentView = OnboardingVideoOverlayView(player: player, onDismiss: onDismiss)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: videoWidth, height: videoHeight)
        panel.contentView = hostingView

        // Start invisible and fade in over 1 second
        panel.alphaValue = 0.0
        onboardingVideoWindow = panel
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 1.0
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1.0
        }
    }

    func hideOnboardingVideoWindow() {
        guard let window = onboardingVideoWindow else { return }
        onboardingVideoWindow = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            window.orderOut(nil)
            window.contentView = nil
        })
    }

    // MARK: - Chat Sidebar

    /// Shows the chat window at the user's most recently selected screen edge.
    func showChatSidebar(on screen: NSScreen, companionManager: CompanionManager) {
        guard chatSidebarWindow == nil else { return }

        let dockSide = preferredChatDockSide
        let sidebarFrame = ChatWindowGeometry.dockedFrame(
            visibleScreenFrame: screen.visibleFrame,
            dockSide: dockSide,
            requestedWidth: ChatWindowGeometry.defaultSidebarWidth
        )
        let windowViewState = ChatWindowViewState(
            presentationMode: .docked(dockSide)
        )
        let window = ChatPanelWindow(contentRect: sidebarFrame)
        window.delegate = self
        window.contentMinSize = NSSize(
            width: ChatWindowGeometry.minimumWidth,
            height: sidebarFrame.height
        )
        window.contentMaxSize = NSSize(
            width: min(ChatWindowGeometry.maximumWidth, screen.visibleFrame.width * 0.55),
            height: sidebarFrame.height
        )

        let sidebarView = ChatSidebarView(
            companionManager: companionManager,
            windowViewState: windowViewState,
            onMinimize: { [weak self] in
                self?.detachChatSidebar()
            },
            onWindowDragEnded: { [weak self] dropLocation in
                self?.finishChatWindowMove(dropLocation: dropLocation)
            },
            onClose: { [weak companionManager] in
                companionManager?.closeChatSidebar()
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        let hostingView = NSHostingView(rootView: sidebarView)
        hostingView.frame = NSRect(origin: .zero, size: sidebarFrame.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        let offScreenOriginX = dockSide == .left
            ? screen.visibleFrame.minX - sidebarFrame.width
            : screen.visibleFrame.maxX
        let offScreenFrame = NSRect(
            x: offScreenOriginX,
            y: sidebarFrame.origin.y,
            width: sidebarFrame.width,
            height: sidebarFrame.height
        )
        window.setFrame(offScreenFrame, display: false)
        chatSidebarWindow = window
        chatWindowViewState = windowViewState
        window.orderFrontRegardless()

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Animate slide-in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(sidebarFrame, display: true)
        }
    }

    /// Hides the chat window using the direction implied by its current mode.
    func hideChatSidebar() {
        guard let window = chatSidebarWindow else { return }
        chatSidebarWindow = nil
        let presentationMode = chatWindowViewState?.presentationMode
        chatWindowViewState = nil
        window.delegate = nil

        switch presentationMode {
        case .docked(let dockSide):
            let currentFrame = window.frame
            let screenFrame = window.screen?.visibleFrame ?? currentFrame
            let offScreenOriginX = dockSide == .left
                ? screenFrame.minX - currentFrame.width
                : screenFrame.maxX
            let offScreenFrame = NSRect(
                x: offScreenOriginX,
                y: currentFrame.origin.y,
                width: currentFrame.width,
                height: currentFrame.height
            )
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(offScreenFrame, display: true)
            }, completionHandler: {
                window.orderOut(nil)
                window.contentView = nil
            })
        case .floating, .none:
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 0
            }, completionHandler: {
                window.orderOut(nil)
                window.contentView = nil
            })
        }
    }

    private var preferredChatDockSide: ChatWindowDockSide {
        let savedDockSide = UserDefaults.standard.string(forKey: "chatWindowDockSide")
        return ChatWindowDockSide(rawValue: savedDockSide ?? "") ?? .right
    }

    func retargetChatSidebar(to screen: NSScreen) {
        guard let window = chatSidebarWindow,
              let presentationMode = chatWindowViewState?.presentationMode
        else {
            return
        }

        switch presentationMode {
        case .docked(let dockSide):
            dockChatSidebar(to: dockSide, on: screen, animated: true)
        case .floating:
            guard window.screen !== screen else { return }

            let sourceVisibleScreenFrame = window.screen?.visibleFrame ?? window.frame
            let targetFrame = ChatWindowGeometry.translatedFloatingFrame(
                floatingFrame: window.frame,
                sourceVisibleScreenFrame: sourceVisibleScreenFrame,
                targetVisibleScreenFrame: screen.visibleFrame
            )
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func detachChatSidebar() {
        guard let window = chatSidebarWindow,
              let windowViewState = chatWindowViewState,
              case .docked = windowViewState.presentationMode,
              let screen = window.screen
        else {
            return
        }

        let visibleScreenFrame = screen.visibleFrame
        let floatingWidth = min(max(window.frame.width, 360), 520)
        let floatingHeight = min(
            ChatWindowGeometry.defaultFloatingHeight,
            visibleScreenFrame.height
        )
        let floatingOriginX = visibleScreenFrame.midX - (floatingWidth / 2)
        let proposedFloatingFrame = NSRect(
            x: floatingOriginX,
            y: visibleScreenFrame.midY - (floatingHeight / 2),
            width: floatingWidth,
            height: floatingHeight
        )
        let floatingFrame = ChatWindowGeometry.clampedFloatingFrame(
            floatingFrame: proposedFloatingFrame,
            visibleScreenFrame: visibleScreenFrame
        )

        windowViewState.presentationMode = .floating
        window.contentMinSize = NSSize(
            width: ChatWindowGeometry.minimumWidth,
            height: ChatWindowGeometry.minimumFloatingHeight
        )
        window.contentMaxSize = NSSize(
            width: min(720, visibleScreenFrame.width),
            height: visibleScreenFrame.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(floatingFrame, display: true)
        }
    }

    private func dockChatSidebar(
        to dockSide: ChatWindowDockSide,
        on screen: NSScreen,
        animated: Bool
    ) {
        guard let window = chatSidebarWindow,
              let windowViewState = chatWindowViewState
        else {
            return
        }

        let dockedFrame = ChatWindowGeometry.dockedFrame(
            visibleScreenFrame: screen.visibleFrame,
            dockSide: dockSide,
            requestedWidth: window.frame.width
        )
        windowViewState.presentationMode = .docked(dockSide)
        UserDefaults.standard.set(dockSide.rawValue, forKey: "chatWindowDockSide")
        window.contentMinSize = NSSize(
            width: ChatWindowGeometry.minimumWidth,
            height: dockedFrame.height
        )
        window.contentMaxSize = NSSize(
            width: min(ChatWindowGeometry.maximumWidth, screen.visibleFrame.width * 0.55),
            height: dockedFrame.height
        )

        guard animated else {
            window.setFrame(dockedFrame, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(dockedFrame, display: true)
        }
    }

    func windowWillResize(
        _ sender: NSWindow,
        to frameSize: NSSize
    ) -> NSSize {
        guard sender === chatSidebarWindow,
              let windowViewState = chatWindowViewState,
              let screen = sender.screen
        else {
            return frameSize
        }

        let maximumAllowedWidth = windowViewState.presentationMode.isFloating
            ? min(720, screen.visibleFrame.width)
            : min(ChatWindowGeometry.maximumWidth, screen.visibleFrame.width * 0.55)
        let constrainedWidth = min(
            max(frameSize.width, ChatWindowGeometry.minimumWidth),
            maximumAllowedWidth
        )

        switch windowViewState.presentationMode {
        case .docked:
            let dockedHeight = max(
                ChatWindowGeometry.minimumFloatingHeight,
                screen.visibleFrame.height - (ChatWindowGeometry.verticalPadding * 2)
            )
            return NSSize(width: constrainedWidth, height: dockedHeight)
        case .floating:
            let constrainedHeight = min(
                max(frameSize.height, ChatWindowGeometry.minimumFloatingHeight),
                screen.visibleFrame.height
            )
            return NSSize(width: constrainedWidth, height: constrainedHeight)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === chatSidebarWindow,
              let windowViewState = chatWindowViewState,
              let screen = window.screen
        else {
            return
        }

        switch windowViewState.presentationMode {
        case .docked(let dockSide):
            dockChatSidebar(to: dockSide, on: screen, animated: false)
        case .floating:
            break
        }
    }

    private func finishChatWindowMove(dropLocation: CGPoint) {
        guard let window = chatSidebarWindow,
              chatWindowViewState?.presentationMode == .floating
        else {
            return
        }

        let dropScreen = NSScreen.screens.first {
            $0.frame.contains(dropLocation)
        } ?? window.screen
        guard let dropScreen else { return }

        if let dockSide = ChatWindowGeometry.dockingSide(
            dropLocation: dropLocation,
            visibleScreenFrame: dropScreen.visibleFrame
        ) {
            dockChatSidebar(to: dockSide, on: dropScreen, animated: true)
        }
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

/// NSViewRepresentable wrapping AVPlayerView from AVKit so the onboarding
/// video has built-in playback controls (play/pause, scrubber).
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// SwiftUI view that displays the onboarding video with playback controls
/// and a close button. Shown in a dedicated floating window managed by
/// OverlayWindowManager.
struct OnboardingVideoOverlayView: View {
    let player: AVPlayer
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            OnboardingVideoPlayerView(player: player)

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.6))
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .buttonStyle(.plain)
            .padding(8)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.4), radius: 12, x: 0, y: 6)
    }
}
