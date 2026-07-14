//
//  SpeechBubbleView.swift
//  leanring-buddy
//
//  A speech bubble that displays Claude's response text above the sprite.
//  White bubble with a small tail pointing down toward the sprite.
//  Text is selectable and scrolls internally if it exceeds max height.
//  Shows a "Press Tab to expand" hint when content overflows.
//

import SwiftUI

struct SpeechBubbleView: View {
    /// The response text to display (updates progressively during streaming).
    let responseText: String
    /// Whether the response is still streaming from Claude.
    let isStreaming: Bool
    /// Name of the active context profile, shown as a subtle header label.
    let activeProfileName: String?
    /// Called when the bubble should be dismissed.
    let onDismiss: () -> Void
    private static let maxBubbleWidth: CGFloat = 400
    private static let maxBubbleHeight: CGFloat = 300
    private static let autoDismissDelay: TimeInterval = 15.0
    /// Height of the triangular tail pointing down to the sprite.
    private static let tailHeight: CGFloat = 8

    @State private var textContentHeight: CGFloat = 0
    @State private var entranceScale: CGFloat = 0.9
    @State private var entranceOpacity: Double = 0.0

    /// Whether the response text exceeds the bubble's max visible height.
    private var isContentOverflowing: Bool {
        textContentHeight > Self.maxBubbleHeight - 40 // Account for padding
    }

    var body: some View {
        VStack(spacing: 0) {
            // Bubble body
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if let activeProfileName, !activeProfileName.isEmpty {
                            Text(activeProfileName)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                        }

                        Group {
                            if isStreaming {
                                Text(responseText)
                                    .font(.system(size: 13))
                                    .foregroundColor(DS.Colors.textPrimary)
                            } else {
                                MarkdownResponseView(markdown: responseText)
                            }
                        }
                            .textSelection(.enabled)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear
                                        .onAppear { textContentHeight = geometry.size.height }
                                        .onChange(of: responseText) { _, _ in
                                            textContentHeight = geometry.size.height
                                        }
                                }
                            )
                    }
                    .frame(maxWidth: Self.maxBubbleWidth - 24, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxWidth: Self.maxBubbleWidth, maxHeight: Self.maxBubbleHeight)

                // "Press Tab to expand" hint when content overflows
                if isContentOverflowing && !isStreaming {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("Press Tab to expand")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .background(
                        VStack(spacing: 0) {
                            LinearGradient(
                                colors: [DS.Colors.surface2.opacity(0), DS.Colors.surface2],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 12)
                            DS.Colors.surface2
                        }
                    )
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DS.Colors.surface2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)

            // Tail pointing down to the sprite
            SpeechBubbleTail()
                .fill(DS.Colors.surface2)
                .frame(width: 16, height: Self.tailHeight)
                .offset(x: -20)
        }
        .fixedSize(horizontal: true, vertical: true)
        .scaleEffect(entranceScale)
        .opacity(entranceOpacity)
        .onAppear {
            // Entrance: 90% scale + 0 opacity → overshoot to 102% → settle to 100%
            withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) {
                entranceScale = 1.0
                entranceOpacity = 1.0
            }
        }
    }
}

/// A small triangular tail shape for the bottom of the speech bubble.
private struct SpeechBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - 8, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX + 8, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
