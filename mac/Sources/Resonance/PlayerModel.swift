import AppKit
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum MacCrossfadePolicy {
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

enum PlaylistOrderPolicy {
    static func merge<Element: Hashable>(
        previous: [Element],
        ordered: [Element],
        preserving preserved: [Element]
    ) -> [Element] {
        let previous = unique(previous)
        let ordered = unique(ordered)
        let previousSet = Set(previous)
        let orderedSet = Set(ordered)
        let preservedSet = Set(unique(preserved).filter {
            previousSet.contains($0) && !orderedSet.contains($0)
        })
        var merged: [Element] = []
        var orderedIndex = ordered.startIndex

        for previousItem in previous {
            if preservedSet.contains(previousItem) {
                merged.append(previousItem)
            } else if orderedIndex < ordered.endIndex {
                merged.append(ordered[orderedIndex])
                ordered.formIndex(after: &orderedIndex)
            }
        }
        merged.append(contentsOf: ordered[orderedIndex...])
        return unique(merged)
    }

    private static func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum PlaylistPresentationEntryID: Hashable {
    case local(UUID)
    case remote(String)

    var storageKey: String {
        switch self {
        case .local(let id): "local:\(id.uuidString.lowercased())"
        case .remote(let id): "remote:\(id)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("local:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("local:".count))) {
            self = .local(id)
        } else if storageKey.hasPrefix("remote:") {
            let id = String(storageKey.dropFirst("remote:".count))
            guard !id.isEmpty else { return nil }
            self = .remote(id)
        } else {
            return nil
        }
    }
}

enum MacServerDownloadProgressPolicy {
    static func transferHasStarted(completedBytes: Int64) -> Bool {
        completedBytes > 0
    }

    static func fraction(completedBytes: Int64, totalBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    static func batchCounter(position: Int, total: Int) -> String? {
        guard total > 0 else { return nil }
        return "\(min(max(position, 1), total))/\(total)"
    }

    static func presentationFraction(completedBytes: Int64, totalBytes: Int64) -> Double? {
        guard completedBytes > 0, totalBytes > 0 else { return nil }
        return fraction(completedBytes: completedBytes, totalBytes: totalBytes)
    }

    static func retainsPopupBetweenItems(hasStarted: Bool, position: Int, total: Int) -> Bool {
        hasStarted && position > 0 && position < total
    }

    static func percentageLabel(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped > 0 && clamped < 0.01
            ? "<1%"
            : "\(Int(clamped * 100))%"
    }
}

enum MacServerDownloadMetadataPolicy {
    static func immediateCatalog(
        knownSongs: [RemoteSong],
        catalogIsAuthoritative: Bool
    ) -> [RemoteSong]? {
        catalogIsAuthoritative ? knownSongs : nil
    }

    static func reusingKnownMetadata(
        in fetchedSongs: [RemoteSong],
        knownSongs: [RemoteSong],
        catalogIsAuthoritative: Bool
    ) -> [RemoteSong] {
        guard catalogIsAuthoritative else { return fetchedSongs }
        let knownByID = knownSongs.reduce(into: [String: RemoteSong]()) { result, song in
            guard !song.isMetadataLoading else { return }
            result[song.id] = song
        }
        return fetchedSongs.map { song in
            guard song.isMetadataLoading,
                  let known = knownByID[song.id],
                  known.sourceURL == song.sourceURL,
                  known.mediaKind == song.mediaKind else { return song }
            var updated = song
            updated.title = known.title
            updated.artist = known.artist
            updated.album = known.album
            updated.durationSeconds = known.durationSeconds
            updated.artworkURL = known.artworkURL
            updated.isMetadataLoading = false
            return updated
        }
    }
}

enum MacServerDownloadConfigurationPolicy {
    static func canStartImmediately(with configuration: MacEffectiveClientConfig) -> Bool {
        guard configuration.allowsOfflineDownload else { return false }
        switch configuration.source {
        case .verifiedServer, .verifiedCache:
            guard let document = configuration.document,
                  let expiration = MacClientConfigVerifier.expirationDate(document) else { return false }
            return expiration > .now
        case .legacyServer:
            return true
        case .safeDefaults:
            return false
        }
    }
}

enum MacRemoteMetadataHydrationPolicy {
    static func canReuse(
        activeContext: String?,
        activeRequestKeys: Set<String>,
        requestedContext: String,
        requestedRequestKeys: Set<String>
    ) -> Bool {
        activeContext == requestedContext
            && requestedRequestKeys.isSubset(of: activeRequestKeys)
    }
}

struct MacRemoteSourceResolutionCacheKey: Hashable {
    let serverContext: String
    let source: String
    let mediaMode: LocalImportMediaMode
}

enum MacRemoteSourceResolutionCachePolicy {
    static func key(
        serverContext: String,
        source: String,
        mediaMode: LocalImportMediaMode
    ) -> MacRemoteSourceResolutionCacheKey {
        MacRemoteSourceResolutionCacheKey(
            serverContext: serverContext,
            source: source,
            mediaMode: mediaMode
        )
    }

    static func isReusable(
        _ resolution: LocalImportResolution,
        key: MacRemoteSourceResolutionCacheKey,
        serverContext: String,
        song: RemoteSong,
        mediaMode: LocalImportMediaMode
    ) -> Bool {
        guard let songSource = song.sourceURL else { return false }
        let expectedMode: LocalImportMediaMode = song.mediaKind == "video" ? .video : .audio
        return key.serverContext == serverContext
            && key.source == songSource
            && key.mediaMode == mediaMode
            && mediaMode == expectedMode
            && resolution.track.sourceURL == songSource
            && resolution.track.title == song.title
            && resolution.track.artist == song.artist
    }
}

enum MacServerDownloadStatePolicy {
    static func owns(generation: UInt64, currentGeneration: UInt64) -> Bool {
        generation == currentGeneration
    }
}

enum MacServerDownloadTransferStatePolicy {
    static func owns(
        stateGeneration: UInt64,
        currentStateGeneration: UInt64,
        transferGeneration: UInt64,
        currentTransferGeneration: UInt64
    ) -> Bool {
        stateGeneration == currentStateGeneration
            && transferGeneration == currentTransferGeneration
    }
}

enum MacServerCatalogMutationPolicy {
    static func didCommit(statusCode: Int) -> Bool {
        (200..<300).contains(statusCode) || statusCode == 409
    }
}

struct MacServerDownloadFileSnapshot: Equatable {
    let size: Int64
    let modificationDate: Date
    let systemNumber: UInt64
    let systemFileNumber: UInt64
}

enum MacServerDownloadValidationPolicy {
    static func isReusable(
        validated: MacServerDownloadFileSnapshot,
        current: MacServerDownloadFileSnapshot?
    ) -> Bool {
        current == validated
    }
}

struct PlaylistPresentationEntry: Identifiable, Hashable {
    let id: PlaylistPresentationEntryID
    let track: Track?
    let remoteSongID: String?
    let remoteSong: RemoteSong?

    var isDownloaded: Bool { track != nil }
    var title: String { track?.title ?? remoteSong?.title ?? "Unavailable song" }
    var artist: String { track?.artist ?? remoteSong?.artist ?? "Not downloaded on this Mac" }
    var album: String { track?.album ?? remoteSong?.album ?? "Server playlist" }
    var kind: SongFilter { track?.kind ?? remoteSong?.kind ?? .audio }
    var durationText: String { track?.durationText ?? remoteSong?.durationText ?? "—" }
}

enum PlaylistPresentationPolicy {
    static func entries(
        in playlist: Playlist,
        tracks: [Track],
        remoteSongs: [RemoteSong]
    ) -> [PlaylistPresentationEntry] {
        let tracksByID = tracks.reduce(into: [UUID: Track]()) { result, track in
            if result[track.id] == nil { result[track.id] = track }
        }
        let playlistTracks = playlist.trackIDs.compactMap { tracksByID[$0] }
        guard !playlist.isSystem, let remoteSongIDs = playlist.remoteSongIDs else {
            return playlistTracks.map {
                PlaylistPresentationEntry(id: .local($0.id), track: $0, remoteSongID: nil, remoteSong: nil)
            }
        }

        let orderedRemoteIDs = unique(remoteSongIDs)
        let remoteIDSet = Set(orderedRemoteIDs)
        var downloadedByRemoteID: [String: Track] = [:]
        let fallbackPreviousKeys: [PlaylistPresentationEntryID] = playlistTracks.map { track in
            guard let remoteID = track.remoteID, remoteIDSet.contains(remoteID) else {
                return .local(track.id)
            }
            if downloadedByRemoteID[remoteID] == nil { downloadedByRemoteID[remoteID] = track }
            return .remote(remoteID)
        }
        let orderedKeys = orderedRemoteIDs.map(PlaylistPresentationEntryID.remote)
        let validLocalKeys = Set(fallbackPreviousKeys.filter {
            if case .local = $0 { return true }
            return false
        })
        let validRemoteKeys = Set(orderedKeys)
        let storedPreviousKeys = unique((playlist.entryOrder ?? []).compactMap(PlaylistPresentationEntryID.init(storageKey:)))
            .filter { key in
                switch key {
                case .local: validLocalKeys.contains(key)
                case .remote: validRemoteKeys.contains(key)
                }
            }
        let previousKeys = unique(storedPreviousKeys + fallbackPreviousKeys)
        let preservedKeys = previousKeys.filter {
            if case .local = $0 { return true }
            return false
        }
        let remoteSongsByID = remoteSongs.reduce(into: [String: RemoteSong]()) { result, song in
            if result[song.id] == nil { result[song.id] = song }
        }

        return PlaylistOrderPolicy.merge(
            previous: previousKeys,
            ordered: orderedKeys,
            preserving: preservedKeys
        ).compactMap { key in
            switch key {
            case .local(let trackID):
                guard let track = tracksByID[trackID] else { return nil }
                return PlaylistPresentationEntry(
                    id: key,
                    track: track,
                    remoteSongID: nil,
                    remoteSong: nil
                )
            case .remote(let remoteID):
                return PlaylistPresentationEntry(
                    id: key,
                    track: downloadedByRemoteID[remoteID],
                    remoteSongID: remoteID,
                    remoteSong: remoteSongsByID[remoteID]
                )
            }
        }
    }

    private static func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

@MainActor
final class PlaybackPositionState: ObservableObject {
    @Published private(set) var position: TimeInterval

    init(position: TimeInterval = 0) {
        self.position = position
    }

    func update(to position: TimeInterval) {
        guard self.position != position else { return }
        self.position = position
    }
}

private struct LocalMediaInspection: Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let kind: SongFilter
    let artworkData: Data?
    let fileURL: URL
}

private final class PersistenceWork<Value: Encodable>: @unchecked Sendable {
    private let value: Value
    private let key: String
    private let defaults: UserDefaults

    init(value: Value, key: String, defaults: UserDefaults) {
        self.value = value
        self.key = key
        self.defaults = defaults
    }

    func perform() {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

private final class PersistenceCoordinator: @unchecked Sendable {
    private struct Key: Hashable {
        let defaults: ObjectIdentifier
        let name: String
    }

    private let queue = DispatchQueue(
        label: "com.gavindietrich.Resonance.persistence",
        qos: .utility
    )
    private let lock = NSLock()
    private var latestGeneration: [Key: UInt64] = [:]

    func schedule<Value: Encodable>(_ value: Value, key name: String, defaults: UserDefaults) {
        let key = Key(defaults: ObjectIdentifier(defaults), name: name)
        let generation = lock.withLock { () -> UInt64 in
            let next = (latestGeneration[key] ?? 0) &+ 1
            latestGeneration[key] = next
            return next
        }
        let work = PersistenceWork(value: value, key: name, defaults: defaults)
        queue.async { [self] in
            let isLatest = lock.withLock { latestGeneration[key] == generation }
            guard isLatest else { return }
            work.perform()
            lock.withLock {
                if latestGeneration[key] == generation {
                    latestGeneration.removeValue(forKey: key)
                }
            }
        }
    }

    func flush() {
        queue.sync {}
    }
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    typealias RemoteSongMetadataResolver = @Sendable (
        _ source: String,
        _ mediaMode: LocalImportMediaMode
    ) async throws -> LocalImportSpotifyTrack

    private struct RemoteSongMetadataRequest: Sendable {
        let songIDs: [String]
        let cacheKey: String
        let source: String
        let mediaMode: LocalImportMediaMode
    }

    private struct RemoteSongMetadataResult: Sendable {
        let request: RemoteSongMetadataRequest
        let metadata: LocalImportSpotifyTrack?
    }

    private struct SharedRemoteSongMetadataTask {
        let id: UUID
        let task: Task<RemoteSongMetadataResult, Never>
    }

    private struct CachedRemoteSongMetadata: Codable, Sendable {
        let metadata: LocalImportSpotifyTrack
        let cachedAt: Date
    }

    private struct NavigationLocation: Equatable {
        let section: AppSection
        let playlistID: UUID?
    }
    private struct StoredLibrary: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
        var favorites: Set<UUID>
        var playlistRevision: Int?
        var knownRemotePlaylistIDs: Set<UUID>?
        var dirtyPlaylistIDs: Set<UUID>?
        var deletedPlaylistIDs: Set<UUID>?
        var playlistSyncServerURL: String?
        var syncProfileID: String?
        var syncProfileName: String?
        var remoteLikedSongIDs: Set<String>?
        var dirtyRemoteLikeSongIDs: Set<String>?
        var likesDirty: Bool?
        var clipRanges: [String: ClipRange]?
        var dirtyClipRangeKeys: Set<String>?
        var deletedClipRangeKeys: Set<String>?
        var completedMigrations: Set<String>?
    }

    private enum StoredLibraryLoadResult {
        case missing
        case loaded(StoredLibrary)
        case corrupt(Data)
    }

    private struct LegacyStoredTrack: Codable {
        let id: UUID
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
        let artworkRawValue: Int
        let filePath: String
        let dateAdded: Date

        var track: Track? {
            guard
                FileManager.default.fileExists(atPath: filePath),
                let artwork = ArtworkStyle(rawValue: artworkRawValue)
            else { return nil }

            return Track(
                id: id,
                title: title,
                artist: artist,
                album: album,
                duration: duration,
                artwork: artwork,
                fileURL: URL(fileURLWithPath: filePath),
                preservesUnlinkedImport: true,
                dateAdded: dateAdded
            )
        }
    }

    private struct DuplicateSongUploadResponse: Decodable {
        let duplicateOf: RemoteSong

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

    private struct ListeningHistoryUploadDocument: Encodable {
        let entries: [ListeningHistoryUploadEntry]
    }

    private struct ListeningHistoryUploadEntry: Encodable {
        let id: String
        let songID: String
        let startedAt: String
        let listenedSeconds: TimeInterval

        enum CodingKeys: String, CodingKey {
            case id
            case songID = "song_id"
            case startedAt = "started_at"
            case listenedSeconds = "listened_seconds"
        }
    }

    private struct CachedUploadCandidate: Sendable {
        let trackID: UUID
        let fileURL: URL
        let size: Int64
        let contentSHA256: String?
        let remoteID: String?
        let sourceServer: String?
        let profileID: String?
    }

    private struct CachedUploadInspectionInput: Sendable {
        let trackID: UUID
        let fileURL: URL?
        let contentSHA256: String?
        let remoteID: String?
        let sourceServer: String?
        let profileID: String?
        let isActiveRemote: Bool
    }

    private struct CachedUploadMatch: Sendable {
        let localTrackID: UUID
        let serverTrackID: UUID
    }

    private struct ServerCatalogUploadMutation {
        let generation: UInt64
        let contextKey: String
        let song: RemoteSong
    }

    private enum ServerSyncError: LocalizedError {
        case invalidURL
        case missingToken
        case missingAdminToken
        case invalidResponse
        case invalidSongIdentifier
        case crossOriginDownload
        case invalidMedia
        case missingSourceLink
        case downloadTooLarge
        case unexpectedDownloadSize
        case downloadHashMismatch
        case server(Int)
        case serverMessage(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a complete HTTPS server URL. Preview builds may use HTTP only for localhost."
            case .missingToken: "Sign in to your Resonance account."
            case .missingAdminToken: "Sign in to your Resonance account or configure a legacy admin key."
            case .invalidResponse: "The server returned an invalid response."
            case .invalidSongIdentifier: "The server returned an unsafe song identifier."
            case .crossOriginDownload: "The server returned a download URL from another server."
            case .invalidMedia: "The downloaded file is not playable media."
            case .missingSourceLink: "Only songs downloaded from a preserved source link can be uploaded. Download this song from its link again first."
            case .downloadTooLarge: "The server file exceeds the supported download size."
            case .unexpectedDownloadSize: "The downloaded file size did not match the server catalog."
            case .downloadHashMismatch: "The downloaded file checksum did not match the server catalog."
            case .server(let status): "The server returned HTTP \(status)."
            case .serverMessage(let status, let message): "The server returned HTTP \(status): \(message)"
            }
        }
    }

    private static let libraryKey = "Resonance.library.v2"
    private static let libraryRecoveryKey = "Resonance.library.v2.recovery"
    private static let legacyTracksKey = "Resonance.importedTracks.v1"
    private static let serverURLKey = "Resonance.serverURL.v1"
    private static let clientCredentialKey = "music-server-client-token"
    private static let adminCredentialKey = "music-server-admin-token"
    private static let accountSessionCredentialKey = "music-server-account-session-v1"
    private static let knownDrasticProfileID = "4f633616-9cf0-44db-8864-09358970c8f9"
    private static let volumeKey = "Resonance.volume.v1"
    private static let playbackRateKey = "Resonance.playbackRate.v1"
    private static let crossfadeEnabledKey = "Resonance.crossfadeEnabled.v1"
    private static let crossfadeSecondsKey = "Resonance.crossfadeSeconds.v1"
    private static let shuffleKey = "Resonance.shuffle.v1"
    private static let repeatKey = "Resonance.repeat.v1"
    private static let currentTrackKey = "Resonance.currentTrack.v1"
    private static let positionKey = "Resonance.position.v1"
    private static let historyKey = "Resonance.history.v1"
    private static let listeningHistoryKey = "Resonance.listeningHistory.v1"
    private static let playbackContextKey = "Resonance.playbackContext.v1"
    private static let shuffleQueueKey = "Resonance.shuffleQueue.v1"
    private static let uploadModeKeyPrefix = "Resonance.transferMode.upload.v1."
    private static let downloadModeKeyPrefix = "Resonance.transferMode.download.v1."
    private static let remoteSongMetadataCacheKey = "Resonance.remoteSongMetadata.v1"
    private static let remoteSongMetadataCacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let remoteSongMetadataCacheLimit = 2_000

    @Published var section: AppSection = .library
    @Published var tracks: [Track]
    @Published var playlists: [Playlist]
    @Published var selectedPlaylistID: UUID?
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published private(set) var playbackDuration: TimeInterval = 0
    let playbackPositionState = PlaybackPositionState()
    let playbackDiscontinuities = PassthroughSubject<TimeInterval, Never>()
    var position: TimeInterval = 0 {
        didSet { playbackPositionState.update(to: position) }
    }
    @Published var volume: Double = 0.78 {
        didSet {
            applyCrossfadeVolumes()
            remoteStreamPlayer?.volume = PlaybackVolumePolicy.gain(for: volume)
            defaults.set(volume, forKey: Self.volumeKey)
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            audioPlayer?.rate = playbackRate
            crossfadePlayer?.rate = playbackRate
            remoteStreamPlayer?.defaultRate = playbackRate
            if remoteStreamPlayer?.timeControlStatus == .playing {
                remoteStreamPlayer?.rate = playbackRate
            }
            defaults.set(Double(playbackRate), forKey: Self.playbackRateKey)
        }
    }
    @Published var shuffleEnabled = false {
        didSet { defaults.set(shuffleEnabled, forKey: Self.shuffleKey) }
    }
    @Published var repeatEnabled = false {
        didSet {
            defaults.set(repeatEnabled, forKey: Self.repeatKey)
            if repeatEnabled { cancelCrossfade() }
        }
    }
    @Published var crossfadeEnabled = false {
        didSet {
            defaults.set(crossfadeEnabled, forKey: Self.crossfadeEnabledKey)
            if !crossfadeEnabled { cancelCrossfade() }
        }
    }
    @Published var crossfadeSeconds: Double = MacCrossfadePolicy.defaultSeconds {
        didSet {
            defaults.set(
                MacCrossfadePolicy.normalizedSeconds(crossfadeSeconds),
                forKey: Self.crossfadeSecondsKey
            )
        }
    }
    @Published var favorites: Set<UUID>
    @Published private(set) var listeningHistoryEntries: [ListeningHistoryEntry] = []
    @Published var searchText = ""
    @Published var filter: SongFilter = .all
    @Published var queueTab: QueueTab = .upNext
    @Published var serverURLString = "" {
        didSet {
            let oldValue = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let newValue = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            var serverContextChanged = oldValue != newValue
            if !oldValue.isEmpty {
                let oldURL = URL(string: oldValue)
                let newURL = URL(string: newValue)
                if oldURL == nil || newURL == nil || !Self.sameOrigin(oldURL!, newURL!) {
                    cancelRemoteSongMetadataHydration()
                    serverCatalogRequestGeneration &+= 1
                    serverCatalogUploadMutations.removeAll()
                    remoteSongs.removeAll()
                    selectedRemoteSongIDs.removeAll()
                } else {
                    serverContextChanged = false
                }
            }
            if serverContextChanged {
                remoteCatalogIsAuthoritative = false
            }
            persistServerCredentialsImmediately()
            if didFinishInitialization, serverContextChanged {
                terminateListenAlongForContextChange("Listen Along ended because the server changed")
                resetClientConfigurationForCurrentContext()
            }
        }
    }
    @Published var serverToken = "" {
        didSet {
            persistServerCredentialsImmediately()
            let identityChanged = MacClientConfigContext.tokenFingerprint(oldValue)
                != MacClientConfigContext.tokenFingerprint(serverToken)
            if identityChanged {
                cancelRemoteSongMetadataHydration()
                serverCatalogRequestGeneration &+= 1
                serverCatalogUploadMutations.removeAll()
                remoteCatalogIsAuthoritative = false
            }
            if didFinishInitialization, identityChanged {
                terminateListenAlongForContextChange("Listen Along ended because the account changed")
                resetClientConfigurationForCurrentContext()
            }
        }
    }
    @Published var serverAdminToken = "" {
        didSet {
            persistServerCredentialsImmediately()
            let identityChanged = serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && MacClientConfigContext.tokenFingerprint(oldValue)
                    != MacClientConfigContext.tokenFingerprint(serverAdminToken)
            if identityChanged {
                cancelRemoteSongMetadataHydration()
                serverCatalogRequestGeneration &+= 1
                serverCatalogUploadMutations.removeAll()
                remoteCatalogIsAuthoritative = false
            }
            if didFinishInitialization, identityChanged {
                terminateListenAlongForContextChange("Listen Along ended because the account changed")
                resetClientConfigurationForCurrentContext()
            }
        }
    }
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountRole: String?
    @Published private(set) var accountDisplayName: String?
    @Published private(set) var accountImageURL: URL?
    @Published private(set) var isAuthenticatingAccount = false
    @Published var serverMessage = "Not connected"
    @Published var remoteSongs: [RemoteSong] = []
    var remoteCatalogIsAuthoritative = false
    @Published private(set) var pendingRemoteSongMetadataCount = 0
    @Published var isSyncingServer = false
    @Published var isRefreshingServerCatalog = false
    @Published private(set) var isServerDownloadTransferVisible = false
    @Published var isUploadingServer = false
    @Published private(set) var isRepairingServerMetadata = false
    @Published private(set) var isUploadingLocalImport = false
    @Published var downloadProgress: Double? = nil
    @Published private(set) var downloadBatchPosition = 0
    @Published private(set) var downloadBatchTotal = 0
    @Published var uploadProgress = 0.0
    @Published var downloadCurrentFile = ""
    @Published var uploadCurrentFile = ""
    @Published var downloadStatus = "Idle"
    @Published var uploadStatus = "Idle"
    @Published var selectedRemoteSongIDs: Set<String> = []
    @Published var isSyncingPlaylists = false
    @Published var playlistSyncStatus = "Not synced"
    @Published var fileOperationError: String?
    @Published private(set) var syncProfileID = "default"
    @Published private(set) var activeSyncProfileName = "Default"
    @Published private(set) var clientConfiguration = MacEffectiveClientConfig.safeDefaults
    @Published private(set) var clientConfigMessage = MacEffectiveClientConfig.safeDefaults.statusText
    @Published private(set) var uploadMode = MacUploadMode.localFile
    @Published private(set) var downloadMode = MacDownloadMode.verifiedFileCache
    @Published private(set) var listenAlongRole: MacListenAlongRole?
    @Published private(set) var listenAlongCode: String?
    @Published private(set) var listenAlongStatus = "Not connected"
    @Published private(set) var listenAlongError: String?

    var allowsInsecurePreviewLoopback: Bool { Self.isPreviewBundle }

    var isListenAlongHost: Bool { listenAlongRole == .host }
    var isListenAlongGuest: Bool { listenAlongRole == .guest }

    var downloadBatchCounter: String? {
        MacServerDownloadProgressPolicy.batchCounter(
            position: downloadBatchPosition,
            total: downloadBatchTotal
        )
    }

    var serverUploadActionsDisabled: Bool {
        isUploadingServer
            || isUploadingLocalImport
            || isRepairingServerMetadata
            || (isSyncingServer && !isRefreshingServerCatalog)
    }

    var localFileUploadActionsDisabled: Bool {
        serverUploadActionsDisabled || !clientConfiguration.allowsLocalFileUpload
    }

    var selectedUploadActionDisabled: Bool {
        serverUploadActionsDisabled
            || !clientConfiguration.permittedUploadModes.contains(uploadMode)
    }

    var offlineDownloadActionsDisabled: Bool {
        isUploadingServer || isSyncingServer || !clientConfiguration.allowsOfflineDownload
    }

    var offlineDownloadUnavailableMessage: String {
        clientConfiguration.allowsStreamOnlyPlayback
            ? "Stream-only playback is enabled; this song will not be saved to the library."
            : "Offline downloads are disabled by the verified server configuration."
    }

    var localImportServerConfiguration: LocalImportServerConfiguration? {
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientConfiguration.allowsReviewedMatch,
              !adminToken.isEmpty,
              let baseURL = try? normalizedServerURL() else { return nil }
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityToken = accessToken.isEmpty ? adminToken : accessToken
        return LocalImportServerConfiguration(
            baseURL: baseURL,
            adminToken: adminToken,
            profileID: syncProfileID,
            clientContext: clientConfigContext(base: baseURL, accessToken: identityToken)
        )
    }

    func beginLocalImportTransfer(
        reservingUpload: Bool,
        rawSourceInput: String? = nil,
        mediaMode: LocalImportMediaMode = .audio,
        requiresReviewedMatch: Bool = false
    ) throws -> LocalImportTransferContext {
        let baseURL = try? normalizedServerURL()
        let context = LocalImportTransferContext(
            id: UUID(),
            baseURL: baseURL,
            adminToken: reservingUpload
                ? serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            profileID: syncProfileID,
            profileName: activeSyncProfileName,
            uploadMode: uploadMode,
            rawSourceInput: rawSourceInput,
            mediaMode: mediaMode,
            requiresReviewedMatch: requiresReviewedMatch,
            reservesUpload: reservingUpload
        )
        guard !isUploadingServer,
              !isUploadingLocalImport,
              !(isSyncingServer && !isRefreshingServerCatalog) else {
            throw LocalImportTransferContextError.serverBusy
        }
        if reservingUpload,
           (context.baseURL == nil || context.adminToken?.isEmpty != false) {
            throw LocalImportTransferContextError.missingUploadConfiguration
        }
        if reservingUpload,
           !clientConfiguration.permittedUploadModes.contains(context.uploadMode) {
            throw LocalImportTransferContextError.uploadModeUnavailable
        }
        if reservingUpload, context.requiresReviewedMatch, context.uploadMode != .reviewedMatch {
            throw LocalImportTransferContextError.reviewedMatchRequired
        }
        activeLocalImportTransferID = context.id
        isUploadingLocalImport = true
        return context
    }

    func validateLocalImportTransfer(_ context: LocalImportTransferContext) throws {
        guard context.profileID == syncProfileID,
              context.baseURL?.absoluteString == (try? normalizedServerURL())?.absoluteString,
              context.uploadMode == uploadMode else {
            throw LocalImportTransferContextError.contextChanged
        }
        guard activeLocalImportTransferID == context.id,
              isUploadingLocalImport else {
            throw LocalImportTransferContextError.contextChanged
        }
        guard context.reservesUpload else { return }
        guard clientConfiguration.permittedUploadModes.contains(context.uploadMode) else {
            throw LocalImportTransferContextError.uploadModeUnavailable
        }
        let currentAdminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.adminToken == currentAdminToken else {
            throw LocalImportTransferContextError.contextChanged
        }
    }

    private func validateCommittedLocalImportTransfer(_ context: LocalImportTransferContext) throws {
        guard context.reservesUpload,
              activeLocalImportTransferID == context.id,
              isUploadingLocalImport,
              context.profileID == syncProfileID,
              context.baseURL?.absoluteString == (try? normalizedServerURL())?.absoluteString,
              context.adminToken == serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw LocalImportTransferContextError.contextChanged
        }
    }

    func endLocalImportTransfer(_ context: LocalImportTransferContext) {
        guard activeLocalImportTransferID == context.id else { return }
        activeLocalImportTransferID = nil
        isUploadingLocalImport = false
    }

    private let defaults: UserDefaults
    private let networkSession: URLSession
    private let serverLinkImportService: LocalDeviceImportService
    private let remoteSongMetadataResolver: RemoteSongMetadataResolver
    private let remoteSongMetadataRetryDelays: [Duration]
    private var remoteSourceResolutions: [MacRemoteSourceResolutionCacheKey: LocalImportResolution] = [:]
    private var remoteSongMetadataCache: [String: CachedRemoteSongMetadata]
    private let serverCacheRoot: URL?
    private let shouldPersistServerCredentials: Bool
    nonisolated private static let persistenceCoordinator = PersistenceCoordinator()
    private let systemPlaybackController: (any MacSystemPlaybackControlling)?
    private var listenAlongController: MacListenAlongController?
    private var listenAlongOperationTask: Task<Void, Never>?
    private var listenAlongPlaybackTask: Task<Void, Never>?
    private var listenAlongPlaybackGeneration: UInt64 = 0
    private var listenAlongActiveSourceURL: String?
    private var audioPlayer: AVAudioPlayer?
    private var loadedAudioTrackID: UUID?
    private var crossfadePlayer: AVAudioPlayer?
    private var crossfadeTrackID: UUID?
    private var activeCrossfadeDuration: TimeInterval = 0
    private var remoteStreamPlayer: AVPlayer?
    private var remoteStreamTrack: Track?
    private var remoteStreamSongID: String?
    private var remoteStreamDirectURL: URL?
    private var remoteStreamDirectHeaders: [String: String] = [:]
    private var remoteStreamLoader: MacAuthenticatedStreamResourceLoader?
    private var remoteYouTubeStreamLoader: MacYouTubeStreamResourceLoader?
    private var remoteStreamAuthorizationLease: MacAuthenticatedStreamAuthorizationLease?
    private var offlineDownloadAuthorizationLease: MacAuthenticatedStreamAuthorizationLease?
    private var offlineDownloadRequiresVerifiedConfiguration = false
    private var remoteStreamEndObserver: NSObjectProtocol?
    private var remoteStreamFailureObserver: NSObjectProtocol?
    private var remoteStreamStatusObservation: NSKeyValueObservation?
    private var remoteStreamPreparationTask: Task<Void, Never>?
    private var remoteStreamLoadGeneration: UInt64 = 0
    private var playbackTimer: Timer?
    private var playbackContextTrackIDs: [UUID] = []
    private var shuffledTrackIDs: [UUID] = []
    private var historyTrackIDs: [UUID] = []
    private var remoteShuffledSongIDs: [String] = []
    private var remoteHistorySongIDs: [String] = []
    private var activeListeningEntryID: UUID?
    private var lastListeningPosition: TimeInterval = 0
    private var lastPersistedListeningSeconds: TimeInterval = 0
    private var pendingListeningSeconds: TimeInterval = 0
    private var lastPersistedPlaybackPosition: TimeInterval = 0
    private var listeningHistorySyncDebounceTask: Task<Void, Never>?
    private var isSyncingListeningHistory = false
    private var listeningHistorySyncPending = false
    private var listeningHistorySyncedSeconds: [String: TimeInterval] = [:]
    private var navigationHistory: [NavigationLocation] = []
    private var navigationIndex = 0
    private var downloadTask: Task<Void, Never>?
    private var serverDownloadStateGeneration: UInt64 = 0
    private var serverDownloadTransferGeneration: UInt64 = 0
    private var uploadTask: Task<Void, Never>?
    private var playlistSyncTask: Task<Void, Never>?
    private var playlistSyncDebounceTask: Task<Void, Never>?
    private var playlistSyncPending = false
    private var playlistMutationGeneration: UInt64 = 0
    private var playlistRevision = 0
    private var knownRemotePlaylistIDs: Set<UUID> = []
    private var dirtyPlaylistIDs: Set<UUID> = []
    private var deletedPlaylistIDs: Set<UUID> = []
    private var playlistSyncServerURL: String?
    private var remoteLikedSongIDs: Set<String> = []
    private var dirtyRemoteLikeSongIDs: Set<String> = []
    private var likesDirty = false
    private var clipRanges: [String: ClipRange] = [:]
    private var dirtyClipRangeKeys: Set<String> = []
    private var deletedClipRangeKeys: Set<String> = []
    private var completedMigrations: Set<String> = []
    private var clipRangeMutationGeneration: UInt64 = 0
    private var serverCatalogRequestGeneration: UInt64 = 0
    private var serverMetadataHydrationGeneration: UInt64 = 0
    private var serverMetadataHydrationTask: Task<Void, Never>?
    private var serverMetadataHydrationContextKey: String?
    private var serverMetadataHydrationRequestKeys: Set<String> = []
    private var sharedRemoteSongMetadataTasks: [String: SharedRemoteSongMetadataTask] = [:]
    private var serverUploadMutationGeneration: UInt64 = 0
    private var serverCatalogUploadMutations: [ServerCatalogUploadMutation] = []
    private var activeLocalImportTransferID: UUID?
    private var didFinishInitialization = false
    private var clientConfigRequestGeneration: UInt64 = 0
    private var clientConfigExpiryTask: Task<Void, Never>?
    private var clientConfigRenewalAttemptedExpiry: String?
    private var accountSession: ResonanceAccountSession?
    private var accountRefreshTask: Task<Void, Never>?
    private var isRefreshingAccountSession = false

    init(
        loadPersistedLibrary: Bool = true,
        defaults: UserDefaults = .standard,
        networkSession: URLSession = .shared,
        serverCacheRoot: URL? = nil,
        persistServerCredentials: Bool = true,
        systemPlaybackController: (any MacSystemPlaybackControlling)? = nil,
        legacyApplicationSupportMigration: LegacyApplicationSupportMigration? = nil,
        remoteSongMetadataResolver: RemoteSongMetadataResolver? = nil,
        remoteSongMetadataRetryDelays: [Duration] = [.milliseconds(400), .milliseconds(1_600)]
    ) {
        Self.persistenceCoordinator.flush()
        let serverLinkImportService = LocalDeviceImportService()
        self.defaults = defaults
        self.networkSession = networkSession
        self.serverLinkImportService = serverLinkImportService
        self.remoteSongMetadataResolver = remoteSongMetadataResolver ?? { source, mediaMode in
            try await serverLinkImportService.resolveMetadata(
                source: source,
                mediaMode: mediaMode
            )
        }
        self.remoteSongMetadataRetryDelays = remoteSongMetadataRetryDelays
        self.remoteSongMetadataCache = Self.loadRemoteSongMetadataCache(from: defaults)
        self.serverCacheRoot = serverCacheRoot
        self.shouldPersistServerCredentials = persistServerCredentials
        self.systemPlaybackController = systemPlaybackController
        self.listenAlongController = nil
        if persistServerCredentials {
            Self.prepareCredentialStore()
        }

        let loadResult = loadPersistedLibrary ? Self.loadLibrary(from: defaults) : .missing
        var stored: StoredLibrary?
        let libraryWasCorrupt: Bool
        switch loadResult {
        case .missing:
            stored = nil
            libraryWasCorrupt = false
        case .loaded(let library):
            stored = library
            libraryWasCorrupt = false
        case .corrupt(let data):
            stored = nil
            libraryWasCorrupt = true
            // Preserve the undecodable bytes before the user makes any new library changes.
            // This keeps manual recovery possible without boot-looping the app.
            defaults.set(data, forKey: Self.libraryRecoveryKey)
        }
        let restoredSyncProfileID = stored?.syncProfileID ?? "default"
        let restoredSyncProfileName = stored?.syncProfileName
            ?? Self.fallbackProfileName(for: restoredSyncProfileID)
        let restoredServerOrigin = Self.originFromServerContextKey(stored?.playlistSyncServerURL)
            ?? ServerSongIdentity.normalizedOrigin(defaults.string(forKey: Self.serverURLKey))
        var didMigrateUnlinkedDownloads = false
        if loadPersistedLibrary,
           var library = stored,
           !(library.completedMigrations ?? []).contains(UnlinkedDownloadMigrationPolicy.identifier),
           let cacheRoot = Self.serverCacheRootDirectory(customRoot: serverCacheRoot) {
            let migration = Self.migrateUnlinkedDownloads(
                library.tracks,
                managedCacheRoot: cacheRoot
            )
            library.tracks = migration.tracks
            if migration.completed {
                var migrations = library.completedMigrations ?? []
                migrations.insert(UnlinkedDownloadMigrationPolicy.identifier)
                library.completedMigrations = migrations
            }
            stored = library
            didMigrateUnlinkedDownloads = migration.changed || migration.completed
        }
        // A file can be temporarily unavailable when an external or network volume is
        // disconnected. Keep its library record and let playback surface availability.
        var migratedPersistedFileURLs = false
        let existingTracks = (stored?.tracks ?? []).map { track in
            var migrated = track
            if let fileURL = migrated.fileURL,
               let migratedURL = legacyApplicationSupportMigration?.migratedFileURL(fileURL) {
                migrated.fileURL = migratedURL
                migratedPersistedFileURLs = true
            }
            if migrated.remoteID != nil, migrated.syncProfileID == nil {
                migrated.syncProfileID = restoredSyncProfileID
            }
            if migrated.remoteID != nil,
               migrated.sourceServer == nil,
               (migrated.syncProfileID ?? "default") == restoredSyncProfileID {
                migrated.sourceServer = restoredServerOrigin
            }
            if let filename = migrated.fileURL?.lastPathComponent,
               MediaKindClassifier.kind(contentType: "", filename: filename) == .video {
                migrated.kind = .video
            }
            return migrated
        }
        var seenRemoteIDs = Set<String>()
        let availableTracks = existingTracks.filter { track in
            guard let remoteID = track.remoteID else { return true }
            if let identity = track.remoteIdentity {
                return seenRemoteIDs.insert(
                    "\(identity.origin)\u{0}\(identity.profileID)\u{0}\(identity.songID)"
                ).inserted
            }
            let profileID = track.syncProfileID ?? "default"
            return seenRemoteIDs.insert("legacy\u{0}\(profileID)\u{0}\(remoteID)").inserted
        }
        let validIDs = Set(availableTracks.map(\.id))
        let availableFavorites = (stored?.favorites ?? []).intersection(validIDs)
        var likedTrackIDs: [UUID] = []
        for trackID in stored?.playlists.first(where: \.isSystem)?.trackIDs ?? []
        where availableFavorites.contains(trackID) && !likedTrackIDs.contains(trackID) {
            likedTrackIDs.append(trackID)
        }
        for trackID in availableTracks.map(\.id)
        where availableFavorites.contains(trackID) && !likedTrackIDs.contains(trackID) {
            likedTrackIDs.append(trackID)
        }

        var availablePlaylists = (stored?.playlists ?? [])
            .map { playlist in
                var copy = playlist
                copy.trackIDs = copy.trackIDs.filter(validIDs.contains)
                return copy
            }

        if let libraryIndex = availablePlaylists.firstIndex(where: \.isSystem) {
            availablePlaylists[libraryIndex].name = "Liked Songs"
            availablePlaylists[libraryIndex].artwork = .liked
            availablePlaylists[libraryIndex].trackIDs = likedTrackIDs
            if libraryIndex != 0 {
                let library = availablePlaylists.remove(at: libraryIndex)
                availablePlaylists.insert(library, at: 0)
            }
        } else {
            availablePlaylists.insert(.library(trackIDs: likedTrackIDs), at: 0)
        }

        tracks = availableTracks
        playlists = availablePlaylists
        favorites = availableFavorites
        selectedPlaylistID = availablePlaylists.first?.id
        let persistedTrackID = defaults.string(forKey: Self.currentTrackKey).flatMap(UUID.init(uuidString:))
        currentTrackID = persistedTrackID.flatMap { wanted in availableTracks.first(where: { $0.id == wanted })?.id }
            ?? availableTracks.first?.id
        let restoredAccountSession = persistServerCredentials ? Self.readAccountSession() : nil
        accountSession = restoredAccountSession
        let restoredServerURLString = restoredAccountSession?.baseURL.absoluteString
            ?? (persistServerCredentials ? (defaults.string(forKey: Self.serverURLKey) ?? "") : "")
        serverURLString = ServerEndpointPolicy.normalizedURL(
            restoredServerURLString,
            allowsInsecurePreviewLoopback: !persistServerCredentials
        )?.absoluteString ?? restoredServerURLString
        serverToken = restoredAccountSession?.accessToken
            ?? (persistServerCredentials ? Self.readServerToken() : "")
        serverAdminToken = restoredAccountSession?.accessToken
            ?? (persistServerCredentials ? Self.readServerToken(key: Self.adminCredentialKey) : "")
        accountEmail = restoredAccountSession?.email
        accountRole = restoredAccountSession?.role
        accountDisplayName = restoredAccountSession?.profileDisplayName
        accountImageURL = restoredAccountSession?.imageURL
        if restoredAccountSession != nil {
            Self.saveServerToken("")
            Self.saveServerToken("", key: Self.adminCredentialKey)
        }
        playlistRevision = stored?.playlistRevision ?? 0
        knownRemotePlaylistIDs = stored?.knownRemotePlaylistIDs ?? []
        dirtyPlaylistIDs = stored?.dirtyPlaylistIDs ?? []
        deletedPlaylistIDs = stored?.deletedPlaylistIDs ?? []
        playlistSyncServerURL = Self.canonicalServerContextKey(stored?.playlistSyncServerURL)
        syncProfileID = restoredSyncProfileID
        activeSyncProfileName = restoredSyncProfileName
        if restoredAccountSession?.profileID == restoredSyncProfileID,
           let restoredAccountSession {
            activeSyncProfileName = restoredAccountSession.profileDisplayName
        }
        remoteLikedSongIDs = stored?.remoteLikedSongIDs ?? Set(availableFavorites.compactMap { trackID in
            availableTracks.first(where: {
                $0.id == trackID
                    && ($0.syncProfileID ?? "default") == restoredSyncProfileID
                    && ($0.remoteID == nil
                        || ServerSongIdentity.normalizedOrigin($0.sourceServer) == restoredServerOrigin)
            })?.remoteID
        })
        if let storedDirtyLikeIDs = stored?.dirtyRemoteLikeSongIDs {
            dirtyRemoteLikeSongIDs = storedDirtyLikeIDs
        } else if stored?.likesDirty ?? false {
            dirtyRemoteLikeSongIDs = Set(availableTracks.compactMap { track in
                guard track.remoteID != nil,
                      (track.syncProfileID ?? "default") == restoredSyncProfileID,
                      ServerSongIdentity.normalizedOrigin(track.sourceServer) == restoredServerOrigin else {
                    return nil
                }
                return track.remoteID
            })
        }
        likesDirty = !dirtyRemoteLikeSongIDs.isEmpty
        clipRanges = stored?.clipRanges ?? [:]
        dirtyClipRangeKeys = stored?.dirtyClipRangeKeys ?? []
        deletedClipRangeKeys = stored?.deletedClipRangeKeys ?? []
        completedMigrations = stored?.completedMigrations ?? []
        if loadPersistedLibrary, stored == nil, !libraryWasCorrupt {
            completedMigrations.insert(UnlinkedDownloadMigrationPolicy.identifier)
        }

        super.init()

        self.listenAlongController = MacListenAlongController(
            networkSession: networkSession,
            requestBuilder: { [weak self] url, method, body, extraHeaders in
                guard let self,
                      !self.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let base = try? self.normalizedServerURL(),
                      Self.sameOrigin(url, base) else {
                    throw MacListenAlongError.invalidContext
                }
                var request = self.authenticatedRequest(url: url)
                request.httpMethod = method
                request.httpBody = body
                for (name, value) in extraHeaders {
                    request.setValue(value, forHTTPHeaderField: name)
                }
                return request
            }
        )
        listenAlongController?.onSnapshot = { [weak self] snapshot, role in
            self?.receiveListenAlongSnapshot(snapshot, role: role)
        }
        listenAlongController?.onStatus = { [weak self] status in
            self?.listenAlongStatus = status
        }
        listenAlongController?.onEnded = { [weak self] message in
            self?.listenAlongSessionEnded(message)
        }

        if defaults.object(forKey: Self.volumeKey) != nil { volume = defaults.double(forKey: Self.volumeKey) }
        if defaults.object(forKey: Self.playbackRateKey) != nil { playbackRate = Float(defaults.double(forKey: Self.playbackRateKey)) }
        crossfadeEnabled = defaults.bool(forKey: Self.crossfadeEnabledKey)
        if defaults.object(forKey: Self.crossfadeSecondsKey) != nil {
            crossfadeSeconds = MacCrossfadePolicy.normalizedSeconds(
                defaults.double(forKey: Self.crossfadeSecondsKey)
            )
        }
        shuffleEnabled = defaults.bool(forKey: Self.shuffleKey)
        repeatEnabled = defaults.bool(forKey: Self.repeatKey)
        position = defaults.double(forKey: Self.positionKey)
        playbackDuration = max(currentTrack?.duration ?? 0, 0)
        if let currentTrack {
            let bounds = playbackBounds(for: currentTrack, duration: playbackDuration)
            position = min(max(position, bounds.start), bounds.end)
        }
        playbackPositionState.update(to: position)
        historyTrackIDs = (defaults.stringArray(forKey: Self.historyKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter(validIDs.contains)
        if
            let listeningHistoryData = defaults.data(forKey: Self.listeningHistoryKey),
            let decodedHistory = try? JSONDecoder().decode(
                [ListeningHistoryEntry].self,
                from: listeningHistoryData
            )
        {
            let validHistory = decodedHistory.filter {
                validIDs.contains($0.trackID) || $0.originatedOnThisDevice == false
            }
            let restoredHistoryOrigin = restoredServerOrigin
            let migratedLegacyHistory = validHistory.contains {
                $0.syncProfileID == nil || ($0.serverOrigin == nil && restoredHistoryOrigin != nil)
            }
            listeningHistoryEntries = Array(
                validHistory
                    .map { entry in
                        var scopedEntry = entry
                        if scopedEntry.syncProfileID == nil {
                            scopedEntry.syncProfileID = syncProfileID
                        }
                        if scopedEntry.serverOrigin == nil {
                            scopedEntry.serverOrigin = restoredHistoryOrigin
                        }
                        return scopedEntry
                    }
                    .suffix(2_000)
            )
            if migratedLegacyHistory { persistListeningHistory() }
        }
        let restoredContext = Self.restoredTrackIDs(
            from: defaults.stringArray(forKey: Self.playbackContextKey),
            validIDs: validIDs
        )
        if let currentTrackID, restoredContext.contains(currentTrackID) {
            playbackContextTrackIDs = restoredContext
        }
        let contextIDs = Set(playbackContextTrackIDs)
        shuffledTrackIDs = Self.restoredTrackIDs(
            from: defaults.stringArray(forKey: Self.shuffleQueueKey),
            validIDs: contextIDs.isEmpty ? validIDs : contextIDs
        ).filter { $0 != currentTrackID }
        navigationHistory = [NavigationLocation(section: .library, playlistID: nil)]
        defaults.set(volume, forKey: Self.volumeKey)
        defaults.set(Double(playbackRate), forKey: Self.playbackRateKey)
        defaults.set(crossfadeEnabled, forKey: Self.crossfadeEnabledKey)
        defaults.set(crossfadeSeconds, forKey: Self.crossfadeSecondsKey)
        persistPlaybackPosition()
        persistPlaybackContext()
        persistShuffleQueue()
        hydrateRemotePlaylistTracks()

        if loadPersistedLibrary {
            Task { @MainActor [weak self] in
                await self?.reconcileLocalPlayableDurations()
                await self?.reconcileCachedUploadedLocalTracks()
            }
        }

        if loadPersistedLibrary, stored == nil, !libraryWasCorrupt {
            migrateLegacyLibraryIfNeeded()
        } else if migratedPersistedFileURLs || didMigrateUnlinkedDownloads {
            persistLibrary()
        }
        didFinishInitialization = true
        resetClientConfigurationForCurrentContext()
        configureSystemPlaybackHandlers()
        if let restoredAccountSession { scheduleAccountRefresh(restoredAccountSession) }
    }

    deinit {
        accountRefreshTask?.cancel()
        serverMetadataHydrationTask?.cancel()
        Self.persistenceCoordinator.flush()
        playlistSyncTask?.cancel()
        playlistSyncDebounceTask?.cancel()
        listeningHistorySyncDebounceTask?.cancel()
        clientConfigExpiryTask?.cancel()
        listenAlongOperationTask?.cancel()
        listenAlongPlaybackTask?.cancel()
        MainActor.assumeIsolated {
            systemPlaybackController?.invalidate()
        }
    }

    var currentTrack: Track? {
        guard let currentTrackID else { return nil }
        return tracks.first { $0.id == currentTrackID }
            ?? remoteStreamTrack.flatMap { $0.id == currentTrackID ? $0 : nil }
    }

    func isStreamingRemoteSong(_ song: RemoteSong) -> Bool {
        remoteStreamSongID == song.id && remoteStreamTrack?.id == currentTrackID
    }

    func canFavorite(_ track: Track) -> Bool {
        tracks.contains(where: { $0.id == track.id })
    }

    var selectedPlaylist: Playlist? {
        guard let selectedPlaylistID else { return nil }
        return playlists.first { $0.id == selectedPlaylistID }
    }

    var customPlaylists: [Playlist] {
        playlists.filter { !$0.isSystem }
    }

    var canNavigateBack: Bool { navigationIndex > 0 }
    var canNavigateForward: Bool { navigationIndex + 1 < navigationHistory.count }

    var isCollectionPlaying: Bool {
        guard isPlaying, let currentTrackID else { return false }
        return playbackTracks.contains { $0.id == currentTrackID }
    }

    var displayedTracks: [Track] {
        let collectionTracks = unfilteredCollectionTracks

        let filtered: [Track]
        switch filter {
        case .all:
            filtered = collectionTracks
        case .recentlyAdded:
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            filtered = collectionTracks.filter { $0.dateAdded >= cutoff }
        case .audio:
            filtered = collectionTracks.filter { $0.kind == .audio }
        case .video:
            filtered = collectionTracks.filter { $0.kind == .video }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { track in
            track.title.localizedCaseInsensitiveContains(query)
                || track.artist.localizedCaseInsensitiveContains(query)
                || track.album.localizedCaseInsensitiveContains(query)
        }
    }

    var unfilteredCollectionEntries: [PlaylistPresentationEntry] {
        if section == .playlists, let playlist = selectedPlaylist {
            return playlistEntries(in: playlist)
        }
        return visibleTracks.map {
            PlaylistPresentationEntry(id: .local($0.id), track: $0, remoteSongID: nil, remoteSong: nil)
        }
    }

    var displayedCollectionEntries: [PlaylistPresentationEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        let filtered = unfilteredCollectionEntries.filter { entry in
            switch filter {
            case .all:
                return true
            case .recentlyAdded:
                return entry.track.map { $0.dateAdded >= cutoff } ?? false
            case .audio:
                return entry.kind == .audio
            case .video:
                return entry.kind == .video
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return filtered }
        return filtered.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.artist.localizedCaseInsensitiveContains(query)
                || entry.album.localizedCaseInsensitiveContains(query)
        }
    }

    func playlistEntries(in playlist: Playlist) -> [PlaylistPresentationEntry] {
        PlaylistPresentationPolicy.entries(in: playlist, tracks: tracks, remoteSongs: remoteSongs)
    }

    func playlistEntryCount(_ playlist: Playlist) -> Int {
        playlistEntries(in: playlist).count
    }

    var unfilteredCollectionTracks: [Track] {
        if section == .playlists, let playlist = selectedPlaylist {
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            return playlist.trackIDs.compactMap { tracksByID[$0] }
        } else {
            return visibleTracks
        }
    }

    var visibleTracks: [Track] {
        let activeOrigin = (try? normalizedServerURL()).flatMap(ServerSongIdentity.normalizedOrigin)
        return tracks.filter {
            guard $0.remoteID != nil else { return true }
            guard ($0.syncProfileID ?? "default") == syncProfileID else { return false }
            guard let activeOrigin else { return true }
            guard let trackOrigin = ServerSongIdentity.normalizedOrigin($0.sourceServer) else {
                return false
            }
            return trackOrigin == activeOrigin
        }
    }

    var activeProfileListeningHistoryEntries: [ListeningHistoryEntry] {
        let activeOrigin = (try? normalizedServerURL()).flatMap(ServerSongIdentity.normalizedOrigin)
        return listeningHistoryEntries.filter {
            guard ($0.syncProfileID ?? "default") == syncProfileID else { return false }
            guard let activeOrigin else { return true }
            guard let entryOrigin = $0.serverOrigin else { return false }
            return entryOrigin == activeOrigin
        }
    }

    var hasActiveLibraryFilter: Bool {
        filter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historyTracks: [Track] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let localTracksByMetadataKey = ListeningHistoryTrackResolver.localTracksByMetadataKey(tracks)
        var tracksByRemoteIdentity: [String: Track] = [:]
        for track in tracks {
            guard let remoteID = track.remoteID else { continue }
            tracksByRemoteIdentity[ListeningHistoryTrackResolver.remoteIdentity(
                serverOrigin: ServerSongIdentity.normalizedOrigin(track.sourceServer),
                profileID: track.syncProfileID,
                remoteSongID: remoteID
            )] = track
        }
        let scopedHistory = activeProfileListeningHistoryEntries
            .filter { $0.id != activeListeningEntryID }
        let listeningHistory = scopedHistory
            .filter { entry in
                let track = ListeningHistoryTrackResolver.track(
                    for: entry,
                    tracksByID: tracksByID,
                    tracksByRemoteIdentity: tracksByRemoteIdentity,
                    localTracksByMetadataKey: localTracksByMetadataKey
                )
                return ListeningHistoryPlayPolicy.qualifies(entry, track: track)
            }
            .sorted { $0.startedAt > $1.startedAt }
        if !scopedHistory.isEmpty {
            return listeningHistory.map {
                ListeningHistoryTrackResolver.track(
                    for: $0,
                    tracksByID: tracksByID,
                    tracksByRemoteIdentity: tracksByRemoteIdentity,
                    localTracksByMetadataKey: localTracksByMetadataKey
                )
            }
        }
        return historyTrackIDs.reversed().compactMap { tracksByID[$0] }
    }

    var queueTracks: [Track] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        if queueTab == .history {
            return historyTracks
        }

        let context = activePlaybackTracks
        guard !context.isEmpty else { return [] }
        if shuffleEnabled {
            return shuffledTrackIDs.compactMap { tracksByID[$0] }
        }

        guard
            let currentTrackID,
            let currentIndex = context.firstIndex(where: { $0.id == currentTrackID })
        else { return context }

        return Array(context[context.index(after: currentIndex)...]) + Array(context[..<currentIndex])
    }

    var collectionTitle: String {
        section == .playlists ? (selectedPlaylist?.name ?? "Playlist") : "Library"
    }

    var collectionArtwork: ArtworkStyle {
        section == .playlists ? (selectedPlaylist?.artwork ?? .liked) : .liked
    }

    var collectionTrackCount: Int {
        section == .playlists ? unfilteredCollectionEntries.count : tracks.count
    }

    var collectionDownloadedTrackCount: Int {
        section == .playlists
            ? unfilteredCollectionEntries.reduce(0) { $0 + ($1.isDownloaded ? 1 : 0) }
            : tracks.count
    }

    func selectSection(_ newSection: AppSection) {
        navigate(to: NavigationLocation(section: newSection, playlistID: nil))
    }

    func selectPlaylist(_ playlist: Playlist) {
        guard playlists.contains(where: { $0.id == playlist.id }) else { return }
        navigate(to: NavigationLocation(section: .playlists, playlistID: playlist.id))
    }

    func navigateBack() {
        guard canNavigateBack else { return }
        navigationIndex -= 1
        applyNavigation(navigationHistory[navigationIndex])
    }

    func navigateForward() {
        guard canNavigateForward else { return }
        navigationIndex += 1
        applyNavigation(navigationHistory[navigationIndex])
    }

    private func navigate(to location: NavigationLocation) {
        let current = NavigationLocation(section: section, playlistID: selectedPlaylistID)
        guard location != current else { return }
        if navigationIndex + 1 < navigationHistory.count {
            navigationHistory.removeSubrange((navigationIndex + 1)...)
        }
        navigationHistory.append(location)
        navigationIndex = navigationHistory.count - 1
        applyNavigation(location)
    }

    private func applyNavigation(_ location: NavigationLocation) {
        section = location.section
        selectedPlaylistID = location.playlistID
        filter = .all
        searchText = ""
        reconcileShuffleOrderIfNeeded()
    }

    @discardableResult
    func createPlaylist(named rawName: String) -> Playlist? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !name.isEmpty,
            !playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
        else { return nil }

        let styles: [ArtworkStyle] = [.lateNight, .softFocus, .onRepeat, .electric, .golden, .falling]
        let playlist = Playlist(
            name: name,
            artwork: styles[customPlaylists.count % styles.count],
            trackIDs: [],
            remoteSongIDs: []
        )
        playlists.append(playlist)
        markPlaylistDirty(playlist.id)
        selectedPlaylistID = playlist.id
        section = .playlists
        persistLibrary()
        schedulePlaylistSync()
        return playlist
    }

    func clipRange(for track: Track) -> ClipRange? {
        clipRanges[clipRangeKey(for: track)]
    }

    func saveClipRange(for track: Track, start: TimeInterval, end: TimeInterval) {
        guard let normalized = try? ClipRangePolicy.normalized(
            start: start,
            end: end,
            sourceDuration: track.duration
        ) else { return }
        let bounds = ClipPlaybackPolicy.Bounds(start: normalized.lowerBound, end: normalized.upperBound)
        let key = clipRangeKey(for: track)
        clipRanges[key] = ClipRange(startSeconds: bounds.start, endSeconds: bounds.end)
        clipRangeMutationGeneration &+= 1
        if track.remoteID != nil {
            dirtyClipRangeKeys.insert(key)
            deletedClipRangeKeys.remove(key)
        }
        if currentTrackID == track.id, position < bounds.start || position >= bounds.end {
            seekToTime(bounds.start)
        }
        persistLibrary()
        schedulePlaylistSync()
        publishSystemPlayback()
    }

    func clearClipRange(for track: Track) {
        let key = clipRangeKey(for: track)
        guard clipRanges.removeValue(forKey: key) != nil else { return }
        clipRangeMutationGeneration &+= 1
        if track.remoteID != nil {
            dirtyClipRangeKeys.insert(key)
            deletedClipRangeKeys.insert(key)
        }
        persistLibrary()
        schedulePlaylistSync()
        publishSystemPlayback()
    }

    func deletePlaylist(_ playlist: Playlist) {
        guard !playlist.isSystem else { return }
        playlists.removeAll { $0.id == playlist.id }
        markPlaylistDeleted(playlist.id)
        if selectedPlaylistID == playlist.id {
            selectedPlaylistID = nil
            section = .playlists
        }
        persistLibrary()
        schedulePlaylistSync()
    }

    func addTrack(_ track: Track, to playlist: Playlist) {
        guard
            !playlist.isSystem,
            let index = playlists.firstIndex(where: { $0.id == playlist.id }),
            !playlists[index].trackIDs.contains(track.id)
        else { return }
        playlists[index].trackIDs.append(track.id)
        updateRemoteSongIDs(forPlaylistAt: index)
        markPlaylistDirty(playlist.id)
        persistLibrary()
        schedulePlaylistSync()
    }

    func upsertImportedPlaylist(named rawName: String, tracks importedTracks: [Track]) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedIDs = importedTracks.map(\.id)
        guard !name.isEmpty, !importedIDs.isEmpty else { return }
        let index: Int
        if let existing = playlists.firstIndex(where: {
            !$0.isSystem && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) {
            index = existing
        } else {
            let styles: [ArtworkStyle] = [.lateNight, .softFocus, .onRepeat, .electric, .golden, .falling]
            playlists.append(Playlist(
                name: name,
                artwork: styles[customPlaylists.count % styles.count],
                trackIDs: [],
                remoteSongIDs: []
            ))
            index = playlists.index(before: playlists.endIndex)
        }
        var seen = Set(playlists[index].trackIDs)
        playlists[index].trackIDs.append(contentsOf: importedIDs.filter { seen.insert($0).inserted })
        updateRemoteSongIDs(forPlaylistAt: index)
        markPlaylistDirty(playlists[index].id)
        persistLibrary()
        schedulePlaylistSync()
    }

    func removeTrackFromSelectedPlaylist(_ track: Track) {
        guard let selectedPlaylist else { return }
        removeTrack(track, from: selectedPlaylist.id)
    }

    func removeTrack(_ track: Track, from playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[index].isSystem else { return }
        playlists[index].trackIDs.removeAll { $0 == track.id }
        updateRemoteSongIDs(forPlaylistAt: index)
        markPlaylistDirty(playlistID)
        persistLibrary()
        schedulePlaylistSync()
    }

    func moveTrack(_ trackID: UUID, over targetTrackID: UUID, in playlistID: UUID) {
        guard trackID != targetTrackID,
              let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let sourceIndex = playlists[playlistIndex].trackIDs.firstIndex(of: trackID),
              let targetIndex = playlists[playlistIndex].trackIDs.firstIndex(of: targetTrackID)
        else { return }

        let movedTrackID = playlists[playlistIndex].trackIDs.remove(at: sourceIndex)
        playlists[playlistIndex].trackIDs.insert(
            movedTrackID,
            at: min(targetIndex, playlists[playlistIndex].trackIDs.endIndex)
        )
        if !playlists[playlistIndex].isSystem {
            updateRemoteSongIDs(forPlaylistAt: playlistIndex)
            markPlaylistDirty(playlistID)
        }
        persistLibrary()
        if !playlists[playlistIndex].isSystem {
            schedulePlaylistSync()
        }
    }

    func moveTrack(_ trackID: UUID, to destinationIndex: Int, in playlistID: UUID) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }),
              let sourceIndex = playlists[playlistIndex].trackIDs.firstIndex(of: trackID)
        else { return }

        let movedTrackID = playlists[playlistIndex].trackIDs.remove(at: sourceIndex)
        let clampedDestination = min(max(destinationIndex, 0), playlists[playlistIndex].trackIDs.endIndex)
        playlists[playlistIndex].trackIDs.insert(movedTrackID, at: clampedDestination)
        if !playlists[playlistIndex].isSystem {
            updateRemoteSongIDs(forPlaylistAt: playlistIndex)
            markPlaylistDirty(playlistID)
        }
        persistLibrary()
        if !playlists[playlistIndex].isSystem {
            schedulePlaylistSync()
        }
    }

    func movePlaylistEntry(
        _ entryID: PlaylistPresentationEntryID,
        to destinationIndex: Int,
        in playlistID: UUID
    ) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var entries = playlistEntries(in: playlists[playlistIndex])
        guard let sourceIndex = entries.firstIndex(where: { $0.id == entryID }) else { return }

        let movedEntry = entries.remove(at: sourceIndex)
        let clampedDestination = min(max(destinationIndex, 0), entries.endIndex)
        entries.insert(movedEntry, at: clampedDestination)
        if !playlists[playlistIndex].isSystem {
            playlists[playlistIndex].entryOrder = entries.map { $0.id.storageKey }
        }
        playlists[playlistIndex].trackIDs = entries.compactMap(\.track?.id)
        if !playlists[playlistIndex].isSystem {
            playlists[playlistIndex].remoteSongIDs = entries.compactMap(\.remoteSongID)
            markPlaylistDirty(playlistID)
        }
        persistLibrary()
        if !playlists[playlistIndex].isSystem {
            schedulePlaylistSync()
        }
    }

    func removeTrackFromLibrary(_ track: Track) {
        let removingCurrentTrack = currentTrackID == track.id
        if removingCurrentTrack { stopCurrentPlayback() }

        let activeRemoteID = track.remoteID.flatMap { remoteID in
            track.remoteIdentity == activeRemoteIdentity(songID: remoteID) ? remoteID : nil
        }
        let conclusivelyMissingRemoteID = activeRemoteID.flatMap { remoteID in
            remoteCatalogIsAuthoritative && !remoteSongs.contains(where: { $0.id == remoteID })
                ? remoteID
                : nil
        }
        var changedRemotePlaylistMembership = false
        for index in playlists.indices where playlists[index].trackIDs.contains(track.id) {
            if playlists[index].isSystem {
                playlists[index].trackIDs.removeAll { $0 == track.id }
                continue
            }

            var seenRemoteSongIDs = Set<String>()
            let oldRemoteSongIDs = (playlists[index].remoteSongIDs ?? []).filter { remoteID in
                !remoteID.isEmpty && seenRemoteSongIDs.insert(remoteID).inserted
            }
            var nextRemoteSongIDs = oldRemoteSongIDs
            var entryIDs: [PlaylistPresentationEntryID]
            if let storedEntryOrder = playlists[index].entryOrder {
                var seenEntryIDs = Set<PlaylistPresentationEntryID>()
                entryIDs = storedEntryOrder.compactMap(PlaylistPresentationEntryID.init(storageKey:))
                    .filter { seenEntryIDs.insert($0).inserted }
            } else {
                entryIDs = playlistEntries(in: playlists[index]).map(\.id)
            }

            let localEntryID = PlaylistPresentationEntryID.local(track.id)
            if let remoteID = activeRemoteID {
                let remoteEntryID = PlaylistPresentationEntryID.remote(remoteID)
                let hasCanonicalMembership = nextRemoteSongIDs.contains(remoteID)
                let catalogConfirmsMembership = remoteCatalogIsAuthoritative
                    && remoteSongs.contains { $0.id == remoteID }
                if conclusivelyMissingRemoteID == remoteID {
                    entryIDs.removeAll { $0 == localEntryID || $0 == remoteEntryID }
                    nextRemoteSongIDs.removeAll { $0 == remoteID }
                } else if hasCanonicalMembership || catalogConfirmsMembership {
                    entryIDs = entryIDs.map { $0 == localEntryID ? remoteEntryID : $0 }
                    if !hasCanonicalMembership {
                        nextRemoteSongIDs.append(remoteID)
                    }
                } else {
                    entryIDs.removeAll { $0 == localEntryID }
                }
            } else {
                entryIDs.removeAll { $0 == localEntryID }
            }

            var seenEntryIDs = Set<PlaylistPresentationEntryID>()
            entryIDs = entryIDs.filter { seenEntryIDs.insert($0).inserted }
            playlists[index].trackIDs.removeAll { $0 == track.id }
            playlists[index].remoteSongIDs = nextRemoteSongIDs
            playlists[index].entryOrder = entryIDs.map(\.storageKey)
            if nextRemoteSongIDs != oldRemoteSongIDs {
                markPlaylistDirty(playlists[index].id)
                changedRemotePlaylistMembership = true
            }
        }

        tracks.removeAll { $0.id == track.id }
        favorites.remove(track.id)
        historyTrackIDs.removeAll { $0 == track.id }
        shuffledTrackIDs.removeAll { $0 == track.id }
        playbackContextTrackIDs.removeAll { $0 == track.id }

        if removingCurrentTrack {
            currentTrackID = playbackContextTrackIDs.first(where: { candidateID in
                tracks.contains { $0.id == candidateID }
            }) ?? tracks.first?.id
            if let currentTrackID {
                if !playbackContextTrackIDs.contains(currentTrackID) {
                    playbackContextTrackIDs = tracks.map(\.id)
                }
                shuffledTrackIDs.removeAll { $0 == currentTrackID }
            }
            position = 0
        }
        persistHistory()
        persistPlaybackContext()
        persistShuffleQueue()
        persistPlaybackPosition()
        persistLibrary()
        if changedRemotePlaylistMembership { schedulePlaylistSync() }
    }

    func revealInFinder(_ track: Track) {
        guard let url = track.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func fileSize(for track: Track) -> Int64 {
        guard let fileURL = track.fileURL else { return 0 }
        return Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    var localLibraryBytes: Int64 {
        tracks.reduce(0) { $0 + fileSize(for: $1) }
    }

    var downloadedTrackCount: Int {
        tracks.filter { $0.remoteID != nil }.count
    }

    @discardableResult
    func deleteDownloadedCopy(_ track: Track) -> Bool {
        guard track.remoteID != nil, let fileURL = track.fileURL else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            fileOperationError = "Couldn’t delete \(track.title): \(error.localizedDescription)"
            return false
        }
        fileOperationError = nil
        removeTrackFromLibrary(track)
        return true
    }

    @discardableResult
    func deleteOriginalFile(_ track: Track) -> Bool {
        guard track.remoteID == nil, let fileURL = track.fileURL else { return false }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            fileOperationError = "Couldn’t delete \(track.title): \(error.localizedDescription)"
            return false
        }
        fileOperationError = nil
        removeTrackFromLibrary(track)
        return true
    }

    func isRemoteSongSynced(_ song: RemoteSong) -> Bool {
        guard let base = try? normalizedServerURL(),
              let identity = ServerSongIdentity(
                serverURL: base,
                profileID: syncProfileID,
                songID: song.id
              ) else { return false }
        return tracks.contains { $0.remoteIdentity == identity }
    }

    func toggleRemoteSelection(_ song: RemoteSong) {
        if selectedRemoteSongIDs.contains(song.id) {
            selectedRemoteSongIDs.remove(song.id)
        } else {
            selectedRemoteSongIDs.insert(song.id)
        }
    }

    func refreshServerCatalog() {
        Task {
            await refreshClientConfigurationNow()
            await refreshServerCatalogNow()
        }
    }

    func repairServerMetadata() {
        guard !serverUploadActionsDisabled, !isSyncingPlaylists else { return }
        uploadTask = Task { await repairServerMetadataNow() }
    }

    private func repairServerMetadataNow() async {
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else {
            serverMessage = ServerSyncError.missingAdminToken.localizedDescription
            return
        }
        isRepairingServerMetadata = true
        uploadCurrentFile = "Server catalog metadata"
        uploadProgress = 0
        uploadStatus = "Repairing server metadata…"
        defer {
            isRepairingServerMetadata = false
            uploadCurrentFile = ""
        }
        do {
            let base = try normalizedServerURL()
            let processed = try await backfillServerMetadataIfAvailable(base: base)
            uploadStatus = processed == 0
                ? "Server metadata is already complete"
                : "Repaired metadata for \(processed) \(processed == 1 ? "song" : "songs")"
            uploadProgress = 1
            serverMessage = uploadStatus
            await refreshServerCatalogNow()
        } catch is CancellationError {
            uploadStatus = "Metadata repair cancelled"
            serverMessage = uploadStatus
        } catch {
            uploadStatus = "Metadata repair failed: \(error.localizedDescription)"
            serverMessage = uploadStatus
        }
    }

    func connectAndSyncServer() {
        refreshServerCatalog()
    }

    func clearServerCredentials() {
        accountSession = nil
        accountRefreshTask?.cancel()
        accountRefreshTask = nil
        Self.deleteAccountSession()
        accountEmail = nil
        accountRole = nil
        accountDisplayName = nil
        accountImageURL = nil
        serverURLString = ""
        serverToken = ""
        serverAdminToken = ""
        remoteSongs.removeAll()
        remoteCatalogIsAuthoritative = false
        selectedRemoteSongIDs.removeAll()
        serverMessage = "Not connected"
        downloadStatus = ""
        uploadStatus = ""
        playlistSyncStatus = ""
        resetClientConfigurationForCurrentContext()
    }

    func signIn(with provider: ResonanceSocialAuthProvider) async {
        guard !isAuthenticatingAccount else { return }
        isAuthenticatingAccount = true
        serverMessage = "Opening \(provider.title) sign-in…"
        defer { isAuthenticatingAccount = false }
        do {
            let client = try ResonanceSocialAuthClient(
                baseURL: ResonanceSocialAuthClient.accountSignInBaseURL,
                session: networkSession
            )
            let session = try await client.signIn(
                with: provider,
                migrationProfileID: syncProfileID
            )
            try await applyAccountSession(session)
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    private func applyAccountSession(_ session: ResonanceAccountSession) async throws {
        migrateConfirmedLegacyProfile(for: session)
        guard !shouldPersistServerCredentials || Self.saveAccountSession(session) else {
            throw ResonanceSocialAuthError.rejected("The account session could not be saved securely.")
        }
        accountSession = session
        accountEmail = session.email
        accountRole = session.role
        accountDisplayName = session.profileDisplayName
        accountImageURL = session.imageURL
        serverURLString = session.baseURL.absoluteString
        serverToken = session.accessToken
        serverAdminToken = session.accessToken
        if let profileID = session.profileID, !profileID.isEmpty {
            activateSyncProfile(SyncProfile(
                id: profileID,
                name: session.profileDisplayName,
                isDefault: true
            ))
        }
        Self.saveServerToken("")
        Self.saveServerToken("", key: Self.adminCredentialKey)
        scheduleAccountRefresh(session)
        serverMessage = "Signed in with Clerk"
        await refreshClientConfigurationNow()
        await refreshServerCatalogNow()
        await syncPlaylistsNow()
    }

    func signOutAccount() async {
        let active = accountSession
        clearServerCredentials()
        if let active, let client = try? ResonanceSocialAuthClient(baseURL: active.baseURL, session: networkSession) {
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
            let client = try ResonanceSocialAuthClient(baseURL: current.baseURL, session: networkSession)
            let refreshed = try await client.refresh(current, migrationProfileID: syncProfileID)
            guard accountSession == current else { return }
            migrateConfirmedLegacyProfile(for: refreshed)
            guard !shouldPersistServerCredentials || Self.saveAccountSession(refreshed) else {
                throw ResonanceSocialAuthError.rejected("The refreshed account session could not be saved securely.")
            }
            accountSession = refreshed
            accountEmail = refreshed.email
            accountRole = refreshed.role
            accountDisplayName = refreshed.profileDisplayName
            accountImageURL = refreshed.imageURL
            serverURLString = refreshed.baseURL.absoluteString
            serverToken = refreshed.accessToken
            serverAdminToken = refreshed.accessToken
            if let profileID = refreshed.profileID, !profileID.isEmpty {
                activateSyncProfile(SyncProfile(
                    id: profileID,
                    name: refreshed.profileDisplayName,
                    isDefault: true
                ))
            }
            await refreshClientConfigurationNow()
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
              let currentBase = try? normalizedServerURL(),
              ServerSongIdentity.normalizedOrigin(currentBase)
                == ServerSongIdentity.normalizedOrigin(session.baseURL),
              let origin = ServerSongIdentity.normalizedOrigin(session.baseURL) else { return }

        let oldClipPrefix = "origin=\(origin)|profile=\(migratedProfileID)|remote:"
        let newClipPrefix = "origin=\(origin)|profile=\(accountProfileID)|remote:"
        func migratedClipKey(_ key: String) -> String {
            guard key.hasPrefix(oldClipPrefix) else { return key }
            return newClipPrefix + key.dropFirst(oldClipPrefix.count)
        }

        for index in tracks.indices
        where tracks[index].remoteID != nil
            && (tracks[index].syncProfileID ?? "default") == migratedProfileID
            && ServerSongIdentity.normalizedOrigin(tracks[index].sourceServer) == origin {
            tracks[index].syncProfileID = accountProfileID
        }
        for index in listeningHistoryEntries.indices
        where (listeningHistoryEntries[index].syncProfileID ?? "default") == migratedProfileID
            && ServerSongIdentity.normalizedOrigin(listeningHistoryEntries[index].serverOrigin) == origin {
            listeningHistoryEntries[index].syncProfileID = accountProfileID
        }
        clipRanges = clipRanges.reduce(into: [:]) { result, pair in
            result[migratedClipKey(pair.key)] = pair.value
        }
        dirtyClipRangeKeys = Set(dirtyClipRangeKeys.map(migratedClipKey))
        deletedClipRangeKeys = Set(deletedClipRangeKeys.map(migratedClipKey))

        let oldServerKey = Self.serverContextKey(base: session.baseURL, profileID: migratedProfileID)
        if playlistSyncServerURL == oldServerKey {
            playlistSyncServerURL = Self.serverContextKey(base: session.baseURL, profileID: accountProfileID)
        }
        let oldTransferScope = MacClientConfigContext.transferModeScope(
            origin: origin,
            profileID: migratedProfileID
        )
        let newTransferScope = MacClientConfigContext.transferModeScope(
            origin: origin,
            profileID: accountProfileID
        )
        for prefix in [Self.uploadModeKeyPrefix, Self.downloadModeKeyPrefix]
        where defaults.object(forKey: prefix + newTransferScope) == nil {
            defaults.set(defaults.object(forKey: prefix + oldTransferScope), forKey: prefix + newTransferScope)
        }
        cancelRemoteSongMetadataHydration()
        serverCatalogRequestGeneration &+= 1
        serverCatalogUploadMutations.removeAll()
        remoteSongs.removeAll()
        remoteCatalogIsAuthoritative = false
        selectedRemoteSongIDs.removeAll()
        syncProfileID = accountProfileID
        activeSyncProfileName = session.profileDisplayName
        persistListeningHistory()
        persistLibrary()
    }

    func selectUploadMode(_ mode: MacUploadMode) {
        guard clientConfiguration.permittedUploadModes.contains(mode) else {
            uploadMode = clientConfiguration.resolvedUploadMode(uploadMode)
            clientConfigMessage = "\(mode.title) is disabled by the verified server configuration"
            return
        }
        uploadMode = mode
        persistTransferModesForCurrentContext()
    }

    func selectDownloadMode(_ mode: MacDownloadMode) {
        guard clientConfiguration.permittedDownloadModes.contains(mode) else {
            downloadMode = clientConfiguration.resolvedDownloadMode(downloadMode)
            clientConfigMessage = "\(mode.title) is disabled by the verified server configuration"
            return
        }
        downloadMode = mode
        persistTransferModesForCurrentContext()
    }

    func refreshClientConfigurationNow() async {
        clientConfigRequestGeneration &+= 1
        let requestGeneration = clientConfigRequestGeneration
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = accessToken.isEmpty ? adminToken : accessToken
        guard !token.isEmpty, let base = try? normalizedServerURL() else {
            resetClientConfigurationForCurrentContext()
            return
        }
        let context = clientConfigContext(base: base, accessToken: token)
        var request = URLRequest(url: base.appendingPathComponent("api/v1/client-config"))
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        setProfileHeader(on: &request, profileID: context.profileID)
        applyClientConfigContextHeaders(to: &request, context: context)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: (Data, HTTPURLResponse)
        do {
            result = try await boundedResponseData(for: request, limit: 128 * 1_024)
        } catch is CancellationError {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                context: context,
                token: token
            ) else { return }
            applyCachedClientConfiguration(context: context, accessToken: token)
            return
        } catch is MacBoundedResponseError {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                context: context,
                token: token
            ) else { return }
            rejectClientConfiguration(context: context)
            return
        } catch {
            guard isCurrentClientConfigRequest(
                generation: requestGeneration,
                context: context,
                token: token
            ) else { return }
            applyCachedClientConfiguration(context: context, accessToken: token)
            return
        }

        guard isCurrentClientConfigRequest(
            generation: requestGeneration,
            context: context,
            token: token
        ) else { return }
        let (body, response) = result
        guard response.url.map({ Self.sameOrigin($0, base) }) == true else {
            rejectClientConfiguration(context: context)
            return
        }
        if response.statusCode == 404 || response.statusCode == 405 {
            defaults.removeObject(forKey: context.cacheKey)
            applyClientConfiguration(.init(document: nil, source: .legacyServer))
            return
        }
        if (500...599).contains(response.statusCode) {
            applyCachedClientConfiguration(context: context, accessToken: token)
            return
        }
        guard response.statusCode == 200,
              Self.isJSONResponse(response) else {
            rejectClientConfiguration(context: context)
            return
        }
        let contentDigest = response.value(forHTTPHeaderField: "Content-Digest")
        let signature = response.value(forHTTPHeaderField: "X-Resonance-Config-Signature")
        guard let document = try? MacClientConfigVerifier.verify(
            body: body,
            contentDigest: contentDigest,
            signature: signature,
            context: context,
            accessToken: token
        ), let contentDigest, let signature else {
            rejectClientConfiguration(context: context)
            return
        }
        let highestVerifiedRevision = defaults.integer(forKey: context.highestRevisionKey)
        guard document.revision >= highestVerifiedRevision else {
            rejectClientConfiguration(context: context)
            clientConfigMessage = "Safe defaults • signed configuration revision rolled back"
            return
        }
        defaults.set(max(highestVerifiedRevision, document.revision), forKey: context.highestRevisionKey)
        let cached = MacCachedClientConfig(
            body: body,
            contentDigest: contentDigest,
            signature: signature,
            context: context,
            cachedAt: .now
        )
        if let encoded = try? JSONEncoder().encode(cached) {
            defaults.set(encoded, forKey: context.cacheKey)
        }
        applyClientConfiguration(.init(document: document, source: .verifiedServer))
    }

    func downloadSelectedServerSongs() {
        guard clientConfiguration.allowsOfflineDownload else {
            downloadStatus = offlineDownloadUnavailableMessage
            return
        }
        guard !selectedRemoteSongIDs.isEmpty else {
            downloadStatus = "Select one or more songs first"
            return
        }
        let selection = selectedRemoteSongIDs
        downloadTask = Task { await syncServerLibrary(songIDs: selection, reconcile: false) }
    }

    func downloadServerSong(_ song: RemoteSong) {
        guard !isSyncingServer, clientConfiguration.allowsOfflineDownload else {
            if !clientConfiguration.allowsOfflineDownload {
                downloadStatus = offlineDownloadUnavailableMessage
            }
            return
        }
        downloadTask = Task { await syncServerLibrary(songIDs: [song.id], reconcile: false) }
    }

    func startListenAlongHost() async {
        listenAlongError = nil
        guard let controller = listenAlongController,
              !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let base = try? normalizedServerURL() else {
            listenAlongError = MacListenAlongError.invalidContext.localizedDescription
            return
        }
        guard let track = currentTrack,
              let sourceURL = listenAlongSourceURL(for: track) else {
            listenAlongError = MacListenAlongError.invalidSource.localizedDescription
            listenAlongStatus = "Choose a song with a supported source link first"
            return
        }
        let mediaKind: MacListenAlongMediaKind = track.kind == .video ? .video : .audio
        listenAlongStatus = "Starting Listen Along…"
        do {
            _ = try await controller.startHost(
                baseURL: base,
                sourceURL: sourceURL,
                mediaKind: mediaKind,
                positionSeconds: position,
                isPlaying: isPlaying
            )
        } catch {
            listenAlongError = error.localizedDescription
            listenAlongStatus = "Not connected"
        }
    }

    func joinListenAlong(code: String) async {
        listenAlongError = nil
        guard let controller = listenAlongController,
              !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let base = try? normalizedServerURL() else {
            listenAlongError = MacListenAlongError.invalidContext.localizedDescription
            return
        }
        listenAlongStatus = "Joining Listen Along…"
        do {
            _ = try await controller.joinGuest(baseURL: base, code: code)
        } catch {
            listenAlongError = error.localizedDescription
            listenAlongStatus = "Not connected"
        }
    }

    func leaveListenAlong() async {
        listenAlongError = nil
        guard let controller = listenAlongController else { return }
        if listenAlongRole == .host {
            await controller.endHost()
        } else {
            controller.leaveGuest()
        }
    }

    private func listenAlongSourceURL(for track: Track?) -> String? {
        if let source = track?.sourceURL,
           let canonical = MacListenAlongSourcePolicy.canonical(source) {
            return canonical
        }
        if let remoteID = remoteStreamSongID,
           let source = remoteSongs.first(where: { $0.id == remoteID })?.sourceURL {
            return MacListenAlongSourcePolicy.canonical(source)
        }
        return nil
    }

    private func publishListenAlongHostState() {
        guard listenAlongRole == .host,
              let controller = listenAlongController,
              let track = currentTrack else { return }
        guard let sourceURL = listenAlongSourceURL(for: track) else {
            listenAlongError = MacListenAlongError.invalidSource.localizedDescription
            listenAlongStatus = "Ending Listen Along…"
            listenAlongOperationTask?.cancel()
            listenAlongOperationTask = Task { @MainActor [weak self] in
                await controller.endHost()
                guard let self, self.listenAlongRole == .host else { return }
                self.listenAlongSessionEnded(
                    "Listen Along ended: the selected song has no source link"
                )
            }
            return
        }
        controller.enqueueHostUpdate(
            sourceURL: sourceURL,
            mediaKind: track.kind == .video ? .video : .audio,
            positionSeconds: position,
            isPlaying: isPlaying
        )
    }

    private func receiveListenAlongSnapshot(
        _ snapshot: MacListenAlongSnapshot,
        role: MacListenAlongRole
    ) {
        listenAlongRole = role
        listenAlongCode = snapshot.code
        listenAlongError = nil
        listenAlongStatus = role == .host
            ? "Hosting \(snapshot.code)"
            : "Following \(snapshot.code)"
        guard role == .guest else { return }
        applyListenAlongGuestSnapshot(snapshot)
    }

    private func listenAlongSessionEnded(_ message: String) {
        let wasGuest = listenAlongRole == .guest
        let existingError = listenAlongError
        listenAlongRole = nil
        listenAlongCode = nil
        listenAlongActiveSourceURL = nil
        listenAlongStatus = message
        if existingError == nil {
            listenAlongError = nil
        }
        listenAlongOperationTask = nil
        listenAlongPlaybackTask?.cancel()
        listenAlongPlaybackTask = nil
        listenAlongPlaybackGeneration &+= 1
        if wasGuest {
            stopCurrentPlayback()
            currentTrackID = tracks.first?.id
            playbackDuration = currentTrack?.duration ?? 0
            position = 0
            publishSystemPlayback()
        }
    }

    private func terminateListenAlongForContextChange(_ message: String) {
        guard listenAlongRole != nil else { return }
        listenAlongController?.resetLocalState()
        listenAlongSessionEnded(message)
    }

    private func applyListenAlongGuestSnapshot(_ snapshot: MacListenAlongSnapshot) {
        guard let sourceURL = snapshot.sourceURL.flatMap(MacListenAlongSourcePolicy.canonical) else {
            listenAlongError = MacListenAlongError.invalidSource.localizedDescription
            listenAlongStatus = "Host has no supported source link"
            return
        }
        let desiredPosition = MacListenAlongPositionProjection.position(for: snapshot)
        let sourceChanged = listenAlongActiveSourceURL != sourceURL
            || currentTrack == nil
            || listenAlongSourceURL(for: currentTrack) != sourceURL
        if sourceChanged {
            listenAlongActiveSourceURL = sourceURL
            listenAlongPlaybackGeneration &+= 1
            let generation = listenAlongPlaybackGeneration
            listenAlongPlaybackTask?.cancel()
            listenAlongPlaybackTask = Task { @MainActor [weak self] in
                await self?.prepareListenAlongGuestSource(
                    sourceURL: sourceURL,
                    mediaKind: snapshot.mediaKind,
                    position: desiredPosition,
                    isPlaying: snapshot.isPlaying,
                    generation: generation
                )
            }
            return
        }
        synchronizeListenAlongPlayback(
            position: desiredPosition,
            isPlaying: snapshot.isPlaying
        )
    }

    private func prepareListenAlongGuestSource(
        sourceURL: String,
        mediaKind: MacListenAlongMediaKind,
        position desiredPosition: TimeInterval,
        isPlaying desiredPlaying: Bool,
        generation: UInt64
    ) async {
        guard generation == listenAlongPlaybackGeneration,
              listenAlongRole == .guest else { return }
        if let local = tracks.first(where: {
            listenAlongSourceURL(for: $0) == sourceURL
                && $0.fileURL != nil
        }) {
            loadListenAlongLocalTrack(
                local,
                position: desiredPosition,
                isPlaying: desiredPlaying,
                generation: generation
            )
            return
        }
        let remote = remoteSongs.first(where: {
            MacListenAlongSourcePolicy.canonical($0.sourceURL) == sourceURL
        })
        if let remote,
           MacListenAlongPlaybackPolicy.shouldUseServerStream(
               hasCatalogMatch: true,
               streamOnlyEnabled: clientConfiguration.allowsStreamOnlyPlayback,
               hasPlayableServerBytes: MacRemoteStreamMediaPolicy.unavailableMessage(
                   kind: remote.kind,
                   size: remote.size
               ) == nil
           ) {
            startRemoteSong(
                remote,
                preservingShuffleQueue: true,
                recordingHistory: false,
                listenAlongPosition: desiredPosition,
                listenAlongIsPlaying: desiredPlaying,
                listenAlongGeneration: generation
            )
            return
        }
        // The server catalog is metadata here, not a download requirement.
        // Resolve the host's stable source into a short-lived provider stream
        // whenever there is no local file or usable server stream.
        do {
            let mode: LocalImportMediaMode = mediaKind == .video ? .video : .audio
            let resolution = try await serverLinkImportService.resolve(
                source: sourceURL,
                mediaMode: mode,
                serverConfiguration: nil
            ) { _ in }
            guard let candidate = resolution.candidates.first else {
                throw LocalImportError(
                    stage: .inspectingSource,
                    code: "LISTEN_ALONG_NO_PREVIEW",
                    message: "This source did not provide a playable preview on this Mac."
                )
            }
            let preview = try await serverLinkImportService.previewStream(
                for: candidate,
                mediaMode: mode
            )
            guard generation == listenAlongPlaybackGeneration,
                  listenAlongRole == .guest else { return }
            let track = Track(
                title: resolution.track.title,
                artist: resolution.track.artist,
                album: resolution.track.album ?? "Listen Along",
                duration: resolution.track.durationSeconds.map(Double.init) ?? 0,
                kind: mode == .video ? .video : .audio,
                artwork: .midnight,
                artworkURL: resolution.track.artworkURL ?? candidate.thumbnailURL,
                sourceURL: sourceURL
            )
            startDirectListenAlongStream(
                track: track,
                preview: preview,
                position: desiredPosition,
                isPlaying: desiredPlaying,
                generation: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == listenAlongPlaybackGeneration else { return }
            listenAlongError = error.localizedDescription
            listenAlongStatus = "Unable to resolve host song"
        }
    }

    private func loadListenAlongLocalTrack(
        _ track: Track,
        position desiredPosition: TimeInterval,
        isPlaying desiredPlaying: Bool,
        generation: UInt64
    ) {
        guard generation == listenAlongPlaybackGeneration,
              listenAlongRole == .guest,
              let fileURL = track.fileURL,
              let player = try? AVAudioPlayer(contentsOf: fileURL) else {
            listenAlongError = "The matching local song is unavailable on this Mac"
            return
        }
        stopCurrentPlayback()
        currentTrackID = track.id
        remoteStreamTrack = nil
        remoteStreamDirectURL = nil
        remoteStreamDirectHeaders = [:]
        loadedAudioTrackID = track.id
        player.delegate = self
        player.volume = PlaybackVolumePolicy.gain(for: volume)
        player.enableRate = true
        player.rate = playbackRate
        player.prepareToPlay()
        audioPlayer = player
        synchronizePlaybackDuration(for: track, playerDuration: player.duration)
        let bounds = playbackBounds(for: track, duration: playbackDuration)
        position = desiredPosition.clamped(to: bounds.start...bounds.end)
        player.currentTime = position
        isPlaying = desiredPlaying && player.play()
        if isPlaying {
            beginListeningSession(for: track)
            startPlaybackTimer()
        } else {
            stopPlaybackTimer()
        }
        publishSystemPlayback()
    }

    private func synchronizeListenAlongPlayback(
        position desiredPosition: TimeInterval,
        isPlaying desiredPlaying: Bool
    ) {
        guard let track = currentTrack else { return }
        let bounds = playbackBounds(for: track, duration: playbackDuration)
        let safePosition = desiredPosition.clamped(to: bounds.start...bounds.end)
        if abs(position - safePosition) > 0.75 {
            applyListenAlongPosition(safePosition)
        }
        if desiredPlaying != isPlaying {
            if desiredPlaying {
                resumeListenAlongPlayback()
            } else {
                pausePlayback(allowListenAlongGuest: true)
            }
        }
    }

    private func applyListenAlongPosition(_ desiredPosition: TimeInterval) {
        position = desiredPosition
        if loadedAudioTrackID == currentTrackID {
            audioPlayer?.currentTime = desiredPosition
        }
        if remoteStreamTrack?.id == currentTrackID {
            remoteStreamPlayer?.seek(
                to: CMTime(seconds: desiredPosition, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        playbackDiscontinuities.send(desiredPosition)
        publishSystemPlayback()
    }

    private func resumeListenAlongPlayback() {
        guard let track = currentTrack else { return }
        if remoteStreamTrack?.id == track.id, let remoteStreamPlayer {
            remoteStreamPlayer.playImmediately(atRate: playbackRate)
        } else if loadedAudioTrackID == track.id {
            _ = audioPlayer?.play()
        }
        isPlaying = true
        beginListeningSession(for: track)
        startPlaybackTimer()
        publishSystemPlayback()
    }

    func playRemoteSong(_ song: RemoteSong) {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can change the song"
            return
        }
        startRemoteSong(song, preservingShuffleQueue: false, recordingHistory: true)
        publishListenAlongHostState()
    }

    private func startRemoteSong(
        _ song: RemoteSong,
        preservingShuffleQueue: Bool,
        recordingHistory: Bool,
        listenAlongPosition: TimeInterval? = nil,
        listenAlongIsPlaying: Bool? = nil,
        listenAlongGeneration: UInt64? = nil
    ) {
        guard clientConfiguration.allowsStreamOnlyPlayback else {
            downloadStatus = offlineDownloadUnavailableMessage
            serverMessage = downloadStatus
            return
        }
        if let message = MacRemoteStreamMediaPolicy.unavailableMessage(kind: song.kind, size: song.size) {
            downloadStatus = message
            serverMessage = message
            return
        }
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty,
              remoteSongs.contains(where: { $0.id == song.id }),
              let base = try? normalizedServerURL(),
              let streamURL = try? remoteURL(song.streamURL, relativeTo: base),
              let signedDocument = clientConfiguration.document,
              let streamExpiration = MacClientConfigVerifier.expirationDate(signedDocument) else {
            serverMessage = ServerSyncError.invalidResponse.localizedDescription
            return
        }

        let departingSongID = remoteStreamSongID
        if shuffleEnabled {
            if !preservingShuffleQueue {
                rebuildRemoteShuffleOrder(excluding: song.id)
                remoteHistorySongIDs.removeAll()
            }
            if recordingHistory,
               let departingSongID,
               departingSongID != song.id {
                remoteHistorySongIDs.append(departingSongID)
                if remoteHistorySongIDs.count > 100 {
                    remoteHistorySongIDs.removeFirst(remoteHistorySongIDs.count - 100)
                }
            }
        } else {
            remoteShuffledSongIDs.removeAll()
            remoteHistorySongIDs.removeAll()
        }

        let streamContext = clientConfigContext(base: base, accessToken: token)
        let authorizationLease: MacAuthenticatedStreamAuthorizationLease
        do {
            authorizationLease = try MacAuthenticatedStreamAuthorizationLease(
                context: streamContext,
                expiresAt: streamExpiration
            )
        } catch {
            serverMessage = "Stream unavailable: \(error.localizedDescription)"
            return
        }

        stopCurrentPlayback(preservingRemoteNavigation: true)
        let artworkIndex = song.id.utf8.reduce(0) { (value, byte) in
            (value &* 31 &+ Int(byte)) % ArtworkStyle.allCases.count
        }
        let track = Track(
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.durationSeconds ?? 0,
            kind: song.kind,
            artwork: ArtworkStyle.allCases[artworkIndex],
            artworkURL: song.artworkURL,
            remoteID: song.id,
            sourceServer: ServerSongIdentity.normalizedOrigin(base),
            syncProfileID: syncProfileID,
            sourceURL: song.sourceURL
        )
        remoteStreamTrack = track
        remoteStreamSongID = song.id
        remoteStreamAuthorizationLease = authorizationLease
        currentTrackID = track.id
        position = playbackBounds(for: track).start
        playbackDuration = max(track.duration, 0)
        let generation = remoteStreamLoadGeneration
        let profileID = syncProfileID
        let origin = ServerSongIdentity.normalizedOrigin(base)
        var authenticated = authenticatedRequest(url: streamURL, profileID: profileID)
        authenticated.setValue("audio/*,video/*;q=0.9,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let headers = authenticated.allHTTPHeaderFields ?? [:]
        serverMessage = "Preparing stream • \(song.title)"
        remoteStreamPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await prepareRemoteStream(
                song: song,
                track: track,
                sourceURL: streamURL,
                headers: headers,
                expectedToken: token,
                expectedOrigin: origin,
                expectedProfileID: profileID,
                authorizationLease: authorizationLease,
                generation: generation,
                listenAlongPosition: listenAlongPosition,
                listenAlongIsPlaying: listenAlongIsPlaying,
                listenAlongGeneration: listenAlongGeneration
            )
        }
    }

    private func prepareRemoteStream(
        song: RemoteSong,
        track: Track,
        sourceURL: URL,
        headers: [String: String],
        expectedToken: String,
        expectedOrigin: String?,
        expectedProfileID: String,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        generation: UInt64,
        listenAlongPosition: TimeInterval? = nil,
        listenAlongIsPlaying: Bool? = nil,
        listenAlongGeneration: UInt64? = nil
    ) async {
        do {
            let loader = MacAuthenticatedStreamResourceLoader(
                sourceURL: sourceURL,
                headers: headers,
                expectedContentLength: song.size,
                authorizationLease: authorizationLease,
                onAuthorizationInvalidated: { [weak self, weak authorizationLease] in
                    Task { @MainActor [weak self, weak authorizationLease] in
                        guard let self, let authorizationLease else { return }
                        self.remoteStreamAuthorizationDidExpire(
                            lease: authorizationLease,
                            generation: generation
                        )
                    }
                }
            )
            let assetURL = try MacAuthenticatedStreamPolicy.assetURL(for: sourceURL)
            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            remoteStreamLoader = loader
            guard try await asset.load(.isPlayable) else {
                throw MacAuthenticatedStreamError.invalidResponse
            }
            let measuredDuration = try? await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard generation == remoteStreamLoadGeneration,
                  remoteStreamTrack?.id == track.id,
                  remoteStreamSongID == song.id,
                  remoteStreamAuthorizationLease === authorizationLease,
                  clientConfiguration.allowsStreamOnlyPlayback,
                  serverToken.trimmingCharacters(in: .whitespacesAndNewlines) == expectedToken,
                  syncProfileID == expectedProfileID,
                  let currentBase = try? normalizedServerURL(),
                  ServerSongIdentity.normalizedOrigin(currentBase) == expectedOrigin,
                  listenAlongGeneration == nil
                    || (listenAlongRole == .guest
                        && listenAlongPlaybackGeneration == listenAlongGeneration) else { return }

            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.volume = PlaybackVolumePolicy.gain(for: volume)
            player.defaultRate = playbackRate
            player.automaticallyWaitsToMinimizeStalling = true
            remoteStreamPlayer = player
            if let measuredDuration,
               measuredDuration.isFinite,
               measuredDuration > 0 {
                playbackDuration = measuredDuration
                remoteStreamTrack?.duration = measuredDuration
            }
            remoteStreamEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.remoteStreamDidFinish(item: item, generation: generation)
                }
            }
            remoteStreamFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.remoteStreamDidFail(item: item, generation: generation, error: error)
                }
            }
            remoteStreamStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, item.status == .failed else { return }
                    self.remoteStreamDidFail(item: item, generation: generation, error: item.error)
                }
            }
            remoteStreamPreparationTask = nil
            let bounds = playbackBounds(for: track, duration: playbackDuration)
            if let listenAlongPosition {
                position = listenAlongPosition.clamped(to: bounds.start...bounds.end)
            }
            position = min(max(position, bounds.start), bounds.end)
            await player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            let shouldPlay = listenAlongIsPlaying ?? true
            if shouldPlay {
                player.playImmediately(atRate: playbackRate)
                isPlaying = true
                beginListeningSession(for: track)
                startPlaybackTimer()
            } else {
                player.pause()
                isPlaying = false
                stopPlaybackTimer()
            }
            serverMessage = listenAlongGeneration == nil
                ? "Streaming • \(song.title)"
                : "Following host • \(song.title)"
            publishSystemPlayback()
        } catch is CancellationError {
            return
        } catch {
            guard generation == remoteStreamLoadGeneration else { return }
            remoteStreamPreparationTask = nil
            if let remoteStreamEndObserver {
                NotificationCenter.default.removeObserver(remoteStreamEndObserver)
                self.remoteStreamEndObserver = nil
            }
            if let remoteStreamFailureObserver {
                NotificationCenter.default.removeObserver(remoteStreamFailureObserver)
                self.remoteStreamFailureObserver = nil
            }
            remoteStreamStatusObservation?.invalidate()
            remoteStreamStatusObservation = nil
            remoteStreamPlayer?.pause()
            remoteStreamPlayer = nil
            remoteStreamLoader?.invalidate()
            remoteStreamLoader = nil
            remoteYouTubeStreamLoader?.invalidate()
            remoteYouTubeStreamLoader = nil
            remoteStreamAuthorizationLease?.invalidate()
            remoteStreamAuthorizationLease = nil
            remoteStreamSongID = nil
            remoteStreamTrack = nil
            if currentTrackID == track.id {
                currentTrackID = tracks.first?.id
                playbackDuration = currentTrack?.duration ?? 0
                position = 0
            }
            isPlaying = false
            stopPlaybackTimer()
            serverMessage = "Stream failed: \(error.localizedDescription)"
            publishSystemPlayback()
        }
    }

    private func startDirectListenAlongStream(
        track: Track,
        preview: LocalImportPreviewStream,
        position desiredPosition: TimeInterval,
        isPlaying desiredPlaying: Bool,
        generation: UInt64
    ) {
        guard listenAlongRole == .guest,
              generation == listenAlongPlaybackGeneration,
              let components = URLComponents(
                url: preview.url,
                resolvingAgainstBaseURL: false
              ),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.isEmpty == false else {
            listenAlongError = "The host source returned an unsafe preview URL"
            return
        }
        stopCurrentPlayback()
        remoteStreamTrack = track
        remoteStreamSongID = nil
        remoteStreamDirectURL = preview.url
        remoteStreamDirectHeaders = preview.httpHeaders.filter {
            $0.key.caseInsensitiveCompare("Authorization") != .orderedSame
        }
        currentTrackID = track.id
        position = max(desiredPosition, 0)
        playbackDuration = max(track.duration, 0)
        serverMessage = "Preparing host preview • \(track.title)"
        remoteStreamPreparationTask = Task { @MainActor [weak self] in
            await self?.prepareDirectListenAlongStream(
                track: track,
                sourceURL: preview.url,
                headers: preview.httpHeaders,
                contentLength: preview.contentLength,
                contentType: preview.contentType,
                position: desiredPosition,
                isPlaying: desiredPlaying,
                generation: generation
            )
        }
    }

    private func prepareDirectListenAlongStream(
        track: Track,
        sourceURL: URL,
        headers: [String: String],
        contentLength: Int64?,
        contentType: String?,
        position desiredPosition: TimeInterval,
        isPlaying desiredPlaying: Bool,
        generation: UInt64
    ) async {
        do {
            let asset: AVURLAsset
            if let contentLength, let contentType {
                let loader = try MacYouTubeStreamResourceLoader(
                    sourceURL: sourceURL,
                    headers: headers,
                    contentLength: contentLength,
                    contentType: contentType
                )
                asset = AVURLAsset(url: try MacYouTubeStreamResourceLoader.assetURL(for: sourceURL))
                asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
                remoteYouTubeStreamLoader = loader
            } else {
                asset = AVURLAsset(
                    url: sourceURL,
                    options: [
                        "AVURLAssetHTTPHeaderFieldsKey": headers.filter {
                            $0.key.caseInsensitiveCompare("Authorization") != .orderedSame
                        }
                    ]
                )
            }
            guard try await asset.load(.isPlayable) else {
                throw MacListenAlongError.invalidResponse
            }
            let measuredDuration = try? await asset.load(.duration).seconds
            try Task.checkCancellation()
            guard generation == listenAlongPlaybackGeneration,
                  listenAlongRole == .guest,
                  remoteStreamTrack?.id == track.id,
                  remoteStreamDirectURL == sourceURL else { return }
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.volume = PlaybackVolumePolicy.gain(for: volume)
            player.defaultRate = playbackRate
            player.automaticallyWaitsToMinimizeStalling = true
            remoteStreamPlayer = player
            if let measuredDuration,
               measuredDuration.isFinite,
               measuredDuration > 0 {
                playbackDuration = measuredDuration
                remoteStreamTrack?.duration = measuredDuration
            }
            remoteStreamEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.remoteStreamDidFinish(item: item, generation: self.remoteStreamLoadGeneration)
                }
            }
            remoteStreamFailureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item else { return }
                    self.remoteStreamDidFail(
                        item: item,
                        generation: self.remoteStreamLoadGeneration,
                        error: error
                    )
                }
            }
            remoteStreamStatusObservation = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor [weak self, weak item] in
                    guard let self, let item, item.status == .failed else { return }
                    self.remoteStreamDidFail(
                        item: item,
                        generation: self.remoteStreamLoadGeneration,
                        error: item.error
                    )
                }
            }
            remoteStreamPreparationTask = nil
            let bounds = playbackBounds(for: track, duration: playbackDuration)
            position = desiredPosition.clamped(to: bounds.start...bounds.end)
            await player.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if desiredPlaying {
                player.playImmediately(atRate: playbackRate)
                isPlaying = true
                beginListeningSession(for: track)
                startPlaybackTimer()
            } else {
                player.pause()
                isPlaying = false
                stopPlaybackTimer()
            }
            serverMessage = "Following host • \(track.title)"
            publishSystemPlayback()
        } catch is CancellationError {
            return
        } catch {
            guard generation == listenAlongPlaybackGeneration else { return }
            remoteStreamPreparationTask = nil
            if let remoteStreamEndObserver {
                NotificationCenter.default.removeObserver(remoteStreamEndObserver)
                self.remoteStreamEndObserver = nil
            }
            if let remoteStreamFailureObserver {
                NotificationCenter.default.removeObserver(remoteStreamFailureObserver)
                self.remoteStreamFailureObserver = nil
            }
            remoteStreamStatusObservation?.invalidate()
            remoteStreamStatusObservation = nil
            remoteStreamPlayer?.pause()
            remoteStreamPlayer = nil
            remoteStreamDirectURL = nil
            remoteStreamDirectHeaders = [:]
            remoteStreamTrack = nil
            if currentTrackID == track.id {
                currentTrackID = tracks.first?.id
                playbackDuration = currentTrack?.duration ?? 0
                position = 0
            }
            isPlaying = false
            stopPlaybackTimer()
            listenAlongError = error.localizedDescription
            listenAlongStatus = "Unable to play host preview"
            publishSystemPlayback()
        }
    }

    private func remoteStreamDidFinish(item: AVPlayerItem, generation: UInt64) {
        guard generation == remoteStreamLoadGeneration,
              remoteStreamPlayer?.currentItem === item else { return }
        if listenAlongRole == .guest {
            isPlaying = false
            stopPlaybackTimer()
            publishSystemPlayback()
            return
        }
        finishCurrentPlaybackRange()
    }

    private func remoteStreamDidFail(
        item: AVPlayerItem,
        generation: UInt64,
        error: Error?
    ) {
        guard generation == remoteStreamLoadGeneration,
              remoteStreamPlayer?.currentItem === item else { return }
        failRemoteStream(
            generation: generation,
            error: error ?? MacAuthenticatedStreamError.invalidResponse
        )
    }

    private func remoteStreamAuthorizationDidExpire(
        lease: MacAuthenticatedStreamAuthorizationLease,
        generation: UInt64
    ) {
        guard remoteStreamAuthorizationLease === lease else { return }
        failRemoteStream(generation: generation, error: MacAuthenticatedStreamError.authorizationExpired)
    }

    private func failRemoteStream(generation: UInt64, error: Error) {
        guard generation == remoteStreamLoadGeneration,
              remoteStreamTrack != nil else { return }
        let detail = error.localizedDescription
        stopCurrentPlayback()
        currentTrackID = tracks.first?.id
        playbackDuration = currentTrack?.duration ?? 0
        position = 0
        serverMessage = "Stream failed: \(detail)"
        publishSystemPlayback()
    }

    func downloadAllServerSongs() {
        guard clientConfiguration.allowsOfflineDownload else {
            downloadStatus = offlineDownloadUnavailableMessage
            return
        }
        downloadTask = Task { await syncServerLibrary(songIDs: nil, reconcile: false) }
    }

    func cancelServerDownload() {
        downloadTask?.cancel()
    }

    func cancelServerUpload() {
        uploadTask?.cancel()
    }

    func deleteRemoteSong(_ song: RemoteSong) {
        uploadTask = Task {
            let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !adminToken.isEmpty else {
                serverMessage = ServerSyncError.missingAdminToken.localizedDescription
                return
            }
            do {
                let base = try normalizedServerURL()
                let profileID = syncProfileID
                let songID = try Self.validatedRemoteSongIdentifier(song.id)
                let endpoint = base.appendingPathComponent("api/v1/admin/songs", isDirectory: true)
                var request = URLRequest(url: endpoint.appendingPathComponent(songID, isDirectory: false))
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
                setProfileHeader(on: &request, profileID: profileID)
                let (_, response) = try await networkSession.data(for: request)
                if let http = response as? HTTPURLResponse {
                    invalidateRemoteCatalogAuthorityAfterCommittedMutation(
                        base: base,
                        profileID: profileID,
                        statusCode: http.statusCode
                    )
                }
                try Self.validate(response)
                remoteSongs.removeAll { $0.id == song.id }
                selectedRemoteSongIDs.remove(song.id)
                serverMessage = "Deleted \(song.title) from the server"
            } catch {
                serverMessage = "Server delete failed: \(error.localizedDescription)"
            }
        }
    }

    func chooseSongsToUpload() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshClientConfigurationNow()
            guard clientConfiguration.permittedUploadModes.contains(uploadMode) else {
                uploadStatus = "\(uploadMode.title) is disabled by the verified server configuration"
                return
            }
            serverMessage = uploadMode == .reviewedMatch
                ? "Choose and review a match in Import from Web"
                : "Download a song in Import from Web to register its preserved direct source"
            NotificationCenter.default.post(name: .importMusicFromLink, object: nil)
        }
    }

    func uploadMissingDownloadedSongs() {
        guard !localFileUploadActionsDisabled else {
            if !clientConfiguration.allowsLocalFileUpload {
                uploadStatus = "Preserved source-link uploads are disabled by the verified server configuration"
            }
            return
        }
        uploadTask = Task { await uploadDownloadedSongsMissingFromServer() }
    }

    func refreshServerCatalogNow() async {
        guard !isSyncingServer else { return }
        serverDownloadStateGeneration &+= 1
        isSyncingServer = true
        isRefreshingServerCatalog = true
        defer {
            isRefreshingServerCatalog = false
            isSyncingServer = false
        }
        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let profileID = syncProfileID
            let credentialFingerprint = MacClientConfigContext.tokenFingerprint(serverToken)
            let contextKey = Self.serverContextKey(base: base, profileID: profileID)
            serverCatalogRequestGeneration &+= 1
            let requestGeneration = serverCatalogRequestGeneration
            let uploadGeneration = serverUploadMutationGeneration
            var catalog = try await fetchRemoteCatalog(base: base)
            guard requestGeneration == serverCatalogRequestGeneration,
                  profileID == syncProfileID,
                  credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
                  let currentBase = try? normalizedServerURL(),
                  Self.serverContextKey(base: currentBase, profileID: syncProfileID) == contextKey else {
                return
            }
            for mutation in serverCatalogUploadMutations
            where mutation.generation > uploadGeneration && mutation.contextKey == contextKey {
                catalog = [mutation.song] + catalog.filter { $0.id != mutation.song.id }
            }
            remoteSongs = applyingKnownRemoteSongMetadata(to: catalog)
            remoteCatalogIsAuthoritative = true
            selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
            serverMessage = "Connected • \(remoteSongs.count) \(remoteSongs.count == 1 ? "song" : "songs") available"

            if await repairLegacyRemoteSourceLinks(in: catalog, base: base) {
                catalog = try await fetchRemoteCatalog(base: base)
                guard requestGeneration == serverCatalogRequestGeneration,
                      profileID == syncProfileID,
                      credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
                      let currentBase = try? normalizedServerURL(),
                      Self.serverContextKey(base: currentBase, profileID: syncProfileID) == contextKey else {
                    return
                }
                for mutation in serverCatalogUploadMutations
                where mutation.generation > uploadGeneration && mutation.contextKey == contextKey {
                    catalog = [mutation.song] + catalog.filter { $0.id != mutation.song.id }
                }
                remoteSongs = applyingKnownRemoteSongMetadata(to: catalog)
                remoteCatalogIsAuthoritative = true
                selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
                serverMessage = "Connected • \(remoteSongs.count) \(remoteSongs.count == 1 ? "song" : "songs") available"
            }

            beginRemoteSongMetadataHydration(contextKey: contextKey)
            await reconcileCachedUploadedLocalTracks()
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    private func releaseServerDownloadState(
        generation: UInt64,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease?
    ) {
        authorizationLease?.invalidate()
        if let authorizationLease,
           offlineDownloadAuthorizationLease === authorizationLease {
            offlineDownloadAuthorizationLease = nil
            offlineDownloadRequiresVerifiedConfiguration = false
        }
        guard MacServerDownloadStatePolicy.owns(
            generation: generation,
            currentGeneration: serverDownloadStateGeneration
        ) else { return }
        serverDownloadTransferGeneration &+= 1
        isSyncingServer = false
        isServerDownloadTransferVisible = false
        downloadCurrentFile = ""
        downloadBatchPosition = 0
        downloadBatchTotal = 0
    }

    private func beginServerDownloadTransfer(stateGeneration: UInt64) throws -> UInt64 {
        guard MacServerDownloadStatePolicy.owns(
            generation: stateGeneration,
            currentGeneration: serverDownloadStateGeneration
        ) else { throw CancellationError() }
        serverDownloadTransferGeneration &+= 1
        let transferGeneration = serverDownloadTransferGeneration
        downloadProgress = nil
        return transferGeneration
    }

    private func publishServerDownloadTransfer(
        completedBytes: Int64,
        totalBytes: Int64,
        stateGeneration: UInt64,
        transferGeneration: UInt64
    ) {
        guard MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: serverDownloadStateGeneration,
            transferGeneration: transferGeneration,
            currentTransferGeneration: serverDownloadTransferGeneration
        ), MacServerDownloadProgressPolicy.transferHasStarted(
            completedBytes: completedBytes
        ) else { return }
        isServerDownloadTransferVisible = true
        downloadProgress = MacServerDownloadProgressPolicy.presentationFraction(
            completedBytes: completedBytes,
            totalBytes: totalBytes
        )
    }

    private func releaseServerDownloadTransfer(
        stateGeneration: UInt64,
        transferGeneration: UInt64
    ) {
        guard MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: serverDownloadStateGeneration,
            transferGeneration: transferGeneration,
            currentTransferGeneration: serverDownloadTransferGeneration
        ) else { return }
        if !MacServerDownloadProgressPolicy.retainsPopupBetweenItems(
            hasStarted: isServerDownloadTransferVisible,
            position: downloadBatchPosition,
            total: downloadBatchTotal
        ) {
            isServerDownloadTransferVisible = false
        }
        downloadProgress = nil
    }

    nonisolated private static func awaitServerDownloadAuthorizationRefresh(
        _ refresh: Task<Void, Never>?
    ) async throws {
        guard let refresh else {
            try Task.checkCancellation()
            return
        }
        await withTaskCancellationHandler(
            operation: { await refresh.value },
            onCancel: { refresh.cancel() }
        )
        try Task.checkCancellation()
    }

    private struct ValidatedCachedServerSong {
        let destination: URL
        let snapshot: MacServerDownloadFileSnapshot
        let contentSHA256: String
    }

    private struct ServerSongDownloadPlan {
        let requiresDownload: Bool
        let validatedCache: ValidatedCachedServerSong?

        static let download = ServerSongDownloadPlan(
            requiresDownload: true,
            validatedCache: nil
        )
    }

    nonisolated private static func serverDownloadFileSnapshot(
        at url: URL
    ) -> MacServerDownloadFileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modificationDate = attributes[.modificationDate] as? Date,
              let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let systemFileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return MacServerDownloadFileSnapshot(
            size: size,
            modificationDate: modificationDate,
            systemNumber: systemNumber,
            systemFileNumber: systemFileNumber
        )
    }

    private func remoteSourceLinkNeedsDownload(
        _ remote: RemoteSong,
        base: URL,
        profileID: String
    ) -> Bool {
        guard let identity = ServerSongIdentity(
            serverURL: base,
            profileID: profileID,
            songID: remote.id
        ) else { return true }
        return !tracks.contains { track in
            guard track.remoteIdentity == identity,
                  let fileURL = track.fileURL else { return false }
            return FileManager.default.fileExists(atPath: fileURL.path)
        }
    }

    private func serverSongDownloadPlan(
        for remote: RemoteSong,
        base: URL,
        cache: URL,
        profileID: String
    ) async throws -> ServerSongDownloadPlan {
        if remote.isSourceLinkRecord {
            return ServerSongDownloadPlan(
                requiresDownload: remoteSourceLinkNeedsDownload(
                    remote,
                    base: base,
                    profileID: profileID
                ),
                validatedCache: nil
            )
        }

        let maximumDownloadSize: Int64 = remote.kind == .video
            ? 1_024 * 1_024 * 1_024
            : 256 * 1_024 * 1_024
        guard remote.size > 0,
              remote.size <= maximumDownloadSize,
              let destination = try? Self.cachedDestination(for: remote, in: cache),
              let initialSnapshot = Self.serverDownloadFileSnapshot(at: destination),
              initialSnapshot.size == remote.size,
              (try? AVAudioPlayer(contentsOf: destination)) != nil else { return .download }
        do {
            let expectedContentSHA256 = try Self.catalogSHA256(remote.contentSHA256)
            let localHash = try await Self.fileSHA256Detached(at: destination)
            try Task.checkCancellation()
            guard MacServerDownloadValidationPolicy.isReusable(
                validated: initialSnapshot,
                current: Self.serverDownloadFileSnapshot(at: destination)
            ), expectedContentSHA256.map({ $0 == localHash }) ?? true else {
                return .download
            }
            return ServerSongDownloadPlan(
                requiresDownload: false,
                validatedCache: ValidatedCachedServerSong(
                    destination: destination,
                    snapshot: initialSnapshot,
                    contentSHA256: localHash
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .download
        }
    }

    func syncServerLibrary(songIDs: Set<String>? = nil, reconcile _: Bool = false) async {
        guard !isSyncingServer else { return }
        serverDownloadStateGeneration &+= 1
        let stateGeneration = serverDownloadStateGeneration
        isSyncingServer = true
        isServerDownloadTransferVisible = true
        downloadCurrentFile = "Loading song metadata"
        downloadStatus = "Preparing download"
        var authorizationLease: MacAuthenticatedStreamAuthorizationLease?
        var authorizationRefresh: Task<Void, Never>?
        defer {
            releaseServerDownloadState(
                generation: stateGeneration,
                authorizationLease: authorizationLease
            )
        }
        let canStartWithCurrentConfiguration = MacServerDownloadConfigurationPolicy
            .canStartImmediately(with: clientConfiguration)
        if !canStartWithCurrentConfiguration {
            // A cold/expired policy has no active authorization to borrow, so
            // it remains a hidden prerequisite. An exact active policy skips
            // this network wait and is refreshed after its lease is installed.
            await refreshClientConfigurationNow()
        }
        guard MacServerDownloadStatePolicy.owns(
            generation: stateGeneration,
            currentGeneration: serverDownloadStateGeneration
        ) else { return }
        guard clientConfiguration.allowsOfflineDownload else {
            downloadStatus = offlineDownloadUnavailableMessage
            serverMessage = downloadStatus
            return
        }
        downloadProgress = nil
        downloadBatchPosition = 0
        downloadBatchTotal = 0
        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty else { throw ServerSyncError.missingToken }
            let credentialFingerprint = MacClientConfigContext.tokenFingerprint(accessToken)
            let startingConfiguration = clientConfiguration
            let expiration = startingConfiguration.document
                .flatMap(MacClientConfigVerifier.expirationDate)
                ?? .distantFuture
            let lease = try MacAuthenticatedStreamAuthorizationLease(
                context: clientConfigContext(base: base, accessToken: accessToken),
                expiresAt: expiration
            )
            authorizationLease = lease
            offlineDownloadAuthorizationLease = lease
            offlineDownloadRequiresVerifiedConfiguration = startingConfiguration.document != nil
                && (startingConfiguration.source == .verifiedServer || startingConfiguration.source == .verifiedCache)
            if canStartWithCurrentConfiguration {
                authorizationRefresh = Task { @MainActor [weak self] in
                    await self?.refreshClientConfigurationNow()
                }
            }
            let catalogProfileID = syncProfileID
            let fetchedCatalog = if let immediate = MacServerDownloadMetadataPolicy.immediateCatalog(
                knownSongs: remoteSongs,
                catalogIsAuthoritative: remoteCatalogIsAuthoritative
            ) {
                immediate
            } else {
                try await fetchRemoteCatalog(base: base)
            }
            let catalogSongs = applyingKnownRemoteSongMetadata(
                to: applyingCurrentRemoteSongMetadata(to: fetchedCatalog)
            )
            guard catalogProfileID == syncProfileID,
                  credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
                  let currentBase = try? normalizedServerURL(),
                  Self.serverContextKey(base: currentBase, profileID: catalogProfileID)
                    == Self.serverContextKey(base: base, profileID: catalogProfileID) else {
                throw CancellationError()
            }
            remoteSongs = catalogSongs
            remoteCatalogIsAuthoritative = true
            reconcileDownloadedMediaKinds(with: catalogSongs)
            var songs = songIDs.map { ids in catalogSongs.filter { ids.contains($0.id) } } ?? catalogSongs
            songs = await prepareRemoteSongMetadataForDownload(
                songs,
                contextKey: Self.serverContextKey(base: base, profileID: catalogProfileID)
            )
            downloadStatus = songs.isEmpty ? "Nothing to download" : "Preparing download"
            let cache = try serverCacheDirectory(for: base, profileID: syncProfileID)
            var pendingSongIDs = Set<String>()
            var downloadPlans: [ServerSongDownloadPlan] = []
            downloadPlans.reserveCapacity(songs.count)
            for remote in songs {
                try Task.checkCancellation()
                let plan = try await serverSongDownloadPlan(
                    for: remote,
                    base: base,
                    cache: cache,
                    profileID: catalogProfileID
                )
                downloadPlans.append(plan)
                if plan.requiresDownload {
                    pendingSongIDs.insert(remote.id)
                }
            }
            guard catalogProfileID == syncProfileID,
                  credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
                  let currentBase = try? normalizedServerURL(),
                  Self.serverContextKey(base: currentBase, profileID: catalogProfileID)
                    == Self.serverContextKey(base: base, profileID: catalogProfileID) else {
                throw CancellationError()
            }
            downloadBatchTotal = pendingSongIDs.count
            var changedCount = 0
            var failedCount = 0
            var pendingPosition = 0

            for (remote, plan) in zip(songs, downloadPlans) {
                try Task.checkCancellation()
                guard catalogProfileID == syncProfileID,
                      credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
                      let currentBase = try? normalizedServerURL(),
                      Self.serverContextKey(base: currentBase, profileID: catalogProfileID)
                        == Self.serverContextKey(base: base, profileID: catalogProfileID) else {
                    throw CancellationError()
                }
                var isPendingDownload = plan.requiresDownload
                var reusableCachedValidation: ValidatedCachedServerSong?
                var reusableCachedPlayer: AVAudioPlayer?
                if remote.isSourceLinkRecord {
                    isPendingDownload = remoteSourceLinkNeedsDownload(
                        remote,
                        base: base,
                        profileID: catalogProfileID
                    )
                } else if !isPendingDownload,
                          let validation = plan.validatedCache,
                          let plannedDestination = try? Self.cachedDestination(for: remote, in: cache),
                          plannedDestination.standardizedFileURL == validation.destination.standardizedFileURL,
                          MacServerDownloadValidationPolicy.isReusable(
                            validated: validation.snapshot,
                            current: Self.serverDownloadFileSnapshot(at: validation.destination)
                          ),
                          let player = try? AVAudioPlayer(contentsOf: validation.destination) {
                    reusableCachedValidation = validation
                    reusableCachedPlayer = player
                } else if !isPendingDownload {
                    isPendingDownload = true
                }
                if isPendingDownload {
                    pendingSongIDs.insert(remote.id)
                } else {
                    pendingSongIDs.remove(remote.id)
                }
                downloadBatchTotal = pendingSongIDs.count
                if isPendingDownload {
                    pendingPosition += 1
                    downloadBatchPosition = pendingPosition
                    downloadCurrentFile = remote.title
                    downloadStatus = "Downloading \(pendingPosition) of \(pendingSongIDs.count)"
                    downloadProgress = nil
                }
                var stagingURL: URL?
                do {
                    if remote.isSourceLinkRecord {
                        let remoteIdentity = ServerSongIdentity(
                            serverURL: base,
                            profileID: syncProfileID,
                            songID: remote.id
                        )
                        if let existing = tracks.first(where: { $0.remoteIdentity == remoteIdentity }),
                           let fileURL = existing.fileURL,
                           FileManager.default.fileExists(atPath: fileURL.path) {
                            if isPendingDownload { downloadProgress = 1 }
                            continue
                        }
                        let transferGeneration = try beginServerDownloadTransfer(
                            stateGeneration: stateGeneration
                        )
                        defer {
                            releaseServerDownloadTransfer(
                                stateGeneration: stateGeneration,
                                transferGeneration: transferGeneration
                            )
                        }
                        let sourceImportTask: Task<Track, Error> = Task { @MainActor [weak self] in
                            guard let self else { throw CancellationError() }
                            return try await self.importSavedRemoteSource(
                                remote,
                                base: base,
                                profileID: catalogProfileID,
                                authorizationLease: lease,
                                authorizationRefresh: authorizationRefresh,
                                stateGeneration: stateGeneration,
                                transferGeneration: transferGeneration
                            )
                        }
                        lease.setInvalidationHandler { sourceImportTask.cancel() }
                        do {
                            defer { lease.setInvalidationHandler(nil) }
                            _ = try await withTaskCancellationHandler(
                                operation: { try await sourceImportTask.value },
                                onCancel: { sourceImportTask.cancel() }
                            )
                        }
                        changedCount += 1
                        if isPendingDownload { downloadProgress = 1 }
                        continue
                    }
                    let maximumDownloadSize: Int64 = remote.kind == .video
                        ? 1_024 * 1_024 * 1_024
                        : 256 * 1_024 * 1_024
                    guard remote.size > 0, remote.size <= maximumDownloadSize else {
                        throw ServerSyncError.downloadTooLarge
                    }
                    let destination = try Self.cachedDestination(for: remote, in: cache)
                    let expectedContentSHA256 = try Self.catalogSHA256(remote.contentSHA256)
                    let remoteIdentity = ServerSongIdentity(
                        serverURL: base,
                        profileID: syncProfileID,
                        songID: remote.id
                    )
                    let existingIndex = tracks.firstIndex {
                        $0.remoteIdentity == remoteIdentity
                    }
                    let previousCachedURL = existingIndex.flatMap { tracks[$0].fileURL }
                    let localSize = reusableCachedValidation?.snapshot.size
                    let cachedPlayer = reusableCachedPlayer
                    var resolvedContentSHA256 = reusableCachedValidation?.contentSHA256

                    if let existingIndex,
                       localSize == remote.size,
                       cachedPlayer != nil,
                       tracks[existingIndex].fileURL?.standardizedFileURL == destination.standardizedFileURL {
                        tracks[existingIndex].contentSHA256 = resolvedContentSHA256
                        if isPendingDownload { downloadProgress = 1 }
                        continue
                    }

                    let player: AVAudioPlayer
                    if localSize == remote.size, let cachedPlayer {
                        player = cachedPlayer
                    } else {
                        let downloadURL = try remoteURL(remote.downloadURL, relativeTo: base)
                        var request = authenticatedRequest(url: downloadURL)
                        request.timeoutInterval = 120
                        let ext = PathExtension.safe(remote.filename)
                        let staging = cache.appendingPathComponent(".download-\(UUID().uuidString)\(ext)")
                        guard Self.isDescendant(staging, of: cache) else {
                            throw ServerSyncError.invalidSongIdentifier
                        }
                        stagingURL = staging
                        let transferGeneration = try beginServerDownloadTransfer(
                            stateGeneration: stateGeneration
                        )
                        defer {
                            releaseServerDownloadTransfer(
                                stateGeneration: stateGeneration,
                                transferGeneration: transferGeneration
                            )
                        }
                        _ = try await MacLeaseBoundDownloader.download(
                            request: request,
                            to: staging,
                            expectedContentLength: remote.size,
                            authorizationLease: lease,
                            session: networkSession,
                            progress: { [weak self] completedBytes, totalBytes in
                                self?.publishServerDownloadTransfer(
                                    completedBytes: completedBytes,
                                    totalBytes: totalBytes,
                                    stateGeneration: stateGeneration,
                                    transferGeneration: transferGeneration
                                )
                            }
                        )
                        releaseServerDownloadTransfer(
                            stateGeneration: stateGeneration,
                            transferGeneration: transferGeneration
                        )
                        try Task.checkCancellation()
                        let stagedSize = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                        guard stagedSize == remote.size else { throw ServerSyncError.unexpectedDownloadSize }
                        try Task.checkCancellation()
                        let stagedHash = try await Self.fileSHA256Detached(at: staging)
                        try Task.checkCancellation()
                        guard expectedContentSHA256 == nil || stagedHash == expectedContentSHA256 else {
                            throw ServerSyncError.downloadHashMismatch
                        }
                        guard let stagedPlayer = try? AVAudioPlayer(contentsOf: staging) else {
                            throw ServerSyncError.invalidMedia
                        }
                        try Task.checkCancellation()
                        try await Self.awaitServerDownloadAuthorizationRefresh(authorizationRefresh)
                        try lease.authorize()
                        try Task.checkCancellation()
                        try MacAuthorizedDownloadFinalizer.finalize(authorizationLease: lease) {
                            try Self.installValidatedDownload(from: staging, at: destination)
                        }
                        stagingURL = nil
                        player = stagedPlayer
                        resolvedContentSHA256 = stagedHash
                    }

                    let metadata = await Self.metadata(for: destination)
                    if let validation = reusableCachedValidation,
                       !MacServerDownloadValidationPolicy.isReusable(
                        validated: validation.snapshot,
                        current: Self.serverDownloadFileSnapshot(at: validation.destination)
                       ) {
                        throw ServerSyncError.invalidMedia
                    }
                    let fallbackStem = destination.deletingPathExtension().lastPathComponent
                    let track = Track(
                        id: existingIndex.map { tracks[$0].id } ?? UUID(),
                        title: metadata.title == fallbackStem ? remote.title : metadata.title,
                        artist: metadata.artist == "Unknown Artist" ? remote.artist : metadata.artist,
                        album: metadata.album == "Unknown Album" ? remote.album : metadata.album,
                        duration: player.duration,
                        kind: remote.kind,
                        artwork: existingIndex.map { tracks[$0].artwork } ?? ArtworkStyle.allCases[tracks.count % ArtworkStyle.allCases.count],
                        artworkData: metadata.artworkData,
                        artworkURL: remote.artworkURL ?? existingIndex.flatMap { tracks[$0].artworkURL },
                        fileURL: destination,
                        remoteID: remote.id,
                        sourceServer: ServerSongIdentity.normalizedOrigin(base),
                        syncProfileID: syncProfileID,
                        downloadSourceURL: remote.sourceURL ?? existingIndex.flatMap { tracks[$0].downloadSourceURL },
                        contentSHA256: resolvedContentSHA256,
                        preservesUnlinkedImport: existingIndex.flatMap { tracks[$0].preservesUnlinkedImport } ?? false,
                        dateAdded: existingIndex.map { tracks[$0].dateAdded } ?? .now
                    )

                    if let existingIndex {
                        tracks[existingIndex] = track
                        if let previousCachedURL,
                           previousCachedURL.standardizedFileURL != destination.standardizedFileURL,
                           Self.isDescendant(previousCachedURL, of: cache) {
                            try? FileManager.default.removeItem(at: previousCachedURL)
                        }
                    } else {
                        tracks.append(track)
                    }
                    changedCount += 1
                    if isPendingDownload { downloadProgress = 1 }
                } catch is CancellationError {
                    if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
                    throw CancellationError()
                } catch {
                    if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
                    failedCount += 1
                }
            }

            await reconcileCachedUploadedLocalTracks()
            beginRemoteSongMetadataHydration(
                contextKey: Self.serverContextKey(base: base, profileID: catalogProfileID)
            )
            if currentTrackID == nil { currentTrackID = tracks.first?.id }
            hydrateRemotePlaylistTracks()
            persistLibrary()
            reconcileShuffleOrderIfNeeded()
            serverMessage = failedCount > 0
                ? "Downloaded \(changedCount); \(failedCount) failed"
                : (changedCount == 0
                    ? "Up to date • \(songs.count) server \(songs.count == 1 ? "song" : "songs")"
                    : "Synced \(changedCount) \(changedCount == 1 ? "song" : "songs")")
            downloadProgress = 1
            downloadStatus = failedCount > 0
                ? "Downloaded \(changedCount); \(failedCount) failed"
                : (changedCount == 0 ? "Up to date" : "Downloaded \(changedCount) songs")
            selectedRemoteSongIDs.subtract(Set(songs.map(\.id)))
            releaseServerDownloadState(
                generation: stateGeneration,
                authorizationLease: authorizationLease
            )
            await syncPlaylistsNow()
        } catch is CancellationError {
            serverMessage = "Download cancelled"
            downloadStatus = "Cancelled"
        } catch {
            serverMessage = error.localizedDescription
            downloadStatus = "Download failed: \(error.localizedDescription)"
        }
    }

    func uploadSongsToServer(_ urls: [URL]) async {
        let capturedUploadMode = MacUploadMode.localFile
        guard !localFileUploadActionsDisabled else {
            if !clientConfiguration.allowsLocalFileUpload {
                uploadStatus = "Preserved source-link uploads are disabled by the verified server configuration"
            }
            return
        }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else {
            uploadStatus = ServerSyncError.missingAdminToken.localizedDescription
            return
        }
        isUploadingServer = true
        uploadProgress = 0
        uploadStatus = "Preparing upload…"
        defer {
            isUploadingServer = false
            uploadCurrentFile = ""
        }

        do {
            let base = try normalizedServerURL()
            let profileID = syncProfileID
            saveServerURL(base)
            var failedCount = 0
            var associationConflictCount = 0
            for (index, fileURL) in urls.enumerated() {
                try Task.checkCancellation()
                let uploadFilename = ServerUploadNaming.filename(for: fileURL)
                uploadCurrentFile = uploadFilename
                uploadStatus = "Uploading \(index + 1) of \(urls.count)"
                if tracks.contains(where: {
                    Self.sameLocalFile($0.fileURL, fileURL)
                        && Self.hasConflictingRemoteAssociation(
                            $0,
                            targetServer: base,
                            targetProfileID: profileID
                        )
                }) {
                    failedCount += 1
                    associationConflictCount += 1
                    uploadProgress = Double(index + 1) / Double(max(urls.count, 1))
                    continue
                }
                do {
                    guard let tracked = tracks.first(where: { Self.sameLocalFile($0.fileURL, fileURL) }) else {
                        throw ServerSyncError.missingSourceLink
                    }
                    let uploadedSong = try await uploadServerFile(
                        tracked,
                        base: base,
                        adminToken: adminToken,
                        profileID: profileID,
                        capturedUploadMode: capturedUploadMode
                    )
                    mergeUploadedServerSong(uploadedSong, base: base, profileID: profileID)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedCount += 1
                }
                uploadProgress = Double(index + 1) / Double(max(urls.count, 1))
            }
            let successCount = urls.count - failedCount
            if associationConflictCount > 0 {
                let guidance = LocalImportTransferContextError.remoteAssociationConflict.localizedDescription
                uploadStatus = successCount == 0 && failedCount == associationConflictCount
                    ? guidance
                    : "Uploaded \(successCount); \(failedCount) failed. \(guidance)"
            } else {
                uploadStatus = failedCount == 0
                    ? "Uploaded \(successCount) songs"
                    : "Uploaded \(successCount); \(failedCount) failed"
            }
            serverMessage = uploadStatus
        } catch is CancellationError {
            uploadStatus = "Cancelled"
        } catch {
            uploadStatus = "Upload failed: \(error.localizedDescription)"
        }
    }

    private func uploadDownloadedSongsMissingFromServer() async {
        let capturedUploadMode = MacUploadMode.localFile
        guard !localFileUploadActionsDisabled else {
            if !clientConfiguration.allowsLocalFileUpload {
                uploadStatus = "Preserved source-link uploads are disabled by the verified server configuration"
                serverMessage = uploadStatus
            }
            return
        }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else {
            uploadStatus = ServerSyncError.missingAdminToken.localizedDescription
            serverMessage = uploadStatus
            return
        }
        isUploadingServer = true
        uploadProgress = 0
        uploadStatus = "Checking downloaded songs…"
        defer {
            isUploadingServer = false
            uploadCurrentFile = ""
        }

        do {
            let base = try normalizedServerURL()
            let profileID = syncProfileID
            saveServerURL(base)
            let catalog = remoteSongs
            let plan = MissingServerUploadPolicy.plan(
                tracks: tracks,
                catalog: catalog,
                activeProfileID: profileID,
                activeServerURL: base
            )
            for (trackID, remoteID) in plan.existingRemoteIDsByTrackID {
                reconcileUploadedLocalTrack(
                    trackID: trackID,
                    remoteID: remoteID,
                    sourceServer: ServerSongIdentity.normalizedOrigin(base),
                    profileID: profileID
                )
            }
            let candidates = plan.uploadTrackIDs.compactMap { trackID in
                tracks.first(where: { $0.id == trackID })
            }
            guard !candidates.isEmpty else {
                uploadProgress = 1
                uploadStatus = plan.ambiguousTrackIDs.isEmpty
                    ? "All downloaded songs are already on the server"
                    : "\(plan.ambiguousTrackIDs.count) ambiguous hash \(plan.ambiguousTrackIDs.count == 1 ? "match needs" : "matches need") review"
                serverMessage = uploadStatus
                return
            }

            var failures: [String] = []
            var uploadedCount = 0
            for (index, track) in candidates.enumerated() {
                try Task.checkCancellation()
                guard let fileURL = track.fileURL else { continue }
                uploadCurrentFile = ServerUploadNaming.filename(for: fileURL, title: track.title)
                uploadStatus = "Uploading \(index + 1) of \(candidates.count)"
                var uploadedSong: RemoteSong?
                var lastError: Error?
                for attempt in 1...3 {
                    do {
                        if attempt > 1 {
                            try await Task.sleep(for: .milliseconds(attempt == 2 ? 400 : 1_200))
                        }
                        uploadedSong = try await uploadServerFile(
                            track,
                            base: base,
                            adminToken: adminToken,
                            profileID: profileID,
                            capturedUploadMode: capturedUploadMode
                        )
                        break
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        lastError = error
                    }
                }

                if let uploadedSong {
                    uploadedCount += 1
                    mergeUploadedServerSong(uploadedSong, base: base, profileID: profileID)
                    reconcileUploadedLocalTrack(
                        trackID: track.id,
                        remoteID: uploadedSong.id,
                        sourceServer: ServerSongIdentity.normalizedOrigin(base),
                        profileID: profileID
                    )
                } else {
                    let name = track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
                    failures.append("\(name) (\(lastError?.localizedDescription ?? "upload failed"))")
                }
                uploadProgress = Double(index + 1) / Double(candidates.count)
            }

            let reconciledCount = plan.existingRemoteIDsByTrackID.count
            if failures.isEmpty {
                uploadStatus = "Uploaded \(uploadedCount); matched \(reconciledCount) already on the server"
            } else {
                uploadStatus = "Uploaded \(uploadedCount); failed: \(failures.joined(separator: ", "))"
            }
            if !plan.ambiguousTrackIDs.isEmpty {
                uploadStatus += "; \(plan.ambiguousTrackIDs.count) need review"
            }
            serverMessage = uploadStatus
        } catch is CancellationError {
            uploadStatus = "Upload cancelled"
            serverMessage = uploadStatus
        } catch {
            uploadStatus = "Upload failed: \(error.localizedDescription)"
            serverMessage = uploadStatus
        }
    }

    private func uploadServerFile(
        _ track: Track,
        base: URL,
        adminToken: String,
        profileID: String,
        capturedUploadMode: MacUploadMode
    ) async throws -> RemoteSong {
        guard let rawSource = track.sourceURL ?? track.downloadSourceURL,
              let sourceURL = URL(string: rawSource),
              sourceURL.scheme?.lowercased() == "https",
              sourceURL.user == nil,
              sourceURL.password == nil else { throw ServerSyncError.missingSourceLink }
        let url = base.appendingPathComponent("api/v1/admin/songs")
        guard Self.sameOrigin(url, base) else { throw ServerSyncError.invalidURL }
        await refreshClientConfigurationNow()
        try Task.checkCancellation()
        guard clientConfiguration.permittedUploadModes.contains(capturedUploadMode),
              matchesGenericFileUploadContext(
                base: base,
                profileID: profileID,
                adminToken: adminToken
              ) else {
            throw LocalImportTransferContextError.uploadModeUnavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 90
        request.httpBody = try JSONEncoder().encode(SourceLinkUploadDocument(
            sourceURL: sourceURL.absoluteString,
            mediaKind: track.kind == .video ? "video" : "audio"
        ))
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        setProfileHeader(on: &request, profileID: profileID)
        applyCurrentClientConfigHeaders(to: &request, base: base, fallbackToken: adminToken)
        var (data, response) = try await networkSession.data(
            for: request,
            delegate: MacRejectRedirectDelegate()
        )
        if track.kind != .video,
           Self.requiresLegacySourceLinkSchema(response: response, data: data) {
            guard matchesGenericFileUploadContext(
                base: base,
                profileID: profileID,
                adminToken: adminToken
            ) else { throw LocalImportTransferContextError.contextChanged }
            request.httpBody = try JSONEncoder().encode(SourceLinkUploadDocument(
                sourceURL: sourceURL.absoluteString,
                mediaKind: "audio",
                schemaVersion: 2
            ))
            (data, response) = try await networkSession.data(
                for: request,
                delegate: MacRejectRedirectDelegate()
            )
        }
        if let http = response as? HTTPURLResponse {
            invalidateRemoteCatalogAuthorityAfterCommittedMutation(
                base: base,
                profileID: profileID,
                statusCode: http.statusCode
            )
        }
        guard matchesGenericFileUploadContext(
            base: base,
            profileID: profileID,
            adminToken: adminToken
        ) else {
            throw LocalImportTransferContextError.contextChanged
        }
        return try Self.uploadedSong(from: data, response: response)
    }

    private func matchesGenericFileUploadContext(
        base: URL,
        profileID: String,
        adminToken: String
    ) -> Bool {
        guard serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines) == adminToken,
              syncProfileID == profileID,
              let currentBase = try? normalizedServerURL() else { return false }
        return Self.serverContextKey(base: currentBase, profileID: syncProfileID)
            == Self.serverContextKey(base: base, profileID: profileID)
    }

    func selectAndPlay(_ track: Track) {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can change the song"
            return
        }
        setPlaybackContext(playbackTracks, ensuring: track.id)
        startTrack(track.id, preservingShuffleQueue: false)
        publishListenAlongHostState()
    }

    func togglePlay() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can control playback"
            return
        }
        defer { publishListenAlongHostState() }
        if isPlaying {
            pausePlayback()
            return
        }
        guard let track = currentTrack ?? tracks.first else { return }
        if remoteStreamTrack?.id == track.id {
            guard let remoteStreamPlayer else { return }
            let bounds = playbackBounds(for: track, duration: playbackDuration)
            if position >= bounds.end - 0.05 || position < bounds.start {
                remoteStreamPlayer.seek(
                    to: CMTime(seconds: bounds.start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                position = bounds.start
            }
            remoteStreamPlayer.playImmediately(atRate: playbackRate)
            isPlaying = true
            beginListeningSession(for: track)
            startPlaybackTimer()
            publishSystemPlayback()
            return
        }
        ensurePlaybackContext(containing: track.id)
        if currentTrackID != track.id {
            startTrack(track.id, preservingShuffleQueue: false)
        } else {
            beginPlayback(of: track, resuming: true)
        }
    }

    func toggleCollectionPlayback() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can control playback"
            return
        }
        let context = playbackTracks
        guard !context.isEmpty else { return }
        let currentInContext = currentTrack.flatMap { current in
            context.contains(where: { $0.id == current.id }) ? current : nil
        }

        if isPlaying, currentInContext != nil {
            pausePlayback()
        } else if let currentInContext, !isPlaying {
            setPlaybackContext(context, ensuring: currentInContext.id)
            beginPlayback(of: currentInContext, resuming: true)
        } else if let first = context.first {
            setPlaybackContext(context, ensuring: first.id)
            startTrack(first.id, preservingShuffleQueue: false)
        }
    }

    func next() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can skip songs"
            return
        }
        defer { publishListenAlongHostState() }
        if let remoteStreamSongID {
            let playableSongs = streamableRemoteSongs
            guard !playableSongs.isEmpty else {
                stopCurrentPlayback()
                return
            }
            if shuffleEnabled {
                reconcileRemoteShuffleOrder(excluding: remoteStreamSongID)
                if remoteShuffledSongIDs.isEmpty {
                    rebuildRemoteShuffleOrder(excluding: remoteStreamSongID)
                }
                guard let nextID = remoteShuffledSongIDs.first,
                      let nextSong = playableSongs.first(where: { $0.id == nextID }) else {
                    stopCurrentPlayback()
                    return
                }
                remoteShuffledSongIDs.removeFirst()
                startRemoteSong(nextSong, preservingShuffleQueue: true, recordingHistory: true)
                return
            }
            let eligibleIDs = playableSongs.map(\.id)
            guard let nextID = MacRemoteStreamQueuePolicy.orderedNextID(
                current: remoteStreamSongID,
                eligible: eligibleIDs
            ), let nextSong = playableSongs.first(where: { $0.id == nextID }) else {
                stopCurrentPlayback()
                return
            }
            startRemoteSong(
                nextSong,
                preservingShuffleQueue: true,
                recordingHistory: true
            )
            return
        }
        let context = activePlaybackTracks
        guard !context.isEmpty else { return }
        captureFallbackPlaybackContextIfNeeded(context)

        if shuffleEnabled {
            if shuffledTrackIDs.isEmpty { rebuildShuffleOrder() }
            if let nextID = shuffledTrackIDs.first {
                shuffledTrackIDs.removeFirst()
                persistShuffleQueue()
                startTrack(nextID, preservingShuffleQueue: true)
                return
            }
        }

        guard
            let currentTrackID,
            let currentIndex = context.firstIndex(where: { $0.id == currentTrackID })
        else {
            startTrack(context[0].id, preservingShuffleQueue: false)
            return
        }
        let nextIndex = context.index(after: currentIndex)
        startTrack((nextIndex == context.endIndex ? context[0] : context[nextIndex]).id, preservingShuffleQueue: false)
    }

    func previous() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can skip songs"
            return
        }
        defer { publishListenAlongHostState() }
        if let remoteStreamSongID {
            let playableSongs = streamableRemoteSongs
            guard !playableSongs.isEmpty else {
                stopCurrentPlayback()
                return
            }
            if position > 3 {
                seek(to: 0)
                if !isPlaying { togglePlay() }
                return
            }
            if shuffleEnabled {
                let eligibleIDs = Set(playableSongs.map(\.id))
                if let previousID = MacRemoteStreamQueuePolicy.popPreviousID(
                    history: &remoteHistorySongIDs,
                    eligible: eligibleIDs
                ), let previousSong = playableSongs.first(where: { $0.id == previousID }) {
                    remoteShuffledSongIDs.removeAll { $0 == previousID || $0 == remoteStreamSongID }
                    if previousID != remoteStreamSongID {
                        remoteShuffledSongIDs.insert(remoteStreamSongID, at: 0)
                    }
                    startRemoteSong(previousSong, preservingShuffleQueue: true, recordingHistory: false)
                    return
                }
                return
            }
            let eligibleIDs = playableSongs.map(\.id)
            guard let previousID = MacRemoteStreamQueuePolicy.orderedPreviousID(
                current: remoteStreamSongID,
                eligible: eligibleIDs
            ), let previousSong = playableSongs.first(where: { $0.id == previousID }) else {
                stopCurrentPlayback()
                return
            }
            startRemoteSong(previousSong, preservingShuffleQueue: true, recordingHistory: false)
            return
        }
        let context = activePlaybackTracks
        guard !context.isEmpty else { return }
        captureFallbackPlaybackContextIfNeeded(context)
        if position > 3, let currentTrack {
            seek(to: 0)
            beginPlayback(of: currentTrack, resuming: true)
            return
        }

        if shuffleEnabled {
            while let previousID = historyTrackIDs.popLast() {
                guard context.contains(where: { $0.id == previousID }) else { continue }
                let departedTrackID = currentTrackID
                persistHistory()
                shuffledTrackIDs.removeAll { $0 == previousID || $0 == departedTrackID }
                if let departedTrackID, departedTrackID != previousID {
                    shuffledTrackIDs.insert(departedTrackID, at: 0)
                }
                persistShuffleQueue()
                startTrack(previousID, preservingShuffleQueue: true, recordingHistory: false)
                return
            }
            persistHistory()
            return
        }

        guard
            let currentTrackID,
            let currentIndex = context.firstIndex(where: { $0.id == currentTrackID })
        else {
            startTrack(context.last!.id, preservingShuffleQueue: false)
            return
        }
        let previousIndex = currentIndex == context.startIndex ? context.index(before: context.endIndex) : context.index(before: currentIndex)
        startTrack(context[previousIndex].id, preservingShuffleQueue: false)
    }

    func toggleFavorite(_ track: Track) {
        guard tracks.contains(where: { $0.id == track.id }) else { return }
        guard let likedIndex = playlists.firstIndex(where: \.isSystem) else { return }
        if favorites.contains(track.id) {
            favorites.remove(track.id)
            playlists[likedIndex].trackIDs.removeAll { $0 == track.id }
        } else {
            favorites.insert(track.id)
            if !playlists[likedIndex].trackIDs.contains(track.id) {
                playlists[likedIndex].trackIDs.append(track.id)
            }
        }
        if track.remoteID != nil {
            playlistMutationGeneration &+= 1
            likesDirty = true
        }
        persistLibrary()
        schedulePlaylistSync()
        publishSystemPlayback()
    }

    func toggleShuffle() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can change playback options"
            return
        }
        shuffleEnabled.toggle()
        if let remoteStreamSongID {
            remoteHistorySongIDs.removeAll()
            if shuffleEnabled {
                rebuildRemoteShuffleOrder(excluding: remoteStreamSongID)
            } else {
                remoteShuffledSongIDs.removeAll()
            }
        } else if shuffleEnabled {
            rebuildShuffleOrder()
        } else {
            shuffledTrackIDs.removeAll()
            persistShuffleQueue()
        }
        publishSystemPlayback()
        publishListenAlongHostState()
    }

    func toggleRepeat() {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can change playback options"
            return
        }
        repeatEnabled.toggle()
        audioPlayer?.numberOfLoops = 0
        publishSystemPlayback()
        publishListenAlongHostState()
    }

    func setPlaybackRate(_ rate: Float) {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can change playback options"
            return
        }
        playbackRate = rate
        audioPlayer?.enableRate = true
        audioPlayer?.rate = rate
        crossfadePlayer?.rate = rate
        remoteStreamPlayer?.defaultRate = rate
        if remoteStreamPlayer?.timeControlStatus == .playing {
            remoteStreamPlayer?.rate = rate
        }
        publishSystemPlayback()
        publishListenAlongHostState()
    }

    func seek(to fraction: Double) {
        guard let track = currentTrack else { return }
        let duration = playbackDuration > 0 ? playbackDuration : track.duration
        seekToTime(ClipPlaybackPolicy.position(
            fraction: fraction,
            within: playbackBounds(for: track, duration: duration)
        ))
    }

    func seekToTime(_ requestedTime: TimeInterval) {
        guard !isListenAlongGuest else {
            listenAlongStatus = "Only the host can seek"
            return
        }
        cancelCrossfade()
        guard let track = currentTrack else { return }
        updateListeningSession()
        let safeTime = requestedTime.isFinite ? requestedTime : 0
        let duration = playbackDuration > 0 ? playbackDuration : track.duration
        let bounds = playbackBounds(for: track, duration: duration)
        position = safeTime.clamped(to: bounds.start...bounds.end)
        if loadedAudioTrackID == track.id {
            audioPlayer?.currentTime = position
        }
        if remoteStreamTrack?.id == track.id, let remoteStreamPlayer {
            remoteStreamPlayer.seek(
                to: CMTime(seconds: position, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }
        playbackDiscontinuities.send(position)
        lastListeningPosition = position
        persistPlaybackPosition()
        publishSystemPlayback()
        publishListenAlongHostState()
    }

    func importLocalFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Music to Your Library"
        panel.message = "Choose audio or video files and folders. Your files stay where they are on this Mac."
        panel.prompt = "Add Music"
        panel.allowedContentTypes = [.audio, .video, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importLocalFiles(at: urls) }
    }

    func importLocalFiles(at selectedURLs: [URL]) async {
        let knownPaths = Set(tracks.compactMap { $0.fileURL?.standardizedFileURL.path })
        let styles: [ArtworkStyle] = [.midnight, .electric, .echoes, .golden, .weightless, .falling]
        let inspections = await Self.inspectLocalMedia(
            selectedURLs: selectedURLs,
            excludingPaths: knownPaths
        )
        let imported = inspections.enumerated().map { offset, inspection in
            Track(
                title: inspection.title,
                artist: inspection.artist,
                album: inspection.album,
                duration: inspection.duration,
                kind: inspection.kind,
                artwork: styles[(tracks.count + offset) % styles.count],
                artworkData: inspection.artworkData,
                fileURL: inspection.fileURL,
                preservesUnlinkedImport: true,
                dateAdded: .now
            )
        }
        guard !imported.isEmpty else { return }
        tracks.append(contentsOf: imported)
        if currentTrackID == nil { currentTrackID = tracks.first?.id }
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
    }

    private func reconcileLocalPlayableDurations() async {
        let candidates = tracks.compactMap { track -> (UUID, URL)? in
            guard let fileURL = track.fileURL else { return nil }
            return (track.id, fileURL)
        }
        let measurements = await Task.detached(priority: .utility) {
            candidates.compactMap { id, fileURL -> (UUID, TimeInterval)? in
                guard let player = try? AVAudioPlayer(contentsOf: fileURL),
                      let duration = MacPlayableMediaDurationPolicy.preferred(
                        storedDuration: nil,
                        playableDurations: [player.duration]
                      ) else { return nil }
                return (id, duration)
            }
        }.value
        var changed = false
        for (id, duration) in measurements {
            guard let index = tracks.firstIndex(where: { $0.id == id }),
                  abs(tracks[index].duration - duration) > 0.25 else { continue }
            tracks[index].duration = duration
            changed = true
        }
        if changed { persistLibrary() }
    }

    @discardableResult
    func associateLocalImportSource(
        trackID: UUID,
        source: LocalImportSourceAssociation
    ) -> Track? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              tracks[index].fileURL != nil else { return nil }
        let sourceURL = source.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let downloadSourceURL = source.downloadSourceURL?.absoluteString
        var changed = false
        if !sourceURL.isEmpty, tracks[index].sourceURL != sourceURL {
            tracks[index].sourceURL = sourceURL
            changed = true
        }
        if let downloadSourceURL, tracks[index].downloadSourceURL != downloadSourceURL {
            tracks[index].downloadSourceURL = downloadSourceURL
            changed = true
        }
        if changed { persistLibrary() }
        return tracks[index]
    }

    @discardableResult
    func insertLocalImportedAudio(_ imported: LocalImportedAudio) -> Track {
        if let duplicate = tracks.first(where: {
            $0.sourceSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.sourceSHA256
                || $0.contentSHA256 == imported.contentSHA256
        }) {
            if duplicate.fileURL?.standardizedFileURL != imported.fileURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: imported.fileURL)
            }
            return associateLocalImportSource(
                trackID: duplicate.id,
                source: LocalImportSourceAssociation(
                    sourceURL: imported.metadata.sourceURL,
                    downloadSourceURL: imported.downloadSourceURL
                )
            ) ?? duplicate
        }

        let styles: [ArtworkStyle] = [.midnight, .electric, .echoes, .golden, .weightless, .falling]
        let track = Track(
            title: imported.metadata.title,
            artist: imported.metadata.artist,
            album: imported.metadata.album ?? "Imported",
            duration: imported.duration,
            kind: imported.mediaMode == .video ? .video : .audio,
            artwork: styles[tracks.count % styles.count],
            artworkData: imported.artworkData,
            artworkURL: imported.metadata.artworkURL,
            fileURL: imported.fileURL.standardizedFileURL,
            remoteID: nil,
            sourceServer: nil,
            syncProfileID: nil,
            sourceURL: imported.metadata.sourceURL,
            downloadSourceURL: imported.downloadSourceURL?.absoluteString,
            sourceSHA256: imported.sourceSHA256,
            contentSHA256: imported.contentSHA256,
            preservesUnlinkedImport: true,
            dateAdded: .now
        )
        tracks.append(track)
        if currentTrackID == nil { currentTrackID = track.id }
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
        return track
    }

    @discardableResult
    func repairLocalImportArtwork(trackID: UUID, artworkData: Data) -> Track? {
        guard !artworkData.isEmpty,
              let index = tracks.firstIndex(where: { $0.id == trackID }),
              tracks[index].remoteID == nil,
              tracks[index].sourceServer == nil else { return nil }
        guard tracks[index].artworkData != artworkData else { return tracks[index] }
        tracks[index].artworkData = artworkData
        persistLibrary()
        return tracks[index]
    }

    @discardableResult
    func uploadLocalImportToActiveProfile(_ track: Track) async throws -> Bool {
        let context = try beginLocalImportTransfer(reservingUpload: true)
        defer { endLocalImportTransfer(context) }
        return try await uploadLocalImportToActiveProfile(track, context: context)
    }

    @discardableResult
    func uploadLocalImportToActiveProfile(
        _ track: Track,
        context: LocalImportTransferContext
    ) async throws -> Bool {
        try validateLocalImportTransfer(context)
        guard let currentTrack = tracks.first(where: { $0.id == track.id }) else {
            throw ServerSyncError.invalidMedia
        }
        guard context.reservesUpload,
              let base = context.baseURL,
              let adminToken = context.adminToken,
              !adminToken.isEmpty else {
            throw LocalImportTransferContextError.missingUploadConfiguration
        }
        if Self.hasConflictingRemoteAssociation(
            currentTrack,
            targetServer: base,
            targetProfileID: context.profileID
        ) {
            throw LocalImportTransferContextError.remoteAssociationConflict
        }
        if let remoteID = currentTrack.remoteID,
           remoteSongs.contains(where: { $0.id == remoteID }),
           currentTrack.syncProfileID == context.profileID,
           let sourceServer = currentTrack.sourceServer.flatMap(URL.init(string:)),
           Self.sameOrigin(sourceServer, base) {
            return false
        }
        if let contentHash = currentTrack.contentSHA256?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !contentHash.isEmpty,
           let existing = remoteSongs.first(where: {
               $0.contentSHA256?
                   .trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased() == contentHash
           }) {
            reconcileUploadedLocalTrack(
                trackID: currentTrack.id,
                remoteID: existing.id,
                sourceServer: ServerSongIdentity.normalizedOrigin(base),
                profileID: context.profileID
            )
            return false
        }
        if context.requiresReviewedMatch, context.uploadMode != .reviewedMatch {
            throw LocalImportTransferContextError.reviewedMatchRequired
        }
        guard context.uploadMode == .localFile
                || context.uploadMode == .serverSourceLink
                || context.uploadMode == .reviewedMatch else {
            throw LocalImportTransferContextError.uploadModeUnavailable
        }
        saveServerURL(base)
        try validateLocalImportTransfer(context)
        let uploadedSong = try await uploadServerFile(
            currentTrack,
            base: base,
            adminToken: adminToken,
            profileID: context.profileID,
            capturedUploadMode: context.uploadMode
        )
        try validateCommittedLocalImportTransfer(context)
        mergeUploadedServerSong(uploadedSong, base: base, profileID: context.profileID)
        reconcileUploadedLocalTrack(
            trackID: currentTrack.id,
            remoteID: uploadedSong.id,
            sourceServer: ServerSongIdentity.normalizedOrigin(base),
            profileID: context.profileID
        )
        serverMessage = "Connected • \(remoteSongs.count) songs available"
        return true
    }

    private func importServerSourcePage(
        for track: Track,
        rawUserInput: String?,
        base: URL,
        adminToken: String,
        profileID: String,
        context: LocalImportTransferContext
    ) async throws -> RemoteSong {
        guard clientConfiguration.allowsServerSourceLink else {
            throw LocalImportTransferContextError.uploadModeUnavailable
        }
        guard let sourcePage = MacSourceImportPolicy.exactCanonicalYouTubePage(rawUserInput) else {
            throw LocalImportTransferContextError.unsupportedSourceLink
        }
        let payload = MacSourceImportRequest(
            sourcePageURL: sourcePage.absoluteString
        )
        let body = try JSONEncoder().encode(payload)
        let endpoint = base.appendingPathComponent("api/v1/admin/source-imports")
        guard Self.sameOrigin(endpoint, base) else { throw ServerSyncError.crossOriginDownload }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = body
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        setProfileHeader(on: &request, profileID: profileID)
        applyCurrentClientConfigHeaders(to: &request, base: base, fallbackToken: adminToken)
        try validateLocalImportTransfer(context)
        let (data, http) = try await boundedResponseData(for: request, limit: 2 * 1_024 * 1_024)
        invalidateRemoteCatalogAuthorityAfterCommittedMutation(
            base: base,
            profileID: profileID,
            statusCode: http.statusCode
        )
        guard http.url.map({ Self.sameOrigin($0, base) }) == true,
              Self.isJSONResponse(http) else {
            throw ServerSyncError.invalidResponse
        }
        if http.statusCode == 201,
           let imported = try? JSONDecoder().decode(MacSourceImportResponse.self, from: data),
           imported.schemaVersion == 1 {
            return imported.song
        }
        if http.statusCode == 409 {
            if let duplicate = MacSourceImportPolicy.duplicateSong(from: data) {
                return duplicate
            }
        }
        throw Self.serverError(status: http.statusCode, data: data)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        if crossfadePlayer != nil {
            completeCrossfade()
        } else {
            finishCurrentPlaybackRange()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        endListeningSession()
        isPlaying = false
        stopPlaybackTimer()
        systemPlaybackController?.publish(nil)
    }

    private func configureSystemPlaybackHandlers() {
        guard let systemPlaybackController else { return }
        systemPlaybackController.handlers = MacSystemPlaybackHandlers(
            play: { [weak self] in
                guard let self, !self.isPlaying else { return }
                self.togglePlay()
            },
            pause: { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pausePlayback()
            },
            stop: { [weak self] in
                guard let self, self.isPlaying else { return }
                self.pausePlayback()
            },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] time in self?.seekToTime(time) },
            skip: { [weak self] interval in
                guard let self else { return }
                self.seekToTime(self.position + interval)
            },
            changeRate: { [weak self] rate in
                self?.setPlaybackRate(rate.clamped(to: 0.5...2))
            },
            setShuffle: { [weak self] enabled in
                guard let self, self.shuffleEnabled != enabled else { return }
                self.toggleShuffle()
            },
            setRepeat: { [weak self] enabled in
                guard let self, self.repeatEnabled != enabled else { return }
                self.toggleRepeat()
            },
            setFavorite: { [weak self] favorite in
                guard let self, let track = self.currentTrack,
                      self.tracks.contains(where: { $0.id == track.id }),
                      self.favorites.contains(track.id) != favorite else { return }
                self.toggleFavorite(track)
            }
        )
    }

    private func publishSystemPlayback() {
        guard let systemPlaybackController else { return }
        guard let track = currentTrack,
              loadedAudioTrackID == track.id
                || remoteStreamTrack?.id == track.id else {
            systemPlaybackController.publish(nil)
            return
        }
        let isRemoteStream = remoteStreamTrack?.id == track.id
        let queue = isRemoteStream ? [track] : activePlaybackTracks
        let remoteQueueIndex = remoteStreamSongID.flatMap { currentID in
            streamableRemoteSongs.firstIndex(where: { $0.id == currentID })
        }
        systemPlaybackController.publish(MacNowPlayingSnapshot(
            track: track,
            position: position,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            queue: queue,
            isFavorite: favorites.contains(track.id),
            canFavorite: !isRemoteStream,
            shuffleEnabled: shuffleEnabled,
            repeatEnabled: repeatEnabled,
            profileID: syncProfileID,
            queueIndexOverride: isRemoteStream ? remoteQueueIndex : nil,
            queueCountOverride: isRemoteStream ? streamableRemoteSongs.count : nil
        ))
    }

    private var playbackTracks: [Track] {
        section == .storage ? visibleTracks : displayedTracks
    }

    private var activePlaybackTracks: [Track] {
        guard !playbackContextTrackIDs.isEmpty else { return playbackTracks }
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let context = playbackContextTrackIDs.compactMap { tracksByID[$0] }
        return context.isEmpty ? playbackTracks : context
    }

    private func setPlaybackContext(_ context: [Track], ensuring trackID: UUID) {
        let preferredContext = context.contains(where: { $0.id == trackID }) ? context : tracks
        playbackContextTrackIDs = preferredContext.map(\.id)
        persistPlaybackContext()
    }

    private func ensurePlaybackContext(containing trackID: UUID) {
        guard !activePlaybackTracks.contains(where: { $0.id == trackID }) || playbackContextTrackIDs.isEmpty else { return }
        setPlaybackContext(playbackTracks, ensuring: trackID)
    }

    private func captureFallbackPlaybackContextIfNeeded(_ context: [Track]) {
        guard playbackContextTrackIDs.isEmpty else { return }
        playbackContextTrackIDs = context.map(\.id)
        persistPlaybackContext()
    }

    private func startTrack(
        _ trackID: UUID,
        preservingShuffleQueue: Bool,
        recordingHistory: Bool = true
    ) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        if recordingHistory { recordCurrentTrackInHistory(whenSwitchingTo: track.id) }
        stopCurrentPlayback()
        currentTrackID = track.id
        position = playbackBounds(for: track).start
        persistPlaybackPosition()
        if shuffleEnabled, !preservingShuffleQueue { rebuildShuffleOrder() }
        beginPlayback(of: track)
    }

    private func beginPlayback(of track: Track, resuming: Bool = false) {
        guard let fileURL = track.fileURL else {
            systemPlaybackController?.publish(nil)
            return
        }
        if loadedAudioTrackID != track.id || audioPlayer == nil {
            guard let player = try? AVAudioPlayer(contentsOf: fileURL) else {
                isPlaying = false
                systemPlaybackController?.publish(nil)
                return
            }
            player.delegate = self
            player.volume = PlaybackVolumePolicy.gain(for: volume)
            player.numberOfLoops = 0
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            audioPlayer = player
            loadedAudioTrackID = track.id
        }

        synchronizePlaybackDuration(for: track, playerDuration: audioPlayer?.duration)

        let bounds = playbackBounds(for: track, duration: playbackDuration)
        if !resuming || position < bounds.start || position >= bounds.end { position = bounds.start }
        audioPlayer?.currentTime = position
        isPlaying = audioPlayer?.play() ?? false
        if isPlaying {
            beginListeningSession(for: track)
            startPlaybackTimer()
        }
        publishSystemPlayback()
    }

    private func synchronizePlaybackDuration(for track: Track, playerDuration: TimeInterval?) {
        let measuredDuration = MacPlayableMediaDurationPolicy.preferred(
            storedDuration: nil,
            playableDurations: [playerDuration]
        )
        let resolvedDuration = MacPlayableMediaDurationPolicy.preferred(
            storedDuration: track.duration,
            playableDurations: [measuredDuration]
        ) ?? 0
        playbackDuration = resolvedDuration

        guard measuredDuration != nil,
              abs(track.duration - resolvedDuration) > 0.25,
              let trackIndex = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[trackIndex].duration = resolvedDuration
        persistLibrary()
    }

    private func pausePlayback(allowListenAlongGuest: Bool = false) {
        guard allowListenAlongGuest || !isListenAlongGuest else {
            listenAlongStatus = "Only the host can control playback"
            return
        }
        cancelCrossfade()
        updateListeningSession(flush: true)
        if remoteStreamTrack?.id == currentTrackID, let remoteStreamPlayer {
            remoteStreamPlayer.pause()
            let currentTime = remoteStreamPlayer.currentTime().seconds
            position = currentTime.isFinite ? max(currentTime, 0) : position
        } else {
            audioPlayer?.pause()
            position = audioPlayer?.currentTime ?? position
        }
        isPlaying = false
        stopPlaybackTimer()
        persistListeningHistory()
        scheduleListeningHistorySync()
        persistPlaybackPosition()
        publishSystemPlayback()
        publishListenAlongHostState()
    }

    private func stopCurrentPlayback(preservingRemoteNavigation: Bool = false) {
        cancelCrossfade()
        endListeningSession()
        remoteStreamLoadGeneration &+= 1
        remoteStreamPreparationTask?.cancel()
        remoteStreamPreparationTask = nil
        if let remoteStreamEndObserver {
            NotificationCenter.default.removeObserver(remoteStreamEndObserver)
            self.remoteStreamEndObserver = nil
        }
        if let remoteStreamFailureObserver {
            NotificationCenter.default.removeObserver(remoteStreamFailureObserver)
            self.remoteStreamFailureObserver = nil
        }
        remoteStreamStatusObservation?.invalidate()
        remoteStreamStatusObservation = nil
        remoteStreamPlayer?.pause()
        remoteStreamPlayer = nil
        remoteStreamLoader?.invalidate()
        remoteStreamLoader = nil
        remoteYouTubeStreamLoader?.invalidate()
        remoteYouTubeStreamLoader = nil
        remoteStreamAuthorizationLease?.invalidate()
        remoteStreamAuthorizationLease = nil
        remoteStreamDirectURL = nil
        remoteStreamDirectHeaders = [:]
        remoteStreamTrack = nil
        remoteStreamSongID = nil
        if !preservingRemoteNavigation {
            remoteShuffledSongIDs.removeAll()
            remoteHistorySongIDs.removeAll()
        }
        audioPlayer?.stop()
        audioPlayer = nil
        loadedAudioTrackID = nil
        isPlaying = false
        stopPlaybackTimer()
        systemPlaybackController?.publish(nil)
    }

    private func finishCurrentPlaybackRange() {
        guard let track = currentTrack else { return }
        let bounds = playbackBounds(for: track, duration: playbackDuration)
        updateListeningSession(flush: true)
        position = bounds.end

        if isListenAlongGuest {
            remoteStreamPlayer?.pause()
            audioPlayer?.pause()
            isPlaying = false
            stopPlaybackTimer()
            publishSystemPlayback()
            return
        }

        if repeatEnabled {
            endListeningSession()
            position = bounds.start
            if remoteStreamTrack?.id == track.id, let remoteStreamPlayer {
                remoteStreamPlayer.seek(
                    to: CMTime(seconds: bounds.start, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                remoteStreamPlayer.playImmediately(atRate: playbackRate)
                isPlaying = true
            } else if let audioPlayer {
                audioPlayer.currentTime = bounds.start
                isPlaying = audioPlayer.play()
            }
            playbackDiscontinuities.send(bounds.start)
            if isPlaying {
                beginListeningSession(for: track)
                startPlaybackTimer()
            }
            persistPlaybackPosition()
            publishSystemPlayback()
            return
        }

        remoteStreamPlayer?.pause()
        audioPlayer?.pause()
        isPlaying = false
        stopPlaybackTimer()
        persistPlaybackPosition()
        publishSystemPlayback()
        next()
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                if self.remoteStreamTrack?.id == self.currentTrackID,
                   let remoteStreamPlayer = self.remoteStreamPlayer {
                    let currentTime = remoteStreamPlayer.currentTime().seconds
                    if currentTime.isFinite { self.position = max(currentTime, 0) }
                } else {
                    self.position = self.audioPlayer?.currentTime ?? self.position
                }
                if let track = self.currentTrack,
                   self.updateCrossfadeIfNeeded(for: track) {
                    return
                }
                if let track = self.currentTrack,
                   ClipPlaybackPolicy.reachedEnd(
                    position: self.position,
                    bounds: self.playbackBounds(for: track, duration: self.playbackDuration)
                   ) {
                    self.finishCurrentPlaybackRange()
                    return
                }
                self.updateListeningSession()
                self.persistPlaybackPositionIfNeeded()
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    private func automaticCrossfadeTrack() -> Track? {
        let context = activePlaybackTracks
        guard context.count > 1 else { return nil }
        if shuffleEnabled {
            reconcileShuffleOrderIfNeeded()
            if shuffledTrackIDs.isEmpty { rebuildShuffleOrder() }
            guard let nextID = shuffledTrackIDs.first else { return nil }
            return context.first { $0.id == nextID }
        }
        guard let currentTrackID,
              let currentIndex = context.firstIndex(where: { $0.id == currentTrackID }) else {
            return context.first
        }
        let nextIndex = context.index(after: currentIndex)
        return nextIndex == context.endIndex ? context.first : context[nextIndex]
    }

    private func updateCrossfadeIfNeeded(for currentTrack: Track) -> Bool {
        guard crossfadeEnabled, !repeatEnabled, remoteStreamTrack == nil,
              let currentPlayer = audioPlayer else {
            cancelCrossfade()
            return false
        }
        let currentBounds = playbackBounds(for: currentTrack, duration: playbackDuration)

        if crossfadePlayer == nil {
            guard let nextTrack = automaticCrossfadeTrack(),
                  let fileURL = nextTrack.fileURL,
                  let nextPlayer = try? AVAudioPlayer(contentsOf: fileURL) else { return false }
            let nextBounds = playbackBounds(for: nextTrack, duration: nextPlayer.duration)
            let duration = MacCrossfadePolicy.effectiveDuration(
                requestedSeconds: crossfadeSeconds,
                currentDuration: currentBounds.end - currentBounds.start,
                nextDuration: nextBounds.end - nextBounds.start
            )
            let remaining = currentBounds.end - currentPlayer.currentTime
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
        let remaining = currentBounds.end - currentPlayer.currentTime
        applyCrossfadeVolumes(progress: MacCrossfadePolicy.progress(
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
            audioPlayer?.volume = gain
            return
        }
        let resolvedProgress = progress ?? {
            guard let audioPlayer, let currentTrack else { return 0.0 }
            let bounds = playbackBounds(for: currentTrack, duration: playbackDuration)
            return MacCrossfadePolicy.progress(
                remaining: bounds.end - audioPlayer.currentTime,
                duration: activeCrossfadeDuration
            )
        }()
        audioPlayer?.volume = gain * Float(1 - resolvedProgress)
        crossfadePlayer.volume = gain * Float(resolvedProgress)
    }

    private func cancelCrossfade() {
        crossfadePlayer?.delegate = nil
        crossfadePlayer?.stop()
        crossfadePlayer = nil
        crossfadeTrackID = nil
        activeCrossfadeDuration = 0
        audioPlayer?.volume = PlaybackVolumePolicy.gain(for: volume)
    }

    private func completeCrossfade() {
        guard let nextPlayer = crossfadePlayer,
              let nextTrackID = crossfadeTrackID,
              let nextTrack = tracks.first(where: { $0.id == nextTrackID }) else {
            cancelCrossfade()
            return
        }
        endListeningSession()
        recordCurrentTrackInHistory(whenSwitchingTo: nextTrackID)
        if shuffleEnabled {
            shuffledTrackIDs.removeAll { $0 == nextTrackID }
            persistShuffleQueue()
        }
        audioPlayer?.delegate = nil
        audioPlayer?.stop()
        audioPlayer = nextPlayer
        loadedAudioTrackID = nextTrackID
        crossfadePlayer = nil
        crossfadeTrackID = nil
        activeCrossfadeDuration = 0
        nextPlayer.volume = PlaybackVolumePolicy.gain(for: volume)
        currentTrackID = nextTrackID
        synchronizePlaybackDuration(for: nextTrack, playerDuration: nextPlayer.duration)
        position = nextPlayer.currentTime
        isPlaying = nextPlayer.isPlaying
        persistPlaybackPosition()
        if isPlaying { beginListeningSession(for: nextTrack) }
        publishSystemPlayback()
    }

    private func reconcileShuffleOrderIfNeeded() {
        guard shuffleEnabled else { return }
        let context = activePlaybackTracks
        if playbackContextTrackIDs.isEmpty {
            playbackContextTrackIDs = context.map(\.id)
            persistPlaybackContext()
        }

        let eligibleIDs = context.map(\.id).filter { $0 != currentTrackID }
        let eligibleSet = Set(eligibleIDs)
        var seen = Set<UUID>()
        shuffledTrackIDs = shuffledTrackIDs.filter { id in
            eligibleSet.contains(id) && seen.insert(id).inserted
        }

        let playedIDs = Set(historyTrackIDs)
        for id in eligibleIDs where !seen.contains(id) && !playedIDs.contains(id) {
            shuffledTrackIDs.append(id)
            seen.insert(id)
        }
        persistShuffleQueue()
    }

    private var streamableRemoteSongs: [RemoteSong] {
        remoteSongs.filter {
            MacRemoteStreamMediaPolicy.unavailableMessage(kind: $0.kind, size: $0.size) == nil
        }
    }

    private func reconcileRemoteShuffleOrder(excluding currentSongID: String) {
        remoteShuffledSongIDs = MacRemoteStreamQueuePolicy.reconciledShuffleQueue(
            existing: remoteShuffledSongIDs,
            history: remoteHistorySongIDs,
            current: currentSongID,
            eligible: streamableRemoteSongs.map(\.id)
        )
    }

    private func rebuildRemoteShuffleOrder(excluding currentSongID: String) {
        remoteShuffledSongIDs = streamableRemoteSongs
            .map(\.id)
            .filter { $0 != currentSongID }
            .shuffled()
    }

    private func rebuildShuffleOrder() {
        let context = activePlaybackTracks
        if playbackContextTrackIDs.isEmpty {
            playbackContextTrackIDs = context.map(\.id)
            persistPlaybackContext()
        }
        shuffledTrackIDs = context.map(\.id).filter { $0 != currentTrackID }.shuffled()
        persistShuffleQueue()
    }

    private func recordCurrentTrackInHistory(whenSwitchingTo newTrackID: UUID) {
        guard let currentTrackID, currentTrackID != newTrackID else { return }
        historyTrackIDs.append(currentTrackID)
        if historyTrackIDs.count > 100 { historyTrackIDs.removeFirst(historyTrackIDs.count - 100) }
        persistHistory()
    }

    private func persistHistory() {
        defaults.set(historyTrackIDs.map(\.uuidString), forKey: Self.historyKey)
    }

    private func beginListeningSession(for track: Track) {
        let serverOrigin = ServerSongIdentity.normalizedOrigin(track.sourceServer)
            ?? (try? normalizedServerURL()).flatMap(ServerSongIdentity.normalizedOrigin)
        if
            let activeListeningEntryID,
            let activeEntry = listeningHistoryEntries.first(where: { $0.id == activeListeningEntryID }),
            activeEntry.trackID == track.id,
            activeEntry.serverOrigin == serverOrigin,
            (activeEntry.syncProfileID ?? "default") == syncProfileID
        {
            return
        }

        let entry = ListeningHistoryRetentionPolicy.entry(
            for: track,
            serverOrigin: serverOrigin,
            profileID: syncProfileID
        )
        ListeningHistoryRetentionPolicy.append(entry, to: &listeningHistoryEntries)
        activeListeningEntryID = entry.id
        lastListeningPosition = currentPlaybackPosition
        lastPersistedListeningSeconds = 0
        pendingListeningSeconds = 0
        persistListeningHistory()
    }

    private func updateListeningSession(flush: Bool = false) {
        let currentPosition = currentPlaybackPosition
        guard
            let activeListeningEntryID,
            let entryIndex = listeningHistoryEntries.firstIndex(where: { $0.id == activeListeningEntryID })
        else {
            lastListeningPosition = currentPosition
            pendingListeningSeconds = 0
            return
        }

        let delta = currentPosition - lastListeningPosition
        if isPlaying, delta > 0, delta < 5 {
            pendingListeningSeconds += delta
        }
        lastListeningPosition = currentPosition

        let listenedSeconds = listeningHistoryEntries[entryIndex].listenedSeconds
            + pendingListeningSeconds
        let reachedPersistenceBoundary = listenedSeconds - lastPersistedListeningSeconds >= 15
        guard (flush || reachedPersistenceBoundary), pendingListeningSeconds > 0 else { return }

        listeningHistoryEntries[entryIndex].listenedSeconds += pendingListeningSeconds
        pendingListeningSeconds = 0
        if reachedPersistenceBoundary {
            lastPersistedListeningSeconds = listenedSeconds
            persistListeningHistory()
            scheduleListeningHistorySync()
        }
    }

    private func endListeningSession() {
        updateListeningSession(flush: true)
        if activeListeningEntryID != nil {
            persistListeningHistory()
            scheduleListeningHistorySync()
        }
        activeListeningEntryID = nil
        lastListeningPosition = 0
        lastPersistedListeningSeconds = 0
        pendingListeningSeconds = 0
    }

    private var currentPlaybackPosition: TimeInterval {
        if remoteStreamTrack?.id == currentTrackID, let remoteStreamPlayer {
            let currentTime = remoteStreamPlayer.currentTime().seconds
            if currentTime.isFinite { return max(currentTime, 0) }
        }
        return audioPlayer?.currentTime ?? position
    }

    private func persistListeningHistory() {
        let snapshot = listeningHistoryEntries
        persist(snapshot, key: Self.listeningHistoryKey)
    }

    private func persistPlaybackContext() {
        defaults.set(playbackContextTrackIDs.map(\.uuidString), forKey: Self.playbackContextKey)
    }

    private func persistShuffleQueue() {
        defaults.set(shuffledTrackIDs.map(\.uuidString), forKey: Self.shuffleQueueKey)
    }

    private func persistLibrary() {
        let stored = StoredLibrary(
            tracks: tracks,
            playlists: playlists,
            favorites: favorites,
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: playlistSyncServerURL,
            syncProfileID: syncProfileID,
            syncProfileName: activeSyncProfileName,
            remoteLikedSongIDs: remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs: dirtyRemoteLikeSongIDs,
            likesDirty: likesDirty,
            clipRanges: clipRanges,
            dirtyClipRangeKeys: dirtyClipRangeKeys,
            deletedClipRangeKeys: deletedClipRangeKeys,
            completedMigrations: completedMigrations
        )
        persist(stored, key: Self.libraryKey)
    }

    private func persist<Value: Encodable>(
        _ value: Value,
        key: String
    ) {
        Self.persistenceCoordinator.schedule(value, key: key, defaults: defaults)
    }

    func flushPersistence() {
        Self.persistenceCoordinator.flush()
    }

    private func persistPlaybackPosition() {
        if let currentTrackID {
            defaults.set(currentTrackID.uuidString, forKey: Self.currentTrackKey)
        } else {
            defaults.removeObject(forKey: Self.currentTrackKey)
        }
        defaults.set(position, forKey: Self.positionKey)
        lastPersistedPlaybackPosition = position
    }

    private func persistPlaybackPositionIfNeeded() {
        guard abs(position - lastPersistedPlaybackPosition) >= 5 else { return }
        persistPlaybackPosition()
    }

    func selectSyncProfile(matching query: String) async -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            serverMessage = "Enter a profile name or ID"
            return false
        }
        guard !isSyncingServer,
              !isUploadingServer,
              !isUploadingLocalImport,
              !isSyncingPlaylists else {
            serverMessage = "Wait for the current server transfer or sync to finish"
            return false
        }

        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let request = authenticatedRequest(
                url: base.appendingPathComponent("api/v1/profiles"),
                includeProfile: false
            )
            let (data, response) = try await networkSession.data(for: request)
            try Self.validate(response)
            let payload = try JSONDecoder().decode(SyncProfilesResponse.self, from: data)
            let requestedProfile = Self.syncProfile(matching: trimmed, in: payload.profiles)
            guard let profile = requestedProfile
                ?? payload.profiles.first(where: { $0.id == payload.defaultProfileID })
                ?? payload.profiles.first(where: { $0.isDefault })
            else {
                serverMessage = "Profile “\(trimmed)” was not found"
                return false
            }
            let currentProfileStillExists = payload.profiles.contains { $0.id == syncProfileID }
            if currentProfileStillExists,
               (!dirtyPlaylistIDs.isEmpty || !deletedPlaylistIDs.isEmpty || likesDirty) {
                await syncPlaylistsNow()
                guard dirtyPlaylistIDs.isEmpty, deletedPlaylistIDs.isEmpty, !likesDirty else {
                    serverMessage = "Sync the current profile before switching"
                    return false
                }
            }
            activateSyncProfile(profile)
            if requestedProfile == nil {
                serverMessage = "Profile “\(trimmed)” was not found • Switched to \(profile.name)"
            }
            return true
        } catch {
            serverMessage = "Could not switch profile: \(error.localizedDescription)"
            return false
        }
    }

    nonisolated static func syncProfile(matching query: String, in profiles: [SyncProfile]) -> SyncProfile? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return profiles.first { $0.id == trimmed }
            ?? profiles.first { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }
    }

    private static func fallbackProfileName(for id: String) -> String {
        if id == "default" { return "Default" }
        if id == knownDrasticProfileID { return "Drastic" }
        return id
    }

    private func activateSyncProfile(_ profile: SyncProfile) {
        guard !profile.id.isEmpty else { return }
        activeSyncProfileName = ResonanceEmailPrivacy.safeDisplayName(profile.name, email: accountEmail)
        guard profile.id != syncProfileID else {
            serverMessage = "Using \(profile.name)"
            persistLibrary()
            return
        }

        terminateListenAlongForContextChange("Listen Along ended because the profile changed")
        endListeningSession()
        let oldProfileID = syncProfileID
        let currentTrackBelongsToOldProfile = currentTrack.map {
            $0.remoteID != nil && ($0.syncProfileID ?? "default") == oldProfileID
        } ?? false
        if currentTrackBelongsToOldProfile {
            stopCurrentPlayback()
        }

        playlistSyncDebounceTask?.cancel()
        playlistSyncDebounceTask = nil
        playlistSyncPending = false
        syncProfileID = profile.id
        playlists = playlists.filter(\.isSystem)
        favorites = favorites.filter { trackID in
            tracks.first(where: { $0.id == trackID })?.remoteID == nil
        }
        if let likedIndex = playlists.firstIndex(where: \.isSystem) {
            playlists[likedIndex].trackIDs = visibleTracks.map(\.id).filter(favorites.contains)
            selectedPlaylistID = playlists[likedIndex].id
        }

        playlistRevision = 0
        knownRemotePlaylistIDs.removeAll()
        dirtyPlaylistIDs.removeAll()
        deletedPlaylistIDs.removeAll()
        playlistSyncServerURL = nil
        remoteLikedSongIDs.removeAll()
        dirtyRemoteLikeSongIDs.removeAll()
        playlistMutationGeneration &+= 1
        likesDirty = false
        cancelRemoteSongMetadataHydration()
        serverCatalogRequestGeneration &+= 1
        serverCatalogUploadMutations.removeAll()
        remoteSongs.removeAll()
        remoteCatalogIsAuthoritative = false
        selectedRemoteSongIDs.removeAll()
        resetClientConfigurationForCurrentContext()

        if currentTrackBelongsToOldProfile || currentTrackID.map({ id in
            !visibleTracks.contains(where: { $0.id == id })
        }) == true {
            currentTrackID = visibleTracks.first?.id
            position = 0
            playbackContextTrackIDs = visibleTracks.map(\.id)
            shuffledTrackIDs.removeAll()
        } else {
            playbackContextTrackIDs = playbackContextTrackIDs.filter { id in
                visibleTracks.contains(where: { $0.id == id })
            }
            shuffledTrackIDs = shuffledTrackIDs.filter { id in
                visibleTracks.contains(where: { $0.id == id })
            }
        }

        navigationHistory = [NavigationLocation(section: section, playlistID: selectedPlaylistID)]
        navigationIndex = 0
        serverMessage = "Switched to \(profile.name)"
        persistPlaybackContext()
        persistShuffleQueue()
        persistPlaybackPosition()
        persistLibrary()
        if isPlaying, let currentTrack {
            beginListeningSession(for: currentTrack)
        }
    }

    private func setProfileHeader(on request: inout URLRequest, profileID: String? = nil) {
        request.setValue(profileID ?? syncProfileID, forHTTPHeaderField: "X-Resonance-Profile")
    }

    @discardableResult
    func backfillServerMetadataIfAvailable(base: URL) async throws -> Int {
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else { return 0 }

        let endpoint = base.appendingPathComponent("api/v1/admin/metadata")
        var processedTotal = 0
        var requestsRemaining = 16

        while requestsRemaining > 0 {
            try Task.checkCancellation()
            requestsRemaining -= 1

            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "limit", value: "8")]
            guard let url = components?.url else { throw ServerSyncError.invalidURL }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
            setProfileHeader(on: &request)

            let (data, response) = try await networkSession.data(for: request)
            try Task.checkCancellation()
            try Self.validate(response)
            let result = try JSONDecoder().decode(RemoteMetadataBackfill.self, from: data)
            processedTotal += result.processed
            uploadStatus = "Repairing metadata • \(processedTotal) processed"
            let total = processedTotal + max(result.remaining, 0)
            uploadProgress = total > 0 ? Double(processedTotal) / Double(total) : 1

            if result.remaining <= 0 || result.processed <= 0 {
                break
            }
        }

        return processedTotal
    }

    private func normalizedServerURL() throws -> URL {
        guard let url = ServerEndpointPolicy.normalizedURL(
            serverURLString,
            allowsInsecurePreviewLoopback: Self.isPreviewBundle
        ) else { throw ServerSyncError.invalidURL }
        return url
    }

    private func clientConfigContext(base: URL, accessToken: String) -> MacClientConfigContext {
        let cohortKey = MacClientConfigIdentity.cohortKey(defaults: defaults)
        let buildValue = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let appBuild = max(Int(buildValue ?? "") ?? 1, 1)
        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return MacClientConfigContext(
            origin: ServerSongIdentity.normalizedOrigin(base) ?? base.absoluteString,
            profileID: syncProfileID,
            appVersion: appVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0",
            appBuild: appBuild,
            cohortKey: cohortKey,
            cohortBucket: MacClientConfigContext.cohortBucket(for: cohortKey),
            tokenFingerprint: MacClientConfigContext.tokenFingerprint(accessToken)
        )
    }

    private func applyClientConfigContextHeaders(
        to request: inout URLRequest,
        context: MacClientConfigContext
    ) {
        request.setValue(MacClientConfigContext.platform, forHTTPHeaderField: "X-Resonance-Client-Platform")
        request.setValue(context.appVersion, forHTTPHeaderField: "X-Resonance-App-Version")
        request.setValue(String(context.appBuild), forHTTPHeaderField: "X-Resonance-App-Build")
        request.setValue(context.cohortKey, forHTTPHeaderField: "X-Resonance-Cohort-Key")
        request.setValue(MacClientConfigContext.protocolVersion, forHTTPHeaderField: "X-Resonance-Config-Protocol")
    }

    private func applyCurrentClientConfigHeaders(
        to request: inout URLRequest,
        base: URL,
        fallbackToken: String
    ) {
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityToken = accessToken.isEmpty ? fallbackToken : accessToken
        let context = clientConfigContext(base: base, accessToken: identityToken)
        applyClientConfigContextHeaders(to: &request, context: context)
    }

    private func boundedResponseData(
        for request: URLRequest,
        limit: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, rawResponse) = try await networkSession.bytes(
                for: request,
                delegate: MacRejectRedirectDelegate()
            )
            guard let response = rawResponse as? HTTPURLResponse else {
                throw MacBoundedResponseError.invalidResponse
            }
            if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared > limit {
                throw MacBoundedResponseError.responseTooLarge
            }
            var data = Data()
            data.reserveCapacity(min(limit, 64 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else {
                    throw MacBoundedResponseError.responseTooLarge
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func isJSONResponse(_ response: HTTPURLResponse) -> Bool {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else { return false }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }

    private func applyCachedClientConfiguration(
        context: MacClientConfigContext,
        accessToken: String,
        now: Date = .now
    ) {
        guard let encoded = defaults.data(forKey: context.cacheKey) else {
            applyClientConfiguration(.safeDefaults)
            return
        }
        guard let cached = try? JSONDecoder().decode(MacCachedClientConfig.self, from: encoded),
              cached.context == context,
              now >= cached.cachedAt,
              now.timeIntervalSince(cached.cachedAt) <= MacClientConfigVerifier.maximumLifetime,
              let document = try? MacClientConfigVerifier.verify(
                  body: cached.body,
                  contentDigest: cached.contentDigest,
                  signature: cached.signature,
                  context: context,
                  accessToken: accessToken,
                  now: now
              ) else {
            defaults.removeObject(forKey: context.cacheKey)
            applyClientConfiguration(.safeDefaults)
            return
        }
        let highestVerifiedRevision = defaults.integer(forKey: context.highestRevisionKey)
        guard document.revision >= highestVerifiedRevision else {
            defaults.removeObject(forKey: context.cacheKey)
            applyClientConfiguration(.safeDefaults)
            clientConfigMessage = "Safe defaults • cached configuration revision rolled back"
            return
        }
        defaults.set(max(highestVerifiedRevision, document.revision), forKey: context.highestRevisionKey)
        applyClientConfiguration(.init(document: document, source: .verifiedCache))
    }

    private func isCurrentClientConfigRequest(
        generation: UInt64,
        context: MacClientConfigContext,
        token: String
    ) -> Bool {
        guard generation == clientConfigRequestGeneration,
              context.profileID == syncProfileID,
              let base = try? normalizedServerURL() else { return false }
        let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentToken = accessToken.isEmpty ? adminToken : accessToken
        guard currentToken == token else { return false }
        return clientConfigContext(base: base, accessToken: currentToken) == context
    }

    private func rejectClientConfiguration(context: MacClientConfigContext) {
        defaults.removeObject(forKey: context.cacheKey)
        applyClientConfiguration(.safeDefaults)
        clientConfigMessage = "Safe defaults • signed configuration rejected"
    }

    private func applyClientConfiguration(_ configuration: MacEffectiveClientConfig) {
        clientConfigExpiryTask?.cancel()
        clientConfigExpiryTask = nil
        clientConfiguration = configuration
        clientConfigMessage = configuration.statusText
        restoreTransferModesForCurrentContext()
        if let remoteStreamAuthorizationLease {
            let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let renewed: Bool
            if configuration.allowsStreamOnlyPlayback,
               !accessToken.isEmpty,
               let document = configuration.document,
               let expiration = MacClientConfigVerifier.expirationDate(document),
               let base = try? normalizedServerURL() {
                renewed = remoteStreamAuthorizationLease.renew(
                    context: clientConfigContext(base: base, accessToken: accessToken),
                    expiresAt: expiration
                )
            } else {
                renewed = false
            }
            if !renewed {
                remoteStreamAuthorizationLease.invalidate()
                stopCurrentPlayback()
            }
        }
        if let offlineDownloadAuthorizationLease {
            let accessToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasVerifiedConfiguration = configuration.document != nil
                && (configuration.source == .verifiedServer || configuration.source == .verifiedCache)
            var remainsAuthorized = false
            if configuration.allowsOfflineDownload,
               (!offlineDownloadRequiresVerifiedConfiguration || hasVerifiedConfiguration),
               !accessToken.isEmpty,
               let base = try? normalizedServerURL() {
                remainsAuthorized = MacOfflineDownloadAuthorizationPolicy.remainsAuthorized(
                    lease: offlineDownloadAuthorizationLease,
                    context: clientConfigContext(base: base, accessToken: accessToken),
                    refreshedExpiration: hasVerifiedConfiguration
                        ? configuration.document.flatMap(MacClientConfigVerifier.expirationDate)
                        : nil
                )
            }
            if !remainsAuthorized {
                offlineDownloadAuthorizationLease.invalidate()
            }
        }
        guard let document = configuration.document,
              let expiresAt = MacClientConfigVerifier.expirationDate(document) else { return }
        let delay = expiresAt.timeIntervalSinceNow
        guard delay > 0 else {
            clientConfiguration = .safeDefaults
            clientConfigMessage = "Safe defaults • signed configuration expired"
            restoreTransferModesForCurrentContext()
            return
        }
        let expectedExpiry = document.expiresAt
        let shouldRenew = clientConfigRenewalAttemptedExpiry != expectedExpiry && delay > 5
        let wakeDelay = shouldRenew ? max(delay - min(60, delay / 2), 1) : delay
        clientConfigExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(wakeDelay * 1_000_000_000))
            } catch {
                return
            }
            guard let self,
                  clientConfiguration.document?.expiresAt == expectedExpiry else { return }
            if shouldRenew {
                clientConfigRenewalAttemptedExpiry = expectedExpiry
                await refreshClientConfigurationNow()
                return
            }
            applyClientConfiguration(.safeDefaults)
            clientConfigMessage = "Safe defaults • signed configuration expired"
        }
    }

    private func resetClientConfigurationForCurrentContext() {
        clientConfigRequestGeneration &+= 1
        clientConfigRenewalAttemptedExpiry = nil
        applyClientConfiguration(.safeDefaults)
    }

    private func transferModeScopeForCurrentContext() -> String? {
        guard let base = try? normalizedServerURL(),
              let origin = ServerSongIdentity.normalizedOrigin(base) else { return nil }
        return MacClientConfigContext.transferModeScope(origin: origin, profileID: syncProfileID)
    }

    private func restoreTransferModesForCurrentContext() {
        guard let scope = transferModeScopeForCurrentContext() else {
            uploadMode = .localFile
            downloadMode = .verifiedFileCache
            return
        }
        let storedUpload = defaults.string(forKey: Self.uploadModeKeyPrefix + scope)
            .flatMap(MacUploadMode.init(rawValue:))
        let storedDownload = defaults.string(forKey: Self.downloadModeKeyPrefix + scope)
            .flatMap(MacDownloadMode.init(rawValue:))
        uploadMode = clientConfiguration.resolvedUploadMode(storedUpload)
        downloadMode = clientConfiguration.resolvedDownloadMode(storedDownload)
    }

    private func persistTransferModesForCurrentContext() {
        guard let scope = transferModeScopeForCurrentContext() else { return }
        defaults.set(uploadMode.rawValue, forKey: Self.uploadModeKeyPrefix + scope)
        defaults.set(downloadMode.rawValue, forKey: Self.downloadModeKeyPrefix + scope)
    }

    private func saveServerConfiguration(base: URL) throws {
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServerSyncError.missingToken }
        saveServerURL(base)
        serverToken = token
        if shouldPersistServerCredentials {
            Self.saveServerToken(token)
        }
    }

    private func saveServerURL(_ base: URL) {
        serverURLString = base.absoluteString
        if shouldPersistServerCredentials {
            defaults.set(base.absoluteString, forKey: Self.serverURLKey)
        }
    }

    private static func serverContextKey(base: URL, profileID: String) -> String {
        "\(ServerSongIdentity.normalizedOrigin(base) ?? base.absoluteString)#profile=\(profileID)"
    }

    private static func canonicalServerContextKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let marker = "#profile="
        guard let markerRange = value.range(of: marker) else {
            return ServerSongIdentity.normalizedOrigin(value)
        }
        guard let origin = ServerSongIdentity.normalizedOrigin(String(value[..<markerRange.lowerBound])) else {
            return value
        }
        return origin + String(value[markerRange.lowerBound...])
    }

    private static func originFromServerContextKey(_ value: String?) -> String? {
        guard let value else { return nil }
        if let marker = value.range(of: "#profile=") {
            return ServerSongIdentity.normalizedOrigin(String(value[..<marker.lowerBound]))
        }
        return ServerSongIdentity.normalizedOrigin(value)
    }

    private func activeRemoteIdentity(songID: String) -> ServerSongIdentity? {
        guard let base = try? normalizedServerURL() else { return nil }
        return ServerSongIdentity(serverURL: base, profileID: syncProfileID, songID: songID)
    }

    private func clipRangeKey(for track: Track) -> String {
        if let identity = track.remoteIdentity { return clipRangeKey(identity: identity) }
        return "local:\(track.id.uuidString.lowercased())"
    }

    private func clipRangeKey(identity: ServerSongIdentity) -> String {
        "origin=\(identity.origin)|profile=\(identity.profileID)|remote:\(identity.songID)"
    }

    private func clipRangeKey(remoteID: String) -> String {
        guard let identity = activeRemoteIdentity(songID: remoteID) else {
            return "unscoped|profile=\(syncProfileID)|remote:\(remoteID)"
        }
        return clipRangeKey(identity: identity)
    }

    private func isActiveProfileClipKey(_ key: String) -> Bool {
        guard let base = try? normalizedServerURL(),
              let origin = ServerSongIdentity.normalizedOrigin(base) else { return false }
        return key.hasPrefix("origin=\(origin)|profile=\(syncProfileID)|remote:")
    }

    private func remoteSongID(fromClipKey key: String) -> String? {
        guard let marker = key.range(of: "|remote:"), !key[marker.upperBound...].isEmpty else { return nil }
        return String(key[marker.upperBound...])
    }

    private func playbackBounds(for track: Track, duration: TimeInterval? = nil) -> ClipPlaybackPolicy.Bounds {
        ClipPlaybackPolicy.bounds(range: clipRange(for: track), duration: duration ?? track.duration)
    }

    private func activeRemoteTrack(songID: String) -> Track? {
        guard let identity = activeRemoteIdentity(songID: songID) else { return nil }
        return tracks.first { $0.remoteIdentity == identity }
    }

    private func mergeUploadedServerSong(_ song: RemoteSong, base: URL, profileID: String) {
        let contextKey = Self.serverContextKey(base: base, profileID: profileID)
        serverUploadMutationGeneration &+= 1
        serverCatalogUploadMutations.append(ServerCatalogUploadMutation(
            generation: serverUploadMutationGeneration,
            contextKey: contextKey,
            song: song
        ))
        if serverCatalogUploadMutations.count > 128 {
            serverCatalogUploadMutations.removeFirst(serverCatalogUploadMutations.count - 128)
        }
        guard profileID == syncProfileID,
              let currentBase = try? normalizedServerURL(),
              Self.serverContextKey(base: currentBase, profileID: syncProfileID) == contextKey else {
            return
        }
        remoteSongs = [song] + remoteSongs.filter { $0.id != song.id }
    }

    @discardableResult
    func invalidateRemoteCatalogAuthorityAfterCommittedMutation(
        base: URL,
        profileID: String,
        statusCode: Int
    ) -> Bool {
        guard MacServerCatalogMutationPolicy.didCommit(statusCode: statusCode),
              profileID == syncProfileID,
              let currentBase = try? normalizedServerURL(),
              Self.serverContextKey(base: currentBase, profileID: syncProfileID)
                == Self.serverContextKey(base: base, profileID: profileID) else {
            return false
        }
        // A server mutation may already be durable even when its response body
        // is malformed. Invalidate before decoding so that exact-catalog fast
        // paths cannot keep using a pre-mutation snapshot.
        serverCatalogRequestGeneration &+= 1
        remoteCatalogIsAuthoritative = false
        return true
    }

    private func persistServerCredentialsImmediately() {
        guard shouldPersistServerCredentials else { return }
        defaults.set(serverURLString, forKey: Self.serverURLKey)
        if let accountSession {
            _ = Self.saveAccountSession(accountSession)
            Self.saveServerToken("")
            Self.saveServerToken("", key: Self.adminCredentialKey)
            return
        }
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.saveServerToken(token)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.saveServerToken(adminToken, key: Self.adminCredentialKey)
    }

    func syncPlaylists() {
        playlistSyncTask?.cancel()
        playlistSyncTask = Task { await syncPlaylistsNow() }
    }

    func syncPlaylistsAutomatically() async {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? normalizedServerURL()) != nil else { return }
        await syncPlaylistsNow()
    }

    func syncListeningHistoryAutomatically() async {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? normalizedServerURL()) != nil else { return }
        await syncListeningHistoryNow()
    }

    func syncListeningHistoryNow() async {
        guard !isSyncingListeningHistory else {
            listeningHistorySyncPending = true
            return
        }
        isSyncingListeningHistory = true
        listeningHistorySyncDebounceTask?.cancel()
        listeningHistorySyncDebounceTask = nil
        defer {
            isSyncingListeningHistory = false
            if listeningHistorySyncPending {
                listeningHistorySyncPending = false
                scheduleListeningHistorySync(delay: .zero)
            }
        }

        do {
            let base = try normalizedServerURL()
            let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw ServerSyncError.missingToken }
            let activeProfileID = syncProfileID
            guard let activeOrigin = ServerSongIdentity.normalizedOrigin(base) else {
                throw ServerSyncError.invalidURL
            }
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let localEntries = listeningHistoryEntries.filter {
                $0.originatedOnThisDevice != false
                    && $0.listenedSeconds.isFinite
                    && ListeningHistoryPlayPolicy.qualifies($0, track: tracksByID[$0.trackID])
                    && $0.serverOrigin == activeOrigin
            }
            let profileIDs = Set(localEntries.map { $0.syncProfileID ?? "default" })
                .sorted { left, right in
                    if left == activeProfileID { return true }
                    if right == activeProfileID { return false }
                    return left < right
                }

            var shouldRetry = false
            for profileID in profileIDs {
                let entries = localEntries
                    .filter { ($0.syncProfileID ?? "default") == profileID }
                    .sorted { $0.startedAt < $1.startedAt }
                do {
                    for batchStart in stride(from: 0, to: entries.count, by: 500) {
                        let batchEnd = min(batchStart + 500, entries.count)
                        let pendingEntries = entries[batchStart..<batchEnd].filter { entry in
                            let key = listeningHistorySyncKey(
                                base: base,
                                profileID: profileID,
                                eventID: entry.id
                            )
                            return (listeningHistorySyncedSeconds[key] ?? -1) < entry.listenedSeconds
                        }
                        guard !pendingEntries.isEmpty else { continue }
                        let uploadEntries = pendingEntries.compactMap {
                            listeningHistoryUploadEntry($0, track: tracksByID[$0.trackID])
                        }
                        guard !uploadEntries.isEmpty else { continue }
                        guard try await postListeningHistory(
                            uploadEntries,
                            profileID: profileID,
                            base: base
                        ) else { break }
                        for entry in pendingEntries {
                            listeningHistorySyncedSeconds[listeningHistorySyncKey(
                                base: base,
                                profileID: profileID,
                                eventID: entry.id
                            )] = entry.listenedSeconds
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    shouldRetry = true
                }
            }

            guard let remoteDocument = try await fetchListeningHistory(
                profileID: activeProfileID,
                base: base
            ) else { return }
            guard activeProfileID == syncProfileID,
                  token == serverToken.trimmingCharacters(in: .whitespacesAndNewlines),
                  base == (try? normalizedServerURL()) else {
                listeningHistorySyncPending = true
                return
            }
            mergeRemoteListeningHistory(remoteDocument, profileID: activeProfileID, base: base)
            if shouldRetry { scheduleListeningHistorySync(delay: .seconds(60)) }
        } catch is CancellationError {
            return
        } catch {
            scheduleListeningHistorySync(delay: .seconds(60))
        }
    }

    private func scheduleListeningHistorySync(delay: Duration = .seconds(2)) {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (try? normalizedServerURL()) != nil else { return }
        listeningHistorySyncDebounceTask?.cancel()
        listeningHistorySyncDebounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.listeningHistorySyncDebounceTask = nil
            await self.syncListeningHistoryNow()
        }
    }

    private func listeningHistoryUploadEntry(
        _ entry: ListeningHistoryEntry,
        track: Track?
    ) -> ListeningHistoryUploadEntry? {
        let scopedTrackRemoteID: String? = {
            guard let track, let remoteID = track.remoteID,
                  let entryIdentity = ServerSongIdentity(
                    serverURLString: entry.serverOrigin,
                    profileID: entry.syncProfileID,
                    songID: remoteID
                  ),
                  track.remoteIdentity == entryIdentity else { return nil }
            return remoteID
        }()
        guard let songID = Self.limitedHistoryText(
            entry.remoteSongID ?? scopedTrackRemoteID,
            maximum: 128
        ) else { return nil }
        return ListeningHistoryUploadEntry(
            id: entry.id.uuidString.lowercased(),
            songID: songID,
            startedAt: Self.listeningHistoryTimestamp(entry.startedAt),
            listenedSeconds: min(max(entry.listenedSeconds, 0), 31 * 24 * 60 * 60)
        )
    }

    private func postListeningHistory(
        _ entries: [ListeningHistoryUploadEntry],
        profileID: String,
        base: URL
    ) async throws -> Bool {
        var request = authenticatedRequest(
            url: base.appendingPathComponent("api/v1/listening-history"),
            profileID: profileID
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ListeningHistoryUploadDocument(entries: entries))
        let (data, response) = try await networkSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerSyncError.invalidResponse
        }
        if http.statusCode == 404 || http.statusCode == 405 { return false }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.serverError(status: http.statusCode, data: data)
        }
        return true
    }

    private func fetchListeningHistory(
        profileID: String,
        base: URL
    ) async throws -> RemoteListeningHistoryDocument? {
        var components = URLComponents(
            url: base.appendingPathComponent("api/v1/listening-history"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: "2000")]
        guard let url = components?.url else { throw ServerSyncError.invalidURL }
        let (data, response) = try await networkSession.data(for: authenticatedRequest(
            url: url,
            profileID: profileID
        ))
        guard let http = response as? HTTPURLResponse else {
            throw ServerSyncError.invalidResponse
        }
        if http.statusCode == 404 || http.statusCode == 405 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.serverError(status: http.statusCode, data: data)
        }
        return try JSONDecoder().decode(RemoteListeningHistoryDocument.self, from: data)
    }

    private func mergeRemoteListeningHistory(
        _ document: RemoteListeningHistoryDocument,
        profileID: String,
        base: URL
    ) {
        guard document.profileID == profileID else { return }
        let activeOrigin = ServerSongIdentity.normalizedOrigin(base)
        let tracksByRemoteID: [String: Track] = Dictionary(
            uniqueKeysWithValues: tracks.compactMap { track in
                guard let remoteID = track.remoteID,
                      (track.syncProfileID ?? "default") == profileID,
                      ServerSongIdentity.normalizedOrigin(track.sourceServer)
                        == ServerSongIdentity.normalizedOrigin(base) else { return nil }
                return (remoteID, track) as (String, Track)
            }
        )
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track -> (UUID, Track)? in
            guard track.remoteID == nil
                    || ServerSongIdentity.normalizedOrigin(track.sourceServer) == activeOrigin else {
                return nil
            }
            return (track.id, track)
        })
        let otherContextEntries = listeningHistoryEntries.filter {
            $0.serverOrigin != activeOrigin || ($0.syncProfileID ?? "default") != profileID
        }
        var entriesByID: [UUID: ListeningHistoryEntry] = Dictionary(
            uniqueKeysWithValues: listeningHistoryEntries.compactMap { entry -> (UUID, ListeningHistoryEntry)? in
            guard entry.serverOrigin == activeOrigin,
                  (entry.syncProfileID ?? "default") == profileID else { return nil }
            return (entry.id, entry)
        })

        for remote in document.entries {
            guard let eventID = UUID(uuidString: remote.id),
                  let startedAt = Self.listeningHistoryDate(remote.startedAt) else { continue }
            let mappedTrack = remote.songID.flatMap { tracksByRemoteID[$0] }
                ?? UUID(uuidString: remote.trackID).flatMap { tracksByID[$0] }
            guard let trackID = mappedTrack?.id ?? UUID(uuidString: remote.trackID) else { continue }
            let existing = entriesByID[eventID]
            entriesByID[eventID] = ListeningHistoryEntry(
                id: eventID,
                trackID: mappedTrack?.id ?? existing?.trackID ?? trackID,
                startedAt: existing?.startedAt ?? startedAt,
                listenedSeconds: max(existing?.listenedSeconds ?? 0, remote.listenedSeconds),
                serverOrigin: ServerSongIdentity.normalizedOrigin(base),
                syncProfileID: profileID,
                remoteSongID: remote.songID ?? existing?.remoteSongID ?? mappedTrack?.remoteID,
                title: remote.title ?? existing?.title ?? mappedTrack?.title,
                artist: remote.artist ?? existing?.artist ?? mappedTrack?.artist,
                album: remote.album ?? existing?.album ?? mappedTrack?.album,
                duration: remote.durationSeconds ?? existing?.duration ?? mappedTrack?.duration,
                originatedOnThisDevice: existing?.originatedOnThisDevice ?? false
            )
            listeningHistorySyncedSeconds[listeningHistorySyncKey(
                base: base,
                profileID: profileID,
                eventID: eventID
            )] = remote.listenedSeconds
        }

        let entriesByContext = Dictionary(grouping: otherContextEntries + entriesByID.values) {
            "\($0.serverOrigin ?? "local")#profile=\($0.syncProfileID ?? "default")"
        }
        var boundedEntries: [ListeningHistoryEntry] = []
        for entries in entriesByContext.values {
            boundedEntries.append(contentsOf: entries.sorted { $0.startedAt < $1.startedAt }.suffix(2_000))
        }
        listeningHistoryEntries = boundedEntries.sorted { $0.startedAt < $1.startedAt }
        persistListeningHistory()
    }

    private func listeningHistorySyncKey(
        base: URL,
        profileID: String,
        eventID: UUID
    ) -> String {
        "\(ServerSongIdentity.normalizedOrigin(base) ?? base.absoluteString)#profile=\(profileID)#event=\(eventID.uuidString.lowercased())"
    }

    nonisolated private static func listeningHistoryTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    nonisolated private static func listeningHistoryDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    nonisolated private static func limitedHistoryText(
        _ value: String?,
        maximum: Int
    ) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximum))
    }

    func runAutomaticPlaylistSync() async {
        await reconcileCachedUploadedLocalTracks()
        await syncPlaylistsAutomatically()
        await syncListeningHistoryAutomatically()
        retryPendingRemoteSongMetadata()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await reconcileCachedUploadedLocalTracks()
            await syncPlaylistsAutomatically()
            await syncListeningHistoryAutomatically()
            retryPendingRemoteSongMetadata()
        }
    }

    func syncPlaylistsNow() async {
        guard !isSyncingPlaylists else {
            playlistSyncPending = true
            return
        }
        isSyncingPlaylists = true
        defer {
            isSyncingPlaylists = false
            if playlistSyncPending {
                playlistSyncPending = false
                playlistSyncDebounceTask = Task { [weak self] in
                    await self?.syncPlaylistsNow()
                }
            }
        }

        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let serverKey = Self.serverContextKey(base: base, profileID: syncProfileID)
            let syncToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if playlistSyncServerURL != serverKey {
                playlistSyncServerURL = serverKey
                playlistRevision = 0
                knownRemotePlaylistIDs.removeAll()
                deletedPlaylistIDs.removeAll()
                dirtyPlaylistIDs.formUnion(playlists.filter { !$0.isSystem }.map(\.id))
            }

            playlistSyncStatus = "Syncing playlists…"

            var remoteDocument = try await fetchRemotePlaylists(base: base)
            guard playlistSyncContextMatches(serverKey: serverKey, token: syncToken) else {
                playlistSyncStatus = "Server changed; syncing playlists again…"
                playlistSyncPending = true
                return
            }
            var attempts = 0
            while attempts < 2 {
                let merge = mergedPlaylistDocument(from: remoteDocument)
                if !merge.needsUpload {
                    applyRemotePlaylists(remoteDocument)
                    playlistSyncStatus = "Synced \(remoteDocument.playlists.count) playlist\(remoteDocument.playlists.count == 1 ? "" : "s")"
                    return
                }

                let submittedGeneration = playlistMutationGeneration
                let submittedDirtyIDs = dirtyPlaylistIDs
                let submittedDeletedIDs = deletedPlaylistIDs
                let submittedClipGeneration = clipRangeMutationGeneration
                let submittedDirtyClipKeys = dirtyClipRangeKeys.filter(isActiveProfileClipKey)
                switch try await putRemotePlaylists(merge.document, base: base) {
                case .updated(let updated):
                    guard playlistSyncContextMatches(serverKey: serverKey, token: syncToken) else {
                        playlistSyncStatus = "Server changed; syncing playlists again…"
                        playlistSyncPending = true
                        return
                    }
                    if playlistMutationGeneration == submittedGeneration,
                       clipRangeMutationGeneration == submittedClipGeneration {
                        dirtyPlaylistIDs.subtract(submittedDirtyIDs)
                        deletedPlaylistIDs.subtract(submittedDeletedIDs)
                        likesDirty = false
                        dirtyClipRangeKeys.subtract(submittedDirtyClipKeys)
                        deletedClipRangeKeys.subtract(submittedDirtyClipKeys)
                        applyRemotePlaylists(updated)
                        playlistSyncStatus = "Synced \(updated.playlists.count) playlist\(updated.playlists.count == 1 ? "" : "s")"
                    } else {
                        // The response represents the snapshot that was sent, not newer local
                        // edits. Apply only untouched remote playlists and immediately coalesce
                        // another pass for the remaining local mutations.
                        applyRemotePlaylists(
                            updated,
                            preservingLocalIDs: dirtyPlaylistIDs,
                            preservingLocalLikes: likesDirty,
                            preservingLocalClipKeys: dirtyClipRangeKeys
                        )
                        playlistSyncStatus = "Playlist changes pending sync…"
                        playlistSyncPending = true
                    }
                    return
                case .conflict(let current):
                    guard playlistSyncContextMatches(serverKey: serverKey, token: syncToken) else {
                        playlistSyncStatus = "Server changed; syncing playlists again…"
                        playlistSyncPending = true
                        return
                    }
                    remoteDocument = current
                    attempts += 1
                }
            }

            playlistSyncStatus = "Playlist sync conflicted; try again"
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            playlistSyncStatus = "Playlist sync failed: \(error.localizedDescription)"
        }
    }

    private func playlistSyncContextMatches(serverKey: String, token: String) -> Bool {
        guard serverToken.trimmingCharacters(in: .whitespacesAndNewlines) == token,
              let currentBase = try? normalizedServerURL() else { return false }
        return Self.serverContextKey(base: currentBase, profileID: syncProfileID) == serverKey
            && playlistSyncServerURL == serverKey
    }

    private enum PlaylistPutResult {
        case updated(RemotePlaylistsDocument)
        case conflict(RemotePlaylistsDocument)
    }

    private func fetchRemotePlaylists(base: URL) async throws -> RemotePlaylistsDocument {
        let url = base.appendingPathComponent("api/v1/playlists")
        let (data, response) = try await networkSession.data(for: authenticatedRequest(url: url))
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw ServerSyncError.invalidResponse
        }
        guard status == 200 else { throw Self.serverError(status: status, data: data) }
        return try JSONDecoder().decode(RemotePlaylistsDocument.self, from: data)
    }

    private func putRemotePlaylists(
        _ document: RemotePlaylistsDocument,
        base: URL
    ) async throws -> PlaylistPutResult {
        var request = authenticatedRequest(url: base.appendingPathComponent("api/v1/playlists"))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(document)
        let (data, response) = try await networkSession.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            throw ServerSyncError.invalidResponse
        }
        if status == 200 {
            return .updated(try JSONDecoder().decode(RemotePlaylistsDocument.self, from: data))
        }
        if status == 409 {
            return .conflict(try JSONDecoder().decode(RemotePlaylistsDocument.self, from: data))
        }
        throw Self.serverError(status: status, data: data)
    }

    private static func serverError(status: Int, data: Data) -> ServerSyncError {
        struct ErrorPayload: Decodable { let error: String }
        if let message = try? JSONDecoder().decode(ErrorPayload.self, from: data).error,
           !message.isEmpty {
            return .serverMessage(status, message)
        }
        return .server(status)
    }

    private func mergedPlaylistDocument(
        from remote: RemotePlaylistsDocument
    ) -> (document: RemotePlaylistsDocument, needsUpload: Bool) {
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

        let activeRemoteIDs = Set(visibleTracks.compactMap(\.remoteID))
        let likedSongIDs: [String]
        if likesDirty {
            var mergedLikedSongIDs = remote.likedSongIDs.filter { !activeRemoteIDs.contains($0) }
            let likedTrackOrder = playlists.first(where: \.isSystem)?.trackIDs ?? []
            let orderedFavoriteIDs = likedTrackOrder + favorites.filter { !likedTrackOrder.contains($0) }
            for trackID in orderedFavoriteIDs {
                guard favorites.contains(trackID),
                      let track = visibleTracks.first(where: { $0.id == trackID }),
                      let remoteID = track.remoteID,
                      !mergedLikedSongIDs.contains(remoteID) else { continue }
                mergedLikedSongIDs.append(remoteID)
            }
            likedSongIDs = mergedLikedSongIDs
        } else {
            likedSongIDs = remote.likedSongIDs
        }

        var remoteClipRanges = remote.clipRanges.reduce(into: [String: ClipRange]()) { result, payload in
            result[payload.songID] = ClipRange(
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
            RemotePlaylistsDocument(
                profileID: syncProfileID,
                revision: remote.revision,
                playlists: merged,
                likedSongIDs: likedSongIDs,
                clipRanges: remoteClipRanges.map {
                    RemoteClipRange(
                        songID: $0.key,
                        startSeconds: $0.value.startSeconds,
                        endSeconds: $0.value.endSeconds
                    )
                }
            ),
            needsUpload || !activeDirtyClipKeys.isEmpty
        )
    }

    private func remotePlaylist(from playlist: Playlist) -> RemotePlaylist {
        var songIDs: [String] = []
        for trackID in playlist.trackIDs {
            guard let track = tracks.first(where: { $0.id == trackID }),
                  let remoteID = track.remoteID,
                  track.remoteIdentity == activeRemoteIdentity(songID: remoteID),
                  !songIDs.contains(remoteID) else { continue }
            songIDs.append(remoteID)
        }
        let previousRemoteSongIDs = playlist.remoteSongIDs ?? []
        let unresolvedRemoteSongIDs = previousRemoteSongIDs.filter { remoteID in
            activeRemoteTrack(songID: remoteID) == nil
        }
        songIDs = PlaylistOrderPolicy.merge(
            previous: previousRemoteSongIDs,
            ordered: songIDs,
            preserving: unresolvedRemoteSongIDs
        )
        return RemotePlaylist(id: playlist.id, name: playlist.name, songIDs: songIDs)
    }

    private func applyRemotePlaylists(
        _ document: RemotePlaylistsDocument,
        preservingLocalIDs: Set<UUID> = [],
        preservingLocalLikes: Bool = false,
        preservingLocalClipKeys: Set<String> = []
    ) {
        let existing = Dictionary(uniqueKeysWithValues: playlists.filter { !$0.isSystem }.map { ($0.id, $0) })
        let systemPlaylists = playlists.filter(\.isSystem)
        let existingLikedOrder = systemPlaylists.first(where: \.isSystem)?.trackIDs ?? []
        let styles: [ArtworkStyle] = [.lateNight, .softFocus, .onRepeat, .electric, .golden, .falling]
        var syncedPlaylists = document.playlists.enumerated().compactMap { offset, remote -> Playlist? in
            guard !deletedPlaylistIDs.contains(remote.id) else { return nil }
            if preservingLocalIDs.contains(remote.id), let local = existing[remote.id] {
                return local
            }
            let localOnlyTrackIDs = existing[remote.id]?.trackIDs.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            } ?? []
            let downloadedTrackIDs = remote.songIDs.compactMap { remoteID in
                activeRemoteTrack(songID: remoteID)?.id
            }
            return Playlist(
                id: remote.id,
                name: remote.name,
                artwork: existing[remote.id]?.artwork ?? styles[offset % styles.count],
                trackIDs: PlaylistOrderPolicy.merge(
                    previous: existing[remote.id]?.trackIDs ?? [],
                    ordered: downloadedTrackIDs,
                    preserving: localOnlyTrackIDs
                ),
                remoteSongIDs: remote.songIDs,
                entryOrder: existing[remote.id]?.entryOrder
            )
        }
        let remoteIDs = Set(document.playlists.map(\.id))
        syncedPlaylists.append(contentsOf: playlists.filter { playlist in
            !playlist.isSystem
                && preservingLocalIDs.contains(playlist.id)
                && !remoteIDs.contains(playlist.id)
                && !deletedPlaylistIDs.contains(playlist.id)
        })

        playlists = systemPlaylists + syncedPlaylists
        var preferredRemoteFavoriteOrder: [UUID] = []
        if !preservingLocalLikes {
            let localFavorites = favorites.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            }
            preferredRemoteFavoriteOrder = document.likedSongIDs.compactMap { remoteID in
                activeRemoteTrack(songID: remoteID)?.id
            }
            favorites = Set(localFavorites).union(preferredRemoteFavoriteOrder)
            likesDirty = false
        }

        if let likedIndex = playlists.firstIndex(where: \.isSystem) {
            var orderedFavorites = existingLikedOrder.filter(favorites.contains)
            for trackID in preferredRemoteFavoriteOrder + visibleTracks.map(\.id)
            where favorites.contains(trackID) && !orderedFavorites.contains(trackID) {
                orderedFavorites.append(trackID)
            }
            playlists[likedIndex].trackIDs = orderedFavorites
        }

        let activePreservedClipKeys = preservingLocalClipKeys.filter(isActiveProfileClipKey)
        clipRanges = clipRanges.filter { key, _ in
            !isActiveProfileClipKey(key) || activePreservedClipKeys.contains(key)
        }
        for payload in document.clipRanges {
            let key = clipRangeKey(remoteID: payload.songID)
            guard !activePreservedClipKeys.contains(key),
                  !deletedClipRangeKeys.contains(key),
                  payload.endSeconds - payload.startSeconds >= ClipRangePolicy.minimumDuration else { continue }
            clipRanges[key] = ClipRange(
                startSeconds: payload.startSeconds,
                endSeconds: payload.endSeconds
            )
        }

        playlistRevision = document.revision
        knownRemotePlaylistIDs = Set(document.playlists.map(\.id))
        if let selectedPlaylistID, !playlists.contains(where: { $0.id == selectedPlaylistID }) {
            self.selectedPlaylistID = nil
            section = .playlists
        }
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
    }

    private func hydrateRemotePlaylistTracks() {
        for index in playlists.indices where !playlists[index].isSystem {
            guard let remoteSongIDs = playlists[index].remoteSongIDs else { continue }
            let localOnlyTrackIDs = playlists[index].trackIDs.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            }
            let hydrated = remoteSongIDs.compactMap { remoteID in
                activeRemoteTrack(songID: remoteID)?.id
            }
            playlists[index].trackIDs = PlaylistOrderPolicy.merge(
                previous: playlists[index].trackIDs,
                ordered: hydrated,
                preserving: localOnlyTrackIDs
            )
        }
    }

    private func updateRemoteSongIDs(forPlaylistAt index: Int) {
        guard playlists.indices.contains(index), !playlists[index].isSystem else { return }
        let previouslyUnresolved = (playlists[index].remoteSongIDs ?? []).filter { remoteID in
            activeRemoteTrack(songID: remoteID) == nil
        }
        let ordered: [String] = playlists[index].trackIDs.compactMap { trackID in
            guard let track = tracks.first(where: { $0.id == trackID }),
                  let remoteID = track.remoteID,
                  track.remoteIdentity == activeRemoteIdentity(songID: remoteID) else { return nil }
            return remoteID
        }
        playlists[index].remoteSongIDs = PlaylistOrderPolicy.merge(
            previous: playlists[index].remoteSongIDs ?? [],
            ordered: ordered,
            preserving: previouslyUnresolved
        )
    }

    private func markPlaylistDirty(_ playlistID: UUID) {
        playlistMutationGeneration &+= 1
        deletedPlaylistIDs.remove(playlistID)
        dirtyPlaylistIDs.insert(playlistID)
    }

    private func markPlaylistDeleted(_ playlistID: UUID) {
        playlistMutationGeneration &+= 1
        dirtyPlaylistIDs.remove(playlistID)
        // Keep a tombstone even for a playlist created during an in-flight PUT.
        // The accepted snapshot may have created it on the server already.
        deletedPlaylistIDs.insert(playlistID)
    }

    private func schedulePlaylistSync() {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isSyncingPlaylists {
            playlistSyncPending = true
            return
        }
        playlistSyncDebounceTask?.cancel()
        playlistSyncDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncPlaylistsNow()
        }
    }

    private func fetchRemoteCatalog(base: URL) async throws -> [RemoteSong] {
        let url = base.appendingPathComponent("api/v1/songs")
        let (data, response) = try await networkSession.data(for: authenticatedRequest(url: url))
        try Self.validate(response)
        return try JSONDecoder().decode(RemoteCatalog.self, from: data).songs
    }

    func repairLegacyRemoteSourceLinks(in songs: [RemoteSong], base: URL) async -> Bool {
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else { return false }
        let profileID = syncProfileID
        var repairedAny = false

        for song in songs where song.isSourceLinkRecord && song.requiresOriginalSourcePage {
            guard let remoteIdentity = ServerSongIdentity(
                serverURL: base,
                profileID: profileID,
                songID: song.id
            ),
            let local = tracks.first(where: { track in
                guard track.remoteIdentity == remoteIdentity,
                      let source = track.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let url = URL(string: source),
                      url.scheme?.lowercased() == "https",
                      url.user == nil,
                      url.password == nil else { return false }
                let host = url.host?.lowercased() ?? ""
                return host != "googlevideo.com"
                    && !host.hasSuffix(".googlevideo.com")
                    && url.lastPathComponent.lowercased() != "videoplayback"
            }),
            let sourceURL = local.sourceURL else { continue }

            do {
                let songID = try Self.validatedRemoteSongIdentifier(song.id)
                let endpoint = base
                    .appendingPathComponent("api/v1/admin/songs", isDirectory: true)
                    .appendingPathComponent(songID, isDirectory: false)
                var request = URLRequest(url: endpoint)
                request.httpMethod = "PATCH"
                request.httpBody = try JSONEncoder().encode(SourceLinkUploadDocument(
                    sourceURL: sourceURL,
                    mediaKind: local.kind == .video ? "video" : "audio"
                ))
                request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                setProfileHeader(on: &request, profileID: profileID)
                applyCurrentClientConfigHeaders(to: &request, base: base, fallbackToken: adminToken)
                let (_, response) = try await networkSession.data(for: request)
                try Self.validate(response)
                repairedAny = true
            } catch {
                // The local metadata remains usable. A future refresh can retry
                // after the compatible server route is deployed.
            }
        }
        return repairedAny
    }

    private func remoteSourceResolution(
        for song: RemoteSong,
        base: URL,
        profileID: String,
        metadataOverride: LocalImportMetadata? = nil
    ) async throws -> LocalImportResolution {
        guard let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { throw ServerSyncError.missingSourceLink }
        let mediaMode: LocalImportMediaMode = song.mediaKind == "video" ? .video : .audio
        let serverContext = Self.serverContextKey(base: base, profileID: profileID)
        let key = MacRemoteSourceResolutionCachePolicy.key(
            serverContext: serverContext,
            source: source,
            mediaMode: mediaMode
        )
        if let cached = remoteSourceResolutions[key],
           MacRemoteSourceResolutionCachePolicy.isReusable(
            cached,
            key: key,
            serverContext: serverContext,
            song: song,
            mediaMode: mediaMode
           ) {
            return cached
        }
        remoteSourceResolutions.removeValue(forKey: key)
        let provider: String
        let providerID: String
        if LocalImportURL.isSpotify(source) {
            provider = "spotify"
            providerID = (try? LocalImportURL.spotifyTrack(source)?.trackID) ?? song.id
        } else if LocalImportURL.isSoundCloud(source) {
            provider = "soundcloud"
            providerID = song.id
        } else {
            provider = "youtube"
            providerID = (try? LocalImportURL.youtubeVideoID(source)) ?? song.id
        }
        let knownMetadata = LocalImportSpotifyTrack(
            provider: provider,
            type: "track",
            trackID: providerID,
            title: metadataOverride?.title ?? song.title,
            artist: metadataOverride?.artist ?? song.artist,
            album: metadataOverride?.album ?? song.album,
            trackNumber: nil,
            durationSeconds: song.durationSeconds.map { Int($0.rounded()) },
            artworkURL: metadataOverride?.artworkURL ?? song.artworkURL,
            embedURL: "",
            sourceURL: source
        )
        let progress: LocalImportProgressHandler = { _ in }
        let resolution = try await serverLinkImportService.resolveSavedDownload(
            source: source,
            metadata: knownMetadata,
            mediaMode: mediaMode,
            preparationContext: serverContext,
            progress: progress
        )
        guard resolution.playlist == nil else { throw ServerSyncError.invalidMedia }
        remoteSourceResolutions[key] = resolution
        return resolution
    }

    private func beginRemoteSongMetadataHydration(contextKey: String) {
        let requests = remoteSongMetadataRequests(for: remoteSongs)
        let requestKeys = Set(requests.map(\.cacheKey))
        if serverMetadataHydrationTask != nil,
           MacRemoteMetadataHydrationPolicy.canReuse(
            activeContext: serverMetadataHydrationContextKey,
            activeRequestKeys: serverMetadataHydrationRequestKeys,
            requestedContext: contextKey,
            requestedRequestKeys: requestKeys
           ) {
            return
        }
        let preservesSharedTasks = serverMetadataHydrationContextKey == contextKey
        cancelRemoteSongMetadataHydration(cancelSharedTasks: !preservesSharedTasks)
        pendingRemoteSongMetadataCount = requests.reduce(0) { $0 + $1.songIDs.count }
        guard !requests.isEmpty else { return }

        serverMetadataHydrationGeneration &+= 1
        serverMetadataHydrationContextKey = contextKey
        serverMetadataHydrationRequestKeys = requestKeys
        let generation = serverMetadataHydrationGeneration
        let resolver = remoteSongMetadataResolver
        let retryDelays = remoteSongMetadataRetryDelays
        serverMetadataHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await hydrateRemoteSongMetadata(
                requests,
                using: resolver,
                retryDelays: retryDelays,
                generation: generation,
                contextKey: contextKey
            )
        }
    }

    private func prepareRemoteSongMetadataForDownload(
        _ songs: [RemoteSong],
        contextKey: String
    ) async -> [RemoteSong] {
        let requests = remoteSongMetadataRequests(for: songs)
        guard !requests.isEmpty else { return songs }

        let resolver = remoteSongMetadataResolver
        let retryDelays = remoteSongMetadataRetryDelays
        var results: [RemoteSongMetadataResult] = []
        await withTaskGroup(of: RemoteSongMetadataResult.self) { group in
            var iterator = requests.makeIterator()
            for _ in 0..<min(8, requests.count) {
                guard let request = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else {
                        return RemoteSongMetadataResult(request: request, metadata: nil)
                    }
                    return await self.sharedRemoteSongMetadataResult(
                        request,
                        contextKey: contextKey,
                        using: resolver,
                        retryDelays: retryDelays
                    )
                }
            }
            while let result = await group.next() {
                guard let base = try? normalizedServerURL(),
                      Self.serverContextKey(base: base, profileID: syncProfileID) == contextKey else {
                    group.cancelAll()
                    return
                }
                results.append(result)
                if let request = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else {
                            return RemoteSongMetadataResult(request: request, metadata: nil)
                        }
                        return await self.sharedRemoteSongMetadataResult(
                            request,
                            contextKey: contextKey,
                            using: resolver,
                            retryDelays: retryDelays
                        )
                    }
                }
            }
        }

        guard let base = try? normalizedServerURL(),
              Self.serverContextKey(base: base, profileID: syncProfileID) == contextKey else {
            return songs
        }
        var updatedSongs = remoteSongs
        var cacheChanged = false
        for result in results {
            cacheChanged = applyRemoteSongMetadataResult(result, to: &updatedSongs) || cacheChanged
        }
        remoteSongs = updatedSongs
        if cacheChanged { persistRemoteSongMetadataCache() }
        let requestedIDs = Set(songs.map(\.id))
        let preparedByID = Dictionary(uniqueKeysWithValues: remoteSongs
            .filter { requestedIDs.contains($0.id) }
            .map { ($0.id, $0) })
        return songs.map { preparedByID[$0.id] ?? $0 }
    }

    private func sharedRemoteSongMetadataResult(
        _ request: RemoteSongMetadataRequest,
        contextKey: String,
        using resolver: @escaping RemoteSongMetadataResolver,
        retryDelays: [Duration]
    ) async -> RemoteSongMetadataResult {
        let key = "\(contextKey)\u{1f}\(request.cacheKey)"
        if let shared = sharedRemoteSongMetadataTasks[key] {
            return await shared.task.value
        }
        let id = UUID()
        let task = Task {
            await Self.resolveRemoteSongMetadata(
                request,
                using: resolver,
                retryDelays: retryDelays
            )
        }
        sharedRemoteSongMetadataTasks[key] = SharedRemoteSongMetadataTask(id: id, task: task)
        let result = await task.value
        // Keep successful completed work available to later songs in the same
        // exact server/profile batch. Failed tasks are evicted so retry can
        // make a fresh request.
        if result.metadata == nil,
           sharedRemoteSongMetadataTasks[key]?.id == id {
            sharedRemoteSongMetadataTasks.removeValue(forKey: key)
        }
        return result
    }

    func retryPendingRemoteSongMetadata() {
        guard serverMetadataHydrationTask == nil,
              remoteSongs.contains(where: \.isMetadataLoading),
              let base = try? normalizedServerURL() else { return }
        beginRemoteSongMetadataHydration(
            contextKey: Self.serverContextKey(base: base, profileID: syncProfileID)
        )
    }

    private func hydrateRemoteSongMetadata(
        _ requests: [RemoteSongMetadataRequest],
        using resolver: @escaping RemoteSongMetadataResolver,
        retryDelays: [Duration],
        generation: UInt64,
        contextKey: String
    ) async {
        var remainingCount = requests.reduce(0) { $0 + $1.songIDs.count }
        var didUpdateMetadataCache = false
        defer {
            if didUpdateMetadataCache {
                persistRemoteSongMetadataCache()
            }
            if serverMetadataHydrationGeneration == generation {
                pendingRemoteSongMetadataCount = 0
                serverMetadataHydrationTask = nil
                serverMetadataHydrationContextKey = nil
                serverMetadataHydrationRequestKeys.removeAll()
            }
        }

        await withTaskGroup(of: RemoteSongMetadataResult.self) { group in
            var iterator = requests.makeIterator()
            var bufferedResults: [RemoteSongMetadataResult] = []
            for _ in 0..<min(4, requests.count) {
                guard let request = iterator.next() else { break }
                group.addTask { [weak self] in
                    guard let self else {
                        return RemoteSongMetadataResult(request: request, metadata: nil)
                    }
                    return await self.sharedRemoteSongMetadataResult(
                        request,
                        contextKey: contextKey,
                        using: resolver,
                        retryDelays: retryDelays
                    )
                }
            }

            while let result = await group.next() {
                guard isCurrentRemoteMetadataHydration(generation: generation, contextKey: contextKey) else {
                    group.cancelAll()
                    return
                }
                bufferedResults.append(result)
                remainingCount = max(0, remainingCount - result.request.songIDs.count)
                if bufferedResults.count >= 4 || remainingCount == 0 {
                    var updatedSongs = remoteSongs
                    for bufferedResult in bufferedResults {
                        didUpdateMetadataCache = applyRemoteSongMetadataResult(
                            bufferedResult,
                            to: &updatedSongs
                        ) || didUpdateMetadataCache
                    }
                    remoteSongs = updatedSongs
                    pendingRemoteSongMetadataCount = remainingCount
                    bufferedResults.removeAll(keepingCapacity: true)
                }

                if let request = iterator.next() {
                    group.addTask { [weak self] in
                        guard let self else {
                            return RemoteSongMetadataResult(request: request, metadata: nil)
                        }
                        return await self.sharedRemoteSongMetadataResult(
                            request,
                            contextKey: contextKey,
                            using: resolver,
                            retryDelays: retryDelays
                        )
                    }
                }
            }
        }
    }

    private func applyingKnownRemoteSongMetadata(to songs: [RemoteSong]) -> [RemoteSong] {
        let localTracksByRemoteID = tracks.reduce(into: [String: Track]()) { result, track in
            guard let remoteID = track.remoteID,
                  track.remoteIdentity == activeRemoteIdentity(songID: remoteID),
                  result[remoteID] == nil else { return }
            result[remoteID] = track
        }

        return songs.map { song in
            guard song.isMetadataLoading else { return song }
            if song.requiresOriginalSourcePage {
                return Self.applyingLegacyRemoteMetadataFailure(to: song)
            }
            if let localTrack = localTracksByRemoteID[song.id] {
                var updated = song
                updated.title = localTrack.title
                updated.artist = localTrack.artist
                updated.album = localTrack.album
                updated.durationSeconds = localTrack.duration
                updated.isMetadataLoading = false
                return updated
            }
            guard let cacheKey = remoteSongMetadataCacheKey(for: song) else { return song }
            if let cached = remoteSongMetadataCache[cacheKey],
               cached.cachedAt >= Date().addingTimeInterval(-Self.remoteSongMetadataCacheLifetime) {
                return Self.applying(cached.metadata, to: song)
            }
            guard let source = song.sourceURL,
                  let base = try? normalizedServerURL() else { return song }
            let mediaMode: LocalImportMediaMode = song.mediaKind == "video" ? .video : .audio
            let serverContext = Self.serverContextKey(base: base, profileID: syncProfileID)
            let resolutionKey = MacRemoteSourceResolutionCachePolicy.key(
                serverContext: serverContext,
                source: source,
                mediaMode: mediaMode
            )
            guard let resolution = remoteSourceResolutions[resolutionKey],
                  MacRemoteSourceResolutionCachePolicy.isReusable(
                    resolution,
                    key: resolutionKey,
                    serverContext: serverContext,
                    song: song,
                    mediaMode: mediaMode
                  ) else { return song }
            return Self.applying(resolution.track, to: song)
        }
    }

    private func applyingCurrentRemoteSongMetadata(to songs: [RemoteSong]) -> [RemoteSong] {
        MacServerDownloadMetadataPolicy.reusingKnownMetadata(
            in: songs,
            knownSongs: remoteSongs,
            catalogIsAuthoritative: remoteCatalogIsAuthoritative
        )
    }

    private func remoteSongMetadataRequests(for songs: [RemoteSong]) -> [RemoteSongMetadataRequest] {
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
                    mediaMode: existing.mediaMode
                )
            } else {
                requestIndexByCacheKey[cacheKey] = requests.count
                requests.append(RemoteSongMetadataRequest(
                    songIDs: [song.id],
                    cacheKey: cacheKey,
                    source: source,
                    mediaMode: song.mediaKind == "video" ? .video : .audio
                ))
            }
        }
        return requests
    }

    private func applyRemoteSongMetadataResult(
        _ result: RemoteSongMetadataResult,
        to songs: inout [RemoteSong]
    ) -> Bool {
        if let metadata = result.metadata {
            remoteSongMetadataCache[result.request.cacheKey] = CachedRemoteSongMetadata(
                metadata: metadata,
                cachedAt: Date()
            )
        }
        let songIDs = Set(result.request.songIDs)
        for index in songs.indices where songIDs.contains(songs[index].id) && songs[index].isMetadataLoading {
            if let metadata = result.metadata {
                songs[index] = Self.applying(metadata, to: songs[index])
            } else if songs[index].requiresOriginalSourcePage {
                songs[index] = Self.applyingLegacyRemoteMetadataFailure(to: songs[index])
            }
        }
        return result.metadata != nil
    }

    private func remoteSongMetadataCacheKey(for song: RemoteSong) -> String? {
        guard let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        let mediaMode: LocalImportMediaMode = song.mediaKind == "video" ? .video : .audio
        return "\(mediaMode.rawValue):\(source)"
    }

    private func isCurrentRemoteMetadataHydration(generation: UInt64, contextKey: String) -> Bool {
        guard generation == serverMetadataHydrationGeneration,
              let base = try? normalizedServerURL() else { return false }
        return Self.serverContextKey(base: base, profileID: syncProfileID) == contextKey
    }

    private func cancelRemoteSongMetadataHydration(cancelSharedTasks: Bool = true) {
        serverMetadataHydrationTask?.cancel()
        serverMetadataHydrationTask = nil
        serverMetadataHydrationGeneration &+= 1
        serverMetadataHydrationContextKey = nil
        serverMetadataHydrationRequestKeys.removeAll()
        if cancelSharedTasks {
            for shared in sharedRemoteSongMetadataTasks.values {
                shared.task.cancel()
            }
            sharedRemoteSongMetadataTasks.removeAll()
        }
        pendingRemoteSongMetadataCount = 0
    }

    nonisolated private static func resolveRemoteSongMetadata(
        _ request: RemoteSongMetadataRequest,
        using resolver: @escaping RemoteSongMetadataResolver,
        retryDelays: [Duration]
    ) async -> RemoteSongMetadataResult {
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                let metadata = try await resolver(request.source, request.mediaMode)
                try Task.checkCancellation()
                return RemoteSongMetadataResult(
                    request: request,
                    metadata: metadata
                )
            } catch {
                guard !Task.isCancelled, attempt < retryDelays.count else {
                    return RemoteSongMetadataResult(request: request, metadata: nil)
                }
                do {
                    try await Task.sleep(for: retryDelays[attempt])
                } catch {
                    return RemoteSongMetadataResult(request: request, metadata: nil)
                }
            }
        }
        return RemoteSongMetadataResult(request: request, metadata: nil)
    }

    nonisolated private static func applying(
        _ metadata: LocalImportSpotifyTrack,
        to song: RemoteSong
    ) -> RemoteSong {
        var updated = song
        updated.title = metadata.title
        updated.artist = metadata.artist
        updated.album = metadata.album ?? "Imported"
        updated.durationSeconds = metadata.durationSeconds.map(TimeInterval.init)
        updated.artworkURL = metadata.artworkURL
        updated.isMetadataLoading = false
        return updated
    }

    nonisolated private static func applyingLegacyRemoteMetadataFailure(to song: RemoteSong) -> RemoteSong {
        var updated = song
        updated.title = "Original source link needed"
        updated.artist = "Re-import on the original device"
        updated.album = "Legacy expired link"
        updated.isMetadataLoading = false
        return updated
    }

    @discardableResult
    private func importSavedRemoteSource(
        _ remote: RemoteSong,
        base: URL,
        profileID: String,
        authorizationLease: MacAuthenticatedStreamAuthorizationLease,
        authorizationRefresh: Task<Void, Never>?,
        stateGeneration: UInt64,
        transferGeneration: UInt64
    ) async throws -> Track {
        guard let source = remote.sourceURL else { throw ServerSyncError.invalidMedia }
        let mediaMode: LocalImportMediaMode = remote.mediaKind == "video" ? .video : .audio
        let preparationContext = Self.serverContextKey(base: base, profileID: profileID)
        let metadataEnrichment: LocalImportMetadataEnrichment?
        if remote.isMetadataLoading,
           let cacheKey = remoteSongMetadataCacheKey(for: remote) {
            let request = RemoteSongMetadataRequest(
                songIDs: [remote.id],
                cacheKey: cacheKey,
                source: source,
                mediaMode: mediaMode
            )
            let resolver = remoteSongMetadataResolver
            let retryDelays = remoteSongMetadataRetryDelays
            metadataEnrichment = LocalImportMetadataEnrichment { [weak self] in
                guard let self else { return nil }
                let result = await self.sharedRemoteSongMetadataResult(
                    request,
                    contextKey: preparationContext,
                    using: resolver,
                    retryDelays: retryDelays
                )
                guard !Task.isCancelled, let resolved = result.metadata else { return nil }
                return LocalImportMetadata(
                    title: resolved.title,
                    artist: resolved.artist,
                    album: resolved.album,
                    artworkURL: resolved.artworkURL,
                    sourceURL: source
                )
            }
        } else {
            metadataEnrichment = nil
        }
        defer { metadataEnrichment?.cancel() }
        let resolutionMetadata: LocalImportMetadata?
        if remote.isMetadataLoading, LocalImportURL.isSpotify(source) {
            resolutionMetadata = await metadataEnrichment?.value()
        } else {
            resolutionMetadata = nil
        }
        try Task.checkCancellation()
        let resolution = try await remoteSourceResolution(
            for: remote,
            base: base,
            profileID: profileID,
            metadataOverride: resolutionMetadata
        )
        guard let candidate = resolution.candidates.first else { throw ServerSyncError.invalidMedia }
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
            metadataEnrichment: metadataEnrichment,
            finalizeAuthorization: {
                try await Self.awaitServerDownloadAuthorizationRefresh(authorizationRefresh)
                try authorizationLease.authorize()
                try Task.checkCancellation()
            },
            existingTracks: tracks,
            mediaMode: mediaMode,
            preparationContext: preparationContext
        ) { [weak self] progress in
            if progress.stage == .downloading {
                self?.downloadStatus = "Downloading \(remote.title)"
                self?.publishServerDownloadTransfer(
                    completedBytes: progress.completed,
                    totalBytes: progress.total,
                    stateGeneration: stateGeneration,
                    transferGeneration: transferGeneration
                )
            } else if progress.stage == .processing
                || progress.stage == .savingLocal
                || progress.stage == .localComplete {
                self?.releaseServerDownloadTransfer(
                    stateGeneration: stateGeneration,
                    transferGeneration: transferGeneration
                )
            }
        }
        releaseServerDownloadTransfer(
            stateGeneration: stateGeneration,
            transferGeneration: transferGeneration
        )
        do {
            try await Self.awaitServerDownloadAuthorizationRefresh(authorizationRefresh)
            try authorizationLease.authorize()
        } catch {
            if case .created(let imported) = outcome {
                try? FileManager.default.removeItem(at: imported.fileURL)
            }
            throw error
        }
        let track: Track
        switch outcome {
        case .created(let imported):
            track = insertLocalImportedAudio(imported)
        case .duplicate(let id, let sourceAssociation):
            guard let duplicate = tracks.first(where: { $0.id == id }) else {
                throw ServerSyncError.invalidMedia
            }
            track = associateLocalImportSource(trackID: id, source: sourceAssociation) ?? duplicate
        }
        _ = reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: remote.id,
            sourceServer: ServerSongIdentity.normalizedOrigin(base),
            profileID: profileID
        )
        return tracks.first(where: { $0.id == track.id }) ?? track
    }

    @discardableResult
    func reconcileUploadedLocalTrackForImport(
        trackID: UUID,
        remoteID: String,
        sourceServer: String? = nil,
        profileID: String? = nil
    ) throws -> Bool {
        let resolvedProfileID = profileID ?? syncProfileID
        let resolvedSourceServer = ServerSongIdentity.normalizedOrigin(sourceServer)
            ?? (try? normalizedServerURL()).flatMap(ServerSongIdentity.normalizedOrigin)
        if let track = tracks.first(where: { $0.id == trackID }),
           Self.hasConflictingRemoteAssociation(
               track,
               targetOrigin: resolvedSourceServer,
               targetProfileID: resolvedProfileID
           ) {
            throw LocalImportTransferContextError.remoteAssociationConflict
        }
        return reconcileUploadedLocalTrack(
            trackID: trackID,
            remoteID: remoteID,
            sourceServer: resolvedSourceServer,
            profileID: resolvedProfileID
        )
    }

    @discardableResult
    func reconcileUploadedLocalTrack(
        trackID: UUID,
        remoteID: String,
        sourceServer: String? = nil,
        profileID: String? = nil
    ) -> Bool {
        let resolvedRemoteID = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedRemoteID.isEmpty,
              let targetIndex = tracks.firstIndex(where: { $0.id == trackID }) else { return false }
        let previousRemoteID = tracks[targetIndex].remoteID
        let resolvedProfileID = profileID ?? syncProfileID
        let resolvedSourceServer = ServerSongIdentity.normalizedOrigin(sourceServer)
            ?? (try? normalizedServerURL()).flatMap(ServerSongIdentity.normalizedOrigin)
        if Self.hasConflictingRemoteAssociation(
            tracks[targetIndex],
            targetOrigin: resolvedSourceServer,
            targetProfileID: resolvedProfileID
        ) {
            serverMessage = LocalImportTransferContextError.remoteAssociationConflict.localizedDescription
            return false
        }
        let resolvedIdentity = ServerSongIdentity(
            serverURLString: resolvedSourceServer,
            profileID: resolvedProfileID,
            songID: resolvedRemoteID
        )
        let duplicateIDs = Set(tracks.compactMap { candidate -> UUID? in
            guard candidate.id != trackID,
                  let resolvedIdentity,
                  candidate.remoteIdentity == resolvedIdentity else { return nil }
            return candidate.id
        })
        let identityChanged = tracks[targetIndex].remoteID != resolvedRemoteID
            || tracks[targetIndex].syncProfileID != resolvedProfileID
            || tracks[targetIndex].sourceServer != resolvedSourceServer
        guard identityChanged || !duplicateIDs.isEmpty else { return false }

        if let duplicate = tracks.first(where: { duplicateIDs.contains($0.id) }) {
            if tracks[targetIndex].artworkData == nil { tracks[targetIndex].artworkData = duplicate.artworkData }
            if tracks[targetIndex].fileURL == nil { tracks[targetIndex].fileURL = duplicate.fileURL }
        }
        tracks[targetIndex].remoteID = resolvedRemoteID
        tracks[targetIndex].syncProfileID = resolvedProfileID
        tracks[targetIndex].sourceServer = resolvedSourceServer

        let remap: ([UUID]) -> [UUID] = { values in
            var seen = Set<UUID>()
            return values.compactMap { value in
                let mapped = duplicateIDs.contains(value) ? trackID : value
                return seen.insert(mapped).inserted ? mapped : nil
            }
        }
        let wasFavorite = favorites.contains(trackID) || !favorites.isDisjoint(with: duplicateIDs)
        favorites.subtract(duplicateIDs)
        if wasFavorite { favorites.insert(trackID) }

        for index in playlists.indices {
            let previouslyReferenced = playlists[index].trackIDs.contains(trackID)
                || playlists[index].trackIDs.contains(where: duplicateIDs.contains)
                || previousRemoteID.map { playlists[index].remoteSongIDs?.contains($0) == true } == true
            playlists[index].trackIDs = remap(playlists[index].trackIDs)
            guard previouslyReferenced, !playlists[index].isSystem else { continue }
            if let previousRemoteID, previousRemoteID != resolvedRemoteID {
                var seen = Set<String>()
                playlists[index].remoteSongIDs = (playlists[index].remoteSongIDs ?? []).compactMap { value in
                    let mapped = value == previousRemoteID ? resolvedRemoteID : value
                    return seen.insert(mapped).inserted ? mapped : nil
                }
            }
            updateRemoteSongIDs(forPlaylistAt: index)
            markPlaylistDirty(playlists[index].id)
        }

        historyTrackIDs = historyTrackIDs.map { duplicateIDs.contains($0) ? trackID : $0 }
        var remappedListeningHistory = false
        for index in listeningHistoryEntries.indices
        where duplicateIDs.contains(listeningHistoryEntries[index].trackID) {
            listeningHistoryEntries[index].trackID = trackID
            remappedListeningHistory = true
        }
        playbackContextTrackIDs = remap(playbackContextTrackIDs)
        shuffledTrackIDs = remap(shuffledTrackIDs)
        if let currentTrackID, duplicateIDs.contains(currentTrackID) { self.currentTrackID = trackID }
        if let loadedAudioTrackID, duplicateIDs.contains(loadedAudioTrackID) { self.loadedAudioTrackID = trackID }
        tracks.removeAll { duplicateIDs.contains($0.id) }

        if wasFavorite {
            playlistMutationGeneration &+= 1
            if let previousRemoteID, previousRemoteID != resolvedRemoteID {
                remoteLikedSongIDs.remove(previousRemoteID)
                dirtyRemoteLikeSongIDs.insert(previousRemoteID)
            }
            remoteLikedSongIDs.insert(resolvedRemoteID)
            dirtyRemoteLikeSongIDs.insert(resolvedRemoteID)
            likesDirty = true
        }
        hydrateRemotePlaylistTracks()
        persistHistory()
        if remappedListeningHistory { persistListeningHistory() }
        persistPlaybackContext()
        persistShuffleQueue()
        persistPlaybackPosition()
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
        schedulePlaylistSync()
        return true
    }

    private static func hasConflictingRemoteAssociation(
        _ track: Track,
        targetServer: URL,
        targetProfileID: String
    ) -> Bool {
        hasConflictingRemoteAssociation(
            track,
            targetOrigin: ServerSongIdentity.normalizedOrigin(targetServer),
            targetProfileID: targetProfileID
        )
    }

    private static func hasConflictingRemoteAssociation(
        _ track: Track,
        targetOrigin: String?,
        targetProfileID: String
    ) -> Bool {
        let hasRemoteID = track.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasSourceServer = track.sourceServer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        guard hasRemoteID || hasSourceServer else { return false }
        guard let currentOrigin = ServerSongIdentity.normalizedOrigin(track.sourceServer),
              let targetOrigin else {
            return true
        }
        return currentOrigin != targetOrigin
            || (track.syncProfileID ?? "default") != targetProfileID
    }

    private static func sameLocalFile(_ first: URL?, _ second: URL) -> Bool {
        guard let first, first.isFileURL, second.isFileURL else { return false }
        return first.standardizedFileURL.resolvingSymlinksInPath()
            == second.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    func reconcileCachedUploadedLocalTracks() async -> Bool {
        let inputs = tracks.map { track in
            CachedUploadInspectionInput(
                trackID: track.id,
                fileURL: track.fileURL,
                contentSHA256: track.contentSHA256?.lowercased(),
                remoteID: track.remoteID,
                sourceServer: track.sourceServer,
                profileID: track.syncProfileID,
                isActiveRemote: track.remoteID.map {
                    track.remoteIdentity == activeRemoteIdentity(songID: $0)
                } ?? false
            )
        }
        let localCandidates = await Task.detached(priority: .utility) {
            inputs.compactMap { input -> CachedUploadCandidate? in
                guard input.remoteID == nil,
                      let hash = input.contentSHA256,
                      !hash.isEmpty,
                      let fileURL = input.fileURL,
                      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init),
                      size > 0 else { return nil }
                return CachedUploadCandidate(
                    trackID: input.trackID,
                    fileURL: fileURL,
                    size: size,
                    contentSHA256: hash,
                    remoteID: nil,
                    sourceServer: nil,
                    profileID: nil
                )
            }
        }.value
        guard !localCandidates.isEmpty else { return false }
        let localSizes = Set(localCandidates.map(\.size))
        let serverCandidates = await Task.detached(priority: .utility) {
            inputs.compactMap { input -> CachedUploadCandidate? in
                guard let remoteID = input.remoteID,
                      input.isActiveRemote,
                      let fileURL = input.fileURL,
                      FileManager.default.fileExists(atPath: fileURL.path),
                      let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init),
                      localSizes.contains(size) else { return nil }
                return CachedUploadCandidate(
                    trackID: input.trackID,
                    fileURL: fileURL,
                    size: size,
                    contentSHA256: input.contentSHA256,
                    remoteID: remoteID,
                    sourceServer: input.sourceServer,
                    profileID: input.profileID
                )
            }
        }.value
        guard !serverCandidates.isEmpty else { return false }

        let matches = await Task.detached(priority: .utility) {
            let localByContent = Dictionary(grouping: localCandidates) {
                "\($0.size)#\($0.contentSHA256 ?? "")"
            }
            let hashedServerCandidates = serverCandidates.compactMap { server -> (String, UUID)? in
                let hash = server.contentSHA256 ?? (try? Self.fileSHA256(at: server.fileURL))
                guard let hash else { return nil }
                return ("\(server.size)#\(hash.lowercased())", server.trackID)
            }
            let serverByContent = Dictionary(grouping: hashedServerCandidates, by: \.0)
            return serverByContent.compactMap { key, servers -> CachedUploadMatch? in
                guard servers.count == 1,
                      let serverTrackID = servers.first?.1,
                      let locals = localByContent[key],
                      locals.count == 1,
                      let localTrackID = locals.first?.trackID else { return nil }
                return CachedUploadMatch(localTrackID: localTrackID, serverTrackID: serverTrackID)
            }
        }.value

        var changed = false
        for match in matches {
            guard let serverTrack = tracks.first(where: { $0.id == match.serverTrackID }),
                  let remoteID = serverTrack.remoteID else { continue }
            changed = reconcileUploadedLocalTrack(
                trackID: match.localTrackID,
                remoteID: remoteID,
                sourceServer: serverTrack.sourceServer,
                profileID: serverTrack.syncProfileID
            ) || changed
        }
        return changed
    }

    nonisolated private static func fileSHA256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func fileSHA256Detached(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try fileSHA256(at: url)
        }.value
    }

    nonisolated private static func catalogSHA256(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else { throw ServerSyncError.invalidResponse }
        return normalized
    }

    @discardableResult
    func reconcileDownloadedMediaKinds(with catalog: [RemoteSong]) -> Bool {
        let kindsByRemoteID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.kind) })
        var changed = false
        for index in tracks.indices {
            guard let remoteID = tracks[index].remoteID,
                  tracks[index].remoteIdentity == activeRemoteIdentity(songID: remoteID),
                  let kind = kindsByRemoteID[remoteID],
                  tracks[index].kind != kind else { continue }
            tracks[index].kind = kind
            changed = true
        }
        if changed { persistLibrary() }
        return changed
    }

    private func reconcileDownloadedMediaKindsAutomatically() async {
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let base = try? normalizedServerURL() else { return }
        let profileID = syncProfileID
        let credentialFingerprint = MacClientConfigContext.tokenFingerprint(serverToken)
        guard let catalog = try? await fetchRemoteCatalog(base: base) else { return }
        guard profileID == syncProfileID,
              credentialFingerprint == MacClientConfigContext.tokenFingerprint(serverToken),
              let currentBase = try? normalizedServerURL(),
              Self.serverContextKey(base: currentBase, profileID: profileID)
                == Self.serverContextKey(base: base, profileID: profileID) else { return }
        remoteSongs = catalog
        remoteCatalogIsAuthoritative = true
        reconcileDownloadedMediaKinds(with: catalog)
    }

    private func authenticatedRequest(
        url: URL,
        profileID: String? = nil,
        includeProfile: Bool = true
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        if includeProfile {
            setProfileHeader(on: &request, profileID: profileID)
        }
        if let base = try? normalizedServerURL(), Self.sameOrigin(url, base) {
            applyCurrentClientConfigHeaders(to: &request, base: base, fallbackToken: serverToken)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func remoteURL(_ path: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw ServerSyncError.invalidResponse
        }
        guard Self.sameOrigin(url, base) else { throw ServerSyncError.crossOriginDownload }
        return url
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased(),
              (lhsScheme == "http" || lhsScheme == "https"),
              (rhsScheme == "http" || rhsScheme == "https") else { return false }
        let lhsPort = lhs.port ?? (lhsScheme == "https" ? 443 : 80)
        let rhsPort = rhs.port ?? (rhsScheme == "https" ? 443 : 80)
        return lhsScheme == rhsScheme && lhsHost == rhsHost && lhsPort == rhsPort
    }

    private static func cachedDestination(for song: RemoteSong, in cache: URL) throws -> URL {
        let identifier = try validatedRemoteSongIdentifier(song.id)

        let digest = SHA256.hash(data: Data(identifier.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let destination = cache
            .appendingPathComponent(key + PathExtension.safe(song.filename), isDirectory: false)
            .standardizedFileURL
        guard isDescendant(destination, of: cache) else {
            throw ServerSyncError.invalidSongIdentifier
        }
        return destination
    }

    private static func validatedRemoteSongIdentifier(_ identifier: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !identifier.isEmpty,
              identifier.unicodeScalars.allSatisfy(allowed.contains)
        else { throw ServerSyncError.invalidSongIdentifier }
        return identifier
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let rootPath = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath.hasPrefix(rootPath + "/")
    }

    private static func installValidatedDownload(from staging: URL, at destination: URL) throws {
        guard staging.deletingLastPathComponent().standardizedFileURL
                == destination.deletingLastPathComponent().standardizedFileURL else {
            throw ServerSyncError.invalidSongIdentifier
        }
        guard rename(staging.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServerSyncError.server(http.statusCode) }
    }

    private static func uploadedSong(from data: Data, response: URLResponse) throws -> RemoteSong {
        guard let http = response as? HTTPURLResponse else { throw ServerSyncError.invalidResponse }
        if (200..<300).contains(http.statusCode) {
            guard let song = try? JSONDecoder().decode(RemoteSong.self, from: data) else {
                throw ServerSyncError.invalidResponse
            }
            return song
        }
        if http.statusCode == 409,
           let duplicate = try? JSONDecoder().decode(DuplicateSongUploadResponse.self, from: data) {
            return duplicate.duplicateOf
        }
        throw Self.serverError(status: http.statusCode, data: data)
    }

    private static func requiresLegacySourceLinkSchema(response: URLResponse, data: Data) -> Bool {
        struct ErrorPayload: Decodable { let error: String }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 400,
              let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data) else { return false }
        return payload.error == "Unsupported source-link schema_version"
    }

    private func serverCacheDirectory(for base: URL, profileID: String) throws -> URL {
        let root = try serverCacheRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let context = Self.serverContextKey(base: base, profileID: profileID)
        let safeName = SHA256.hash(data: Data(context.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = root
            .appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("ServerCache", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func serverCacheRootDirectory(customRoot: URL?) -> URL? {
        let root = customRoot ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        guard let root else { return nil }
        return root
            .appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("ServerCache", isDirectory: true)
            .standardizedFileURL
    }

    private static func migrateUnlinkedDownloads(
        _ tracks: [Track],
        managedCacheRoot: URL
    ) -> (tracks: [Track], completed: Bool, changed: Bool) {
        let fileManager = FileManager.default
        var retained: [Track] = []
        var completed = true
        var changed = false

        for track in tracks {
            let isManagedDownload = track.fileURL.map {
                isDescendant($0.standardizedFileURL, of: managedCacheRoot)
            } ?? false
            let decision = UnlinkedDownloadMigrationPolicy.decision(
                for: track,
                legacyDownloadOwned: isManagedDownload
            )
            changed = changed || decision.track != track
            guard decision.shouldDelete else {
                retained.append(decision.track)
                continue
            }

            guard isManagedDownload, let fileURL = decision.track.fileURL else {
                retained.append(decision.track)
                completed = false
                continue
            }
            do {
                if fileManager.fileExists(atPath: fileURL.path) {
                    try fileManager.removeItem(at: fileURL)
                }
                changed = true
            } catch {
                retained.append(decision.track)
                completed = false
            }
        }
        return (retained, completed, changed)
    }

    private static var credentialStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Resonance", isDirectory: true)
            .appendingPathComponent("server-credentials.json")
    }

    private static var credentialStore: FileServerCredentialStore {
        FileServerCredentialStore(storeURL: credentialStoreURL)
    }

    private static var isPreviewBundle: Bool {
        CredentialStorePolicy.isPreviewBundle(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private static func prepareCredentialStore() {
        bootstrapCredentialStoreFromEnvironment()
    }

    private static func bootstrapCredentialStoreFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        guard let client = environment["RESONANCE_CLIENT_TOKEN"],
              let admin = environment["RESONANCE_ADMIN_TOKEN"],
              !client.isEmpty, !admin.isEmpty else { return }
        _ = credentialStore.save(client, key: clientCredentialKey)
        _ = credentialStore.save(admin, key: adminCredentialKey)
        unsetenv("RESONANCE_CLIENT_TOKEN")
        unsetenv("RESONANCE_ADMIN_TOKEN")
    }

    private static func readServerToken() -> String {
        credentialStore.read(key: clientCredentialKey) ?? ""
    }

    private static func readServerToken(key: String) -> String {
        credentialStore.read(
            key: key == adminCredentialKey ? adminCredentialKey : clientCredentialKey
        ) ?? ""
    }

    private static func saveServerToken(_ token: String) {
        _ = credentialStore.save(token, key: clientCredentialKey)
    }

    private static func saveServerToken(_ token: String, key: String) {
        _ = credentialStore.save(
            token,
            key: key == adminCredentialKey ? adminCredentialKey : clientCredentialKey
        )
    }

    private static func readAccountSession() -> ResonanceAccountSession? {
        guard let raw = credentialStore.read(key: accountSessionCredentialKey),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ResonanceAccountSession.self, from: data)
    }

    @discardableResult
    private static func saveAccountSession(_ session: ResonanceAccountSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session),
              let raw = String(data: data, encoding: .utf8) else { return false }
        return credentialStore.save(raw, key: accountSessionCredentialKey)
    }

    private static func deleteAccountSession() {
        _ = credentialStore.delete(key: accountSessionCredentialKey)
    }

    private enum PathExtension {
        static func safe(_ filename: String) -> String {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            let safe = ext.filter { $0.isLetter || $0.isNumber }
            return safe.isEmpty ? "" : "." + safe
        }
    }

    private static func loadLibrary(from defaults: UserDefaults) -> StoredLibraryLoadResult {
        guard let data = defaults.data(forKey: libraryKey) else { return .missing }
        do {
            return .loaded(try JSONDecoder().decode(StoredLibrary.self, from: data))
        } catch {
            return .corrupt(data)
        }
    }

    private static func loadRemoteSongMetadataCache(
        from defaults: UserDefaults
    ) -> [String: CachedRemoteSongMetadata] {
        guard let data = defaults.data(forKey: remoteSongMetadataCacheKey),
              let cache = try? JSONDecoder().decode(
                [String: CachedRemoteSongMetadata].self,
                from: data
              ) else { return [:] }
        return prunedRemoteSongMetadataCache(cache)
    }

    private static func prunedRemoteSongMetadataCache(
        _ cache: [String: CachedRemoteSongMetadata],
        now: Date = Date()
    ) -> [String: CachedRemoteSongMetadata] {
        let cutoff = now.addingTimeInterval(-remoteSongMetadataCacheLifetime)
        let freshest = cache
            .filter { $0.value.cachedAt >= cutoff }
            .sorted { $0.value.cachedAt > $1.value.cachedAt }
            .prefix(remoteSongMetadataCacheLimit)
        return Dictionary(uniqueKeysWithValues: freshest.map { ($0.key, $0.value) })
    }

    private func persistRemoteSongMetadataCache() {
        remoteSongMetadataCache = Self.prunedRemoteSongMetadataCache(remoteSongMetadataCache)
        Self.persistenceCoordinator.schedule(
            remoteSongMetadataCache,
            key: Self.remoteSongMetadataCacheKey,
            defaults: defaults
        )
    }

    private static func restoredTrackIDs(
        from values: [String]?,
        validIDs: Set<UUID>
    ) -> [UUID] {
        var seen = Set<UUID>()
        return (values ?? []).compactMap(UUID.init(uuidString:)).filter { id in
            validIDs.contains(id) && seen.insert(id).inserted
        }
    }

    private func migrateLegacyLibraryIfNeeded() {
        guard
            let data = defaults.data(forKey: Self.legacyTracksKey),
            let legacy = try? JSONDecoder().decode([LegacyStoredTrack].self, from: data)
        else {
            persistLibrary()
            return
        }

        let migrated = legacy.compactMap(\.track)
        tracks = migrated
        playlists = [.library()]
        favorites = []
        selectedPlaylistID = playlists.first?.id
        currentTrackID = tracks.first?.id
        defaults.removeObject(forKey: Self.legacyTracksKey)
        persistLibrary()
    }

    private nonisolated static func expandedMediaURLs(from selectedURLs: [URL]) -> [URL] {
        var results: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]

        for url in selectedURLs {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                while let item = enumerator?.nextObject() as? URL {
                    if isSupportedMediaFile(item) { results.append(item) }
                }
            } else if isSupportedMediaFile(url) {
                results.append(url)
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private nonisolated static func inspectLocalMedia(
        selectedURLs: [URL],
        excludingPaths: Set<String>
    ) async -> [LocalMediaInspection] {
        await Task.detached(priority: .userInitiated) {
            let urls = expandedMediaURLs(from: selectedURLs)
            var knownPaths = excludingPaths
            var results: [LocalMediaInspection] = []
            results.reserveCapacity(urls.count)
            for url in urls {
                let standardizedURL = url.standardizedFileURL
                guard knownPaths.insert(standardizedURL.path).inserted,
                      let player = try? AVAudioPlayer(contentsOf: standardizedURL) else { continue }
                let metadata = await metadata(for: standardizedURL)
                results.append(LocalMediaInspection(
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    duration: player.duration,
                    kind: MediaKindClassifier.kind(
                        contentType: UTType(filenameExtension: standardizedURL.pathExtension)?.preferredMIMEType ?? "",
                        filename: standardizedURL.lastPathComponent
                    ),
                    artworkData: metadata.artworkData,
                    fileURL: standardizedURL
                ))
            }
            return results
        }.value
    }

    nonisolated static func isSupportedMediaFile(_ url: URL) -> Bool {
        let knownMediaExtensions: Set<String> = [
            "aac", "ac3", "aif", "aiff", "caf", "flac", "m4a", "m4v",
            "mov", "mp3", "mp4", "oga", "ogg", "opus", "wav", "webm",
        ]
        if knownMediaExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .video)
    }

    private nonisolated static func metadata(for url: URL) async -> (title: String, artist: String, album: String, artworkData: Data?) {
        let asset = AVURLAsset(url: url)
        var title = url.deletingPathExtension().lastPathComponent
        var artist = "Unknown Artist"
        var album = "Unknown Album"
        var artworkData: Data?

        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            switch item.commonKey?.rawValue {
            case AVMetadataKey.commonKeyTitle.rawValue:
                if let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
            case AVMetadataKey.commonKeyArtist.rawValue:
                if let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
            case AVMetadataKey.commonKeyAlbumName.rawValue:
                if let value = try? await item.load(.stringValue), !value.isEmpty { album = value }
            case AVMetadataKey.commonKeyArtwork.rawValue:
                artworkData = try? await item.load(.dataValue)
            default:
                break
            }
        }
        return (title, artist, album, artworkData)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
