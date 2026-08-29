//
//  SpriteAnimationManager.swift
//  leanring-buddy
//
//  Manages the Samoyed sprite's animation frames, position interpolation,
//  and behavioral state machine. Preloads all GIF frames at launch,
//  advances them with a state-adaptive 10/30/60 Hz cadence so stationary
//  animation, walking patrol, and high-motion tracking use only the work needed.
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

/// Controls how much animation work the sprite performs while preserving the
/// existing behavioral state machine.
enum SpriteAnimationPowerMode: Equatable {
    /// Normal behavior with cadence selected from the current sprite state.
    case active
    /// A stationary south-facing idle animation. Only valid while resting.
    case dozing
    /// No animation or behavioral timers are running.
    case suspended
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

    /// Current animation energy policy. CompanionManager moves between these
    /// modes as the visual runtime becomes active, idle, or fully hidden.
    @Published private(set) var powerMode: SpriteAnimationPowerMode = .suspended

    // MARK: - Animation Internals

    /// All preloaded frames, indexed by [animationType][direction].
    private var preloadedFrames: [SpriteAnimationType: [SpriteDirection: [NSImage]]] = [:]

    /// Per-frame durations from GIF metadata, indexed the same way.
    private var preloadedFrameDurations: [SpriteAnimationType: [SpriteDirection: [TimeInterval]]] = [:]

    /// The frame array currently being played.
    private var activeFrames: [NSImage] = []
    private var activeFrameDurations: [TimeInterval] = []
    private var activeAnimationType: SpriteAnimationType?
    private var activeAnimationDirection: SpriteDirection?
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
    private var animationTimerInterval: TimeInterval?
    private var animationTimerGeneration = 0
    private var lastTickTime: CFTimeInterval = 0.0

    private static let highMotionAnimationInterval: TimeInterval = 1.0 / 60.0
    private static let patrolAnimationInterval: TimeInterval = 1.0 / 30.0
    private static let stationaryAnimationInterval: TimeInterval = 1.0 / 10.0
    private static let cursorPositionSnapDistance: CGFloat = 0.25

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

    /// Stable identifier for the active bundled sprite or cached Petdex pet.
    @Published private(set) var activeSpriteDirectory: String = "max-animations"

    /// Metadata for the selected community pet. Nil means a bundled sprite is active.
    @Published private(set) var activeCustomSpriteMetadata: CachedPetdexSprite?

    /// Invalidates background Petdex preparation whenever another sprite source wins.
    /// This prevents an older atlas decode from replacing a newer bundled or custom
    /// selection after its asynchronous work finishes.
    private var spriteSourceGeneration = 0
    private var petdexPreparationTask: Task<PetdexPreparedAtlasRows, Error>?

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

