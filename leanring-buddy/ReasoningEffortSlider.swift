//
//  ReasoningEffortSlider.swift
//  leanring-buddy
//
//  The effort control shown under the model picker. The thumb can be dragged
//  along a bar (or the bar clicked) and snaps to the levels the selected
//  model supports, so each model only offers the effort values its API
//  accepts.
//

import AppKit
import SwiftUI

/// Shows the effort slider for the model selected in the panel. It observes
/// `ProviderManager` directly so the slider updates as soon as the model or
/// effort changes, independent of when the rest of the panel re-renders.
struct ReasoningEffortSettingRow: View {
    @ObservedObject var providerManager: ProviderManager

    var body: some View {
        if let effortOptions = providerManager.currentReasoningEffortOptions,
           let selectedEffortLevel = providerManager.currentReasoningEffortLevel {
            ReasoningEffortSlider(
                effortLevels: effortOptions.levels,
                selectedEffortLevel: selectedEffortLevel,
                onSelectEffortLevel: { newEffortLevel in
                    providerManager.setCurrentReasoningEffortLevel(newEffortLevel)
                }
            )
        } else if isShowingAnInstalledModel {
            HStack {
                Text("Effort")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text("Not adjustable for this model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
        }
    }

    /// Ollama Local only shows a model once the daemon reports it, so the
    /// "not adjustable" note is hidden until there is a model to describe.
    private var isShowingAnInstalledModel: Bool {
        guard providerManager.selectedProviderID == "ollama-local" else { return true }
        return providerManager.ollamaLocalModels.contains { $0.name == providerManager.currentModelID }
    }
}

struct ReasoningEffortSlider: View {
    /// Ordered from least to most effort.
    let effortLevels: [ReasoningEffortLevel]
    let selectedEffortLevel: ReasoningEffortLevel
    let onSelectEffortLevel: (ReasoningEffortLevel) -> Void

    /// The thumb's center while the user drags. Nil when idle, in which case
    /// the thumb rests on the selected level's stop.
    @State private var draggedThumbCenterX: CGFloat?
    @State private var isHoveringTrack = false

    private static let thumbDiameter: CGFloat = 14
    private static let trackHeight: CGFloat = 4
    private static let stopMarkerDiameter: CGFloat = 4
    private static let controlHeight: CGFloat = 18

    private var selectedLevelIndex: Int {
        effortLevels.firstIndex(of: selectedEffortLevel) ?? 0
    }

    private var isDragging: Bool {
        draggedThumbCenterX != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Effort")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Text(selectedEffortLevel.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: selectedEffortLevel)
            }

            GeometryReader { geometry in
                sliderTrack(trackWidth: geometry.size.width)
            }
            .frame(height: Self.controlHeight)
            .pointerCursor()
            .onHover { isHovering in
                isHoveringTrack = isHovering
            }

            HStack {
                Text(effortLevels.first?.displayName ?? "")
                Spacer()
                Text(effortLevels.last?.displayName ?? "")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort")
        .accessibilityValue(selectedEffortLevel.displayName)
        .accessibilityAdjustableAction { adjustmentDirection in
            switch adjustmentDirection {
            case .increment:
                selectLevel(at: selectedLevelIndex + 1)
            case .decrement:
                selectLevel(at: selectedLevelIndex - 1)
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func sliderTrack(trackWidth: CGFloat) -> some View {
        let firstStopCenterX = Self.thumbDiameter / 2
        let lastStopCenterX = max(trackWidth - Self.thumbDiameter / 2, firstStopCenterX)
        let stopSpacing = effortLevels.count > 1
            ? (lastStopCenterX - firstStopCenterX) / CGFloat(effortLevels.count - 1)
            : 0
        let restingThumbCenterX = firstStopCenterX + CGFloat(selectedLevelIndex) * stopSpacing
        let thumbCenterX = draggedThumbCenterX ?? restingThumbCenterX
        let verticalCenter = Self.controlHeight / 2

        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.white.opacity(0.1))
                .frame(width: lastStopCenterX - firstStopCenterX, height: Self.trackHeight)
                .position(x: (firstStopCenterX + lastStopCenterX) / 2, y: verticalCenter)

            Capsule()
                .fill(DS.Colors.accent)
                .frame(width: max(thumbCenterX - firstStopCenterX, 0), height: Self.trackHeight)
                .position(x: (firstStopCenterX + thumbCenterX) / 2, y: verticalCenter)

            ForEach(Array(effortLevels.enumerated()), id: \.offset) { levelIndex, _ in
                let stopCenterX = firstStopCenterX + CGFloat(levelIndex) * stopSpacing
                Circle()
                    .fill(stopCenterX <= thumbCenterX ? DS.Colors.accentText : Color.white.opacity(0.28))
                    .frame(width: Self.stopMarkerDiameter, height: Self.stopMarkerDiameter)
                    .position(x: stopCenterX, y: verticalCenter)
            }

            Circle()
                .fill(Color.white)
                .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
                .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                .scaleEffect(isDragging ? 1.2 : (isHoveringTrack ? 1.1 : 1.0))
                .animation(.easeOut(duration: 0.12), value: isHoveringTrack)
                .animation(.easeOut(duration: 0.12), value: isDragging)
                .position(x: thumbCenterX, y: verticalCenter)
        }
        .frame(width: trackWidth, height: Self.controlHeight)
        .contentShape(Rectangle())
        // A zero-distance drag handles both clicking a spot on the bar and
        // dragging the thumb. The level updates live while dragging so the
        // label shows what will be selected, and the thumb snaps on release.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { dragValue in
                    let clampedThumbCenterX = min(max(dragValue.location.x, firstStopCenterX), lastStopCenterX)
                    draggedThumbCenterX = clampedThumbCenterX

                    guard stopSpacing > 0 else { return }
                    let nearestLevelIndex = Int(((clampedThumbCenterX - firstStopCenterX) / stopSpacing).rounded())
                    selectLevel(at: nearestLevelIndex)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        draggedThumbCenterX = nil
                    }
                }
        )
    }

    private func selectLevel(at levelIndex: Int) {
        guard effortLevels.indices.contains(levelIndex) else { return }
        let newEffortLevel = effortLevels[levelIndex]
        guard newEffortLevel != selectedEffortLevel else { return }

        // A light haptic tick on Force Touch trackpads marks each level.
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        onSelectEffortLevel(newEffortLevel)
    }
}
