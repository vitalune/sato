//
//  LocalSpeechTranscriptionManager.swift
//  leanring-buddy
//
//  Owns Sato Local model downloads, microphone capture, and on-device
//  transcription through WhisperKit.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import WhisperKit

enum LocalSpeechModel: String, CaseIterable, Hashable, Identifiable {
    case fast
    case accurate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .accurate:
            return "Accurate"
        }
    }

    var detailText: String {
        switch self {
        case .fast:
            return "Best for quick everyday questions"
        case .accurate:
            return "Best for technical terms and formulas"
        }
    }

    var approximateDownloadSizeText: String {
        switch self {
        case .fast:
            return "About 650 MB"
        case .accurate:
            return "About 950 MB"
        }
    }

    /// These are the WhisperKit Core ML conversions of the two OpenAI models.
    /// WhisperKit searches the Argmax model repository using this exact folder name.
    var whisperKitModelVariant: String {
        switch self {
        case .fast:
            return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .accurate:
            return "openai_whisper-large-v3_947MB"
        }
    }
}

enum LocalSpeechModelDownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(message: String)
}

enum LocalSpeechOperationState: Equatable {
    case idle
    case loadingModel
    case requestingMicrophonePermission
    case recording
    case transcribing
}

enum LocalSpeechMicrophonePermission: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

@MainActor
final class LocalSpeechTranscriptionManager: ObservableObject {
    @Published private(set) var selectedModel: LocalSpeechModel
    @Published private(set) var modelDownloadStates: [LocalSpeechModel: LocalSpeechModelDownloadState]
    @Published private(set) var operationState: LocalSpeechOperationState = .idle
    @Published private(set) var microphonePermission: LocalSpeechMicrophonePermission = .notDetermined
    @Published private(set) var lastErrorMessage: String?

    private static let selectedModelUserDefaultsKey = "satoLocalSelectedSpeechModel"
    private static let downloadedModelFolderUserDefaultsKeyPrefix = "satoLocalDownloadedModelFolder."
    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    private static let minimumTranscriptionSampleCount = 4_000
    private static let maximumContextPromptCharacterCount = 800

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let speechModelsDirectoryURL: URL

    private var modelDownloadTasks: [LocalSpeechModel: Task<Void, Never>] = [:]
    private var cancelledModelDownloads: Set<LocalSpeechModel> = []
    private var loadedWhisperKit: WhisperKit?
    private var loadedSpeechModel: LocalSpeechModel?

    init(
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.userDefaults = userDefaults

        let applicationSupportDirectoryURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        speechModelsDirectoryURL = applicationSupportDirectoryURL
            .appendingPathComponent("Sato", isDirectory: true)
            .appendingPathComponent("SpeechModels", isDirectory: true)

        if let savedModelRawValue = userDefaults.string(
            forKey: Self.selectedModelUserDefaultsKey
        ), let savedModel = LocalSpeechModel(rawValue: savedModelRawValue) {
            selectedModel = savedModel
        } else {
            selectedModel = .fast
        }

        var initialDownloadStates: [LocalSpeechModel: LocalSpeechModelDownloadState] = [:]
        for speechModel in LocalSpeechModel.allCases {
            let savedModelFolderPath = userDefaults.string(
                forKey: Self.downloadedModelFolderUserDefaultsKeyPrefix + speechModel.rawValue
            )
            if let savedModelFolderPath,
               fileManager.fileExists(atPath: savedModelFolderPath) {
                initialDownloadStates[speechModel] = .downloaded
            } else {
                initialDownloadStates[speechModel] = .notDownloaded
            }
        }
        modelDownloadStates = initialDownloadStates
        refreshMicrophonePermission()
    }

    var selectedModelDownloadState: LocalSpeechModelDownloadState {
        modelDownloadState(for: selectedModel)
    }

    var isSpeechInputBusy: Bool {
        operationState != .idle
    }

    var isRecording: Bool {
        operationState == .recording
    }

    var canChangeSelectedModel: Bool {
        operationState == .idle
    }

