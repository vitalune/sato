//
//  SamoyedSpriteView.swift
//  leanring-buddy
//
//  Renders the current Samoyed sprite animation frame. The frame image
//  is pre-scaled to 136x136 with nearest-neighbor interpolation by
//  SpriteAnimationManager, so this view just displays it 1:1.
//  Includes a grounding shadow, walking bob, bark head-tilt, and
//  arrival sparkle effect.
//

import SwiftUI

struct SamoyedSpriteView: View {
    @ObservedObject var spriteAnimationManager: SpriteAnimationManager

    var body: some View {
        ZStack {
            // Ground shadow — fades out during flight to sell lift-off illusion
            Ellipse()
                .fill(Color.black.opacity(0.15 * groundShadowOpacity))
                .frame(width: 60, height: 12)
                .blur(radius: 4)
                .offset(x: 1, y: SpriteAnimationManager.renderedSpriteSize / 2.0 + 2)

            // Sprite frame with walking bob and bark head-tilt offsets
            if let frame = spriteAnimationManager.currentFrame {
                Image(nsImage: frame)
                    .interpolation(.none)
                    .resizable()
                    .frame(
                        width: SpriteAnimationManager.renderedSpriteSize,
                        height: SpriteAnimationManager.renderedSpriteSize
                    )
                    .offset(
                        y: spriteAnimationManager.walkingBobOffset
                            + spriteAnimationManager.barkHeadTiltOffset
                    )
            }

            // Arrival sparkle effect
            if spriteAnimationManager.isSparkleActive {
                SparkleEffectView(frameIndex: spriteAnimationManager.sparkleFrameIndex)
            }
        }
    }

    /// Shadow opacity: fully visible when resting/assisting, fades out when flying.
    private var groundShadowOpacity: Double {
        if spriteAnimationManager.isFlying {
            return 0
        }
        return 1.0
    }
}

/// Procedurally-generated pixel-art sparkle effect. 4 frames of small colored
/// squares that radiate outward from center then fade.
private struct SparkleEffectView: View {
    let frameIndex: Int

    /// Each sparkle particle: angle (radians), distance multiplier, color.
    private static let particles: [(angle: Double, distanceScale: CGFloat, color: Color)] = [
        (0,             1.0,  Color.white),
        (.pi / 3,       0.8,  Color.yellow),
        (2 * .pi / 3,   1.1,  Color.white.opacity(0.8)),
        (.pi,           0.9,  Color.yellow.opacity(0.9)),
        (4 * .pi / 3,   1.0,  Color.white.opacity(0.7)),
        (5 * .pi / 3,   0.85, Color.yellow.opacity(0.8)),
        (.pi / 6,       1.2,  Color.white.opacity(0.6)),
        (3 * .pi / 2,   0.7,  Color.yellow.opacity(0.7)),
    ]

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let progress = CGFloat(frameIndex + 1) / 4.0  // 0.25 → 1.0
            let baseRadius: CGFloat = 8 + progress * 28
            let particleOpacity = max(1.0 - progress * 0.8, 0.0)
            let particleSize: CGFloat = max(4.0 - progress * 1.5, 1.5)

            for particle in Self.particles {
                let radius = baseRadius * particle.distanceScale
                let x = center.x + cos(particle.angle) * radius
                let y = center.y + sin(particle.angle) * radius
                let rect = CGRect(
                    x: x - particleSize / 2,
                    y: y - particleSize / 2,
                    width: particleSize,
                    height: particleSize
                )
                context.opacity = particleOpacity
                context.fill(Path(rect), with: .color(particle.color))
            }
        }
        .frame(width: 80, height: 80)
        .allowsHitTesting(false)
    }
}
