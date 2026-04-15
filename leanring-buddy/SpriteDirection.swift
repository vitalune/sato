//
//  SpriteDirection.swift
//  leanring-buddy
//
//  Compass directions for the Samoyed sprite, plus angle-to-direction
//  mapping and mirroring logic for directions that lack a native GIF.
//

import Foundation

/// The types of sprite animation. Each type corresponds to a subfolder
/// (or file) in the max-animations bundle directory.
enum SpriteAnimationType {
    case idle
    case walking
    case flying
    case bark
    case messageDelivered
}

/// Eight compass directions the sprite can face. Used to select the
/// correct directional GIF or its horizontally-mirrored equivalent.
enum SpriteDirection: String, CaseIterable {
    case north
    case northEast
    case east
    case southEast
    case south
    case southWest
    case west
    case northWest

    /// Maps an angle (in radians, measured counter-clockwise from the
    /// positive X axis — i.e. standard `atan2` output) to the nearest
    /// of the 8 compass directions.
    ///
    /// The 360-degree circle is divided into 8 sectors of 45 degrees.
    /// Each sector is centered on its cardinal direction.
    static func fromAngle(_ radians: Double) -> SpriteDirection {
        // Normalize to 0..<360 degrees
        var degrees = radians * (180.0 / .pi)
        degrees = degrees.truncatingRemainder(dividingBy: 360.0)
        if degrees < 0 { degrees += 360.0 }

        // atan2 returns: 0° = right (east), 90° = up (north in math coords).
        // But our screen Y axis is inverted (SwiftUI: Y increases downward),
        // so a positive atan2 angle actually points visually *upward* on screen
        // (toward north). We keep that mapping:
        //   0°   = east
        //   45°  = north-east
        //   90°  = north
        //   135° = north-west
        //   180° = west
        //   225° = south-west
        //   270° = south
        //   315° = south-east
        switch degrees {
        case 337.5..<360.0, 0.0..<22.5:     return .east
        case 22.5..<67.5:                    return .northEast
        case 67.5..<112.5:                   return .north
        case 112.5..<157.5:                  return .northWest
        case 157.5..<202.5:                  return .west
        case 202.5..<247.5:                  return .southWest
        case 247.5..<292.5:                  return .south
        case 292.5..<337.5:                  return .southEast
        default:                             return .east
        }
    }

    /// For a given animation type and desired direction, returns which
    /// actual GIF asset direction to load and whether to flip it
    /// horizontally to synthesize the missing direction.
    ///
    /// This is the single source of truth for the mirroring strategy.
    func resolveAsset(for animationType: SpriteAnimationType) -> (sourceDirection: SpriteDirection, flipHorizontally: Bool) {
        switch animationType {
        case .idle:
            // Available: S, SE, E, NE, N, NW, SW. Missing: W.
            switch self {
            case .west: return (.east, true)
            default:    return (self, false)
            }

        case .walking:
            // Available: E, W. Walking is always horizontal.
            return (self == .west ? .west : .east, false)

        case .flying:
            // Available: NE, SW. All others derived by mirroring or reuse.
            switch self {
            case .northEast: return (.northEast, false)
            case .southWest: return (.southWest, false)
            case .northWest: return (.northEast, true)
            case .southEast: return (.southWest, true)
            case .north:     return (.northEast, false)
            case .south:     return (.southWest, false)
            case .east:      return (.northEast, false)
            case .west:      return (.northEast, true)
            }

        case .bark:
            // Single non-directional asset. Direction is ignored.
            return (.south, false)

        case .messageDelivered:
            // Single non-directional asset. Direction is ignored.
            return (.south, false)
        }
    }
}
