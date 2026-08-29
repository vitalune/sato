//
//  PetdexSpriteCatalog.swift
//  leanring-buddy
//
//  Loads the Petdex community catalog, caches the pet selected by the user,
//  and supplies lightweight static preview frames for the picker.
//

import AppKit
import Combine
import Foundation
import ImageIO

struct PetdexPet: Decodable, Identifiable, Equatable {
    struct SubmittedBy: Decodable, Equatable {
        let name: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let submittedByName = try? container.decode(String.self) {
                name = submittedByName
                return
            }

            let submittedByDetails = try container.decode([String: String].self)
            name = submittedByDetails["name"] ?? "Unknown creator"
        }
    }

    struct Metrics: Decodable, Equatable {
        let installCount: Int
        let likeCount: Int

        private enum CodingKeys: String, CodingKey {
            case installCount
            case likeCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installCount = try container.decodeIfPresent(Int.self, forKey: .installCount) ?? 0
            likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        }
    }

    let slug: String
    let displayName: String
    let description: String
    let spritesheetPath: String
    let featured: Bool
    let kind: String
    let vibes: [String]
    let tags: [String]
    let submittedBy: SubmittedBy
    let spriteVersionNumber: Int
    let dexNumber: Int?
    let metrics: Metrics

    private enum CodingKeys: String, CodingKey {
        case slug
        case displayName
        case description
        case spritesheetPath
        case featured
        case kind
        case vibes
        case tags
        case submittedBy
        case spriteVersionNumber
        case dexNumber
        case metrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        slug = try container.decode(String.self, forKey: .slug)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? slug
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        spritesheetPath = try container.decode(String.self, forKey: .spritesheetPath)
        featured = try container.decodeIfPresent(Bool.self, forKey: .featured) ?? false
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "pet"
        vibes = try container.decodeIfPresent([String].self, forKey: .vibes) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        submittedBy = try container.decodeIfPresent(SubmittedBy.self, forKey: .submittedBy)
            ?? SubmittedBy(name: "Unknown creator")
        spriteVersionNumber = try container.decodeIfPresent(Int.self, forKey: .spriteVersionNumber) ?? 1
        dexNumber = try container.decodeIfPresent(Int.self, forKey: .dexNumber)
        metrics = try container.decodeIfPresent(Metrics.self, forKey: .metrics)
            ?? Metrics(installCount: 0, likeCount: 0)
    }

    var id: String { slug }

    var spritesheetURL: URL? {
        URL(string: spritesheetPath)
    }

    var previewURL: URL? {
        URL(string: "https://assets.petdex.dev/pets/\(slug)/preview.webp")
    }

    var petdexPageURL: URL? {
        URL(string: "https://petdex.dev/pets/\(slug)")
    }
}

private extension PetdexPet.SubmittedBy {
    init(name: String) {
        self.name = name
    }
}

private extension PetdexPet.Metrics {
    init(installCount: Int, likeCount: Int) {
        self.installCount = installCount
        self.likeCount = likeCount
    }
}

struct PetdexCatalogFacets: Decodable, Equatable {
    let kinds: [String: Int]
    let vibes: [String: Int]
}

struct PetdexSearchResponse: Decodable, Equatable {
    let pets: [PetdexPet]
    let nextCursor: Int?
    let total: Int?
    let facets: PetdexCatalogFacets?
}

struct PetdexCatalogQuery: Equatable {
    var searchText: String = ""
    var kind: String?
    var vibe: String?
    var sort: PetdexCatalogSort = .mostInstalled
}

enum PetdexCatalogSort: String, CaseIterable, Identifiable {
    case mostInstalled = "installed"
    case recentlyAdded = "recent"
    case alphabetical = "alpha"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mostInstalled:
            return "Most installed"
        case .recentlyAdded:
            return "Recently added"
        case .alphabetical:
            return "A to Z"
        }
    }
}

struct CachedPetdexSprite: Codable, Equatable {
    let slug: String
    let displayName: String
    let creatorName: String
    let sourceURL: URL
    let installedAt: Date
}

