//
//  TextInputView.swift
//  leanring-buddy
//
//  A small floating text field that appears near the sprite after screenshot
//  selection is confirmed. The user types their question about the selected
//  screen region, submits with Enter, or cancels with Escape.
//

import SwiftUI

struct TextInputView: View {
    /// Called with the user's question text when they press Enter.
    let onSubmit: (String) -> Void
    /// Called when the user presses Escape.
    let onCancel: () -> Void

    @State private var inputText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Ask about this area...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .lineLimit(1...5)
                .focused($isTextFieldFocused)
                .onSubmit {
                    submitIfNotEmpty()
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
        )
        .onAppear {
            // The interactive overlay window is already activated and made key
            // by showInteractiveOverlay(). Set focus after a short delay so
            // the SwiftUI view hierarchy has fully laid out and the window's
            // first responder chain is ready to accept the text field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                // Re-activate in case another window stole focus in the gap
                NSApp.activate(ignoringOtherApps: true)
                isTextFieldFocused = true
            }
            // Fallback: if the first attempt didn't stick (can happen when
            // NSHostingView hasn't finished layout), try once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !isTextFieldFocused {
                    isTextFieldFocused = true
                }
            }
        }
    }

    private func submitIfNotEmpty() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        onSubmit(trimmedText)
    }
}
