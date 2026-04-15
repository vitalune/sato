//
//  ScreenshotSelectionView.swift
//  leanring-buddy
//
//  Full-screen overlay that shows a frozen screenshot of the current screen
//  with a dimmed overlay. The user clicks and drags to select a rectangular
//  region. The selected area appears at full brightness. After confirmation
//  (Enter or double-click), the cropped screenshot is passed to the AI pipeline.
//  Escape cancels without sending anything.
//

import AppKit
import SwiftUI

/// State machine for the screenshot selection interaction.
enum ScreenshotSelectionPhase {
    /// User hasn't started drawing yet — show crosshair cursor
    case waitingForDrag
    /// User is actively dragging to create the selection
    case drawing
    /// Selection exists — user can resize handles or confirm
    case adjusting
}

struct ScreenshotSelectionView: View {
    /// The frozen screenshot image to display behind the dimmed overlay.
    let screenshotImage: NSImage
    /// The screen frame this overlay covers (for coordinate mapping).
    let screenFrame: CGRect

    /// Called with the cropped JPEG data when the user confirms the selection.
    let onConfirm: (Data, CGRect) -> Void
    /// Called when the user cancels (Escape).
    let onCancel: () -> Void

    @State private var selectionPhase: ScreenshotSelectionPhase = .waitingForDrag
    @State private var selectionRect: CGRect = .zero
    @State private var dragStartPoint: CGPoint = .zero

    /// Handle being dragged for resize, if any.
    @State private var activeResizeEdge: ResizeEdge? = nil

    /// Animated dash phase for the marching ants effect on the selection border.
    @State private var marchingAntsDashPhase: CGFloat = 0

    /// White flash overlay opacity for the confirmation "shutter" effect.
    @State private var confirmationFlashOpacity: Double = 0

    /// Minimum selection size in points.
    private static let minimumSelectionSize: CGFloat = 20

    /// Publishers for Enter and Escape key notifications from the interactive overlay.
    private let enterPublisher = NotificationCenter.default.publisher(for: .assistOverlayEnterPressed)
    private let escapePublisher = NotificationCenter.default.publisher(for: .assistOverlayCancelPressed)

    var body: some View {
        ZStack {
            // Frozen screenshot at full brightness
            Image(nsImage: screenshotImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: screenFrame.width, height: screenFrame.height)

            // Dark dimming overlay with a cutout for the selection
            Canvas { context, size in
                // Fill entire canvas with semi-transparent black
                var dimmingPath = Path(CGRect(origin: .zero, size: size))
                // Cut out the selection rectangle so it shows at full brightness
                if selectionRect.width > 0 && selectionRect.height > 0 {
                    dimmingPath.addRect(selectionRect)
                    context.fill(dimmingPath, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
                } else {
                    context.fill(dimmingPath, with: .color(.black.opacity(0.5)))
                }
            }
            .allowsHitTesting(false)

            // Selection rectangle border (marching ants) and handles
            if selectionRect.width > Self.minimumSelectionSize && selectionRect.height > Self.minimumSelectionSize {
                // Marching ants border — animated dashed stroke
                Rectangle()
                    .strokeBorder(style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: [6, 4],
                        dashPhase: marchingAntsDashPhase
                    ))
                    .foregroundColor(.white)
                    .frame(width: selectionRect.width, height: selectionRect.height)
                    .position(x: selectionRect.midX, y: selectionRect.midY)
                    .onAppear {
                        withAnimation(.linear(duration: 0.4).repeatForever(autoreverses: false)) {
                            marchingAntsDashPhase = 10
                        }
                    }

                // Confirmation flash overlay inside selection
                if confirmationFlashOpacity > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(confirmationFlashOpacity))
                        .frame(width: selectionRect.width, height: selectionRect.height)
                        .position(x: selectionRect.midX, y: selectionRect.midY)
                        .allowsHitTesting(false)
                }

                // Dimension label with dark pill background
                Text("\(Int(selectionRect.width)) × \(Int(selectionRect.height))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.75))
                    )
                    .position(
                        x: selectionRect.midX,
                        y: min(selectionRect.maxY + 20, screenFrame.height - 15)
                    )

                // Resize handles at corners and edge midpoints
                if selectionPhase == .adjusting {
                    ForEach(ResizeEdge.allCases, id: \.self) { edge in
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .position(handlePosition(for: edge))
                    }
                }
            }

