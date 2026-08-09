import AVFoundation
import Combine
import CryptoKit
import Foundation
import MediaPlayer
import Security
import UIKit
import UniformTypeIdentifiers

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

private enum MobileBoundedDownloadError: LocalizedError {
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Server returned HTTP \(status)."
        }
    }
}

private enum MobileBoundedResponseError: LocalizedError {
    case tooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            "The server response exceeded the \(limit)-byte safety limit."
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

private final class MobileSameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(MobileSameOriginPolicy.matches(request.url, origin) ? request : nil)
    }
}

final class MobileBoundedDownloadOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumSize: Int64
    private let fileManager: FileManager
    let temporaryURL: URL
    private let authorization: MobileTransferAuthorization
    private let sessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var hasher = SHA256()
    private var byteCount: Int64 = 0
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
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) throws {
        self.maximumSize = maximumSize
        self.authorization = authorization
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
        if !isFinished {
            receivedResponse = true
        }
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
            lock.unlock()
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
            lock.unlock()
            if let authorizationRegistration {
                authorization.unregister(authorizationRegistration)
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
    @Published var tracks: [MobileTrack] = []
    @Published var playlists: [MobilePlaylist] = [MobilePlaylist(name: "Liked Songs", isSystem: true)]
    @Published var favorites: Set<UUID> = []
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published var volume: Double = 0.8 {
        didSet {
            let gain = PlaybackVolumePolicy.gain(for: volume)
            player?.volume = gain
            streamingPlayer?.volume = gain
            UserDefaults.standard.set(volume, forKey: "Resonance.volume")
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            player?.rate = playbackRate
            streamingPlayer?.defaultRate = playbackRate
            if streamingPlayer?.timeControlStatus == .playing {
                streamingPlayer?.rate = playbackRate
            }
            UserDefaults.standard.set(Double(playbackRate), forKey: "Resonance.rate")
        }
    }
    @Published var shuffleEnabled = false { didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "Resonance.shuffle") } }
    @Published var repeatEnabled = false { didSet { UserDefaults.standard.set(repeatEnabled, forKey: "Resonance.repeat") } }
    @Published var searchText = ""
    @Published private(set) var serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"
    @Published private(set) var serverToken = ""
    @Published private(set) var serverAdminToken = ""
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountRole: String?
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var accountImageURL: URL?
    @Published private(set) var isAuthenticatingAccount = false
    @Published var remoteSongs: [MobileRemoteSong] = []
    @Published var selectedRemoteSongIDs: Set<String> = []
    @Published var serverMessage = "Not connected"
    @Published private(set) var isServerConnected = false
    @Published var isSyncing = false
    @Published var isDownloading = false
    @Published var isUploading = false
    @Published var isRefreshingCatalog = false
    @Published var downloadProgress = 0.0
    @Published var uploadProgress = 0.0
    @Published var downloadDetail = "Idle"
    @Published var uploadDetail = "Idle"
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

    var visibleSyncProfileName: String {
        ResonanceEmailPrivacy.safeDisplayName(syncProfileName, email: accountEmail)
    }

    var isUploadTransferBusy: Bool {
        isActivatingSyncProfile || MobileUploadBlockingPolicy.blocksUpload(
            isUploading: isUploading,
            isDownloading: isDownloading,
            isSyncing: isSyncing,
            isRefreshingCatalog: isRefreshingCatalog,
            isSyncingPlaylists: isSyncingPlaylists
        )
    }

    var isProfileTransitionBusy: Bool {
        isActivatingSyncProfile || isUploading || isDownloading || isSyncing || isSyncingPlaylists
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
    private let uploadSerialGate = MobileAsyncSerialGate()
    private let downloadSerialGate = MobileAsyncSerialGate()
    private let root: URL
    private let musicDirectory: URL
    private let artworkDirectory: URL
    private let stateURL: URL
    private let backupStateURL: URL
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var history: [UUID] = []
    private var playbackQueue: [UUID] = []
    private var playbackPlaylistID: UUID?
    private var artworkCache: [String: UIImage] = [:]
    private var nowPlayingArtworkCacheKey: String?
    private var nowPlayingArtworkCache: MPMediaItemArtwork?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private var playlistRevision = 0
    private var playlistMutationGeneration: UInt64 = 0
    private var catalogRequestGeneration: UInt64 = 0
    private var uploadCatalogMutationGeneration: UInt64 = 0
    private var uploadedSongsAwaitingCatalog: [String: MobileRemoteSong] = [:]
    private var knownRemotePlaylistIDs: Set<UUID> = []
    private var dirtyPlaylistIDs: Set<UUID> = []
    private var deletedPlaylistIDs: Set<UUID> = []
    private var playlistSyncServerURL: String?
    private var playlistSyncTask: Task<Void, Never>?
    private var clientConfigRefreshTask: Task<Void, Never>?
    private var activeDownloadAuthorizations: [UUID: MobileTransferAuthorization] = [:]
    private var remoteLikedSongIDs: Set<String> = []
    private var dirtyRemoteLikeSongIDs: Set<String> = []
    private var likesMutationGeneration: UInt64 = 0
    private var likesDirty = false
    private var clipRanges: [String: MobileClipRange] = [:]
    private var dirtyClipRangeKeys: Set<String> = []
    private var deletedClipRangeKeys: Set<String> = []
    private var clipRangeMutationGeneration: UInt64 = 0
    private var profileSyncStates: [MobileServerContext: MobileProfileSyncState] = [:]
    private var clientConfigRequestGeneration: UInt64 = 0
    private var streamingTrack: MobileTrack?
    private var streamingPlayer: AVPlayer?
    private var streamingResourceLoader: MobileAuthenticatedStreamResourceLoader?
    private var streamingAuthorizationLease: MobileAuthenticatedStreamAuthorizationLease?
    private var streamingEndObserver: NSObjectProtocol?
    private var streamingFailureObserver: NSObjectProtocol?
    private var streamingStatusObservation: NSKeyValueObservation?
    private var streamingGeneration: UInt64 = 0
    private var accountSession: ResonanceAccountSession?
    private var accountRefreshTask: Task<Void, Never>?
    private var isRefreshingAccountSession = false

    private struct EmbeddedMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var duration: TimeInterval?
        var artworkData: Data?
    }

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("LikedSongsMobile", isDirectory: true)
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
        shuffleEnabled = UserDefaults.standard.bool(forKey: "Resonance.shuffle")
        repeatEnabled = UserDefaults.standard.bool(forKey: "Resonance.repeat")
        if let session = Self.readAccountSession() {
            accountSession = session
            serverURL = (try? MobileServerEndpointPolicy.resolve(session.baseURL.absoluteString).url.absoluteString)
                ?? session.baseURL.absoluteString
            serverToken = session.accessToken
            serverAdminToken = session.isAdmin ? session.accessToken : ""
            accountEmail = session.email
            accountRole = session.role
            accountDisplayName = session.profileDisplayName
            accountImageURL = session.imageURL
            if session.profileID == syncProfileID {
                syncProfileName = session.profileDisplayName
            }
            try? Self.storeToken("", account: "client")
            try? Self.storeToken("", account: "admin")
            scheduleAccountRefresh(session)
        } else {
            serverToken = Self.readToken(account: "client")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            serverAdminToken = Self.readToken(account: "admin")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        configureAudioSession()
        observeAudioSession()
        configureRemoteCommands()
        Task { [weak self] in
            await self?.refreshEmbeddedMetadata()
            await self?.refreshAccountSessionIfNeeded()
        }
    }

    deinit {
        timer?.invalidate()
        playlistSyncTask?.cancel()
        clientConfigRefreshTask?.cancel()
        accountRefreshTask?.cancel()
        activeDownloadAuthorizations.values.forEach { $0.revoke() }
        if let streamingEndObserver { NotificationCenter.default.removeObserver(streamingEndObserver) }
        if let streamingFailureObserver { NotificationCenter.default.removeObserver(streamingFailureObserver) }
        streamingStatusObservation?.invalidate()
        streamingPlayer?.pause()
        streamingResourceLoader?.invalidate()
        streamingAuthorizationLease?.invalidate()
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func signIn(with provider: ResonanceSocialAuthProvider, serverURL rawServerURL: String) async {
        guard !isAuthenticatingAccount else { return }
        isAuthenticatingAccount = true
        serverMessage = "Opening \(provider.title) sign-in…"
        defer { isAuthenticatingAccount = false }
        do {
            let resolution = try MobileServerEndpointPolicy.resolve(rawServerURL)
            let client = try ResonanceSocialAuthClient(baseURL: resolution.url)
            let session = try await client.signIn(
                with: provider,
                migrationProfileID: syncProfileID
            )
            try Self.storeAccountSession(session)
            accountSession = session
            accountEmail = session.email
            accountRole = session.role
            accountDisplayName = session.profileDisplayName
            accountImageURL = session.imageURL
            try? Self.storeToken("", account: "client")
            try? Self.storeToken("", account: "admin")
            guard applyServerConfiguration(
                serverURL: session.baseURL.absoluteString,
                accessToken: session.accessToken,
                adminToken: session.isAdmin ? session.accessToken : ""
            ) else { return }
            if let profileID = session.profileID, !profileID.isEmpty {
                selectSyncProfile(profileID, name: session.profileDisplayName)
            }
            scheduleAccountRefresh(session)
            serverMessage = "Signed in with Clerk"
            await refreshClientConfiguration()
        } catch {
            serverMessage = error.localizedDescription
            serverConfigurationMessage = error.localizedDescription
        }
    }

    func completeNativeSignIn(serverURL rawServerURL: String) async {
        guard !isAuthenticatingAccount else { return }
        isAuthenticatingAccount = true
        serverMessage = "Finishing account sign-in…"
        defer { isAuthenticatingAccount = false }
        do {
            let resolution = try MobileServerEndpointPolicy.resolve(rawServerURL)
            let client = try ResonanceSocialAuthClient(baseURL: resolution.url)
            let session = try await ResonanceClerkAuthCoordinator.shared.accountSession(
                for: client,
                migrationProfileID: syncProfileID
            )
            try Self.storeAccountSession(session)
            accountSession = session
            accountEmail = session.email
            accountRole = session.role
            accountDisplayName = session.profileDisplayName
            accountImageURL = session.imageURL
            try? Self.storeToken("", account: "client")
            try? Self.storeToken("", account: "admin")
            guard applyServerConfiguration(
                serverURL: session.baseURL.absoluteString,
                accessToken: session.accessToken,
                adminToken: session.isAdmin ? session.accessToken : ""
            ) else { return }
            if let profileID = session.profileID, !profileID.isEmpty {
                selectSyncProfile(profileID, name: session.profileDisplayName)
            }
            scheduleAccountRefresh(session)
            serverMessage = "Signed in with Clerk"
            await refreshClientConfiguration()
        } catch {
            serverMessage = error.localizedDescription
            serverConfigurationMessage = error.localizedDescription
        }
    }

    func signOutAccount() async {
        let active = accountSession
        accountSession = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        try? Self.storeToken("", account: Self.accountSessionKey)
        try? Self.storeToken("", account: "client")
        try? Self.storeToken("", account: "admin")
        accountEmail = nil
        accountRole = nil
        accountDisplayName = nil
        accountImageURL = nil
        serverToken = ""
        serverAdminToken = ""
        isServerConnected = false
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()
        serverMessage = "Signed out"
        if active?.usesNativeClerkSession == true {
            await ResonanceClerkAuthCoordinator.shared.signOut()
        } else if let active, let client = try? ResonanceSocialAuthClient(baseURL: active.baseURL) {
            await client.signOut(active)
        }
    }

    func refreshAccountSessionIfNeeded() async {
        guard let current = accountSession,
              !isRefreshingAccountSession else { return }
        let needsProfileHydration = current.profileID?.isEmpty != false
            || current.displayName?.isEmpty != false
        guard current.usesLegacyProductionServer
            || needsProfileHydration
            || current.expiresAt <= Date().addingTimeInterval(current.usesNativeClerkSession ? 15 : 5 * 60)
        else { return }
        isRefreshingAccountSession = true
        defer { isRefreshingAccountSession = false }
        do {
            let client = try ResonanceSocialAuthClient(baseURL: current.baseURL)
            let refreshed = current.usesNativeClerkSession
                ? try await ResonanceClerkAuthCoordinator.shared.accountSession(
                    for: client,
                    forceRefresh: true,
                    migrationProfileID: current.profileID ?? syncProfileID
                )
                : try await client.refresh(current, migrationProfileID: syncProfileID)
            guard accountSession == current else { return }
            try Self.storeAccountSession(refreshed)
            accountSession = refreshed
            accountEmail = refreshed.email
            accountRole = refreshed.role
            accountDisplayName = refreshed.profileDisplayName
            accountImageURL = refreshed.imageURL
            serverURL = refreshed.baseURL.absoluteString
            serverToken = refreshed.accessToken
            serverAdminToken = refreshed.isAdmin ? refreshed.accessToken : ""
            if let profileID = refreshed.profileID, !profileID.isEmpty {
                selectSyncProfile(profileID, name: refreshed.profileDisplayName)
            }
            await refreshClientConfiguration()
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
        let leadTime: TimeInterval = session.usesNativeClerkSession ? 15 : 5 * 60
        let delay = max(5, session.expiresAt.timeIntervalSinceNow - leadTime)
        accountRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshAccountSessionIfNeeded()
        }
    }

    var currentTrack: MobileTrack? {
        guard let currentTrackID else { return nil }
        return tracks.first { $0.id == currentTrackID }
            ?? streamingTrack.flatMap { $0.id == currentTrackID ? $0 : nil }
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
            revokeActiveDownloadAuthorizations()
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
        } catch is MobileBoundedResponseError {
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
        guard MobileSameOriginPolicy.matches(request.url, origin) else {
            throw URLError(.dataNotAllowed)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let delegate = MobileSameOriginRedirectDelegate(origin: origin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard MobileSameOriginPolicy.matches(response.url, origin) else {
            throw URLError(.dataNotAllowed)
        }
        if response.expectedContentLength > 0,
           response.expectedContentLength > Int64(maximumBytes) {
            throw MobileBoundedResponseError.tooLarge(limit: maximumBytes)
        }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumBytes))
        }
        for try await byte in bytes {
            guard MobileBoundedResponsePolicy.accepts(
                currentCount: data.count,
                adding: 1,
                maximum: maximumBytes
            ) else {
                throw MobileBoundedResponseError.tooLarge(limit: maximumBytes)
            }
            data.append(byte)
        }
        return (data, response)
    }

    private func sameOriginUpload(
        for request: URLRequest,
        fromFile source: URL,
        origin: URL
    ) async throws -> (Data, URLResponse) {
        guard MobileSameOriginPolicy.matches(request.url, origin) else {
            throw URLError(.dataNotAllowed)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let delegate = MobileSameOriginRedirectDelegate(origin: origin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let result = try await session.upload(for: request, fromFile: source)
        guard MobileSameOriginPolicy.matches(result.1.url, origin) else {
            throw URLError(.dataNotAllowed)
        }
        return result
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
            revokeActiveDownloadAuthorizations()
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
        revokeActiveDownloadAuthorizations()
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

    func resolveReviewedMatch(
        source rawSource: String,
        lease: MobileReviewedMatchLease
    ) async throws -> LocalImportResolution {
        guard isReviewedMatchLeaseCurrent(lease),
              let baseURL = normalizedServer() else {
            throw MobileTransferPolicyChangedError.changed
        }
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, source.utf8.count <= 8_192 else {
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
                    artworkScanComplete: true
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
    func insertLocalImportedAudio(_ imported: LocalImportedAudio) throws -> MobileTrack {
        if let duplicate = tracks.first(where: {
            $0.sourceSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.contentSHA256
        }) {
            try? fileManager.removeItem(at: imported.fileURL)
            return duplicate
        }

        let preferred = imported.fileURL.lastPathComponent
        let filename = uniqueFilename(preferred)
        let destination = musicDirectory.appendingPathComponent(filename)
        do {
            try fileManager.moveItem(at: imported.fileURL, to: destination)
            let id = UUID()
            let track = MobileTrack(
                id: id,
                title: imported.metadata.title,
                artist: imported.metadata.artist,
                album: imported.metadata.album ?? "Imported",
                duration: imported.duration,
                relativePath: filename,
                artworkFilename: saveArtwork(imported.artworkData, for: id),
                artworkScanComplete: true,
                sourceSHA256: imported.sourceSHA256,
                contentSHA256: imported.contentSHA256
            )
            tracks.append(track)
            normalizeSystemPlaylist()
            if currentTrackID == nil { currentTrackID = track.id }
            save()
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
        let queueIDs = queue.map(\.id)
        playbackQueue = queueIDs.contains(track.id) ? queueIDs : [track.id]
        playbackPlaylistID = playlistID
        history.removeAll()
        startPlayback(track)
    }

    func play(_ playlist: MobilePlaylist) {
        let queue = tracks(in: playlist)
        guard let first = shuffleEnabled ? queue.randomElement() : queue.first else { return }
        play(first, in: queue, playlistID: playlist.id)
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
        stopTimer()
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
            startTimer()
            updateNowPlaying()
            if !isTransientStream { save() }
        } catch {
            stopTimer()
            isPlaying = false
        }
    }

    func togglePlay() {
        if player?.isPlaying == true
            || streamingPlayer?.timeControlStatus == .playing
            || isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        if isTransientStreamActive, let streamingPlayer {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                streamingPlayer.playImmediately(atRate: playbackRate)
                isPlaying = true
                startTimer()
            } catch {
                isPlaying = false
            }
            updateNowPlaying()
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
            if isPlaying { startTimer() }
        } catch {
            isPlaying = false
        }
        updateNowPlaying()
    }

    func pausePlayback() {
        if isTransientStreamActive, let streamingPlayer {
            streamingPlayer.pause()
            let currentTime = streamingPlayer.currentTime().seconds
            if currentTime.isFinite { position = max(currentTime, 0) }
            stopTimer()
            isPlaying = false
            updateNowPlaying()
            return
        }
        if let player {
            player.pause()
            position = player.currentTime
            UserDefaults.standard.set(position, forKey: "Resonance.position")
        }
        stopTimer()
        isPlaying = false
        updateNowPlaying()
    }

    func seek(to fraction: Double) {
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
            return
        }
        guard let player, let track = currentTrack else { return }
        let bounds = playbackBounds(for: track, duration: player.duration)
        player.currentTime = bounds.start + (bounds.end - bounds.start) * min(max(fraction, 0), 1)
        position = player.currentTime
        UserDefaults.standard.set(position, forKey: "Resonance.position")
        updateNowPlaying()
    }

    func next() {
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
        guard !isTransientStreamActive else { return }
        if let player, let track = currentTrack {
            let bounds = playbackBounds(for: track, duration: player.duration)
            if player.currentTime > bounds.start + 3 {
                player.currentTime = bounds.start
                position = bounds.start
                updateNowPlaying()
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
        stopTimer()
        let start = currentTrack.map { playbackBounds(for: $0).start } ?? 0
        player?.currentTime = start
        position = start
        UserDefaults.standard.set(position, forKey: "Resonance.position")
        isPlaying = false
        updateNowPlaying()
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

    func tracks(in playlist: MobilePlaylist) -> [MobileTrack] {
        playlist.trackIDs.compactMap { id in tracks.first { $0.id == id } }
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
        try? fileManager.removeItem(at: fileURL(for: track))
        if let artworkFilename = track.artworkFilename {
            try? fileManager.removeItem(at: artworkDirectory.appendingPathComponent(artworkFilename))
            artworkCache.removeValue(forKey: artworkFilename)
        }
        tracks.removeAll { $0.id == track.id }
        playbackQueue.removeAll { $0 == track.id }
        history.removeAll { $0 == track.id }
        favorites.remove(track.id)
        var removedFromCustomPlaylist = false
        for index in playlists.indices {
            guard playlists[index].trackIDs.contains(track.id) else { continue }
            playlists[index].trackIDs.removeAll { $0 == track.id }
            guard !playlists[index].isSystem else { continue }
            if let remoteID = track.remoteID {
                playlists[index].remoteSongIDs?.removeAll { $0 == remoteID }
            }
            dirtyPlaylistIDs.insert(playlists[index].id)
            removedFromCustomPlaylist = true
        }
        if removedFromCustomPlaylist {
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
        await sync(songIDs: [])
        await syncPlaylistsNow()
    }
    func downloadSelected() async {
        guard !selectedRemoteSongIDs.isEmpty else { downloadDetail = "Select one or more songs first"; return }
        guard activeDownloadMode != .streamOnly else {
            downloadDetail = "Stream-only mode plays one song at a time. Tap a song to stream it."
            showTransferNotice(title: "Offline download is off", detail: downloadDetail, isError: false)
            return
        }
        await sync(songIDs: selectedRemoteSongIDs)
        await syncPlaylistsNow()
    }
    func download(_ song: MobileRemoteSong) async {
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
        await sync(songIDs: [song.id])
        await syncPlaylistsNow()
    }
    func downloadAll() async {
        guard activeDownloadMode != .streamOnly else {
            downloadDetail = "Stream-only mode does not save the server library. Tap a song to stream it."
            showTransferNotice(title: "Offline download is off", detail: downloadDetail, isError: false)
            return
        }
        await sync(songIDs: nil)
        await syncPlaylistsNow()
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

    private func sync(songIDs: Set<String>?) async {
        guard !isActivatingSyncProfile else { return }
        let submittedContext = activeServerContext
        await downloadSerialGate.acquire()
        guard !isActivatingSyncProfile, submittedContext == activeServerContext else {
            await downloadSerialGate.release()
            return
        }
        await performSync(songIDs: songIDs)
        await downloadSerialGate.release()
    }

    private func performSync(songIDs: Set<String>?) async {
        guard let baseURL = normalizedServer() else {
            isServerConnected = false
            remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                catalog: [],
                uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
            )
            serverMessage = "Enter a valid server URL."
            return
        }
        guard !serverToken.isEmpty else {
            isServerConnected = false
            remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                catalog: [],
                uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
            )
            serverMessage = "Sign in to your Resonance account."
            return
        }
        let requestsDownloads = songIDs.map { !$0.isEmpty } ?? true
        let downloadPolicyLease: MobileTransferPolicyLease?
        if requestsDownloads {
            guard let captured = captureDownloadPolicyLease(.verifiedFileCache) else {
                downloadDetail = "Verified offline downloads are no longer enabled by the signed server policy"
                showTransferNotice(
                    title: "Download policy changed",
                    detail: downloadDetail,
                    isError: true
                )
                return
            }
            downloadPolicyLease = captured
        } else {
            downloadPolicyLease = nil
        }
        catalogRequestGeneration &+= 1
        let requestGeneration = catalogRequestGeneration
        let submittedUploadMutationGeneration = uploadCatalogMutationGeneration
        let requestProfileID = syncProfileID
        isSyncing = true
        defer { isSyncing = false }
        var reachedCatalog = false
        do {
            var catalogRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/songs"))
            catalogRequest.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
            setProfileHeader(on: &catalogRequest)
            let (catalogData, response) = try await URLSession.shared.data(for: catalogRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try JSONDecoder().decode(MobileRemoteCatalog.self, from: catalogData)
            let catalogSongs = MobileCollectionNormalization.uniqueRemoteSongs(catalog.songs)
            guard requestGeneration == catalogRequestGeneration,
                  isCurrentServerContext(baseURL: baseURL, profileID: requestProfileID) else { return }
            reachedCatalog = true
            isServerConnected = true
            let uploadMutatedWhileRefreshing = submittedUploadMutationGeneration != uploadCatalogMutationGeneration
            remoteSongs = uploadMutatedWhileRefreshing || !uploadedSongsAwaitingCatalog.isEmpty
                ? MobileCatalogRefreshMergePolicy.merge(
                    catalog: catalogSongs,
                    uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
                )
                : catalogSongs
            remoteSongs = MobileCollectionNormalization.uniqueRemoteSongs(remoteSongs)
            for song in catalogSongs {
                uploadedSongsAwaitingCatalog.removeValue(forKey: song.id)
            }
            selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
            await backfillDownloadedArtwork(from: catalogSongs, baseURL: baseURL)
            if let downloadPolicyLease,
               !isDownloadPolicyLeaseCurrent(downloadPolicyLease) {
                throw MobileTransferPolicyChangedError.changed
            }
            if requestsDownloads {
                let requestedSongs = songIDs.map { ids in catalogSongs.filter { ids.contains($0.id) } } ?? catalogSongs
                let songs = requestedSongs.filter { !isSynced($0) }
                guard !songs.isEmpty else {
                    downloadProgress = 1
                    downloadDetail = "All requested songs are already on this device"
                    serverMessage = "All requested songs are already downloaded"
                    selectedRemoteSongIDs.subtract(Set(requestedSongs.map(\.id)))
                    return
                }
                isDownloading = true
                downloadProgress = 0
                defer { isDownloading = false }
                var completed = 0
                var failed = 0
                var processed = 0
                var downloadedSongIDs = Set<String>()
                for song in songs {
                    guard let downloadPolicyLease,
                          isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                        commitDownloadCheckpoint(downloadedSongIDs)
                        throw MobileTransferPolicyChangedError.changed
                    }
                    defer {
                        processed += 1
                        downloadProgress = Double(processed) / Double(max(songs.count, 1))
                    }
                    downloadDetail = "Downloading \(completed + 1) of \(songs.count) • \(song.filename)"
                    guard song.size <= MobileDownloadIntegrityPolicy.maximumFileSize else {
                        failed += 1
                        let error = MobileDownloadIntegrityError.tooLarge(
                            actual: song.size,
                            limit: MobileDownloadIntegrityPolicy.maximumFileSize
                        )
                        recordTransferFailure(
                            .download,
                            item: song.title,
                            reason: error.localizedDescription,
                            retryTarget: .download(remoteSongID: song.id)
                        )
                        continue
                    }
                    guard let remoteURL = URL(string: song.downloadURL, relativeTo: baseURL)?.absoluteURL else {
                        failed += 1
                        recordTransferFailure(
                            .download,
                            item: song.title,
                            reason: "The server returned an invalid download URL.",
                            retryTarget: .download(remoteSongID: song.id)
                        )
                        continue
                    }
                    guard sameOrigin(remoteURL, baseURL) else {
                        failed += 1
                        recordTransferFailure(
                            .download,
                            item: song.title,
                            reason: "The server returned a cross-origin file URL. Resonance only accepts the same-origin resolver.",
                            retryTarget: .download(remoteSongID: song.id)
                        )
                        continue
                    }
                    var request = URLRequest(url: remoteURL)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
                    setClientConfigContextHeaders(on: &request, profileID: requestProfileID)
                    do {
                        guard let authorization = registerDownloadAuthorization(
                            for: downloadPolicyLease
                        ) else {
                            throw MobileTransferPolicyChangedError.changed
                        }
                        defer { releaseDownloadAuthorization(authorization.id) }
                        let boundedDownload = try MobileBoundedDownloadOperation(
                            maximumSize: MobileDownloadIntegrityPolicy.maximumFileSize,
                            authorization: authorization.authorization
                        )
                        let downloaded = try await boundedDownload.run(request: request)
                        let temporaryURL = downloaded.temporaryURL
                        defer { try? fileManager.removeItem(at: temporaryURL) }
                        try Task.checkCancellation()
                        guard isCurrentServerContext(baseURL: baseURL, profileID: requestProfileID),
                              isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                            if !isDownloadPolicyLeaseCurrent(downloadPolicyLease) {
                                throw MobileTransferPolicyChangedError.changed
                            }
                            throw CancellationError()
                        }
                        try MobileDownloadIntegrityPolicy.validate(
                            expectedSize: song.size,
                            expectedSHA256: song.contentSHA256,
                            actualSize: downloaded.byteCount,
                            actualSHA256: downloaded.sha256
                        )

                        let audio = try AVAudioPlayer(contentsOf: temporaryURL)
                        let metadata = await embeddedMetadata(at: temporaryURL)
                        let artworkData: Data?
                        if let embeddedArtwork = metadata.artworkData {
                            artworkData = embeddedArtwork
                        } else {
                            artworkData = await remoteArtworkData(for: song, baseURL: baseURL)
                        }
                        try Task.checkCancellation()
                        guard isCurrentServerContext(baseURL: baseURL, profileID: requestProfileID),
                              isDownloadPolicyLeaseCurrent(downloadPolicyLease) else {
                            if !isDownloadPolicyLeaseCurrent(downloadPolicyLease) {
                                throw MobileTransferPolicyChangedError.changed
                            }
                            throw CancellationError()
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
                        let trackID = UUID()
                        tracks.append(MobileTrack(
                            id: trackID,
                            title: metadata.title ?? song.title,
                            artist: metadata.artist ?? usefulFallback(song.artist, default: "Unknown Artist"),
                            album: metadata.album ?? usefulFallback(song.album, default: "Server Library"),
                            duration: metadata.duration ?? audio.duration,
                            relativePath: filename,
                            remoteID: song.id,
                            sourceServer: baseURL.absoluteString,
                            syncProfileID: syncProfileID,
                            artworkFilename: saveArtwork(artworkData, for: trackID),
                            artworkScanComplete: true,
                            contentSHA256: downloaded.sha256
                        ))
                        downloadedSongIDs.insert(song.id)
                        completed += 1
                        save()
                    } catch is MobileTransferPolicyChangedError {
                        commitDownloadCheckpoint(downloadedSongIDs)
                        downloadDetail = "Download stopped because the signed policy changed after \(completed) completed"
                        serverMessage = downloadDetail
                        showTransferNotice(
                            title: "Download policy changed",
                            detail: downloadDetail,
                            isError: true
                        )
                        return
                    } catch is CancellationError {
                        commitDownloadCheckpoint(downloadedSongIDs)
                        downloadDetail = "Download cancelled after \(completed) completed"
                        serverMessage = downloadDetail
                        return
                    } catch let error as URLError where error.code == .cancelled {
                        commitDownloadCheckpoint(downloadedSongIDs)
                        downloadDetail = "Download cancelled after \(completed) completed"
                        serverMessage = downloadDetail
                        return
                    } catch {
                        failed += 1
                        recordTransferFailure(
                            .download,
                            item: song.title,
                            reason: error.localizedDescription,
                            retryTarget: .download(remoteSongID: song.id)
                        )
                    }
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
            } else {
                if submittedUploadMutationGeneration == uploadCatalogMutationGeneration {
                    serverMessage = "Connected • \(catalogSongs.count) song\(catalogSongs.count == 1 ? "" : "s")"
                }
            }
        } catch is MobileTransferPolicyChangedError {
            downloadDetail = "Download stopped because the signed policy expired or changed"
            serverMessage = downloadDetail
            showTransferNotice(
                title: "Download policy changed",
                detail: downloadDetail,
                isError: true
            )
        } catch {
            if !reachedCatalog {
                isServerConnected = false
                remoteSongs = MobileCatalogRefreshMergePolicy.merge(
                    catalog: [],
                    uploadedSongsAwaitingCatalog: uploadedSongsAwaitingCatalog
                )
                selectedRemoteSongIDs.removeAll()
            }
            if submittedUploadMutationGeneration == uploadCatalogMutationGeneration {
                serverMessage = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    private func refreshEmbeddedMetadata() async {
        var changed = false
        for index in tracks.indices {
            let track = tracks[index]
            guard needsMetadataRefresh(track) else { continue }
            let metadata = await embeddedMetadata(at: fileURL(for: track))
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

    private func embeddedMetadata(at url: URL) async -> EmbeddedMetadata {
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        let duration = try? await asset.load(.duration)
        let title = await metadataString(.commonKeyTitle, in: items)
        let artist = await metadataString(.commonKeyArtist, in: items)
        let author = await metadataString(.commonKeyAuthor, in: items)
        let album = await metadataString(.commonKeyAlbumName, in: items)
        let artwork = await metadataData(.commonKeyArtwork, in: items)
        return EmbeddedMetadata(
            title: title,
            artist: artist ?? author,
            album: album,
            duration: duration.map(CMTimeGetSeconds),
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
        guard let data, UIImage(data: data) != nil else { return nil }
        let filename = trackID.uuidString + ".artwork"
        do {
            try data.write(to: artworkDirectory.appendingPathComponent(filename), options: .atomic)
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
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode),
                  data.count <= 10 * 1_024 * 1_024,
                  UIImage(data: data) != nil else { return nil }
            return data
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
                await sync(songIDs: [])
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
            serverMessage = "Sign in with an administrator account first."
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

        isUploading = true
        uploadProgress = 0
        uploadDetail = "Sending source page to \(baseURL.host ?? "server")"
        defer { isUploading = false }
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
                uploadProgress = 1
                uploadDetail = "This source is already in the server library"
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
            uploadProgress = 1
            uploadDetail = imported.status == "restored"
                ? "Restored \(imported.song.title) from its source page"
                : "Imported \(imported.song.title) from its source page"
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
        guard !isDownloading else { return }
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
        isDownloading = true
        downloadProgress = 0
        downloadDetail = "Resolving \(song.title)"
        defer { isDownloading = false }
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
                artworkScanComplete: true,
                contentSHA256: MobileContentHashPolicy.normalizedSHA256(song.contentSHA256)
            )
            streamingTrack = transientTrack
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
            downloadProgress = 1
            downloadDetail = "Streaming \(song.title) • no offline file saved"
            startTimer()
            updateNowPlaying()
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
            startTimer()
        } else {
            isPlaying = false
        }
        updateNowPlaying()
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
        let authorizationLease = streamingAuthorizationLease
        streamingAuthorizationLease = nil
        loader?.invalidate()
        authorizationLease?.setInvalidationHandler(nil)
        authorizationLease?.invalidate()
        streamingTrack = nil
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
        guard activeUploadMode == .localFile else {
            uploadDetail = "Choose Local file upload mode first"
            return
        }
        guard !isUploadTransferBusy else { return }
        guard let baseURL = normalizedServer(),
              MobileUploadCredentialPolicy.canUpload(serverURL: baseURL, adminKey: serverAdminToken) else {
            uploadDetail = "Sign in with an administrator account"
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
        isUploading = true
        uploadProgress = 0
        defer { isUploading = false }
        var completed = 0
        var failed = 0
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                let uploadFilename = MobileServerUploadNaming.filename(for: source)
                uploadDetail = "Uploading \(completed + 1) of \(urls.count) • \(uploadFilename)"
                if let managedTrack = MobileManagedTrackUploadPolicy.managedTrack(
                    matching: source,
                    tracks: tracks,
                    musicDirectory: musicDirectory
                ) {
                    try MobileRemoteAssociationPolicy.validateAdoption(
                        track: managedTrack,
                        targetContext: uploadContext
                    )
                }
                let uploadedSong = try await uploadServerFile(
                    source,
                    to: baseURL,
                    profileID: uploadProfileID
                )
                guard isCurrentServerContext(baseURL: baseURL, profileID: uploadProfileID) else { continue }
                recordUploadedSong(uploadedSong)
                completed += 1
                uploadProgress = Double(completed) / Double(max(urls.count, 1))
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
                try Self.storeToken("", account: "client")
                try Self.storeToken("", account: "admin")
            } else {
                try Self.storeToken(accessToken, account: "client")
                try Self.storeToken(adminToken, account: "admin")
            }
        } catch {
            try? Self.storeToken(previousAccessToken, account: "client")
            try? Self.storeToken(previousAdminToken, account: "admin")
            serverToken = previousAccessToken
            serverAdminToken = previousAdminToken
            serverConfigurationMessage = "Could not save the account session securely: \(error.localizedDescription)"
            return false
        }

        let previousContext = activeServerContext
        let previousServerURL = normalizedServer()?.absoluteString
        clientConfigRequestGeneration &+= 1
        captureActiveProfileState()
        serverURL = resolution.url.absoluteString
        serverToken = accessToken
        serverAdminToken = adminToken
        let nextContext = activeServerContext
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
        catalogRequestGeneration &+= 1
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
        reviewedMatchLease: MobileReviewedMatchLease? = nil
    ) async throws -> Bool {
        let uploadMode = activeUploadMode
        guard uploadMode == .localFile || uploadMode == .reviewedMatch else {
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
            fileURL(for: currentTrack),
            to: baseURL,
            title: currentTrack.title,
            profileID: uploadProfileID,
            reviewedMatchLease: reviewedMatchLease
        )
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

    func dismissTransferNotice() {
        transferNotice = nil
    }

    func uploadDownloadedSongsMissingFromServer() async {
        await uploadDownloadedSongsMissingFromServer(trackIDs: nil)
    }

    private func uploadDownloadedSongsMissingFromServer(trackIDs: Set<UUID>?) async {
        guard activeUploadMode == .localFile else {
            uploadDetail = "Choose Local file upload mode first"
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
            uploadDetail = "Sign in with an administrator account"
            serverMessage = uploadDetail
            return
        }
        let uploadProfileID = syncProfileID

        isUploading = true
        uploadProgress = 0
        uploadDetail = "Checking downloaded songs…"
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
                uploadProgress = 1
                uploadDetail = "All downloaded songs are already on the server"
                serverMessage = uploadDetail
                isUploading = false
                return
            }

            var uploadedCount = 0
            var failures: [String] = []
            for (index, track) in candidates.enumerated() {
                try Task.checkCancellation()
                let source = fileURL(for: track)
                uploadDetail = "Uploading \(index + 1) of \(candidates.count) • \(MobileServerUploadNaming.filename(for: source, title: track.title))"
                var uploadedSong: MobileRemoteSong?
                var lastError: Error?
                for attempt in 1...3 {
                    do {
                        if attempt > 1 {
                            try await Task.sleep(for: .milliseconds(attempt == 2 ? 400 : 1_200))
                        }
                        uploadedSong = try await uploadServerFile(
                            source,
                            to: baseURL,
                            title: track.title,
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
                uploadProgress = Double(index + 1) / Double(candidates.count)
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
        isUploading = false

        // Playlist/like/clip synchronization must not extend the upload busy
        // state or keep the transfer overlay visible after uploads finish.
        if shouldSyncPlaylists {
            await syncPlaylistsNow()
        }
    }

    private func uploadServerFile(
        _ source: URL,
        to baseURL: URL,
        title: String? = nil,
        profileID: String,
        reviewedMatchLease: MobileReviewedMatchLease? = nil
    ) async throws -> MobileRemoteSong {
        let requiredMode: MobileUploadMode = reviewedMatchLease == nil ? .localFile : .reviewedMatch
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

        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw URLError(.fileDoesNotExist)
        }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/admin/songs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "filename", value: MobileServerUploadNaming.filename(for: source, title: title))
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream",
            forHTTPHeaderField: "Content-Type"
        )
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
        let (data, response) = try await sameOriginUpload(
            for: request,
            fromFile: source,
            origin: baseURL
        )
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
        uploadCatalogMutationGeneration &+= 1
        uploadedSongsAwaitingCatalog[song.id] = song
        remoteSongs = [song] + remoteSongs.filter { $0.id != song.id }
    }

    private func adoptUploadedDownload(
        trackID: UUID,
        remoteID: String,
        sourceServer: String,
        profileID: String
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
        save()
        schedulePlaylistSync()
    }

    func deleteRemoteSong(_ song: MobileRemoteSong) async {
        guard !isActivatingSyncProfile else { return }
        guard let baseURL = normalizedServer(), !serverAdminToken.isEmpty else {
            recordTransferFailure(
                .delete,
                item: song.title,
                reason: "Sign in with an administrator account first.",
                retryTarget: .delete(remoteSongID: song.id)
            )
            return
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/admin/songs/\(song.id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        setProfileHeader(on: &request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
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
    }

    func runAutomaticPlaylistSync() async {
        await syncPlaylistsAutomatically()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await syncPlaylistsAutomatically()
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let (data, response) = try await URLSession.shared.data(for: request)
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
                remoteSongIDs: remote.songIDs
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

    private func captureActiveProfileState() {
        guard let activeServerContext else { return }
        profileSyncStates[activeServerContext] = MobileProfileSyncState(
            playlists: playlists.filter { !$0.isSystem },
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: playlistSyncServerURL,
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
        playlistSyncServerURL = state.playlistSyncServerURL
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
            let (data, response) = try await URLSession.shared.data(for: request)
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
            let (createdData, createResponse) = try await URLSession.shared.data(for: createRequest)
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
            return
        }
        playlistSyncTask?.cancel()
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
        catalogRequestGeneration &+= 1
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
            tracks: tracks,
            playlists: playlists,
            favorites: favorites,
            serverURL: serverURL,
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: playlistSyncServerURL,
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
            transferFailures: transferFailures
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
        guard let stored = recovery.library else { return }

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
            MobileServerEndpointPolicy.canonicalContext(context) == context
        }
        for (context, state) in storedProfileStates {
            let canonicalContext = MobileServerEndpointPolicy.canonicalContext(context)
            if profileSyncStates[canonicalContext] == nil {
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

        for track in tracks where track.remoteID != nil {
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
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = player?.isPlaying == true
                || streamingPlayer?.timeControlStatus == .playing
                || isPlaying
            streamingPlayer?.pause()
            stopTimer()
            isPlaying = false
            updateNowPlaying()

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
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resumePlayback() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pausePlayback() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }

    private func startTimer() {
        stopTimer()
        guard player?.isPlaying == true || isTransientStreamActive else { return }
        let playbackTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isTransientStreamActive, let streamingPlayer = self.streamingPlayer {
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
                    self.updateNowPlaying()
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
                    if player.currentTime + 0.02 >= bounds.end {
                        self.advanceAfterFinishing()
                        return
                    }
                }
                self.position = player.currentTime
                UserDefaults.standard.set(self.position, forKey: "Resonance.position")
                self.isPlaying = true
                self.updateNowPlaying()
            }
        }
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateNowPlaying() {
        let remoteCommands = MPRemoteCommandCenter.shared()
        remoteCommands.nextTrackCommand.isEnabled = !isTransientStreamActive
        remoteCommands.previousTrackCommand.isEnabled = !isTransientStreamActive
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let bounds = playbackBounds(for: track, duration: player?.duration)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: max(bounds.end - bounds.start, 0.01),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: min(max(position - bounds.start, 0), bounds.end - bounds.start),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
        ]
        info[MPMediaItemPropertyArtwork] = nowPlayingArtwork(for: track)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func nowPlayingArtwork(for track: MobileTrack) -> MPMediaItemArtwork {
        let cacheKey = "\(track.id.uuidString)|\(track.artworkFilename ?? "fallback")"
        if cacheKey == nowPlayingArtworkCacheKey, let nowPlayingArtworkCache {
            return nowPlayingArtworkCache
        }

        // MPMediaItemArtwork is rendered outside the app process. Redrawing the
        // source into an opaque sRGB bitmap avoids CI-backed or oriented images
        // becoming a black tile on the Lock Screen and Dynamic Island.
        let image = renderedNowPlayingArtwork(from: artwork(for: track))
        let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingArtworkCacheKey = cacheKey
        nowPlayingArtworkCache = mediaArtwork
        return mediaArtwork
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
            guard let self else { return }
            self.advanceAfterFinishing()
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

    private static let keychainService = "com.gavindietrich.LikedSongsMobile"
    private static let accountSessionKey = "account-session-v1"

    private static func readAccountSession() -> ResonanceAccountSession? {
        let raw = readToken(account: accountSessionKey)
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResonanceAccountSession.self, from: data)
    }

    private static func storeAccountSession(_ session: ResonanceAccountSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw ResonanceSocialAuthError.invalidConfiguration
        }
        try storeToken(raw, account: accountSessionKey)
    }

    private struct KeychainStoreError: LocalizedError {
        let operation: String
        let status: OSStatus

        var errorDescription: String? {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(detail)"
        }
    }

    private static func storeToken(_ token: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError(operation: "delete", status: status)
            }
            return
        }

        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(operation: "update", status: updateStatus)
        }

        var newItem = query
        newItem[kSecValueData as String] = data
        let addStatus = SecItemAdd(newItem as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(operation: "add", status: addStatus)
        }
    }

    private static func readToken(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