    /// Builds a simple asset filename map where a single idle GIF is used for all directions.
    /// Files are prefixed to avoid bundle collisions (e.g. "sky-idle", "lexi-bark").
    private static func simpleAssetFileNames(prefix: String, barkFileName: String) -> [SpriteAnimationType: [SpriteDirection: String]] {
        var allDirectionsIdle: [SpriteDirection: String] = [:]
        for direction in SpriteDirection.allCases {
            allDirectionsIdle[direction] = "\(prefix)-idle"
        }
        return [
            .idle: allDirectionsIdle,
            .walking: [.east: "\(prefix)-walk-east", .west: "\(prefix)-walk-west"],
            .flying: [.northEast: "\(prefix)-jump-east", .southWest: "\(prefix)-jump-west"],
            .bark: [.south: barkFileName],
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
        beginSpriteSourceChange()

        if activeCustomSpriteMetadata != nil {
            activeCustomSpriteMetadata = nil
        }
        if activeSpriteDirectory != directoryName {
            activeSpriteDirectory = directoryName
        }

        switch directoryName {
        case "sky-animations":
            assetFileNames = Self.simpleAssetFileNames(prefix: "sky", barkFileName: "sky-lick")
        case "lexi-animations":
            assetFileNames = Self.simpleAssetFileNames(prefix: "lexi", barkFileName: "lexi-bark")
        case "rover-animations":
            assetFileNames = Self.simpleAssetFileNames(prefix: "rover", barkFileName: "rover-bark")
        case "paris-animations":
            assetFileNames = Self.simpleAssetFileNames(prefix: "paris", barkFileName: "paris-howl")
        default:
            assetFileNames = Self.maxAssetFileNames
        }

        preloadedFrames.removeAll()
        preloadedFrameDurations.removeAll()
        preloadAllAnimations()

        resumeAnimationForCurrentState()
    }

    /// Activates a cached Petdex atlas after validating and decoding all runtime
    /// states. The current sprite is left untouched if any preparation step fails.
    func switchToPetdexSprite(
        metadata: CachedPetdexSprite,
        spritesheetURL: URL
    ) async throws {
        try Task.checkCancellation()
        let requestedSourceGeneration = beginSpriteSourceChange()
        let rowRequests = Self.petdexAnimationRowSpecifications.map { rowSpecification in
            PetdexAtlasRowRequest(
                rowIndex: rowSpecification.rowIndex,
                frameCount: rowSpecification.frameDurations.count
            )
        }
        let renderedSpritePixelSize = Int(Self.renderedSpriteSize)
        let preparationTask = Task.detached(priority: .userInitiated) {
            try Self.preparePetdexAtlasRows(
                spritesheetURL: spritesheetURL,
                rowRequests: rowRequests,
                renderedSpritePixelSize: renderedSpritePixelSize
            )
        }
        petdexPreparationTask = preparationTask

        defer {
            if spriteSourceGeneration == requestedSourceGeneration {
                petdexPreparationTask = nil
            }
        }

        let preparedAtlasRows = try await withTaskCancellationHandler {
            try await preparationTask.value
        } onCancel: {
            preparationTask.cancel()
        }

        try Task.checkCancellation()
        guard spriteSourceGeneration == requestedSourceGeneration else {
            throw CancellationError()
        }

        let preparedAnimations = try preparePetdexAnimations(
            preparedAtlasRows: preparedAtlasRows
        )
        try Task.checkCancellation()
        guard spriteSourceGeneration == requestedSourceGeneration else {
            throw CancellationError()
        }

        preloadedFrames = preparedAnimations.frames
        preloadedFrameDurations = preparedAnimations.durations
        if activeCustomSpriteMetadata != metadata {
            activeCustomSpriteMetadata = metadata
        }
        let petdexSpriteIdentifier = "petdex:\(metadata.slug)"
        if activeSpriteDirectory != petdexSpriteIdentifier {
            activeSpriteDirectory = petdexSpriteIdentifier
        }
        resumeAnimationForCurrentState()

        let totalFrameCount = preparedAnimations.frames.values
            .flatMap(\.values)
            .reduce(0) { partialResult, animationFrames in
                partialResult + animationFrames.count
            }
        print("🐕 Sprite: Activated Petdex pet \(metadata.displayName) with \(totalFrameCount) mapped frames")
    }

    @discardableResult
    private func beginSpriteSourceChange() -> Int {
        spriteSourceGeneration &+= 1
        petdexPreparationTask?.cancel()
        petdexPreparationTask = nil
        return spriteSourceGeneration
    }

    private func resumeAnimationForCurrentState() {
        if powerMode == .dozing {
            resetInterruptedBarkState()
            setAnimation(type: .idle, direction: .south)
            updateWalkingBobOffsetIfChanged(0)
            return
        }

        switch spriteState {
        case .resting:
            resetInterruptedBarkState()
            if patrolPauseTimeRemaining <= 0 {
                let walkDirection: SpriteDirection = patrolMovingEast ? .east : .west
                setAnimation(type: .walking, direction: walkDirection)
            } else {
                setAnimation(type: .idle, direction: .south)
            }

        case .flyingToCursor, .flyingToElement, .flyingBackToResting:
            resetInterruptedBarkState()
            let restoredFlightDirection: SpriteDirection
            if case .flying? = activeAnimationType, let activeAnimationDirection {
                restoredFlightDirection = activeAnimationDirection
            } else {
                restoredFlightDirection = directionBetween(
                    from: spriteScreenPosition,
                    to: flightEndPosition
                )
            }
            setAnimation(type: .flying, direction: restoredFlightDirection)

        case .assistingAtCursor:
            if isPlayingMessageDeliveredLoop {
                resetInterruptedBarkState()
                setAnimation(type: .messageDelivered, direction: .south)
                shouldLoopCurrentAnimation = true
            } else if case .bark? = activeAnimationType {
                // Restart the new sprite's bark from frame one while retaining
                // the completion that resets its tilt and periodic-bark cycle.
                setAnimation(type: .bark, direction: .south)
            } else {
                resetInterruptedBarkState()
                setAnimation(type: .idle, direction: .south)
            }

        case .pointingAtElement:
            if case .bark? = activeAnimationType {
                setAnimation(type: .bark, direction: .south)
            } else {
                resetInterruptedBarkState()
                setAnimation(type: .idle, direction: .south)
            }
        }
    }

    /// A looping replacement can never invoke a bark's non-looping completion.
    /// Resolve that state explicitly so the sprite does not remain tilted and a
    /// stale callback cannot fire during a later animation.
    private func resetInterruptedBarkState() {
        onNonLoopingAnimationComplete = nil
        updateBarkHeadTiltOffsetIfChanged(0)
    }

    // MARK: - Petdex Atlas Extraction

    private struct PetdexPreparedAnimations {
        let frames: [SpriteAnimationType: [SpriteDirection: [NSImage]]]
        let durations: [SpriteAnimationType: [SpriteDirection: [TimeInterval]]]
    }

    private struct PetdexAtlasRowRequest: Sendable {
        let rowIndex: Int
        let frameCount: Int
    }

    /// `CGImage` values are immutable and safe to hand back to the main actor.
    /// AppKit image wrappers are deliberately created only after this payload arrives.
    private struct PetdexPreparedAtlasRows: Sendable {
        let framesByRow: [[CGImage]]
    }

    private struct PetdexAnimationRowSpecification {
        let animationType: SpriteAnimationType
        let rowIndex: Int
        let frameDurations: [TimeInterval]
        let directions: [SpriteDirection]
    }

    private static let petdexAnimationRowSpecifications = [
        PetdexAnimationRowSpecification(
            animationType: .idle,
            rowIndex: 0,
            frameDurations: [0.28, 0.11, 0.11, 0.14, 0.14, 0.32],
            directions: SpriteDirection.allCases
        ),
        PetdexAnimationRowSpecification(
            animationType: .walking,
            rowIndex: 1,
            frameDurations: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
            directions: [.east]
        ),
        PetdexAnimationRowSpecification(
            animationType: .walking,
            rowIndex: 2,
            frameDurations: [0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.12, 0.22],
            directions: [.west]
        ),
        PetdexAnimationRowSpecification(
            animationType: .bark,
            rowIndex: 3,
            frameDurations: [0.14, 0.14, 0.14, 0.28],
            directions: [.south]
        ),
        PetdexAnimationRowSpecification(
            animationType: .flying,
            rowIndex: 4,
            frameDurations: [0.14, 0.14, 0.14, 0.14, 0.28],
            directions: SpriteDirection.allCases
        ),
        PetdexAnimationRowSpecification(
            animationType: .messageDelivered,
            rowIndex: 8,
            frameDurations: [0.15, 0.15, 0.15, 0.15, 0.15, 0.28],
            directions: SpriteDirection.allCases
        ),
    ]

    private func preparePetdexAnimations(
        preparedAtlasRows: PetdexPreparedAtlasRows
    ) throws -> PetdexPreparedAnimations {
        guard preparedAtlasRows.framesByRow.count == Self.petdexAnimationRowSpecifications.count else {
            throw PetdexCatalogError.invalidSpritesheet
        }

        var preparedFrames: [SpriteAnimationType: [SpriteDirection: [NSImage]]] = [:]
        var preparedDurations: [SpriteAnimationType: [SpriteDirection: [TimeInterval]]] = [:]

        for (rowSpecificationIndex, rowSpecification) in Self.petdexAnimationRowSpecifications.enumerated() {
            let preparedCGImages = preparedAtlasRows.framesByRow[rowSpecificationIndex]
            guard preparedCGImages.count == rowSpecification.frameDurations.count else {
                throw PetdexCatalogError.invalidSpritesheet
            }
            let rowFrames = preparedCGImages.map { preparedCGImage in
                NSImage(
                    cgImage: preparedCGImage,
                    size: NSSize(
                        width: Self.renderedSpriteSize,
                        height: Self.renderedSpriteSize
                    )
                )
            }

            for direction in rowSpecification.directions {
                preparedFrames[rowSpecification.animationType, default: [:]][direction] = rowFrames
                preparedDurations[rowSpecification.animationType, default: [:]][direction] = rowSpecification.frameDurations
            }
        }

        return PetdexPreparedAnimations(
            frames: preparedFrames,
            durations: preparedDurations
        )
    }

    nonisolated private static func preparePetdexAtlasRows(
        spritesheetURL: URL,
        rowRequests: [PetdexAtlasRowRequest],
        renderedSpritePixelSize: Int
    ) throws -> PetdexPreparedAtlasRows {
        try Task.checkCancellation()
        let spritesheetData = try Data(contentsOf: spritesheetURL)
        try Task.checkCancellation()

        let validatedSpritesheet = try PetdexSpriteCatalog.validatedSpritesheetImage(
            from: spritesheetData
        )
        var framesByRow: [[CGImage]] = []
        framesByRow.reserveCapacity(rowRequests.count)

        for rowRequest in rowRequests {
            try Task.checkCancellation()
            guard rowRequest.rowIndex < validatedSpritesheet.layout.rowCount else {
                throw PetdexCatalogError.invalidSpritesheet
            }
            let rowFrames = try extractPetdexAtlasRow(
                spritesheetImage: validatedSpritesheet.image,
                layout: validatedSpritesheet.layout,
                rowIndex: rowRequest.rowIndex,
                frameCount: rowRequest.frameCount,
                renderedSpritePixelSize: renderedSpritePixelSize
            )
            framesByRow.append(rowFrames)
        }

        return PetdexPreparedAtlasRows(framesByRow: framesByRow)
    }

    nonisolated private static func extractPetdexAtlasRow(
        spritesheetImage: CGImage,
        layout: PetdexSpriteAtlasLayout,
        rowIndex: Int,
        frameCount: Int,
        renderedSpritePixelSize: Int
    ) throws -> [CGImage] {
        guard frameCount <= PetdexSpriteAtlasLayout.columnCount else {
            throw PetdexCatalogError.invalidSpritesheet
        }

        var frames: [CGImage] = []
        frames.reserveCapacity(frameCount)

        for columnIndex in 0..<frameCount {
            try Task.checkCancellation()
            let frameRectangle = try layout.frameRectangle(
                rowIndex: rowIndex,
                columnIndex: columnIndex
            )
            guard let croppedFrame = spritesheetImage.cropping(to: frameRectangle) else {
                throw PetdexCatalogError.invalidSpritesheet
            }

            frames.append(
                scaledAndFlippedCGImage(
                    cgImage: croppedFrame,
                    targetSize: renderedSpritePixelSize,
                    flipHorizontally: false,
                    preservesAspectRatio: true
                )
            )
        }

        return frames
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
        flipHorizontally: Bool,
        preservesAspectRatio: Bool = false
    ) -> NSImage {
        let scaledCGImage = Self.scaledAndFlippedCGImage(
            cgImage: cgImage,
            targetSize: targetSize,
            flipHorizontally: flipHorizontally,
            preservesAspectRatio: preservesAspectRatio
        )
        return NSImage(
            cgImage: scaledCGImage,
            size: NSSize(width: targetSize, height: targetSize)
        )
    }

    nonisolated private static func scaledAndFlippedCGImage(
        cgImage: CGImage,
        targetSize: Int,
        flipHorizontally: Bool,
        preservesAspectRatio: Bool
    ) -> CGImage {
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
            return cgImage
        }

        context.interpolationQuality = .none

        if flipHorizontally {
            context.translateBy(x: CGFloat(targetSize), y: 0)
            context.scaleBy(x: -1.0, y: 1.0)
        }

        let drawingRectangle: CGRect
        if preservesAspectRatio {
            let widthScale = CGFloat(targetSize) / CGFloat(cgImage.width)
            let heightScale = CGFloat(targetSize) / CGFloat(cgImage.height)
            let imageScale = min(widthScale, heightScale)
            let drawingWidth = CGFloat(cgImage.width) * imageScale
            let drawingHeight = CGFloat(cgImage.height) * imageScale
            drawingRectangle = CGRect(
                x: (CGFloat(targetSize) - drawingWidth) / 2,
                y: (CGFloat(targetSize) - drawingHeight) / 2,
                width: drawingWidth,
                height: drawingHeight
            )
        } else {
            drawingRectangle = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        }

        context.draw(cgImage, in: drawingRectangle)

        return context.makeImage() ?? cgImage
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
        activeAnimationType = type
        activeAnimationDirection = direction
        currentFrameIndex = 0
        frameTimeAccumulator = 0.0
        shouldLoopCurrentAnimation = (type != .bark && type != .messageDelivered)
        updateCurrentFrameIfChanged(activeFrames[0])
        updateWalkingBobForCurrentAnimation()
    }

