//
//  SpriteAnimationManager.swift
//  leanring-buddy
//
//  Manages the Samoyed sprite's animation frames, position interpolation,
//  and behavioral state machine. Preloads all GIF frames at launch,
//  steps through them at ~8-10 FPS for a pixel art aesthetic, and
//  interpolates the sprite's screen position at 60 FPS for smooth movement.
//

import AppKit
import Combine
import ImageIO

/// The sprite's behavioral state. Controls which animation plays and
/// how the sprite moves (or stays still).
enum SpriteState: Equatable {
    /// Walking patrol along the bottom screen edge. The sprite walks
    /// back and forth between configurable boundaries with brief idle
    /// pauses at each turnaround point.
    case resting
    /// Flying from current position toward the mouse cursor.
    case flyingToCursor
    /// At the cursor — follows it with a slight offset, plays idle animation.
    case assistingAtCursor
    /// Flying toward a detected UI element (Claude [POINT:] tag).
    case flyingToElement
    /// At the element — bark once, then idle while the speech bubble shows.
    case pointingAtElement
    /// Flying back to the resting position at the bottom of the screen.
    case flyingBackToResting
}

@MainActor
final class SpriteAnimationManager: ObservableObject {

    // MARK: - Published State

    /// The current animation frame to render. Pre-scaled to 136x136
    /// with nearest-neighbor interpolation for crisp pixel art.
    @Published private(set) var currentFrame: NSImage?

    /// The sprite's position in SwiftUI coordinates (top-left origin),
    /// relative to the screen it's currently on.
    @Published var spriteScreenPosition: CGPoint = .zero

    /// The sprite's current behavioral state.
    @Published private(set) var spriteState: SpriteState = .resting

    /// Whether the sprite should be rendered. Controlled by the overlay
    /// visibility logic in CompanionManager.
    @Published var isVisible: Bool = false

    /// Which screen the sprite is currently on. BlueCursorView checks
    /// this against its own screenFrame to decide whether to render.
    @Published var currentScreenFrame: CGRect = .zero

    // MARK: - Animation Internals

    /// All preloaded frames, indexed by [animationType][direction].
    private var preloadedFrames: [SpriteAnimationType: [SpriteDirection: [NSImage]]] = [:]

    /// Per-frame durations from GIF metadata, indexed the same way.
    private var preloadedFrameDurations: [SpriteAnimationType: [SpriteDirection: [TimeInterval]]] = [:]

    /// The frame array currently being played.
    private var activeFrames: [NSImage] = []
    private var activeFrameDurations: [TimeInterval] = []
    private var currentFrameIndex: Int = 0
    private var frameTimeAccumulator: TimeInterval = 0.0

    /// Whether the current animation should loop. Bark plays once, everything else loops.
    private var shouldLoopCurrentAnimation: Bool = true

    /// Callback fired when a non-looping animation (bark) finishes its last frame.
    private var onNonLoopingAnimationComplete: (() -> Void)?

    // MARK: - Position Interpolation

    /// Start and end positions for the current flight.
    private var flightStartPosition: CGPoint = .zero
    private var flightEndPosition: CGPoint = .zero

    /// Total duration and elapsed time for the current flight.
    private var flightDuration: TimeInterval = 0.0
    private var flightElapsedTime: TimeInterval = 0.0

    /// True while the sprite is actively interpolating between two positions.
    @Published private(set) var isFlying: Bool = false

    /// Callback fired when a flight arrives at its destination.
    private var onFlightComplete: (() -> Void)?

    // MARK: - Timer

    private var animationTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0.0

    /// Minimum speed in points per second for flight interpolation.
    private static let flightSpeedPointsPerSecond: CGFloat = 900.0

    /// The size at which sprite frames are rendered (2x the 68px native GIF size).
    static let renderedSpriteSize: CGFloat = 136.0

    // MARK: - Sparkle Effect

    /// Whether the arrival sparkle is currently playing. Observed by the overlay.
    @Published private(set) var isSparkleActive: Bool = false

    /// Current sparkle frame index (0–3). The overlay reads this to draw the effect.
    @Published private(set) var sparkleFrameIndex: Int = 0

    /// Position where the sparkle plays (sprite's landing position).
    @Published private(set) var sparklePosition: CGPoint = .zero

    /// Elapsed time in the sparkle animation. Driven by the main tick timer.
    private var sparkleElapsedTime: TimeInterval = 0.0

    /// Total sparkle duration (~0.3 seconds, 4 frames).
    private static let sparkleTotalDuration: TimeInterval = 0.3

    // MARK: - Walking Bob

    /// Vertical bob offset applied to the sprite during walking patrol.
    /// Synced to the animation frame index for a natural step rhythm.
    @Published private(set) var walkingBobOffset: CGFloat = 0.0

    // MARK: - Bark Head Tilt