struct PetdexSpriteAtlasLayout: Equatable {
    nonisolated static let columnCount = 8
    nonisolated static let supportedRowCounts = [11, 9]
    nonisolated static let canonicalFrameWidth = 192
    nonisolated static let canonicalFrameHeight = 208

    let imageWidth: Int
    let imageHeight: Int
    let rowCount: Int
    let frameWidth: Int
    let frameHeight: Int

    nonisolated static func validatedLayout(
        for image: CGImage
    ) throws -> PetdexSpriteAtlasLayout {
        try validatedLayout(imageWidth: image.width, imageHeight: image.height)
    }

    nonisolated static func validatedLayout(
        imageWidth: Int,
        imageHeight: Int
    ) throws -> PetdexSpriteAtlasLayout {
        guard imageWidth >= 256,
              imageHeight >= 256,
              imageWidth <= 4_096,
              imageHeight <= 6_144,
              imageWidth % columnCount == 0 else {
            throw PetdexCatalogError.invalidSpritesheet
        }

        let frameWidth = imageWidth / columnCount
        for rowCount in supportedRowCounts
        where imageHeight % rowCount == 0 {
            let frameHeight = imageHeight / rowCount
            guard frameWidth * canonicalFrameHeight
                    == frameHeight * canonicalFrameWidth else {
                continue
            }
            return PetdexSpriteAtlasLayout(
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                rowCount: rowCount,
                frameWidth: frameWidth,
                frameHeight: frameHeight
            )
        }

        throw PetdexCatalogError.invalidSpritesheet
    }

    nonisolated func frameRectangle(
        rowIndex: Int,
        columnIndex: Int
    ) throws -> CGRect {
        guard (0..<rowCount).contains(rowIndex),
              (0..<Self.columnCount).contains(columnIndex) else {
            throw PetdexCatalogError.invalidSpritesheet
        }

        // Petdex numbers rows from the first (top) pixel row in the decoded
        // CGImage. CGImage cropping uses that same untransformed pixel space.
        return CGRect(
            x: columnIndex * frameWidth,
            y: rowIndex * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
    }
}

enum PetdexCatalogError: LocalizedError {
    case invalidResponse
    case invalidAssetHost
    case invalidPetIdentifier
    case spritesheetTooLarge
    case invalidSpritesheet
    case missingCachedSprite

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Petdex returned an unexpected response."
        case .invalidAssetHost:
            return "This pet uses an untrusted asset location."
        case .invalidPetIdentifier:
            return "This pet has an invalid identifier."
        case .spritesheetTooLarge:
            return "This pet's spritesheet is too large."
        case .invalidSpritesheet:
            return "This pet's spritesheet is not a supported Petdex format."
        case .missingCachedSprite:
            return "The saved custom sprite is no longer available on this Mac."
        }
    }
}

struct PetdexAssetDownloadPolicy {
    nonisolated static func expectedContentLengthExceedsLimit(
        _ expectedContentLength: Int64,
        maximumByteCount: Int
    ) -> Bool {
        expectedContentLength != NSURLSessionTransferSizeUnknown
            && expectedContentLength > Int64(maximumByteCount)
    }

    nonisolated static func receivedByteCount(
        afterAdding incomingByteCount: Int,
        to currentByteCount: Int,
        maximumByteCount: Int
    ) -> Int? {
        guard currentByteCount >= 0,
              incomingByteCount >= 0,
              currentByteCount <= maximumByteCount,
              incomingByteCount <= maximumByteCount - currentByteCount else {
            return nil
        }
        return currentByteCount + incomingByteCount
    }
}

/// Streams a Petdex asset into a uniquely named temporary file. A data-task
/// delegate is used instead of URLSession's convenience APIs so an incorrect
/// or malicious response is cancelled as soon as it crosses the byte limit.
private final class PetdexBoundedAssetDownloader: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {

    private let request: URLRequest
    private let sessionConfiguration: URLSessionConfiguration
    private let maximumByteCount: Int
    private let oversizedResponseError: Error
    private let fileManager: FileManager
    private let delegateQueue: OperationQueue
    private let stateLock = NSLock()

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var terminalError: Error?
    private var isFinished = false
    private var cancellationWasRequested = false