    // MARK: - Timer Lifecycle

    /// Selects the sprite's energy policy and immediately applies the matching
    /// animation and timer cadence. Dozing is intentionally limited to the
    /// resting state so an in-progress interaction cannot be frozen halfway.
    func setPowerMode(_ newPowerMode: SpriteAnimationPowerMode) {
        if newPowerMode == .dozing, spriteState != .resting {
            return
        }

        let previousPowerMode = powerMode
        if previousPowerMode == newPowerMode {
            refreshAnimationCadence()
            return
        }
        powerMode = newPowerMode

        switch newPowerMode {
        case .active:
            if previousPowerMode == .dozing {
                resumeAnimationForCurrentState()
            } else if previousPowerMode == .suspended,
                      spriteState == .assistingAtCursor,
                      !isPlayingMessageDeliveredLoop,
                      case .idle? = activeAnimationType {
                startAssistingBarkTimer()
            }
            refreshAnimationCadence(forceRestart: previousPowerMode != .active)

        case .dozing:
            updateIsFlyingIfChanged(false)
            onFlightComplete = nil
            stopPowerSensitiveBehaviorTimers()
            updateIsSparkleActiveIfChanged(false)
            updateSparkleFrameIndexIfChanged(0)
            resetInterruptedBarkState()
            setAnimation(type: .idle, direction: .south)
            updateWalkingBobOffsetIfChanged(0)
            refreshAnimationCadence(forceRestart: previousPowerMode != .dozing)

        case .suspended:
            invalidateAnimationTimer()
            stopPowerSensitiveBehaviorTimers()
        }
    }

