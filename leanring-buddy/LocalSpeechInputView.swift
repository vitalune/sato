//
//  LocalSpeechInputView.swift
//  leanring-buddy
//
//  Reusable Sato Local controls for question composers and the menu panel.
//

import SwiftUI

struct LocalSpeechInputButton: View {
    @ObservedObject private var speechTranscriptionManager: LocalSpeechTranscriptionManager
    @Binding private var inputText: String

    private let contextPrompt: String?
    private let foregroundColor: Color
    private let isExternallyDisabled: Bool
    private let onTranscriptInserted: () -> Void

    @State private var speechOperationTask: Task<Void, Never>?

    init(
        speechTranscriptionManager: LocalSpeechTranscriptionManager,
        inputText: Binding<String>,
        contextPrompt: String?,
        foregroundColor: Color,
        isExternallyDisabled: Bool = false,
        onTranscriptInserted: @escaping () -> Void = {}
    ) {
        self.speechTranscriptionManager = speechTranscriptionManager
        _inputText = inputText
        self.contextPrompt = contextPrompt
        self.foregroundColor = foregroundColor
        self.isExternallyDisabled = isExternallyDisabled
        self.onTranscriptInserted = onTranscriptInserted
    }

    var body: some View {
        Button(action: handleButtonClick) {
            ZStack {
                Circle()
                    .fill(buttonBackgroundColor)

                buttonContent
            }
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isButtonDisabled)
        .help(buttonHelpText)
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityValue(buttonAccessibilityValue)
        .onDisappear {
            speechOperationTask?.cancel()
            speechTranscriptionManager.cancelActiveSpeechOperation()
        }
    }

