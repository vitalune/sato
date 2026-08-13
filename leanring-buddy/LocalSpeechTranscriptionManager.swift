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
    case requestingMicrophonePermission
    case recording
    case transcribing
}

enum LocalSpeechModelPreparationStage: Int, Equatable {
    case verifyingModel = 1
    case optimizingForMac = 2
    case loadingSpeechEngine = 3

    static let totalStageCount = 3

    var completedStageCount: Int {
        rawValue - 1
    }

    var displayName: String {
        switch self {
        case .verifyingModel:
            return "Checking model files"
        case .optimizingForMac:
            return "Optimizing for this Mac"
        case .loadingSpeechEngine:
            return "Loading voice engine"
        }
    }
}

enum LocalSpeechModelPreparationState: Equatable {
    case notPrepared
    case preparing(stage: LocalSpeechModelPreparationStage, startedAt: Date)
    case cancelling(startedAt: Date)
    case ready
    case failed(message: String)

    var startedAt: Date? {
        switch self {
        case .preparing(_, let startedAt), .cancelling(let startedAt):
            return startedAt
        case .notPrepared, .ready, .failed:
            return nil
        }
    }

    var isPreparingOrCancelling: Bool {
        switch self {
        case .preparing, .cancelling:
            return true
        case .notPrepared, .ready, .failed:
            return false
        }
    }
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
    @Published private(set) var modelPreparationStates: [LocalSpeechModel: LocalSpeechModelPreparationState]
    @Published private(set) var operationState: LocalSpeechOperationState = .idle
    @Published private(set) var microphonePermission: LocalSpeechMicrophonePermission = .notDetermined
    @Published private(set) var lastErrorMessage: String?

    private static let selectedModelUserDefaultsKey = "satoLocalSelectedSpeechModel"
    private static let downloadedModelFolderUserDefaultsKeyPrefix = "satoLocalDownloadedModelFolder."
    private static let optimizedModelVariantUserDefaultsKeyPrefix = "satoLocalOptimizedModelVariant."
    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    private static let minimumTranscriptionSampleCount = 4_000
    private static let maximumContextPromptCharacterCount = 800
    static let modelPreparationTimeoutDuration: TimeInterval = 10 * 60

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let speechModelsDirectoryURL: URL