    var compactStatusMessage: String? {
        if let lastErrorMessage {
            return lastErrorMessage
        }

        switch operationState {
        case .loadingModel:
            return "Preparing \(selectedModel.displayName) on this Mac…"
        case .requestingMicrophonePermission:
            return "Waiting for microphone access…"
        case .recording:
            return "Listening… click stop when you’re done."
        case .transcribing:
            return "Transcribing on this Mac…"
        case .idle:
            break
        }

        switch selectedModelDownloadState {
        case .notDownloaded:
            return "Download \(selectedModel.displayName) once to use private voice input."
        case .downloading(let progress):
            return "Downloading \(selectedModel.displayName)… \(Int(progress * 100))%"
        case .failed(let message):
            return message
        case .downloaded:
            return nil
        }
    }

    func modelDownloadState(for speechModel: LocalSpeechModel) -> LocalSpeechModelDownloadState {
        modelDownloadStates[speechModel] ?? .notDownloaded
    }

    func selectModel(_ speechModel: LocalSpeechModel) {
        guard canChangeSelectedModel else { return }
        selectedModel = speechModel
        userDefaults.set(speechModel.rawValue, forKey: Self.selectedModelUserDefaultsKey)
        lastErrorMessage = nil
    }

    func downloadSelectedModel() {
        downloadModel(selectedModel)
    }

    func downloadModel(_ speechModel: LocalSpeechModel) {
        guard modelDownloadTasks[speechModel] == nil else { return }

        cancelledModelDownloads.remove(speechModel)
        lastErrorMessage = nil
        setModelDownloadState(.downloading(progress: 0), for: speechModel)

        modelDownloadTasks[speechModel] = Task { [weak self] in
            guard let self else { return }
            await self.performModelDownload(speechModel)
        }
    }

    func cancelSelectedModelDownload() {
        cancelModelDownload(selectedModel)
    }

    func cancelModelDownload(_ speechModel: LocalSpeechModel) {
        guard let modelDownloadTask = modelDownloadTasks[speechModel] else { return }
        cancelledModelDownloads.insert(speechModel)
        modelDownloadTask.cancel()
        setModelDownloadState(.notDownloaded, for: speechModel)
    }

    func deleteSelectedModel() {
        deleteModel(selectedModel)
    }

    func deleteModel(_ speechModel: LocalSpeechModel) {
        guard operationState == .idle else { return }

        cancelModelDownload(speechModel)
        lastErrorMessage = nil

        let loadedModelToUnload = loadedSpeechModel == speechModel ? loadedWhisperKit : nil
        if loadedModelToUnload != nil {
            loadedWhisperKit = nil
            loadedSpeechModel = nil
        }

        Task { [weak self] in
            if let loadedModelToUnload {
                await loadedModelToUnload.unloadModels()
            }
            guard let self else { return }
            self.removeDownloadedModelFiles(speechModel)
            self.setModelDownloadState(.notDownloaded, for: speechModel)
        }
    }

    /// Starts microphone capture. If the selected model has not been downloaded,
    /// the same click begins its one-time download and recording remains off.
    func startRecording() async {
        guard operationState == .idle else { return }
        lastErrorMessage = nil

        guard selectedModelDownloadState == .downloaded else {
            downloadSelectedModel()
            return
        }

        do {
            operationState = .loadingModel
            let whisperKit = try await whisperKitForSelectedModel()
            try Task.checkCancellation()

            operationState = .requestingMicrophonePermission
            let microphoneAccessWasGranted = await AudioProcessor.requestRecordPermission()
            refreshMicrophonePermission()
            try Task.checkCancellation()

            guard microphoneAccessWasGranted else {
                operationState = .idle
                lastErrorMessage = "Microphone access is off. Enable it in System Settings to use Sato Local."
                return
            }

            whisperKit.audioProcessor.purgeAudioSamples(keepingLast: 0)
            try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
            operationState = .recording
        } catch is CancellationError {
            operationState = .idle
        } catch {
            operationState = .idle
            lastErrorMessage = "Sato Local couldn’t start recording. \(error.localizedDescription)"
        }
    }

