//
//  LocalSpeechInputView.swift
//  leanring-buddy
//
//  Reusable Sato Local controls for question composers and the menu panel.
//

import SwiftUI

struct LocalSpeechInputButton: View {
    static let keyboardShortcutDescription = "Cmd + Shift + M"

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
        .keyboardShortcut("m", modifiers: [.command, .shift])
        .help("\(buttonHelpText) (\(Self.keyboardShortcutDescription))")
        .accessibilityLabel(buttonAccessibilityLabel)
        .accessibilityValue(buttonAccessibilityValue)
        .accessibilityHint("Press Command Shift M while a prompt is open.")
        .onDisappear {
            speechOperationTask?.cancel()
            speechTranscriptionManager.cancelActiveSpeechOperation()
        }
    }

    @ViewBuilder
    private var buttonContent: some View {
        switch speechTranscriptionManager.operationState {
        case .requestingMicrophonePermission, .transcribing:
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
                switch speechTranscriptionManager.selectedModelPreparationState {
                case .notPrepared:
                    Image(systemName: "cpu")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(foregroundColor)
                case .preparing, .cancelling:
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                case .ready:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(foregroundColor)
                case .failed:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(DS.Colors.warningText)
                }
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
        case .requestingMicrophonePermission, .transcribing:
            return true
        case .recording:
            return false
        case .idle:
            guard speechTranscriptionManager.selectedModelDownloadState == .downloaded else {
                return false
            }
            return speechTranscriptionManager.selectedModelPreparationState.isPreparingOrCancelling
        }
    }

    private var buttonHelpText: String {
        switch speechTranscriptionManager.operationState {
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
                switch speechTranscriptionManager.selectedModelPreparationState {
                case .notPrepared:
                    return "Set up Sato Local"
                case .preparing:
                    return "Setting up Sato Local"
                case .cancelling:
                    return "Stopping Sato Local setup"
                case .ready:
                    return "Speak with Sato Local"
                case .failed:
                    return "Retry Sato Local setup"
                }
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
            switch speechTranscriptionManager.selectedModelPreparationState {
            case .notPrepared, .failed:
                speechTranscriptionManager.prepareSelectedModel()
            case .preparing, .cancelling:
                break
            case .ready:
                speechOperationTask?.cancel()
                speechOperationTask = Task {
                    await speechTranscriptionManager.startRecording()
                }
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

    @ViewBuilder
    var body: some View {
        if speechTranscriptionManager.selectedModelPreparationState.startedAt != nil,
           speechTranscriptionManager.operationState == .idle {
            TimelineView(.periodic(from: Date(), by: 1)) { timelineContext in
                statusContent(currentDate: timelineContext.date)
            }
        } else {
            statusContent(currentDate: Date())
        }
    }

    @ViewBuilder
    private func statusContent(currentDate: Date) -> some View {
        if let compactStatusMessage = speechTranscriptionManager.compactStatusMessage(
            at: currentDate
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: statusSymbolName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(statusColor)

                Text(compactStatusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 3)

                statusActionButton
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var statusActionButton: some View {
        if speechTranscriptionManager.operationState == .idle,
           speechTranscriptionManager.selectedModelDownloadState == .downloaded,
           speechTranscriptionManager.lastErrorMessage == nil {
            switch speechTranscriptionManager.selectedModelPreparationState {
            case .notPrepared:
                compactActionButton(
                    title: "Set Up",
                    action: speechTranscriptionManager.prepareSelectedModel
                )
            case .preparing:
                compactActionButton(
                    title: "Cancel",
                    action: speechTranscriptionManager.cancelSelectedModelPreparation
                )
            case .failed:
                compactActionButton(
                    title: "Retry",
                    action: speechTranscriptionManager.prepareSelectedModel
                )
            case .ready:
                switch speechTranscriptionManager.microphonePermission {
                case .notDetermined:
                    compactActionButton(
                        title: speechTranscriptionManager.microphonePermissionRequestFailureMessage == nil
                            ? "Allow"
                            : "Retry",
                        action: speechTranscriptionManager.requestMicrophonePermission
                    )
                case .denied, .restricted:
                    compactActionButton(
                        title: "Settings",
                        action: speechTranscriptionManager.openMicrophonePrivacySettings
                    )
                case .authorized:
                    EmptyView()
                }
            case .cancelling:
                EmptyView()
            }
        }
    }

    private func compactActionButton(
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundColor(DS.Colors.accentText)
            .pointerCursor()
    }

    private var statusSymbolName: String {
        if speechTranscriptionManager.lastErrorMessage != nil ||
            speechTranscriptionManager.microphonePermissionRequestFailureMessage != nil {
            return "exclamationmark.triangle.fill"
        }

        switch speechTranscriptionManager.operationState {
        case .recording:
            return "waveform"
        case .transcribing:
            return "text.magnifyingglass"
        case .requestingMicrophonePermission:
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
                switch speechTranscriptionManager.selectedModelPreparationState {
                case .notPrepared:
                    return "cpu"
                case .preparing:
                    return "gearshape.2"
                case .cancelling:
                    return "xmark.circle"
                case .ready:
                    switch speechTranscriptionManager.microphonePermission {
                    case .notDetermined:
                        return "mic.fill"
                    case .authorized:
                        return "checkmark.circle"
                    case .denied, .restricted:
                        return "mic.slash.fill"
                    }
                case .failed:
                    return "exclamationmark.triangle.fill"
                }
            }
        }
    }

    private var statusColor: Color {
        if speechTranscriptionManager.lastErrorMessage != nil ||
            speechTranscriptionManager.microphonePermissionRequestFailureMessage != nil {
            return DS.Colors.warningText
        }
        if case .failed = speechTranscriptionManager.selectedModelDownloadState {
            return DS.Colors.warningText
        }
        if case .failed = speechTranscriptionManager.selectedModelPreparationState {
            return DS.Colors.warningText
        }
        if speechTranscriptionManager.selectedModelPreparationState == .ready,
           (speechTranscriptionManager.microphonePermission == .denied
            || speechTranscriptionManager.microphonePermission == .restricted) {
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
            switch speechTranscriptionManager.selectedModelPreparationState {
            case .notPrepared:
                Text("Set Up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
            case .preparing(let stage, _):
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)

                    Text("\(stage.rawValue)/\(LocalSpeechModelPreparationStage.totalStageCount)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                }
            case .cancelling:
                ProgressView()
                    .controlSize(.mini)
            case .ready:
                readyModelStatusContent
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warningText)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.warningText)
        }
    }

    @ViewBuilder
    private var readyModelStatusContent: some View {
        switch speechTranscriptionManager.microphonePermission {
        case .notDetermined:
            Image(systemName: "mic.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.accentText)
        case .authorized:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.success)
        case .denied, .restricted:
            Image(systemName: "mic.slash.fill")
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

            microphonePermissionStatus

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
    private var microphonePermissionStatus: some View {
        if speechTranscriptionManager.operationState == .requestingMicrophonePermission {
            Label("Waiting for microphone access…", systemImage: "hourglass")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textSecondary)
        } else {
            switch speechTranscriptionManager.microphonePermission {
            case .notDetermined:
                if speechTranscriptionManager.selectedModelPreparationState == .ready {
                    VStack(alignment: .leading, spacing: 8) {
                        if let microphonePermissionRequestFailureMessage =
                            speechTranscriptionManager.microphonePermissionRequestFailureMessage {
                            Label(
                                microphonePermissionRequestFailureMessage,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.warningText)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        Button {
                            speechTranscriptionManager.requestMicrophonePermission()
                        } label: {
                            Label(
                                speechTranscriptionManager.microphonePermissionRequestFailureMessage == nil
                                    ? "Allow Microphone Access"
                                    : "Try Again",
                                systemImage: "mic"
                            )
                            .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .pointerCursor()
                    }
                }
            case .authorized:
                EmptyView()
            case .denied, .restricted:
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
            modelPreparationStatus
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

    @ViewBuilder
    private var modelPreparationStatus: some View {
        switch speechTranscriptionManager.selectedModelPreparationState {
        case .notPrepared:
            VStack(alignment: .leading, spacing: 8) {
                Text("The model is downloaded. Finish one-time setup before using voice input.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                modelActionButton(
                    title: "Finish Setup",
                    systemImage: "cpu",
                    isDestructive: false,
                    action: speechTranscriptionManager.prepareSelectedModel
                )
            }
        case .preparing(let stage, let startedAt):
            TimelineView(.periodic(from: Date(), by: 1)) { timelineContext in
                VStack(alignment: .leading, spacing: 7) {
                    ProgressView(
                        value: Double(stage.completedStageCount),
                        total: Double(LocalSpeechModelPreparationStage.totalStageCount)
                    )
                    .tint(DS.Colors.accentText)

                    HStack(alignment: .firstTextBaseline) {
                        Text(stage.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.textPrimary)

                        Spacer()

                        Text(
                            LocalSpeechTranscriptionManager.elapsedPreparationTimeText(
                                since: startedAt,
                                currentDate: timelineContext.date
                            )
                        )
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                    }

                    Text("Step \(stage.rawValue) of \(LocalSpeechModelPreparationStage.totalStageCount). You can keep using Sato while this finishes.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    modelActionButton(
                        title: "Cancel Setup",
                        systemImage: "xmark",
                        isDestructive: false,
                        isDisabled: false,
                        action: speechTranscriptionManager.cancelSelectedModelPreparation
                    )
                }
            }
        case .cancelling:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)

                Text("Stopping setup safely…")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        case .ready:
            HStack {
                Label("Ready on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.success)

                Spacer()

                removeModelButton
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)

                modelActionButton(
                    title: "Retry Setup",
                    systemImage: "arrow.clockwise",
                    isDestructive: false,
                    action: speechTranscriptionManager.prepareSelectedModel
                )

                removeModelButton
            }
        }
    }

    private var removeModelButton: some View {
        Button("Remove") {
            isConfirmingModelRemoval = true
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.plain)
        .foregroundColor(DS.Colors.destructiveText)
        .pointerCursor()
        .disabled(!speechTranscriptionManager.canChangeSelectedModel)
    }

    private func modelActionButton(
        title: String,
        systemImage: String,
        isDestructive: Bool,
        isDisabled: Bool? = nil,
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
        .disabled(isDisabled ?? !speechTranscriptionManager.canChangeSelectedModel)
    }
}
