import AVFoundation
import Combine
import CryptoKit
import Foundation
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

enum MobileCrossfadePolicy {
    static let defaultSeconds: TimeInterval = 5
    static let minimumSeconds: TimeInterval = 1
    static let maximumSeconds: TimeInterval = 12

    static func normalizedSeconds(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return defaultSeconds }
        return min(max(value, minimumSeconds), maximumSeconds)
    }

    static func effectiveDuration(
        requestedSeconds: TimeInterval,
        currentDuration: TimeInterval,
        nextDuration: TimeInterval
    ) -> TimeInterval {
        guard currentDuration > 0, nextDuration > 0 else { return 0 }
        return min(
            normalizedSeconds(requestedSeconds),
            min(currentDuration / 2, nextDuration / 2)
        )
    }

    static func progress(remaining: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - remaining / duration, 0), 1)
    }
}

enum MobileRemoteMetadataRetryPolicy {
    static let maximumImmediateAttempts = 4

    static func delaySeconds(afterFailureCount count: Int) -> Int {
        switch max(count, 1) {
        case 1: 1
        case 2: 3
        default: 10
        }
    }
}

actor MobileAsyncSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }
}

struct MobileBoundedDownloadResult: Sendable {
    let temporaryURL: URL
    let byteCount: Int64
    let sha256: String
}

struct MobileTransferByteProgress: Equatable, Sendable {
    let completed: Int64
    let total: Int64
}

typealias MobileTransferByteProgressHandler = @Sendable (MobileTransferByteProgress) -> Void

private enum MobileBoundedDownloadError: LocalizedError {
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Server returned HTTP \(status)."
        }
    }
}