    func stopRecordingAndTranscribe(contextPrompt: String?) async -> String? {
        guard operationState == .recording,
              let loadedWhisperKit
        else {
            return nil
        }

        loadedWhisperKit.audioProcessor.stopRecording()
        var capturedAudioSamples = Array(loadedWhisperKit.audioProcessor.audioSamples)
        loadedWhisperKit.audioProcessor.purgeAudioSamples(keepingLast: 0)

        guard capturedAudioSamples.count >= Self.minimumTranscriptionSampleCount else {
            capturedAudioSamples.removeAll(keepingCapacity: false)
            operationState = .idle
            lastErrorMessage = "I didn’t catch enough audio. Try speaking a little longer."
            return nil
        }

        operationState = .transcribing
        lastErrorMessage = nil

        defer {
            capturedAudioSamples.removeAll(keepingCapacity: false)
            loadedWhisperKit.audioProcessor.purgeAudioSamples(keepingLast: 0)
            operationState = .idle
        }

        do {
            let promptTokens = transcriptionPromptTokens(
                contextPrompt: contextPrompt,
                whisperKit: loadedWhisperKit
            )
            let decodingOptions = DecodingOptions(
                language: nil,
                detectLanguage: true,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                promptTokens: promptTokens,
                chunkingStrategy: .vad
            )
            let transcriptionResults = try await loadedWhisperKit.transcribe(
                audioArray: capturedAudioSamples,
                decodeOptions: decodingOptions
            )
            try Task.checkCancellation()

            let transcriptionText = transcriptionResults
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcriptionText.isEmpty else {
                lastErrorMessage = "I couldn’t hear a clear phrase. Try again closer to the microphone."
                return nil
            }

            return transcriptionText
        } catch is CancellationError {
            return nil
        } catch {
            lastErrorMessage = "Sato Local couldn’t transcribe that recording. \(error.localizedDescription)"
            return nil
        }
    }

    func cancelActiveSpeechOperation() {
        loadedWhisperKit?.audioProcessor.stopRecording()
        loadedWhisperKit?.audioProcessor.purgeAudioSamples(keepingLast: 0)
        operationState = .idle
    }