    /// Vertical offset applied during bark animation for a subtle head-tilt effect.
    @Published private(set) var barkHeadTiltOffset: CGFloat = 0.0

    // MARK: - Walking Patrol (Resting State)

    /// Walking speed in points per second during the resting patrol.
    private static let patrolWalkingSpeed: CGFloat = 120.0

    /// Patrol turns around at this fraction of screen width on the left side.
    private static let patrolLeftBoundaryFraction: CGFloat = 0.20

    /// Patrol turns around at this fraction of screen width on the right side.
    private static let patrolRightBoundaryFraction: CGFloat = 0.80

    /// How long the sprite pauses (playing idle) at each turnaround point.
    private static let patrolTurnaroundPauseDuration: TimeInterval = 0.4

    /// Which horizontal direction the sprite is currently walking during patrol.
    /// `true` = walking east (right), `false` = walking west (left).
    private var patrolMovingEast: Bool = true

    /// Time remaining in the turnaround idle pause. Zero means actively walking.
    private var patrolPauseTimeRemaining: TimeInterval = 0.0

    /// Easing acceleration/deceleration zone at patrol turnarounds (seconds).
    private static let patrolEaseZoneDuration: TimeInterval = 0.3

    /// Tracks how long the sprite has been walking since the last turnaround resume,
    /// used to ease-in from a stop.
    private var patrolTimeSinceResume: TimeInterval = 0.0

    /// Tracks how close the sprite is to the next boundary (seconds until arrival).
    /// Used to ease-out before a stop. Negative means not approaching a boundary.
    private var patrolTimeUntilBoundary: TimeInterval = -1.0

    /// Whether the current flight is heading TO the cursor (ease-out)
    /// or BACK to resting (ease-in-out). Controls which bezier curve is used.
    private var currentFlightIsReturnTrip: Bool = false

    // MARK: - Periodic Bark (Assisting State)

    /// Timer that fires periodic bark animations while assisting at the cursor.
    private var assistingBarkTimer: Timer?

    /// Range for random periodic bark intervals while assisting at the cursor.
    private static let assistingBarkIntervalRange: ClosedRange<TimeInterval> = 3.0...6.0

    // MARK: - GIF Asset Filename Map

    /// Which sprite directory is currently active.
    private(set) var activeSpriteDirectory: String = "max-animations"

    /// Maps (animationType, direction) to the exact GIF filename (without extension).
    /// Only includes directions that have a native asset file — mirrored directions
    /// are synthesized at preload time from their source direction.
    /// Swapped when switching sprites via `switchSpriteAssets(directoryName:)`.
    private var assetFileNames: [SpriteAnimationType: [SpriteDirection: String]] = SpriteAnimationManager.maxAssetFileNames

    private static let maxAssetFileNames: [SpriteAnimationType: [SpriteDirection: String]] = [
        .idle: [
            .south:     "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_south",
            .southEast: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_south-east",
            .east:      "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_east",
            .northEast: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_north-east",
            .north:     "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_north",
            .northWest: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_north-west",
            .southWest: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_idle_south-west",
        ],
        .walking: [
            .east: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_custom-trotting happily, legs moving _east",
            .west: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_custom-trotting happily, legs moving _west",
        ],
        .flying: [
            .northEast: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_custom-The white dog floats weightles_north-east",
            .southWest: "Cute_Samoyed_dog_small_fluffy_white_body_round_fri_custom-The white dog floats weightles_south-west",
        ],
        .bark: [
            .south: "bark",
        ],
        .messageDelivered: [
            .south: "message-delivered-south",
        ],
    ]

    /// Sky (tabby cat) uses simpler filenames and a single idle GIF for all directions.
    private static var skyAssetFileNames: [SpriteAnimationType: [SpriteDirection: String]] {
        var allDirectionsIdle: [SpriteDirection: String] = [:]
        for direction in SpriteDirection.allCases {
            allDirectionsIdle[direction] = "idle"
        }
        return [
            .idle: allDirectionsIdle,
            .walking: [.east: "walk-east", .west: "walk-west"],
            .flying: [.northEast: "jump-east", .southWest: "jump-west"],
            .bark: [.south: "lick"],
            .messageDelivered: allDirectionsIdle,
        ]
    }

    // MARK: - Preloading