    // These properties are accessed only by the serial delegate queue.
    private var temporaryFileURL: URL?
    private var temporaryFileHandle: FileHandle?
    private var receivedByteCount = 0

    init(
        request: URLRequest,
        sessionConfiguration: URLSessionConfiguration,
        maximumByteCount: Int,
        oversizedResponseError: Error,
        fileManager: FileManager = .default
    ) {
        self.request = request
        self.sessionConfiguration = sessionConfiguration
        self.maximumByteCount = maximumByteCount
        self.oversizedResponseError = oversizedResponseError
        self.fileManager = fileManager

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.sato.petdex-bounded-download"
        delegateQueue.maxConcurrentOperationCount = 1
        self.delegateQueue = delegateQueue
    }

    func download() async throws -> URL {
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = URLSession(
                    configuration: sessionConfiguration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                let dataTask = session.dataTask(with: request)

                stateLock.lock()
                self.session = session
                self.dataTask = dataTask
                self.continuation = continuation
                let shouldCancelImmediately = cancellationWasRequested
                stateLock.unlock()

                dataTask.resume()
                if shouldCancelImmediately {
                    dataTask.cancel()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private func cancel() {
        stateLock.lock()
        cancellationWasRequested = true
        if terminalError == nil {
            terminalError = CancellationError()
        }
        let dataTask = dataTask
        stateLock.unlock()
        dataTask?.cancel()
    }

    private func recordTerminalErrorIfNeeded(_ error: Error) {
        stateLock.lock()
        if terminalError == nil {
            terminalError = error
        }
        stateLock.unlock()
    }

    private func currentTerminalError() -> Error? {
        stateLock.lock()
        let terminalError = terminalError
        stateLock.unlock()
        return terminalError
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url,
              PetdexSpriteCatalog.isTrustedAssetURL(redirectURL) else {
            recordTerminalErrorIfNeeded(PetdexCatalogError.invalidAssetHost)
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let finalResponseURL = httpResponse.url,
              PetdexSpriteCatalog.isTrustedAssetURL(finalResponseURL) else {
            recordTerminalErrorIfNeeded(PetdexCatalogError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard !PetdexAssetDownloadPolicy.expectedContentLengthExceedsLimit(
            response.expectedContentLength,
            maximumByteCount: maximumByteCount
        ) else {
            recordTerminalErrorIfNeeded(oversizedResponseError)
            completionHandler(.cancel)
            return
        }

        do {
            let temporaryFileURL = fileManager.temporaryDirectory
                .appendingPathComponent("Sato-Petdex-\(UUID().uuidString).asset")
            guard fileManager.createFile(
                atPath: temporaryFileURL.path,
                contents: nil
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            self.temporaryFileURL = temporaryFileURL
            temporaryFileHandle = try FileHandle(forWritingTo: temporaryFileURL)
            completionHandler(.allow)
        } catch {
            recordTerminalErrorIfNeeded(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let temporaryFileHandle else {
            recordTerminalErrorIfNeeded(PetdexCatalogError.invalidResponse)
            dataTask.cancel()
            return
        }
        guard let nextReceivedByteCount = PetdexAssetDownloadPolicy.receivedByteCount(
            afterAdding: data.count,
            to: receivedByteCount,
            maximumByteCount: maximumByteCount
        ) else {
            recordTerminalErrorIfNeeded(oversizedResponseError)
            dataTask.cancel()
            return
        }

        do {
            try temporaryFileHandle.write(contentsOf: data)
            receivedByteCount = nextReceivedByteCount
        } catch {
            recordTerminalErrorIfNeeded(error)
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        do {
            try temporaryFileHandle?.close()
        } catch {
            recordTerminalErrorIfNeeded(error)
        }
        temporaryFileHandle = nil

        let result: Result<URL, Error>
        if let terminalError = currentTerminalError() {
            result = .failure(terminalError)
        } else if let error {
            result = .failure(error)
        } else if let temporaryFileURL {
            result = .success(temporaryFileURL)
        } else {
            result = .failure(PetdexCatalogError.invalidResponse)
        }

        stateLock.lock()
        guard !isFinished else {
            stateLock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        self.dataTask = nil
        self.session = nil
        stateLock.unlock()

        if case .failure = result, let temporaryFileURL {
            try? fileManager.removeItem(at: temporaryFileURL)
        }
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}

@MainActor
final class PetdexSpriteCatalog: ObservableObject {
    @Published private(set) var pets: [PetdexPet] = []
    @Published private(set) var totalPetCount: Int = 0
    @Published private(set) var availableKinds: [String] = []
    @Published private(set) var availableVibes: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var installingPetSlug: String?
    @Published private(set) var catalogErrorMessage: String?
    @Published private(set) var installationErrorMessage: String?

    private static let catalogURL = URL(string: "https://petdex.dev/api/pets/search")!
    private static let maximumCatalogPageSize = 36
    nonisolated private static let maximumSpritesheetByteCount = 8 * 1_024 * 1_024
    private static let cachedSpritesDirectoryName = "CustomSprites"
    private static let cachedSpritesheetFileName = "spritesheet.asset"
    private static let cachedMetadataFileName = "pet.json"
    private static let catalogRefreshInterval: TimeInterval = 5 * 60

    private let fileManager: FileManager
    private let urlSession: URLSession
    private let cachedSpritesDirectoryURL: URL
    private var activeCatalogTask: Task<Void, Never>?
    private var currentQuery = PetdexCatalogQuery()
    private var nextCursor: Int?
    private var lastCatalogRefreshDate: Date?

    init(
        fileManager: FileManager = .default,
        urlSession: URLSession = .shared,
        applicationSupportDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.urlSession = urlSession

        let resolvedApplicationSupportDirectoryURL = applicationSupportDirectoryURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        cachedSpritesDirectoryURL = resolvedApplicationSupportDirectoryURL
            .appendingPathComponent("Sato", isDirectory: true)
            .appendingPathComponent(Self.cachedSpritesDirectoryName, isDirectory: true)
    }

    deinit {
        activeCatalogTask?.cancel()
    }

    func loadInitialCatalogIfNeeded() {
        refreshCurrentCatalogIfStale()
    }

    func prepareForPickerPresentation() {
        guard !isLoading else { return }

        let initialQuery = PetdexCatalogQuery()
        if currentQuery != initialQuery {
            refresh(query: initialQuery)
        } else {
            refreshCurrentCatalogIfStale()
        }
    }

    func refreshCurrentCatalogIfStale() {
        guard !isLoading else { return }

        let shouldRefreshForAge = lastCatalogRefreshDate.map {
            Date().timeIntervalSince($0) >= Self.catalogRefreshInterval
        } ?? true
        guard pets.isEmpty || shouldRefreshForAge else {
            return
        }
        refresh(query: currentQuery)
    }

    func cancelCatalogLoading() {
        activeCatalogTask?.cancel()
        activeCatalogTask = nil
        isLoading = false
        isLoadingMore = false
    }

    func refresh(query: PetdexCatalogQuery) {
        activeCatalogTask?.cancel()
        let isRefreshingSameQuery = currentQuery == query
        let shouldRetainExistingPetsOnFailure = isRefreshingSameQuery && !pets.isEmpty
        let previousNextCursor = nextCursor
        if !isRefreshingSameQuery {
            pets = []
            totalPetCount = 0
        }
        currentQuery = query
        nextCursor = nil
        isLoading = true
        isLoadingMore = false
        catalogErrorMessage = nil

        activeCatalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.fetchCatalogPage(query: query, cursor: 0)
                guard !Task.isCancelled, self.currentQuery == query else { return }

                self.pets = response.pets
                self.nextCursor = response.nextCursor
                self.totalPetCount = response.total ?? response.pets.count
                self.updateAvailableFilters(from: response.facets)
                self.lastCatalogRefreshDate = Date()
                self.isLoading = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.currentQuery == query else { return }
                if !shouldRetainExistingPetsOnFailure {
                    self.pets = []
                    self.nextCursor = nil
                } else {
                    self.nextCursor = previousNextCursor
                }
                self.isLoading = false
                self.catalogErrorMessage = error.localizedDescription
            }
        }
    }

    func loadMorePets() {
        guard let nextCursor,
              !isLoading,
              !isLoadingMore else {
            return
        }

        let query = currentQuery
        isLoadingMore = true
        catalogErrorMessage = nil

        activeCatalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.fetchCatalogPage(query: query, cursor: nextCursor)
                guard !Task.isCancelled, self.currentQuery == query else { return }

                let existingPetIdentifiers = Set(self.pets.map(\.id))
                self.pets.append(contentsOf: response.pets.filter {
                    !existingPetIdentifiers.contains($0.id)
                })
                self.nextCursor = response.nextCursor
                self.isLoadingMore = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.currentQuery == query else { return }
                self.isLoadingMore = false
                self.catalogErrorMessage = error.localizedDescription
            }
        }
    }

    func install(_ pet: PetdexPet) async throws -> (metadata: CachedPetdexSprite, spritesheetURL: URL) {
        guard installingPetSlug == nil else {
            throw CancellationError()
        }
        guard Self.isSafePetSlug(pet.slug) else {
            throw PetdexCatalogError.invalidPetIdentifier
        }
        guard let remoteSpritesheetURL = pet.spritesheetURL,
              Self.isTrustedAssetURL(remoteSpritesheetURL) else {
            throw PetdexCatalogError.invalidAssetHost
        }

        installingPetSlug = pet.slug
        installationErrorMessage = nil

        do {
            let request = URLRequest(url: remoteSpritesheetURL)
            let temporarySpritesheetURL = try await PetdexBoundedAssetDownloader(
                request: request,
                sessionConfiguration: urlSession.configuration,
                maximumByteCount: Self.maximumSpritesheetByteCount,
                oversizedResponseError: PetdexCatalogError.spritesheetTooLarge,
                fileManager: fileManager
            ).download()
            defer {
                try? fileManager.removeItem(at: temporarySpritesheetURL)
            }
            let spritesheetData = try await Self.readAndValidateDownloadedSpritesheet(
                at: temporarySpritesheetURL
            )
            try Task.checkCancellation()

            let petDirectoryURL = cachedDirectoryURL(forPetSlug: pet.slug)
            try fileManager.createDirectory(
                at: petDirectoryURL,
                withIntermediateDirectories: true
            )

            let cachedSpritesheetURL = petDirectoryURL
                .appendingPathComponent(Self.cachedSpritesheetFileName)
            try spritesheetData.write(to: cachedSpritesheetURL, options: .atomic)

            let metadata = CachedPetdexSprite(
                slug: pet.slug,
                displayName: pet.displayName,
                creatorName: pet.submittedBy.name,
                sourceURL: pet.petdexPageURL ?? URL(string: "https://petdex.dev")!,
                installedAt: Date()
            )
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(
                to: petDirectoryURL.appendingPathComponent(Self.cachedMetadataFileName),
                options: .atomic
            )

            installingPetSlug = nil
            return (metadata, cachedSpritesheetURL)
        } catch {
            installingPetSlug = nil
            installationErrorMessage = error.localizedDescription
            throw error
        }
    }

    func cachedSprite(petSlug: String) throws -> (metadata: CachedPetdexSprite, spritesheetURL: URL) {
        guard Self.isSafePetSlug(petSlug) else {
            throw PetdexCatalogError.invalidPetIdentifier
        }

        let petDirectoryURL = cachedDirectoryURL(forPetSlug: petSlug)
        let spritesheetURL = petDirectoryURL.appendingPathComponent(Self.cachedSpritesheetFileName)
        let metadataURL = petDirectoryURL.appendingPathComponent(Self.cachedMetadataFileName)
        guard fileManager.fileExists(atPath: spritesheetURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            throw PetdexCatalogError.missingCachedSprite
        }

        let metadataData = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(CachedPetdexSprite.self, from: metadataData)
        return (metadata, spritesheetURL)
    }

    /// Sato only needs the active custom sprite offline. Bounding this cache
    /// prevents repeated experimentation in the picker from consuming storage.
    func removeCachedSprites(exceptPetSlug retainedPetSlug: String) {
        guard Self.isSafePetSlug(retainedPetSlug),
              let cachedSpriteDirectories = try? fileManager.contentsOfDirectory(
                  at: cachedSpritesDirectoryURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for cachedSpriteDirectory in cachedSpriteDirectories
        where cachedSpriteDirectory.lastPathComponent != retainedPetSlug {
            do {
                try fileManager.removeItem(at: cachedSpriteDirectory)
            } catch {
                print(
                    "⚠️ Sprite: Could not remove old custom sprite cache "
                        + "\(cachedSpriteDirectory.lastPathComponent): \(error)"
                )
            }
        }
    }

    func clearInstallationError() {
        installationErrorMessage = nil
    }

    func recordInstallationError(_ message: String) {
        installationErrorMessage = message
    }

    nonisolated static func isTrustedAssetURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == "assets.petdex.dev"
            && url.port == nil
            && url.user == nil
            && url.password == nil
    }

    nonisolated static func validatedSpritesheetImage(
        from data: Data
    ) throws -> (image: CGImage, layout: PetdexSpriteAtlasLayout) {
        guard data.count <= maximumSpritesheetByteCount,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) == 1,
              let imageProperties = CGImageSourceCopyPropertiesAtIndex(
                  imageSource,
                  0,
                  nil
              ) as? [CFString: Any],
              let imageWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let imageHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int else {
            throw PetdexCatalogError.invalidSpritesheet
        }

        let layout = try PetdexSpriteAtlasLayout.validatedLayout(
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PetdexCatalogError.invalidSpritesheet
        }
        return (image, layout)
    }

    /// ImageIO may need to inflate the entire WebP atlas to validate it. Keep
    /// that read and decode away from the main actor while returning only the
    /// bounded, Sendable bytes needed by the cache writer.
    nonisolated private static func readAndValidateDownloadedSpritesheet(
        at temporarySpritesheetURL: URL
    ) async throws -> Data {
        try Task.checkCancellation()

        let readAndValidationTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let spritesheetData = try Data(contentsOf: temporarySpritesheetURL)
            guard spritesheetData.count <= maximumSpritesheetByteCount else {
                throw PetdexCatalogError.spritesheetTooLarge
            }

            _ = try validatedSpritesheetImage(from: spritesheetData)
            try Task.checkCancellation()
            return spritesheetData
        }

        return try await withTaskCancellationHandler {
            try await readAndValidationTask.value
        } onCancel: {
            readAndValidationTask.cancel()
        }
    }

    private func fetchCatalogPage(
        query: PetdexCatalogQuery,
        cursor: Int
    ) async throws -> PetdexSearchResponse {
        var urlComponents = URLComponents(
            url: Self.catalogURL,
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "sort", value: query.sort.rawValue),
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: String(Self.maximumCatalogPageSize)),
            URLQueryItem(name: "includeMeta", value: cursor == 0 ? "1" : "0"),
        ]

        let trimmedSearchText = query.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSearchText.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: trimmedSearchText))
        }
        if let kind = query.kind {
            queryItems.append(URLQueryItem(name: "kinds", value: kind))
        }
        if let vibe = query.vibe {
            queryItems.append(URLQueryItem(name: "vibes", value: vibe))
        }
        urlComponents.queryItems = queryItems

        guard let requestURL = urlComponents.url else {
            throw PetdexCatalogError.invalidResponse
        }

        var request = URLRequest(url: requestURL)
        request.timeoutInterval = 20
        request.cachePolicy = .useProtocolCachePolicy
        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PetdexCatalogError.invalidResponse
        }

        return try JSONDecoder().decode(PetdexSearchResponse.self, from: responseData)
    }