    /// Existing callers continue to mean "make the visual runtime active."
    func startAnimationTimer() {
        setPowerMode(.active)
    }

    /// Existing callers continue to fully suspend animation when the overlay hides.
    func stopAnimationTimer() {
        setPowerMode(.suspended)
    }

    private var desiredAnimationTimerInterval: TimeInterval? {
        switch powerMode {
        case .suspended:
            return nil
        case .dozing:
            return Self.stationaryAnimationInterval
        case .active:
            if isFlying || spriteState == .assistingAtCursor {
                return Self.highMotionAnimationInterval
            }
            if spriteState == .resting, patrolPauseTimeRemaining <= 0 {
                return Self.patrolAnimationInterval
            }
            return Self.stationaryAnimationInterval
        }
    }

    private func refreshAnimationCadence(forceRestart: Bool = false) {
        guard let desiredAnimationTimerInterval else {
            invalidateAnimationTimer()
            return
        }

        if !forceRestart,
           animationTimer != nil,
           animationTimerInterval == desiredAnimationTimerInterval {
            return
        }

        invalidateAnimationTimer()
        animationTimerInterval = desiredAnimationTimerInterval
        lastTickTime = CACurrentMediaTime()
        let scheduledTimerGeneration = animationTimerGeneration
        let scheduledAnimationTimer = Timer.scheduledTimer(
            withTimeInterval: desiredAnimationTimerInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.animationTimerGeneration == scheduledTimerGeneration,
                      self.powerMode != .suspended else {
                    return
                }
                self.tick()
            }
        }
        scheduledAnimationTimer.tolerance = desiredAnimationTimerInterval >= Self.stationaryAnimationInterval
            ? desiredAnimationTimerInterval * 0.15
            : desiredAnimationTimerInterval * 0.05
        animationTimer = scheduledAnimationTimer
    }

    private func invalidateAnimationTimer() {
        animationTimerGeneration += 1
        animationTimer?.invalidate()
        animationTimer = nil
        animationTimerInterval = nil
    }

    private func stopPowerSensitiveBehaviorTimers() {
        stopAssistingBarkTimer()
        let shouldFinishPendingMessageDeliveredStop = messageDeliveredStopTask != nil
        messageDeliveredStopTask?.cancel()
        messageDeliveredStopTask = nil

        if shouldFinishPendingMessageDeliveredStop {
            isPlayingMessageDeliveredLoop = false
            if spriteState == .assistingAtCursor {
                setAnimation(type: .idle, direction: .south)
            }
        }
    }

    /// Advances only the work allowed by the current power mode. The timer's
    /// cadence is refreshed after the tick because patrol and flight completion
    /// can change the required frequency synchronously.
    private func tick() {
        guard powerMode != .suspended else { return }

        let now = CACurrentMediaTime()
        let deltaTime = now - lastTickTime
        lastTickTime = now

        stepAnimationFrame(deltaTime: deltaTime)

        if powerMode == .active {
            if isFlying {
                stepFlightPosition(deltaTime: deltaTime)
            }

            if spriteState == .resting {
                stepPatrol(deltaTime: deltaTime)
            } else {
                updateWalkingBobOffsetIfChanged(0)
            }

            if spriteState == .assistingAtCursor {
                updatePositionToFollowCursor()
            }

            stepSparkle(deltaTime: deltaTime)
        }

        refreshAnimationCadence()
    }

    /// Advances the sprite animation frame based on elapsed time and
    /// the per-frame duration from GIF metadata.
    private func stepAnimationFrame(deltaTime: TimeInterval) {
        guard !activeFrames.isEmpty else { return }

        frameTimeAccumulator += deltaTime
        var didAdvanceFrame = false
        var frameAdvanceCount = 0
        let maximumFrameAdvances = max(activeFrames.count * 2, 1)

        while frameAdvanceCount < maximumFrameAdvances {
            let frameDuration = currentFrameIndex < activeFrameDurations.count
                ? max(activeFrameDurations[currentFrameIndex], 0.01)
                : Self.stationaryAnimationInterval
            guard frameTimeAccumulator >= frameDuration else { break }

            frameTimeAccumulator -= frameDuration
            let nextIndex = currentFrameIndex + 1
            if nextIndex >= activeFrames.count {
                if shouldLoopCurrentAnimation {
                    currentFrameIndex = 0
                } else {
                    frameTimeAccumulator = 0
                    let completion = onNonLoopingAnimationComplete
                    onNonLoopingAnimationComplete = nil
                    completion?()
                    return
                }
            } else {
                currentFrameIndex = nextIndex
            }

            didAdvanceFrame = true
            frameAdvanceCount += 1
        }

        if frameAdvanceCount == maximumFrameAdvances {
            frameTimeAccumulator = 0
        }

        if didAdvanceFrame {
            updateCurrentFrameIfChanged(activeFrames[currentFrameIndex])
            updateWalkingBobForCurrentAnimation()
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

        updateIsFlyingIfChanged(true)
        onFlightComplete = completion
        refreshAnimationCadence()
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
        updateSpriteScreenPositionIfChanged(CGPoint(x: interpolatedX, y: interpolatedY))

        if linearProgress >= 1.0 {
            updateIsFlyingIfChanged(false)
            updateSpriteScreenPositionIfChanged(flightEndPosition)
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
            updateWalkingBobOffsetIfChanged(0)
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
            updateSpriteScreenPositionIfChanged(CGPoint(x: snappedX, y: spriteScreenPosition.y))
            patrolPauseTimeRemaining = Self.patrolTurnaroundPauseDuration
            updateWalkingBobOffsetIfChanged(0)
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

        updateSpriteScreenPositionIfChanged(CGPoint(x: newX, y: spriteScreenPosition.y))
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

        let remainingDistance = hypot(
            targetX - spriteScreenPosition.x,
            targetY - spriteScreenPosition.y
        )
        if remainingDistance <= Self.cursorPositionSnapDistance {
            updateSpriteScreenPositionIfChanged(CGPoint(x: targetX, y: targetY))
            return
        }

        // Spring-like smoothing toward the target (lerp factor per frame)
        let smoothingFactor: CGFloat = 0.15
        let newX = spriteScreenPosition.x + (targetX - spriteScreenPosition.x) * smoothingFactor
        let newY = spriteScreenPosition.y + (targetY - spriteScreenPosition.y) * smoothingFactor
        updateSpriteScreenPositionIfChanged(CGPoint(x: newX, y: newY))
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
        if powerMode == .dozing, newState != .resting {
            return
        }
        if (newState == .flyingToCursor || newState == .flyingToElement), targetPosition == nil {
            return
        }

        let previousState = spriteState
        if previousState != newState,
           activeAnimationType == .bark {
            resetInterruptedBarkState()
        }
        updateSpriteStateIfChanged(newState)
        updateCurrentScreenFrameIfChanged(screenFrame)
        defer { refreshAnimationCadence() }

        switch newState {
        case .resting:
            stopAssistingBarkTimer()
            updateIsFlyingIfChanged(false)
            onFlightComplete = nil

            // If arriving from a flight (flyingBackToResting), the sprite is already
            // at the resting Y position. For initial setup, place at bottom center.
            let bottomY = screenFrame.height - (Self.renderedSpriteSize / 2.0)
            if previousState == .flyingBackToResting {
                // Keep the current X so the patrol starts from where the sprite landed
                updateSpriteScreenPositionIfChanged(CGPoint(x: spriteScreenPosition.x, y: bottomY))
            } else {
                let restPosition = restingPosition(for: screenFrame)
                updateSpriteScreenPositionIfChanged(restPosition)
            }

            // Begin walking patrol — pick direction based on which boundary is closer
            let screenMidX = screenFrame.width / 2.0
            patrolMovingEast = spriteScreenPosition.x <= screenMidX
            patrolPauseTimeRemaining = 0
            let walkDirection: SpriteDirection = patrolMovingEast ? .east : .west
            if powerMode == .dozing {
                setAnimation(type: .idle, direction: .south)
                updateWalkingBobOffsetIfChanged(0)
            } else {
                setAnimation(type: .walking, direction: walkDirection)
            }
            updateIsVisibleIfChanged(true)

        case .flyingToCursor:
            stopAssistingBarkTimer()
            guard let targetScreenPoint = targetPosition else { return }
            updateIsVisibleIfChanged(true)
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
            updateIsFlyingIfChanged(false)
            onFlightComplete = nil
            // Play sparkle effect on arrival, then bark
            triggerSparkleEffect(at: spriteScreenPosition)
            updateBarkHeadTiltOffsetIfChanged(-1.5)
            setAnimation(type: .bark, direction: .south)
            onNonLoopingAnimationComplete = { [weak self] in
                self?.updateBarkHeadTiltOffsetIfChanged(0)
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
            updateIsFlyingIfChanged(false)
            onFlightComplete = nil
            // Play bark animation once with head-tilt, then switch to idle
            updateBarkHeadTiltOffsetIfChanged(-1.5)
            setAnimation(type: .bark, direction: .south)
            onNonLoopingAnimationComplete = { [weak self] in
                self?.updateBarkHeadTiltOffsetIfChanged(0)
                self?.setAnimation(type: .idle, direction: .south)
            }

        case .flyingBackToResting:
            stopAssistingBarkTimer()
            updateIsVisibleIfChanged(true)
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
        guard powerMode == .active, spriteState == .assistingAtCursor else { return }
        scheduleNextAssistingBark()
    }

    /// Schedules one bark after a random delay, then reschedules itself.
    private func scheduleNextAssistingBark() {
        guard powerMode == .active, spriteState == .assistingAtCursor else { return }

        let randomInterval = TimeInterval.random(in: Self.assistingBarkIntervalRange)
        let scheduledBarkTimer = Timer.scheduledTimer(withTimeInterval: randomInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.powerMode == .active,
                      self.spriteState == .assistingAtCursor else {
                    return
                }
                self.updateBarkHeadTiltOffsetIfChanged(-1.5)
                self.setAnimation(type: .bark, direction: .south)
                self.onNonLoopingAnimationComplete = { [weak self] in
                    guard let self,
                          self.powerMode == .active,
                          self.spriteState == .assistingAtCursor else {
                        return
                    }
                    self.updateBarkHeadTiltOffsetIfChanged(0)
                    self.setAnimation(type: .idle, direction: .south)
                    self.scheduleNextAssistingBark()
                }
            }
        }
        scheduledBarkTimer.tolerance = min(randomInterval * 0.1, 0.5)
        assistingBarkTimer = scheduledBarkTimer
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
        guard powerMode != .dozing, spriteState == .assistingAtCursor else { return }
        messageDeliveredStopTask?.cancel()
        messageDeliveredStopTask = nil
        stopAssistingBarkTimer()
        resetInterruptedBarkState()
        isPlayingMessageDeliveredLoop = true
        setAnimation(type: .messageDelivered, direction: .south)
        // Override the non-looping default for messageDelivered — we want it to loop
        shouldLoopCurrentAnimation = true
    }

    /// Stops the message-delivered loop after a 2-second delay, then
    /// returns to idle south and resumes periodic bark.
    func stopMessageDeliveredLoop() {
        messageDeliveredStopTask?.cancel()
        messageDeliveredStopTask = nil

        guard powerMode == .active else {
            isPlayingMessageDeliveredLoop = false
            if spriteState == .assistingAtCursor {
                setAnimation(type: .idle, direction: .south)
            }
            return
        }

        messageDeliveredStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.isPlayingMessageDeliveredLoop = false
            self.messageDeliveredStopTask = nil
            guard self.powerMode == .active,
                  self.spriteState == .assistingAtCursor else {
                return
            }
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
        updateSparklePositionIfChanged(position)
        sparkleElapsedTime = 0
        updateSparkleFrameIndexIfChanged(0)
        updateIsSparkleActiveIfChanged(true)
    }

    /// Advances the sparkle animation. Called from tick() each frame.
    private func stepSparkle(deltaTime: TimeInterval) {
        guard isSparkleActive else { return }
        sparkleElapsedTime += deltaTime

        let progress = sparkleElapsedTime / Self.sparkleTotalDuration
        if progress >= 1.0 {
            updateIsSparkleActiveIfChanged(false)
            updateSparkleFrameIndexIfChanged(0)
            return
        }

        // 4 frames spread across the duration
        updateSparkleFrameIndexIfChanged(min(Int(progress * 4.0), 3))
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

    private func updateCurrentFrameIfChanged(_ newFrame: NSImage) {
        guard currentFrame !== newFrame else { return }
        currentFrame = newFrame
    }

    private func updateSpriteScreenPositionIfChanged(_ newPosition: CGPoint) {
        guard spriteScreenPosition != newPosition else { return }
        spriteScreenPosition = newPosition
    }

    private func updateSpriteStateIfChanged(_ newState: SpriteState) {
        guard spriteState != newState else { return }
        spriteState = newState
    }

    private func updateIsVisibleIfChanged(_ newVisibility: Bool) {
        guard isVisible != newVisibility else { return }
        isVisible = newVisibility
    }

    private func updateCurrentScreenFrameIfChanged(_ newScreenFrame: CGRect) {
        guard currentScreenFrame != newScreenFrame else { return }
        currentScreenFrame = newScreenFrame
    }

    private func updateIsFlyingIfChanged(_ newIsFlying: Bool) {
        guard isFlying != newIsFlying else { return }
        isFlying = newIsFlying
    }

    private func updateIsSparkleActiveIfChanged(_ newIsSparkleActive: Bool) {
        guard isSparkleActive != newIsSparkleActive else { return }
        isSparkleActive = newIsSparkleActive
    }

    private func updateSparkleFrameIndexIfChanged(_ newFrameIndex: Int) {
        guard sparkleFrameIndex != newFrameIndex else { return }
        sparkleFrameIndex = newFrameIndex
    }

    private func updateSparklePositionIfChanged(_ newPosition: CGPoint) {
        guard sparklePosition != newPosition else { return }
        sparklePosition = newPosition
    }

    private func updateWalkingBobOffsetIfChanged(_ newOffset: CGFloat) {
        guard abs(walkingBobOffset - newOffset) > 0.001 else { return }
        walkingBobOffset = newOffset
    }

    private func updateWalkingBobForCurrentAnimation() {
        guard powerMode == .active,
              spriteState == .resting,
              patrolPauseTimeRemaining <= 0,
              case .walking? = activeAnimationType else {
            updateWalkingBobOffsetIfChanged(0)
            return
        }

        let frameCount = max(CGFloat(activeFrames.count), 1.0)
        let bobPhase = CGFloat(currentFrameIndex) * .pi / frameCount * 2.0
        updateWalkingBobOffsetIfChanged(sin(bobPhase) * 1.5)
    }

    private func updateBarkHeadTiltOffsetIfChanged(_ newOffset: CGFloat) {
        guard abs(barkHeadTiltOffset - newOffset) > 0.001 else { return }
        barkHeadTiltOffset = newOffset
    }

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