    /// Extracts all GIF frames from every animation asset, scales them to
    /// 136x136 with nearest-neighbor interpolation, and creates mirrored
    /// versions for directions that lack a native GIF. Call once at launch.
    func preloadAllAnimations() {
        for animationType in [SpriteAnimationType.idle, .walking, .flying, .bark, .messageDelivered] {
            preloadedFrames[animationType] = [:]
            preloadedFrameDurations[animationType] = [:]

            guard let fileNames = assetFileNames[animationType] else { continue }

            // Load native assets
            for (direction, fileName) in fileNames {
                let (frames, durations) = extractFramesFromGIF(
                    resourceName: fileName,
                    subdirectory: nil,
                    flipHorizontally: false
                )
                if frames.isEmpty {
                    print("⚠️ Sprite: Failed to load \(animationType) \(direction) from \(fileName).gif")
                    continue
                }
                preloadedFrames[animationType]?[direction] = frames
                preloadedFrameDurations[animationType]?[direction] = durations
            }

            // Generate mirrored assets for directions that don't have a native file
            for direction in SpriteDirection.allCases {
                // Skip if we already have frames for this direction
                if preloadedFrames[animationType]?[direction] != nil { continue }

                let resolved = direction.resolveAsset(for: animationType)
                // Only generate if the resolution says to flip (otherwise it would
                // point to an existing direction which we already loaded)
                guard resolved.flipHorizontally else { continue }
                guard let sourceFileNames = assetFileNames[animationType],
                      let sourceFileName = sourceFileNames[resolved.sourceDirection] else { continue }

                let (frames, durations) = extractFramesFromGIF(
                    resourceName: sourceFileName,
                    subdirectory: nil,
                    flipHorizontally: true
                )
                if frames.isEmpty {
                    print("⚠️ Sprite: Failed to generate mirrored \(animationType) \(direction)")
                    continue
                }
                preloadedFrames[animationType]?[direction] = frames
                preloadedFrameDurations[animationType]?[direction] = durations
            }
        }

        let totalDirections = preloadedFrames.values.reduce(0) { $0 + $1.count }
        let totalFrames = preloadedFrames.values.flatMap(\.values).reduce(0) { $0 + $1.count }
        print("🐕 Sprite: Preloaded \(totalDirections) animations, \(totalFrames) total frames")

        let messageDeliveredFrameCount = preloadedFrames[.messageDelivered]?.values.first?.count ?? 0
        print("🐕 Sprite: message-delivered loaded: \(messageDeliveredFrameCount) frames")
    }

    /// Switches the sprite to a different animation directory. Clears all cached
    /// frames, rebuilds the filename map, reloads animations, and restarts patrol.
    func switchSpriteAssets(directoryName: String) {
        activeSpriteDirectory = directoryName

        if directoryName == "sky-animations" {
            assetFileNames = Self.skyAssetFileNames
        } else {
            assetFileNames = Self.maxAssetFileNames
        }

        preloadedFrames.removeAll()
        preloadedFrameDurations.removeAll()
        preloadAllAnimations()

        // Reset to idle so the new sprite is immediately visible
        setAnimation(type: .idle, direction: .south)
    }

    // MARK: - GIF Frame Extraction

    /// Extracts individual frames from a GIF file in the app bundle,
    /// scales each to 136x136 with nearest-neighbor interpolation, and
    /// optionally flips horizontally for mirrored directions.
    private func extractFramesFromGIF(
        resourceName: String,
        subdirectory: String?,
        flipHorizontally: Bool
    ) -> (frames: [NSImage], durations: [TimeInterval]) {
        guard let gifURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: "gif",
            subdirectory: subdirectory
        ) else {
            print("⚠️ Sprite: GIF not found: \(resourceName).gif in \(subdirectory ?? "root")")
            return ([], [])
        }

        guard let imageSource = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else {
            print("⚠️ Sprite: Could not create image source for \(resourceName).gif")
            return ([], [])
        }

        let frameCount = CGImageSourceGetCount(imageSource)
        var frames: [NSImage] = []
        var durations: [TimeInterval] = []

        let targetSize = Int(Self.renderedSpriteSize)