            // Instructions
            if selectionPhase == .waitingForDrag {
                VStack(spacing: 6) {
                    Text("Click and drag to select a region")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                    Text("Press Escape to cancel")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.7))
                )
                .position(x: screenFrame.width / 2, y: screenFrame.height / 2)
            }

            if selectionPhase == .adjusting {
                Text("Press Enter to confirm  ·  Escape to cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.6))
                    )
                    .position(x: screenFrame.width / 2, y: screenFrame.height - 40)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    handleDragChanged(value)
                }
                .onEnded { value in
                    handleDragEnded(value)
                }
        )
        .onTapGesture(count: 2) {
            if selectionPhase == .adjusting && selectionRect.width > Self.minimumSelectionSize {
                confirmSelection()
            }
        }
        .onReceive(enterPublisher) { _ in
            if selectionPhase == .adjusting && selectionRect.width > Self.minimumSelectionSize {
                confirmSelection()
            }
        }
        .onReceive(escapePublisher) { _ in
            onCancel()
        }
    }

    // MARK: - Drag Handling

    private func handleDragChanged(_ value: DragGesture.Value) {
        if selectionPhase == .waitingForDrag || selectionPhase == .drawing {
            if selectionPhase == .waitingForDrag {
                dragStartPoint = value.startLocation
                selectionPhase = .drawing
            }

            let minX = min(dragStartPoint.x, value.location.x)
            let minY = min(dragStartPoint.y, value.location.y)
            let maxX = max(dragStartPoint.x, value.location.x)
            let maxY = max(dragStartPoint.y, value.location.y)
            selectionRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else if selectionPhase == .adjusting {
            // Check if drag started near a resize handle
            if activeResizeEdge == nil {
                activeResizeEdge = hitTestResizeHandle(at: value.startLocation)
            }

            if let edge = activeResizeEdge {
                resizeSelection(edge: edge, to: value.location)
            } else {
                // Drag started inside the selection — move the whole rect
                let translation = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                let dragOrigin = CGPoint(
                    x: value.startLocation.x - translation.width,
                    y: value.startLocation.y - translation.height
                )
                _ = dragOrigin
                selectionRect = CGRect(
                    x: max(0, min(selectionRect.origin.x + value.translation.width / 60, screenFrame.width - selectionRect.width)),
                    y: max(0, min(selectionRect.origin.y + value.translation.height / 60, screenFrame.height - selectionRect.height)),
                    width: selectionRect.width,
                    height: selectionRect.height
                )
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value) {
        activeResizeEdge = nil
        if selectionPhase == .drawing {
            if selectionRect.width > Self.minimumSelectionSize && selectionRect.height > Self.minimumSelectionSize {
                selectionPhase = .adjusting
            } else {
                selectionPhase = .waitingForDrag
                selectionRect = .zero
            }
        }
    }

    // MARK: - Resize Handles

    enum ResizeEdge: CaseIterable {
        case topLeft, top, topRight
        case left, right
        case bottomLeft, bottom, bottomRight
    }

    private func handlePosition(for edge: ResizeEdge) -> CGPoint {
        let r = selectionRect
        switch edge {
        case .topLeft:     return CGPoint(x: r.minX, y: r.minY)
        case .top:         return CGPoint(x: r.midX, y: r.minY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.minY)
        case .left:        return CGPoint(x: r.minX, y: r.midY)
        case .right:       return CGPoint(x: r.maxX, y: r.midY)
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.maxY)
        case .bottom:      return CGPoint(x: r.midX, y: r.maxY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        }
    }

    private func hitTestResizeHandle(at point: CGPoint) -> ResizeEdge? {
        let hitRadius: CGFloat = 12
        for edge in ResizeEdge.allCases {
            let handlePos = handlePosition(for: edge)
            if hypot(point.x - handlePos.x, point.y - handlePos.y) < hitRadius {
                return edge
            }
        }
        return nil
    }

    private func resizeSelection(edge: ResizeEdge, to point: CGPoint) {
        var r = selectionRect
        switch edge {
        case .topLeft:
            r = CGRect(x: point.x, y: point.y, width: r.maxX - point.x, height: r.maxY - point.y)
        case .top:
            r = CGRect(x: r.minX, y: point.y, width: r.width, height: r.maxY - point.y)
        case .topRight:
            r = CGRect(x: r.minX, y: point.y, width: point.x - r.minX, height: r.maxY - point.y)
        case .left:
            r = CGRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: r.height)
        case .right:
            r = CGRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: r.height)
        case .bottomLeft:
            r = CGRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: point.y - r.minY)
        case .bottom:
            r = CGRect(x: r.minX, y: r.minY, width: r.width, height: point.y - r.minY)
        case .bottomRight:
            r = CGRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: point.y - r.minY)
        }

        if r.width >= Self.minimumSelectionSize && r.height >= Self.minimumSelectionSize {
            selectionRect = r
        }
    }

    // MARK: - Confirm / Cancel

    private func confirmSelection() {
        guard selectionRect.width > Self.minimumSelectionSize,
              selectionRect.height > Self.minimumSelectionSize else { return }

        // Flash the selection white briefly like a camera shutter
        confirmationFlashOpacity = 0.3
        withAnimation(.easeOut(duration: 0.1)) {
            confirmationFlashOpacity = 0
        }

        // Brief delay for the flash to play before processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.cropAndConfirmSelection()
        }
    }

    private func cropAndConfirmSelection() {
        guard selectionRect.width > Self.minimumSelectionSize,
              selectionRect.height > Self.minimumSelectionSize else { return }

        // Crop the screenshot to the selected region.
        // The screenshot image covers the full screen, so selection coordinates
        // map directly to image coordinates (at screen-point resolution).
        let imageSize = screenshotImage.size
        let scaleX = imageSize.width / screenFrame.width
        let scaleY = imageSize.height / screenFrame.height

        let cropRect = CGRect(
            x: selectionRect.origin.x * scaleX,
            y: selectionRect.origin.y * scaleY,
            width: selectionRect.width * scaleX,
            height: selectionRect.height * scaleY
        )

        // Get the CGImage from the NSImage and crop it
        guard let cgImage = screenshotImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let croppedCGImage = cgImage.cropping(to: cropRect) else {
            onCancel()
            return
        }

        let croppedImage = NSBitmapImageRep(cgImage: croppedCGImage)
        guard let jpegData = croppedImage.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            onCancel()
            return
        }

        onConfirm(jpegData, selectionRect)
    }
}

// MARK: - Key Event Handling

/// An NSView subclass that handles keyDown events for the screenshot selection overlay.
/// SwiftUI views inside an NSPanel that normally ignoresMouseEvents can't receive key events
/// directly, so this hosting view captures Enter and Escape.
class ScreenshotSelectionKeyHandler: NSView {
    var onEnter: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Enter/Return
            onEnter?()
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }
}