    @ViewBuilder
    private var buttonContent: some View {
        switch speechTranscriptionManager.operationState {
        case .loadingModel, .requestingMicrophonePermission, .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(foregroundColor)
        case .recording:
            Image(systemName: "stop.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
        case .idle:
            switch speechTranscriptionManager.selectedModelDownloadState {
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .tint(foregroundColor)
            case .notDownloaded:
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(foregroundColor)
            case .failed:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(DS.Colors.warningText)
            case .downloaded:
                Image(systemName: "mic.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(foregroundColor)
            }
        }
    }

    private var buttonBackgroundColor: Color {
        if speechTranscriptionManager.isRecording {
            return DS.Colors.destructive
        }
        return Color.white.opacity(0.08)
    }

    private var isButtonDisabled: Bool {
        if isExternallyDisabled && !speechTranscriptionManager.isRecording {
            return true
        }

        switch speechTranscriptionManager.operationState {
        case .loadingModel, .requestingMicrophonePermission, .transcribing:
            return true
        case .idle, .recording:
            return false
        }
    }

    private var buttonHelpText: String {
        switch speechTranscriptionManager.operationState {
        case .loadingModel:
            return "Preparing Sato Local"
        case .requestingMicrophonePermission:
            return "Waiting for microphone access"
        case .recording:
            return "Stop and transcribe"
        case .transcribing:
            return "Transcribing on this Mac"
        case .idle:
            switch speechTranscriptionManager.selectedModelDownloadState {
            case .notDownloaded, .failed:
                return "Download \(speechTranscriptionManager.selectedModel.displayName) for Sato Local"
            case .downloading:
                return "Cancel model download"
            case .downloaded:
                return "Speak with Sato Local"
            }
        }
    }

    private var buttonAccessibilityLabel: String {
        switch speechTranscriptionManager.operationState {
        case .recording:
            return "Stop voice input"
        case .transcribing:
            return "Transcribing voice input"
        default:
            return "Sato Local voice input"
        }
    }

    private var buttonAccessibilityValue: String {
        speechTranscriptionManager.compactStatusMessage ?? "Ready"
    }

    private func handleButtonClick() {
        if speechTranscriptionManager.isRecording {
            speechOperationTask?.cancel()
            speechOperationTask = Task {
                let transcriptionText = await speechTranscriptionManager.stopRecordingAndTranscribe(
                    contextPrompt: contextPrompt
                )
                guard let transcriptionText, !Task.isCancelled else { return }
                inputText = Self.appendingTranscript(
                    transcriptionText,
                    to: inputText
                )
                onTranscriptInserted()
            }
            return
        }

        switch speechTranscriptionManager.selectedModelDownloadState {
        case .notDownloaded, .failed:
            speechTranscriptionManager.downloadSelectedModel()
        case .downloading:
            speechTranscriptionManager.cancelSelectedModelDownload()
        case .downloaded:
            speechOperationTask?.cancel()
            speechOperationTask = Task {
                await speechTranscriptionManager.startRecording()
            }
        }
    }

    private static func appendingTranscript(
        _ transcriptionText: String,
        to existingText: String
    ) -> String {
        guard !existingText.isEmpty else { return transcriptionText }
        guard existingText.last?.isWhitespace != true else {
            return existingText + transcriptionText
        }
        return existingText + " " + transcriptionText
    }
}

struct LocalSpeechCompactStatusView: View {
    @ObservedObject var speechTranscriptionManager: LocalSpeechTranscriptionManager
    let textColor: Color

    var body: some View {
        if let compactStatusMessage = speechTranscriptionManager.compactStatusMessage {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: statusSymbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(statusColor)

                Text(compactStatusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var statusSymbolName: String {
        if speechTranscriptionManager.lastErrorMessage != nil {
            return "exclamationmark.triangle.fill"
        }

        switch speechTranscriptionManager.operationState {
        case .recording:
            return "waveform"
        case .transcribing:
            return "text.magnifyingglass"
        case .loadingModel, .requestingMicrophonePermission:
            return "hourglass"
        case .idle:
            switch speechTranscriptionManager.selectedModelDownloadState {
            case .failed:
                return "exclamationmark.triangle.fill"
            case .downloading:
                return "arrow.down.circle"
            case .notDownloaded:
                return "lock.shield"
            case .downloaded:
                return "checkmark.circle"
            }
        }
    }

    private var statusColor: Color {
        if speechTranscriptionManager.lastErrorMessage != nil {
            return DS.Colors.warningText
        }
        if case .failed = speechTranscriptionManager.selectedModelDownloadState {
            return DS.Colors.warningText
        }
        if speechTranscriptionManager.isRecording {
            return DS.Colors.destructiveText
        }
        return textColor
    }
}

struct LocalSpeechSettingsRow: View {
    @ObservedObject var speechTranscriptionManager: LocalSpeechTranscriptionManager
    @State private var isSettingsPresented = false

    var body: some View {
        Button {
            isSettingsPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice Input")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Sato Local · \(speechTranscriptionManager.selectedModel.displayName)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                rowStatusContent

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Configure Sato Local voice input")
        .popover(isPresented: $isSettingsPresented, arrowEdge: .trailing) {
            LocalSpeechSettingsView(
                speechTranscriptionManager: speechTranscriptionManager
            )
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var rowStatusContent: some View {
        switch speechTranscriptionManager.selectedModelDownloadState {
        case .notDownloaded:
            Text("Set Up")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
        case .downloading(let progress):
            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundColor(DS.Colors.accentText)
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.success)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.warningText)
        }
    }
}

private struct LocalSpeechSettingsView: View {
    @ObservedObject var speechTranscriptionManager: LocalSpeechTranscriptionManager
    @State private var isConfirmingModelRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 20))
                    .foregroundColor(DS.Colors.accentText)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sato Local")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)

                    Text("Private voice input powered by WhisperKit")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                }
            }

            Picker(
                "Speech model",
                selection: Binding(
                    get: { speechTranscriptionManager.selectedModel },
                    set: { speechTranscriptionManager.selectModel($0) }
                )
            ) {
                ForEach(LocalSpeechModel.allCases) { speechModel in
                    Text(speechModel.displayName)
                        .tag(speechModel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .pointerCursor()
            .disabled(!speechTranscriptionManager.canChangeSelectedModel)

            VStack(alignment: .leading, spacing: 3) {
                Text(speechTranscriptionManager.selectedModel.detailText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("\(speechTranscriptionManager.selectedModel.approximateDownloadSizeText). Downloads once, then works offline.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            modelDownloadStatus

            if speechTranscriptionManager.microphonePermission == .denied
                || speechTranscriptionManager.microphonePermission == .restricted {
                Button {
                    speechTranscriptionManager.openMicrophonePrivacySettings()
                } label: {
                    Label("Open Microphone Settings", systemImage: "mic.slash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointerCursor()
            }

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.success)

                Text("Microphone audio stays on this Mac. Only the text you choose to send goes to your selected AI provider.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(DS.Colors.surface1)
        .alert("Remove \(speechTranscriptionManager.selectedModel.displayName)?", isPresented: $isConfirmingModelRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                speechTranscriptionManager.deleteSelectedModel()
            }
        } message: {
            Text("You can download this speech model again later.")
        }
        .onAppear {
            speechTranscriptionManager.refreshMicrophonePermission()
        }
    }

    @ViewBuilder
    private var modelDownloadStatus: some View {
        switch speechTranscriptionManager.selectedModelDownloadState {
        case .notDownloaded:
            modelActionButton(
                title: "Download \(speechTranscriptionManager.selectedModel.displayName)",
                systemImage: "arrow.down.circle.fill",
                isDestructive: false,
                action: speechTranscriptionManager.downloadSelectedModel
            )
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(value: progress)
                    .tint(DS.Colors.accentText)

                HStack {
                    Text("Downloading…")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                }

                modelActionButton(
                    title: "Cancel Download",
                    systemImage: "xmark",
                    isDestructive: false,
                    action: speechTranscriptionManager.cancelSelectedModelDownload
                )
            }
        case .downloaded:
            HStack {
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)

                Spacer()

                Button("Remove") {
                    isConfirmingModelRemoval = true
                }
                .font(.system(size: 10, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.destructiveText)
                .pointerCursor()
                .disabled(!speechTranscriptionManager.canChangeSelectedModel)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)

                modelActionButton(
                    title: "Try Again",
                    systemImage: "arrow.clockwise",
                    isDestructive: false,
                    action: speechTranscriptionManager.downloadSelectedModel
                )
            }
        }
    }

    private func modelActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isDestructive ? DS.Colors.destructiveText : DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isDestructive ? Color.clear : DS.Colors.accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isDestructive ? DS.Colors.destructive : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!speechTranscriptionManager.canChangeSelectedModel)
    }
}