    func refreshMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            microphonePermission = .notDetermined
        case .authorized:
            microphonePermission = .authorized
        case .denied:
            microphonePermission = .denied
        case .restricted:
            microphonePermission = .restricted
        @unknown default:
            microphonePermission = .denied
        }
    }

    func openMicrophonePrivacySettings() {
        guard let microphoneSettingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        ) else {
            return
        }
        NSWorkspace.shared.open(microphoneSettingsURL)
    }

    func stop() {
        for modelDownloadTask in modelDownloadTasks.values {
            modelDownloadTask.cancel()
        }
        modelDownloadTasks.removeAll()
        cancelActiveSpeechOperation()

        let loadedWhisperKit = loadedWhisperKit
        self.loadedWhisperKit = nil
        loadedSpeechModel = nil
        Task {
            await loadedWhisperKit?.unloadModels()
        }
    }

    // MARK: - Model Download and Loading

    private func performModelDownload(_ speechModel: LocalSpeechModel) async {
        defer {
            modelDownloadTasks[speechModel] = nil
            cancelledModelDownloads.remove(speechModel)
        }

        let modelDownloadBaseURL = modelDownloadBaseURL(for: speechModel)

        do {
            try fileManager.createDirectory(
                at: modelDownloadBaseURL,
                withIntermediateDirectories: true
            )

            let downloadedModelFolderURL = try await WhisperKit.download(
                variant: speechModel.whisperKitModelVariant,
                downloadBase: modelDownloadBaseURL,
                useBackgroundSession: false,
                from: Self.modelRepository,
                progressCallback: { [weak self] downloadProgress in
                    let completedFraction = downloadProgress.fractionCompleted
                    Task { @MainActor [weak self] in
                        self?.updateModelDownloadProgress(
                            completedFraction,
                            for: speechModel
                        )
                    }
                }
            )
            try Task.checkCancellation()

            userDefaults.set(
                downloadedModelFolderURL.path,
                forKey: downloadedModelFolderUserDefaultsKey(for: speechModel)
            )
            setModelDownloadState(.downloaded, for: speechModel)
        } catch {
            let downloadWasCancelled = error is CancellationError
                || Task.isCancelled
                || cancelledModelDownloads.contains(speechModel)
            removeDownloadedModelFiles(speechModel)

            if downloadWasCancelled {
                setModelDownloadState(.notDownloaded, for: speechModel)
            } else {
                let failureMessage = "Couldn’t download \(speechModel.displayName). Check your connection and try again."
                setModelDownloadState(.failed(message: failureMessage), for: speechModel)
            }
        }
    }

    private func updateModelDownloadProgress(
        _ progress: Double,
        for speechModel: LocalSpeechModel
    ) {
        guard modelDownloadTasks[speechModel] != nil,
              !cancelledModelDownloads.contains(speechModel)
        else {
            return
        }
        let clampedProgress = min(max(progress, 0), 1)
        setModelDownloadState(.downloading(progress: clampedProgress), for: speechModel)
    }

    private func whisperKitForSelectedModel() async throws -> WhisperKit {
        if loadedSpeechModel == selectedModel,
           let loadedWhisperKit {
            return loadedWhisperKit
        }

        if let loadedWhisperKit {
            await loadedWhisperKit.unloadModels()
            self.loadedWhisperKit = nil
            loadedSpeechModel = nil
        }

        guard let downloadedModelFolderURL = downloadedModelFolderURL(for: selectedModel) else {
            setModelDownloadState(.notDownloaded, for: selectedModel)
            throw LocalSpeechTranscriptionError.modelFilesUnavailable
        }

        let whisperKitConfiguration = WhisperKitConfig(
            model: selectedModel.whisperKitModelVariant,
            downloadBase: modelDownloadBaseURL(for: selectedModel),
            modelRepo: Self.modelRepository,
            modelFolder: downloadedModelFolderURL.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false,
            useBackgroundDownloadSession: false
        )
        let newlyLoadedWhisperKit = try await WhisperKit(whisperKitConfiguration)

        if Task.isCancelled {
            await newlyLoadedWhisperKit.unloadModels()
            throw CancellationError()
        }

        loadedWhisperKit = newlyLoadedWhisperKit
        loadedSpeechModel = selectedModel
        return newlyLoadedWhisperKit
    }

    private func transcriptionPromptTokens(
        contextPrompt: String?,
        whisperKit: WhisperKit
    ) -> [Int]? {
        guard let contextPrompt else { return nil }
        let trimmedContextPrompt = contextPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContextPrompt.isEmpty else { return nil }

        let limitedContextPrompt = String(
            trimmedContextPrompt.prefix(Self.maximumContextPromptCharacterCount)
        )
        return whisperKit.tokenizer?.encode(text: limitedContextPrompt)
    }

    private func downloadedModelFolderURL(for speechModel: LocalSpeechModel) -> URL? {
        guard let downloadedModelFolderPath = userDefaults.string(
            forKey: downloadedModelFolderUserDefaultsKey(for: speechModel)
        ), fileManager.fileExists(atPath: downloadedModelFolderPath)
        else {
            return nil
        }
        return URL(fileURLWithPath: downloadedModelFolderPath, isDirectory: true)
    }

    private func modelDownloadBaseURL(for speechModel: LocalSpeechModel) -> URL {
        speechModelsDirectoryURL.appendingPathComponent(speechModel.rawValue, isDirectory: true)
    }

    private func downloadedModelFolderUserDefaultsKey(for speechModel: LocalSpeechModel) -> String {
        Self.downloadedModelFolderUserDefaultsKeyPrefix + speechModel.rawValue
    }

    private func removeDownloadedModelFiles(_ speechModel: LocalSpeechModel) {
        let modelDownloadBaseURL = modelDownloadBaseURL(for: speechModel)
        if fileManager.fileExists(atPath: modelDownloadBaseURL.path) {
            try? fileManager.removeItem(at: modelDownloadBaseURL)
        }
        userDefaults.removeObject(forKey: downloadedModelFolderUserDefaultsKey(for: speechModel))
    }

    private func setModelDownloadState(
        _ downloadState: LocalSpeechModelDownloadState,
        for speechModel: LocalSpeechModel
    ) {
        var updatedModelDownloadStates = modelDownloadStates
        updatedModelDownloadStates[speechModel] = downloadState
        modelDownloadStates = updatedModelDownloadStates
    }
}

private enum LocalSpeechTranscriptionError: LocalizedError {
    case modelFilesUnavailable

    var errorDescription: String? {
        switch self {
        case .modelFilesUnavailable:
            return "The selected speech model needs to be downloaded again."
        }
    }
}