        for frameIndex in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil) else {
                continue
            }

            // Extract frame duration from GIF metadata
            let frameDuration = extractFrameDuration(from: imageSource, atIndex: frameIndex)
            durations.append(frameDuration)

            // Scale to 136x136 with nearest-neighbor interpolation, optionally flipped
            let scaledImage = scaleAndFlipFrame(
                cgImage: cgImage,
                targetSize: targetSize,
                flipHorizontally: flipHorizontally
            )
            frames.append(scaledImage)
        }

        return (frames, durations)
    }

    /// Reads the frame duration from GIF metadata. Falls back to 0.1s
    /// (10 FPS) if the metadata is missing or zero.
    private func extractFrameDuration(from source: CGImageSource, atIndex index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }

        // Prefer unclamped delay time (more accurate), fall back to delay time
        if let unclampedDelay = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double,
           unclampedDelay > 0.0 {
            return unclampedDelay
        }
        if let delay = gifProperties[kCGImagePropertyGIFDelayTime] as? Double,
           delay > 0.0 {
            return delay
        }

        return 0.1
    }

    /// Scales a CGImage to the target size using nearest-neighbor
    /// interpolation (preserving pixel art crispness) and optionally
    /// flips it horizontally for mirrored sprite directions.
    private func scaleAndFlipFrame(
        cgImage: CGImage,
        targetSize: Int,
        flipHorizontally: Bool
    ) -> NSImage {
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(cgImage: cgImage, size: NSSize(width: targetSize, height: targetSize))
        }

        context.interpolationQuality = .none

        if flipHorizontally {
            context.translateBy(x: CGFloat(targetSize), y: 0)
            context.scaleBy(x: -1.0, y: 1.0)
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        guard let scaledCGImage = context.makeImage() else {
            return NSImage(cgImage: cgImage, size: NSSize(width: targetSize, height: targetSize))
        }

        return NSImage(cgImage: scaledCGImage, size: NSSize(width: targetSize, height: targetSize))
    }

    // MARK: - Animation Control

    /// Sets the active animation to the given type and direction.
    /// Looks up the preloaded frames, resolving mirroring if needed,
    /// and resets the frame counter to the first frame.
    func setAnimation(type: SpriteAnimationType, direction: SpriteDirection) {
        let resolved = direction.resolveAsset(for: type)

        // Try the resolved direction first. If not found (e.g. because the
        // mirroring was done at preload time under the *requested* direction
        // key), fall back to the requested direction.
        let frames = preloadedFrames[type]?[direction]
                  ?? preloadedFrames[type]?[resolved.sourceDirection]
        let durations = preloadedFrameDurations[type]?[direction]
                     ?? preloadedFrameDurations[type]?[resolved.sourceDirection]

        guard let frames, let durations, !frames.isEmpty else {
            print("⚠️ Sprite: No frames for \(type) \(direction)")
            return
        }

        activeFrames = frames
        activeFrameDurations = durations
        currentFrameIndex = 0
        frameTimeAccumulator = 0.0
        shouldLoopCurrentAnimation = (type != .bark && type != .messageDelivered)
        currentFrame = activeFrames[0]
    }

    // MARK: - Timer Lifecycle

    /// Starts the 60fps animation timer that drives both frame stepping
    /// and position interpolation.
    func startAnimationTimer() {
        guard animationTimer == nil else { return }
        lastTickTime = CACurrentMediaTime()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Stops the animation timer and any behavioral timers.
    /// Called when the overlay is hidden.
    func stopAnimationTimer() {
        animationTimer?.invalidate()
        animationTimer = nil
        stopAssistingBarkTimer()
    }

    /// Called every ~16.67ms. Advances the animation frame if enough time
    /// has elapsed, and interpolates the sprite's position during flights.
    private func tick() {
        let now = CACurrentMediaTime()
        let deltaTime = now - lastTickTime
        lastTickTime = now

        // Advance animation frame
        stepAnimationFrame(deltaTime: deltaTime)

        // Interpolate position during flight
        if isFlying {
            stepFlightPosition(deltaTime: deltaTime)
        }

        // Walk back and forth along the bottom edge while resting
        if spriteState == .resting {
            stepPatrol(deltaTime: deltaTime)
        } else {
            walkingBobOffset = 0
        }

        // When assisting at cursor, track the mouse position
        if spriteState == .assistingAtCursor {
            updatePositionToFollowCursor()
        }

        // Advance sparkle effect
        stepSparkle(deltaTime: deltaTime)
    }

    /// Advances the sprite animation frame based on elapsed time and
    /// the per-frame duration from GIF metadata.
    private func stepAnimationFrame(deltaTime: TimeInterval) {
        guard !activeFrames.isEmpty else { return }

        frameTimeAccumulator += deltaTime

        let frameDuration = currentFrameIndex < activeFrameDurations.count
            ? activeFrameDurations[currentFrameIndex]
            : 0.1

        if frameTimeAccumulator >= frameDuration {
            frameTimeAccumulator -= frameDuration

            let nextIndex = currentFrameIndex + 1
            if nextIndex >= activeFrames.count {
                if shouldLoopCurrentAnimation {
                    currentFrameIndex = 0
                } else {
                    // Non-looping animation finished — stay on last frame
                    onNonLoopingAnimationComplete?()
                    onNonLoopingAnimationComplete = nil
                    return
                }
            } else {
                currentFrameIndex = nextIndex
            }

            currentFrame = activeFrames[currentFrameIndex]
        }
    }

    // MARK: - Flight Position Interpolation

    /// Begins interpolating the sprite's position from its current location
    /// to the given target. Uses smoothstep easing at ~900 pts/sec.
    private func beginFlight(to targetPosition: CGPoint, completion: @escaping () -> Void) {
        flightStartPosition = spriteScreenPosition
        flightEndPosition = targetPosition
        flightElapsedTime = 0.0

        let distance = hypot(
            targetPosition.x - spriteScreenPosition.x,
            targetPosition.y - spriteScreenPosition.y
        )
        // Duration based on distance at ~900 pts/sec, clamped to 0.4s–1.5s
        flightDuration = min(max(Double(distance) / Double(Self.flightSpeedPointsPerSecond), 0.4), 1.5)

        isFlying = true
        onFlightComplete = completion
    }

    /// Advances the flight interpolation by deltaTime. Uses cubic bezier easing:
    /// ease-out for flights TO the cursor (eager launch, gentle landing),
    /// ease-in-out for return flights (relaxed departure and arrival).
    private func stepFlightPosition(deltaTime: TimeInterval) {
        flightElapsedTime += deltaTime

        let linearProgress = min(flightElapsedTime / flightDuration, 1.0)
        let easedProgress: CGFloat
        if currentFlightIsReturnTrip {
            easedProgress = easeInOutBezier(CGFloat(linearProgress))
        } else {
            easedProgress = easeOutBezier(CGFloat(linearProgress))
        }

        let interpolatedX = flightStartPosition.x + (flightEndPosition.x - flightStartPosition.x) * easedProgress
        let interpolatedY = flightStartPosition.y + (flightEndPosition.y - flightStartPosition.y) * easedProgress
        spriteScreenPosition = CGPoint(x: interpolatedX, y: interpolatedY)

        if linearProgress >= 1.0 {
            isFlying = false
            spriteScreenPosition = flightEndPosition
            onFlightComplete?()
            onFlightComplete = nil
        }
    }

    // MARK: - Walking Patrol Stepping

    /// Moves the sprite horizontally along the bottom screen edge. At each
    /// boundary, pauses briefly with idle animation (facing south toward the user)
    /// before turning around. Eases speed in/out at turnaround points.
    private func stepPatrol(deltaTime: TimeInterval) {
        let screenWidth = currentScreenFrame.width
        guard screenWidth > 0 else { return }

        let leftBoundary = screenWidth * Self.patrolLeftBoundaryFraction
        let rightBoundary = screenWidth * Self.patrolRightBoundaryFraction

        // If in a turnaround pause, count down and resume walking when done
        if patrolPauseTimeRemaining > 0 {
            patrolPauseTimeRemaining -= deltaTime
            walkingBobOffset = 0
            if patrolPauseTimeRemaining <= 0 {
                patrolPauseTimeRemaining = 0
                patrolTimeSinceResume = 0
                // Flip direction and start walking
                patrolMovingEast.toggle()
                let walkDirection: SpriteDirection = patrolMovingEast ? .east : .west
                setAnimation(type: .walking, direction: walkDirection)
                print("🐕 Patrol: resuming, now walking \(patrolMovingEast ? "east" : "west")")
            }
            return
        }

        patrolTimeSinceResume += deltaTime

        // Calculate ease-in factor (accelerate from stop)
        let easeInFactor: CGFloat
        if patrolTimeSinceResume < Self.patrolEaseZoneDuration {
            let normalizedTime = CGFloat(patrolTimeSinceResume / Self.patrolEaseZoneDuration)
            easeInFactor = easeInOutBezier(normalizedTime)
        } else {
            easeInFactor = 1.0
        }

        // Calculate distance to the approaching boundary for ease-out
        let targetBoundary = patrolMovingEast ? rightBoundary : leftBoundary
        let distanceToBoundary = abs(targetBoundary - spriteScreenPosition.x)
        let stoppingDistance = Self.patrolWalkingSpeed * CGFloat(Self.patrolEaseZoneDuration) * 0.6

        // Snap to boundary when very close (< 2pt) to prevent the easing from
        // asymptotically approaching but never reaching the boundary.
        if distanceToBoundary < 2.0 {
            let snappedX = targetBoundary
            spriteScreenPosition = CGPoint(x: snappedX, y: spriteScreenPosition.y)
            patrolPauseTimeRemaining = Self.patrolTurnaroundPauseDuration
            walkingBobOffset = 0
            setAnimation(type: .idle, direction: .south)
            print("🐕 Patrol: reached \(patrolMovingEast ? "right" : "left") boundary, turning \(patrolMovingEast ? "west" : "east")")
            return
        }

        let easeOutFactor: CGFloat
        if distanceToBoundary < stoppingDistance && stoppingDistance > 0 {
            let normalizedDistance = CGFloat(distanceToBoundary / stoppingDistance)
            // Clamp minimum so sprite never fully stalls before reaching boundary
            easeOutFactor = max(easeInOutBezier(normalizedDistance), 0.05)
        } else {
            easeOutFactor = 1.0
        }

        let speedMultiplier = min(easeInFactor, easeOutFactor)
        let displacement = Self.patrolWalkingSpeed * speedMultiplier * CGFloat(deltaTime) * (patrolMovingEast ? 1.0 : -1.0)
        var newX = spriteScreenPosition.x + displacement

        // Vertical bob synced to animation frame (~1.5pt amplitude)
        let bobPhase = CGFloat(currentFrameIndex) * .pi / max(CGFloat(activeFrames.count), 1.0) * 2.0
        walkingBobOffset = sin(bobPhase) * 1.5

        // Clamp to boundary (belt-and-suspenders — snap above should catch this)
        if patrolMovingEast && newX >= rightBoundary {
            newX = rightBoundary
            patrolPauseTimeRemaining = Self.patrolTurnaroundPauseDuration
            setAnimation(type: .idle, direction: .south)
            print("🐕 Patrol: reached right boundary, turning west")
        } else if !patrolMovingEast && newX <= leftBoundary {
            newX = leftBoundary
            patrolPauseTimeRemaining = Self.patrolTurnaroundPauseDuration
            setAnimation(type: .idle, direction: .south)
            print("🐕 Patrol: reached left boundary, turning east")
        }

        spriteScreenPosition = CGPoint(x: newX, y: spriteScreenPosition.y)
    }

    /// When assisting at cursor, smoothly track the mouse position.
    /// Uses the same coordinate system as the existing cursor tracking
    /// in BlueCursorView (SwiftUI top-left origin).
    private func updatePositionToFollowCursor() {
        let mouseLocation = NSEvent.mouseLocation
        guard currentScreenFrame.contains(mouseLocation) else { return }

        // Convert AppKit screen coordinates (bottom-left origin) to SwiftUI (top-left origin)
        let localX = mouseLocation.x - currentScreenFrame.origin.x
        let localY = currentScreenFrame.height - (mouseLocation.y - currentScreenFrame.origin.y)

        // Offset so the sprite sits near the cursor, not directly on top.
        // The sprite is 136x136 — center it slightly above and to the right of the cursor tip.
        let targetX = localX + 20
        let targetY = localY + 10

        // Spring-like smoothing toward the target (lerp factor per frame)
        let smoothingFactor: CGFloat = 0.15
        let newX = spriteScreenPosition.x + (targetX - spriteScreenPosition.x) * smoothingFactor
        let newY = spriteScreenPosition.y + (targetY - spriteScreenPosition.y) * smoothingFactor
        spriteScreenPosition = CGPoint(x: newX, y: newY)
    }

    // MARK: - State Machine

    /// Computes the resting position for the sprite: bottom center of the
    /// given screen frame, in SwiftUI coordinates (top-left origin).
    func restingPosition(for screenFrame: CGRect) -> CGPoint {
        let centerX = screenFrame.width / 2.0
        // Position the sprite so its bottom edge sits on the screen's bottom edge.
        // In SwiftUI coords, Y increases downward, so "bottom" = screenFrame.height.
        // The sprite is rendered centered on its position, so offset up by half the sprite size.
        let bottomY = screenFrame.height - (Self.renderedSpriteSize / 2.0)
        return CGPoint(x: centerX, y: bottomY)
    }

    /// Transitions the sprite to a new behavioral state. Computes the
    /// target position and animation for the new state and begins
    /// any required flight interpolation.
    ///
    /// - Parameters:
    ///   - newState: The state to transition to.
    ///   - targetPosition: The position to fly toward (in AppKit screen coordinates,
    ///     bottom-left origin). Ignored for states that don't require a target.
    ///   - screenFrame: The NSScreen frame the sprite is on (AppKit coords).
    func transitionTo(_ newState: SpriteState, targetPosition: CGPoint?, screenFrame: CGRect) {
        let previousState = spriteState
        spriteState = newState
        currentScreenFrame = screenFrame

        switch newState {
        case .resting:
            stopAssistingBarkTimer()
            isFlying = false
            onFlightComplete = nil

            // If arriving from a flight (flyingBackToResting), the sprite is already
            // at the resting Y position. For initial setup, place at bottom center.
            let bottomY = screenFrame.height - (Self.renderedSpriteSize / 2.0)
            if previousState == .flyingBackToResting {
                // Keep the current X so the patrol starts from where the sprite landed
                spriteScreenPosition = CGPoint(x: spriteScreenPosition.x, y: bottomY)
            } else {
                let restPosition = restingPosition(for: screenFrame)
                spriteScreenPosition = restPosition
            }

            // Begin walking patrol — pick direction based on which boundary is closer
            let screenMidX = screenFrame.width / 2.0
            patrolMovingEast = spriteScreenPosition.x <= screenMidX
            patrolPauseTimeRemaining = 0
            let walkDirection: SpriteDirection = patrolMovingEast ? .east : .west
            setAnimation(type: .walking, direction: walkDirection)
            isVisible = true

        case .flyingToCursor:
            stopAssistingBarkTimer()
            guard let targetScreenPoint = targetPosition else { return }
            isVisible = true
            currentFlightIsReturnTrip = false

            // Convert the AppKit cursor position to SwiftUI coordinates
            let targetSwiftUI = convertAppKitToSwiftUI(targetScreenPoint, screenFrame: screenFrame)
            let offsetTarget = CGPoint(x: targetSwiftUI.x + 20, y: targetSwiftUI.y + 10)

            // Pick the flying direction based on movement angle
            let flyingDirection = directionBetween(from: spriteScreenPosition, to: offsetTarget)
            setAnimation(type: .flying, direction: flyingDirection)

            beginFlight(to: offsetTarget) { [weak self] in
                self?.transitionTo(.assistingAtCursor, targetPosition: nil, screenFrame: screenFrame)
            }

        case .assistingAtCursor:
            isFlying = false
            onFlightComplete = nil
            // Play sparkle effect on arrival, then bark
            triggerSparkleEffect(at: spriteScreenPosition)
            barkHeadTiltOffset = -1.5
            setAnimation(type: .bark, direction: .south)
            onNonLoopingAnimationComplete = { [weak self] in
                self?.barkHeadTiltOffset = 0
                self?.setAnimation(type: .idle, direction: .south)
                self?.startAssistingBarkTimer()
            }

        case .flyingToElement:
            stopAssistingBarkTimer()
            guard let targetScreenPoint = targetPosition else { return }
            currentFlightIsReturnTrip = false

            let targetSwiftUI = convertAppKitToSwiftUI(targetScreenPoint, screenFrame: screenFrame)

            let flyingDirection = directionBetween(from: spriteScreenPosition, to: targetSwiftUI)
            setAnimation(type: .flying, direction: flyingDirection)

            beginFlight(to: targetSwiftUI) { [weak self] in
                self?.transitionTo(.pointingAtElement, targetPosition: nil, screenFrame: screenFrame)
            }

        case .pointingAtElement:
            isFlying = false
            onFlightComplete = nil
            // Play bark animation once with head-tilt, then switch to idle
            barkHeadTiltOffset = -1.5
            setAnimation(type: .bark, direction: .south)
            onNonLoopingAnimationComplete = { [weak self] in
                self?.barkHeadTiltOffset = 0
                self?.setAnimation(type: .idle, direction: .south)
            }

        case .flyingBackToResting:
            stopAssistingBarkTimer()
            isVisible = true
            currentFlightIsReturnTrip = true
            let restPosition = restingPosition(for: screenFrame)

            let flyingDirection = directionBetween(from: spriteScreenPosition, to: restPosition)
            setAnimation(type: .flying, direction: flyingDirection)

            beginFlight(to: restPosition) { [weak self] in
                self?.transitionTo(.resting, targetPosition: nil, screenFrame: screenFrame)
            }
        }

        if previousState != newState {
            print("🐕 Sprite: \(previousState) → \(newState)")
        }
    }

    // MARK: - Assisting Bark Timer

    /// Starts a timer that plays a bark animation at random intervals
    /// while the sprite is assisting at the cursor, so the dog looks like
    /// it's occasionally "commenting" or getting attention.
    private func startAssistingBarkTimer() {
        stopAssistingBarkTimer()
        scheduleNextAssistingBark()
    }

    /// Schedules one bark after a random delay, then reschedules itself.
    private func scheduleNextAssistingBark() {
        let randomInterval = TimeInterval.random(in: Self.assistingBarkIntervalRange)
        assistingBarkTimer = Timer.scheduledTimer(withTimeInterval: randomInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.spriteState == .assistingAtCursor else { return }
                self.barkHeadTiltOffset = -1.5  // Subtle upward tilt during bark
                self.setAnimation(type: .bark, direction: .south)
                self.onNonLoopingAnimationComplete = { [weak self] in
                    self?.barkHeadTiltOffset = 0
                    self?.setAnimation(type: .idle, direction: .south)
                    self?.scheduleNextAssistingBark()
                }
            }
        }
    }

    /// Whether the message-delivered animation is currently looping.
    private(set) var isPlayingMessageDeliveredLoop: Bool = false

    /// Task that handles the delayed stop of the message-delivered loop
    /// (keeps looping for 2 seconds after streaming finishes).
    private var messageDeliveredStopTask: Task<Void, Never>?

    /// Starts looping the message-delivered animation continuously.
    /// Called when Claude begins streaming a response. Cancels any pending
    /// bark timer so they don't overlap.
    func startMessageDeliveredLoop() {
        guard spriteState == .assistingAtCursor else { return }
        messageDeliveredStopTask?.cancel()
        messageDeliveredStopTask = nil
        stopAssistingBarkTimer()
        isPlayingMessageDeliveredLoop = true
        setAnimation(type: .messageDelivered, direction: .south)
        // Override the non-looping default for messageDelivered — we want it to loop
        shouldLoopCurrentAnimation = true
    }

    /// Stops the message-delivered loop after a 2-second delay, then
    /// returns to idle south and resumes periodic bark.
    func stopMessageDeliveredLoop() {
        messageDeliveredStopTask?.cancel()
        messageDeliveredStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isPlayingMessageDeliveredLoop = false
            self.setAnimation(type: .idle, direction: .south)
            self.startAssistingBarkTimer()
        }
    }

    /// Cancels the periodic bark timer.
    private func stopAssistingBarkTimer() {
        assistingBarkTimer?.invalidate()
        assistingBarkTimer = nil
    }

    // MARK: - Sparkle Effect

    /// Triggers the arrival sparkle effect at the given position.
    /// The sparkle plays over ~0.3 seconds with 4 frames, driven by the tick timer.
    private func triggerSparkleEffect(at position: CGPoint) {
        sparklePosition = position
        sparkleElapsedTime = 0
        sparkleFrameIndex = 0
        isSparkleActive = true
    }

    /// Advances the sparkle animation. Called from tick() each frame.
    private func stepSparkle(deltaTime: TimeInterval) {
        guard isSparkleActive else { return }
        sparkleElapsedTime += deltaTime

        let progress = sparkleElapsedTime / Self.sparkleTotalDuration
        if progress >= 1.0 {
            isSparkleActive = false
            sparkleFrameIndex = 0
            return
        }

        // 4 frames spread across the duration
        sparkleFrameIndex = min(Int(progress * 4.0), 3)
    }

    // MARK: - Cubic Bezier Easing

    /// Evaluates a cubic bezier curve at parameter `t` (0–1) given two control
    /// points `p1` and `p2`. The curve starts at (0,0) and ends at (1,1), matching
    /// the CSS cubic-bezier() convention.
    ///
    /// Uses Newton-Raphson iteration to invert the X bezier (find the `t` parameter
    /// that produces the desired X value), then evaluates the Y bezier at that `t`.
    private func cubicBezier(t inputT: CGFloat, p1: CGPoint, p2: CGPoint) -> CGFloat {
        // The bezier X(t) = 3(1-t)^2*t*p1.x + 3(1-t)*t^2*p2.x + t^3
        func sampleX(_ t: CGFloat) -> CGFloat {
            let oneMinusT = 1.0 - t
            return 3.0 * oneMinusT * oneMinusT * t * p1.x + 3.0 * oneMinusT * t * t * p2.x + t * t * t
        }
        func sampleY(_ t: CGFloat) -> CGFloat {
            let oneMinusT = 1.0 - t
            return 3.0 * oneMinusT * oneMinusT * t * p1.y + 3.0 * oneMinusT * t * t * p2.y + t * t * t
        }
        func sampleDerivativeX(_ t: CGFloat) -> CGFloat {
            let oneMinusT = 1.0 - t
            return 3.0 * oneMinusT * oneMinusT * p1.x + 6.0 * oneMinusT * t * (p2.x - p1.x) + 3.0 * t * t * (1.0 - p2.x)
        }

        // Newton-Raphson to find t for the given X (inputT is the linear X progress)
        var guessT = inputT
        for _ in 0..<8 {
            let currentX = sampleX(guessT) - inputT
            let derivative = sampleDerivativeX(guessT)
            if abs(derivative) < 1e-6 { break }
            guessT -= currentX / derivative
            guessT = max(0, min(1, guessT))
        }

        return sampleY(guessT)
    }

    /// Ease-out: fast start, gentle arrival. CSS ~ cubic-bezier(0, 0.55, 0.45, 1)
    private func easeOutBezier(_ t: CGFloat) -> CGFloat {
        cubicBezier(t: t, p1: CGPoint(x: 0, y: 0.55), p2: CGPoint(x: 0.45, y: 1))
    }

    /// Ease-in-out: gentle start, fast middle, gentle end. CSS ~ cubic-bezier(0.42, 0, 0.58, 1)
    private func easeInOutBezier(_ t: CGFloat) -> CGFloat {
        cubicBezier(t: t, p1: CGPoint(x: 0.42, y: 0), p2: CGPoint(x: 0.58, y: 1))
    }

    // MARK: - Helpers

    /// Converts an AppKit screen point (bottom-left origin, global coordinates)
    /// to SwiftUI coordinates (top-left origin, local to the screen).
    private func convertAppKitToSwiftUI(_ screenPoint: CGPoint, screenFrame: CGRect) -> CGPoint {
        let localX = screenPoint.x - screenFrame.origin.x
        let localY = screenFrame.height - (screenPoint.y - screenFrame.origin.y)
        return CGPoint(x: localX, y: localY)
    }

    /// Computes the compass direction from one point to another.
    func directionBetween(from: CGPoint, to: CGPoint) -> SpriteDirection {
        let deltaX = to.x - from.x
        // SwiftUI Y axis: positive = downward. Negate for standard math coords
        // where positive Y = upward, so atan2 gives correct compass directions.
        let deltaY = -(to.y - from.y)
        let angle = atan2(deltaY, deltaX)
        return SpriteDirection.fromAngle(angle)
    }
}