    private func updateAvailableFilters(from facets: PetdexCatalogFacets?) {
        guard let facets else { return }
        availableKinds = facets.kinds
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .map(\.key)
        availableVibes = facets.vibes
            .sorted { left, right in
                left.value == right.value ? left.key < right.key : left.value > right.value
            }
            .map(\.key)
    }

    private func cachedDirectoryURL(forPetSlug petSlug: String) -> URL {
        cachedSpritesDirectoryURL.appendingPathComponent(petSlug, isDirectory: true)
    }

    private static func isSafePetSlug(_ petSlug: String) -> Bool {
        guard !petSlug.isEmpty,
              petSlug.count <= 100,
              let firstCharacter = petSlug.first,
              firstCharacter != "-" else {
            return false
        }

        let allowedSlugCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-"
        )
        return petSlug.unicodeScalars.allSatisfy(allowedSlugCharacters.contains)
    }
}

@MainActor
final class PetdexPreviewImageLoader: ObservableObject {
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var didFail = false

    private static let imageCache: NSCache<NSString, NSImage> = {
        let imageCache = NSCache<NSString, NSImage>()
        imageCache.countLimit = 180
        imageCache.totalCostLimit = 32 * 1_024 * 1_024
        return imageCache
    }()
    private static let maximumPreviewByteCount = 1 * 1_024 * 1_024
    private var loadingTask: Task<Void, Never>?