private actor MobileRemoteMetadataResolutionBroker {
    private struct Key: Hashable, Sendable {
        let scope: UInt64
        let cacheKey: String
    }

    private struct Entry {
        let id: UUID
        let task: Task<LocalImportSpotifyTrack?, Never>
        var waiters: [UUID: CheckedContinuation<LocalImportSpotifyTrack?, Error>]
    }

    private var entries: [Key: Entry] = [:]

    func resolve(
        scope: UInt64,
        cacheKey: String,
        source: String,
        using service: LocalDeviceImportService
    ) async throws -> LocalImportSpotifyTrack? {
        try Task.checkCancellation()
        let key = Key(scope: scope, cacheKey: cacheKey)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var entry = entries[key] {
                    entry.waiters[waiterID] = continuation
                    entries[key] = entry
                    return
                }
                let entryID = UUID()
                let task = Task<LocalImportSpotifyTrack?, Never> {
                    do {
                        try Task.checkCancellation()
                        let metadata = try await service.resolveMetadata(source: source)
                        try Task.checkCancellation()
                        return metadata
                    } catch {
                        return nil
                    }
                }
                entries[key] = Entry(
                    id: entryID,
                    task: task,
                    waiters: [waiterID: continuation]
                )
                Task.detached { [weak self] in
                    let result = await task.value
                    await self?.complete(result, key: key, entryID: entryID)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, key: key) }
        }
    }

    private func complete(
        _ result: LocalImportSpotifyTrack?,
        key: Key,
        entryID: UUID
    ) {
        guard entries[key]?.id == entryID,
              let entry = entries.removeValue(forKey: key) else { return }
        for continuation in entry.waiters.values {
            continuation.resume(returning: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID, key: Key) {
        guard var entry = entries[key],
              let continuation = entry.waiters.removeValue(forKey: waiterID) else { return }
        if entry.waiters.isEmpty {
            entries.removeValue(forKey: key)
            entry.task.cancel()
        } else {
            entries[key] = entry
        }
        continuation.resume(throwing: CancellationError())
    }

    func cancel(scope: UInt64) {
        let keys = entries.keys.filter { $0.scope == scope }
        for key in keys {
            guard let entry = entries.removeValue(forKey: key) else { continue }
            entry.task.cancel()
            for continuation in entry.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}

enum MobileTransferPolicyChangedError: LocalizedError {
    case changed

    var errorDescription: String? {
        "The signed transfer policy expired or changed."
    }
}

struct MobileReviewedMatchLease: Equatable, Sendable {
    let transferPolicy: MobileTransferPolicyLease
    let origin: String
    let profileID: String
    let adminTokenFingerprint: String
    let requestContext: MobileClientRequestContext
}

struct MobileRawUploadLease: Equatable, Sendable {
    let transferPolicy: MobileTransferPolicyLease
    let mode: MobileUploadMode
    let origin: String
    let profileID: String
    let adminTokenFingerprint: String
    let requestContext: MobileClientRequestContext
}

final class MobileBoundedDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumSize: Int64
    private let fileManager: FileManager
    let temporaryURL: URL
    private let authorization: MobileTransferAuthorization
    private let progress: MobileTransferByteProgressHandler
    private let sessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var hasher = SHA256()
    private var byteCount: Int64 = 0
    private var expectedByteCount: Int64 = 0
    private var lastReportedByteCount: Int64 = 0
    private var receivedResponse = false
    private var continuation: CheckedContinuation<MobileBoundedDownloadResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isFinished = false
    private var allowedOrigin: URL?
    private var authorizationRegistration: UUID?

    init(
        maximumSize: Int64,
        authorization: MobileTransferAuthorization,
        fileManager: FileManager = .default,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        progress: @escaping MobileTransferByteProgressHandler = { _ in }
    ) throws {
        self.maximumSize = maximumSize
        self.authorization = authorization
        self.progress = progress
        self.fileManager = fileManager
        self.sessionConfiguration = sessionConfiguration
        temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent("\(MobileTransientDownloadPolicy.filenamePrefix)\(UUID().uuidString)")
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.qualityOfService = .utility
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            fileHandle = try FileHandle(forWritingTo: temporaryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
        super.init()
    }

    func run(request: URLRequest) async throws -> MobileBoundedDownloadResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = sessionConfiguration
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.urlCache = nil
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: delegateQueue
                )
                let task = session.dataTask(with: request)

                lock.lock()
                let alreadyFinished = isFinished
                if !alreadyFinished {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    self.allowedOrigin = request.url
                }
                lock.unlock()

                if alreadyFinished {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard let registration = authorization.register({ [weak self] in
                    self?.cancelBecauseUnauthorized()
                }) else {
                    complete(with: .failure(MobileTransferPolicyChangedError.changed))
                    return
                }
                lock.lock()
                let finishedBeforeRegistration = isFinished
                if !finishedBeforeRegistration {
                    authorizationRegistration = registration
                }
                lock.unlock()
                if finishedBeforeRegistration {
                    authorization.unregister(registration)
                } else if Task.isCancelled {
                    cancel()
                } else if !authorization.isAuthorized() {
                    cancelBecauseUnauthorized()
                } else {
                    lock.lock()
                    let shouldResume = !isFinished
                    lock.unlock()
                    guard shouldResume else { return }
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard authorization.isAuthorized() else {
            completionHandler(nil)
            cancelBecauseUnauthorized()
            return
        }
        completionHandler(MobileSameOriginPolicy.matches(request.url, allowedOrigin) ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard authorization.isAuthorized() else {
            completionHandler(.cancel)
            cancelBecauseUnauthorized()
            return
        }
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(with: .failure(URLError(.badServerResponse)))
            return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            complete(with: .failure(MobileBoundedDownloadError.unexpectedStatus(response.statusCode)))
            return
        }
        if let oversized = MobileDownloadByteLimitPolicy.oversizedByteCount(
            totalBytesWritten: 0,
            totalBytesExpected: response.expectedContentLength,
            maximumSize: maximumSize
        ) {
            completionHandler(.cancel)
            complete(with: .failure(MobileDownloadIntegrityError.tooLarge(
                actual: oversized,
                limit: maximumSize
            )))
            return
        }

        lock.lock()
        guard MobileBoundedDownloadCallbackPolicy.acceptsResponse(isFinished: isFinished) else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        receivedResponse = true
        expectedByteCount = max(response.expectedContentLength, 0)
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard authorization.isAuthorized() else {
            dataTask.cancel()
            cancelBecauseUnauthorized()
            return
        }
        lock.lock()
        guard !isFinished, let fileHandle else {
            lock.unlock()
            return
        }

        let addition = byteCount.addingReportingOverflow(Int64(data.count))
        let nextByteCount = addition.overflow ? Int64.max : addition.partialValue
        if addition.overflow || nextByteCount > maximumSize {
            lock.unlock()
            dataTask.cancel()
            complete(with: .failure(MobileDownloadIntegrityError.tooLarge(
                actual: nextByteCount,
                limit: maximumSize
            )))
            return
        }

        do {
            try fileHandle.write(contentsOf: data)
            hasher.update(data: data)
            byteCount = nextByteCount
            let expectedByteCount = self.expectedByteCount
            let shouldReportProgress = MobileTransferByteProgressPolicy.shouldReport(
                completedBytes: nextByteCount,
                lastReportedBytes: lastReportedByteCount,
                totalBytes: expectedByteCount
            )
            if shouldReportProgress {
                lastReportedByteCount = nextByteCount
            }
            lock.unlock()
            if shouldReportProgress {
                progress(MobileTransferByteProgress(
                    completed: nextByteCount,
                    total: expectedByteCount
                ))
            }
        } catch {
            lock.unlock()
            dataTask.cancel()
            complete(with: .failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard authorization.isAuthorized() else {
            cancelBecauseUnauthorized()
            return
        }
        if let error {
            complete(with: .failure(error))
            return
        }

        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        guard receivedResponse, let fileHandle else {
            lock.unlock()
            complete(with: .failure(URLError(.badServerResponse)))
            return
        }

        do {
            try fileHandle.close()
            self.fileHandle = nil
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let result = MobileBoundedDownloadResult(
                temporaryURL: temporaryURL,
                byteCount: byteCount,
                sha256: digest
            )
            isFinished = true
            let continuation = self.continuation
            self.continuation = nil
            let session = self.session
            self.session = nil
            self.task = nil
            let authorizationRegistration = self.authorizationRegistration
            self.authorizationRegistration = nil
            let shouldReportProgress = byteCount != lastReportedByteCount
            if shouldReportProgress {
                lastReportedByteCount = byteCount
            }
            let finalByteCount = byteCount
            let expectedByteCount = self.expectedByteCount
            lock.unlock()
            if let authorizationRegistration {
                authorization.unregister(authorizationRegistration)
            }
            if shouldReportProgress {
                progress(MobileTransferByteProgress(
                    completed: finalByteCount,
                    total: expectedByteCount
                ))
            }
            session?.finishTasksAndInvalidate()
            continuation?.resume(returning: result)
        } catch {
            lock.unlock()
            complete(with: .failure(error))
        }
    }

    private func cancel() {
        complete(with: .failure(CancellationError()))
    }

    private func cancelBecauseUnauthorized() {
        complete(with: .failure(MobileTransferPolicyChangedError.changed))
    }

    private func complete(with result: Result<MobileBoundedDownloadResult, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let fileHandle = self.fileHandle
        self.fileHandle = nil
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        let task = self.task
        self.task = nil
        let authorizationRegistration = self.authorizationRegistration
        self.authorizationRegistration = nil
        lock.unlock()

        if let authorizationRegistration {
            authorization.unregister(authorizationRegistration)
        }
        task?.cancel()
        session?.invalidateAndCancel()
        try? fileHandle?.close()
        if case .failure = result {
            try? fileManager.removeItem(at: temporaryURL)
        }
        continuation?.resume(with: result)
    }
}

@MainActor
final class MusicLibrary: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    private struct PlaylistServerError: LocalizedError {
        let status: Int
        let message: String?

        var errorDescription: String? {
            if let message, !message.isEmpty { return "The server returned HTTP \(status): \(message)" }
            return "The server returned HTTP \(status)."
        }
    }

    private struct ServerErrorPayload: Decodable { let error: String }
    private struct DuplicateSongUploadResponse: Decodable {
        let duplicateOf: MobileRemoteSong

        enum CodingKeys: String, CodingKey {
            case duplicateOf = "duplicate_of"
        }
    }
    private struct SourceLinkUploadDocument: Encodable {
        let schemaVersion: Int
        let sourceURL: String
        let mediaKind: String?

        init(sourceURL: String, mediaKind: String, schemaVersion: Int = 3) {
            self.schemaVersion = schemaVersion
            self.sourceURL = sourceURL
            self.mediaKind = schemaVersion == 3 ? mediaKind : nil
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case sourceURL = "source_url"
            case mediaKind = "media_kind"
        }
    }

    private struct ListeningHistorySyncContext: Equatable {
        let baseURL: URL
        let origin: String
        let profileID: String
        let accountID: String?
        let token: String
        let generation: UInt64
    }

    private struct SourceLinkRequiredError: LocalizedError {
        var errorDescription: String? {
            "Only songs downloaded from a preserved source link can be uploaded. Download this song from its link again first."
        }
    }
    private struct SourceImportResponse: Decodable {
        let schemaVersion: Int
        let status: String
        let song: MobileRemoteSong

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case status, song
        }
    }

    private struct SourceImportDuplicateResponse: Decodable {
        let schemaVersion: Int
        let status: String
        let duplicateOf: MobileRemoteSong

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case status
            case duplicateOf = "duplicate_of"
        }
    }
    private struct SourceImportRequest: Encodable {
        let schemaVersion = 1
        let sourcePageURL: String

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case sourcePageURL = "source_page_url"
        }
    }
    private struct RemoteSongMetadataRequest: Sendable {
        let songIDs: [String]
        let cacheKey: String
        let source: String
        let mediaKind: String
    }
    private struct RemoteSongMetadataResult: Sendable {
        let request: RemoteSongMetadataRequest
        let metadata: LocalImportSpotifyTrack?
    }
    private enum RemoteDownloadItemResult: Sendable {
        case downloaded(songID: String)
        case failed(songID: String, title: String, reason: String)
        case policyChanged
        case cancelled
    }
    @Published var tracks: [MobileTrack] = []
    @Published var playlists: [MobilePlaylist] = [MobilePlaylist(name: "Liked Songs", isSystem: true)]
    @Published var favorites: Set<UUID> = []
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    var companionVideoPlaybackPosition: TimeInterval {
        guard let player else { return position }
        return max(player.currentTime, 0)
    }
    @Published var volume: Double = 0.8 {
        didSet {
            let gain = PlaybackVolumePolicy.gain(for: volume)
            applyCrossfadeVolumes()
            streamingPlayer?.volume = gain
            UserDefaults.standard.set(volume, forKey: "Resonance.volume")
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            player?.rate = playbackRate
            crossfadePlayer?.rate = playbackRate
            streamingPlayer?.defaultRate = playbackRate
            if streamingPlayer?.timeControlStatus == .playing {
                streamingPlayer?.rate = playbackRate
            }
            UserDefaults.standard.set(Double(playbackRate), forKey: "Resonance.rate")
            updateNowPlaying()
        }
    }
    @Published var shuffleEnabled = false { didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "Resonance.shuffle") } }
    @Published var repeatEnabled = false {
        didSet {
            UserDefaults.standard.set(repeatEnabled, forKey: "Resonance.repeat")
            if repeatEnabled { cancelCrossfade() }
        }
    }
    @Published var crossfadeEnabled = false {
        didSet {
            UserDefaults.standard.set(crossfadeEnabled, forKey: "Resonance.crossfade.enabled")
            if !crossfadeEnabled { cancelCrossfade() }
        }
    }
    @Published var crossfadeSeconds: Double = MobileCrossfadePolicy.defaultSeconds {
        didSet {
            UserDefaults.standard.set(
                MobileCrossfadePolicy.normalizedSeconds(crossfadeSeconds),
                forKey: "Resonance.crossfade.seconds"
            )
        }
    }
    @Published var searchText = ""
    @Published private(set) var isRefreshingDownloadedMetadata = false
    @Published private(set) var downloadedMetadataRefreshDetail = "Refresh titles, artists, albums, and artwork from saved source links."
    @Published private(set) var serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"
    @Published private(set) var serverToken = ""
    @Published private(set) var serverAdminToken = ""
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountRole: String?
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var accountImageURL: URL?
    @Published private(set) var isAuthenticatingAccount = false
    @Published var remoteSongs: [MobileRemoteSong] = []
    @Published private(set) var pendingRemoteSongMetadataCount = 0
    @Published var selectedRemoteSongIDs: Set<String> = []
    @Published var serverMessage = "Not connected"
    @Published private(set) var isServerConnected = false
    @Published var isSyncing = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isUploading = false
    @Published var isRefreshingCatalog = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var uploadProgress = 0.0
    @Published private(set) var downloadDetail = "Idle"
    @Published private(set) var uploadDetail = "Idle"
    @Published private(set) var transferDisplay: MobileTransferDisplayState?
    @Published var transferNotice: MobileTransferNotice?
    @Published var transferFailures: [MobileTransferFailure] = []
    @Published var libraryRecoveryNotice: MobileLibraryRecoveryNotice?
    @Published private(set) var serverConfigurationMessage: String?
    @Published var isSyncingPlaylists = false
    @Published var playlistSyncDetail = "Not synced"
    @Published var syncProfileID = "default"
    @Published var syncProfileName = "Default"
    @Published private(set) var isActivatingSyncProfile = false
    @Published private(set) var clientFeatureConfiguration = MobileClientFeatureConfiguration.safeDefaults
    @Published private(set) var clientConfigurationStatus = "Using safe transfer defaults"
    @Published private(set) var selectedUploadMode = MobileUploadMode.localFile
    @Published private(set) var selectedDownloadMode = MobileDownloadMode.verifiedFileCache
    @Published private(set) var isTransientStreamActive = false
    @Published private(set) var listeningHistoryEntries: [MobileListeningHistoryEntry] = []

    var visibleSyncProfileName: String {
        ResonanceEmailPrivacy.safeDisplayName(syncProfileName, email: accountEmail)
    }

    var isTransferBusy: Bool {
        activeTransferSessionID != nil || isUploading || isDownloading
    }

    var isUploadTransferBusy: Bool {
        activeTransferSessionID != nil || isActivatingSyncProfile || MobileUploadBlockingPolicy.blocksUpload(
            isUploading: isUploading,
            isDownloading: isDownloading,
            isSyncing: isSyncing,
            isRefreshingCatalog: isRefreshingCatalog,
            isSyncingPlaylists: isSyncingPlaylists
        )
    }

    var isProfileTransitionBusy: Bool {
        isActivatingSyncProfile || isTransferBusy || isSyncing || isSyncingPlaylists
    }

    var cachedRemoteSongsForUploadPlanning: [MobileRemoteSong] {
        isServerConnected ? remoteSongs : []
    }

    var activeServerURLForUploadPlanning: URL? {
        normalizedServer()
    }

    var availableUploadModes: [MobileUploadMode] {
        MobileTransferModePolicy.availableUploadModes(configuration: clientFeatureConfiguration)
    }

    var availableDownloadModes: [MobileDownloadMode] {
        MobileTransferModePolicy.availableDownloadModes(configuration: clientFeatureConfiguration)
    }

    var activeUploadMode: MobileUploadMode? {
        MobileTransferModePolicy.effectiveUploadMode(
            preferred: selectedUploadMode,
            configuration: clientFeatureConfiguration
        )
    }

    var activeDownloadMode: MobileDownloadMode? {
        MobileTransferModePolicy.effectiveDownloadMode(
            preferred: selectedDownloadMode,
            configuration: clientFeatureConfiguration
        )
    }

    var clientConfigurationDisplayStatus: String {
        guard clientFeatureConfiguration.current() == clientFeatureConfiguration else {
            return "Feature policy expired; using safe transfer defaults"
        }
        return clientConfigurationStatus
    }

    private let fileManager = FileManager.default
    private let serverLinkImportService = LocalDeviceImportService()
    private let remoteMetadataImportService = LocalDeviceImportService()
    private let remoteMetadataResolutionBroker = MobileRemoteMetadataResolutionBroker()
    private var remoteSourceResolutions: [MobileRemoteSourceResolutionCacheKey: LocalImportResolution] = [:]
    private var remoteSongMetadataCache: [String: MobileRemoteSongMetadataCacheEntry] = [:]
    private let uploadSerialGate = MobileAsyncSerialGate()
    private let downloadSerialGate = MobileAsyncSerialGate()
    private let root: URL
    private let musicDirectory: URL
    private let artworkDirectory: URL
    private let stateURL: URL
    private let backupStateURL: URL
    private var player: AVAudioPlayer?
    private var crossfadePlayer: AVAudioPlayer?
    private var crossfadeTrackID: UUID?
    private var activeCrossfadeDuration: TimeInterval = 0
    private var timer: Timer?
    private var history: [UUID] = []
    private var playbackQueue: [UUID] = []
    private var playbackPlaylistID: UUID?
    private var artworkCache: [String: UIImage] = [:]
    private var nowPlayingArtworkCacheKey: String?
    private var nowPlayingArtworkCache: MPMediaItemArtwork?
    private var remoteNowPlayingArtworkCache: [String: UIImage] = [:]
    private var nowPlayingArtworkLoadTask: Task<Void, Never>?
    private var nowPlayingArtworkLoadRemoteID: String?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private var playlistRevision = 0
    private var playlistMutationGeneration: UInt64 = 0
    private var catalogRequestGeneration: UInt64 = 0
    private var fullCatalogAuthority: MobileFullCatalogAuthoritySnapshot?
    private var remoteSongMetadataHydrationGeneration: UInt64 = 0
    private var remoteSongMetadataHydrationTask: Task<Void, Never>?
    private var catalogMutationGeneration: UInt64 = 0
    private var uploadedSongsAwaitingCatalog: [String: MobileRemoteSong] = [:]
    private var knownRemotePlaylistIDs: Set<UUID> = []
    private var dirtyPlaylistIDs: Set<UUID> = []
    private var deletedPlaylistIDs: Set<UUID> = []
    private var playlistSyncServerURL: String?
    private var playlistSyncTask: Task<Void, Never>?
    private var listeningHistorySyncTask: Task<Void, Never>?
    private var isSyncingListeningHistory = false
    private var listeningHistorySyncPending = false
    private var listeningHistorySyncGeneration: UInt64 = 0
    private var listeningHistorySyncedSeconds: [String: TimeInterval] = [:]
    private var clientConfigRefreshTask: Task<Void, Never>?
    private var activeDownloadAuthorizations: [UUID: MobileTransferAuthorization] = [:]
    private var activeDownloadBatch: (id: UUID, task: Task<Void, Never>)?
    private var activeTransferSessionID: UUID?
    private var byteGatedDownloadSessionID: UUID?
    private var activeNativeDownloadOperationID: UUID?
    private var activeNativeDownloadPresentationOperationID: UUID?
    private var remoteLikedSongIDs: Set<String> = []
    private var dirtyRemoteLikeSongIDs: Set<String> = []
    private var likesMutationGeneration: UInt64 = 0
    private var likesDirty = false
    private var clipRanges: [String: MobileClipRange] = [:]
    private var dirtyClipRangeKeys: Set<String> = []
    private var deletedClipRangeKeys: Set<String> = []
    private var completedMigrations: Set<String> = []
    private var clipRangeMutationGeneration: UInt64 = 0
    private var profileSyncStates: [MobileServerContext: MobileProfileSyncState] = [:]
    private var clientConfigRequestGeneration: UInt64 = 0
    private var streamingTrack: MobileTrack?
    private var streamingArtworkURL: URL?
    private var streamingPlayer: AVPlayer?
    private var streamingResourceLoader: MobileAuthenticatedStreamResourceLoader?
    private var streamingYouTubeLoader: MobileYouTubeStreamResourceLoader?
    private var streamingAuthorizationLease: MobileAuthenticatedStreamAuthorizationLease?
    private var streamingPreview: LocalImportPreviewStream?
    private var streamingPreviewSourceURL: String?
    private var streamingEndObserver: NSObjectProtocol?
    private var streamingFailureObserver: NSObjectProtocol?
    private var streamingStatusObservation: NSKeyValueObservation?
    private var streamingGeneration: UInt64 = 0
    private var accountSession: ResonanceAccountSession?
    private var accountRefreshTask: Task<Void, Never>?
    private var isRefreshingAccountSession = false
    private var activeListeningHistoryEntryID: UUID?
    private var lastListeningPosition: TimeInterval = 0
    private var lastPersistedListeningSeconds: TimeInterval = 0
    private var pendingListeningSeconds: TimeInterval = 0
    private weak var listenAlongController: MobileListenAlongController?
    private var listenAlongApplyingRemoteState = false

    private struct EmbeddedMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval?
        var artworkData: Data?
    }

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        MobileLegacyAppMigration.run(applicationSupportRoot: support)
        root = support.appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
        musicDirectory = root.appendingPathComponent("Music", isDirectory: true)
        artworkDirectory = root.appendingPathComponent("Artwork", isDirectory: true)
        stateURL = root.appendingPathComponent("library.json")
        backupStateURL = root.appendingPathComponent("library.backup.json")
        super.init()
        removeOrphanedTransferArtifacts()
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        load()
        if UserDefaults.standard.object(forKey: "Resonance.volume") != nil { volume = UserDefaults.standard.double(forKey: "Resonance.volume") }
        if UserDefaults.standard.object(forKey: "Resonance.rate") != nil { playbackRate = Float(UserDefaults.standard.double(forKey: "Resonance.rate")) }
        crossfadeEnabled = UserDefaults.standard.bool(forKey: "Resonance.crossfade.enabled")
        if UserDefaults.standard.object(forKey: "Resonance.crossfade.seconds") != nil {
            crossfadeSeconds = MobileCrossfadePolicy.normalizedSeconds(
                UserDefaults.standard.double(forKey: "Resonance.crossfade.seconds")
            )
        }
        shuffleEnabled = UserDefaults.standard.bool(forKey: "Resonance.shuffle")
        repeatEnabled = UserDefaults.standard.bool(forKey: "Resonance.repeat")
        if let session = Self.readAccountSession() {
            accountSession = session
            serverURL = (try? MobileServerEndpointPolicy.resolve(session.baseURL.absoluteString).url.absoluteString)
                ?? session.baseURL.absoluteString
            serverToken = session.accessToken
            serverAdminToken = session.accessToken
            accountEmail = session.email
            accountRole = session.role
            accountDisplayName = session.profileDisplayName
            accountImageURL = session.imageURL
            if session.profileID == syncProfileID {
                syncProfileName = session.profileDisplayName
            }
            try? Self.storeToken("", key: "client")
            try? Self.storeToken("", key: "admin")
            scheduleAccountRefresh(session)
        } else {
            serverToken = Self.readToken(key: "client")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            serverAdminToken = Self.readToken(key: "admin")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        configureAudioSession()
        observeAudioSession()
        configureRemoteCommands()
        updateNowPlaying()
        Task { [weak self] in
            await self?.refreshEmbeddedMetadata()
            await self?.refreshAccountSessionIfNeeded()
        }
    }

    deinit {
        timer?.invalidate()
        remoteSongMetadataHydrationTask?.cancel()
        playlistSyncTask?.cancel()
        listeningHistorySyncTask?.cancel()
        clientConfigRefreshTask?.cancel()
        accountRefreshTask?.cancel()
        nowPlayingArtworkLoadTask?.cancel()
        activeDownloadBatch?.task.cancel()
        activeDownloadAuthorizations.values.forEach { $0.revoke() }
        if let streamingEndObserver { NotificationCenter.default.removeObserver(streamingEndObserver) }
        if let streamingFailureObserver { NotificationCenter.default.removeObserver(streamingFailureObserver) }
        streamingStatusObservation?.invalidate()
        streamingPlayer?.pause()
        crossfadePlayer?.stop()
        streamingResourceLoader?.invalidate()
        streamingYouTubeLoader?.invalidate()
        streamingAuthorizationLease?.invalidate()
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for registration in remoteCommandTargets {
            registration.command.removeTarget(registration.target)
        }
    }

    func signIn(with provider: ResonanceSocialAuthProvider) async {
        guard !isAuthenticatingAccount else { return }
        isAuthenticatingAccount = true
        serverMessage = "Opening \(provider.title) sign-in…"
        defer { isAuthenticatingAccount = false }
        do {
            let client = try ResonanceSocialAuthClient(
                baseURL: ResonanceSocialAuthClient.accountSignInBaseURL
            )
            let session = try await client.signIn(
                with: provider,
                migrationProfileID: syncProfileID
            )
            // Stop the owned transfer before replacing any account, token, or
            // profile state that its callbacks are scoped to.
            cancelActiveDownloadBatch()
            endListeningHistorySession()
            invalidateListeningHistorySync()
            migrateConfirmedLegacyProfile(for: session)
            try Self.storeAccountSession(session)
            accountSession = session
            accountEmail = session.email
            accountRole = session.role
            accountDisplayName = session.profileDisplayName
            accountImageURL = session.imageURL
            try? Self.storeToken("", key: "client")
            try? Self.storeToken("", key: "admin")
            guard applyServerConfiguration(
                serverURL: session.baseURL.absoluteString,
                accessToken: session.accessToken,
                adminToken: session.accessToken
            ) else { return }
            if let profileID = session.profileID, !profileID.isEmpty {
                selectSyncProfile(profileID, name: session.profileDisplayName)
            }
            scheduleAccountRefresh(session)
            serverMessage = "Signed in with Clerk"
            await refreshClientConfiguration()
            await syncListeningHistoryNow()
        } catch {
            serverMessage = error.localizedDescription
            serverConfigurationMessage = error.localizedDescription
        }
    }

    func signOutAccount() async {
        endListeningHistorySession()
        await syncListeningHistoryNow()
        let active = accountSession
        listenAlongController?.profileOrServerContextDidChange()
        cancelActiveDownloadBatch()
        accountSession = nil
        remoteSourceResolutions.removeAll()
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        invalidateListeningHistorySync()
        try? Self.storeToken("", key: Self.accountSessionKey)
        try? Self.storeToken("", key: "client")
        try? Self.storeToken("", key: "admin")
        accountEmail = nil
        accountRole = nil
        accountDisplayName = nil
        accountImageURL = nil
        serverToken = ""
        serverAdminToken = ""
        advanceCatalogRequestGeneration()
        isServerConnected = false
        cancelRemoteSongMetadataHydration()
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()
        serverMessage = "Signed out"
        if let active, let client = try? ResonanceSocialAuthClient(baseURL: active.baseURL) {
            await client.signOut(active)
        }
    }

    func refreshAccountSessionIfNeeded() async {
        guard let current = accountSession,
              !isRefreshingAccountSession else { return }
        let needsProfileHydration = current.profileID?.isEmpty != false
            || current.profileID != current.accountID
            || current.displayName?.isEmpty != false
        guard current.usesLegacyProductionServer
            || needsProfileHydration
            || current.expiresAt <= Date().addingTimeInterval(5 * 60)
        else { return }
        isRefreshingAccountSession = true
        defer { isRefreshingAccountSession = false }
        do {
            let client = try ResonanceSocialAuthClient(baseURL: current.baseURL)
            let refreshed = try await client.refresh(current, migrationProfileID: syncProfileID)
            guard accountSession == current else { return }
            if refreshed.accountID != current.accountID
                || refreshed.baseURL != current.baseURL
                || refreshed.profileID != current.profileID {
                endListeningHistorySession()
                invalidateListeningHistorySync()
            }
            let previousCatalogContext = activeServerContext
            let previousCatalogServerURL = normalizedServer()?.absoluteString
            let previousCatalogToken = serverToken
            let refreshedProfileID = refreshed.profileID.flatMap { $0.isEmpty ? nil : $0 }
                ?? syncProfileID
            let refreshedCatalogContext = MobileServerEndpointPolicy.context(
                serverURL: refreshed.baseURL,
                profileID: refreshedProfileID
            )
            let refreshChangesDownloadScope = previousCatalogContext != refreshedCatalogContext
                || previousCatalogServerURL != refreshed.baseURL.absoluteString
                || previousCatalogToken != refreshed.accessToken
            if refreshChangesDownloadScope {
                // Cancellation and authorization revocation precede every
                // credential/context mutation visible to transfer callbacks.
                listenAlongController?.profileOrServerContextDidChange()
                cancelActiveDownloadBatch()
            }
            migrateConfirmedLegacyProfile(for: refreshed)
            try Self.storeAccountSession(refreshed)
            accountSession = refreshed
            accountEmail = refreshed.email
            accountRole = refreshed.role
            accountDisplayName = refreshed.profileDisplayName
            accountImageURL = refreshed.imageURL
            serverURL = refreshed.baseURL.absoluteString
            serverToken = refreshed.accessToken
            serverAdminToken = refreshed.accessToken
            if refreshChangesDownloadScope {
                advanceCatalogRequestGeneration()
            }
            if let profileID = refreshed.profileID, !profileID.isEmpty {
                selectSyncProfile(profileID, name: refreshed.profileDisplayName)
            }
            await refreshClientConfiguration()
            await syncListeningHistoryNow()
            scheduleAccountRefresh(refreshed)
        } catch {
            guard accountSession == current else { return }
            if current.expiresAt <= Date() {
                await signOutAccount()
                serverMessage = "Your account session expired. Please sign in again."
            } else {
                accountRefreshTask?.cancel()
                accountRefreshTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    await self?.refreshAccountSessionIfNeeded()
                }
            }
        }
    }

    private func scheduleAccountRefresh(_ session: ResonanceAccountSession) {
        accountRefreshTask?.cancel()
        let delay = max(5, session.expiresAt.timeIntervalSinceNow - 5 * 60)
        accountRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshAccountSessionIfNeeded()
        }
    }

    private func migrateConfirmedLegacyProfile(for session: ResonanceAccountSession) {
        guard let migratedProfileID = session.migratedProfileID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !migratedProfileID.isEmpty,
              let accountProfileID = session.profileID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !accountProfileID.isEmpty,
              migratedProfileID != accountProfileID,
              syncProfileID == migratedProfileID,
              let oldContext = MobileServerEndpointPolicy.context(
                serverURL: session.baseURL,
                profileID: migratedProfileID
              ),
              activeServerContext == oldContext,
              let newContext = MobileServerEndpointPolicy.context(
                serverURL: session.baseURL,
                profileID: accountProfileID
              ) else { return }

        captureActiveProfileState()
        if let state = profileSyncStates.removeValue(forKey: oldContext) {
            profileSyncStates[newContext] = state
        }

        for index in tracks.indices where tracks[index].remoteIdentity()?.context == oldContext {
            tracks[index].syncProfileID = accountProfileID
        }
        if streamingTrack?.remoteIdentity()?.context == oldContext {
            streamingTrack?.syncProfileID = accountProfileID
        }
        for index in listeningHistoryEntries.indices
        where MobileListeningHistoryPolicy.normalizedOrigin(listeningHistoryEntries[index].serverOrigin) == oldContext.origin
            && (listeningHistoryEntries[index].syncProfileID ?? "default") == migratedProfileID
            && (listeningHistoryEntries[index].accountID == nil || listeningHistoryEntries[index].accountID == session.accountID) {
            listeningHistoryEntries[index].serverOrigin = newContext.origin
            listeningHistoryEntries[index].syncProfileID = accountProfileID
            listeningHistoryEntries[index].accountID = session.accountID
        }

        let oldClipPrefix = "\(oldContext.storagePrefix)|remote:"
        let newClipPrefix = "\(newContext.storagePrefix)|remote:"
        func migratedClipKey(_ key: String) -> String {
            guard key.hasPrefix(oldClipPrefix) else { return key }
            return newClipPrefix + key.dropFirst(oldClipPrefix.count)
        }
        clipRanges = clipRanges.reduce(into: [:]) { result, pair in
            result[migratedClipKey(pair.key)] = pair.value
        }
        dirtyClipRangeKeys = Set(dirtyClipRangeKeys.map(migratedClipKey))
        deletedClipRangeKeys = Set(deletedClipRangeKeys.map(migratedClipKey))

        let oldServerKey = "\(session.baseURL.absoluteString)#profile=\(migratedProfileID)"
        if playlistSyncServerURL == oldServerKey {
            playlistSyncServerURL = "\(session.baseURL.absoluteString)#profile=\(accountProfileID)"
        }
        if let origin = MobileClientConfigOrigin.normalized(session.baseURL) {
            let oldScope = MobileTransferPreferenceScope(origin: origin, profileID: migratedProfileID)
            let newScope = MobileTransferPreferenceScope(origin: origin, profileID: accountProfileID)
            for (oldKey, newKey) in [
                (oldScope.uploadKey, newScope.uploadKey),
                (oldScope.downloadKey, newScope.downloadKey),
            ] where UserDefaults.standard.object(forKey: newKey) == nil {
                UserDefaults.standard.set(UserDefaults.standard.object(forKey: oldKey), forKey: newKey)
            }
        }
        advanceCatalogRequestGeneration()
        syncProfileID = accountProfileID
        syncProfileName = session.profileDisplayName
        save()
    }

    var currentTrack: MobileTrack? {
        guard let currentTrackID else { return nil }
        return tracks.first { $0.id == currentTrackID }
            ?? streamingTrack.flatMap { $0.id == currentTrackID ? $0 : nil }
    }

    var activeListeningHistoryEntries: [MobileListeningHistoryEntry] {
        guard let activeServerContext else {
            let accountID = accountSession?.accountID
            return listeningHistoryEntries.filter {
                $0.serverOrigin == nil && ($0.accountID == nil || $0.accountID == accountID)
            }
        }
        let accountID = accountSession?.accountID
        return listeningHistoryEntries.filter {
            MobileListeningHistoryPolicy.normalizedOrigin($0.serverOrigin) == activeServerContext.origin
                && ($0.syncProfileID ?? "default") == syncProfileID
                && ($0.accountID == nil || $0.accountID == accountID)
        }
    }

    /// Artwork for a transient Listen Along stream. Transient tracks are not
    /// persisted in the local library, so their provider artwork is kept
    /// alongside the stream and consumed by the normal player artwork view.
    func listenAlongArtworkURL(for track: MobileTrack) -> URL? {
        guard streamingTrack?.id == track.id else { return nil }
        return streamingArtworkURL
    }

    private func resolvedListenAlongArtworkURL(_ value: URL?, relativeTo baseURL: URL) -> URL? {
        guard let value else { return nil }
        let resolved = value.scheme == nil
            ? URL(string: value.relativeString, relativeTo: baseURL)?.absoluteURL
            : value
        guard let resolved else { return nil }
        return MobileArtworkURLPolicy.validated(resolved, allowedOrigin: baseURL)
            ?? MobileArtworkURLPolicy.validated(resolved)
    }

    private func removeOrphanedTransferArtifacts() {
        MobileOwnedTransferArtifactCleaner.removeOrphans(
            temporaryDirectory: fileManager.temporaryDirectory,
            stagingDirectory: root.appendingPathComponent("LocalImports", isDirectory: true),
            fileManager: fileManager
        )
    }

    var activeServerContext: MobileServerContext? {
        guard let server = URL(string: serverURL) else { return nil }
        return MobileServerEndpointPolicy.context(serverURL: server, profileID: syncProfileID)
    }

    var isListenAlongPlaybackLocked: Bool {
        listenAlongController?.isParticipant == true
    }

    var listenAlongCurrentSourceURL: String? {
        guard let track = currentTrack else { return nil }
        if let sourceURL = track.sourceURL,
           let canonical = MobileTrackPersistencePolicy.canonicalSourceURL(sourceURL) {
            return canonical
        }
        guard let remoteID = track.remoteID else { return nil }
        return remoteSongs.first(where: { $0.id == remoteID })?.sourceURL.flatMap {
            MobileTrackPersistencePolicy.canonicalSourceURL($0)
        }
    }

    var listenAlongCurrentMediaKind: String {
        guard let track = currentTrack else { return "audio" }
        if let remoteID = track.remoteID,
           let remoteSong = remoteSongs.first(where: { $0.id == remoteID }) {
            return remoteSong.mediaKind == "video" ? "video" : "audio"
        }
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
        return videoExtensions.contains(
            URL(fileURLWithPath: track.relativePath).pathExtension.lowercased()
        ) ? "video" : "audio"
    }

    var listenAlongServerURL: URL? { normalizedServer() }

    func listenAlongRequestContext() -> MobileClientRequestContext {
        clientRequestContext()
    }

    func attachListenAlongController(_ controller: MobileListenAlongController) {
        listenAlongController = controller
        updateNowPlaying()
    }

    func refreshListenAlongControlState() {
        updateNowPlaying()
    }

    private var listenAlongLocalPlaybackIsLocked: Bool {
        listenAlongController?.isParticipant == true && !listenAlongApplyingRemoteState
    }

    private func notifyListenAlongPlaybackChanged() {
        guard !listenAlongApplyingRemoteState else { return }
        listenAlongController?.hostPlaybackDidChange()
    }

    private var authoritativeCatalogSongIDs: Set<String>? {
        MobileFullCatalogAuthorityPolicy.songIDsIfCurrent(
            fullCatalogAuthority,
            context: activeServerContext,
            requestGeneration: catalogRequestGeneration
        )
    }

    private func invalidateFullCatalogAuthority() {
        fullCatalogAuthority = nil
    }

    @discardableResult
    private func advanceCatalogRequestGeneration() -> UInt64 {
        catalogRequestGeneration &+= 1
        invalidateFullCatalogAuthority()
        return catalogRequestGeneration
    }

    func belongsToActiveServerContext(_ track: MobileTrack) -> Bool {
        guard track.remoteID != nil else { return true }
        guard let activeServerContext else { return false }
        return track.remoteIdentity()?.context == activeServerContext
    }

    func selectUploadMode(_ mode: MobileUploadMode) {
        guard availableUploadModes.contains(mode), let scope = transferPreferenceScope else { return }
        selectedUploadMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: scope.uploadKey)
    }

    func selectDownloadMode(_ mode: MobileDownloadMode) {
        guard availableDownloadModes.contains(mode), let scope = transferPreferenceScope else { return }
        if selectedDownloadMode != mode {
            cancelActiveDownloadBatch()
            if isTransientStreamActive {
                discardStreamingPlayback()
                showTransferNotice(
                    title: "Stream stopped",
                    detail: "The selected download mode changed.",
                    isError: false
                )
            }
        }
        selectedDownloadMode = mode
        if mode == .streamOnly { selectedRemoteSongIDs.removeAll() }
        UserDefaults.standard.set(mode.rawValue, forKey: scope.downloadKey)
    }

    func refreshClientConfiguration() async {
        clientConfigRequestGeneration &+= 1
        let requestGeneration = clientConfigRequestGeneration
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearerToken = accessToken.isEmpty ? adminToken : accessToken
        guard let baseURL = normalizedServer(),
              let origin = MobileClientConfigOrigin.normalized(baseURL),
              !bearerToken.isEmpty else {
            useSafeClientConfiguration(status: "Using safe transfer defaults")
            return
        }
        let requestProfileID = syncProfileID
        let tokenFingerprint = MobileClientConfigCacheScope.tokenFingerprint(bearerToken)
        let appVersion = clientAppVersion
        let appBuild = clientAppBuild
        let cohortKey = clientCohortKey
        let requestContext = MobileClientRequestContext(
            profileID: requestProfileID,
            platform: "ios",
            appVersion: appVersion,
            appBuild: appBuild,
            cohortKey: cohortKey
        )
        guard requestContext.isComplete else {
            useSafeClientConfiguration(status: "Invalid client build context; using safe defaults")
            return
        }
        let expected = MobileClientConfigExpectedAudience(
            origin: origin,
            profileID: requestProfileID,
            appVersion: appVersion,
            appBuild: appBuild,
            cohortKey: cohortKey
        )
        let cacheScope = MobileClientConfigCacheScope(
            origin: origin,
            profileID: requestProfileID,
            platform: "ios",
            appVersion: appVersion,
            appBuild: String(appBuild),
            tokenFingerprint: tokenFingerprint
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/client-config"))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        requestContext.apply(to: &request)

        do {
            let (body, response) = try await sameOriginData(for: request, origin: baseURL)
            guard let response = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                origin: origin,
                profileID: requestProfileID,
                tokenFingerprint: tokenFingerprint
            ) else { return }
            guard MobileSameOriginPolicy.matches(response.url, baseURL) else {
                UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
                useSafeClientConfiguration(status: "Invalid feature response; using safe defaults")
                return
            }
            switch MobileClientConfigHTTPPolicy.disposition(
                status: response.statusCode,
                contentType: response.value(forHTTPHeaderField: "Content-Type")
            ) {
            case .evictAndUseSafeDefaults:
                UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
                useSafeClientConfiguration(
                    status: response.statusCode == 404 || response.statusCode == 405
                        ? "Server uses safe legacy transfer defaults"
                        : "Invalid feature response; using safe defaults"
                )
                return
            case .useFreshCache:
                if let verified = cachedClientConfiguration(
                    scope: cacheScope,
                    expected: expected,
                    token: bearerToken
                ) {
                    adoptClientConfiguration(verified, status: "Using verified cached feature policy")
                } else {
                    useSafeClientConfiguration(status: "Feature policy unavailable; using safe defaults")
                }
                return
            case .verify:
                break
            }
            let digest = response.value(forHTTPHeaderField: "Content-Digest")
            let signature = response.value(forHTTPHeaderField: "X-Resonance-Config-Signature")
            let verified: MobileVerifiedClientConfiguration
            do {
                verified = try MobileClientConfigVerifier.verify(
                    body: body,
                    contentDigest: digest,
                    signature: signature,
                    accessToken: bearerToken,
                    expected: expected
                )
            } catch {
                UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
                useSafeClientConfiguration(status: "Invalid feature policy; using safe defaults")
                return
            }
            guard recordVerifiedRevision(verified.payload.revision, scope: cacheScope) else {
                UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
                useSafeClientConfiguration(status: "Rejected stale feature revision; using safe defaults")
                return
            }
            guard let digest, let signature else {
                throw MobileClientConfigVerificationError.missingSignature
            }
            let record = MobileClientConfigCacheRecord(
                body: body,
                contentDigest: digest,
                signature: signature,
                cachedAt: .now
            )
            if let encoded = try? JSONEncoder().encode(record) {
                UserDefaults.standard.set(encoded, forKey: cacheScope.storageKey)
            }
            adoptClientConfiguration(verified, status: "Feature policy revision \(verified.payload.revision)")
        } catch is MobileSensitiveResponseError {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                origin: origin,
                profileID: requestProfileID,
                tokenFingerprint: tokenFingerprint
            ) else { return }
            UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
            useSafeClientConfiguration(status: "Oversized feature response; using safe defaults")
        } catch let error as URLError where error.code == .dataNotAllowed {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                origin: origin,
                profileID: requestProfileID,
                tokenFingerprint: tokenFingerprint
            ) else { return }
            UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
            useSafeClientConfiguration(status: "Cross-origin feature response blocked; using safe defaults")
        } catch {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                origin: origin,
                profileID: requestProfileID,
                tokenFingerprint: tokenFingerprint
            ) else { return }
            guard MobileClientConfigTransportPolicy.mayUseFreshCache(for: error) else {
                UserDefaults.standard.removeObject(forKey: cacheScope.storageKey)
                useSafeClientConfiguration(status: "Invalid feature response; using safe defaults")
                return
            }
            guard let verified = cachedClientConfiguration(
                scope: cacheScope,
                expected: expected,
                token: bearerToken
            ) else {
                useSafeClientConfiguration(status: "Feature policy unavailable; using safe defaults")
                return
            }
            adoptClientConfiguration(verified, status: "Using verified cached feature policy")
        }
    }

    private var clientAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var clientAppBuild: Int {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return Int(value) ?? 0
    }

    private var clientCohortKey: String {
        let key = "Resonance.clientConfig.cohortKey.v1"
        if let existing = UserDefaults.standard.string(forKey: key),
           MobileClientConfigCohort.isValidKey(existing) {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = Array(SHA256.hash(data: Data(UUID().uuidString.utf8)).prefix(16))
        }
        let generated = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    private var transferPreferenceScope: MobileTransferPreferenceScope? {
        guard let baseURL = normalizedServer(),
              let origin = MobileClientConfigOrigin.normalized(baseURL) else { return nil }
        return MobileTransferPreferenceScope(origin: origin, profileID: syncProfileID)
    }

    private func setClientConfigContextHeaders(
        on request: inout URLRequest,
        profileID: String? = nil
    ) {
        clientRequestContext(profileID: profileID).apply(to: &request)
    }

    private func clientRequestContext(profileID: String? = nil) -> MobileClientRequestContext {
        MobileClientRequestContext(
            profileID: profileID ?? syncProfileID,
            platform: "ios",
            appVersion: clientAppVersion,
            appBuild: clientAppBuild,
            cohortKey: clientCohortKey
        )
    }

    private func sameOriginData(
        for request: URLRequest,
        origin: URL,
        maximumBytes: Int = MobileBoundedResponsePolicy.clientConfigMaximumBytes
    ) async throws -> (Data, URLResponse) {
        let (data, response) = try await MobileSensitiveNetworkPolicy.data(
            for: request,
            origin: origin,
            maximumBytes: maximumBytes
        )
        return (data, response)
    }

    private func isCurrentClientConfigRequest(
        generation: UInt64,
        origin: String,
        profileID: String,
        tokenFingerprint: String
    ) -> Bool {
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentToken = accessToken.isEmpty ? adminToken : accessToken
        guard generation == clientConfigRequestGeneration,
              profileID == syncProfileID,
              tokenFingerprint == MobileClientConfigCacheScope.tokenFingerprint(currentToken),
              let baseURL = normalizedServer(),
              MobileClientConfigOrigin.normalized(baseURL) == origin else { return false }
        return true
    }

    private func cachedClientConfiguration(
        scope: MobileClientConfigCacheScope,
        expected: MobileClientConfigExpectedAudience,
        token: String,
        now: Date = .now
    ) -> MobileVerifiedClientConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: scope.storageKey),
              let record = try? JSONDecoder().decode(MobileClientConfigCacheRecord.self, from: data),
              MobileClientConfigCachePolicy.isFresh(record, now: now),
              let verified = try? MobileClientConfigVerifier.verify(
                body: record.body,
                contentDigest: record.contentDigest,
                signature: record.signature,
                accessToken: token,
                expected: expected,
                now: now
              ),
              recordVerifiedRevision(verified.payload.revision, scope: scope) else {
            UserDefaults.standard.removeObject(forKey: scope.storageKey)
            return nil
        }
        return verified
    }

    private func recordVerifiedRevision(
        _ revision: Int,
        scope: MobileClientConfigCacheScope
    ) -> Bool {
        let defaults = UserDefaults.standard
        let highest = (defaults.object(forKey: scope.highestRevisionKey) as? NSNumber)?.intValue
        guard MobileClientConfigRevisionPolicy.accepts(
            candidate: revision,
            highestVerified: highest
        ) else { return false }
        if highest.map({ revision > $0 }) ?? true {
            defaults.set(revision, forKey: scope.highestRevisionKey)
        }
        return true
    }

    private func adoptClientConfiguration(
        _ verified: MobileVerifiedClientConfiguration,
        status: String
    ) {
        let nextConfiguration = MobileClientFeatureConfiguration(verified: verified)
        let samePolicy = nextConfiguration.hasSamePolicy(as: clientFeatureConfiguration)
        if !samePolicy {
            cancelActiveDownloadBatch()
        }
        if let streamingAuthorizationLease {
            let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let renewed = MobileTransferModePolicy.effectiveDownloadMode(
                    preferred: selectedDownloadMode,
                    configuration: nextConfiguration
                ) == .streamOnly
                && !accessToken.isEmpty
                && authenticatedStreamLeaseContext(
                    baseURL: normalizedServer(),
                    profileID: syncProfileID,
                    accessToken: accessToken
                ).map {
                    streamingAuthorizationLease.renew(
                        context: $0,
                        expiresAt: verified.expiresAt
                    )
                } == true
            if !renewed {
                discardStreamingPlayback()
                showTransferNotice(
                    title: "Stream stopped",
                    detail: "The signed stream policy changed.",
                    isError: true
                )
            }
        }
        clientFeatureConfiguration = nextConfiguration
        clientConfigurationStatus = status
        reconcileTransferModePreferences()
        // Use the latest signed expiration for both the active stream lease and
        // the proactive configuration refresh. A shortened authoritative lease
        // therefore refreshes sooner without being treated as a revocation.
        scheduleClientConfigurationRefresh(expiresAt: verified.expiresAt)
    }

    private func useSafeClientConfiguration(status: String) {
        clientConfigRefreshTask?.cancel()
        clientConfigRefreshTask = nil
        cancelActiveDownloadBatch()
        if isTransientStreamActive {
            discardStreamingPlayback()
            showTransferNotice(
                title: "Stream stopped",
                detail: "The signed stream policy is unavailable or expired.",
                isError: true
            )
        }
        clientFeatureConfiguration = .safeDefaults
        clientConfigurationStatus = status
        reconcileTransferModePreferences()
    }

    private func scheduleClientConfigurationRefresh(expiresAt: Date) {
        clientConfigRefreshTask?.cancel()
        guard let delay = MobileClientConfigRefreshPolicy.delay(until: expiresAt) else {
            useSafeClientConfiguration(status: "Feature policy expired; using safe transfer defaults")
            return
        }
        clientConfigRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                await self?.refreshClientConfiguration()
            } catch {
                return
            }
        }
    }

    private func reconcileTransferModePreferences() {
        let defaults = UserDefaults.standard
        let storedUpload = transferPreferenceScope
            .flatMap { defaults.string(forKey: $0.uploadKey) }
            .flatMap(MobileUploadMode.init(rawValue:))
        let storedDownload = transferPreferenceScope
            .flatMap { defaults.string(forKey: $0.downloadKey) }
            .flatMap(MobileDownloadMode.init(rawValue:))
        selectedUploadMode = MobileTransferModePolicy.effectiveUploadMode(
            preferred: storedUpload,
            configuration: clientFeatureConfiguration
        ) ?? .localFile
        selectedDownloadMode = MobileTransferModePolicy.effectiveDownloadMode(
            preferred: storedDownload,
            configuration: clientFeatureConfiguration
        ) ?? .verifiedFileCache
        if activeDownloadMode == .streamOnly { selectedRemoteSongIDs.removeAll() }
    }

    func captureReviewedMatchLease() -> MobileReviewedMatchLease? {
        guard let transferPolicy = MobileTransferPolicyLeasePolicy.captureUpload(
            .reviewedMatch,
            configuration: clientFeatureConfiguration,
            preferredMode: selectedUploadMode
        ),
        let baseURL = normalizedServer(),
        let origin = MobileClientConfigOrigin.normalized(baseURL) else { return nil }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestContext = clientRequestContext(profileID: syncProfileID)
        guard !adminToken.isEmpty, requestContext.isComplete else { return nil }
        return MobileReviewedMatchLease(
            transferPolicy: transferPolicy,
            origin: origin,
            profileID: syncProfileID,
            adminTokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint(adminToken),
            requestContext: requestContext
        )
    }

    func isReviewedMatchLeaseCurrent(_ lease: MobileReviewedMatchLease) -> Bool {
        guard isReviewedMatchRequestContextCurrent(lease) else { return false }
        return MobileTransferPolicyLeasePolicy.isCurrent(
            lease.transferPolicy,
            configuration: clientFeatureConfiguration,
            preferredUploadMode: selectedUploadMode,
            preferredDownloadMode: selectedDownloadMode
        )
    }

    func isReviewedMatchRequestContextCurrent(_ lease: MobileReviewedMatchLease) -> Bool {
        let currentAdminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lease.profileID == syncProfileID,
              lease.requestContext == clientRequestContext(profileID: syncProfileID),
              lease.adminTokenFingerprint == MobileClientConfigCacheScope.tokenFingerprint(currentAdminToken),
              let baseURL = normalizedServer(),
              MobileClientConfigOrigin.normalized(baseURL) == lease.origin else { return false }
        return true
    }

    private func captureRawUploadLease(
        mode: MobileUploadMode,
        baseURL: URL,
        profileID: String
    ) -> MobileRawUploadLease? {
        guard let transferPolicy = MobileTransferPolicyLeasePolicy.captureUpload(
            mode,
            configuration: clientFeatureConfiguration,
            preferredMode: selectedUploadMode
        ),
        let origin = MobileClientConfigOrigin.normalized(baseURL) else { return nil }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestContext = clientRequestContext(profileID: profileID)
        guard !adminToken.isEmpty, requestContext.isComplete else { return nil }
        return MobileRawUploadLease(
            transferPolicy: transferPolicy,
            mode: mode,
            origin: origin,
            profileID: profileID,
            adminTokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint(adminToken),
            requestContext: requestContext
        )
    }

    private func isRawUploadLeaseCurrent(_ lease: MobileRawUploadLease) -> Bool {
        guard isRawUploadRequestContextCurrent(lease) else { return false }
        return MobileTransferPolicyLeasePolicy.isCurrent(
            lease.transferPolicy,
            configuration: clientFeatureConfiguration,
            preferredUploadMode: selectedUploadMode,
            preferredDownloadMode: selectedDownloadMode
        )
    }

    private func isRawUploadRequestContextCurrent(_ lease: MobileRawUploadLease) -> Bool {
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lease.profileID == syncProfileID,
              lease.requestContext == clientRequestContext(profileID: syncProfileID),
              lease.adminTokenFingerprint == MobileClientConfigCacheScope.tokenFingerprint(adminToken),
              let baseURL = normalizedServer(),
              MobileClientConfigOrigin.normalized(baseURL) == lease.origin else { return false }
        return true
    }

    private func authenticatedStreamLeaseContext(
        baseURL: URL?,
        profileID: String,
        accessToken: String
    ) -> MobileAuthenticatedStreamLeaseContext? {
        guard let baseURL,
              let origin = MobileClientConfigOrigin.normalized(baseURL),
              !accessToken.isEmpty else { return nil }
        let requestContext = clientRequestContext(profileID: profileID)
        guard requestContext.isComplete else { return nil }
        return MobileAuthenticatedStreamLeaseContext(
            origin: origin,
            requestContext: requestContext,
            tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint(accessToken)
        )
    }

    private func captureDownloadPolicyLease(
        _ mode: MobileDownloadMode
    ) -> MobileTransferPolicyLease? {
        MobileTransferPolicyLeasePolicy.captureDownload(
            mode,
            configuration: clientFeatureConfiguration,
            preferredMode: selectedDownloadMode
        )
    }

    private func isDownloadPolicyLeaseCurrent(_ lease: MobileTransferPolicyLease) -> Bool {
        MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: clientFeatureConfiguration,
            preferredUploadMode: selectedUploadMode,
            preferredDownloadMode: selectedDownloadMode
        )
    }

    private func registerDownloadAuthorization(
        for lease: MobileTransferPolicyLease
    ) -> (id: UUID, authorization: MobileTransferAuthorization)? {
        guard isDownloadPolicyLeaseCurrent(lease) else { return nil }
        let authorization = MobileTransferAuthorization(
            expiresAt: lease.configuration.expiresAt
        )
        guard authorization.isAuthorized() else { return nil }
        let id = UUID()
        activeDownloadAuthorizations[id] = authorization
        return (id, authorization)
    }

    private func releaseDownloadAuthorization(_ id: UUID) {
        activeDownloadAuthorizations.removeValue(forKey: id)
    }

    private func revokeActiveDownloadAuthorizations() {
        let authorizations = Array(activeDownloadAuthorizations.values)
        activeDownloadAuthorizations.removeAll()
        authorizations.forEach { $0.revoke() }
    }

    private func cancelActiveDownloadBatch() {
        activeDownloadBatch?.task.cancel()
        activeDownloadBatch = nil
        revokeActiveDownloadAuthorizations()
        guard isDownloading, let sessionID = activeTransferSessionID else { return }
        finishTransferSession(sessionID)
    }

    func resolveReviewedMatch(
        source rawSource: String,
        lease: MobileReviewedMatchLease
    ) async throws -> LocalImportResolution {
        guard isReviewedMatchLeaseCurrent(lease),
              let baseURL = normalizedServer() else {
            throw MobileTransferPolicyChangedError.changed
        }
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.count <= MobileDurableURLPolicy.maximumCharacters else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_REVIEW_SOURCE",
                message: "Enter one Spotify track or YouTube video link to review."
            )
        }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = baseURL.appendingPathComponent("api/v1/admin/debrid/resolve")
        guard MobileSameOriginPolicy.matches(endpoint, baseURL) else {
            throw URLError(.dataNotAllowed)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        lease.requestContext.apply(to: &request)
        request.httpBody = try JSONEncoder().encode(["source": source])

        let (data, response) = try await sameOriginData(
            for: request,
            origin: baseURL,
            maximumBytes: MobileBoundedResponsePolicy.sourceImportMaximumBytes
        )
        guard isReviewedMatchLeaseCurrent(lease) else {
            throw MobileTransferPolicyChangedError.changed
        }
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            throw playlistServerError(status: http.statusCode, data: data)
        }
        guard MobileClientConfigHTTPPolicy.disposition(
            status: http.statusCode,
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        ) == .verify else {
            throw URLError(.cannotParseResponse)
        }
        return try JSONDecoder().decode(MobileReviewedMatchResponse.self, from: data)
            .reviewedResolution()
    }

    var tracksForActiveProfile: [MobileTrack] {
        tracks.filter(belongsToActiveServerContext)
    }

    var filteredTracks: [MobileTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracksForActiveProfile }
        return tracksForActiveProfile.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    func fileURL(for track: MobileTrack) -> URL {
        return musicDirectory.appendingPathComponent(track.relativePath)
    }

    func artwork(for track: MobileTrack) -> UIImage? {
        guard let filename = track.artworkFilename else { return nil }
        if let cached = artworkCache[filename] { return cached }
        guard let image = UIImage(contentsOfFile: artworkDirectory.appendingPathComponent(filename).path) else { return nil }
        let squareImage = centerCroppedSquare(image)
        artworkCache[filename] = squareImage
        return squareImage
    }

    private func centerCroppedSquare(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let width = cgImage.width
        let height = cgImage.height
        let contentBounds = detectedArtworkContentBounds(in: cgImage)
        let side = min(contentBounds.width, contentBounds.height)
        let cropRect = CGRect(
            x: contentBounds.midX - side / 2,
            y: contentBounds.midY - side / 2,
            width: side,
            height: side
        ).integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard cropRect.width > 0, cropRect.height > 0 else { return image }
        if cropRect.width == CGFloat(width), cropRect.height == CGFloat(height) { return image }
        guard let croppedImage = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: croppedImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func detectedArtworkContentBounds(in image: CGImage) -> CGRect {
        let sourceWidth = image.width
        let sourceHeight = image.height
        let sampleScale = min(1, 160 / Double(max(sourceWidth, sourceHeight)))
        let sampleWidth = max(Int((Double(sourceWidth) * sampleScale).rounded()), 1)
        let sampleHeight = max(Int((Double(sourceHeight) * sampleScale).rounded()), 1)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return CGRect(x: 0, y: 0, width: CGFloat(sourceWidth), height: CGFloat(sourceHeight))
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(sampleWidth), height: CGFloat(sampleHeight)))

        struct LineStats {
            let channels: [Double]
            let deviation: Double
        }

        func stats(for offsets: [Int]) -> LineStats {
            guard !offsets.isEmpty else { return LineStats(channels: [0, 0, 0, 0], deviation: 255) }
            var totals = [Double](repeating: 0, count: bytesPerPixel)
            for offset in offsets {
                for channel in 0..<bytesPerPixel {
                    totals[channel] += Double(pixels[offset + channel])
                }
            }
            let means = totals.map { $0 / Double(offsets.count) }
            var totalDeviation = 0.0
            for offset in offsets {
                for channel in 0..<bytesPerPixel {
                    totalDeviation += abs(Double(pixels[offset + channel]) - means[channel])
                }
            }
            return LineStats(
                channels: means,
                deviation: totalDeviation / Double(offsets.count * bytesPerPixel)
            )
        }

        func rowStats(_ row: Int, xRange: Range<Int>) -> LineStats {
            stats(for: xRange.map { row * bytesPerRow + $0 * bytesPerPixel })
        }

        func columnStats(_ column: Int, yRange: Range<Int>) -> LineStats {
            stats(for: yRange.map { $0 * bytesPerRow + column * bytesPerPixel })
        }

        func colorDistance(_ lhs: LineStats, _ rhs: LineStats) -> Double {
            zip(lhs.channels, rhs.channels).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(bytesPerPixel)
        }

        func borderRun(lineCount: Int, statsAt: (Int) -> LineStats, fromStart: Bool) -> Int {
            guard lineCount >= 6 else { return 0 }
            let edgeIndex = fromStart ? 0 : lineCount - 1
            let reference = statsAt(edgeIndex)
            guard reference.deviation <= 10 else { return 0 }
            var count = 0
            for offset in 0..<(lineCount / 2) {
                let index = fromStart ? offset : lineCount - 1 - offset
                let candidate = statsAt(index)
                guard candidate.deviation <= 13, colorDistance(candidate, reference) <= 18 else { break }
                count += 1
            }
            return count
        }

        func symmetricInsets(_ first: Int, _ second: Int, length: Int) -> (Int, Int) {
            guard first >= 2, second >= 2, first + second < length * 3 / 4 else { return (0, 0) }
            let tolerance = max(2, min(first, second) / 3)
            guard abs(first - second) <= tolerance else { return (0, 0) }
            return (first, second)
        }

        let fullXRange = 0..<sampleWidth
        let firstRows = borderRun(
            lineCount: sampleHeight,
            statsAt: { rowStats($0, xRange: fullXRange) },
            fromStart: true
        )
        let lastRows = borderRun(
            lineCount: sampleHeight,
            statsAt: { rowStats($0, xRange: fullXRange) },
            fromStart: false
        )
        let (rowInsetStart, rowInsetEnd) = symmetricInsets(firstRows, lastRows, length: sampleHeight)
        let contentYRange = rowInsetStart..<(sampleHeight - rowInsetEnd)

        let firstColumns = borderRun(
            lineCount: sampleWidth,
            statsAt: { columnStats($0, yRange: contentYRange) },
            fromStart: true
        )
        let lastColumns = borderRun(
            lineCount: sampleWidth,
            statsAt: { columnStats($0, yRange: contentYRange) },
            fromStart: false
        )
        let (columnInsetStart, columnInsetEnd) = symmetricInsets(firstColumns, lastColumns, length: sampleWidth)

        let scaleX = CGFloat(sourceWidth) / CGFloat(sampleWidth)
        let scaleY = CGFloat(sourceHeight) / CGFloat(sampleHeight)
        return CGRect(
            x: CGFloat(columnInsetStart) * scaleX,
            y: CGFloat(rowInsetStart) * scaleY,
            width: CGFloat(sampleWidth - columnInsetStart - columnInsetEnd) * scaleX,
            height: CGFloat(sampleHeight - rowInsetStart - rowInsetEnd) * scaleY
        ).integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(sourceWidth), height: CGFloat(sourceHeight)))
    }

    func importFiles(_ urls: [URL]) async {
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let filename = uniqueFilename(source.lastPathComponent)
            let destination = musicDirectory.appendingPathComponent(filename)
            do {
                try fileManager.copyItem(at: source, to: destination)
                let audio = try AVAudioPlayer(contentsOf: destination)
                let metadata = await embeddedMetadata(at: destination)
                let trackID = UUID()
                tracks.append(MobileTrack(
                    id: trackID,
                    title: metadata.title ?? source.deletingPathExtension().lastPathComponent,
                    artist: metadata.artist ?? "Unknown Artist",
                    album: metadata.album ?? "Imported",
                    duration: metadata.duration ?? audio.duration,
                    relativePath: filename,
                    artworkFilename: saveArtwork(metadata.artworkData, for: trackID),
                    artworkScanComplete: true,
                    preservesUnlinkedImport: true
                ))
            } catch {
                try? fileManager.removeItem(at: destination)
            }
        }
        normalizeSystemPlaylist()
        if currentTrackID == nil { currentTrackID = tracksForActiveProfile.first?.id }
        save()
    }

    @discardableResult
    func associateLocalImportSource(
        trackID: UUID,
        source: LocalImportSourceAssociation,
        persistImmediately: Bool = true
    ) -> MobileTrack? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              !tracks[index].relativePath.isEmpty else { return nil }
        let sanitizedTrack = MobileTrackPersistencePolicy.sanitized(tracks[index])
        var changed = false
        if sanitizedTrack != tracks[index] {
            tracks[index] = sanitizedTrack
            changed = true
        }
        let sourceURL = MobileTrackPersistencePolicy.canonicalSourceURL(source.sourceURL)
        let legitimateServerOrigin = tracks[index].sourceServer.flatMap(URL.init(string:))
        let downloadSourceURL = MobileTrackPersistencePolicy.persistedDownloadSourceURL(
            source.downloadSourceURL,
            legitimateServerOrigin: legitimateServerOrigin
        )
        if let sourceURL, tracks[index].sourceURL != sourceURL {
            tracks[index].sourceURL = sourceURL
            changed = true
        }
        if let downloadSourceURL, tracks[index].downloadSourceURL != downloadSourceURL {
            tracks[index].downloadSourceURL = downloadSourceURL
            changed = true
        }
        if changed && persistImmediately { save() }
        return tracks[index]
    }

    @discardableResult
    func insertLocalImportedAudio(
        _ imported: LocalImportedAudio,
        persistImmediately: Bool = true
    ) throws -> MobileTrack {
        if let duplicate = tracks.first(where: {
            $0.sourceSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.contentSHA256
        }) {
            try? fileManager.removeItem(at: imported.fileURL)
            return associateLocalImportSource(
                trackID: duplicate.id,
                source: LocalImportSourceAssociation(
                    sourceURL: imported.metadata.sourceURL,
                    downloadSourceURL: imported.downloadSourceURL
                ),
                persistImmediately: persistImmediately
            ) ?? duplicate
        }

        let preferred = imported.fileURL.lastPathComponent
        let filename = uniqueFilename(preferred)
        let destination = musicDirectory.appendingPathComponent(filename)
        do {
            try fileManager.moveItem(at: imported.fileURL, to: destination)
            let id = UUID()
            let sourceURL = MobileTrackPersistencePolicy.canonicalSourceURL(imported.metadata.sourceURL)
            let downloadSourceURL = MobileTrackPersistencePolicy.persistedDownloadSourceURL(
                imported.downloadSourceURL
            )
            let track = MobileTrack(
                id: id,
                title: imported.metadata.title,
                artist: imported.metadata.artist,
                album: imported.metadata.album ?? "Imported",
                duration: imported.duration,
                relativePath: filename,
                sourceURL: sourceURL,
                downloadSourceURL: downloadSourceURL,
                artworkFilename: saveArtwork(imported.artworkData, for: id),
                artworkScanComplete: true,
                sourceSHA256: imported.sourceSHA256,
                contentSHA256: imported.contentSHA256,
                preservesUnlinkedImport: true
            )
            tracks.append(track)
            normalizeSystemPlaylist()
            if currentTrackID == nil { currentTrackID = track.id }
            if persistImmediately { save() }
            return track
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func clipRange(for track: MobileTrack) -> MobileClipRange? {
        clipRanges[clipRangeKey(for: track)]
    }

    func saveClipRange(for track: MobileTrack, start: TimeInterval, end: TimeInterval) {
        let maximum = max(0, track.duration)
        let lower = min(max(start, 0), maximum)
        let upper = min(max(end, 0), maximum)
        guard upper - lower >= 0.25 else { return }
        let key = clipRangeKey(for: track)
        clipRanges[key] = MobileClipRange(startSeconds: lower, endSeconds: upper)
        clipRangeMutationGeneration &+= 1
        if track.remoteID != nil {
            dirtyClipRangeKeys.insert(key)
            deletedClipRangeKeys.remove(key)
        }
        if currentTrackID == track.id, let player,
           player.currentTime < lower || player.currentTime >= upper {
            player.currentTime = lower
            position = lower
        }
        save()
        schedulePlaylistSync()
        updateNowPlaying()
    }

    func clearClipRange(for track: MobileTrack) {
        let key = clipRangeKey(for: track)
        guard clipRanges.removeValue(forKey: key) != nil else { return }
        clipRangeMutationGeneration &+= 1
        if track.remoteID != nil {
            dirtyClipRangeKeys.insert(key)
            deletedClipRangeKeys.insert(key)
        }
        save()
        schedulePlaylistSync()
        updateNowPlaying()
    }

    func playbackElapsed(for track: MobileTrack) -> TimeInterval {
        let bounds = playbackBounds(for: track)
        return min(max(position - bounds.start, 0), bounds.end - bounds.start)
    }

    func playbackDuration(for track: MobileTrack) -> TimeInterval {
        let bounds = playbackBounds(for: track)
        return max(bounds.end - bounds.start, 0.01)
    }

    func playbackProgress(for track: MobileTrack) -> Double {
        min(max(playbackElapsed(for: track) / playbackDuration(for: track), 0), 1)
    }

    func play(_ track: MobileTrack) {
        play(track, in: tracksForActiveProfile)
    }

    func play(_ track: MobileTrack, in queue: [MobileTrack], playlistID: UUID? = nil) {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        let queueIDs = queue.map(\.id)
        playbackQueue = queueIDs.contains(track.id) ? queueIDs : [track.id]
        playbackPlaylistID = playlistID
        history.removeAll()
        startPlayback(track)
    }

    func play(_ playlist: MobilePlaylist) {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        let queue = tracks(in: playlist)
        guard let first = shuffleEnabled ? queue.randomElement() : queue.first else { return }
        play(first, in: queue, playlistID: playlist.id)
    }

    func followListenAlongLocalTrack(
        _ track: MobileTrack,
        position: TimeInterval,
        isPlaying: Bool
    ) {
        listenAlongApplyingRemoteState = true
        defer { listenAlongApplyingRemoteState = false }
        if currentTrack?.id != track.id || isTransientStreamActive {
            playbackQueue = [track.id]
            playbackPlaylistID = nil
            startPlayback(track, recordHistory: false, startingAt: position)
        } else {
            applyListenAlongPlaybackPosition(position, isPlaying: isPlaying)
            return
        }
        if !isPlaying { pausePlayback() }
        updateNowPlaying()
    }

    func followListenAlongRemoteSong(
        _ song: MobileRemoteSong,
        position: TimeInterval,
        isPlaying: Bool
    ) async -> Bool {
        guard song.mediaKind == "audio", song.size > 0 else { return false }
        listenAlongApplyingRemoteState = true
        defer { listenAlongApplyingRemoteState = false }
        await streamRemoteSong(song)
        guard isTransientStreamActive,
              streamingTrack?.remoteID == song.id else { return false }
        applyListenAlongPlaybackPosition(position, isPlaying: isPlaying)
        return true
    }

    /// Applies a revision to an already-loaded transient stream without
    /// resolving or rebuilding the stream. Listen Along publishes play/pause
    /// and seek changes as new revisions, so the source identity is the only
    /// thing that needs to be checked before applying them locally.
    func followListenAlongCurrentStream(
        sourceIdentity: String?,
        position: TimeInterval,
        isPlaying: Bool
    ) -> Bool {
        guard isTransientStreamActive,
              streamingPlayer != nil,
              let track = streamingTrack,
              currentTrackID == track.id,
              let sourceURL = track.sourceURL,
              MobileListenAlongSourcePolicy.identity(sourceURL) == sourceIdentity else {
            return false
        }
        listenAlongApplyingRemoteState = true
        defer { listenAlongApplyingRemoteState = false }
        applyListenAlongPlaybackPosition(position, isPlaying: isPlaying)
        return true
    }

    func stopListenAlongPlaybackIfNeeded() {
        guard isTransientStreamActive else { return }
        discardStreamingPlayback()
    }

    func playListenAlongPreview(
        _ preview: LocalImportPreviewStream,
        sourceURL: String,
        title: String,
        artist: String,
        album: String,
        artworkURL: URL? = nil,
        duration: TimeInterval,
        position: TimeInterval,
        isPlaying: Bool
    ) async throws {
        guard let scheme = preview.url.scheme?.lowercased(), scheme == "https" else {
            throw MobileListenAlongError.invalidSource
        }
        guard preview.url.user == nil,
              preview.url.password == nil,
              preview.url.host?.isEmpty == false else {
            throw MobileListenAlongError.invalidSource
        }

        let departingLocalID = streamingTrack == nil ? currentTrackID : nil
        discardStreamingPlayback()
        if let departingLocalID,
           tracks.contains(where: { $0.id == departingLocalID }) {
            history.append(departingLocalID)
        }
        stopTimer()
        player?.stop()
        player = nil

        streamingGeneration &+= 1
        let generation = streamingGeneration
        let transientTrack = MobileTrack(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Listen Along" : title,
            artist: artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown Artist" : artist,
            album: album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Listen Along" : album,
            duration: max(duration, 0),
            relativePath: "",
            sourceURL: sourceURL,
            artworkScanComplete: true
        )
        streamingTrack = transientTrack
        streamingArtworkURL = artworkURL
        streamingPreview = preview
        streamingPreviewSourceURL = sourceURL
        isTransientStreamActive = true
        currentTrackID = transientTrack.id
        playbackQueue = [transientTrack.id]
        playbackPlaylistID = nil
        self.position = max(position, 0)
        UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")

        let asset: AVURLAsset
        if let contentLength = preview.contentLength,
           let contentType = preview.contentType {
            let loader = try MobileYouTubeStreamResourceLoader(
                sourceURL: preview.url,
                headers: preview.httpHeaders,
                contentLength: contentLength,
                contentType: contentType
            )
            asset = AVURLAsset(url: try MobileYouTubeStreamResourceLoader.assetURL(for: preview.url))
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            streamingYouTubeLoader = loader
        } else {
            var assetOptions: [String: Any] = [:]
            if !preview.httpHeaders.isEmpty {
                assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = preview.httpHeaders
            }
            asset = AVURLAsset(url: preview.url, options: assetOptions)
        }
        guard try await asset.load(.isPlayable) else {
            discardStreamingPlayback()
            throw MobileAuthenticatedStreamError.invalidResponse
        }
        let measuredDuration = try? await asset.load(.duration).seconds
        try Task.checkCancellation()

        let item = AVPlayerItem(asset: asset)
        let streamPlayer = AVPlayer(playerItem: item)
        streamPlayer.volume = PlaybackVolumePolicy.gain(for: volume)
        streamPlayer.defaultRate = playbackRate
        streamPlayer.automaticallyWaitsToMinimizeStalling = true
        streamingPlayer = streamPlayer
        if let measuredDuration,
           measuredDuration.isFinite,
           measuredDuration > 0 {
            streamingTrack?.duration = measuredDuration
        }
        streamingEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.authenticatedStreamDidFinish(item: item, generation: generation)
            }
        }
        streamingFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.authenticatedStreamDidFail(item: item, generation: generation, error: error)
            }
        }
        streamingStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, item.status == .failed else { return }
                self.authenticatedStreamDidFail(item: item, generation: generation, error: item.error)
            }
        }

        let streamBounds = playbackBounds(for: streamingTrack ?? transientTrack)
        let clampedPosition = min(max(position, streamBounds.start), streamBounds.end)
        if clampedPosition > streamBounds.start {
            await seekAuthenticatedStream(streamPlayer, to: clampedPosition)
        }
        try AVAudioSession.sharedInstance().setActive(true)
        if isPlaying {
            streamPlayer.playImmediately(atRate: playbackRate)
            self.isPlaying = true
            startTimer()
        } else {
            streamPlayer.pause()
            self.isPlaying = false
            stopTimer()
        }
        self.position = clampedPosition
        updateNowPlaying()
    }

    private func applyListenAlongPlaybackPosition(
        _ requestedPosition: TimeInterval,
        isPlaying requestedIsPlaying: Bool
    ) {
        guard let track = currentTrack else { return }
        let duration = isTransientStreamActive ? nil : player?.duration
        let bounds = playbackBounds(for: track, duration: duration)
        let target = min(max(requestedPosition.isFinite ? requestedPosition : 0, bounds.start), bounds.end)
        if isTransientStreamActive, let streamingPlayer {
            streamingPlayer.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if requestedIsPlaying {
                streamingPlayer.playImmediately(atRate: playbackRate)
                startTimer()
            } else {
                streamingPlayer.pause()
                stopTimer()
            }
        } else if let player {
            player.currentTime = target
            if requestedIsPlaying {
                player.rate = playbackRate
                _ = player.play()
                startTimer()
            } else {
                player.pause()
                stopTimer()
            }
        }
        position = target
        isPlaying = requestedIsPlaying
        updateNowPlaying()
    }

    func isPlaylistPlaying(_ playlist: MobilePlaylist) -> Bool {
        guard let currentTrackID else { return false }
        return isPlaying && playbackPlaylistID == playlist.id && playlist.trackIDs.contains(currentTrackID)
    }

    func isPlaylistPlaybackActive(_ playlist: MobilePlaylist) -> Bool {
        guard let currentTrackID else { return false }
        return playbackPlaylistID == playlist.id && playlist.trackIDs.contains(currentTrackID)
    }

    func togglePlayback(of playlist: MobilePlaylist) {
        if isPlaylistPlaybackActive(playlist), player != nil {
            togglePlay()
        } else {
            play(playlist)
        }
    }

    private func startPlayback(
        _ track: MobileTrack,
        recordHistory: Bool = true,
        startingAt requestedPosition: TimeInterval = 0
    ) {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        if currentTrackID != track.id || streamingTrack != nil {
            endListeningHistorySession()
        }
        stopTimer()
        cancelCrossfade()
        if streamingTrack != nil {
            discardStreamingPlayback()
        }
        if recordHistory, currentTrackID != track.id, let currentTrackID {
            history.append(currentTrackID)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: fileURL(for: track))
            next.delegate = self
            next.enableRate = true
            next.volume = PlaybackVolumePolicy.gain(for: volume)
            next.rate = playbackRate
            next.prepareToPlay()
            if let measuredDuration = MobilePlayableMediaDurationPolicy.preferred(
                storedDuration: track.duration,
                playableDurations: [next.duration]
            ), let trackIndex = tracks.firstIndex(where: { $0.id == track.id }),
               abs(tracks[trackIndex].duration - measuredDuration) > 0.25 {
                tracks[trackIndex].duration = measuredDuration
            }
            let bounds = playbackBounds(for: track, duration: next.duration)
            let clampedPosition = min(max(requestedPosition, bounds.start), bounds.end)
            let resumePosition = clampedPosition >= bounds.end ? bounds.start : clampedPosition
            next.currentTime = resumePosition
            guard next.play() else {
                isPlaying = false
                return
            }
            player = next
            currentTrackID = track.id
            let isTransientStream = streamingTrack?.id == track.id
            if isTransientStream {
                UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")
            } else {
                UserDefaults.standard.set(track.id.uuidString, forKey: "Resonance.currentTrack")
            }
            isPlaying = true
            position = resumePosition
            UserDefaults.standard.set(position, forKey: "Resonance.position")
            beginListeningHistorySession(for: track)
            startTimer()
            updateNowPlaying()
            if !isTransientStream { save() }
            notifyListenAlongPlaybackChanged()
        } catch {
            stopTimer()
            isPlaying = false
            updateNowPlaying()
        }
    }

    func togglePlay() {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        if player?.isPlaying == true
            || streamingPlayer?.timeControlStatus == .playing
            || isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        if isTransientStreamActive, let streamingPlayer {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                streamingPlayer.playImmediately(atRate: playbackRate)
                isPlaying = true
                if let streamingTrack { beginListeningHistorySession(for: streamingTrack) }
                startTimer()
            } catch {
                isPlaying = false
            }
            updateNowPlaying()
            notifyListenAlongPlaybackChanged()
            return
        }
        guard let player else {
            guard let track = currentTrack ?? tracksForActiveProfile.first else { return }
            if playbackQueue.isEmpty {
                playbackQueue = tracksForActiveProfile.map(\.id)
                playbackPlaylistID = nil
            }
            let resumePosition = track.id == currentTrackID ? position : 0
            startPlayback(track, recordHistory: false, startingAt: resumePosition)
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if let track = currentTrack {
                let bounds = playbackBounds(for: track, duration: player.duration)
                if player.currentTime < bounds.start || player.currentTime >= bounds.end {
                    player.currentTime = bounds.start
                    position = bounds.start
                }
            }
            player.rate = playbackRate
            isPlaying = player.play()
            if isPlaying {
                if let currentTrack { beginListeningHistorySession(for: currentTrack) }
                startTimer()
            }
        } catch {
            isPlaying = false
        }
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
    }

    func pausePlayback() {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        cancelCrossfade()
        if isTransientStreamActive, let streamingPlayer {
            streamingPlayer.pause()
            let currentTime = streamingPlayer.currentTime().seconds
            if currentTime.isFinite { position = max(currentTime, 0) }
            updateListeningHistorySession(flush: true)
            persistListeningHistory()
            scheduleListeningHistorySync()
            stopTimer()
            isPlaying = false
            updateNowPlaying()
            notifyListenAlongPlaybackChanged()
            return
        }
        if let player {
            player.pause()
            position = player.currentTime
            UserDefaults.standard.set(position, forKey: "Resonance.position")
        }
        updateListeningHistorySession(flush: true)
        persistListeningHistory()
        scheduleListeningHistorySync()
        stopTimer()
        isPlaying = false
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
    }

    func seek(to fraction: Double) {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        cancelCrossfade()
        if isTransientStreamActive,
           let streamingPlayer,
           let track = streamingTrack {
            let bounds = playbackBounds(for: track)
            let target = MobileClipPlaybackPolicy.position(
                fraction: fraction,
                within: .init(start: bounds.start, end: bounds.end)
            )
            position = target
            streamingPlayer.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            updateNowPlaying()
            notifyListenAlongPlaybackChanged()
            return
        }
        guard let player, let track = currentTrack else { return }
        let bounds = playbackBounds(for: track, duration: player.duration)
        player.currentTime = bounds.start + (bounds.end - bounds.start) * min(max(fraction, 0), 1)
        position = player.currentTime
        UserDefaults.standard.set(position, forKey: "Resonance.position")
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
    }

    private func seek(toElapsedTime elapsedTime: TimeInterval) {
        guard let track = currentTrack else { return }
        let duration = isTransientStreamActive ? nil : player?.duration
        let bounds = playbackBounds(for: track, duration: duration)
        seek(to: MobileNowPlayingPolicy.seekFraction(
            elapsedTime: elapsedTime,
            bounds: .init(start: bounds.start, end: bounds.end)
        ))
    }

    func next() {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        guard !isTransientStreamActive else { return }
        let queue = activeQueue
        guard !queue.isEmpty else { return }
        if shuffleEnabled, let next = queue.filter({ $0.id != currentTrackID }).randomElement() ?? queue.first {
            startPlayback(next)
            return
        }
        let index = queue.firstIndex { $0.id == currentTrackID } ?? -1
        startPlayback(queue[(index + 1) % queue.count])
    }

    func previous() {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        guard !isTransientStreamActive else { return }
        if let player, let track = currentTrack {
            let bounds = playbackBounds(for: track, duration: player.duration)
            if player.currentTime > bounds.start + 3 {
                player.currentTime = bounds.start
                position = bounds.start
                updateNowPlaying()
                notifyListenAlongPlaybackChanged()
                return
            }
        }

        let queue = activeQueue
        guard !queue.isEmpty else { return }
        if shuffleEnabled,
           let previousID = history.popLast(),
           let track = queue.first(where: { $0.id == previousID }) {
            startPlayback(track, recordHistory: false)
            return
        }

        let index = queue.firstIndex { $0.id == currentTrackID } ?? 0
        startPlayback(queue[(index - 1 + queue.count) % queue.count], recordHistory: false)
    }

    private func advanceAfterFinishing() {
        endListeningHistorySession()
        stopTimer()
        guard let track = currentTrack else {
            completePlaybackAtQueueEnd()
            return
        }
        if repeatEnabled {
            startPlayback(track, recordHistory: false)
            return
        }

        let queue = activeQueue
        guard !queue.isEmpty else {
            completePlaybackAtQueueEnd()
            return
        }
        if shuffleEnabled {
            let nextTrack = queue.filter({ $0.id != currentTrackID }).randomElement() ?? queue[0]
            startPlayback(nextTrack)
            return
        }

        let index = queue.firstIndex(where: { $0.id == currentTrackID }) ?? -1
        guard let nextIndex = MobileQueueCompletionPolicy.nextIndex(
            count: queue.count,
            currentIndex: index
        ) else { return }
        startPlayback(queue[nextIndex])
    }

    private func completePlaybackAtQueueEnd() {
        endListeningHistorySession()
        stopTimer()
        let start = currentTrack.map { playbackBounds(for: $0).start } ?? 0
        player?.currentTime = start
        position = start
        UserDefaults.standard.set(position, forKey: "Resonance.position")
        isPlaying = false
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
    }

    private var activeQueue: [MobileTrack] {
        var playableTracks = tracksForActiveProfile
        if let streamingTrack { playableTracks.append(streamingTrack) }
        let activeTrackIDs = Set(playableTracks.map(\.id))
        let queuedTracks: [MobileTrack] = playbackQueue.compactMap { id in
            guard activeTrackIDs.contains(id) else { return nil }
            return playableTracks.first { $0.id == id }
        }
        if playbackPlaylistID != nil { return queuedTracks }
        return queuedTracks.isEmpty ? playableTracks : queuedTracks
    }

    func toggleFavorite(_ track: MobileTrack) {
        guard streamingTrack?.id != track.id else {
            showTransferNotice(
                title: "Stream is temporary",
                detail: "Download the song before adding it to Liked Songs.",
                isError: false
            )
            return
        }
        let willLike = !favorites.contains(track.id)
        if willLike { favorites.insert(track.id) } else { favorites.remove(track.id) }
        if let remoteID = track.remoteID {
            likesMutationGeneration &+= 1
            if willLike { remoteLikedSongIDs.insert(remoteID) } else { remoteLikedSongIDs.remove(remoteID) }
            dirtyRemoteLikeSongIDs.insert(remoteID)
            likesDirty = true
        }
        normalizeSystemPlaylist()
        save()
        schedulePlaylistSync()
    }

    func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = MobilePlaylist(name: trimmed, remoteSongIDs: [])
        playlists.append(playlist)
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.insert(playlist.id)
        save()
        schedulePlaylistSync()
    }

    func deletePlaylist(_ playlist: MobilePlaylist) {
        guard !playlist.isSystem,
              playlists.contains(where: { $0.id == playlist.id }) else { return }

        playlists.removeAll { $0.id == playlist.id }
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.remove(playlist.id)
        deletedPlaylistIDs.insert(playlist.id)

        if playbackPlaylistID == playlist.id {
            playbackPlaylistID = nil
            playbackQueue = tracksForActiveProfile.map(\.id)
        }

        save()
        schedulePlaylistSync()
    }

    func add(_ track: MobileTrack, to playlist: MobilePlaylist) {
        guard streamingTrack?.id != track.id else {
            showTransferNotice(
                title: "Stream is temporary",
                detail: "Download the song before adding it to a playlist.",
                isError: false
            )
            return
        }
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }), !playlists[index].isSystem else { return }
        if !playlists[index].trackIDs.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            updateRemoteSongIDs(forPlaylistAt: index)
            playlistMutationGeneration &+= 1
            dirtyPlaylistIDs.insert(playlist.id)
            if playbackPlaylistID == playlist.id {
                playbackQueue = playlists[index].trackIDs
            }
        }
        save()
        schedulePlaylistSync()
    }

    func upsertImportedPlaylist(named rawName: String, tracks importedTracks: [MobileTrack]) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedIDs = importedTracks.map(\.id)
        guard !name.isEmpty, !importedIDs.isEmpty else { return }
        let index: Int
        if let existing = playlists.firstIndex(where: {
            !$0.isSystem && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            index = existing
        } else {
            playlists.append(MobilePlaylist(name: name, remoteSongIDs: []))
            index = playlists.index(before: playlists.endIndex)
        }
        var seen = Set(playlists[index].trackIDs)
        playlists[index].trackIDs.append(contentsOf: importedIDs.filter { seen.insert($0).inserted })
        updateRemoteSongIDs(forPlaylistAt: index)
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.insert(playlists[index].id)
        save()
        schedulePlaylistSync()
    }

    func remove(_ track: MobileTrack, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        if playlists[index].isSystem {
            guard favorites.contains(track.id) else { return }
            toggleFavorite(track)
            if playbackPlaylistID == playlistID,
               let refreshed = playlists.first(where: { $0.id == playlistID }) {
                playbackQueue = refreshed.trackIDs
            }
            return
        }
        guard playlists[index].trackIDs.contains(track.id) else { return }
        playlists[index].trackIDs.removeAll { $0 == track.id }
        updateRemoteSongIDs(forPlaylistAt: index)
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.insert(playlistID)
        if playbackPlaylistID == playlistID {
            playbackQueue = playlists[index].trackIDs
        }
        save()
        schedulePlaylistSync()
    }

    func moveTracks(in playlistID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[playlistIndex].isSystem else { return }

        var orderedIDs = playlists[playlistIndex].trackIDs
        let validOffsets = source.filter { orderedIDs.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }

        let movingIDs = validOffsets.map { orderedIDs[$0] }
        for offset in validOffsets.reversed() {
            orderedIDs.remove(at: offset)
        }

        let removedBeforeDestination = validOffsets.count { $0 < destination }
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), orderedIDs.count)
        orderedIDs.insert(contentsOf: movingIDs, at: insertionIndex)
        playlists[playlistIndex].trackIDs = orderedIDs
        updateRemoteSongIDs(forPlaylistAt: playlistIndex)
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.insert(playlistID)

        if playbackPlaylistID == playlistID {
            playbackQueue = orderedIDs
        }
        save()
        schedulePlaylistSync()
    }

    func movePlaylistEntries(in playlistID: UUID, fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[playlistIndex].isSystem else { return }

        let entries = playlistEntries(in: playlists[playlistIndex])
        let reordered = MobilePlaylistPresentationMovePolicy.move(
            entries,
            fromOffsets: source,
            toOffset: destination
        )
        guard reordered.map(\.id) != entries.map(\.id) else { return }

        let persisted = MobilePlaylistPresentationMovePolicy.persistedOrder(for: reordered)
        playlists[playlistIndex].trackIDs = persisted.trackIDs
        playlists[playlistIndex].remoteSongIDs = persisted.remoteSongIDs
        playlists[playlistIndex].entryOrder = persisted.entryOrder
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.insert(playlistID)

        if playbackPlaylistID == playlistID {
            playbackQueue = persisted.trackIDs
        }
        save()
        schedulePlaylistSync()
    }

    func tracks(in playlist: MobilePlaylist) -> [MobileTrack] {
        playlist.trackIDs.compactMap { id in tracks.first { $0.id == id } }
    }

    func playlistEntries(in playlist: MobilePlaylist) -> [MobilePlaylistPresentationEntry] {
        MobilePlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: tracks,
            remoteSongs: remoteSongs
        )
    }

    func playlistEntryCount(_ playlist: MobilePlaylist) -> Int {
        playlistEntries(in: playlist).count
    }

    func remove(_ track: MobileTrack) {
        let removedClipKey = clipRangeKey(for: track)
        let removedCurrentTrack = currentTrackID == track.id
        if removedCurrentTrack {
            stopTimer()
            player?.stop()
            player = nil
            isPlaying = false
        }
        let authoritativeSongIDs = authoritativeCatalogSongIDs
        let remoteBacking = MobileLocalTrackRemovalAuthorityPolicy.resolve(
            track: track,
            activeContext: activeServerContext,
            catalogIsAuthoritative: authoritativeSongIDs != nil,
            catalogRemoteSongIDs: authoritativeSongIDs ?? []
        )
        var changedRemotePlaylistMembership = false
        for index in playlists.indices where !playlists[index].isSystem {
            guard playlists[index].trackIDs.contains(track.id) else { continue }
            let presentationOrder = playlistEntries(in: playlists[index]).map(\.id)
            let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
                trackID: track.id,
                remoteSongID: remoteBacking.remoteSongID,
                remoteBackingAuthority: remoteBacking.authority,
                from: playlists[index],
                presentationOrder: presentationOrder
            )
            playlists[index] = result.playlist
            if result.remoteMembershipChanged {
                dirtyPlaylistIDs.insert(playlists[index].id)
                changedRemotePlaylistMembership = true
            }
        }
        try? fileManager.removeItem(at: fileURL(for: track))
        if let artworkFilename = track.artworkFilename {
            try? fileManager.removeItem(at: artworkDirectory.appendingPathComponent(artworkFilename))
            artworkCache.removeValue(forKey: artworkFilename)
        }
        tracks.removeAll { $0.id == track.id }
        playbackQueue.removeAll { $0 == track.id }
        history.removeAll { $0 == track.id }
        favorites.remove(track.id)
        if changedRemotePlaylistMembership {
            playlistMutationGeneration &+= 1
            schedulePlaylistSync()
        }
        clipRanges.removeValue(forKey: removedClipKey)
        dirtyClipRangeKeys.remove(removedClipKey)
        deletedClipRangeKeys.remove(removedClipKey)
        if removedCurrentTrack {
            currentTrackID = tracksForActiveProfile.first?.id
            position = 0
            UserDefaults.standard.set(position, forKey: "Resonance.position")
            if let currentTrackID {
                UserDefaults.standard.set(currentTrackID.uuidString, forKey: "Resonance.currentTrack")
            } else {
                UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")
            }
            updateNowPlaying()
        }
        normalizeSystemPlaylist()
        save()
    }

    func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        await refreshClientConfiguration()
        await syncCatalog()
        await syncPlaylistsNow()
    }
    func downloadSelected() async {
        guard !selectedRemoteSongIDs.isEmpty else { downloadDetail = "Select one or more songs first"; return }
        guard activeDownloadMode == .verifiedFileCache else {
            downloadDetail = "Stream-only mode plays one song at a time. Tap a song to stream it."
            showTransferNotice(title: "Offline download is off", detail: downloadDetail, isError: false)
            return
        }
        let requestedSongIDs = selectedRemoteSongIDs
        let pendingSongs = pendingLoadedCatalogSongs(requestedSongIDs: requestedSongIDs)
        guard !pendingSongs.isEmpty else {
            downloadDetail = "All requested songs are already on this device"
            selectedRemoteSongIDs.subtract(requestedSongIDs)
            showTransferNotice(title: "Already downloaded", detail: downloadDetail, isError: false)
            return
        }
        await downloadLoadedCatalogSongs(pendingSongs)
    }
    func download(_ song: MobileRemoteSong) async {
        guard !listenAlongLocalPlaybackIsLocked else { return }
        if activeDownloadMode == .streamOnly {
            await streamRemoteSong(song)
            return
        }
        guard activeDownloadMode == .verifiedFileCache else {
            showTransferNotice(
                title: "Download unavailable",
                detail: "The active server policy does not allow an offline or streaming transfer.",
                isError: true
            )
            return
        }
        guard !isSynced(song) else {
            downloadDetail = "\(song.title) is already on this device"
            showTransferNotice(title: "Already downloaded", detail: downloadDetail, isError: false)
            return
        }
        await downloadLoadedCatalogSongs([song])
    }
    func downloadAll() async {
        guard activeDownloadMode != .streamOnly else {
            downloadDetail = "Stream-only mode does not save the server library. Tap a song to stream it."
            showTransferNotice(title: "Offline download is off", detail: downloadDetail, isError: false)
            return
        }
        let pendingSongs = pendingLoadedCatalogSongs(requestedSongIDs: nil)
        guard !pendingSongs.isEmpty else {
            downloadDetail = "All server songs are already on this device"
            showTransferNotice(title: "Already downloaded", detail: downloadDetail, isError: false)
            return
        }
        await downloadLoadedCatalogSongs(pendingSongs)
    }

    private func beginDownloadTransfer() -> UUID? {
        reserveTransferSession(kind: .download, requiresReceivedBytes: true)
    }

    private func pendingLoadedCatalogSongs(
        requestedSongIDs: Set<String>?
    ) -> [MobileRemoteSong] {
        let syncedSongIDs = Set(remoteSongs.lazy.filter { self.isSynced($0) }.map(\.id))
        return MobileLoadedCatalogDownloadPolicy.pendingSongs(
            from: remoteSongs,
            requestedSongIDs: requestedSongIDs,
            syncedSongIDs: syncedSongIDs
        )
    }

    /// Downloads the immutable rows the user can already see. Catalog refresh
    /// and metadata hydration are deliberately not awaited here; reconciliation
    /// happens only after the media batch has released its transfer session.
    private func downloadLoadedCatalogSongs(_ songs: [MobileRemoteSong]) async {
        guard !songs.isEmpty,
              !isActivatingSyncProfile,
              let baseURL = normalizedServer(),
              let submittedContext = activeServerContext,
              !serverToken.isEmpty else {
            downloadDetail = "Sign in to your Resonance account first."
            showTransferNotice(title: "Download unavailable", detail: downloadDetail, isError: true)
            return
        }
        guard let downloadPolicyLease = captureDownloadPolicyLease(.verifiedFileCache) else {
            downloadDetail = "Verified offline downloads are no longer enabled by the signed server policy"
            showTransferNotice(title: "Download policy changed", detail: downloadDetail, isError: true)
            return
        }
        let submittedProfileID = syncProfileID
        let submittedAccessToken = serverToken
        guard let transferSessionID = beginDownloadTransfer() else { return }

        await downloadSerialGate.acquire()
        let ownsTransfer = MobileTransferSessionPolicy.accepts(
            transferSessionID,
            activeSessionID: activeTransferSessionID
        )
        if !isActivatingSyncProfile,
           ownsTransfer,
           submittedContext == activeServerContext,
           submittedProfileID == syncProfileID,
           submittedAccessToken == serverToken,
           isDownloadPolicyLeaseCurrent(downloadPolicyLease) {
            let batchID = UUID()
            let batchTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performLoadedCatalogDownload(
                    songs,
                    baseURL: baseURL,
                    profileID: submittedProfileID,
                    accessToken: submittedAccessToken,
                    downloadPolicyLease: downloadPolicyLease,
                    transferSessionID: transferSessionID
                )
            }
            activeDownloadBatch = (batchID, batchTask)
            await batchTask.value
            if activeDownloadBatch?.id == batchID {
                activeDownloadBatch = nil
            }
        }
        await downloadSerialGate.release()
        finishTransferSession(transferSessionID)

        // The transfer is complete and its popup is gone before playlist
        // reconciliation begins. Do not refetch the unchanged song catalog
        // here: that would cancel and restart metadata hydration which may
        // already be ready to update one of the newly saved tracks.
        guard submittedContext == activeServerContext,
              submittedProfileID == syncProfileID,
              submittedAccessToken == serverToken else { return }
        await syncPlaylistsNow()
    }

    private func performLoadedCatalogDownload(
        _ songs: [MobileRemoteSong],
        baseURL: URL,
        profileID: String,
        accessToken: String,
        downloadPolicyLease: MobileTransferPolicyLease,
        transferSessionID: UUID
    ) async {
        let results = await downloadRemoteSongs(
            songs,
            baseURL: baseURL,
            profileID: profileID,
            accessToken: accessToken,
            downloadPolicyLease: downloadPolicyLease,
            transferSessionID: transferSessionID
        )
        var completed = 0
        var failed = 0
        var downloadedSongIDs = Set<String>()
        var policyChanged = false
        var cancelled = false
        for result in results {
            switch result {
            case .downloaded(let songID):
                downloadedSongIDs.insert(songID)
                completed += 1
            case .failed(let songID, let title, let reason):
                failed += 1
                recordTransferFailure(
                    .download,
                    item: title,
                    reason: reason,
                    retryTarget: .download(remoteSongID: songID)
                )
            case .policyChanged:
                policyChanged = true
            case .cancelled:
                cancelled = true
            }
        }

        if policyChanged || cancelled {
            commitDownloadCheckpoint(downloadedSongIDs)
            if policyChanged {
                downloadDetail = "Download stopped because the signed policy changed after \(completed) completed"
                serverMessage = downloadDetail
                showTransferNotice(
                    title: "Download policy changed",
                    detail: downloadDetail,
                    isError: true
                )
            } else {
                downloadDetail = "Download cancelled after \(completed) completed"
                serverMessage = downloadDetail
            }
            return
        }

        normalizeSystemPlaylist()
        hydrateRemotePlaylistTracks()
        hydrateRemoteLikedTracks()
        save()
        selectedRemoteSongIDs.subtract(downloadedSongIDs)
        if failed == 0 {
            downloadDetail = "Downloaded \(completed) song\(completed == 1 ? "" : "s")"
            serverMessage = "Synced \(completed) song\(completed == 1 ? "" : "s")"
        } else {
            downloadDetail = "Downloaded \(completed) of \(songs.count) • \(failed) failed"
            serverMessage = completed == 0
                ? "Download failed. No songs were added."
                : "Synced \(completed) song\(completed == 1 ? "" : "s"); \(failed) failed"
        }
    }

    func toggleRemoteSelection(_ song: MobileRemoteSong) {
        if selectedRemoteSongIDs.contains(song.id) { selectedRemoteSongIDs.remove(song.id) }
        else { selectedRemoteSongIDs.insert(song.id) }
    }

    func isSynced(_ song: MobileRemoteSong) -> Bool {
        guard let activeServerContext else { return false }
        let expected = MobileRemoteIdentity(context: activeServerContext, remoteID: song.id)
        return tracks.contains { $0.remoteIdentity() == expected }
    }

    private func syncCatalog() async {
        guard !isActivatingSyncProfile else { return }
        let submittedContext = activeServerContext
        await downloadSerialGate.acquire()
        guard !isActivatingSyncProfile,
              submittedContext == activeServerContext else {
            await downloadSerialGate.release()
            return
        }
        await performCatalogSync()
        await downloadSerialGate.release()
    }

    private func remoteSourceResolution(for song: MobileRemoteSong) async throws -> LocalImportResolution {
        guard let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { throw SourceLinkRequiredError() }
        let mediaMode = LocalImportMediaMode(rawValue: song.mediaKind) ?? .audio
        // Media acquisition uses the catalog row immediately. Provider
        // metadata hydration is a separate background concern and must never
        // sit in front of the first audio request.
        let currentSong = remoteSongs.first(where: { $0.id == song.id }) ?? song
        let cachedMetadata = remoteSongMetadataCacheKey(for: currentSong)
            .flatMap { remoteSongMetadataCache[$0]?.metadata }
        let knownCatalogMetadata = MobileRemoteSourceMetadataReusePolicy.knownTrack(for: currentSong)
            ?? cachedMetadata
            ?? MobileRemoteSourceMetadataReusePolicy.acquisitionTrack(for: currentSong)
        guard let cacheKey = MobileRemoteSourceResolutionCachePolicy.key(
            context: activeServerContext,
            accountScope: accountSession?.accountID,
            mediaKind: song.mediaKind,
            sourceURL: source
        ) else { throw URLError(.unsupportedURL) }
        if let cached = remoteSourceResolutions[cacheKey],
           MobileRemoteSourceResolutionCachePolicy.canReuse(
            cached,
            cachedKey: cacheKey,
            expectedKey: cacheKey,
            knownCatalogMetadata: knownCatalogMetadata
           ) {
            return cached
        }
        remoteSourceResolutions.removeValue(forKey: cacheKey)
        let resolution: LocalImportResolution
        let acquisitionMetadata: LocalImportSpotifyTrack
        if let knownCatalogMetadata {
            acquisitionMetadata = knownCatalogMetadata
        } else if LocalImportURL.isSpotify(source) {
            // Spotify's audio search needs exact title/artist terms. Share only
            // that necessary provider request when the server row has not been
            // hydrated yet; the transfer remains invisible until audio bytes.
            guard let metadataCacheKey = remoteSongMetadataCacheKey(for: currentSong),
                  let resolvedMetadata = try await remoteMetadataResolutionBroker.resolve(
                    scope: remoteSongMetadataHydrationGeneration,
                    cacheKey: metadataCacheKey,
                   source: source,
                   using: remoteMetadataImportService
                  ) else { throw SourceLinkRequiredError() }
            try Task.checkCancellation()
            acquisitionMetadata = resolvedMetadata
            remoteSongMetadataCache[metadataCacheKey] = MobileRemoteSongMetadataCacheEntry(
                sourceURL: source,
                mediaKind: currentSong.mediaKind,
                metadata: acquisitionMetadata,
                cachedAt: Date()
            )
            if let index = remoteSongs.firstIndex(where: { $0.id == song.id }) {
                remoteSongs[index] = Self.applying(acquisitionMetadata, to: remoteSongs[index])
            }
            applyResolvedRemoteMetadata(acquisitionMetadata, songIDs: [song.id])
            save()
        } else {
            throw SourceLinkRequiredError()
        }
        resolution = try await serverLinkImportService.resolveUsingCatalogMetadata(
            source: source,
            metadata: acquisitionMetadata,
            mediaMode: mediaMode
        ) { _ in }
        guard resolution.playlist == nil else { throw URLError(.cannotParseResponse) }
        remoteSourceResolutions[cacheKey] = resolution
        return resolution
    }

    private func applyingKnownRemoteSongMetadata(
        to songs: [MobileRemoteSong]
    ) -> [MobileRemoteSong] {
        let localTracksByRemoteID = tracks.reduce(into: [String: MobileTrack]()) { result, track in
            guard belongsToActiveServerContext(track),
                  let remoteID = track.remoteID,
                  result[remoteID] == nil else { return }
            result[remoteID] = track
        }
        return songs.map { song in
            guard song.isMetadataLoading else { return song }
            if let localTrack = localTracksByRemoteID[song.id] {
                var updated = song
                updated.title = localTrack.title
                updated.artist = localTrack.artist
                updated.album = localTrack.album
                updated.duration = localTrack.duration
                updated.isMetadataLoading = false
                return updated
            }
            guard let cacheKey = remoteSongMetadataCacheKey(for: song) else {
                return Self.applyingRemoteMetadataFailure(to: song)
            }
            if let cached = remoteSongMetadataCache[cacheKey] {
                return Self.applying(cached.metadata, to: song)
            }
            guard let resolutionKey = MobileRemoteSourceResolutionCachePolicy.key(
                context: activeServerContext,
                accountScope: accountSession?.accountID,
                mediaKind: song.mediaKind,
                sourceURL: song.sourceURL
            ), let resolution = remoteSourceResolutions[resolutionKey],
               MobileRemoteSourceResolutionCachePolicy.canReuse(
                resolution,
                cachedKey: resolutionKey,
                expectedKey: resolutionKey,
                knownCatalogMetadata: nil
               ) else { return song }
            return Self.applying(resolution.track, to: song)
        }
    }

    private func beginRemoteSongMetadataHydration(baseURL: URL, profileID: String) {
        cancelRemoteSongMetadataHydration()
        let requests = remoteSongMetadataRequests(for: remoteSongs)
        pendingRemoteSongMetadataCount = requests.reduce(0) { $0 + $1.songIDs.count }
        guard !requests.isEmpty else { return }

        remoteSongMetadataHydrationGeneration &+= 1
        let generation = remoteSongMetadataHydrationGeneration
        remoteSongMetadataHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await hydrateRemoteSongMetadata(
                requests,
                generation: generation,
                baseURL: baseURL,
                profileID: profileID
            )
        }
    }

    private func hydrateRemoteSongMetadata(
        _ requests: [RemoteSongMetadataRequest],
        generation: UInt64,
        baseURL: URL,
        profileID: String
    ) async {
        var pendingRequests = requests
        var attempt = 0
        var didUpdateCache = false
        defer {
            if didUpdateCache {
                remoteSongMetadataCache = MobileRemoteSongMetadataCachePolicy.normalized(
                    remoteSongMetadataCache
                )
                save()
            }
            if remoteSongMetadataHydrationGeneration == generation {
                pendingRemoteSongMetadataCount = 0
                remoteSongMetadataHydrationTask = nil
            }
        }

        // Keep provider enrichment on its own actor/session set so a slow
        // metadata request cannot serialize the media acquisition service.
        let service = remoteMetadataImportService
        let metadataBroker = remoteMetadataResolutionBroker
        while !pendingRequests.isEmpty,
              attempt < MobileRemoteMetadataRetryPolicy.maximumImmediateAttempts {
            attempt += 1
            var remainingCount = pendingRequests.reduce(0) { $0 + $1.songIDs.count }
            await withTaskGroup(of: RemoteSongMetadataResult.self) { group in
                var iterator = pendingRequests.makeIterator()
                var bufferedResults: [RemoteSongMetadataResult] = []
                for _ in 0..<min(4, pendingRequests.count) {
                    guard let request = iterator.next() else { break }
                    group.addTask {
                        await Self.resolveRemoteSongMetadata(
                            request,
                            scope: generation,
                            using: service,
                            broker: metadataBroker
                        )
                    }
                }

                while let result = await group.next() {
                    guard isCurrentRemoteMetadataHydration(
                        generation: generation,
                        baseURL: baseURL,
                        profileID: profileID
                    ) else {
                        group.cancelAll()
                        return
                    }
                    bufferedResults.append(result)
                    remainingCount = max(0, remainingCount - result.request.songIDs.count)
                    if bufferedResults.count >= 4 || remainingCount == 0 {
                        var updatedSongs = remoteSongs
                        for bufferedResult in bufferedResults {
                            didUpdateCache = applyRemoteSongMetadataResult(
                                bufferedResult,
                                to: &updatedSongs
                            ) || didUpdateCache
                        }
                        remoteSongs = updatedSongs
                        bufferedResults.removeAll(keepingCapacity: true)
                    }
                    if let request = iterator.next() {
                        group.addTask {
                            await Self.resolveRemoteSongMetadata(
                                request,
                                scope: generation,
                                using: service,
                                broker: metadataBroker
                            )
                        }
                    }
                }
            }

            guard isCurrentRemoteMetadataHydration(
                generation: generation,
                baseURL: baseURL,
                profileID: profileID
            ) else { return }

            pendingRequests = remoteSongMetadataRequests(for: remoteSongs)
            pendingRemoteSongMetadataCount = pendingRequests.reduce(0) { $0 + $1.songIDs.count }
            guard !pendingRequests.isEmpty,
                  attempt < MobileRemoteMetadataRetryPolicy.maximumImmediateAttempts else { break }

            do {
                try await Task.sleep(
                    for: .seconds(MobileRemoteMetadataRetryPolicy.delaySeconds(afterFailureCount: attempt))
                )
            } catch {
                return
            }
        }

        if isCurrentRemoteMetadataHydration(
            generation: generation,
            baseURL: baseURL,
            profileID: profileID
        ) {
            await backfillDownloadedArtwork(from: remoteSongs, baseURL: baseURL)
        }
    }

    private func remoteSongMetadataRequests(
        for songs: [MobileRemoteSong]
    ) -> [RemoteSongMetadataRequest] {
        var requests: [RemoteSongMetadataRequest] = []
        var requestIndexByCacheKey: [String: Int] = [:]
        for song in songs where song.isMetadataLoading {
            guard let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !source.isEmpty,
                  let cacheKey = remoteSongMetadataCacheKey(for: song) else { continue }
            if let requestIndex = requestIndexByCacheKey[cacheKey] {
                let existing = requests[requestIndex]
                requests[requestIndex] = RemoteSongMetadataRequest(
                    songIDs: existing.songIDs + [song.id],
                    cacheKey: existing.cacheKey,
                    source: existing.source,
                    mediaKind: existing.mediaKind
                )
            } else {
                requestIndexByCacheKey[cacheKey] = requests.count
                requests.append(RemoteSongMetadataRequest(
                    songIDs: [song.id],
                    cacheKey: cacheKey,
                    source: source,
                    mediaKind: song.mediaKind
                ))
            }
        }
        return requests
    }

    private func applyRemoteSongMetadataResult(
        _ result: RemoteSongMetadataResult,
        to songs: inout [MobileRemoteSong]
    ) -> Bool {
        if let metadata = result.metadata {
            remoteSongMetadataCache[result.request.cacheKey] = MobileRemoteSongMetadataCacheEntry(
                sourceURL: result.request.source,
                mediaKind: result.request.mediaKind,
                metadata: metadata,
                cachedAt: Date()
            )
        }
        let songIDs = Set(result.request.songIDs)
        for index in songs.indices
        where songIDs.contains(songs[index].id) && songs[index].isMetadataLoading {
            if let metadata = result.metadata {
                songs[index] = Self.applying(metadata, to: songs[index])
            } else {
                songs[index] = Self.applyingRemoteMetadataFailure(to: songs[index])
            }
        }
        if let metadata = result.metadata {
            applyResolvedRemoteMetadata(metadata, songIDs: songIDs)
            if let display = transferDisplay,
               display.kind == .download,
               songIDs.contains(display.itemID),
               display.completedBytes > 0 {
                publishTransfer(MobileTransferDisplayState(
                    kind: display.kind,
                    itemID: display.itemID,
                    songTitle: metadata.title,
                    detail: display.detail,
                    currentItem: display.currentItem,
                    totalItems: display.totalItems,
                    completedBytes: display.completedBytes,
                    totalBytes: display.totalBytes,
                    fallbackProgress: display.fallbackProgress
                ))
            }
        }
        return result.metadata != nil
    }

    private func applyResolvedRemoteMetadata(
        _ metadata: LocalImportSpotifyTrack,
        songIDs: Set<String>
    ) {
        var changed = false
        for index in tracks.indices {
            guard let remoteID = tracks[index].remoteID,
                  songIDs.contains(remoteID),
                  belongsToActiveServerContext(tracks[index]) else { continue }
            if tracks[index].title != metadata.title {
                tracks[index].title = metadata.title
                changed = true
            }
            if tracks[index].artist != metadata.artist {
                tracks[index].artist = metadata.artist
                changed = true
            }
            if let album = metadata.album, tracks[index].album != album {
                tracks[index].album = album
                changed = true
            }
            if tracks[index].duration <= 0,
               let duration = metadata.durationSeconds.map(TimeInterval.init),
               abs(tracks[index].duration - duration) > 0.5 {
                tracks[index].duration = duration
                changed = true
            }
        }
        if changed {
            updateNowPlaying()
        }
    }

    private func remoteSongMetadataCacheKey(for song: MobileRemoteSong) -> String? {
        guard let sourceURL = song.sourceURL else { return nil }
        return MobileRemoteSongMetadataCachePolicy.key(
            sourceURL: sourceURL,
            mediaKind: song.mediaKind
        )
    }

    private func isCurrentRemoteMetadataHydration(
        generation: UInt64,
        baseURL: URL,
        profileID: String
    ) -> Bool {
        generation == remoteSongMetadataHydrationGeneration
            && isCurrentServerContext(baseURL: baseURL, profileID: profileID)
    }

    private func cancelRemoteSongMetadataHydration() {
        let cancelledGeneration = remoteSongMetadataHydrationGeneration
        remoteSongMetadataHydrationTask?.cancel()
        remoteSongMetadataHydrationTask = nil
        remoteSongMetadataHydrationGeneration &+= 1
        pendingRemoteSongMetadataCount = 0
        let metadataBroker = remoteMetadataResolutionBroker
        Task {
            await metadataBroker.cancel(scope: cancelledGeneration)
        }
    }

    func retryPendingRemoteSongMetadata() {
        guard remoteSongMetadataHydrationTask == nil,
              remoteSongs.contains(where: \.isMetadataLoading),
              !serverToken.isEmpty,
              let baseURL = normalizedServer() else { return }
        beginRemoteSongMetadataHydration(baseURL: baseURL, profileID: syncProfileID)
    }

    nonisolated private static func resolveRemoteSongMetadata(
        _ request: RemoteSongMetadataRequest,
        scope: UInt64,
        using service: LocalDeviceImportService,
        broker: MobileRemoteMetadataResolutionBroker
    ) async -> RemoteSongMetadataResult {
        guard !Task.isCancelled else {
            return RemoteSongMetadataResult(request: request, metadata: nil)
        }
        let metadata = try? await broker.resolve(
            scope: scope,
            cacheKey: request.cacheKey,
            source: request.source,
            using: service
        )
        return RemoteSongMetadataResult(
            request: request,
            metadata: Task.isCancelled ? nil : metadata
        )
    }

    nonisolated private static func applying(
        _ metadata: LocalImportSpotifyTrack,
        to song: MobileRemoteSong
    ) -> MobileRemoteSong {
        var updated = song
        updated.title = metadata.title
        updated.artist = metadata.artist
        updated.album = metadata.album ?? "Imported"
        updated.duration = metadata.durationSeconds.map(TimeInterval.init)
        updated.artworkURL = metadata.artworkURL
            .flatMap(URL.init(string:))
            .flatMap { MobileArtworkURLPolicy.validated($0) }
        updated.isMetadataLoading = false
        return updated
    }

    nonisolated private static func applyingRemoteMetadataFailure(
        to song: MobileRemoteSong
    ) -> MobileRemoteSong {
        var updated = song
        if song.requiresOriginalSourcePage {
            updated.title = "Original source link needed"
            updated.artist = "Re-import on the original device"
            updated.album = "Legacy expired link"
            updated.isMetadataLoading = false
        } else {
            updated.title = "Resolving metadata…"
            updated.artist = "Retrying automatically"
            updated.album = "Link only"
            updated.isMetadataLoading = true
        }
        return updated
    }

    @discardableResult
    private func importSavedRemoteSource(
        _ song: MobileRemoteSong,
        baseURL: URL,
        accessToken: String,
        downloadPolicyLease: MobileTransferPolicyLease,
        transferSessionID: UUID,
        operationID: UUID,
        currentItem: Int,
        totalItems: Int
    ) async throws -> MobileTrack {
        guard accessToken == serverToken,
              ownsNativeDownloadOperation(
            sessionID: transferSessionID,
            operationID: operationID
        ) else { throw CancellationError() }
        let resolution = try await remoteSourceResolution(for: song)
        guard accessToken == serverToken,
              ownsNativeDownloadOperation(
            sessionID: transferSessionID,
            operationID: operationID
        ) else { throw CancellationError() }
        guard let candidate = resolution.candidates.first,
              let source = song.sourceURL else { throw URLError(.cannotParseResponse) }
        let metadata = LocalImportMetadata(
            title: resolution.track.title,
            artist: resolution.track.artist,
            album: resolution.track.album,
            artworkURL: resolution.track.artworkURL,
            sourceURL: source
        )
        let outcome = try await serverLinkImportService.importCandidate(
            candidate,
            metadata: metadata,
            existingTracks: tracks,
            mediaMode: LocalImportMediaMode(rawValue: song.mediaKind) ?? .audio,
            includeArtwork: false,
            preferResolvedMetadata: song.isMetadataLoading && !LocalImportURL.isSpotify(source)
        ) { [weak self] progress in
            guard let self,
                  accessToken == self.serverToken,
                  self.ownsNativeDownloadOperation(
                sessionID: transferSessionID,
                operationID: operationID
            ) else { return }
            if MobileDownloadTransferPresentationPolicy.shouldEndBytePresentation(
                for: progress.stage
            ) {
                if self.transferDisplay?.itemID == song.id {
                    self.endNativeDownloadBytePresentation(
                        sessionID: transferSessionID,
                        operationID: operationID,
                        preserveForNextItem: MobileDownloadTransferPresentationPolicy.shouldPreserveBetweenItems(
                            currentItem: currentItem,
                            totalItems: totalItems
                        )
                    )
                }
                return
            }
            guard MobileDownloadTransferPresentationPolicy.shouldPresent(
                     completedBytes: progress.completed,
                     fallbackProgress: nil
                  ) else { return }
            let displaySong = self.remoteSongs.first(where: { $0.id == song.id }) ?? song
            self.downloadDetail = "Downloading \(displaySong.title)"
            self.presentTransfer(
                sessionID: transferSessionID,
                operationID: operationID,
                kind: .download,
                itemID: song.id,
                songTitle: displaySong.title,
                detail: "Downloading song",
                currentItem: currentItem,
                totalItems: totalItems,
                completedBytes: progress.completed,
                totalBytes: progress.total,
                fallbackProgress: nil
            )
        }
        guard accessToken == serverToken,
              ownsNativeDownloadOperation(
            sessionID: transferSessionID,
            operationID: operationID
        ) else { throw CancellationError() }
        let track: MobileTrack
        let importedMetadata: LocalImportMetadata?
        switch outcome {
        case .created(let imported):
            importedMetadata = imported.metadata
            track = try insertLocalImportedAudio(imported, persistImmediately: false)
        case .duplicate(let id, let sourceAssociation):
            importedMetadata = nil
            guard let duplicate = tracks.first(where: { $0.id == id }) else {
                throw URLError(.fileDoesNotExist)
            }
            track = associateLocalImportSource(
                trackID: id,
                source: sourceAssociation,
                persistImmediately: false
            ) ?? duplicate
        }
        if let trackIndex = tracks.firstIndex(where: { $0.id == track.id }) {
            let current = tracks[trackIndex]
            let finalMetadata = MobileSourceImportFinalMetadataPolicy.resolve(
                localTitle: current.title,
                localArtist: current.artist,
                localAlbum: current.album,
                localDuration: current.duration,
                currentRemoteSong: remoteSongs.first(where: { $0.id == song.id })
            )
            tracks[trackIndex].title = finalMetadata.title
            tracks[trackIndex].artist = finalMetadata.artist
            tracks[trackIndex].album = finalMetadata.album
            tracks[trackIndex].duration = finalMetadata.duration

            // A direct provider resolution already supplied enough metadata to
            // name the saved song. Persist that snapshot immediately instead
            // of waiting for the independent catalog hydrator to finish.
            if let remoteIndex = remoteSongs.firstIndex(where: { $0.id == song.id }),
               remoteSongs[remoteIndex].isMetadataLoading {
                let durationSeconds = finalMetadata.duration.isFinite
                    && finalMetadata.duration > 0
                    && finalMetadata.duration < Double(Int.max)
                    ? Int(finalMetadata.duration.rounded())
                    : nil
                let resolvedMetadata = LocalImportSpotifyTrack(
                    provider: LocalImportURL.isSoundCloud(source) ? "soundcloud" : "youtube",
                    type: "track",
                    trackID: resolution.track.trackID,
                    title: finalMetadata.title,
                    artist: finalMetadata.artist,
                    album: finalMetadata.album,
                    trackNumber: nil,
                    durationSeconds: durationSeconds,
                    artworkURL: importedMetadata?.artworkURL
                        ?? remoteSongs[remoteIndex].artworkURL?.absoluteString,
                    embedURL: "",
                    sourceURL: source
                )
                remoteSongs[remoteIndex] = Self.applying(
                    resolvedMetadata,
                    to: remoteSongs[remoteIndex]
                )
                if let metadataCacheKey = remoteSongMetadataCacheKey(for: remoteSongs[remoteIndex]) {
                    remoteSongMetadataCache[metadataCacheKey] = MobileRemoteSongMetadataCacheEntry(
                        sourceURL: source,
                        mediaKind: remoteSongs[remoteIndex].mediaKind,
                        metadata: resolvedMetadata,
                        cachedAt: Date()
                    )
                }
            }
        }
        guard accessToken == serverToken,
              isCurrentServerContext(baseURL: baseURL, profileID: syncProfileID) else {
            // Preserve the completed local import even if the server/profile
            // changed before its remote association could be committed.
            save()
            throw CancellationError()
        }
        guard isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
            // The verified bytes remain a valid local import, but an expired
            // lease must not attach them to the server identity.
            save()
            throw MobileTransferPolicyChangedError.changed
        }
        try adoptUploadedDownload(
            trackID: track.id,
            remoteID: song.id,
            sourceServer: baseURL.absoluteString,
            profileID: syncProfileID,
            persistImmediately: false
        )
        // Import, provenance, and remote identity are committed together so a
        // source-link song rewrites the library only once.
        save()
        return tracks.first(where: { $0.id == track.id }) ?? track
    }

    private func downloadRemoteSong(
        _ song: MobileRemoteSong,
        baseURL: URL,
        profileID: String,
        accessToken: String,
        downloadPolicyLease: MobileTransferPolicyLease,
        transferSessionID: UUID,
        currentItem: Int,
        totalItems: Int
    ) async -> RemoteDownloadItemResult {
        guard accessToken == serverToken,
              isCurrentServerContext(baseURL: baseURL, profileID: profileID) else {
            return .cancelled
        }
        guard isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
            return .policyChanged
        }
        guard let operationID = beginNativeDownloadOperation(
            sessionID: transferSessionID
        ) else { return .cancelled }
        defer {
            finishNativeDownloadOperation(
                sessionID: transferSessionID,
                operationID: operationID
            )
        }
        if song.isSourceLinkRecord {
            do {
                _ = try await importSavedRemoteSource(
                    song,
                    baseURL: baseURL,
                    accessToken: accessToken,
                    downloadPolicyLease: downloadPolicyLease,
                    transferSessionID: transferSessionID,
                    operationID: operationID,
                    currentItem: currentItem,
                    totalItems: totalItems
                )
                // Keep a multi-song batch card mounted while this item is
                // validated and the next one is prepared. A final item can
                // still retire byte progress before its local processing.
                endNativeDownloadBytePresentation(
                    sessionID: transferSessionID,
                    operationID: operationID,
                    preserveForNextItem: MobileDownloadTransferPresentationPolicy.shouldPreserveBetweenItems(
                        currentItem: currentItem,
                        totalItems: totalItems
                    )
                )
                return .downloaded(songID: song.id)
            } catch is MobileTransferPolicyChangedError {
                return .policyChanged
            } catch is CancellationError {
                return .cancelled
            } catch let error as URLError where error.code == .cancelled {
                return .cancelled
            } catch {
                return .failed(
                    songID: song.id,
                    title: song.title,
                    reason: error.localizedDescription
                )
            }
        }

        guard song.size <= MobileDownloadIntegrityPolicy.maximumFileSize else {
            let error = MobileDownloadIntegrityError.tooLarge(
                actual: song.size,
                limit: MobileDownloadIntegrityPolicy.maximumFileSize
            )
            return .failed(
                songID: song.id,
                title: song.title,
                reason: error.localizedDescription
            )
        }
        guard let remoteURL = URL(string: song.downloadURL, relativeTo: baseURL)?.absoluteURL else {
            return .failed(
                songID: song.id,
                title: song.title,
                reason: "The server returned an invalid download URL."
            )
        }
        guard sameOrigin(remoteURL, baseURL) else {
            return .failed(
                songID: song.id,
                title: song.title,
                reason: "The server returned a cross-origin file URL. Resonance only accepts the same-origin resolver."
            )
        }

        var request = URLRequest(url: remoteURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        setClientConfigContextHeaders(on: &request, profileID: profileID)
        let progressSongID = song.id
        let catalogByteCount = song.size
        do {
            guard let authorization = registerDownloadAuthorization(
                for: downloadPolicyLease
            ) else {
                throw MobileTransferPolicyChangedError.changed
            }
            defer { releaseDownloadAuthorization(authorization.id) }
            let boundedDownload = try MobileBoundedDownloadOperation(
                maximumSize: MobileDownloadIntegrityPolicy.maximumFileSize,
                authorization: authorization.authorization,
                progress: { [weak self] byteProgress in
                    Task { @MainActor [weak self] in
                        guard let self,
                              accessToken == self.serverToken,
                              self.ownsNativeDownloadOperation(
                                  sessionID: transferSessionID,
                                  operationID: operationID
                              ) else { return }
                        let displaySong = self.remoteSongs.first(where: { $0.id == progressSongID }) ?? song
                        self.presentTransfer(
                            sessionID: transferSessionID,
                            operationID: operationID,
                            kind: .download,
                            itemID: progressSongID,
                            songTitle: displaySong.title,
                            detail: "Downloading song",
                            currentItem: currentItem,
                            totalItems: totalItems,
                            completedBytes: byteProgress.completed,
                            totalBytes: byteProgress.total > 0 ? byteProgress.total : catalogByteCount
                        )
                    }
                }
            )
            let downloaded = try await boundedDownload.run(request: request)
            // Keep a multi-song batch card mounted between items; only the
            // final item retires byte progress before its local validation.
            endNativeDownloadBytePresentation(
                sessionID: transferSessionID,
                operationID: operationID,
                preserveForNextItem: MobileDownloadTransferPresentationPolicy.shouldPreserveBetweenItems(
                    currentItem: currentItem,
                    totalItems: totalItems
                )
            )
            let temporaryURL = downloaded.temporaryURL
            defer { try? fileManager.removeItem(at: temporaryURL) }
            try Task.checkCancellation()
            guard accessToken == serverToken,
                  ownsNativeDownloadOperation(
                sessionID: transferSessionID,
                operationID: operationID
            ) else { throw CancellationError() }
            guard isCurrentServerContext(baseURL: baseURL, profileID: profileID) else {
                throw CancellationError()
            }
            guard isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                throw MobileTransferPolicyChangedError.changed
            }
            try MobileDownloadIntegrityPolicy.validate(
                expectedSize: song.size,
                expectedSHA256: song.contentSHA256,
                actualSize: downloaded.byteCount,
                actualSHA256: downloaded.sha256
            )

            let mediaDuration: TimeInterval
            if song.mediaKind == "video" || song.contentType.lowercased().hasPrefix("video/") {
                let asset = AVURLAsset(url: temporaryURL)
                guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "The downloaded video does not contain a playable video track."
                    ])
                }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [
                        NSLocalizedDescriptionKey: "The downloaded video has an invalid duration."
                    ])
                }
                mediaDuration = duration
            } else {
                mediaDuration = try AVAudioPlayer(contentsOf: temporaryURL).duration
            }
            let metadata = await embeddedMetadata(at: temporaryURL)
            let artworkData = metadata.artworkData
            try Task.checkCancellation()
            guard accessToken == serverToken,
                  ownsNativeDownloadOperation(
                sessionID: transferSessionID,
                operationID: operationID
            ) else { throw CancellationError() }
            guard isCurrentServerContext(baseURL: baseURL, profileID: profileID) else {
                throw CancellationError()
            }
            guard isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                throw MobileTransferPolicyChangedError.changed
            }
            let filename = uniqueFilename(song.filename)
            let destination = musicDirectory.appendingPathComponent(filename)
            try fileManager.moveItem(at: temporaryURL, to: destination)
            do {
                try markServerDownloadExcludedFromBackup(at: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            let catalogSong = remoteSongs.first(where: { $0.id == song.id }) ?? song
            let trackID = UUID()
            let persistedSourceURL = MobileTrackPersistencePolicy.canonicalSourceURL(song.sourceURL)
            let persistedDownloadSourceURL = MobileTrackPersistencePolicy.persistedDownloadSourceURL(
                song.sourceURL.flatMap(URL.init(string:)),
                legitimateServerOrigin: baseURL
            )
            tracks.append(MobileTrack(
                id: trackID,
                title: metadata.title ?? catalogSong.title,
                artist: metadata.artist ?? usefulFallback(catalogSong.artist, default: "Unknown Artist"),
                album: metadata.album ?? usefulFallback(catalogSong.album, default: "Server Library"),
                duration: MobilePlayableMediaDurationPolicy.preferred(
                    storedDuration: metadata.duration ?? catalogSong.duration,
                    playableDurations: [mediaDuration]
                ) ?? mediaDuration,
                relativePath: filename,
                remoteID: song.id,
                sourceServer: baseURL.absoluteString,
                syncProfileID: profileID,
                sourceURL: persistedSourceURL,
                downloadSourceURL: persistedDownloadSourceURL,
                artworkFilename: saveArtwork(artworkData, for: trackID),
                artworkScanComplete: artworkData != nil,
                contentSHA256: downloaded.sha256,
                preservesUnlinkedImport: false
            ))
            save()
            return .downloaded(songID: song.id)
        } catch is MobileTransferPolicyChangedError {
            return .policyChanged
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            return .failed(
                songID: song.id,
                title: song.title,
                reason: error.localizedDescription
            )
        }
    }

    private func downloadRemoteSongs(
        _ songs: [MobileRemoteSong],
        baseURL: URL,
        profileID: String,
        accessToken: String,
        downloadPolicyLease: MobileTransferPolicyLease,
        transferSessionID: UUID
    ) async -> [RemoteDownloadItemResult] {
        var results: [RemoteDownloadItemResult] = []

        func isInterrupted(_ result: RemoteDownloadItemResult) -> Bool {
            switch result {
            case .policyChanged, .cancelled: true
            case .downloaded, .failed: false
            }
        }

        for (index, song) in songs.enumerated() {
            let result = await downloadRemoteSong(
                song,
                baseURL: baseURL,
                profileID: profileID,
                accessToken: accessToken,
                downloadPolicyLease: downloadPolicyLease,
                transferSessionID: transferSessionID,
                currentItem: index + 1,
                totalItems: songs.count
            )
            results.append(result)
            if isInterrupted(result) { break }
            if index + 1 < songs.count {
                hideTransferPresentation(sessionID: transferSessionID)
            }
        }
        return results
    }

    private func performCatalogSync() async {
        cancelRemoteSongMetadataHydration()
        guard let baseURL = normalizedServer() else {
            invalidateFullCatalogAuthority()
            isServerConnected = false
            remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                catalog: [],
                uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
            )
            serverMessage = "Enter a valid server URL."
            return
        }
        guard !serverToken.isEmpty else {
            invalidateFullCatalogAuthority()
            isServerConnected = false
            remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                catalog: [],
                uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
            )
            serverMessage = "Sign in to your Resonance account."
            return
        }
        let wasServerConnected = isServerConnected
        let catalogBeforeRefresh = remoteSongs
        let serverMessageBeforeRefresh = serverMessage
        let requestGeneration = advanceCatalogRequestGeneration()
        let submittedCatalogMutationGeneration = catalogMutationGeneration
        let requestProfileID = syncProfileID
        let requestAccessToken = serverToken
        let requestContext = MobileServerEndpointPolicy.context(
            serverURL: baseURL,
            profileID: requestProfileID
        )
        isSyncing = true
        defer { isSyncing = false }
        var reachedCatalog = false
        do {
            var catalogRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/songs"))
            catalogRequest.setValue("Bearer \(requestAccessToken)", forHTTPHeaderField: "Authorization")
            setProfileHeader(on: &catalogRequest)
            let (catalogData, response) = try await sameOriginData(
                for: catalogRequest,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.catalogMaximumBytes
            )
            guard let catalogStatus = (response as? HTTPURLResponse)?.statusCode else {
                throw URLError(.badServerResponse)
            }
            guard catalogStatus == 200 else {
                throw playlistServerError(status: catalogStatus, data: catalogData)
            }
            let catalog = try JSONDecoder().decode(MobileRemoteCatalog.self, from: catalogData)
            let catalogSongs = applyingKnownRemoteSongMetadata(
                to: MobileCollectionNormalization.uniqueRemoteSongs(catalog.songs)
            )
            guard requestGeneration == catalogRequestGeneration,
                  serverToken == requestAccessToken,
                  isCurrentServerContext(baseURL: baseURL, profileID: requestProfileID) else { return }
            reachedCatalog = true
            isServerConnected = true
            let catalogMutatedWhileRefreshing = submittedCatalogMutationGeneration != catalogMutationGeneration
            remoteSongs = catalogMutatedWhileRefreshing || !uploadedSongsAwaitingCatalog.isEmpty
                ? MobileCatalogRefreshMergePolicy.merge(
                    catalog: catalogSongs,
                    uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
                )
                : catalogSongs
            remoteSongs = MobileCollectionNormalization.uniqueRemoteSongs(remoteSongs)
            for song in catalogSongs {
                uploadedSongsAwaitingCatalog.removeValue(forKey: song.id)
            }
            fullCatalogAuthority = MobileFullCatalogAuthorityPolicy.completedFetch(
                context: requestContext,
                requestGeneration: requestGeneration,
                currentRequestGeneration: catalogRequestGeneration,
                credentialIsCurrent: serverToken == requestAccessToken,
                catalogMutationGenerationUnchanged: !catalogMutatedWhileRefreshing,
                hasPendingCatalogMerges: !uploadedSongsAwaitingCatalog.isEmpty,
                songIDs: Set(catalogSongs.map(\.id))
            )
            selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
            beginRemoteSongMetadataHydration(baseURL: baseURL, profileID: requestProfileID)
            if submittedCatalogMutationGeneration == catalogMutationGeneration {
                serverMessage = "Connected • \(catalogSongs.count) song\(catalogSongs.count == 1 ? "" : "s")"
            }
        } catch {
            let wasCancelled = Task.isCancelled
                || (error as? URLError)?.code == .cancelled
                || error is CancellationError
            let isAuthenticationFailure = (error as? PlaylistServerError).map {
                $0.status == 401 || $0.status == 403
            } ?? false
            let preservesCatalog = MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
                wasConnected: wasServerConnected,
                hadCatalog: !catalogBeforeRefresh.isEmpty,
                wasCancelled: wasCancelled,
                isAuthenticationFailure: isAuthenticationFailure
            )
            if isAuthenticationFailure {
                cancelRemoteSongMetadataHydration()
                isServerConnected = false
                remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                    catalog: [],
                    uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
                )
                selectedRemoteSongIDs.removeAll()
            } else if !reachedCatalog, !preservesCatalog {
                isServerConnected = false
                remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                    catalog: [],
                    uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
                )
                selectedRemoteSongIDs.removeAll()
            } else if !reachedCatalog {
                isServerConnected = wasServerConnected
                remoteSongs = catalogBeforeRefresh
                selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
                beginRemoteSongMetadataHydration(baseURL: baseURL, profileID: requestProfileID)
            }
            if submittedCatalogMutationGeneration == catalogMutationGeneration {
                if isAuthenticationFailure {
                    serverMessage = "Authentication failed. Sign in again."
                } else if wasCancelled {
                    serverMessage = serverMessageBeforeRefresh
                } else {
                    serverMessage = preservesCatalog
                        ? "Refresh failed: \(error.localizedDescription)"
                        : "Connection failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func refreshEmbeddedMetadata() async {
        var changed = false
        for index in tracks.indices {
            let track = tracks[index]
            let mediaURL = fileURL(for: track)
            if let playableDuration = (try? AVAudioPlayer(contentsOf: mediaURL))?.duration,
               let resolvedDuration = MobilePlayableMediaDurationPolicy.preferred(
                    storedDuration: track.duration,
                    playableDurations: [playableDuration]
               ), abs(resolvedDuration - tracks[index].duration) > 0.25 {
                tracks[index].duration = resolvedDuration
                changed = true
            }
            guard needsMetadataRefresh(track) else { continue }
            let metadata = await embeddedMetadata(at: mediaURL)
            if let title = metadata.title, title != tracks[index].title {
                tracks[index].title = title
                changed = true
            }
            if let artist = metadata.artist, artist != tracks[index].artist {
                tracks[index].artist = artist
                changed = true
            }
            if let album = metadata.album, album != tracks[index].album {
                tracks[index].album = album
                changed = true
            }
            if let duration = metadata.duration,
               duration.isFinite,
               duration > 0,
               abs(duration - tracks[index].duration) > 0.5 {
                tracks[index].duration = duration
                changed = true
            }
            if tracks[index].artworkScanComplete != true {
                tracks[index].artworkFilename = saveArtwork(metadata.artworkData, for: track.id)
                tracks[index].artworkScanComplete = true
                changed = true
            }
        }
        if changed {
            normalizeSystemPlaylist()
            save()
            updateNowPlaying()
        }
    }

    func refreshDownloadedSongMetadata() async {
        guard !isRefreshingDownloadedMetadata else { return }
        let candidates = tracks.compactMap { track -> (track: MobileTrack, fileURL: URL, source: String?)? in
            let mediaURL = fileURL(for: track)
            guard fileManager.fileExists(atPath: mediaURL.path) else { return nil }
            return (
                track,
                mediaURL,
                MobileDownloadedSongMetadataRefreshPolicy.sourceURL(for: track, fileExists: true)
            )
        }
        guard !candidates.isEmpty else {
            downloadedMetadataRefreshDetail = "No downloaded songs are available to refresh."
            return
        }

        isRefreshingDownloadedMetadata = true
        downloadedMetadataRefreshDetail = "Preparing " + String(candidates.count)
            + " song" + (candidates.count == 1 ? "" : "s") + "…"
        defer { isRefreshingDownloadedMetadata = false }

        var sourceFailures = 0
        for (offset, candidate) in candidates.enumerated() {
            downloadedMetadataRefreshDetail = "Refreshing " + String(offset + 1)
                + " of " + String(candidates.count) + " • " + candidate.track.title
            let embedded = await embeddedMetadata(at: candidate.fileURL)
            guard let currentIndex = tracks.firstIndex(where: { $0.id == candidate.track.id }) else { continue }

            if let title = embedded.title { tracks[currentIndex].title = title }
            if let artist = embedded.artist { tracks[currentIndex].artist = artist }
            if let album = embedded.album { tracks[currentIndex].album = album }
            if let duration = embedded.duration,
               duration.isFinite,
               duration > 0 {
                tracks[currentIndex].duration = duration
            }
            if let artworkData = embedded.artworkData,
               let filename = saveArtwork(artworkData, for: tracks[currentIndex].id) {
                tracks[currentIndex].artworkFilename = filename
                tracks[currentIndex].artworkScanComplete = true
            }

            guard let source = candidate.source else { continue }
            do {
                let metadata = try await serverLinkImportService.resolveMetadata(source: source)
                let artworkData = await serverLinkImportService.artworkData(for: metadata.artworkURL)
                guard let refreshedIndex = tracks.firstIndex(where: { $0.id == candidate.track.id }) else { continue }
                let artworkFilename = artworkData.flatMap { saveArtwork($0, for: tracks[refreshedIndex].id) }
                tracks[refreshedIndex] = MobileDownloadedSongMetadataRefreshPolicy.applying(
                    metadata,
                    artworkFilename: artworkFilename,
                    to: tracks[refreshedIndex]
                )
                let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
                let mediaKind = videoExtensions.contains(candidate.fileURL.pathExtension.lowercased()) ? "video" : "audio"
                if let cacheKey = MobileRemoteSongMetadataCachePolicy.key(
                    sourceURL: source,
                    mediaKind: mediaKind
                ) {
                    remoteSongMetadataCache[cacheKey] = MobileRemoteSongMetadataCacheEntry(
                        sourceURL: source,
                        mediaKind: mediaKind,
                        metadata: metadata,
                        cachedAt: Date()
                    )
                }
                if let remoteID = tracks[refreshedIndex].remoteID,
                   let remoteIndex = remoteSongs.firstIndex(where: { $0.id == remoteID }) {
                    remoteSongs[remoteIndex] = Self.applying(metadata, to: remoteSongs[remoteIndex])
                }
            } catch {
                sourceFailures += 1
            }
        }

        normalizeSystemPlaylist()
        nowPlayingArtworkCache = nil
        nowPlayingArtworkCacheKey = nil
        save()
        updateNowPlaying()
        downloadedMetadataRefreshDetail = sourceFailures == 0
            ? "Re-cached metadata for " + String(candidates.count)
                + " song" + (candidates.count == 1 ? "" : "s") + "."
            : "Re-cached " + String(candidates.count)
                + " song" + (candidates.count == 1 ? "" : "s") + " • "
                + String(sourceFailures) + " source refresh"
                + (sourceFailures == 1 ? "" : "es") + " failed."
    }

    private func embeddedMetadata(at url: URL) async -> EmbeddedMetadata {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        let duration = try? await asset.load(.duration)
        let playableDuration = (try? AVAudioPlayer(contentsOf: url))?.duration
        let title = await metadataString(.commonKeyTitle, in: items)
        let artist = await metadataString(.commonKeyArtist, in: items)
        let author = await metadataString(.commonKeyAuthor, in: items)
        let album = await metadataString(.commonKeyAlbumName, in: items)
        let artwork = await metadataData(.commonKeyArtwork, in: items)
        return EmbeddedMetadata(
            title: title,
            artist: artist ?? author,
            album: album,
            duration: MobilePlayableMediaDurationPolicy.preferred(
                storedDuration: duration.map(CMTimeGetSeconds),
                playableDurations: [playableDuration]
            ),
            artworkData: artwork
        )
    }

    private func metadataString(_ key: AVMetadataKey, in items: [AVMetadataItem]) async -> String? {
        guard let item = items.first(where: { $0.commonKey == key }),
              let value = try? await item.load(.stringValue) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func metadataData(_ key: AVMetadataKey, in items: [AVMetadataItem]) async -> Data? {
        guard let item = items.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.dataValue)
    }

    private func saveArtwork(_ data: Data?, for trackID: UUID) -> String? {
        guard let data,
              let safeData = MobileArtworkImagePolicy.jpegData(from: data) else { return nil }
        let filename = trackID.uuidString + ".artwork"
        do {
            try safeData.write(to: artworkDirectory.appendingPathComponent(filename), options: .atomic)
            artworkCache.removeValue(forKey: filename)
            return filename
        } catch {
            return nil
        }
    }

    private func backfillDownloadedArtwork(
        from songs: [MobileRemoteSong],
        baseURL: URL
    ) async {
        let songsByID = songs.reduce(into: [String: MobileRemoteSong]()) { result, song in
            if result[song.id] == nil { result[song.id] = song }
        }
        var changed = false
        let context = MobileServerEndpointPolicy.context(serverURL: baseURL, profileID: syncProfileID)

        for index in tracks.indices {
            let track = tracks[index]
            guard let remoteID = track.remoteID,
                  let context,
                  track.remoteIdentity() == MobileRemoteIdentity(context: context, remoteID: remoteID),
                  let song = songsByID[remoteID],
                  artwork(for: track) == nil,
                  let data = await remoteArtworkData(for: song, baseURL: baseURL),
                  let filename = saveArtwork(data, for: track.id) else { continue }

            tracks[index].artworkFilename = filename
            tracks[index].artworkScanComplete = true
            changed = true
        }

        if changed {
            normalizeSystemPlaylist()
            save()
            updateNowPlaying()
        }
    }

    private func remoteArtworkData(
        for song: MobileRemoteSong,
        baseURL: URL
    ) async -> Data? {
        guard let catalogURL = song.artworkURL else { return nil }
        let artworkURL: URL
        if catalogURL.scheme == nil {
            guard let resolved = URL(string: catalogURL.relativeString, relativeTo: baseURL)?.absoluteURL else {
                return nil
            }
            artworkURL = resolved
        } else {
            artworkURL = catalogURL
        }

        var request = URLRequest(url: artworkURL)
        if sameOrigin(artworkURL, baseURL) {
            request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
            setProfileHeader(on: &request)
        }

        do {
            let (data, response): (Data, URLResponse)
            if sameOrigin(artworkURL, baseURL) {
                (data, response) = try await sameOriginData(
                    for: request,
                    origin: baseURL,
                    maximumBytes: MobileBoundedResponsePolicy.artworkMaximumBytes
                )
            } else {
                (data, response) = try await MobileArtworkURLPolicy.data(
                    for: request,
                    maximumBytes: MobileBoundedResponsePolicy.artworkMaximumBytes
                )
            }
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  let safeArtwork = MobileArtworkImagePolicy.jpegData(from: data) else { return nil }
            return safeArtwork
        } catch {
            return nil
        }
    }

    private func needsMetadataRefresh(_ track: MobileTrack) -> Bool {
        let placeholders = ["unknown artist", "server library", "local file"]
        let filenameTitle = URL(fileURLWithPath: track.relativePath).deletingPathExtension().lastPathComponent
        return placeholders.contains(track.artist.lowercased())
            || track.album == "Imported"
            || track.title == filenameTitle
            || track.artworkScanComplete != true
    }

    private func usefulFallback(_ value: String, default defaultValue: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["unknown artist", "server library", "local file"]
        return trimmed.isEmpty || placeholders.contains(trimmed.lowercased()) ? defaultValue : trimmed
    }

    private func markServerDownloadExcludedFromBackup(at url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private func commitDownloadCheckpoint(_ downloadedSongIDs: Set<String>) {
        normalizeSystemPlaylist()
        hydrateRemotePlaylistTracks()
        hydrateRemoteLikedTracks()
        selectedRemoteSongIDs.subtract(downloadedSongIDs)
        save()
    }

    private func recordTransferFailure(
        _ operation: MobileTransferFailure.Operation,
        item: String,
        reason: String,
        retryTarget: MobileTransferRetryTarget? = nil
    ) {
        transferFailures.insert(
            MobileTransferFailure(
                operation: operation,
                item: item,
                reason: reason,
                retryTarget: retryTarget
            ),
            at: 0
        )
        save()
    }

    func clearTransferFailures() {
        transferFailures.removeAll()
        save()
    }

    func retryTransferFailure(_ failure: MobileTransferFailure) async {
        guard let target = failure.retryTarget else { return }
        transferFailures.removeAll { $0.id == failure.id }
        save()
        switch target {
        case .download(let remoteSongID):
            if let song = remoteSongs.first(where: { $0.id == remoteSongID }) {
                await download(song)
            } else {
                await refreshCatalog()
            }
        case .uploadTrack(let trackID):
            await uploadDownloadedSongsMissingFromServer(trackIDs: [trackID])
        case .uploadFile(let source):
            await uploadFiles([source])
        case .delete(let remoteSongID):
            if let song = remoteSongs.first(where: { $0.id == remoteSongID }) {
                await deleteRemoteSong(song)
            } else {
                await syncCatalog()
                if let song = remoteSongs.first(where: { $0.id == remoteSongID }) {
                    await deleteRemoteSong(song)
                }
            }
        }
    }

    func importServerSourceLink(_ rawValue: String) async -> Bool {
        guard activeUploadMode == .serverSourceLink else {
            serverMessage = "Source-link upload is not enabled by the active server policy."
            return false
        }
        guard !isUploadTransferBusy else {
            serverMessage = "Wait for the active upload or download to finish."
            return false
        }
        guard let baseURL = normalizedServer(), !serverAdminToken.isEmpty else {
            serverMessage = "Sign in to your Resonance account first."
            return false
        }

        guard let sourcePageURL = MobileSourcePagePolicy.validatedOriginalYouTubePage(rawValue) else {
            serverMessage = "Protocol 1 source upload supports canonical HTTPS YouTube video pages."
            return false
        }

        let endpoint = baseURL.appendingPathComponent("api/v1/admin/source-imports")
        guard sameOrigin(endpoint, baseURL) else {
            serverMessage = "Source-link upload was blocked because the endpoint was not same-origin."
            return false
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        setClientConfigContextHeaders(on: &request)
        do {
            request.httpBody = try JSONEncoder().encode(SourceImportRequest(
                sourcePageURL: sourcePageURL
            ))
        } catch {
            serverMessage = "Could not prepare source upload: \(error.localizedDescription)"
            return false
        }

        uploadDetail = "Sending source page to \(baseURL.host ?? "server")"
        guard let transferSessionID = beginTransferSession(with: MobileTransferDisplayState(
            kind: .upload,
            itemID: sourcePageURL,
            songTitle: "Import from Web",
            detail: "Sending source page",
            currentItem: 1,
            totalItems: 1,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        )) else { return false }
        defer {
            finishTransferSession(transferSessionID)
        }
        do {
            let (data, response) = try await sameOriginData(
                for: request,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.sourceImportMaximumBytes
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 409 {
                let duplicate = try JSONDecoder().decode(SourceImportDuplicateResponse.self, from: data)
                guard duplicate.schemaVersion == 1, duplicate.status == "duplicate" else {
                    throw URLError(.cannotParseResponse)
                }
                recordUploadedSong(duplicate.duplicateOf)
                uploadDetail = "This source is already in the server library"
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: sourcePageURL,
                    songTitle: duplicate.duplicateOf.title,
                    detail: uploadDetail,
                    currentItem: 1,
                    totalItems: 1,
                    fallbackProgress: 1
                )
                serverMessage = uploadDetail
                return true
            }
            guard status == 201 else {
                let detail = (try? JSONDecoder().decode(ServerErrorPayload.self, from: data).error)
                serverMessage = detail ?? "Source upload failed with HTTP \(status)."
                return false
            }
            let imported = try JSONDecoder().decode(SourceImportResponse.self, from: data)
            guard imported.schemaVersion == 1,
                  imported.status == "imported" || imported.status == "restored" else {
                throw URLError(.cannotParseResponse)
            }
            recordUploadedSong(imported.song)
            uploadDetail = imported.status == "restored"
                ? "Restored \(imported.song.title) from its source page"
                : "Imported \(imported.song.title) from its source page"
            presentTransfer(
                sessionID: transferSessionID,
                kind: .upload,
                itemID: sourcePageURL,
                songTitle: imported.song.title,
                detail: uploadDetail,
                currentItem: 1,
                totalItems: 1,
                fallbackProgress: 1
            )
            serverMessage = uploadDetail
            showTransferNotice(title: "Server import complete", detail: uploadDetail, isError: false)
            return true
        } catch {
            uploadDetail = "Source upload failed"
            serverMessage = "Source upload failed: \(error.localizedDescription)"
            showTransferNotice(title: uploadDetail, detail: serverMessage, isError: true)
            return false
        }
    }

    private func streamRemoteSong(_ song: MobileRemoteSong) async {
        guard !isTransferBusy else { return }
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = normalizedServer(), !accessToken.isEmpty else {
            showTransferNotice(
                title: "Stream unavailable",
                detail: "Sign in to your Resonance account first.",
                isError: true
            )
            return
        }
        guard MobileAuthenticatedStreamPolicy.normalizedAudioMIMEType(song.contentType) != nil else {
            let detail = song.contentType.lowercased().hasPrefix("video/")
                ? "Video stream-only playback is not available on iPhone or iPad. Change the server policy to Verified offline file, then download the video."
                : "The catalog did not publish a supported audio content type for this song."
            downloadDetail = detail
            showTransferNotice(title: "Download required", detail: detail, isError: false)
            return
        }
        guard song.size > 0 else {
            showTransferNotice(
                title: "Stream unavailable",
                detail: "The server did not publish a verified media size for this song.",
                isError: true
            )
            return
        }
        guard let downloadPolicyLease = captureDownloadPolicyLease(.streamOnly) else {
            showTransferNotice(
                title: "Stream policy changed",
                detail: "Stream-only playback is no longer enabled by the signed server policy.",
                isError: true
            )
            return
        }
        let profileID = syncProfileID
        guard let leaseContext = authenticatedStreamLeaseContext(
            baseURL: baseURL,
            profileID: profileID,
            accessToken: accessToken
        ), let policyExpiration = downloadPolicyLease.configuration.expiresAt else {
            showTransferNotice(
                title: "Stream unavailable",
                detail: "The signed stream authorization is incomplete.",
                isError: true
            )
            return
        }
        guard let transferSessionID = beginTransferSession(with: MobileTransferDisplayState(
            kind: .download,
            itemID: song.id,
            songTitle: song.title,
            detail: "Preparing stream",
            currentItem: 1,
            totalItems: 1,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        )) else { return }
        defer {
            finishTransferSession(transferSessionID)
        }
        do {
            let mediaEndpoint = baseURL
                .appendingPathComponent("api/v1/songs")
                .appendingPathComponent(song.id)
                .appendingPathComponent("media-location")
            guard sameOrigin(mediaEndpoint, baseURL) else { throw URLError(.unsupportedURL) }
            var locationRequest = URLRequest(url: mediaEndpoint)
            locationRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            leaseContext.requestContext.apply(to: &locationRequest)
            let (locationData, locationResponse) = try await sameOriginData(
                for: locationRequest,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.mediaLocationMaximumBytes
            )
            guard isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                throw MobileTransferPolicyChangedError.changed
            }
            guard serverToken.trimmingCharacters(in: .whitespacesAndNewlines) == accessToken,
                  isCurrentServerContext(baseURL: baseURL, profileID: profileID) else {
                throw CancellationError()
            }
            guard (locationResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let location = try JSONDecoder().decode(
                MobileRemoteMediaLocationResponse.self,
                from: locationData
            ).mediaLocation
            let expectedContentType = try MobileAuthenticatedStreamPolicy.validateDescriptor(
                catalogLength: song.size,
                catalogSHA256: song.contentSHA256,
                catalogContentType: song.contentType,
                locationLength: location.byteLength,
                locationSHA256: location.contentSHA256,
                locationContentType: location.contentType,
                supportsRanges: location.supportsRanges,
                state: location.state
            )
            guard let streamURL = URL(string: location.streamURL, relativeTo: baseURL)?.absoluteURL,
                  sameOrigin(streamURL, baseURL) else {
                throw URLError(.dataNotAllowed)
            }

            var streamRequest = URLRequest(url: streamURL)
            streamRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            streamRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            streamRequest.setValue("audio/*", forHTTPHeaderField: "Accept")
            leaseContext.requestContext.apply(to: &streamRequest)

            let authorizationLease = try MobileAuthenticatedStreamAuthorizationLease(
                context: leaseContext,
                expiresAt: policyExpiration
            )
            let departingLocalID = streamingTrack == nil ? currentTrackID : nil
            endListeningHistorySession()
            discardStreamingPlayback()
            if let departingLocalID,
               tracks.contains(where: { $0.id == departingLocalID }) {
                history.append(departingLocalID)
            }
            stopTimer()
            player?.stop()
            player = nil

            streamingGeneration &+= 1
            let generation = streamingGeneration
            let transientTrack = MobileTrack(
                title: song.title,
                artist: usefulFallback(song.artist, default: "Unknown Artist"),
                album: usefulFallback(song.album, default: "Server Library"),
                duration: song.duration ?? 0,
                relativePath: "",
                remoteID: song.id,
                sourceServer: baseURL.absoluteString,
                syncProfileID: profileID,
                sourceURL: song.sourceURL,
                artworkScanComplete: true,
                contentSHA256: MobileContentHashPolicy.normalizedSHA256(song.contentSHA256)
            )
            streamingTrack = transientTrack
            streamingArtworkURL = resolvedListenAlongArtworkURL(song.artworkURL, relativeTo: baseURL)
            isTransientStreamActive = true
            currentTrackID = transientTrack.id
            playbackQueue = [transientTrack.id]
            playbackPlaylistID = nil
            position = 0
            UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")

            let loader = MobileAuthenticatedStreamResourceLoader(
                sourceURL: streamURL,
                headers: streamRequest.allHTTPHeaderFields ?? [:],
                expectedContentLength: song.size,
                expectedContentType: expectedContentType,
                authorizationLease: authorizationLease,
                onAuthorizationInvalidated: { [weak self, weak authorizationLease] in
                    Task { @MainActor [weak self, weak authorizationLease] in
                        guard let self, let authorizationLease else { return }
                        self.authenticatedStreamAuthorizationDidExpire(
                            lease: authorizationLease,
                            generation: generation
                        )
                    }
                }
            )
            let assetURL = try MobileAuthenticatedStreamPolicy.assetURL(for: streamURL)
            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            streamingResourceLoader = loader
            streamingAuthorizationLease = authorizationLease
            downloadDetail = "Preparing authenticated stream • \(song.title)"

            guard try await asset.load(.isPlayable) else {
                throw MobileAuthenticatedStreamError.invalidResponse
            }
            let measuredDuration = try? await asset.load(.duration).seconds
            try Task.checkCancellation()
            try authorizationLease.authorize()
            guard generation == streamingGeneration,
                  streamingTrack?.id == transientTrack.id,
                  streamingAuthorizationLease === authorizationLease,
                  serverToken.trimmingCharacters(in: .whitespacesAndNewlines) == accessToken,
                  isCurrentServerContext(baseURL: baseURL, profileID: profileID),
                  activeDownloadMode == .streamOnly else {
                throw CancellationError()
            }

            let item = AVPlayerItem(asset: asset)
            let streamPlayer = AVPlayer(playerItem: item)
            streamPlayer.volume = PlaybackVolumePolicy.gain(for: volume)
            streamPlayer.defaultRate = playbackRate
            streamPlayer.automaticallyWaitsToMinimizeStalling = true
            streamingPlayer = streamPlayer
            if let measuredDuration,
               measuredDuration.isFinite,
               measuredDuration > 0 {
                streamingTrack?.duration = measuredDuration
            }
            let streamBounds = playbackBounds(for: streamingTrack ?? transientTrack)
            streamingEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.authenticatedStreamDidFinish(item: item, generation: generation)
                }
            }
            streamingFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.authenticatedStreamDidFail(
                        item: item,
                        generation: generation,
                        error: error
                    )
                }
            }
            streamingStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, item.status == .failed else { return }
                    self.authenticatedStreamDidFail(
                        item: item,
                        generation: generation,
                        error: item.error
                    )
                }
            }
            position = streamBounds.start
            if streamBounds.start > 0 {
                await seekAuthenticatedStream(streamPlayer, to: streamBounds.start)
                try Task.checkCancellation()
                try authorizationLease.authorize()
                guard generation == streamingGeneration,
                      streamingPlayer === streamPlayer,
                      streamingAuthorizationLease === authorizationLease,
                      serverToken.trimmingCharacters(in: .whitespacesAndNewlines) == accessToken,
                      isCurrentServerContext(baseURL: baseURL, profileID: profileID),
                      activeDownloadMode == .streamOnly else {
                    throw CancellationError()
                }
            }
            try AVAudioSession.sharedInstance().setActive(true)
            streamPlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            if let streamingTrack { beginListeningHistorySession(for: streamingTrack) }
            downloadDetail = "Streaming \(song.title) • no offline file saved"
            presentTransfer(
                sessionID: transferSessionID,
                kind: .download,
                itemID: song.id,
                songTitle: song.title,
                detail: "Stream ready",
                currentItem: 1,
                totalItems: 1,
                fallbackProgress: 1
            )
            startTimer()
            updateNowPlaying()
            notifyListenAlongPlaybackChanged()
        } catch is MobileTransferPolicyChangedError {
            discardStreamingPlayback()
            downloadDetail = "Stream stopped because the signed policy expired or changed"
            showTransferNotice(
                title: "Stream policy changed",
                detail: downloadDetail,
                isError: true
            )
        } catch is CancellationError {
            discardStreamingPlayback()
            downloadDetail = "Stream cancelled"
        } catch {
            discardStreamingPlayback()
            downloadDetail = "Could not stream \(song.title)"
            recordTransferFailure(
                .download,
                item: song.title,
                reason: error.localizedDescription,
                retryTarget: .download(remoteSongID: song.id)
            )
            showTransferNotice(title: "Stream failed", detail: error.localizedDescription, isError: true)
        }
    }

    private func authenticatedStreamDidFinish(item: AVPlayerItem, generation: UInt64) {
        guard generation == streamingGeneration,
              streamingPlayer?.currentItem === item else { return }
        completeAuthenticatedStreamPlayback(generation: generation)
    }

    private func completeAuthenticatedStreamPlayback(generation: UInt64) {
        guard generation == streamingGeneration,
              isTransientStreamActive,
              let streamingPlayer,
              let streamingTrack else { return }
        let bounds = playbackBounds(for: streamingTrack)
        endListeningHistorySession()
        stopTimer()
        streamingPlayer.pause()
        streamingPlayer.seek(
            to: CMTime(seconds: bounds.start, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        position = bounds.start
        if repeatEnabled {
            streamingPlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            beginListeningHistorySession(for: streamingTrack)
            startTimer()
        } else {
            isPlaying = false
        }
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
    }

    private func seekAuthenticatedStream(_ player: AVPlayer, to seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
    }

    private func authenticatedStreamDidFail(
        item: AVPlayerItem,
        generation: UInt64,
        error: Error?
    ) {
        guard generation == streamingGeneration,
              streamingPlayer?.currentItem === item else { return }
        failAuthenticatedStream(
            generation: generation,
            error: error ?? MobileAuthenticatedStreamError.invalidResponse
        )
    }

    private func authenticatedStreamAuthorizationDidExpire(
        lease: MobileAuthenticatedStreamAuthorizationLease,
        generation: UInt64
    ) {
        guard streamingAuthorizationLease === lease else { return }
        failAuthenticatedStream(
            generation: generation,
            error: MobileAuthenticatedStreamError.authorizationExpired
        )
    }

    private func failAuthenticatedStream(generation: UInt64, error: Error) {
        guard generation == streamingGeneration, isTransientStreamActive else { return }
        let detail = error.localizedDescription
        let title = streamingTrack?.title ?? "Stream"
        discardStreamingPlayback()
        downloadDetail = "Stream stopped: \(detail)"
        recordTransferFailure(
            .download,
            item: title,
            reason: detail,
            retryTarget: nil
        )
        showTransferNotice(title: "Stream stopped", detail: detail, isError: true)
    }

    private func discardStreamingPlayback() {
        let hadStreamingState = isTransientStreamActive
            || streamingTrack != nil
            || streamingPlayer != nil
            || streamingResourceLoader != nil
            || streamingAuthorizationLease != nil
            || streamingPreview != nil
        endListeningHistorySession()
        let streamingID = streamingTrack?.id
        streamingGeneration &+= 1
        if let streamingEndObserver {
            NotificationCenter.default.removeObserver(streamingEndObserver)
            self.streamingEndObserver = nil
        }
        if let streamingFailureObserver {
            NotificationCenter.default.removeObserver(streamingFailureObserver)
            self.streamingFailureObserver = nil
        }
        streamingStatusObservation?.invalidate()
        streamingStatusObservation = nil
        streamingPlayer?.pause()
        streamingPlayer = nil
        let loader = streamingResourceLoader
        streamingResourceLoader = nil
        let youtubeLoader = streamingYouTubeLoader
        streamingYouTubeLoader = nil
        let authorizationLease = streamingAuthorizationLease
        streamingAuthorizationLease = nil
        loader?.invalidate()
        youtubeLoader?.invalidate()
        authorizationLease?.setInvalidationHandler(nil)
        authorizationLease?.invalidate()
        streamingTrack = nil
        streamingArtworkURL = nil
        streamingPreview = nil
        streamingPreviewSourceURL = nil
        isTransientStreamActive = false
        if hadStreamingState {
            stopTimer()
            isPlaying = false
        }
        if currentTrackID == streamingID {
            currentTrackID = nil
            position = 0
            UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")
            UserDefaults.standard.set(position, forKey: "Resonance.position")
        }
        if let streamingID {
            playbackQueue.removeAll { $0 == streamingID }
            history.removeAll { $0 == streamingID }
        }
        updateNowPlaying()
    }

    func uploadFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard activeUploadMode == .localFile else {
            uploadDetail = "Choose Preserved source link upload mode first"
            return
        }
        guard !isUploadTransferBusy else { return }
        guard let baseURL = normalizedServer(),
              MobileUploadCredentialPolicy.canUpload(serverURL: baseURL, adminKey: serverAdminToken) else {
            uploadDetail = "Sign in to your Resonance account"
            return
        }
        let uploadProfileID = syncProfileID
        guard let uploadContext = MobileServerEndpointPolicy.context(
            serverURL: baseURL,
            profileID: uploadProfileID
        ) else {
            uploadDetail = "Enter a valid server URL and profile"
            return
        }
        let firstSource = urls[0]
        let firstTrack = MobileManagedTrackUploadPolicy.managedTrack(
            matching: firstSource,
            tracks: tracks,
            musicDirectory: musicDirectory
        )
        guard let transferSessionID = beginTransferSession(with: MobileTransferDisplayState(
            kind: .upload,
            itemID: firstSource.absoluteString,
            songTitle: firstTrack?.title ?? "Selected song",
            detail: "Preparing song",
            currentItem: 1,
            totalItems: urls.count,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        )) else { return }
        defer {
            finishTransferSession(transferSessionID)
        }
        var completed = 0
        var failed = 0
        for (index, source) in urls.enumerated() {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let uploadFilename = MobileServerUploadNaming.filename(for: source)
                uploadDetail = "Uploading \(index + 1) of \(urls.count) • \(uploadFilename)"
                guard let managedTrack = MobileManagedTrackUploadPolicy.managedTrack(
                    matching: source,
                    tracks: tracks,
                    musicDirectory: musicDirectory
                ) else { throw SourceLinkRequiredError() }
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: source.absoluteString,
                    songTitle: managedTrack.title,
                    detail: "Uploading song",
                    currentItem: index + 1,
                    totalItems: urls.count
                )
                try MobileRemoteAssociationPolicy.validateAdoption(
                    track: managedTrack,
                    targetContext: uploadContext
                )
                let uploadedSong = try await uploadServerFile(
                    managedTrack,
                    to: baseURL,
                    profileID: uploadProfileID
                )
                guard isCurrentServerContext(baseURL: baseURL, profileID: uploadProfileID) else { continue }
                recordUploadedSong(uploadedSong)
                completed += 1
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: source.absoluteString,
                    songTitle: managedTrack.title,
                    detail: "Upload complete",
                    currentItem: index + 1,
                    totalItems: urls.count,
                    fallbackProgress: 1
                )
            } catch {
                failed += 1
                if error is MobileRemoteAssociationError {
                    showTransferNotice(
                        title: "Upload blocked; server link kept",
                        detail: error.localizedDescription,
                        isError: true
                    )
                }
                recordTransferFailure(
                    .upload,
                    item: source.lastPathComponent,
                    reason: error.localizedDescription,
                    retryTarget: .uploadFile(source)
                )
            }
        }
        uploadDetail = failed == 0
            ? "Uploaded \(completed) song\(completed == 1 ? "" : "s")"
            : "Uploaded \(completed) of \(urls.count) • \(failed) failed"
        serverMessage = uploadDetail

        // The admin upload response (including HTTP 409 duplicate details)
        // reconciles the catalog without requiring an access-token refresh.
    }

    var canUploadLocalImports: Bool {
        (activeUploadMode == .localFile || activeUploadMode == .reviewedMatch)
        && MobileUploadCredentialPolicy.canUpload(
            serverURL: normalizedServer(),
            adminKey: serverAdminToken
        )
    }

    @discardableResult
    func applyServerConfiguration(
        serverURL rawServerURL: String,
        accessToken rawAccessToken: String,
        adminToken rawAdminToken: String
    ) -> Bool {
        guard !isProfileTransitionBusy else {
            serverConfigurationMessage = "Wait for active transfers and playlist sync to finish."
            return false
        }
        let resolution: MobileServerEndpointResolution
        do {
            resolution = try MobileServerEndpointPolicy.resolve(rawServerURL)
        } catch {
            serverConfigurationMessage = error.localizedDescription
            return false
        }

        let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = rawAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousAccessToken = serverToken
        let previousAdminToken = serverAdminToken
        do {
            if accountSession?.accessToken == accessToken {
                try Self.storeToken("", key: "client")
                try Self.storeToken("", key: "admin")
            } else {
                try Self.storeToken(accessToken, key: "client")
                try Self.storeToken(adminToken, key: "admin")
            }
        } catch {
            try? Self.storeToken(previousAccessToken, key: "client")
            try? Self.storeToken(previousAdminToken, key: "admin")
            serverToken = previousAccessToken
            serverAdminToken = previousAdminToken
            serverConfigurationMessage = "Could not save the account session securely: \(error.localizedDescription)"
            return false
        }

        let previousContext = activeServerContext
        let previousServerURL = normalizedServer()?.absoluteString
        let nextContextBeforeMutation = MobileServerEndpointPolicy.context(
            serverURL: resolution.url,
            profileID: syncProfileID
        )
        if previousContext != nextContextBeforeMutation || previousServerURL != resolution.url.absoluteString {
            listenAlongController?.profileOrServerContextDidChange()
        }
        clientConfigRequestGeneration &+= 1
        captureActiveProfileState()
        serverURL = resolution.url.absoluteString
        serverToken = accessToken
        serverAdminToken = adminToken
        let nextContext = activeServerContext
        if previousContext != nextContext || previousAccessToken != accessToken {
            remoteSourceResolutions.removeAll()
        }
        if previousContext != nextContext {
            restoreActiveProfileState()
            if let currentTrack,
               currentTrack.remoteID != nil,
               !belongsToActiveServerContext(currentTrack) {
                stopTimer()
                player?.stop()
                player = nil
                isPlaying = false
                discardStreamingPlayback()
                currentTrackID = nil
                position = 0
                UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")
                UserDefaults.standard.set(position, forKey: "Resonance.position")
            }
            playbackPlaylistID = nil
            playbackQueue = tracksForActiveProfile.map(\.id)
            history.removeAll { !playbackQueue.contains($0) }
        }
        if previousContext != nextContext || previousServerURL != resolution.url.absoluteString {
            transferFailures.removeAll()
            transferNotice = nil
        }
        isServerConnected = false
        cancelRemoteSongMetadataHydration()
        advanceCatalogRequestGeneration()
        uploadedSongsAwaitingCatalog.removeAll()
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()
        useSafeClientConfiguration(status: "Using safe defaults until the server policy refreshes")
        serverConfigurationMessage = resolution.usesInsecureLocalHTTP
            ? "Local development mode uses unencrypted HTTP. Credentials will only be sent to this loopback host."
            : "Server settings saved securely."
        serverMessage = serverConfigurationMessage ?? "Server settings saved"
        save()
        return true
    }

    @discardableResult
    func reconcileLocalImportWithServer(trackID: UUID, remoteID: String) -> Bool {
        guard let baseURL = normalizedServer() else { return false }
        do {
            try adoptUploadedDownload(
                trackID: trackID,
                remoteID: remoteID,
                sourceServer: baseURL.absoluteString,
                profileID: syncProfileID
            )
            return true
        } catch {
            let detail = error.localizedDescription
            serverMessage = detail
            showTransferNotice(title: "Server link kept", detail: detail, isError: true)
            return false
        }
    }

    @discardableResult
    func uploadLocalImportToActiveProfile(
        _ track: MobileTrack,
        reviewedMatchLease: MobileReviewedMatchLease? = nil,
        transferSessionID: UUID
    ) async throws -> Bool {
        guard MobileTransferSessionPolicy.accepts(
            transferSessionID,
            activeSessionID: activeTransferSessionID
        ) else { throw CancellationError() }
        let uploadMode = activeUploadMode
        guard uploadMode == .localFile || uploadMode == .serverSourceLink || uploadMode == .reviewedMatch else {
            throw URLError(.dataNotAllowed)
        }
        if uploadMode == .reviewedMatch {
            guard let reviewedMatchLease,
                  isReviewedMatchLeaseCurrent(reviewedMatchLease) else {
                throw MobileTransferPolicyChangedError.changed
            }
        } else if reviewedMatchLease != nil {
            throw MobileTransferPolicyChangedError.changed
        }
        let requiresAuthoritativeRawUpload = reviewedMatchLease != nil
        guard let currentTrack = tracks.first(where: { $0.id == track.id }) else {
            throw URLError(.fileDoesNotExist)
        }
        guard let baseURL = normalizedServer() else { throw URLError(.badURL) }
        let uploadProfileID = syncProfileID
        guard !serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        let activeCachedSongs = cachedRemoteSongsForUploadPlanning
        guard let expectedContext = MobileServerEndpointPolicy.context(
            serverURL: baseURL,
            profileID: uploadProfileID
        ) else { throw URLError(.badURL) }
        try MobileRemoteAssociationPolicy.validateAdoption(
            track: currentTrack,
            targetContext: expectedContext
        )
        if !requiresAuthoritativeRawUpload,
           let remoteID = currentTrack.remoteID,
           currentTrack.remoteIdentity() == MobileRemoteIdentity(context: expectedContext, remoteID: remoteID),
           activeCachedSongs.contains(where: { $0.id == remoteID }) {
            return false
        }
        if !requiresAuthoritativeRawUpload,
           let hash = MobileContentHashPolicy.normalizedSHA256(currentTrack.contentSHA256),
           let existing = activeCachedSongs.first(where: {
               MobileContentHashPolicy.normalizedSHA256($0.contentSHA256) == hash
           }) {
            try adoptUploadedDownload(
                trackID: currentTrack.id,
                remoteID: existing.id,
                sourceServer: baseURL.absoluteString,
                profileID: uploadProfileID
            )
            return false
        }
        let uploadedSong = try await uploadServerFile(
            currentTrack,
            to: baseURL,
            profileID: uploadProfileID,
            reviewedMatchLease: reviewedMatchLease
        )
        guard MobileTransferSessionPolicy.accepts(
            transferSessionID,
            activeSessionID: activeTransferSessionID
        ) else { throw CancellationError() }
        if let reviewedMatchLease {
            guard MobileReviewedUploadCompletionPolicy.shouldReconcileCommittedResponse(
                requestContextCurrent: isReviewedMatchRequestContextCurrent(reviewedMatchLease),
                leaseStillCurrent: isReviewedMatchLeaseCurrent(reviewedMatchLease)
            ) else {
                throw URLError(.cancelled)
            }
        }
        guard isCurrentServerContext(baseURL: baseURL, profileID: uploadProfileID) else {
            throw URLError(.cancelled)
        }
        recordUploadedSong(uploadedSong)
        try adoptUploadedDownload(
            trackID: currentTrack.id,
            remoteID: uploadedSong.id,
            sourceServer: baseURL.absoluteString,
            profileID: uploadProfileID
        )
        isServerConnected = true
        serverMessage = "Connected • \(remoteSongs.count) song\(remoteSongs.count == 1 ? "" : "s")"
        return true
    }

    func showTransferNotice(title: String, detail: String, isError: Bool) {
        transferNotice = MobileTransferNotice(title: title, detail: detail, isError: isError)
    }

    @discardableResult
    func beginTransferSession(with display: MobileTransferDisplayState) -> UUID? {
        guard let sessionID = reserveTransferSession(kind: display.kind) else { return nil }
        applyTransferSession(display, sessionID: sessionID)
        return sessionID
    }

    private func reserveTransferSession(
        kind: MobileTransferDisplayState.Kind,
        requiresReceivedBytes: Bool = false
    ) -> UUID? {
        guard MobileTransferSessionPolicy.canBegin(
            activeSessionID: activeTransferSessionID
        ) else { return nil }
        let sessionID = UUID()
        activeTransferSessionID = sessionID
        byteGatedDownloadSessionID = kind == .download && requiresReceivedBytes ? sessionID : nil
        activeNativeDownloadOperationID = nil
        activeNativeDownloadPresentationOperationID = nil
        transferDisplay = nil
        isDownloading = kind == .download
        isUploading = kind == .upload
        return sessionID
    }

    func updateTransferSession(
        _ sessionID: UUID,
        with display: MobileTransferDisplayState
    ) {
        applyTransferSession(display, sessionID: sessionID)
    }

    func finishTransferSession(_ sessionID: UUID) {
        guard MobileTransferSessionPolicy.accepts(
            sessionID,
            activeSessionID: activeTransferSessionID
        ) else { return }
        activeTransferSessionID = nil
        byteGatedDownloadSessionID = nil
        activeNativeDownloadOperationID = nil
        activeNativeDownloadPresentationOperationID = nil
        isDownloading = false
        isUploading = false
        transferDisplay = nil
    }

    private func applyTransferSession(
        _ display: MobileTransferDisplayState,
        sessionID: UUID
    ) {
        guard MobileTransferSessionPolicy.accepts(
            sessionID,
            activeSessionID: activeTransferSessionID
        ) else { return }
        isDownloading = display.kind == .download
        isUploading = display.kind == .upload
        switch display.kind {
        case .download:
            downloadDetail = display.detail
        case .upload:
            uploadDetail = display.detail
        }
        publishTransfer(display)
    }

    private func beginNativeDownloadOperation(sessionID: UUID) -> UUID? {
        guard MobileTransferSessionPolicy.accepts(
            sessionID,
            activeSessionID: activeTransferSessionID
        ), activeNativeDownloadOperationID == nil else { return nil }
        let operationID = UUID()
        activeNativeDownloadOperationID = operationID
        activeNativeDownloadPresentationOperationID = operationID
        return operationID
    }

    private func finishNativeDownloadOperation(sessionID: UUID, operationID: UUID) {
        guard MobileTransferSessionPolicy.acceptsOperation(
            sessionID: sessionID,
            operationID: operationID,
            activeSessionID: activeTransferSessionID,
            activeOperationID: activeNativeDownloadOperationID
        ) else { return }
        activeNativeDownloadOperationID = nil
        if activeNativeDownloadPresentationOperationID == operationID {
            activeNativeDownloadPresentationOperationID = nil
        }
    }

    private func endNativeDownloadBytePresentation(
        sessionID: UUID,
        operationID: UUID,
        preserveForNextItem: Bool = false
    ) {
        guard ownsNativeDownloadOperation(sessionID: sessionID, operationID: operationID) else { return }
        activeNativeDownloadPresentationOperationID = nil
        if !preserveForNextItem {
            hideTransferPresentation(sessionID: sessionID)
        }
    }

    private func hideTransferPresentation(sessionID: UUID) {
        guard MobileTransferSessionPolicy.accepts(
            sessionID,
            activeSessionID: activeTransferSessionID
        ) else { return }
        transferDisplay = nil
        downloadProgress = 0
    }

    private func ownsNativeDownloadOperation(sessionID: UUID, operationID: UUID) -> Bool {
        MobileTransferSessionPolicy.acceptsOperation(
            sessionID: sessionID,
            operationID: operationID,
            activeSessionID: activeTransferSessionID,
            activeOperationID: activeNativeDownloadOperationID
        )
    }

    private func presentTransfer(
        sessionID: UUID,
        operationID: UUID? = nil,
        kind: MobileTransferDisplayState.Kind,
        itemID: String,
        songTitle: String,
        detail: String,
        currentItem: Int,
        totalItems: Int,
        completedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        fallbackProgress: Double? = nil
    ) {
        guard MobileTransferSessionPolicy.accepts(
            sessionID,
            activeSessionID: activeTransferSessionID
        ) else { return }
        if let operationID,
           !ownsNativeDownloadOperation(sessionID: sessionID, operationID: operationID) {
            return
        }
        if kind == .download,
           let operationID,
           !MobileTransferSessionPolicy.acceptsBytePresentation(
            operationID: operationID,
            activePresentationOperationID: activeNativeDownloadPresentationOperationID
           ) {
            return
        }
        if kind == .download, byteGatedDownloadSessionID == sessionID {
            let hasReceivedBytes = transferDisplay?.kind == .download
                && transferDisplay?.itemID == itemID
                && (transferDisplay?.completedBytes ?? 0) > 0
            guard MobileDownloadTransferPresentationPolicy.shouldPresent(
                completedBytes: completedBytes,
                fallbackProgress: fallbackProgress,
                hasReceivedBytes: hasReceivedBytes
            ) else { return }
        }
        let display = MobileTransferDisplayState(
            kind: kind,
            itemID: itemID,
            songTitle: songTitle,
            detail: detail,
            currentItem: currentItem,
            totalItems: totalItems,
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fallbackProgress: fallbackProgress
        )
        applyTransferSession(display, sessionID: sessionID)
    }

    private func publishTransfer(_ display: MobileTransferDisplayState) {
        transferDisplay = display
        switch display.kind {
        case .download:
            downloadProgress = display.progress ?? 0
        case .upload:
            uploadProgress = display.progress ?? 0
        }
    }

    func dismissTransferNotice() {
        transferNotice = nil
    }

    func uploadDownloadedSongsMissingFromServer() async {
        await uploadDownloadedSongsMissingFromServer(trackIDs: nil)
    }

    private func uploadDownloadedSongsMissingFromServer(trackIDs: Set<UUID>?) async {
        guard activeUploadMode == .localFile else {
            uploadDetail = "Choose Preserved source link upload mode first"
            serverMessage = uploadDetail
            return
        }
        guard !isUploadTransferBusy else { return }
        guard let baseURL = normalizedServer() else {
            uploadDetail = "Enter a valid server URL"
            serverMessage = uploadDetail
            return
        }
        guard !serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            uploadDetail = "Sign in to your Resonance account"
            serverMessage = uploadDetail
            return
        }
        let uploadProfileID = syncProfileID

        uploadDetail = "Checking downloaded songs…"
        guard let transferSessionID = beginTransferSession(with: MobileTransferDisplayState(
            kind: .upload,
            itemID: "missing-server-songs",
            songTitle: "Checking library",
            detail: "Finding songs to upload",
            currentItem: 1,
            totalItems: 1,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        )) else { return }
        var transferSessionFinished = false
        defer {
            if !transferSessionFinished {
                finishTransferSession(transferSessionID)
            }
        }
        var shouldSyncPlaylists = false

        do {
            // Use only the active cached catalog for duplicate planning.
            // The PUT endpoint's HTTP 409 response is authoritative when
            // no access-token catalog is available.
            let catalog = isServerConnected ? remoteSongs : []
            let plan = MobileMissingServerUploadPolicy.plan(
                tracks: tracks,
                catalog: catalog,
                activeProfileID: uploadProfileID,
                activeServerURL: baseURL
            )
            for (trackID, remoteID) in plan.existingRemoteIDsByTrackID
                where trackIDs == nil || trackIDs?.contains(trackID) == true {
                try adoptUploadedDownload(
                    trackID: trackID,
                    remoteID: remoteID,
                    sourceServer: baseURL.absoluteString,
                    profileID: uploadProfileID
                )
            }
            let candidateIDs = plan.uploadTrackIDs.filter {
                trackIDs == nil || trackIDs?.contains($0) == true
            }
            let candidates = candidateIDs.compactMap { trackID in
                tracks.first(where: { $0.id == trackID })
            }
            guard !candidates.isEmpty else {
                uploadDetail = "All downloaded songs are already on the server"
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: "missing-server-songs",
                    songTitle: "Downloaded songs",
                    detail: uploadDetail,
                    currentItem: 1,
                    totalItems: 1,
                    fallbackProgress: 1
                )
                serverMessage = uploadDetail
                return
            }

            var uploadedCount = 0
            var failures: [String] = []
            for (index, track) in candidates.enumerated() {
                try Task.checkCancellation()
                let source = fileURL(for: track)
                uploadDetail = "Uploading \(index + 1) of \(candidates.count) • \(MobileServerUploadNaming.filename(for: source, title: track.title))"
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: track.id.uuidString,
                    songTitle: track.title,
                    detail: "Uploading song",
                    currentItem: index + 1,
                    totalItems: candidates.count
                )
                var uploadedSong: MobileRemoteSong?
                var lastError: Error?
                for attempt in 1...3 {
                    do {
                        if attempt > 1 {
                            try await Task.sleep(for: .milliseconds(attempt == 2 ? 400 : 1_200))
                        }
                        uploadedSong = try await uploadServerFile(
                            track,
                            to: baseURL,
                            profileID: uploadProfileID
                        )
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }

                if let uploadedSong {
                    guard isCurrentServerContext(baseURL: baseURL, profileID: uploadProfileID) else {
                        throw CancellationError()
                    }
                    uploadedCount += 1
                    recordUploadedSong(uploadedSong)
                    try adoptUploadedDownload(
                        trackID: track.id,
                        remoteID: uploadedSong.id,
                        sourceServer: baseURL.absoluteString,
                        profileID: uploadProfileID
                    )
                } else {
                    let name = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
                    let reason = lastError?.localizedDescription ?? "Upload failed."
                    failures.append("\(name) (\(reason))")
                    recordTransferFailure(
                        .upload,
                        item: name,
                        reason: reason,
                        retryTarget: .uploadTrack(trackID: track.id)
                    )
                }
                presentTransfer(
                    sessionID: transferSessionID,
                    kind: .upload,
                    itemID: track.id.uuidString,
                    songTitle: track.title,
                    detail: uploadedSong == nil ? "Upload failed" : "Upload complete",
                    currentItem: index + 1,
                    totalItems: candidates.count,
                    fallbackProgress: 1
                )
            }

            let matchedCount = plan.existingRemoteIDsByTrackID.count
            if failures.isEmpty {
                uploadDetail = "Uploaded \(uploadedCount); matched \(matchedCount) already on the server"
            } else {
                uploadDetail = "Uploaded \(uploadedCount); failed: \(failures.joined(separator: ", "))"
            }
            serverMessage = uploadDetail
            shouldSyncPlaylists = !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch is CancellationError {
            uploadDetail = "Upload cancelled"
            serverMessage = uploadDetail
        } catch {
            isServerConnected = false
            uploadDetail = "Upload failed: \(error.localizedDescription)"
            serverMessage = uploadDetail
        }
        finishTransferSession(transferSessionID)
        transferSessionFinished = true
        // Playlist/like/clip synchronization must not extend the upload busy
        // state or keep the transfer overlay visible after uploads finish.
        if shouldSyncPlaylists {
            await syncPlaylistsNow()
        }
    }

    private func uploadServerFile(
        _ track: MobileTrack,
        to baseURL: URL,
        profileID: String,
        reviewedMatchLease: MobileReviewedMatchLease? = nil
    ) async throws -> MobileRemoteSong {
        let requiredMode: MobileUploadMode = reviewedMatchLease == nil
            ? (activeUploadMode ?? .localFile)
            : .reviewedMatch
        guard let uploadLease = captureRawUploadLease(
            mode: requiredMode,
            baseURL: baseURL,
            profileID: profileID
        ) else {
            throw MobileTransferPolicyChangedError.changed
        }
        await uploadSerialGate.acquire()
        defer { Task { await uploadSerialGate.release() } }
        try Task.checkCancellation()
        guard isRawUploadLeaseCurrent(uploadLease) else {
            throw MobileTransferPolicyChangedError.changed
        }
        if let reviewedMatchLease,
           !isReviewedMatchLeaseCurrent(reviewedMatchLease) {
            throw MobileTransferPolicyChangedError.changed
        }

        guard let rawSource = track.sourceURL ?? track.downloadSourceURL,
              let sourceURL = URL(string: rawSource),
              sourceURL.scheme?.lowercased() == "https",
              sourceURL.user == nil,
              sourceURL.password == nil else { throw SourceLinkRequiredError() }
        let url = baseURL.appendingPathComponent("api/v1/admin/songs")
        guard MobileSameOriginPolicy.matches(url, baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 90
        let mediaKind = ["mp4", "mov", "m4v", "webm"].contains(
            URL(fileURLWithPath: track.relativePath).pathExtension.lowercased()
        ) ? "video" : "audio"
        request.httpBody = try JSONEncoder().encode(SourceLinkUploadDocument(
            sourceURL: sourceURL.absoluteString,
            mediaKind: mediaKind
        ))
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let reviewedMatchLease {
            guard reviewedMatchLease.profileID == profileID,
                  MobileClientConfigOrigin.normalized(baseURL) == reviewedMatchLease.origin,
                  reviewedMatchLease.requestContext == uploadLease.requestContext else {
                throw MobileTransferPolicyChangedError.changed
            }
            reviewedMatchLease.requestContext.apply(to: &request)
        } else {
            uploadLease.requestContext.apply(to: &request)
        }
        guard isRawUploadLeaseCurrent(uploadLease) else {
            throw MobileTransferPolicyChangedError.changed
        }
        if let reviewedMatchLease, !isReviewedMatchLeaseCurrent(reviewedMatchLease) {
            throw MobileTransferPolicyChangedError.changed
        }
        var (data, response) = try await sameOriginData(
            for: request,
            origin: baseURL,
            maximumBytes: 2 * 1_024 * 1_024
        )
        if mediaKind == "audio",
           sourceLinkSchemaUnsupported(response: response, data: data) {
            guard isRawUploadLeaseCurrent(uploadLease) else {
                throw MobileTransferPolicyChangedError.changed
            }
            if let reviewedMatchLease, !isReviewedMatchLeaseCurrent(reviewedMatchLease) {
                throw MobileTransferPolicyChangedError.changed
            }
            request.httpBody = try JSONEncoder().encode(SourceLinkUploadDocument(
                sourceURL: sourceURL.absoluteString,
                mediaKind: mediaKind,
                schemaVersion: 2
            ))
            (data, response) = try await sameOriginData(
                for: request,
                origin: baseURL,
                maximumBytes: 2 * 1_024 * 1_024
            )
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 201,
           let song = try? JSONDecoder().decode(MobileRemoteSong.self, from: data) {
            guard isRawUploadRequestContextCurrent(uploadLease) else {
                throw CancellationError()
            }
            return song
        }
        if http.statusCode == 409,
           let duplicate = try? JSONDecoder().decode(DuplicateSongUploadResponse.self, from: data) {
            guard isRawUploadRequestContextCurrent(uploadLease) else {
                throw CancellationError()
            }
            return duplicate.duplicateOf
        }
        throw playlistServerError(status: http.statusCode, data: data)
    }

    private func recordUploadedSong(_ song: MobileRemoteSong) {
        catalogMutationGeneration &+= 1
        invalidateFullCatalogAuthority()
        uploadedSongsAwaitingCatalog[song.id] = song
        remoteSongs = [song] + remoteSongs.filter { $0.id != song.id }
    }

    private func adoptUploadedDownload(
        trackID: UUID,
        remoteID: String,
        sourceServer: String,
        profileID: String,
        persistImmediately: Bool = true
    ) throws {
        guard let targetIndex = tracks.firstIndex(where: { $0.id == trackID }) else {
            throw URLError(.fileDoesNotExist)
        }
        let oldTrack = tracks[targetIndex]
        let oldRemoteID = oldTrack.remoteID
        let oldClipKey = clipRangeKey(for: oldTrack)
        guard let activeSource = URL(string: sourceServer),
              let targetContext = MobileServerEndpointPolicy.context(
                  serverURL: activeSource,
                  profileID: profileID
              ) else { throw URLError(.badURL) }
        try MobileRemoteAssociationPolicy.validateAdoption(
            track: oldTrack,
            targetContext: targetContext
        )
        let expectedIdentity = MobileRemoteIdentity(context: targetContext, remoteID: remoteID)
        let newClipKey = clipRangeKey(identity: expectedIdentity)
        let duplicateIDs = Set(tracks.compactMap { candidate -> UUID? in
            guard candidate.id != trackID,
                  candidate.remoteIdentity() == expectedIdentity else { return nil }
            return candidate.id
        })
        tracks[targetIndex].remoteID = remoteID
        tracks[targetIndex].sourceServer = sourceServer
        tracks[targetIndex].syncProfileID = profileID

        let remapTrackIDs: ([UUID]) -> [UUID] = { values in
            var seen = Set<UUID>()
            return values.compactMap { value in
                let mapped = duplicateIDs.contains(value) ? trackID : value
                return seen.insert(mapped).inserted ? mapped : nil
            }
        }
        let wasFavorite = favorites.contains(trackID) || !favorites.isDisjoint(with: duplicateIDs)
        favorites.subtract(duplicateIDs)
        if wasFavorite { favorites.insert(trackID) }

        for index in playlists.indices where !playlists[index].isSystem {
            let referencedTrack = playlists[index].trackIDs.contains(trackID)
                || playlists[index].trackIDs.contains(where: duplicateIDs.contains)
            let referencedRemote = oldRemoteID.map { playlists[index].remoteSongIDs?.contains($0) == true } ?? false
            playlists[index].trackIDs = remapTrackIDs(playlists[index].trackIDs)
            guard referencedTrack || referencedRemote else { continue }
            var remoteIDs = playlists[index].remoteSongIDs ?? []
            if let oldRemoteID {
                remoteIDs = remoteIDs.map { $0 == oldRemoteID ? remoteID : $0 }
            }
            if !remoteIDs.contains(remoteID) { remoteIDs.append(remoteID) }
            playlists[index].remoteSongIDs = Array(remoteIDs.reduce(into: [String]()) { result, value in
                if !result.contains(value) { result.append(value) }
            })
            updateRemoteSongIDs(forPlaylistAt: index)
            playlistMutationGeneration &+= 1
            dirtyPlaylistIDs.insert(playlists[index].id)
        }

        history = history.map { duplicateIDs.contains($0) ? trackID : $0 }
        playbackQueue = remapTrackIDs(playbackQueue)
        if let currentTrackID, duplicateIDs.contains(currentTrackID) { self.currentTrackID = trackID }
        tracks.removeAll { duplicateIDs.contains($0.id) }

        if oldClipKey != newClipKey, let range = clipRanges.removeValue(forKey: oldClipKey) {
            clipRanges[newClipKey] = range
            dirtyClipRangeKeys.insert(newClipKey)
            if oldRemoteID != nil {
                dirtyClipRangeKeys.insert(oldClipKey)
                deletedClipRangeKeys.insert(oldClipKey)
            }
        }
        if wasFavorite {
            likesMutationGeneration &+= 1
            if let oldRemoteID, oldRemoteID != remoteID {
                remoteLikedSongIDs.remove(oldRemoteID)
                dirtyRemoteLikeSongIDs.insert(oldRemoteID)
            }
            remoteLikedSongIDs.insert(remoteID)
            dirtyRemoteLikeSongIDs.insert(remoteID)
            likesDirty = true
        }
        normalizeSystemPlaylist()
        if persistImmediately { save() }
        schedulePlaylistSync()
    }

    func deleteRemoteSong(_ song: MobileRemoteSong) async {
        guard !isActivatingSyncProfile else { return }
        guard let baseURL = normalizedServer(), !serverAdminToken.isEmpty else {
            recordTransferFailure(
                .delete,
                item: song.title,
                reason: "Sign in to your Resonance account first.",
                retryTarget: .delete(remoteSongID: song.id)
            )
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/admin/songs/\(song.id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        setProfileHeader(on: &request)
        do {
            let (data, response) = try await sameOriginData(
                for: request,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.profileMaximumBytes
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 204 else {
                let detail = (try? JSONDecoder().decode(ServerErrorPayload.self, from: data).error)
                recordTransferFailure(
                    .delete,
                    item: song.title,
                    reason: detail.map { "HTTP \(status): \($0)" } ?? "Server returned HTTP \(status).",
                    retryTarget: .delete(remoteSongID: song.id)
                )
                return
            }
            catalogMutationGeneration &+= 1
            invalidateFullCatalogAuthority()
            uploadedSongsAwaitingCatalog.removeValue(forKey: song.id)
            remoteSongs.removeAll { $0.id == song.id }
            selectedRemoteSongIDs.remove(song.id)
        } catch {
            recordTransferFailure(
                .delete,
                item: song.title,
                reason: error.localizedDescription,
                retryTarget: .delete(remoteSongID: song.id)
            )
        }
    }

    func syncListeningHistoryAutomatically() async {
        guard listeningHistorySyncContext() != nil else { return }
        await syncListeningHistoryNow()
    }

    func syncListeningHistoryNow() async {
        guard !isSyncingListeningHistory else {
            listeningHistorySyncPending = true
            return
        }
        guard let context = listeningHistorySyncContext() else { return }
        isSyncingListeningHistory = true
        listeningHistorySyncTask?.cancel()
        listeningHistorySyncTask = nil
        defer {
            isSyncingListeningHistory = false
            if listeningHistorySyncPending {
                listeningHistorySyncPending = false
                scheduleListeningHistorySync(delay: .zero)
            }
        }

        do {
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let pendingEntries = listeningHistoryEntries.filter { entry in
                entry.originatedOnThisDevice != false
                    && MobileListeningHistoryPolicy.normalizedOrigin(entry.serverOrigin) == context.origin
                    && (entry.syncProfileID ?? "default") == context.profileID
                    && (entry.accountID == nil || entry.accountID == context.accountID)
                    && MobileListeningHistoryPolicy.qualifies(entry, trackDuration: tracksByID[entry.trackID]?.duration)
                    && (listeningHistorySyncedSeconds[listeningHistorySyncKey(context: context, eventID: entry.id)] ?? -1)
                        < entry.listenedSeconds
            }
            var shouldRetry = false
            for pendingBatch in MobileListeningHistoryPolicy.batches(pendingEntries) {
                guard isCurrentListeningHistoryContext(context) else {
                    listeningHistorySyncPending = true
                    return
                }
                let uploadBatch = pendingBatch.compactMap { entry -> (MobileListeningHistoryEntry, MobileListeningHistoryUploadEntry)? in
                    guard let upload = MobileListeningHistoryPolicy.uploadEntry(
                        entry,
                        track: tracksByID[entry.trackID],
                        origin: context.origin,
                        profileID: context.profileID,
                        accountID: context.accountID
                    ) else { return nil }
                    return (entry, upload)
                }
                guard !uploadBatch.isEmpty else { continue }
                do {
                    guard try await postListeningHistory(uploadBatch.map(\.1), context: context) else { break }
                    guard isCurrentListeningHistoryContext(context) else {
                        listeningHistorySyncPending = true
                        return
                    }
                    for (entry, _) in uploadBatch {
                        listeningHistorySyncedSeconds[listeningHistorySyncKey(context: context, eventID: entry.id)] = entry.listenedSeconds
                    }
                    persistListeningHistory()
                } catch is CancellationError {
                    return
                } catch {
                    shouldRetry = true
                    break
                }
            }

            guard isCurrentListeningHistoryContext(context),
                  let remoteDocument = try await fetchListeningHistory(context: context) else { return }
            guard isCurrentListeningHistoryContext(context) else {
                listeningHistorySyncPending = true
                return
            }
            listeningHistoryEntries = MobileListeningHistoryPolicy.merge(
                remoteDocument,
                into: listeningHistoryEntries,
                tracks: tracks,
                catalog: remoteSongs,
                origin: context.origin,
                profileID: context.profileID,
                accountID: context.accountID
            )
            for remote in remoteDocument.entries {
                guard let eventID = UUID(uuidString: remote.id) else { continue }
                let key = listeningHistorySyncKey(context: context, eventID: eventID)
                listeningHistorySyncedSeconds[key] = max(
                    listeningHistorySyncedSeconds[key] ?? 0,
                    MobileListeningHistoryPolicy.clampedListenedSeconds(remote.listenedSeconds)
                )
            }
            persistListeningHistory()
            if shouldRetry { scheduleListeningHistorySync(delay: .seconds(60)) }
        } catch is CancellationError {
            return
        } catch {
            scheduleListeningHistorySync(delay: .seconds(60))
        }
    }

    private func listeningHistorySyncContext() -> ListeningHistorySyncContext? {
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              let baseURL = normalizedServer(),
              let origin = MobileServerEndpointPolicy.normalizedOrigin(of: baseURL) else { return nil }
        return ListeningHistorySyncContext(
            baseURL: baseURL,
            origin: origin,
            profileID: syncProfileID,
            accountID: accountSession?.accountID,
            token: token,
            generation: listeningHistorySyncGeneration
        )
    }

    private func isCurrentListeningHistoryContext(_ context: ListeningHistorySyncContext) -> Bool {
        guard context.generation == listeningHistorySyncGeneration,
              context.profileID == syncProfileID,
              context.accountID == accountSession?.accountID,
              context.token == serverToken.trimmingCharacters(in: .whitespacesAndNewlines),
              normalizedServer()?.absoluteString == context.baseURL.absoluteString else { return false }
        return true
    }

    private func listeningHistorySyncKey(
        context: ListeningHistorySyncContext,
        eventID: UUID
    ) -> String {
        let account = context.accountID ?? "anonymous"
        return "\(context.origin)#profile=\(context.profileID)#account=\(account)#event=\(eventID.uuidString.lowercased())"
    }

    private func invalidateListeningHistorySync() {
        listeningHistorySyncGeneration &+= 1
        listeningHistorySyncTask?.cancel()
        listeningHistorySyncTask = nil
        listeningHistorySyncPending = false
    }

    private func scheduleListeningHistorySync(delay: Duration = .seconds(2)) {
        guard listeningHistorySyncContext() != nil else { return }
        listeningHistorySyncTask?.cancel()
        listeningHistorySyncTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.listeningHistorySyncTask = nil
            await self.syncListeningHistoryNow()
        }
    }

    private func postListeningHistory(
        _ entries: [MobileListeningHistoryUploadEntry],
        context: ListeningHistorySyncContext
    ) async throws -> Bool {
        guard !entries.isEmpty else { return true }
        var request = URLRequest(url: context.baseURL.appendingPathComponent("api/v1/listening-history"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue(context.profileID, forHTTPHeaderField: "X-Resonance-Profile")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(MobileListeningHistoryUploadDocument(entries: entries))
        let (data, response) = try await sameOriginData(
            for: request,
            origin: context.baseURL,
            maximumBytes: 256 * 1_024
        )
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 || http.statusCode == 405 { return false }
        guard (200..<300).contains(http.statusCode) else {
            throw playlistServerError(status: http.statusCode, data: data)
        }
        return true
    }

    private func fetchListeningHistory(
        context: ListeningHistorySyncContext
    ) async throws -> MobileRemoteListeningHistoryDocument? {
        var components = URLComponents(
            url: context.baseURL.appendingPathComponent("api/v1/listening-history"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "2000")]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(context.token)", forHTTPHeaderField: "Authorization")
        request.setValue(context.profileID, forHTTPHeaderField: "X-Resonance-Profile")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await sameOriginData(
            for: request,
            origin: context.baseURL,
            maximumBytes: 8 * 1_024 * 1_024
        )
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 404 || http.statusCode == 405 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw playlistServerError(status: http.statusCode, data: data)
        }
        return try JSONDecoder().decode(MobileRemoteListeningHistoryDocument.self, from: data)
    }

    func syncPlaylistsNow() async {
        guard !isActivatingSyncProfile, !isSyncingPlaylists else { return }
        guard let baseURL = normalizedServer() else {
            playlistSyncDetail = "Enter a valid server URL"
            return
        }
        guard !serverToken.isEmpty else {
            playlistSyncDetail = "Sign in to your Resonance account"
            return
        }
        let submittedProfileID = syncProfileID

        let serverKey = "\(baseURL.absoluteString)#profile=\(syncProfileID)"
        if playlistSyncServerURL != serverKey {
            playlistSyncServerURL = serverKey
            playlistRevision = 0
            knownRemotePlaylistIDs.removeAll()
            deletedPlaylistIDs.removeAll()
            dirtyPlaylistIDs.formUnion(playlists.filter { !$0.isSystem }.map(\.id))
        }

        isSyncingPlaylists = true
        playlistSyncDetail = "Syncing playlists…"
        defer { isSyncingPlaylists = false }

        do {
            var remoteDocument = try await fetchRemotePlaylists(from: baseURL)
            guard isCurrentServerContext(baseURL: baseURL, profileID: submittedProfileID) else { return }
            var attempts = 0

            while attempts < 2 {
                let merge = mergedPlaylistDocument(from: remoteDocument)
                if !merge.needsUpload {
                    applyRemotePlaylists(remoteDocument)
                    playlistSyncDetail = "Synced \(remoteDocument.playlists.count) playlist\(remoteDocument.playlists.count == 1 ? "" : "s")"
                    return
                }

                let submittedLikesGeneration = likesMutationGeneration
                let submittedDirtyLikeIDs = dirtyRemoteLikeSongIDs
                let submittedClipGeneration = clipRangeMutationGeneration
                let submittedDirtyClipKeys = dirtyClipRangeKeys.filter(isActiveProfileClipKey)
                let submittedPlaylistGeneration = playlistMutationGeneration
                switch try await putRemotePlaylists(merge.document, to: baseURL) {
                case .updated(let updated):
                    guard isCurrentServerContext(baseURL: baseURL, profileID: submittedProfileID) else { return }
                    let canApplySubmittedPlaylists = MobilePlaylistSyncResponsePolicy.shouldApplyResponse(
                        submittedMutationGeneration: submittedPlaylistGeneration,
                        currentMutationGeneration: playlistMutationGeneration
                    )
                    if canApplySubmittedPlaylists {
                        dirtyPlaylistIDs.removeAll()
                        deletedPlaylistIDs.removeAll()
                    }
                    if likesMutationGeneration == submittedLikesGeneration {
                        dirtyRemoteLikeSongIDs.subtract(submittedDirtyLikeIDs)
                    }
                    likesDirty = !dirtyRemoteLikeSongIDs.isEmpty
                    if clipRangeMutationGeneration == submittedClipGeneration {
                        dirtyClipRangeKeys.subtract(submittedDirtyClipKeys)
                        deletedClipRangeKeys.subtract(submittedDirtyClipKeys)
                    }
                    if canApplySubmittedPlaylists {
                        applyRemotePlaylists(updated)
                        playlistSyncDetail = "Synced \(updated.playlists.count) playlist\(updated.playlists.count == 1 ? "" : "s")"
                    } else {
                        playlistRevision = updated.revision
                        knownRemotePlaylistIDs = Set(updated.playlists.map(\.id))
                        playlistSyncDetail = "Saved; syncing newer playlist changes…"
                        save()
                    }
                    if !canApplySubmittedPlaylists
                        || likesDirty
                        || dirtyClipRangeKeys.contains(where: isActiveProfileClipKey) {
                        schedulePlaylistSync()
                    }
                    return
                case .conflict(let current):
                    guard isCurrentServerContext(baseURL: baseURL, profileID: submittedProfileID) else { return }
                    remoteDocument = current
                    attempts += 1
                }
            }

            playlistSyncDetail = "Playlist sync conflicted; try again"
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            playlistSyncDetail = "Playlist sync failed: \(error.localizedDescription)"
        }
    }

    func syncPlaylistsAutomatically() async {
        guard normalizedServer() != nil,
              !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await syncPlaylistsNow()
        await syncListeningHistoryAutomatically()
    }

    func runAutomaticPlaylistSync() async {
        await syncPlaylistsAutomatically()
        retryPendingRemoteSongMetadata()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await syncPlaylistsAutomatically()
            retryPendingRemoteSongMetadata()
        }
    }

    private enum PlaylistPutResult {
        case updated(MobileRemotePlaylistsDocument)
        case conflict(MobileRemotePlaylistsDocument)
    }

    private func fetchRemotePlaylists(from baseURL: URL) async throws -> MobileRemotePlaylistsDocument {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/playlists"))
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        setProfileHeader(on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await sameOriginData(
            for: request,
            origin: baseURL,
            maximumBytes: MobileBoundedResponsePolicy.playlistMaximumBytes
        )
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw URLError(.badServerResponse)
        }
        guard status == 200 else { throw playlistServerError(status: status, data: data) }
        return try JSONDecoder().decode(MobileRemotePlaylistsDocument.self, from: data)
    }

    private func putRemotePlaylists(
        _ document: MobileRemotePlaylistsDocument,
        to baseURL: URL
    ) async throws -> PlaylistPutResult {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/playlists"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        setProfileHeader(on: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(document)
        let (data, response) = try await sameOriginData(
            for: request,
            origin: baseURL,
            maximumBytes: MobileBoundedResponsePolicy.playlistMaximumBytes
        )
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw URLError(.badServerResponse)
        }
        if status == 200 {
            return .updated(try JSONDecoder().decode(MobileRemotePlaylistsDocument.self, from: data))
        }
        if status == 409 {
            return .conflict(try JSONDecoder().decode(MobileRemotePlaylistsDocument.self, from: data))
        }
        throw playlistServerError(status: status, data: data)
    }

    private func playlistServerError(status: Int, data: Data) -> PlaylistServerError {
        let message = try? JSONDecoder().decode(ServerErrorPayload.self, from: data).error
        return PlaylistServerError(status: status, message: message)
    }

    private func sourceLinkSchemaUnsupported(response: URLResponse, data: Data) -> Bool {
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              status == 400,
              let message = try? JSONDecoder().decode(ServerErrorPayload.self, from: data).error else {
            return false
        }
        return message == "Unsupported source-link schema_version"
    }

    private func isCurrentServerContext(baseURL: URL, profileID: String) -> Bool {
        syncProfileID == profileID && normalizedServer()?.absoluteString == baseURL.absoluteString
    }

    private func mergedPlaylistDocument(
        from remote: MobileRemotePlaylistsDocument
    ) -> (document: MobileRemotePlaylistsDocument, needsUpload: Bool) {
        var merged = remote.playlists.filter { !deletedPlaylistIDs.contains($0.id) }
        let remoteIDs = Set(remote.playlists.map(\.id))
        var needsUpload = !deletedPlaylistIDs.isEmpty || likesDirty

        for playlist in playlists where !playlist.isSystem {
            let isUnsyncedLocalPlaylist = !remoteIDs.contains(playlist.id)
                && !knownRemotePlaylistIDs.contains(playlist.id)
            guard dirtyPlaylistIDs.contains(playlist.id) || isUnsyncedLocalPlaylist else { continue }

            let payload = remotePlaylist(from: playlist)
            if let index = merged.firstIndex(where: { $0.id == playlist.id }) {
                merged[index] = payload
            } else {
                merged.append(payload)
            }
            needsUpload = true
        }

        var likedSongIDs = Set(remote.likedSongIDs)
        for remoteID in dirtyRemoteLikeSongIDs {
            if remoteLikedSongIDs.contains(remoteID) {
                likedSongIDs.insert(remoteID)
            } else {
                likedSongIDs.remove(remoteID)
            }
        }

        var remoteClipRanges = remote.clipRanges.reduce(into: [String: MobileClipRange]()) { result, payload in
            result[payload.songID] = MobileClipRange(
                startSeconds: payload.startSeconds,
                endSeconds: payload.endSeconds
            )
        }
        let activeDirtyClipKeys = dirtyClipRangeKeys.filter(isActiveProfileClipKey)
        for key in activeDirtyClipKeys {
            guard let remoteID = remoteSongID(fromClipKey: key) else { continue }
            if deletedClipRangeKeys.contains(key) {
                remoteClipRanges.removeValue(forKey: remoteID)
            } else if let range = clipRanges[key] {
                remoteClipRanges[remoteID] = range
            }
        }

        return (
            MobileRemotePlaylistsDocument(
                profileID: syncProfileID,
                revision: remote.revision,
                playlists: merged,
                likedSongIDs: Array(likedSongIDs),
                clipRanges: remoteClipRanges.map {
                    MobileRemoteClipRange(songID: $0.key, startSeconds: $0.value.startSeconds, endSeconds: $0.value.endSeconds)
                }
            ),
            needsUpload || !activeDirtyClipKeys.isEmpty
        )
    }

    private func remotePlaylist(from playlist: MobilePlaylist) -> MobileRemotePlaylist {
        var songIDs: [String] = []
        for trackID in playlist.trackIDs {
            guard let track = tracks.first(where: { $0.id == trackID }),
                  belongsToActiveServerContext(track),
                  let remoteID = track.remoteID,
                  !songIDs.contains(remoteID) else { continue }
            songIDs.append(remoteID)
        }
        let previousRemoteSongIDs = playlist.remoteSongIDs ?? []
        let unresolvedRemoteSongIDs = previousRemoteSongIDs.filter { remoteID in
            guard let activeServerContext else { return true }
            let identity = MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID)
            return !tracks.contains { $0.remoteIdentity() == identity }
        }
        songIDs = MobilePlaylistOrderPolicy.merge(
            previous: previousRemoteSongIDs,
            ordered: songIDs,
            preserving: unresolvedRemoteSongIDs
        )
        return MobileRemotePlaylist(id: playlist.id, name: playlist.name, songIDs: songIDs)
    }

    private func applyRemotePlaylists(_ document: MobileRemotePlaylistsDocument) {
        let existing = playlists.filter { !$0.isSystem }.reduce(into: [UUID: MobilePlaylist]()) { result, playlist in
            if result[playlist.id] == nil { result[playlist.id] = playlist }
        }
        let systemPlaylists = playlists.filter(\.isSystem)
        let uniqueRemotePlaylists = MobileCollectionNormalization.uniqueRemotePlaylists(document.playlists)
        let remotePlaylists = uniqueRemotePlaylists.map { remote -> MobilePlaylist in
            let localOnlyTrackIDs = existing[remote.id]?.trackIDs.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            } ?? []
            let downloadedTrackIDs: [UUID] = remote.songIDs.compactMap { remoteID -> UUID? in
                guard let activeServerContext else { return nil }
                let identity = MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID)
                return tracks.first(where: { $0.remoteIdentity() == identity })?.id
            }
            return MobilePlaylist(
                id: remote.id,
                name: remote.name,
                trackIDs: MobilePlaylistOrderPolicy.merge(
                    previous: existing[remote.id]?.trackIDs ?? [],
                    ordered: downloadedTrackIDs,
                    preserving: localOnlyTrackIDs
                ),
                remoteSongIDs: remote.songIDs,
                entryOrder: existing[remote.id]?.entryOrder
            )
        }

        playlists = systemPlaylists + remotePlaylists
        var mergedLikedSongIDs = Set(document.likedSongIDs)
        for remoteID in dirtyRemoteLikeSongIDs {
            if remoteLikedSongIDs.contains(remoteID) {
                mergedLikedSongIDs.insert(remoteID)
            } else {
                mergedLikedSongIDs.remove(remoteID)
            }
        }
        remoteLikedSongIDs = mergedLikedSongIDs
        let activeDirtyClipKeys = dirtyClipRangeKeys.filter(isActiveProfileClipKey)
        clipRanges = clipRanges.filter { key, _ in
            !isActiveProfileClipKey(key) || key.contains("|local:") || activeDirtyClipKeys.contains(key)
        }
        for payload in document.clipRanges {
            let key = clipRangeKey(remoteID: payload.songID)
            guard !activeDirtyClipKeys.contains(key), !deletedClipRangeKeys.contains(key),
                  payload.endSeconds - payload.startSeconds >= 0.25 else { continue }
            clipRanges[key] = MobileClipRange(startSeconds: payload.startSeconds, endSeconds: payload.endSeconds)
        }
        hydrateRemoteLikedTracks()
        playlistRevision = document.revision
        knownRemotePlaylistIDs = Set(uniqueRemotePlaylists.map(\.id))
        dirtyPlaylistIDs.subtract(knownRemotePlaylistIDs)
        likesDirty = !dirtyRemoteLikeSongIDs.isEmpty
        normalizeSystemPlaylist()
        save()
    }

    private func hydrateRemotePlaylistTracks() {
        guard let activeServerContext else { return }
        for index in playlists.indices where !playlists[index].isSystem {
            guard let remoteSongIDs = playlists[index].remoteSongIDs else { continue }
            let localOnlyTrackIDs = playlists[index].trackIDs.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            }
            let hydrated: [UUID] = remoteSongIDs.compactMap { remoteID -> UUID? in
                let identity = MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID)
                return tracks.first(where: { $0.remoteIdentity() == identity })?.id
            }
            playlists[index].trackIDs = MobilePlaylistOrderPolicy.merge(
                previous: playlists[index].trackIDs,
                ordered: hydrated,
                preserving: localOnlyTrackIDs
            )
        }
    }

    private func hydrateRemoteLikedTracks() {
        let localFavorites = favorites.filter { trackID in
            tracks.first(where: { $0.id == trackID })?.remoteID == nil
        }
        let hydratedRemoteFavorites = tracks.compactMap { track -> UUID? in
            guard let remoteID = track.remoteID,
                  let activeServerContext,
                  track.remoteIdentity() == MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID),
                  remoteLikedSongIDs.contains(remoteID) else { return nil }
            return track.id
        }
        favorites = Set(localFavorites).union(hydratedRemoteFavorites)
    }

    private func updateRemoteSongIDs(forPlaylistAt index: Int) {
        guard playlists.indices.contains(index), !playlists[index].isSystem else { return }
        let previouslyUnresolved = (playlists[index].remoteSongIDs ?? []).filter { remoteID in
            guard let activeServerContext else { return true }
            let identity = MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID)
            return !tracks.contains { $0.remoteIdentity() == identity }
        }
        let ordered: [String] = playlists[index].trackIDs.compactMap { trackID -> String? in
            guard let track = tracks.first(where: { $0.id == trackID }),
                  belongsToActiveServerContext(track) else { return nil }
            return track.remoteID
        }
        playlists[index].remoteSongIDs = MobilePlaylistOrderPolicy.merge(
            previous: playlists[index].remoteSongIDs ?? [],
            ordered: ordered,
            preserving: previouslyUnresolved
        )
    }

    private func schedulePlaylistSync() {
        playlistSyncTask?.cancel()
        guard !serverToken.isEmpty else { return }
        playlistSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncPlaylistsNow()
        }
    }

    private func clipRangeKey(for track: MobileTrack) -> String {
        if let identity = track.remoteIdentity() { return clipRangeKey(identity: identity) }
        return "local:\(track.id.uuidString.lowercased())"
    }

    private func clipRangeKey(remoteID: String) -> String {
        guard let activeServerContext else { return "unscoped|remote:\(remoteID)" }
        return clipRangeKey(identity: MobileRemoteIdentity(context: activeServerContext, remoteID: remoteID))
    }

    private func clipRangeKey(identity: MobileRemoteIdentity) -> String {
        "\(identity.context.storagePrefix)|remote:\(identity.remoteID)"
    }

    private func isActiveProfileClipKey(_ key: String) -> Bool {
        guard let activeServerContext else { return false }
        return key.hasPrefix("\(activeServerContext.storagePrefix)|remote:")
    }

    private func remoteSongID(fromClipKey key: String) -> String? {
        let marker = "|remote:"
        guard let range = key.range(of: marker), !key[range.upperBound...].isEmpty else { return nil }
        return String(key[range.upperBound...])
    }

    private func migrateLegacyClipRangeKeys(fallbackServerURL: URL?) {
        func migrated(_ key: String) -> String {
            if key.hasPrefix("origin=") || key.hasPrefix("local:") { return key }
            if let localRange = key.range(of: "|local:") {
                return "local:" + String(key[localRange.upperBound...])
            }
            guard let remoteRange = key.range(of: "|remote:"),
                  let fallbackServerURL else { return key }
            let profileID = String(key[..<remoteRange.lowerBound])
            let remoteID = String(key[remoteRange.upperBound...])
            guard let context = MobileServerEndpointPolicy.context(
                serverURL: fallbackServerURL,
                profileID: profileID
            ) else { return key }
            return clipRangeKey(identity: MobileRemoteIdentity(context: context, remoteID: remoteID))
        }

        clipRanges = clipRanges.reduce(into: [:]) { result, pair in
            result[migrated(pair.key)] = pair.value
        }
        dirtyClipRangeKeys = Set(dirtyClipRangeKeys.map(migrated))
        deletedClipRangeKeys = Set(deletedClipRangeKeys.map(migrated))
    }

    private func playbackBounds(for track: MobileTrack, duration: TimeInterval? = nil) -> (start: TimeInterval, end: TimeInterval) {
        let bounds = MobileClipPlaybackPolicy.bounds(
            range: clipRange(for: track),
            duration: duration ?? track.duration
        )
        return (bounds.start, bounds.end)
    }

    private func beginListeningHistorySession(for track: MobileTrack) {
        let serverOrigin = track.remoteIdentity()?.context.origin ?? activeServerContext?.origin
        let profileID = track.syncProfileID ?? syncProfileID
        let accountID = accountSession?.accountID
        if let activeID = activeListeningHistoryEntryID,
           let active = listeningHistoryEntries.first(where: { $0.id == activeID }),
           active.trackID == track.id,
           MobileListeningHistoryPolicy.normalizedOrigin(active.serverOrigin) == serverOrigin,
           (active.syncProfileID ?? "default") == profileID,
           active.accountID == accountID {
            lastListeningPosition = currentListeningPlaybackPosition
            return
        }
        endListeningHistorySession()
        let entry = MobileListeningHistoryEntry(
            trackID: track.id,
            serverOrigin: serverOrigin,
            syncProfileID: profileID,
            accountID: accountID,
            remoteSongID: track.remoteID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: isTransientStreamActive && streamingTrack?.id == track.id
                ? streamingArtworkURL?.absoluteString
                : nil,
            originatedOnThisDevice: true
        )
        MobileListeningHistoryPolicy.append(entry, to: &listeningHistoryEntries)
        activeListeningHistoryEntryID = entry.id
        lastListeningPosition = currentListeningPlaybackPosition
        lastPersistedListeningSeconds = 0
        pendingListeningSeconds = 0
        persistListeningHistory()
    }

    private func updateListeningHistorySession(flush: Bool = false) {
        let currentPosition = currentListeningPlaybackPosition
        guard let activeID = activeListeningHistoryEntryID,
              let index = listeningHistoryEntries.firstIndex(where: { $0.id == activeID }) else {
            lastListeningPosition = currentPosition
            pendingListeningSeconds = 0
            return
        }
        let delta = currentPosition - lastListeningPosition
        if isPlaying, delta > 0, delta < 5 { pendingListeningSeconds += delta }
        lastListeningPosition = currentPosition
        let listenedSeconds = listeningHistoryEntries[index].listenedSeconds + pendingListeningSeconds
        let reachedPersistenceBoundary = listenedSeconds - lastPersistedListeningSeconds >= 15
        guard (flush || reachedPersistenceBoundary), pendingListeningSeconds > 0 else { return }
        listeningHistoryEntries[index].listenedSeconds = MobileListeningHistoryPolicy.clampedListenedSeconds(listenedSeconds)
        pendingListeningSeconds = 0
        lastPersistedListeningSeconds = listeningHistoryEntries[index].listenedSeconds
        persistListeningHistory()
        scheduleListeningHistorySync()
    }

    private func endListeningHistorySession() {
        updateListeningHistorySession(flush: true)
        guard activeListeningHistoryEntryID != nil else { return }
        persistListeningHistory()
        scheduleListeningHistorySync()
        activeListeningHistoryEntryID = nil
        lastListeningPosition = 0
        lastPersistedListeningSeconds = 0
        pendingListeningSeconds = 0
    }

    private var currentListeningPlaybackPosition: TimeInterval {
        if isTransientStreamActive, let streamingPlayer {
            let currentTime = streamingPlayer.currentTime().seconds
            if currentTime.isFinite { return max(currentTime, 0) }
        }
        if let player, player.currentTime.isFinite { return max(player.currentTime, 0) }
        return max(position, 0)
    }

    private func persistListeningHistory() {
        listeningHistoryEntries = MobileListeningHistoryPolicy.bounded(listeningHistoryEntries)
        pruneListeningHistorySyncState()
        save()
    }

    private func pruneListeningHistorySyncState() {
        let eventIDs = Set(listeningHistoryEntries.map { $0.id.uuidString.lowercased() })
        listeningHistorySyncedSeconds = listeningHistorySyncedSeconds.filter { key, _ in
            guard let marker = key.range(of: "#event=") else { return false }
            return eventIDs.contains(String(key[marker.upperBound...]))
        }
    }

    private func captureActiveProfileState() {
        guard let activeServerContext else { return }
        profileSyncStates[activeServerContext] = MobileProfileSyncState(
            playlists: playlists.filter { !$0.isSystem },
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: MobileServerEndpointPolicy.canonicalStoredServerKey(playlistSyncServerURL),
            remoteLikedSongIDs: remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs: dirtyRemoteLikeSongIDs,
            likesDirty: likesDirty
        )
    }

    private func restoreActiveProfileState() {
        let localFavorites = favorites.filter { trackID in
            tracks.first(where: { $0.id == trackID })?.remoteID == nil
        }
        let systemPlaylist = playlists.first(where: \.isSystem)
            ?? MobilePlaylist(name: "Liked Songs", isSystem: true)
        guard let activeServerContext,
              let state = profileSyncStates[activeServerContext] else {
            playlists = [systemPlaylist]
            favorites = localFavorites
            playlistRevision = 0
            knownRemotePlaylistIDs.removeAll()
            dirtyPlaylistIDs.removeAll()
            deletedPlaylistIDs.removeAll()
            playlistSyncServerURL = nil
            remoteLikedSongIDs.removeAll()
            dirtyRemoteLikeSongIDs.removeAll()
            likesDirty = false
            normalizeSystemPlaylist()
            return
        }

        playlists = [systemPlaylist] + state.playlists
        favorites = localFavorites
        playlistRevision = state.playlistRevision
        knownRemotePlaylistIDs = state.knownRemotePlaylistIDs
        dirtyPlaylistIDs = state.dirtyPlaylistIDs
        deletedPlaylistIDs = state.deletedPlaylistIDs
        playlistSyncServerURL = MobileServerEndpointPolicy.canonicalStoredServerKey(state.playlistSyncServerURL)
        remoteLikedSongIDs = state.remoteLikedSongIDs
        dirtyRemoteLikeSongIDs = state.dirtyRemoteLikeSongIDs
        likesDirty = state.likesDirty || !dirtyRemoteLikeSongIDs.isEmpty
        hydrateRemotePlaylistTracks()
        hydrateRemoteLikedTracks()
        normalizeSystemPlaylist()
    }

    func activateSyncProfile(named rawName: String) async -> Bool {
        guard !isProfileTransitionBusy else {
            serverMessage = "Wait for active transfers and playlist sync to finish."
            return false
        }
        isActivatingSyncProfile = true
        defer { isActivatingSyncProfile = false }
        let name = rawName
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !name.isEmpty else {
            serverMessage = "Enter a profile name."
            return false
        }
        guard let baseURL = normalizedServer() else {
            serverMessage = "Enter a valid server URL."
            return false
        }
        guard !serverToken.isEmpty else {
            serverMessage = "Sign in to your Resonance account."
            return false
        }

        do {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/profiles"))
            request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await sameOriginData(
                for: request,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.profileMaximumBytes
            )
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(MobileSyncProfilesResponse.self, from: data)
            if let profile = payload.profiles.first(where: {
                $0.id == name || $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) {
                selectSyncProfile(profile.id, name: profile.name)
                return true
            }

            var createRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/profiles"))
            createRequest.httpMethod = "POST"
            createRequest.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
            createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            createRequest.httpBody = try JSONEncoder().encode(["name": name])
            let (createdData, createResponse) = try await sameOriginData(
                for: createRequest,
                origin: baseURL,
                maximumBytes: MobileBoundedResponsePolicy.profileMaximumBytes
            )
            guard let createStatus = (createResponse as? HTTPURLResponse)?.statusCode,
                  createStatus == 201 else {
                let message = try? JSONDecoder().decode(ServerErrorPayload.self, from: createdData).error
                throw PlaylistServerError(
                    status: (createResponse as? HTTPURLResponse)?.statusCode ?? 0,
                    message: message
                )
            }
            let profile = try JSONDecoder().decode(MobileSyncProfile.self, from: createdData)
            selectSyncProfile(profile.id, name: profile.name)
            return true
        } catch {
            serverMessage = "Could not activate profile: \(error.localizedDescription)"
            return false
        }
    }

    private func selectSyncProfile(_ id: String, name: String) {
        guard !id.isEmpty else { return }
        if id == syncProfileID {
            syncProfileName = name
            save()
            scheduleListeningHistorySync(delay: .zero)
            return
        }
        endListeningHistorySession()
        invalidateListeningHistorySync()
        listenAlongController?.profileOrServerContextDidChange()
        cancelActiveDownloadBatch()
        playlistSyncTask?.cancel()
        remoteSourceResolutions.removeAll()
        clientConfigRequestGeneration &+= 1
        captureActiveProfileState()
        syncProfileID = id
        syncProfileName = name
        restoreActiveProfileState()

        if let currentTrack, currentTrack.remoteID != nil, !belongsToActiveServerContext(currentTrack) {
            stopTimer()
            player?.stop()
            player = nil
            isPlaying = false
            discardStreamingPlayback()
            currentTrackID = nil
            position = 0
            UserDefaults.standard.removeObject(forKey: "Resonance.currentTrack")
            UserDefaults.standard.set(position, forKey: "Resonance.position")
        }
        cancelRemoteSongMetadataHydration()
        advanceCatalogRequestGeneration()
        uploadedSongsAwaitingCatalog.removeAll()
        playbackPlaylistID = nil
        playbackQueue = tracksForActiveProfile.map(\.id)
        let activeTrackIDs = Set(playbackQueue)
        history.removeAll { !activeTrackIDs.contains($0) }
        playlistMutationGeneration &+= 1
        likesMutationGeneration &+= 1
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()
        transferFailures.removeAll()
        transferNotice = nil
        useSafeClientConfiguration(status: "Using safe defaults until the profile policy refreshes")
        normalizeSystemPlaylist()
        save()
        scheduleListeningHistorySync(delay: .zero)
        updateNowPlaying()
    }

    private func setProfileHeader(on request: inout URLRequest) {
        request.setValue(syncProfileID, forHTTPHeaderField: "X-Resonance-Profile")
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(for: lhs) == effectivePort(for: rhs)
    }

    private func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private func normalizedServer() -> URL? {
        try? MobileServerEndpointPolicy.resolve(serverURL).url
    }

    private func uniqueFilename(_ preferred: String) -> String {
        let clean = preferred.replacingOccurrences(of: "/", with: "-")
        var candidate = clean
        var counter = 2
        while fileManager.fileExists(atPath: musicDirectory.appendingPathComponent(candidate).path) {
            let base = (clean as NSString).deletingPathExtension
            let ext = (clean as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            counter += 1
        }
        return candidate
    }

    private func normalizeSystemPlaylist() {
        if playlists.isEmpty { playlists = [MobilePlaylist(name: "Liked Songs", isSystem: true)] }
        if let index = playlists.firstIndex(where: \.isSystem) {
            playlists[index].trackIDs = tracks.map(\.id).filter(favorites.contains)
        } else {
            playlists.insert(MobilePlaylist(name: "Liked Songs", trackIDs: tracks.map(\.id).filter(favorites.contains), isSystem: true), at: 0)
        }
    }

    private func save() {
        normalizeSystemPlaylist()
        listeningHistoryEntries = MobileListeningHistoryPolicy.bounded(listeningHistoryEntries)
        pruneListeningHistorySyncState()
        captureActiveProfileState()
        let queueReferences = playbackQueue.compactMap { trackID -> MobilePlaybackQueueReference? in
            guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
            return MobilePlaybackQueueReference(trackID: track.id, remoteIdentity: track.remoteIdentity())
        }
        let currentReference = currentTrack.flatMap { track -> MobilePlaybackQueueReference? in
            guard streamingTrack?.id != track.id else { return nil }
            return MobilePlaybackQueueReference(trackID: track.id, remoteIdentity: track.remoteIdentity())
        }
        let historyReferences = history.compactMap { trackID -> MobilePlaybackQueueReference? in
            guard let track = tracks.first(where: { $0.id == trackID }) else { return nil }
            return MobilePlaybackQueueReference(trackID: track.id, remoteIdentity: track.remoteIdentity())
        }
        let playbackSnapshot = MobilePlaybackSnapshot(
            version: MobilePlaybackSnapshot.currentVersion,
            queue: queueReferences,
            playlistID: playbackPlaylistID,
            currentTrack: currentReference,
            history: historyReferences
        )
        let stored = MobileStoredLibrary(
            tracks: tracks.map(MobileTrackPersistencePolicy.sanitized),
            playlists: playlists,
            favorites: favorites,
            serverURL: MobileServerEndpointPolicy.canonicalStoredServerURL(serverURL) ?? "",
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: MobileServerEndpointPolicy.canonicalStoredServerKey(playlistSyncServerURL),
            syncProfileID: syncProfileID,
            syncProfileName: syncProfileName,
            remoteLikedSongIDs: remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs: dirtyRemoteLikeSongIDs,
            likesDirty: likesDirty,
            clipRanges: clipRanges,
            dirtyClipRangeKeys: dirtyClipRangeKeys,
            deletedClipRangeKeys: deletedClipRangeKeys,
            profileStates: profileSyncStates,
            playbackQueue: queueReferences.map(\.trackID),
            playbackPlaylistID: queueReferences.isEmpty ? nil : playbackPlaylistID,
            playbackSnapshot: playbackSnapshot,
            listeningHistory: listeningHistoryEntries,
            listeningHistorySyncedSeconds: listeningHistorySyncedSeconds,
            transferFailures: transferFailures,
            completedMigrations: completedMigrations,
            remoteSongMetadataCache: MobileRemoteSongMetadataCachePolicy.normalized(
                remoteSongMetadataCache
            )
        )
        do {
            let data = try JSONEncoder().encode(stored)
            if let existing = try? Data(contentsOf: stateURL),
               MobileStoredLibraryRecoveryPolicy.recover(primaryData: existing, backupData: nil).source == .primary {
                try existing.write(to: backupStateURL, options: .atomic)
            }
            try data.write(to: stateURL, options: .atomic)
        } catch {
            libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                title: "Library could not be saved",
                message: "Your in-memory changes are still available. \(error.localizedDescription)"
            )
        }
    }

    private func migrateUnlinkedDownloads(
        _ storedTracks: [MobileTrack]
    ) -> (tracks: [MobileTrack], completed: Bool, changed: Bool) {
        var retained: [MobileTrack] = []
        var completed = true
        var changed = false

        for track in storedTracks {
            let mediaURL = fileURL(for: track)
            let legacyDownloadOwned = (try? mediaURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            ).isExcludedFromBackup) == true
            let decision = MobileUnlinkedDownloadMigrationPolicy.decision(
                for: track,
                legacyDownloadOwned: legacyDownloadOwned
            )
            changed = changed || decision.track != track
            guard decision.shouldDelete else {
                retained.append(decision.track)
                continue
            }

            guard isDescendant(mediaURL, of: musicDirectory) else {
                retained.append(decision.track)
                completed = false
                continue
            }
            do {
                if fileManager.fileExists(atPath: mediaURL.path) {
                    try fileManager.removeItem(at: mediaURL)
                }
                if let artworkFilename = decision.track.artworkFilename {
                    let artworkURL = artworkDirectory.appendingPathComponent(artworkFilename)
                    if isDescendant(artworkURL, of: artworkDirectory) {
                        try? fileManager.removeItem(at: artworkURL)
                        artworkCache.removeValue(forKey: artworkFilename)
                    }
                }
                changed = true
            } catch {
                retained.append(decision.track)
                completed = false
            }
        }
        return (retained, completed, changed)
    }

    private func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let rootPath = directory.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private func load() {
        let primaryData = try? Data(contentsOf: stateURL)
        let backupData = try? Data(contentsOf: backupStateURL)
        let recovery = MobileStoredLibraryRecoveryPolicy.recover(
            primaryData: primaryData,
            backupData: backupData
        )
        if recovery.primaryWasCorrupt {
            let quarantineURL = root.appendingPathComponent(
                "library-corrupt-\(Int(Date().timeIntervalSince1970)).json"
            )
            do {
                if fileManager.fileExists(atPath: stateURL.path) {
                    try fileManager.moveItem(at: stateURL, to: quarantineURL)
                }
                if recovery.source == .backup, let backupData {
                    try backupData.write(to: stateURL, options: .atomic)
                }
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: recovery.source == .backup ? "Library recovered" : "Library needs recovery",
                    message: recovery.source == .backup
                        ? "The primary library was damaged. Resonance restored the last valid backup and preserved the damaged file as \(quarantineURL.lastPathComponent)."
                        : "The library file was damaged and no valid backup was available. It was preserved as \(quarantineURL.lastPathComponent)."
                )
            } catch {
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: "Library recovery incomplete",
                    message: "Resonance did not overwrite the damaged library. \(error.localizedDescription)"
                )
            }
        } else if recovery.source == .backup, let backupData {
            do {
                try backupData.write(to: stateURL, options: .atomic)
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: "Library restored",
                    message: "The primary library file was missing. Resonance restored the last valid backup."
                )
            } catch {
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: "Library recovery incomplete",
                    message: "Resonance loaded the backup in memory but could not restore the primary library file. \(error.localizedDescription)"
                )
            }
        }
        guard var stored = recovery.library else {
            if !recovery.primaryWasCorrupt {
                completedMigrations.insert(MobileUnlinkedDownloadMigrationPolicy.identifier)
            }
            return
        }

        let sanitizedTracks = stored.tracks.map(MobileTrackPersistencePolicy.sanitized)
        let didSanitizePersistedMediaLinks = sanitizedTracks != stored.tracks
        stored.tracks = sanitizedTracks

        remoteSongMetadataCache = MobileRemoteSongMetadataCachePolicy.normalized(
            stored.remoteSongMetadataCache ?? [:]
        )

        var didMigrateUnlinkedDownloads = false
        if !(stored.completedMigrations ?? []).contains(MobileUnlinkedDownloadMigrationPolicy.identifier) {
            let migration = migrateUnlinkedDownloads(stored.tracks)
            stored.tracks = migration.tracks
            let retainedIDs = Set(migration.tracks.map(\.id))
            stored.playlists = stored.playlists.map { playlist in
                var migrated = playlist
                migrated.trackIDs.removeAll { !retainedIDs.contains($0) }
                return migrated
            }
            stored.favorites.formIntersection(retainedIDs)
            stored.profileStates = stored.profileStates?.mapValues { state in
                var migrated = state
                migrated.playlists = migrated.playlists.map { playlist in
                    var playlist = playlist
                    playlist.trackIDs.removeAll { !retainedIDs.contains($0) }
                    return playlist
                }
                return migrated
            }
            if migration.completed {
                var migrations = stored.completedMigrations ?? []
                migrations.insert(MobileUnlinkedDownloadMigrationPolicy.identifier)
                stored.completedMigrations = migrations
            }
            didMigrateUnlinkedDownloads = migration.changed || migration.completed
        }
        completedMigrations = stored.completedMigrations ?? []

        var fallbackServerURL = URL(string: stored.serverURL)
        do {
            let resolution = try MobileServerEndpointPolicy.resolve(stored.serverURL)
            serverURL = resolution.url.absoluteString
            fallbackServerURL = resolution.url
        } catch {
            serverURL = stored.serverURL
            serverConfigurationMessage = error.localizedDescription
            serverMessage = error.localizedDescription
        }
        syncProfileID = stored.syncProfileID ?? "default"
        syncProfileName = stored.syncProfileName ?? (syncProfileID == "default" ? "Default" : syncProfileID)
        let fallbackHistoryOrigin = fallbackServerURL.flatMap {
            MobileServerEndpointPolicy.normalizedOrigin(of: $0)
        }
        listeningHistoryEntries = MobileListeningHistoryPolicy.bounded(
            (stored.listeningHistory ?? []).map { entry in
                var migrated = entry
                if migrated.serverOrigin == nil { migrated.serverOrigin = fallbackHistoryOrigin }
                if migrated.syncProfileID == nil { migrated.syncProfileID = syncProfileID }
                return migrated
            }
        )
        listeningHistorySyncedSeconds = stored.listeningHistorySyncedSeconds ?? [:]
        pruneListeningHistorySyncState()
        var availableTracks = stored.tracks.filter {
            fileManager.fileExists(atPath: musicDirectory.appendingPathComponent($0.relativePath).path)
        }
        for index in availableTracks.indices where availableTracks[index].remoteID != nil {
            if availableTracks[index].sourceServer == nil {
                availableTracks[index].sourceServer = fallbackServerURL?.absoluteString
            }
            if availableTracks[index].syncProfileID == nil {
                availableTracks[index].syncProfileID = "default"
            }
        }
        let normalization = MobileCollectionNormalization.normalize(
            tracks: availableTracks,
            playlists: stored.playlists,
            fallbackServerURL: fallbackServerURL
        )
        tracks = normalization.tracks
        transferFailures = stored.transferFailures ?? []
        playlists = normalization.playlists
        favorites = stored.favorites.intersection(Set(tracks.map(\.id)))
        playlistRevision = stored.playlistRevision ?? 0
        knownRemotePlaylistIDs = stored.knownRemotePlaylistIDs ?? []
        dirtyPlaylistIDs = stored.dirtyPlaylistIDs ?? []
        deletedPlaylistIDs = stored.deletedPlaylistIDs ?? []
        playlistSyncServerURL = MobileServerEndpointPolicy.canonicalStoredServerKey(stored.playlistSyncServerURL)
        let migratedLikedSongIDs = Set<String>(favorites.compactMap { trackID -> String? in
            guard let track = tracks.first(where: { $0.id == trackID }),
                  belongsToActiveServerContext(track) else { return nil }
            return track.remoteID
        })
        remoteLikedSongIDs = stored.remoteLikedSongIDs ?? migratedLikedSongIDs
        if let storedDirtyLikeIDs = stored.dirtyRemoteLikeSongIDs {
            dirtyRemoteLikeSongIDs = storedDirtyLikeIDs
        } else if stored.likesDirty ?? false {
            dirtyRemoteLikeSongIDs = Set<String>(tracks.compactMap { track -> String? in
                guard track.remoteID != nil, belongsToActiveServerContext(track) else { return nil }
                return track.remoteID
            })
        } else if stored.remoteLikedSongIDs == nil {
            // Before server-backed likes existed, favorites were only device-local.
            // Upload those known likes on the first sync instead of letting an empty
            // remote document erase them during migration.
            dirtyRemoteLikeSongIDs = migratedLikedSongIDs
        }
        likesDirty = !dirtyRemoteLikeSongIDs.isEmpty
        clipRanges = stored.clipRanges ?? [:]
        dirtyClipRangeKeys = stored.dirtyClipRangeKeys ?? []
        deletedClipRangeKeys = stored.deletedClipRangeKeys ?? []
        migrateLegacyClipRangeKeys(fallbackServerURL: fallbackServerURL)
        let storedProfileStates = stored.profileStates ?? [:]
        profileSyncStates = storedProfileStates.filter { context, _ in
            MobileServerEndpointPolicy.isCanonicalContext(context)
        }
        for (context, state) in storedProfileStates {
            let canonicalContext = MobileServerEndpointPolicy.canonicalContext(context)
            if MobileServerEndpointPolicy.isCanonicalContext(canonicalContext),
               profileSyncStates[canonicalContext] == nil {
                profileSyncStates[canonicalContext] = state
            }
        }
        captureActiveProfileState()
        hydrateRemotePlaylistTracks()
        hydrateRemoteLikedTracks()
        normalizeSystemPlaylist()
        let savedID = UserDefaults.standard.string(forKey: "Resonance.currentTrack").flatMap(UUID.init(uuidString:))
        let legacyCurrentTrackID = savedID.flatMap { wanted in
            tracksForActiveProfile.first(where: { $0.id == wanted })?.id
        } ?? tracksForActiveProfile.first?.id
        position = UserDefaults.standard.double(forKey: "Resonance.position")
        let activeTrackIDs = Set(tracksForActiveProfile.map(\.id))
        let playlistIDs = Set(playlists.map(\.id))
        let restoredPlayback: MobilePlaybackRestoreResult
        if let snapshot = stored.playbackSnapshot,
           (1...MobilePlaybackSnapshot.currentVersion).contains(snapshot.version) {
            restoredPlayback = MobilePlaybackSnapshotPolicy.restore(
                snapshot: snapshot,
                tracks: tracks,
                activeTrackIDs: activeTrackIDs,
                playlistIDs: playlistIDs
            )
        } else {
            restoredPlayback = MobilePlaybackSnapshotPolicy.restore(
                queue: stored.playbackQueue ?? [],
                playlistID: stored.playbackPlaylistID,
                currentTrackID: legacyCurrentTrackID,
                activeTrackIDs: activeTrackIDs,
                playlistIDs: playlistIDs
            )
        }
        playbackQueue = restoredPlayback.queue
        playbackPlaylistID = restoredPlayback.playlistID
        currentTrackID = restoredPlayback.currentTrackID ?? legacyCurrentTrackID
        history = restoredPlayback.history

        for track in tracks
        where track.remoteID != nil && track.preservesUnlinkedImport != true {
            try? markServerDownloadExcludedFromBackup(at: fileURL(for: track))
        }
        if normalization.repairCount > 0 {
            let repairMessage = "Resonance repaired \(normalization.repairCount) duplicate identifier or remote-association conflict\(normalization.repairCount == 1 ? "" : "s") without deleting audio files."
            if let existing = libraryRecoveryNotice {
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: existing.title,
                    message: existing.message + " " + repairMessage
                )
            } else {
                libraryRecoveryNotice = MobileLibraryRecoveryNotice(
                    title: "Library identifiers repaired",
                    message: repairMessage
                )
            }
            dirtyPlaylistIDs.formUnion(playlists.filter { !$0.isSystem }.map(\.id))
            save()
        } else if didMigrateUnlinkedDownloads || didSanitizePersistedMediaLinks {
            save()
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleAudioInterruption(notification)
            }
        })

        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverAfterMediaServicesReset()
            }
        })

        audioSessionObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleRouteChange(notification)
            }
        })

        audioSessionObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateListeningHistorySession(flush: true)
                self.persistListeningHistory()
                self.scheduleListeningHistorySync()
            }
        })
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = player?.isPlaying == true
                || streamingPlayer?.timeControlStatus == .playing
                || isPlaying
            cancelCrossfade()
            updateListeningHistorySession(flush: true)
            persistListeningHistory()
            scheduleListeningHistorySync()
            streamingPlayer?.pause()
            stopTimer()
            isPlaying = false
            updateNowPlaying()
            notifyListenAlongPlaybackChanged()

        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }

            do {
                try AVAudioSession.sharedInstance().setActive(true)
                if isTransientStreamActive, let streamingPlayer {
                    streamingPlayer.playImmediately(atRate: playbackRate)
                    isPlaying = true
                } else if let player {
                    player.rate = playbackRate
                    isPlaying = player.play()
                } else {
                    isPlaying = false
                }
                if isPlaying { startTimer() }
                updateNowPlaying()
                notifyListenAlongPlaybackChanged()
            } catch {
                isPlaying = false
            }

        @unknown default:
            break
        }
    }

    private func recoverAfterMediaServicesReset() {
        let shouldResume = isPlaying || wasPlayingBeforeInterruption
        let resumePosition = position
        configureAudioSession()
        guard shouldResume, let track = currentTrack else { return }
        if isTransientStreamActive,
           let remoteID = track.remoteID,
           let remoteSong = remoteSongs.first(where: { $0.id == remoteID }) {
            discardStreamingPlayback()
            Task { await streamRemoteSong(remoteSong) }
            return
        }
        startPlayback(track, recordHistory: false, startingAt: resumePosition)
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              reason == .oldDeviceUnavailable else { return }

        // Respect the standard iOS behavior when headphones or another output
        // disappear: pause instead of unexpectedly switching to the speaker.
        pausePlayback()
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in self?.resumePlayback() }
            return .success
        }
        remoteCommandTargets.append((center.playCommand, playTarget))

        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in self?.pausePlayback() }
            return .success
        }
        remoteCommandTargets.append((center.pauseCommand, pauseTarget))

        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in self?.togglePlay() }
            return .success
        }
        remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

        let nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in self?.next() }
            return .success
        }
        remoteCommandTargets.append((center.nextTrackCommand, nextTarget))

        let previousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
            guard self != nil else { return .commandFailed }
            Task { @MainActor [weak self] in self?.previous() }
            return .success
        }
        remoteCommandTargets.append((center.previousTrackCommand, previousTarget))

        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard self != nil,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let elapsedTime = positionEvent.positionTime
            Task { @MainActor [weak self] in self?.seek(toElapsedTime: elapsedTime) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))

        let hasCurrentTrack = currentTrack != nil
        let allowsLocalPlaybackControl = !isListenAlongPlaybackLocked
        let allowsTrackNavigation = allowsLocalPlaybackControl
            && hasCurrentTrack
            && !isTransientStreamActive
            && activeQueue.count > 1
        center.playCommand.isEnabled = allowsLocalPlaybackControl && hasCurrentTrack && !isPlaying
        center.pauseCommand.isEnabled = allowsLocalPlaybackControl && hasCurrentTrack && isPlaying
        center.togglePlayPauseCommand.isEnabled = allowsLocalPlaybackControl && hasCurrentTrack
        center.nextTrackCommand.isEnabled = allowsTrackNavigation
        center.previousTrackCommand.isEnabled = allowsTrackNavigation
        center.changePlaybackPositionCommand.isEnabled = allowsLocalPlaybackControl && hasCurrentTrack
        center.changePlaybackRateCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.stopCommand.isEnabled = false
    }

    private func startTimer() {
        stopTimer()
        guard player?.isPlaying == true || isTransientStreamActive else { return }
        let playbackTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isTransientStreamActive, let streamingPlayer = self.streamingPlayer {
                    let wasPlaying = self.isPlaying
                    let currentTime = streamingPlayer.currentTime().seconds
                    if currentTime.isFinite, let track = self.streamingTrack {
                        let bounds = self.playbackBounds(for: track)
                        if currentTime + 0.02 < bounds.start {
                            streamingPlayer.seek(
                                to: CMTime(seconds: bounds.start, preferredTimescale: 600),
                                toleranceBefore: .zero,
                                toleranceAfter: .zero
                            )
                            self.position = bounds.start
                        } else if MobileClipPlaybackPolicy.reachedEnd(
                            position: currentTime,
                            bounds: .init(start: bounds.start, end: bounds.end)
                        ) {
                            self.completeAuthenticatedStreamPlayback(
                                generation: self.streamingGeneration
                            )
                            return
                        } else {
                            self.position = max(currentTime, bounds.start)
                        }
                    }
                    self.isPlaying = streamingPlayer.timeControlStatus != .paused
                    self.updateListeningHistorySession()
                    if self.isPlaying != wasPlaying {
                        self.updateNowPlaying()
                    }
                    return
                }
                guard let player = self.player else { return }
                guard player.isPlaying else {
                    self.stopTimer()
                    self.isPlaying = false
                    self.updateNowPlaying()
                    return
                }
                if let track = self.currentTrack {
                    let bounds = self.playbackBounds(for: track, duration: player.duration)
                    if self.updateCrossfade(currentPlayer: player, currentTrack: track, bounds: bounds) {
                        return
                    }
                    if player.currentTime + 0.02 >= bounds.end {
                        self.advanceAfterFinishing()
                        return
                    }
                }
                self.position = player.currentTime
                self.updateListeningHistorySession()
                UserDefaults.standard.set(self.position, forKey: "Resonance.position")
                self.isPlaying = true
            }
        }
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func automaticCrossfadeTrack() -> MobileTrack? {
        let queue = activeQueue
        guard queue.count > 1 else { return nil }
        if shuffleEnabled {
            return queue.filter { $0.id != currentTrackID }.randomElement()
        }
        let currentIndex = queue.firstIndex { $0.id == currentTrackID } ?? -1
        guard let nextIndex = MobileQueueCompletionPolicy.nextIndex(
            count: queue.count,
            currentIndex: currentIndex
        ) else { return nil }
        return queue[nextIndex]
    }

    private func updateCrossfade(
        currentPlayer: AVAudioPlayer,
        currentTrack: MobileTrack,
        bounds: (start: TimeInterval, end: TimeInterval)
    ) -> Bool {
        guard crossfadeEnabled, !repeatEnabled, streamingTrack == nil else {
            cancelCrossfade()
            return false
        }

        if crossfadePlayer == nil {
            guard let nextTrack = automaticCrossfadeTrack(),
                  let nextPlayer = try? AVAudioPlayer(contentsOf: fileURL(for: nextTrack)) else {
                return false
            }
            let nextBounds = playbackBounds(for: nextTrack, duration: nextPlayer.duration)
            let duration = MobileCrossfadePolicy.effectiveDuration(
                requestedSeconds: crossfadeSeconds,
                currentDuration: bounds.end - bounds.start,
                nextDuration: nextBounds.end - nextBounds.start
            )
            let remaining = bounds.end - currentPlayer.currentTime
            guard duration >= 0.25, remaining <= duration else { return false }
            nextPlayer.delegate = self
            nextPlayer.enableRate = true
            nextPlayer.rate = playbackRate
            nextPlayer.volume = 0
            nextPlayer.currentTime = nextBounds.start
            nextPlayer.prepareToPlay()
            guard nextPlayer.play() else { return false }
            crossfadePlayer = nextPlayer
            crossfadeTrackID = nextTrack.id
            activeCrossfadeDuration = duration
        }

        guard crossfadePlayer != nil else { return false }
        let remaining = bounds.end - currentPlayer.currentTime
        applyCrossfadeVolumes(progress: MobileCrossfadePolicy.progress(
            remaining: remaining,
            duration: activeCrossfadeDuration
        ))
        if remaining <= 0.02 {
            completeCrossfade()
            return true
        }
        return false
    }

    private func applyCrossfadeVolumes(progress: Double? = nil) {
        let gain = PlaybackVolumePolicy.gain(for: volume)
        guard let crossfadePlayer else {
            player?.volume = gain
            return
        }
        let resolvedProgress = progress ?? {
            guard let player, let track = currentTrack else { return 0.0 }
            let bounds = playbackBounds(for: track, duration: player.duration)
            return MobileCrossfadePolicy.progress(
                remaining: bounds.end - player.currentTime,
                duration: activeCrossfadeDuration
            )
        }()
        player?.volume = gain * Float(1 - resolvedProgress)
        crossfadePlayer.volume = gain * Float(resolvedProgress)
    }

    private func cancelCrossfade() {
        crossfadePlayer?.delegate = nil
        crossfadePlayer?.stop()
        crossfadePlayer = nil
        crossfadeTrackID = nil
        activeCrossfadeDuration = 0
        player?.volume = PlaybackVolumePolicy.gain(for: volume)
    }

    private func completeCrossfade() {
        guard let nextPlayer = crossfadePlayer,
              let nextTrackID = crossfadeTrackID,
              let nextTrack = activeQueue.first(where: { $0.id == nextTrackID }) else {
            cancelCrossfade()
            return
        }
        let outgoingPlayer = player
        if let currentTrackID, currentTrackID != nextTrackID {
            history.append(currentTrackID)
        }
        outgoingPlayer?.delegate = nil
        outgoingPlayer?.stop()
        player = nextPlayer
        crossfadePlayer = nil
        crossfadeTrackID = nil
        activeCrossfadeDuration = 0
        nextPlayer.volume = PlaybackVolumePolicy.gain(for: volume)
        currentTrackID = nextTrack.id
        position = nextPlayer.currentTime
        UserDefaults.standard.set(nextTrack.id.uuidString, forKey: "Resonance.currentTrack")
        UserDefaults.standard.set(position, forKey: "Resonance.position")
        isPlaying = nextPlayer.isPlaying
        updateNowPlaying()
        notifyListenAlongPlaybackChanged()
        save()
    }

    private func updateNowPlaying() {
        let remoteCommands = MPRemoteCommandCenter.shared()
        guard let track = currentTrack else {
            remoteCommands.playCommand.isEnabled = false
            remoteCommands.pauseCommand.isEnabled = false
            remoteCommands.togglePlayPauseCommand.isEnabled = false
            remoteCommands.nextTrackCommand.isEnabled = false
            remoteCommands.previousTrackCommand.isEnabled = false
            remoteCommands.changePlaybackPositionCommand.isEnabled = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            nowPlayingArtworkLoadTask?.cancel()
            nowPlayingArtworkLoadTask = nil
            nowPlayingArtworkLoadRemoteID = nil
            return
        }

        let allowsLocalPlaybackControl = !isListenAlongPlaybackLocked
        let allowsTrackNavigation = allowsLocalPlaybackControl
            && !isTransientStreamActive
            && activeQueue.count > 1
        remoteCommands.playCommand.isEnabled = allowsLocalPlaybackControl && !isPlaying
        remoteCommands.pauseCommand.isEnabled = allowsLocalPlaybackControl && isPlaying
        remoteCommands.togglePlayPauseCommand.isEnabled = allowsLocalPlaybackControl
        remoteCommands.nextTrackCommand.isEnabled = allowsTrackNavigation
        remoteCommands.previousTrackCommand.isEnabled = allowsTrackNavigation
        remoteCommands.changePlaybackPositionCommand.isEnabled = allowsLocalPlaybackControl

        let playerDuration = isTransientStreamActive ? nil : player?.duration
        let bounds = playbackBounds(for: track, duration: playerDuration)
        let snapshot = MobileNowPlayingPolicy.snapshot(
            for: track,
            position: position,
            bounds: .init(start: bounds.start, end: bounds.end),
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            allowsTrackNavigation: allowsTrackNavigation
        )
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.defaultPlaybackRate,
            MPNowPlayingInfoPropertyExternalContentIdentifier: snapshot.identifier,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]
        info[MPMediaItemPropertyArtwork] = nowPlayingArtwork(for: track)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        scheduleNowPlayingArtworkLoad(for: track)
    }

    private func nowPlayingArtwork(for track: MobileTrack) -> MPMediaItemArtwork {
        let remoteArtwork = track.remoteID.flatMap { remoteNowPlayingArtworkCache[$0] }
        let sourceArtwork = artwork(for: track) ?? remoteArtwork
        let sourceKey = track.artworkFilename
            ?? (remoteArtwork == nil ? "fallback" : "remote:\(track.remoteID ?? "")")
        let cacheKey = "\(track.id.uuidString)|\(sourceKey)"
        if cacheKey == nowPlayingArtworkCacheKey, let nowPlayingArtworkCache {
            return nowPlayingArtworkCache
        }

        // MPMediaItemArtwork is rendered outside the app process. Redrawing the
        // source into an opaque sRGB bitmap avoids CI-backed or oriented images
        // becoming a black tile on the Lock Screen and Dynamic Island.
        let image = renderedNowPlayingArtwork(from: sourceArtwork)
        let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingArtworkCacheKey = cacheKey
        nowPlayingArtworkCache = mediaArtwork
        return mediaArtwork
    }

    private func scheduleNowPlayingArtworkLoad(for track: MobileTrack) {
        guard artwork(for: track) == nil,
              let remoteID = track.remoteID,
              remoteNowPlayingArtworkCache[remoteID] == nil,
              let song = remoteSongs.first(where: { $0.id == remoteID }),
              song.artworkURL != nil,
              let baseURL = normalizedServer() else {
            if nowPlayingArtworkLoadRemoteID != track.remoteID {
                nowPlayingArtworkLoadTask?.cancel()
                nowPlayingArtworkLoadTask = nil
                nowPlayingArtworkLoadRemoteID = nil
            }
            return
        }
        guard nowPlayingArtworkLoadRemoteID != remoteID else { return }

        nowPlayingArtworkLoadTask?.cancel()
        nowPlayingArtworkLoadRemoteID = remoteID
        nowPlayingArtworkLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.nowPlayingArtworkLoadRemoteID == remoteID {
                    self.nowPlayingArtworkLoadRemoteID = nil
                    self.nowPlayingArtworkLoadTask = nil
                }
            }
            do {
                guard let data = await self.remoteArtworkData(for: song, baseURL: baseURL) else {
                    return
                }
                try Task.checkCancellation()
                guard let image = MobileArtworkImagePolicy.image(from: data),
                      self.currentTrack?.remoteID == remoteID else { return }
                self.remoteNowPlayingArtworkCache = [remoteID: image]
                self.nowPlayingArtworkCacheKey = nil
                self.nowPlayingArtworkCache = nil
                self.updateNowPlaying()
            } catch {
                return
            }
        }
    }

    private func renderedNowPlayingArtwork(from source: UIImage?) -> UIImage {
        let size = CGSize(width: 600, height: 600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let bounds = CGRect(origin: .zero, size: size)

            if let source, source.size.width > 0, source.size.height > 0 {
                UIColor.black.setFill()
                UIRectFill(bounds)
                let scale = max(size.width / source.size.width, size.height / source.size.height)
                let drawnSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
                let drawnRect = CGRect(
                    x: (size.width - drawnSize.width) / 2,
                    y: (size.height - drawnSize.height) / 2,
                    width: drawnSize.width,
                    height: drawnSize.height
                )
                source.draw(in: drawnRect)
            } else {
                UIColor(red: 0.25, green: 0.12, blue: 0.62, alpha: 1).setFill()
                UIRectFill(bounds)
                let configuration = UIImage.SymbolConfiguration(pointSize: 190, weight: .semibold)
                let symbol = UIImage(systemName: "waveform", withConfiguration: configuration)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                if let symbol {
                    let origin = CGPoint(
                        x: (size.width - symbol.size.width) / 2,
                        y: (size.height - symbol.size.height) / 2
                    )
                    symbol.draw(at: origin)
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            if self.crossfadePlayer != nil {
                self.completeCrossfade()
            } else {
                self.advanceAfterFinishing()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stopTimer()
            self.isPlaying = false
            if self.activeQueue.count > 1 {
                self.next()
            } else {
                if self.currentTrackID == self.streamingTrack?.id {
                    self.player = nil
                    self.discardStreamingPlayback()
                }
                self.updateNowPlaying()
            }
        }
    }

    private static let accountSessionKey = "account-session-v1"

    private static var credentialStore: MobileFileCredentialStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeURL = support
            .appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
            .appendingPathComponent("server-credentials.json")
        return MobileFileCredentialStore(storeURL: storeURL)
    }

    private static func readAccountSession() -> ResonanceAccountSession? {
        let raw = readToken(key: accountSessionKey)
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResonanceAccountSession.self, from: data)
    }

    private static func storeAccountSession(_ session: ResonanceAccountSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        try storeToken(raw, key: accountSessionKey)
    }

    private static func storeToken(_ token: String, key: String) throws {
        try credentialStore.save(token, key: key)
    }

    private static func readToken(key: String) -> String {
        (credentialStore.read(key: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
