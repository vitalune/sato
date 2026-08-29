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
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var speechTranscriptionManager: LocalSpeechTranscriptionManager
    let speechContextPrompt: String?
    /// Called with the user's question text when they press Enter.
    let onSubmit: (String) -> Void
    /// Called when the user presses Escape.
    let onCancel: () -> Void

    @State private var inputText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
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
                        speechTranscriptionManager.cancelActiveSpeechOperation()
                        onCancel()
                        return .handled
                    }

                LocalSpeechInputButton(
                    speechTranscriptionManager: speechTranscriptionManager,
                    inputText: $inputText,
                    contextPrompt: speechContextPrompt,
                    foregroundColor: DS.Colors.textSecondary,
                    onTranscriptInserted: {
                        isTextFieldFocused = true
                    }
                )
            }

            LocalSpeechCompactStatusView(
                speechTranscriptionManager: speechTranscriptionManager,
                textColor: DS.Colors.textTertiary
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 360)
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
            requestInputFocusIfVisualRuntimeIsActive()
        }
        .onChange(of: companionManager.isVisualRuntimePaused) { _, isPaused in
            if isPaused {
                isTextFieldFocused = false
            } else {
                requestInputFocusIfVisualRuntimeIsActive()
            }
        }
    }

    private func requestInputFocusIfVisualRuntimeIsActive() {
        guard !companionManager.isVisualRuntimePaused,
              !companionManager.isSleeping else {
            return
        }

        // The interactive window is activated by OverlayWindowManager. Delay
        // focus until its hosting hierarchy and responder chain are ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !companionManager.isVisualRuntimePaused,
                  !companionManager.isSleeping else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            isTextFieldFocused = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !companionManager.isVisualRuntimePaused,
                  !companionManager.isSleeping else {
                return
            }
            if !isTextFieldFocused {
                isTextFieldFocused = true
            }
        }
    }

    private func submitIfNotEmpty() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              !speechTranscriptionManager.isSpeechInputBusy
        else {
            return
        }
        onSubmit(trimmedText)
    }
}