    func loadPreview(for pet: PetdexPet) {
        guard previewImage == nil, loadingTask == nil else { return }

        let previewCacheKey = "\(pet.slug)|\(pet.spritesheetPath)" as NSString
        if let cachedImage = Self.imageCache.object(forKey: previewCacheKey) {
            previewImage = cachedImage
            return
        }

        loadingTask = Task { [weak self] in
            guard let self else { return }
            let loadedImage = await self.loadPreviewImage(for: pet)
            guard !Task.isCancelled else { return }

            if let loadedImage {
                let approximatePixelCost = PetdexSpriteAtlasLayout.canonicalFrameWidth
                    * PetdexSpriteAtlasLayout.canonicalFrameHeight
                    * 4
                Self.imageCache.setObject(
                    loadedImage,
                    forKey: previewCacheKey,
                    cost: approximatePixelCost
                )
                self.previewImage = loadedImage
            } else {
                self.didFail = true
            }
            self.loadingTask = nil
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
    }

    private func loadPreviewImage(for pet: PetdexPet) async -> NSImage? {
        guard let previewURL = pet.previewURL,
              PetdexSpriteCatalog.isTrustedAssetURL(previewURL) else {
            return nil
        }
        return await downloadPreviewFrame(from: previewURL)
    }

    private func downloadPreviewFrame(from url: URL) async -> NSImage? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .useProtocolCachePolicy
            let temporaryPreviewURL = try await PetdexBoundedAssetDownloader(
                request: request,
                sessionConfiguration: URLSession.shared.configuration,
                maximumByteCount: Self.maximumPreviewByteCount,
                oversizedResponseError: PetdexCatalogError.spritesheetTooLarge
            ).download()
            defer {
                try? FileManager.default.removeItem(at: temporaryPreviewURL)
            }
            guard !Task.isCancelled,
                  let imageData = try? Data(contentsOf: temporaryPreviewURL),
                  imageData.count <= Self.maximumPreviewByteCount,
                  let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
                  CGImageSourceGetCount(imageSource) == 1,
                  let imageProperties = CGImageSourceCopyPropertiesAtIndex(
                      imageSource,
                      0,
                      nil
                  ) as? [CFString: Any],
                  let imageWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
                  let imageHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
                  imageWidth == 6 * PetdexSpriteAtlasLayout.canonicalFrameWidth,
                  imageHeight == PetdexSpriteAtlasLayout.canonicalFrameHeight,
                  let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return nil
            }

            let frameWidth = PetdexSpriteAtlasLayout.canonicalFrameWidth
            let frameHeight = PetdexSpriteAtlasLayout.canonicalFrameHeight
            let firstFrameRectangle = CGRect(
                x: 0,
                y: 0,
                width: frameWidth,
                height: frameHeight
            )
            guard let croppedFrame = sourceImage.cropping(
                to: firstFrameRectangle
            ) else {
                return nil
            }

            // Cropped CGImages can retain the entire six-frame strip. Redraw
            // the one frame so the preview cache owns only the pixels it uses.
            guard let frameContext = CGContext(
                data: nil,
                width: frameWidth,
                height: frameHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            frameContext.interpolationQuality = .none
            frameContext.draw(
                croppedFrame,
                in: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
            )
            guard let copiedFrame = frameContext.makeImage() else { return nil }
            return NSImage(
                cgImage: copiedFrame,
                size: NSSize(width: frameWidth, height: frameHeight)
            )
        } catch {
            return nil
        }
    }
}