    private var modelDownloadTasks: [LocalSpeechModel: Task<Void, Never>] = [:]
    private var cancelledModelDownloads: Set<LocalSpeechModel> = []
    private var modelPreparationTasks: [LocalSpeechModel: Task<Void, Never>] = [:]
    private var modelPreparationTimeoutTasks: [LocalSpeechModel: Task<Void, Never>] = [:]
    private var modelPreparationCancellationReasons: [LocalSpeechModel: ModelPreparationCancellationReason] = [:]
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
        var initialPreparationStates: [LocalSpeechModel: LocalSpeechModelPreparationState] = [:]
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
            initialPreparationStates[speechModel] = .notPrepared
        }
        modelDownloadStates = initialDownloadStates
        modelPreparationStates = initialPreparationStates
        refreshMicrophonePermission()

        // Resume interrupted first-run setup without making the user discover
        // the delay again from the microphone button.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.prepareSelectedModel()
        }
    }

    var selectedModelDownloadState: LocalSpeechModelDownloadState {
        modelDownloadState(for: selectedModel)
    }

    var selectedModelPreparationState: LocalSpeechModelPreparationState {
        modelPreparationState(for: selectedModel)
    }

    var isSpeechInputBusy: Bool {
        operationState != .idle
    }

    var isRecording: Bool {
        operationState == .recording
    }

    var canChangeSelectedModel: Bool {
        operationState == .idle && !selectedModelPreparationState.isPreparingOrCancelling
    }

    var compactStatusMessage: String? {
        compactStatusMessage(at: Date())
    }

    func compactStatusMessage(at currentDate: Date) -> String? {
        if let lastErrorMessage {
            return lastErrorMessage
        }

        switch operationState {
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
            switch selectedModelPreparationState {
            case .notPrepared:
                return "Finish setting up \(selectedModel.displayName) to use voice input."
            case .preparing(let stage, let startedAt):
                let elapsedTimeText = Self.elapsedPreparationTimeText(
                    since: startedAt,
                    currentDate: currentDate
                )
                return "\(stage.displayName) · Step \(stage.rawValue) of \(LocalSpeechModelPreparationStage.totalStageCount) · \(elapsedTimeText)"
            case .cancelling:
                return "Stopping \(selectedModel.displayName) setup…"
            case .ready:
                return nil
            case .failed(let message):
                return message
            }
        }
    }

    static func elapsedPreparationTimeText(
        since startedAt: Date,
        currentDate: Date
    ) -> String {
        let elapsedSeconds = max(0, Int(currentDate.timeIntervalSince(startedAt)))
        guard elapsedSeconds >= 60 else {
            return "\(elapsedSeconds)s elapsed"
        }

        let elapsedMinutes = elapsedSeconds / 60
        let remainingSeconds = elapsedSeconds % 60
        return String(format: "%dm %02ds elapsed", elapsedMinutes, remainingSeconds)
    }

    func modelDownloadState(for speechModel: LocalSpeechModel) -> LocalSpeechModelDownloadState {
        modelDownloadStates[speechModel] ?? .notDownloaded
    }

    func modelPreparationState(for speechModel: LocalSpeechModel) -> LocalSpeechModelPreparationState {
        modelPreparationStates[speechModel] ?? .notPrepared
    }

    func selectModel(_ speechModel: LocalSpeechModel) {
        guard canChangeSelectedModel, speechModel != selectedModel else { return }

        selectedModel = speechModel
        userDefaults.set(speechModel.rawValue, forKey: Self.selectedModelUserDefaultsKey)
        lastErrorMessage = nil
        prepareSelectedModel()
    }

    func downloadSelectedModel() {
        downloadModel(selectedModel)
    }

    func downloadModel(_ speechModel: LocalSpeechModel) {
        guard modelDownloadTasks[speechModel] == nil else { return }

        cancelledModelDownloads.remove(speechModel)
        lastErrorMessage = nil
        setModelPreparationState(.notPrepared, for: speechModel)
        userDefaults.removeObject(forKey: optimizedModelVariantUserDefaultsKey(for: speechModel))
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
        setModelPreparationState(.notPrepared, for: speechModel)
        setModelDownloadState(.notDownloaded, for: speechModel)
    }

    func prepareSelectedModel() {
        prepareModel(selectedModel)
    }

    func cancelSelectedModelPreparation() {
        cancelModelPreparation(selectedModel, reason: .userCancelled)
    }

    func deleteSelectedModel() {
        deleteModel(selectedModel)
    }

    func deleteModel(_ speechModel: LocalSpeechModel) {
        guard operationState == .idle,
              modelPreparationTasks[speechModel] == nil
        else {
            return
        }

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
            self.setModelPreparationState(.notPrepared, for: speechModel)
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

        guard selectedModelPreparationState == .ready,
              loadedSpeechModel == selectedModel,
              let loadedWhisperKit
        else {
            prepareSelectedModel()
            return
        }

        do {
            operationState = .requestingMicrophonePermission
            let microphoneAccessWasGranted = await AudioProcessor.requestRecordPermission()
            refreshMicrophonePermission()
            try Task.checkCancellation()

            guard microphoneAccessWasGranted else {
                operationState = .idle
                lastErrorMessage = "Microphone access is off. Enable it in System Settings to use Sato Local."
                return
            }

            loadedWhisperKit.audioProcessor.purgeAudioSamples(keepingLast: 0)
            try loadedWhisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil, callback: nil)
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

        for modelPreparationTask in modelPreparationTasks.values {
            modelPreparationTask.cancel()
        }
        modelPreparationTasks.removeAll()

        for modelPreparationTimeoutTask in modelPreparationTimeoutTasks.values {
            modelPreparationTimeoutTask.cancel()
        }
        modelPreparationTimeoutTasks.removeAll()
        modelPreparationCancellationReasons.removeAll()

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
            setModelPreparationState(.notPrepared, for: speechModel)

            if selectedModel == speechModel {
                prepareModel(speechModel)
            }
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

    private func prepareModel(_ speechModel: LocalSpeechModel) {
        guard modelDownloadState(for: speechModel) == .downloaded,
              modelPreparationTasks[speechModel] == nil
        else {
            return
        }

        if loadedSpeechModel == speechModel,
           loadedWhisperKit != nil {
            setModelPreparationState(.ready, for: speechModel)
            return
        }

        let previouslyLoadedWhisperKitToUnload: WhisperKit?
        if let loadedSpeechModel,
           loadedSpeechModel != speechModel {
            previouslyLoadedWhisperKitToUnload = loadedWhisperKit
            self.loadedWhisperKit = nil
            self.loadedSpeechModel = nil
            setModelPreparationState(.notPrepared, for: loadedSpeechModel)
        } else {
            previouslyLoadedWhisperKitToUnload = nil
        }

        lastErrorMessage = nil
        let preparationStartedAt = Date()
        setModelPreparationState(
            .preparing(stage: .verifyingModel, startedAt: preparationStartedAt),
            for: speechModel
        )
        print("🎙️ Sato Local: checking \(speechModel.displayName) model files")

        modelPreparationTasks[speechModel] = Task { [weak self] in
            guard let self else { return }
            await self.performModelPreparation(
                speechModel,
                preparationStartedAt: preparationStartedAt,
                previouslyLoadedWhisperKitToUnload: previouslyLoadedWhisperKitToUnload
            )
        }

        modelPreparationTimeoutTasks[speechModel] = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(Self.modelPreparationTimeoutDuration * 1_000_000_000)
                )
            } catch {
                return
            }

            guard let self else { return }
            self.cancelModelPreparation(speechModel, reason: .timedOut)
        }
    }

    private func performModelPreparation(
        _ speechModel: LocalSpeechModel,
        preparationStartedAt: Date,
        previouslyLoadedWhisperKitToUnload: WhisperKit?
    ) async {
        var newlyPreparedWhisperKit: WhisperKit?

        do {
            await previouslyLoadedWhisperKitToUnload?.unloadModels()
            try Task.checkCancellation()

            guard let downloadedModelFolderURL = downloadedModelFolderURL(for: speechModel) else {
                setModelDownloadState(.notDownloaded, for: speechModel)
                throw LocalSpeechTranscriptionError.modelFilesUnavailable
            }

            let whisperKitConfiguration = WhisperKitConfig(
                model: speechModel.whisperKitModelVariant,
                downloadBase: modelDownloadBaseURL(for: speechModel),
                modelRepo: Self.modelRepository,
                modelFolder: downloadedModelFolderURL.path,
                verbose: false,
                prewarm: false,
                load: false,
                download: false,
                useBackgroundDownloadSession: false
            )
            let whisperKit = try await WhisperKit(whisperKitConfiguration)
            newlyPreparedWhisperKit = whisperKit
            try Task.checkCancellation()

            if !modelHasCompletedOptimization(speechModel) {
                setModelPreparationState(
                    .preparing(stage: .optimizingForMac, startedAt: preparationStartedAt),
                    for: speechModel
                )
                print("🎙️ Sato Local: optimizing \(speechModel.displayName) for this Mac")
                try await whisperKit.prewarmModels()
                try Task.checkCancellation()
                userDefaults.set(
                    speechModel.whisperKitModelVariant,
                    forKey: optimizedModelVariantUserDefaultsKey(for: speechModel)
                )
            }

            setModelPreparationState(
                .preparing(stage: .loadingSpeechEngine, startedAt: preparationStartedAt),
                for: speechModel
            )
            print("🎙️ Sato Local: loading the \(speechModel.displayName) voice engine")
            try await whisperKit.loadModels()
            try Task.checkCancellation()

            if let previouslyLoadedWhisperKit = loadedWhisperKit,
               previouslyLoadedWhisperKit !== whisperKit {
                await previouslyLoadedWhisperKit.unloadModels()
            }

            loadedWhisperKit = whisperKit
            loadedSpeechModel = speechModel
            newlyPreparedWhisperKit = nil
            setModelPreparationState(.ready, for: speechModel)
            let preparationDuration = Date().timeIntervalSince(preparationStartedAt)
            print(
                "🎙️ Sato Local: \(speechModel.displayName) ready in "
                    + String(format: "%.1f", preparationDuration)
                    + " seconds"
            )
        } catch {
            await newlyPreparedWhisperKit?.unloadModels()

            let cancellationReason = modelPreparationCancellationReasons.removeValue(
                forKey: speechModel
            )
            if Task.isCancelled || error is CancellationError || cancellationReason != nil {
                switch cancellationReason {
                case .timedOut:
                    setModelPreparationState(
                        .failed(message: "Setup didn’t finish within 10 minutes. Retry now, or restart Sato if it happens again."),
                        for: speechModel
                    )
                    print("⚠️ Sato Local: \(speechModel.displayName) setup timed out")
                case .userCancelled, .none:
                    setModelPreparationState(.notPrepared, for: speechModel)
                    print("🎙️ Sato Local: \(speechModel.displayName) setup cancelled")
                }
            } else {
                setModelPreparationState(
                    .failed(message: "Couldn’t finish setting up \(speechModel.displayName). Retry, or remove and download the model again if it keeps happening."),
                    for: speechModel
                )
                print(
                    "⚠️ Sato Local: \(speechModel.displayName) setup failed: "
                        + error.localizedDescription
                )
            }
        }

        modelPreparationTimeoutTasks.removeValue(forKey: speechModel)?.cancel()
        modelPreparationTasks[speechModel] = nil
    }

    private func cancelModelPreparation(
        _ speechModel: LocalSpeechModel,
        reason: ModelPreparationCancellationReason
    ) {
        guard let modelPreparationTask = modelPreparationTasks[speechModel] else { return }

        let preparationStartedAt = modelPreparationState(for: speechModel).startedAt ?? Date()
        modelPreparationCancellationReasons[speechModel] = reason
        setModelPreparationState(.cancelling(startedAt: preparationStartedAt), for: speechModel)
        modelPreparationTimeoutTasks.removeValue(forKey: speechModel)?.cancel()
        modelPreparationTask.cancel()
    }

    private func modelHasCompletedOptimization(_ speechModel: LocalSpeechModel) -> Bool {
        userDefaults.string(forKey: optimizedModelVariantUserDefaultsKey(for: speechModel))
            == speechModel.whisperKitModelVariant
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

    private func optimizedModelVariantUserDefaultsKey(for speechModel: LocalSpeechModel) -> String {
        Self.optimizedModelVariantUserDefaultsKeyPrefix + speechModel.rawValue
    }

    private func removeDownloadedModelFiles(_ speechModel: LocalSpeechModel) {
        let modelDownloadBaseURL = modelDownloadBaseURL(for: speechModel)
        if fileManager.fileExists(atPath: modelDownloadBaseURL.path) {
            try? fileManager.removeItem(at: modelDownloadBaseURL)
        }
        userDefaults.removeObject(forKey: downloadedModelFolderUserDefaultsKey(for: speechModel))
        userDefaults.removeObject(forKey: optimizedModelVariantUserDefaultsKey(for: speechModel))
    }

    private func setModelDownloadState(
        _ downloadState: LocalSpeechModelDownloadState,
        for speechModel: LocalSpeechModel
    ) {
        var updatedModelDownloadStates = modelDownloadStates
        updatedModelDownloadStates[speechModel] = downloadState
        modelDownloadStates = updatedModelDownloadStates
    }

    private func setModelPreparationState(
        _ preparationState: LocalSpeechModelPreparationState,
        for speechModel: LocalSpeechModel
    ) {
        var updatedModelPreparationStates = modelPreparationStates
        updatedModelPreparationStates[speechModel] = preparationState
        modelPreparationStates = updatedModelPreparationStates
    }
}

private enum ModelPreparationCancellationReason {
    case userCancelled
    case timedOut
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
