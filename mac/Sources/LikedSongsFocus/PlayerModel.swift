import AppKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class PlayerModel: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
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

    private struct ListeningHistoryUploadDocument: Encodable {
        let client = "macos"
        let deviceID: String
        let entries: [ListeningHistoryUploadEntry]

        enum CodingKeys: String, CodingKey {
            case client, entries
            case deviceID = "device_id"
        }
    }

    private struct ListeningHistoryUploadEntry: Encodable {
        let id: String
        let trackID: String
        let songID: String?
        let startedAt: String
        let listenedSeconds: TimeInterval
        let title: String?
        let artist: String?
        let album: String?
        let durationSeconds: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case id, title, artist, album
            case trackID = "track_id"
            case songID = "song_id"
            case startedAt = "started_at"
            case listenedSeconds = "listened_seconds"
            case durationSeconds = "duration_seconds"
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

    private struct CachedUploadMatch: Sendable {
        let localTrackID: UUID
        let serverTrackID: UUID
    }

    private enum ServerSyncError: LocalizedError {
        case invalidURL
        case missingToken
        case missingAdminToken
        case invalidResponse
        case invalidSongIdentifier
        case crossOriginDownload
        case invalidMedia
        case unexpectedDownloadSize
        case server(Int)
        case serverMessage(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a complete http:// or https:// server URL."
            case .missingToken: "Enter the server access token."
            case .missingAdminToken: "Enter the server admin key to upload songs."
            case .invalidResponse: "The server returned an invalid response."
            case .invalidSongIdentifier: "The server returned an unsafe song identifier."
            case .crossOriginDownload: "The server returned a download URL from another server."
            case .invalidMedia: "The downloaded file is not playable media."
            case .unexpectedDownloadSize: "The downloaded file size did not match the server catalog."
            case .server(let status): "The server returned HTTP \(status)."
            case .serverMessage(let status, let message): "The server returned HTTP \(status): \(message)"
            }
        }
    }

    private static let libraryKey = "LikedSongsFocus.library.v2"
    private static let libraryRecoveryKey = "LikedSongsFocus.library.v2.recovery"
    private static let legacyTracksKey = "LikedSongsFocus.importedTracks.v1"
    private static let serverURLKey = "LikedSongsFocus.serverURL.v1"
    private static let clientCredentialAccount = "music-server-client-token"
    private static let adminCredentialAccount = "music-server-admin-token"
    private static let knownDrasticProfileID = "4f633616-9cf0-44db-8864-09358970c8f9"
    private static let volumeKey = "LikedSongsFocus.volume.v1"
    private static let playbackRateKey = "LikedSongsFocus.playbackRate.v1"
    private static let shuffleKey = "LikedSongsFocus.shuffle.v1"
    private static let repeatKey = "LikedSongsFocus.repeat.v1"
    private static let currentTrackKey = "LikedSongsFocus.currentTrack.v1"
    private static let positionKey = "LikedSongsFocus.position.v1"
    private static let historyKey = "LikedSongsFocus.history.v1"
    private static let listeningHistoryKey = "LikedSongsFocus.listeningHistory.v1"
    private static let listeningHistoryDeviceIDKey = "LikedSongsFocus.listeningHistory.deviceID.v1"
    private static let playbackContextKey = "LikedSongsFocus.playbackContext.v1"
    private static let shuffleQueueKey = "LikedSongsFocus.shuffleQueue.v1"

    @Published var section: AppSection = .library
    @Published var tracks: [Track]
    @Published var playlists: [Playlist]
    @Published var selectedPlaylistID: UUID?
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published var volume: Double = 0.78 {
        didSet {
            audioPlayer?.volume = Float(volume.clamped(to: 0...1))
            defaults.set(volume, forKey: Self.volumeKey)
        }
    }
    @Published var playbackRate: Float = 1 {
        didSet {
            audioPlayer?.rate = playbackRate
            defaults.set(Double(playbackRate), forKey: Self.playbackRateKey)
        }
    }
    @Published var shuffleEnabled = false {
        didSet { defaults.set(shuffleEnabled, forKey: Self.shuffleKey) }
    }
    @Published var repeatEnabled = false {
        didSet { defaults.set(repeatEnabled, forKey: Self.repeatKey) }
    }
    @Published var favorites: Set<UUID>
    @Published private(set) var listeningHistoryEntries: [ListeningHistoryEntry] = []
    @Published var searchText = ""
    @Published var filter: SongFilter = .all
    @Published var queueTab: QueueTab = .upNext
    @Published var serverURLString = "" {
        didSet { persistServerCredentialsImmediately() }
    }
    @Published var serverToken = "" {
        didSet { persistServerCredentialsImmediately() }
    }
    @Published var serverAdminToken = "" {
        didSet { persistServerCredentialsImmediately() }
    }
    @Published var serverMessage = "Not connected"
    @Published var remoteSongs: [RemoteSong] = []
    @Published var isSyncingServer = false
    @Published var isRefreshingServerCatalog = false
    @Published var isUploadingServer = false
    @Published var downloadProgress = 0.0
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

    private let defaults: UserDefaults
    private let networkSession: URLSession
    private let serverCacheRoot: URL?
    private let clipLibraryRoot: URL?
    private let shouldPersistServerCredentials: Bool
    private let listeningHistoryDeviceID: String
    private var audioPlayer: AVAudioPlayer?
    private var loadedAudioTrackID: UUID?
    private var playbackTimer: Timer?
    private var playbackContextTrackIDs: [UUID] = []
    private var shuffledTrackIDs: [UUID] = []
    private var historyTrackIDs: [UUID] = []
    private var activeListeningEntryID: UUID?
    private var lastListeningPosition: TimeInterval = 0
    private var lastPersistedListeningSeconds: TimeInterval = 0
    private var listeningHistorySyncDebounceTask: Task<Void, Never>?
    private var isSyncingListeningHistory = false
    private var listeningHistorySyncPending = false
    private var listeningHistorySyncedSeconds: [String: TimeInterval] = [:]
    private var navigationHistory: [NavigationLocation] = []
    private var navigationIndex = 0
    private var downloadTask: Task<Void, Never>?
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

    init(
        loadPersistedLibrary: Bool = true,
        defaults: UserDefaults = .standard,
        networkSession: URLSession = .shared,
        serverCacheRoot: URL? = nil,
        clipLibraryRoot: URL? = nil,
        persistServerCredentials: Bool = true
    ) {
        self.defaults = defaults
        self.networkSession = networkSession
        self.serverCacheRoot = serverCacheRoot
        self.clipLibraryRoot = clipLibraryRoot
        self.shouldPersistServerCredentials = persistServerCredentials
        if let storedDeviceID = defaults.string(forKey: Self.listeningHistoryDeviceIDKey),
           !storedDeviceID.isEmpty {
            listeningHistoryDeviceID = storedDeviceID
        } else {
            let generatedDeviceID = UUID().uuidString.lowercased()
            listeningHistoryDeviceID = generatedDeviceID
            defaults.set(generatedDeviceID, forKey: Self.listeningHistoryDeviceIDKey)
        }

        if persistServerCredentials {
            Self.bootstrapCredentialStoreFromEnvironment()
        }

        let loadResult = loadPersistedLibrary ? Self.loadLibrary(from: defaults) : .missing
        let stored: StoredLibrary?
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
        // A file can be temporarily unavailable when an external or network volume is
        // disconnected. Keep its library record and let playback surface availability.
        let existingTracks = (stored?.tracks ?? []).map { track in
            var migrated = track
            if migrated.remoteID != nil, migrated.syncProfileID == nil {
                migrated.syncProfileID = restoredSyncProfileID
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
            let profileID = track.syncProfileID ?? "default"
            return seenRemoteIDs.insert("\(profileID)\u{0}\(remoteID)").inserted
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
        serverURLString = persistServerCredentials ? (defaults.string(forKey: Self.serverURLKey) ?? "") : ""
        serverToken = persistServerCredentials ? Self.readServerToken() : ""
        serverAdminToken = persistServerCredentials ? Self.readServerToken(account: Self.adminCredentialAccount) : ""
        playlistRevision = stored?.playlistRevision ?? 0
        knownRemotePlaylistIDs = stored?.knownRemotePlaylistIDs ?? []
        dirtyPlaylistIDs = stored?.dirtyPlaylistIDs ?? []
        deletedPlaylistIDs = stored?.deletedPlaylistIDs ?? []
        playlistSyncServerURL = stored?.playlistSyncServerURL
        syncProfileID = restoredSyncProfileID
        activeSyncProfileName = restoredSyncProfileName
        remoteLikedSongIDs = stored?.remoteLikedSongIDs ?? Set(availableFavorites.compactMap { trackID in
            availableTracks.first(where: {
                $0.id == trackID && ($0.syncProfileID ?? "default") == restoredSyncProfileID
            })?.remoteID
        })
        if let storedDirtyLikeIDs = stored?.dirtyRemoteLikeSongIDs {
            dirtyRemoteLikeSongIDs = storedDirtyLikeIDs
        } else if stored?.likesDirty ?? false {
            dirtyRemoteLikeSongIDs = Set(availableTracks.compactMap { track in
                guard track.remoteID != nil,
                      (track.syncProfileID ?? "default") == restoredSyncProfileID else { return nil }
                return track.remoteID
            })
        }
        likesDirty = !dirtyRemoteLikeSongIDs.isEmpty

        super.init()

        if defaults.object(forKey: Self.volumeKey) != nil { volume = defaults.double(forKey: Self.volumeKey) }
        if defaults.object(forKey: Self.playbackRateKey) != nil { playbackRate = Float(defaults.double(forKey: Self.playbackRateKey)) }
        shuffleEnabled = defaults.bool(forKey: Self.shuffleKey)
        repeatEnabled = defaults.bool(forKey: Self.repeatKey)
        position = defaults.double(forKey: Self.positionKey)
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
            let migratedLegacyHistory = validHistory.contains { $0.syncProfileID == nil }
            listeningHistoryEntries = Array(
                validHistory
                    .map { entry in
                        var scopedEntry = entry
                        if scopedEntry.syncProfileID == nil {
                            scopedEntry.syncProfileID = syncProfileID
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
        persistPlaybackPosition()
        persistPlaybackContext()
        persistShuffleQueue()
        hydrateRemotePlaylistTracks()

        if loadPersistedLibrary {
            Task { @MainActor [weak self] in
                await self?.reconcileCachedUploadedLocalTracks()
            }
        }

        if loadPersistedLibrary, stored == nil, !libraryWasCorrupt {
            migrateLegacyLibraryIfNeeded()
        }
    }

    deinit {
        playlistSyncTask?.cancel()
        playlistSyncDebounceTask?.cancel()
        listeningHistorySyncDebounceTask?.cancel()
    }

    var currentTrack: Track? {
        guard let currentTrackID else { return nil }
        return tracks.first { $0.id == currentTrackID }
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

    var unfilteredCollectionTracks: [Track] {
        if section == .playlists, let playlist = selectedPlaylist {
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            return playlist.trackIDs.compactMap { tracksByID[$0] }
        } else {
            return visibleTracks
        }
    }

    var visibleTracks: [Track] {
        tracks.filter {
            $0.remoteID == nil || ($0.syncProfileID ?? "default") == syncProfileID
        }
    }

    var activeProfileListeningHistoryEntries: [ListeningHistoryEntry] {
        listeningHistoryEntries.filter { ($0.syncProfileID ?? "default") == syncProfileID }
    }

    var hasActiveLibraryFilter: Bool {
        filter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var historyTracks: [Track] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
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
        section == .playlists ? (selectedPlaylist?.count ?? 0) : tracks.count
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

    func removeTrackFromLibrary(_ track: Track) {
        let removingCurrentTrack = currentTrackID == track.id
        if removingCurrentTrack { stopCurrentPlayback() }

        tracks.removeAll { $0.id == track.id }
        favorites.remove(track.id)
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { $0 == track.id }
        }
        historyTrackIDs.removeAll { $0 == track.id }
        listeningHistoryEntries.removeAll { $0.trackID == track.id }
        persistListeningHistory()
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
        tracks.contains { $0.remoteID == song.id }
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
            await refreshServerCatalogNow()
            await syncPlaylistsNow()
            await syncListeningHistoryNow()
        }
    }

    func connectAndSyncServer() {
        refreshServerCatalog()
    }

    func clearServerCredentials() {
        serverURLString = ""
        serverToken = ""
        serverAdminToken = ""
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()
        serverMessage = "Not connected"
        downloadStatus = ""
        uploadStatus = ""
        playlistSyncStatus = ""
    }

    func downloadSelectedServerSongs() {
        guard !selectedRemoteSongIDs.isEmpty else {
            downloadStatus = "Select one or more songs first"
            return
        }
        let selection = selectedRemoteSongIDs
        downloadTask = Task { await syncServerLibrary(songIDs: selection, reconcile: false) }
    }

    func downloadServerSong(_ song: RemoteSong) {
        guard !isSyncingServer else { return }
        downloadTask = Task { await syncServerLibrary(songIDs: [song.id], reconcile: false) }
    }

    func downloadAllServerSongs() {
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
                let songID = try Self.validatedRemoteSongIdentifier(song.id)
                let endpoint = base.appendingPathComponent("api/v1/admin/songs", isDirectory: true)
                var request = URLRequest(url: endpoint.appendingPathComponent(songID, isDirectory: false))
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
                setProfileHeader(on: &request)
                let (_, response) = try await networkSession.data(for: request)
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .movie]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadTask = Task { await uploadSongsToServer(panel.urls) }
    }

    func refreshServerCatalogNow() async {
        guard !isSyncingServer else { return }
        isSyncingServer = true
        isRefreshingServerCatalog = true
        defer {
            isRefreshingServerCatalog = false
            isSyncingServer = false
        }
        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            _ = try? await backfillServerMetadataIfAvailable(base: base)
            remoteSongs = try await fetchRemoteCatalog(base: base)
            await reconcileCachedUploadedLocalTracks()
            selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
            serverMessage = "Connected • \(remoteSongs.count) \(remoteSongs.count == 1 ? "song" : "songs") available"
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    func syncServerLibrary(songIDs: Set<String>? = nil, reconcile _: Bool = false) async {
        guard !isSyncingServer else { return }
        isSyncingServer = true
        downloadStatus = "Preparing download…"
        downloadProgress = 0
        defer {
            isSyncingServer = false
            downloadCurrentFile = ""
        }

        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let catalogSongs = try await fetchRemoteCatalog(base: base)
            remoteSongs = catalogSongs
            reconcileDownloadedMediaKinds(with: catalogSongs)
            let songs = songIDs.map { ids in catalogSongs.filter { ids.contains($0.id) } } ?? catalogSongs
            downloadStatus = songs.isEmpty ? "Nothing to download" : "Checking \(songs.count) songs"
            let cache = try serverCacheDirectory(for: base)
            var changedCount = 0
            var failedCount = 0

            for (index, remote) in songs.enumerated() {
                try Task.checkCancellation()
                downloadCurrentFile = remote.filename
                downloadStatus = "Downloading \(index + 1) of \(songs.count)"
                var stagingURL: URL?
                do {
                    let destination = try Self.cachedDestination(for: remote, in: cache)
                    let existingIndex = tracks.firstIndex {
                        $0.remoteID == remote.id && ($0.syncProfileID ?? "default") == syncProfileID
                    }
                    let previousCachedURL = existingIndex.flatMap { tracks[$0].fileURL }
                    let destinationExists = FileManager.default.fileExists(atPath: destination.path)
                    let localSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    let cachedPlayer = destinationExists ? try? AVAudioPlayer(contentsOf: destination) : nil

                    if destinationExists, cachedPlayer == nil {
                        // Never leave an invalid same-size file in place: it would otherwise
                        // make every later sync incorrectly skip the download.
                        try FileManager.default.removeItem(at: destination)
                    }

                    if let existingIndex,
                       localSize == remote.size,
                       cachedPlayer != nil,
                       tracks[existingIndex].fileURL?.standardizedFileURL == destination.standardizedFileURL {
                        downloadProgress = Double(index + 1) / Double(max(songs.count, 1))
                        continue
                    }

                    let player: AVAudioPlayer
                    if localSize == remote.size, let cachedPlayer {
                        player = cachedPlayer
                    } else {
                        let downloadURL = try remoteURL(remote.downloadURL, relativeTo: base)
                        var request = authenticatedRequest(url: downloadURL)
                        request.timeoutInterval = 120
                        let (temporaryURL, response) = try await networkSession.download(for: request)
                        try Self.validate(response)

                        let ext = PathExtension.safe(remote.filename)
                        let staging = cache.appendingPathComponent(".download-\(UUID().uuidString)\(ext)")
                        guard Self.isDescendant(staging, of: cache) else {
                            throw ServerSyncError.invalidSongIdentifier
                        }
                        stagingURL = staging
                        try FileManager.default.moveItem(at: temporaryURL, to: staging)
                        let stagedSize = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                        guard stagedSize == remote.size else { throw ServerSyncError.unexpectedDownloadSize }
                        guard let stagedPlayer = try? AVAudioPlayer(contentsOf: staging) else {
                            throw ServerSyncError.invalidMedia
                        }
                        try Self.installValidatedDownload(from: staging, at: destination)
                        stagingURL = nil
                        player = stagedPlayer
                    }

                    let metadata = await Self.metadata(for: destination)
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
                        fileURL: destination,
                        remoteID: remote.id,
                        sourceServer: base.absoluteString,
                        syncProfileID: syncProfileID,
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
                } catch is CancellationError {
                    if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
                    throw CancellationError()
                } catch {
                    if let stagingURL { try? FileManager.default.removeItem(at: stagingURL) }
                    failedCount += 1
                }
                downloadProgress = Double(index + 1) / Double(max(songs.count, 1))
            }

            await reconcileCachedUploadedLocalTracks()
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
        guard !isUploadingServer else { return }
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
            try saveServerConfiguration(base: base)
            var failedCount = 0
            for (index, fileURL) in urls.enumerated() {
                try Task.checkCancellation()
                uploadCurrentFile = fileURL.lastPathComponent
                uploadStatus = "Uploading \(index + 1) of \(urls.count)"
                var components = URLComponents(
                    url: base.appendingPathComponent("api/v1/admin/songs"),
                    resolvingAgainstBaseURL: false
                )
                components?.queryItems = [URLQueryItem(name: "filename", value: fileURL.lastPathComponent)]
                guard let url = components?.url else { throw ServerSyncError.invalidURL }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.timeoutInterval = 600
                request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
                setProfileHeader(on: &request)
                request.setValue(UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
                do {
                    let (_, response) = try await networkSession.upload(for: request, fromFile: fileURL)
                    try Self.validate(response)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedCount += 1
                }
                uploadProgress = Double(index + 1) / Double(max(urls.count, 1))
            }
            let successCount = urls.count - failedCount
            uploadStatus = failedCount == 0 ? "Uploaded \(successCount) songs" : "Uploaded \(successCount); \(failedCount) failed"
            remoteSongs = try await fetchRemoteCatalog(base: base)
            reconcileDownloadedMediaKinds(with: remoteSongs)
            serverMessage = "Connected • \(remoteSongs.count) songs available"
        } catch is CancellationError {
            uploadStatus = "Cancelled"
        } catch {
            uploadStatus = "Upload failed: \(error.localizedDescription)"
        }
    }

    func selectAndPlay(_ track: Track) {
        setPlaybackContext(playbackTracks, ensuring: track.id)
        startTrack(track.id, preservingShuffleQueue: false)
    }

    func togglePlay() {
        if isPlaying {
            pausePlayback()
            return
        }
        guard let track = currentTrack ?? tracks.first else { return }
        ensurePlaybackContext(containing: track.id)
        if currentTrackID != track.id {
            startTrack(track.id, preservingShuffleQueue: false)
        } else {
            beginPlayback(of: track, resuming: true)
        }
    }

    func toggleCollectionPlayback() {
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
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled {
            rebuildShuffleOrder()
        } else {
            shuffledTrackIDs.removeAll()
            persistShuffleQueue()
        }
    }

    func toggleRepeat() {
        repeatEnabled.toggle()
        audioPlayer?.numberOfLoops = repeatEnabled ? -1 : 0
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        audioPlayer?.enableRate = true
        audioPlayer?.rate = rate
    }

    func seek(to fraction: Double) {
        guard let track = currentTrack else { return }
        updateListeningSession()
        position = track.duration * fraction.clamped(to: 0...1)
        if loadedAudioTrackID == track.id {
            audioPlayer?.currentTime = position
        }
        lastListeningPosition = position
        persistPlaybackPosition()
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
        let urls = Self.expandedMediaURLs(from: selectedURLs)
        var knownPaths = Set(tracks.compactMap { $0.fileURL?.standardizedFileURL.path })
        let styles: [ArtworkStyle] = [.midnight, .electric, .echoes, .golden, .weightless, .falling]
        var imported: [Track] = []

        for url in urls where !knownPaths.contains(url.standardizedFileURL.path) {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            let metadata = await Self.metadata(for: url)
            let track = Track(
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                duration: player.duration,
                kind: MediaKindClassifier.kind(
                    contentType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "",
                    filename: url.lastPathComponent
                ),
                artwork: styles[(tracks.count + imported.count) % styles.count],
                artworkData: metadata.artworkData,
                fileURL: url.standardizedFileURL,
                dateAdded: .now
            )
            imported.append(track)
            knownPaths.insert(url.standardizedFileURL.path)
        }

        guard !imported.isEmpty else { return }
        tracks.append(contentsOf: imported)
        if currentTrackID == nil { currentTrackID = tracks.first?.id }
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
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
            return duplicate
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
            fileURL: imported.fileURL.standardizedFileURL,
            remoteID: nil,
            sourceServer: nil,
            syncProfileID: nil,
            sourceURL: imported.metadata.sourceURL,
            sourceSHA256: imported.sourceSHA256,
            contentSHA256: imported.contentSHA256,
            dateAdded: .now
        )
        tracks.append(track)
        if currentTrackID == nil { currentTrackID = track.id }
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
        return track
    }

    @discardableResult
    func createClip(
        from trackID: UUID,
        startTime: TimeInterval,
        endTime: TimeInterval,
        title rawTitle: String
    ) async throws -> Track {
        guard let source = tracks.first(where: { $0.id == trackID }),
              let sourceURL = source.fileURL,
              FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ClipEditorError.missingSource
        }
        let range = try ClipRangePolicy.normalized(
            start: startTime,
            end: endTime,
            sourceDuration: source.duration
        )
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? "\(source.title) Clip" : trimmedTitle
        let directory = try clipDirectory()
        let destination = directory.appendingPathComponent(
            "\(Self.safeClipFilenameStem(title))-\(UUID().uuidString.prefix(8)).m4a",
            isDirectory: false
        )

        do {
            try await ClipAudioProcessor.exportM4AClip(
                input: sourceURL,
                output: destination,
                range: range,
                title: title,
                artist: source.artist,
                album: source.album,
                artwork: source.artworkData
            )
            let player = try AVAudioPlayer(contentsOf: destination)
            guard player.duration > 0 else { throw ClipEditorError.exportFailed("The exported file is empty.") }
            let clip = Track(
                title: title,
                artist: source.artist,
                album: source.album,
                duration: player.duration,
                kind: .audio,
                artwork: source.artwork,
                artworkData: source.artworkData,
                fileURL: destination.standardizedFileURL,
                dateAdded: .now
            )
            tracks.append(clip)
            if currentTrackID == nil { currentTrackID = clip.id }
            persistLibrary()
            reconcileShuffleOrderIfNeeded()
            return clip
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func uploadLocalImportToActiveProfile(_ track: Track) async throws {
        guard let currentTrack = tracks.first(where: { $0.id == track.id }),
              currentTrack.remoteID == nil,
              let fileURL = currentTrack.fileURL else {
            throw ServerSyncError.invalidMedia
        }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adminToken.isEmpty else { throw ServerSyncError.missingAdminToken }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let isVideo = track.kind == .video
        let maximumSize = isVideo ? 1_024 * 1_024 * 1_024 : 256 * 1_024 * 1_024
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumSize else { throw ServerSyncError.invalidMedia }

        let base = try normalizedServerURL()
        try saveServerConfiguration(base: base)
        var components = URLComponents(
            url: base.appendingPathComponent("api/v1/admin/songs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "filename", value: fileURL.lastPathComponent)]
        guard let url = components?.url else { throw ServerSyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 600
        request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue(isVideo ? "video/mp4" : "audio/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        setProfileHeader(on: &request)
        let (data, response) = try await networkSession.upload(for: request, fromFile: fileURL)
        let uploadedSong = try Self.uploadedSong(from: data, response: response)
        let refreshedCatalog = (try? await fetchRemoteCatalog(base: base)) ?? remoteSongs
        remoteSongs = [uploadedSong] + refreshedCatalog.filter { $0.id != uploadedSong.id }
        reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: uploadedSong.id,
            sourceServer: base.absoluteString,
            profileID: syncProfileID
        )
        serverMessage = "Connected • \(remoteSongs.count) songs available"
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        updateListeningSession()
        position = currentTrack?.duration ?? player.duration
        isPlaying = false
        stopPlaybackTimer()
        next()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        endListeningSession()
        isPlaying = false
        stopPlaybackTimer()
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
        position = 0
        persistPlaybackPosition()
        if shuffleEnabled, !preservingShuffleQueue { rebuildShuffleOrder() }
        beginPlayback(of: track)
    }

    private func beginPlayback(of track: Track, resuming: Bool = false) {
        guard let fileURL = track.fileURL else { return }
        if loadedAudioTrackID != track.id || audioPlayer == nil {
            guard let player = try? AVAudioPlayer(contentsOf: fileURL) else {
                isPlaying = false
                return
            }
            player.delegate = self
            player.volume = Float(volume)
            player.numberOfLoops = repeatEnabled ? -1 : 0
            player.enableRate = true
            player.rate = playbackRate
            player.prepareToPlay()
            audioPlayer = player
            loadedAudioTrackID = track.id
        }

        if !resuming { audioPlayer?.currentTime = 0 }
        if position >= track.duration { position = 0 }
        audioPlayer?.currentTime = position
        isPlaying = audioPlayer?.play() ?? false
        if isPlaying {
            beginListeningSession(for: track)
            startPlaybackTimer()
        }
    }

    private func pausePlayback() {
        updateListeningSession()
        audioPlayer?.pause()
        position = audioPlayer?.currentTime ?? position
        isPlaying = false
        stopPlaybackTimer()
        persistListeningHistory()
        scheduleListeningHistorySync()
        persistPlaybackPosition()
    }

    private func stopCurrentPlayback() {
        endListeningSession()
        audioPlayer?.stop()
        audioPlayer = nil
        loadedAudioTrackID = nil
        isPlaying = false
        stopPlaybackTimer()
    }

    private func startPlaybackTimer() {
        stopPlaybackTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.position = self.audioPlayer?.currentTime ?? self.position
                self.updateListeningSession()
                self.persistPlaybackPosition()
            }
        }
        playbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
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
        if
            let activeListeningEntryID,
            let activeEntry = listeningHistoryEntries.first(where: { $0.id == activeListeningEntryID }),
            activeEntry.trackID == track.id,
            (activeEntry.syncProfileID ?? "default") == syncProfileID
        {
            return
        }

        let entry = ListeningHistoryEntry(
            trackID: track.id,
            syncProfileID: syncProfileID,
            remoteSongID: track.remoteID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            originatedOnThisDevice: true
        )
        listeningHistoryEntries.append(entry)
        if listeningHistoryEntries.count > 2_000 {
            listeningHistoryEntries.removeFirst(listeningHistoryEntries.count - 2_000)
        }
        activeListeningEntryID = entry.id
        lastListeningPosition = audioPlayer?.currentTime ?? position
        lastPersistedListeningSeconds = 0
        persistListeningHistory()
    }

    private func updateListeningSession() {
        let currentPosition = audioPlayer?.currentTime ?? position
        guard
            let activeListeningEntryID,
            let entryIndex = listeningHistoryEntries.firstIndex(where: { $0.id == activeListeningEntryID })
        else {
            lastListeningPosition = currentPosition
            return
        }

        let delta = currentPosition - lastListeningPosition
        if isPlaying, delta > 0, delta < 5 {
            listeningHistoryEntries[entryIndex].listenedSeconds += delta
        }
        lastListeningPosition = currentPosition

        let listenedSeconds = listeningHistoryEntries[entryIndex].listenedSeconds
        if listenedSeconds - lastPersistedListeningSeconds >= 15 {
            lastPersistedListeningSeconds = listenedSeconds
            persistListeningHistory()
            scheduleListeningHistorySync()
        }
    }

    private func endListeningSession() {
        updateListeningSession()
        if activeListeningEntryID != nil {
            persistListeningHistory()
            scheduleListeningHistorySync()
        }
        activeListeningEntryID = nil
        lastListeningPosition = 0
        lastPersistedListeningSeconds = 0
    }

    private func persistListeningHistory() {
        guard let data = try? JSONEncoder().encode(listeningHistoryEntries) else { return }
        defaults.set(data, forKey: Self.listeningHistoryKey)
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
            likesDirty: likesDirty
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.libraryKey)
    }

    private func persistPlaybackPosition() {
        if let currentTrackID {
            defaults.set(currentTrackID.uuidString, forKey: Self.currentTrackKey)
        } else {
            defaults.removeObject(forKey: Self.currentTrackKey)
        }
        defaults.set(position, forKey: Self.positionKey)
    }

    func selectSyncProfile(matching query: String) async -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            serverMessage = "Enter a profile name or ID"
            return false
        }
        guard !isSyncingServer, !isUploadingServer, !isSyncingPlaylists else {
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
        activeSyncProfileName = profile.name
        guard profile.id != syncProfileID else {
            serverMessage = "Using \(profile.name)"
            persistLibrary()
            return
        }

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
        remoteSongs.removeAll()
        selectedRemoteSongIDs.removeAll()

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
            try Self.validate(response)
            let result = try JSONDecoder().decode(RemoteMetadataBackfill.self, from: data)
            processedTotal += result.processed

            if result.remaining <= 0 || result.processed <= 0 {
                break
            }
        }

        return processedTotal
    }

    private func normalizedServerURL() throws -> URL {
        let raw = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            var components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host != nil
        else { throw ServerSyncError.invalidURL }
        components.query = nil
        components.fragment = nil
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = components.url else { throw ServerSyncError.invalidURL }
        return url
    }

    private func saveServerConfiguration(base: URL) throws {
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ServerSyncError.missingToken }
        serverURLString = base.absoluteString
        serverToken = token
        if shouldPersistServerCredentials {
            defaults.set(base.absoluteString, forKey: Self.serverURLKey)
            Self.saveServerToken(token)
        }
    }

    private func persistServerCredentialsImmediately() {
        guard shouldPersistServerCredentials else { return }
        defaults.set(serverURLString, forKey: Self.serverURLKey)
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.saveServerToken(token)
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.saveServerToken(adminToken, account: Self.adminCredentialAccount)
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
            let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let localEntries = listeningHistoryEntries.filter {
                $0.originatedOnThisDevice != false
                    && $0.listenedSeconds.isFinite
                    && $0.listenedSeconds > 0
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
                        let uploadEntries = pendingEntries.map {
                            listeningHistoryUploadEntry($0, track: tracksByID[$0.trackID])
                        }
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
    ) -> ListeningHistoryUploadEntry {
        ListeningHistoryUploadEntry(
            id: entry.id.uuidString.lowercased(),
            trackID: entry.trackID.uuidString.lowercased(),
            songID: Self.limitedHistoryText(entry.remoteSongID ?? track?.remoteID, maximum: 128),
            startedAt: Self.listeningHistoryTimestamp(entry.startedAt),
            listenedSeconds: min(max(entry.listenedSeconds, 0), 31 * 24 * 60 * 60),
            title: Self.limitedHistoryText(entry.title ?? track?.title, maximum: 500),
            artist: Self.limitedHistoryText(entry.artist ?? track?.artist, maximum: 500),
            album: Self.limitedHistoryText(entry.album ?? track?.album, maximum: 500),
            durationSeconds: {
                let duration = entry.duration ?? track?.duration
                guard let duration, duration.isFinite, duration >= 0 else { return nil }
                return min(duration, 7 * 24 * 60 * 60)
            }()
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
        request.httpBody = try JSONEncoder().encode(ListeningHistoryUploadDocument(
            deviceID: listeningHistoryDeviceID,
            entries: entries
        ))
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
        let tracksByRemoteID: [String: Track] = Dictionary(
            uniqueKeysWithValues: tracks.compactMap { track in
                guard let remoteID = track.remoteID,
                      (track.syncProfileID ?? "default") == profileID else { return nil }
                return (remoteID, track) as (String, Track)
            }
        )
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var entriesByID = Dictionary(uniqueKeysWithValues: listeningHistoryEntries.map { ($0.id, $0) })

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

        let entriesByProfile = Dictionary(grouping: entriesByID.values) {
            $0.syncProfileID ?? "default"
        }
        listeningHistoryEntries = entriesByProfile.values
            .flatMap { entries in entries.sorted { $0.startedAt < $1.startedAt }.suffix(2_000) }
            .sorted { $0.startedAt < $1.startedAt }
        persistListeningHistory()
    }

    private func listeningHistorySyncKey(
        base: URL,
        profileID: String,
        eventID: UUID
    ) -> String {
        "\(base.absoluteString)#profile=\(profileID)#event=\(eventID.uuidString.lowercased())"
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
            let serverKey = "\(base.absoluteString)#profile=\(syncProfileID)"
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
                switch try await putRemotePlaylists(merge.document, base: base) {
                case .updated(let updated):
                    guard playlistSyncContextMatches(serverKey: serverKey, token: syncToken) else {
                        playlistSyncStatus = "Server changed; syncing playlists again…"
                        playlistSyncPending = true
                        return
                    }
                    if playlistMutationGeneration == submittedGeneration {
                        dirtyPlaylistIDs.subtract(submittedDirtyIDs)
                        deletedPlaylistIDs.subtract(submittedDeletedIDs)
                        likesDirty = false
                        applyRemotePlaylists(updated)
                        playlistSyncStatus = "Synced \(updated.playlists.count) playlist\(updated.playlists.count == 1 ? "" : "s")"
                    } else {
                        // The response represents the snapshot that was sent, not newer local
                        // edits. Apply only untouched remote playlists and immediately coalesce
                        // another pass for the remaining local mutations.
                        applyRemotePlaylists(
                            updated,
                            preservingLocalIDs: dirtyPlaylistIDs,
                            preservingLocalLikes: likesDirty
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
        return "\(currentBase.absoluteString)#profile=\(syncProfileID)" == serverKey
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

        return (
            RemotePlaylistsDocument(
                profileID: syncProfileID,
                revision: remote.revision,
                playlists: merged,
                likedSongIDs: likedSongIDs
            ),
            needsUpload
        )
    }

    private func remotePlaylist(from playlist: Playlist) -> RemotePlaylist {
        var songIDs: [String] = []
        for trackID in playlist.trackIDs {
            guard let remoteID = tracks.first(where: { $0.id == trackID })?.remoteID,
                  !songIDs.contains(remoteID) else { continue }
            songIDs.append(remoteID)
        }
        for remoteID in playlist.remoteSongIDs ?? [] where !songIDs.contains(remoteID) {
            songIDs.append(remoteID)
        }
        return RemotePlaylist(id: playlist.id, name: playlist.name, songIDs: songIDs)
    }

    private func applyRemotePlaylists(
        _ document: RemotePlaylistsDocument,
        preservingLocalIDs: Set<UUID> = [],
        preservingLocalLikes: Bool = false
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
            var downloadedTrackIDs = remote.songIDs.compactMap { remoteID in
                tracks.first(where: { $0.remoteID == remoteID })?.id
            }
            downloadedTrackIDs.append(contentsOf: localOnlyTrackIDs.filter { !downloadedTrackIDs.contains($0) })
            return Playlist(
                id: remote.id,
                name: remote.name,
                artwork: existing[remote.id]?.artwork ?? styles[offset % styles.count],
                trackIDs: downloadedTrackIDs,
                remoteSongIDs: remote.songIDs
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
                visibleTracks.first(where: { $0.remoteID == remoteID })?.id
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
            var hydrated = remoteSongIDs.compactMap { remoteID in
                tracks.first(where: { $0.remoteID == remoteID })?.id
            }
            hydrated.append(contentsOf: localOnlyTrackIDs.filter { !hydrated.contains($0) })
            playlists[index].trackIDs = hydrated
        }
    }

    private func updateRemoteSongIDs(forPlaylistAt index: Int) {
        guard playlists.indices.contains(index), !playlists[index].isSystem else { return }
        let previouslyUnresolved = (playlists[index].remoteSongIDs ?? []).filter { remoteID in
            !tracks.contains { $0.remoteID == remoteID }
        }
        var ordered = playlists[index].trackIDs.compactMap { trackID in
            tracks.first(where: { $0.id == trackID })?.remoteID
        }
        ordered.append(contentsOf: previouslyUnresolved.filter { !ordered.contains($0) })
        playlists[index].remoteSongIDs = ordered
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
        let resolvedProfileID = profileID ?? syncProfileID
        let resolvedSourceServer = sourceServer ?? (try? normalizedServerURL())?.absoluteString
        let sourceURL = resolvedSourceServer.flatMap(URL.init(string:))
        let duplicateIDs = Set(tracks.compactMap { candidate -> UUID? in
            guard candidate.id != trackID,
                  candidate.remoteID == resolvedRemoteID,
                  (candidate.syncProfileID ?? "default") == resolvedProfileID else { return nil }
            if let sourceURL,
               let candidateSource = candidate.sourceServer.flatMap(URL.init(string:)),
               !Self.sameOrigin(sourceURL, candidateSource) {
                return nil
            }
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
            playlists[index].trackIDs = remap(playlists[index].trackIDs)
            guard previouslyReferenced, !playlists[index].isSystem else { continue }
            updateRemoteSongIDs(forPlaylistAt: index)
            markPlaylistDirty(playlists[index].id)
        }

        historyTrackIDs = historyTrackIDs.map { duplicateIDs.contains($0) ? trackID : $0 }
        playbackContextTrackIDs = remap(playbackContextTrackIDs)
        shuffledTrackIDs = remap(shuffledTrackIDs)
        if let currentTrackID, duplicateIDs.contains(currentTrackID) { self.currentTrackID = trackID }
        if let loadedAudioTrackID, duplicateIDs.contains(loadedAudioTrackID) { self.loadedAudioTrackID = trackID }
        tracks.removeAll { duplicateIDs.contains($0.id) }

        if wasFavorite {
            playlistMutationGeneration &+= 1
            remoteLikedSongIDs.insert(resolvedRemoteID)
            dirtyRemoteLikeSongIDs.insert(resolvedRemoteID)
            likesDirty = true
        }
        hydrateRemotePlaylistTracks()
        persistHistory()
        persistPlaybackContext()
        persistShuffleQueue()
        persistPlaybackPosition()
        persistLibrary()
        reconcileShuffleOrderIfNeeded()
        schedulePlaylistSync()
        return true
    }

    @discardableResult
    func reconcileCachedUploadedLocalTracks() async -> Bool {
        let manager = FileManager.default
        let localCandidates = tracks.compactMap { track -> CachedUploadCandidate? in
            guard track.remoteID == nil,
                  let hash = track.contentSHA256?.lowercased(),
                  !hash.isEmpty,
                  let fileURL = track.fileURL,
                  let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                  size > 0 else { return nil }
            return CachedUploadCandidate(
                trackID: track.id,
                fileURL: fileURL,
                size: size,
                contentSHA256: hash,
                remoteID: nil,
                sourceServer: nil,
                profileID: nil
            )
        }
        guard !localCandidates.isEmpty else { return false }
        let localSizes = Set(localCandidates.map(\.size))
        let serverCandidates = tracks.compactMap { track -> CachedUploadCandidate? in
            guard let remoteID = track.remoteID,
                  (track.syncProfileID ?? "default") == syncProfileID,
                  let fileURL = track.fileURL,
                  manager.fileExists(atPath: fileURL.path),
                  let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
                  localSizes.contains(size) else { return nil }
            return CachedUploadCandidate(
                trackID: track.id,
                fileURL: fileURL,
                size: size,
                contentSHA256: track.contentSHA256?.lowercased(),
                remoteID: remoteID,
                sourceServer: track.sourceServer,
                profileID: track.syncProfileID
            )
        }
        guard !serverCandidates.isEmpty else { return false }

        let matches = await Task.detached(priority: .utility) {
            let localByContent = Dictionary(
                localCandidates.map { ("\($0.size)#\($0.contentSHA256 ?? "")", $0.trackID) },
                uniquingKeysWith: { first, _ in first }
            )
            return serverCandidates.compactMap { server -> CachedUploadMatch? in
                let hash = server.contentSHA256 ?? (try? Self.fileSHA256(at: server.fileURL))
                guard let hash,
                      let localTrackID = localByContent["\(server.size)#\(hash.lowercased())"] else { return nil }
                return CachedUploadMatch(localTrackID: localTrackID, serverTrackID: server.trackID)
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

    @discardableResult
    func reconcileDownloadedMediaKinds(with catalog: [RemoteSong]) -> Bool {
        let kindsByRemoteID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0.kind) })
        var changed = false
        for index in tracks.indices {
            guard let remoteID = tracks[index].remoteID,
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
        guard let catalog = try? await fetchRemoteCatalog(base: base) else { return }
        remoteSongs = catalog
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
        let manager = FileManager.default
        guard manager.fileExists(atPath: destination.path) else {
            try manager.moveItem(at: staging, to: destination)
            return
        }

        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: false)
        try manager.moveItem(at: destination, to: backup)
        do {
            try manager.moveItem(at: staging, to: destination)
            try? manager.removeItem(at: backup)
        } catch {
            try? manager.moveItem(at: backup, to: destination)
            throw error
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

    private func serverCacheDirectory(for base: URL) throws -> URL {
        let root = try serverCacheRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let rawName = (base.host ?? "server") + "-" + String(base.port ?? (base.scheme == "https" ? 443 : 80))
        let safeName = rawName.map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
        let directory = root
            .appendingPathComponent("Liked Songs", isDirectory: true)
            .appendingPathComponent("ServerCache", isDirectory: true)
            .appendingPathComponent(safeName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func clipDirectory() throws -> URL {
        let directory: URL
        if let clipLibraryRoot {
            directory = clipLibraryRoot
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Liked Songs", isDirectory: true)
                .appendingPathComponent("Clips", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func safeClipFilenameStem(_ title: String) -> String {
        let allowed = title.map { character in
            character.isLetter || character.isNumber || character == " " || character == "-" || character == "_"
                ? character
                : "-"
        }
        let stem = String(allowed.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? "Clip" : stem
    }

    private static var credentialStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Liked Songs", isDirectory: true)
            .appendingPathComponent("server-credentials.json")
    }

    private static var credentialStore: LocalServerCredentialStore {
        LocalServerCredentialStore(storeURL: credentialStoreURL)
    }

    private static func bootstrapCredentialStoreFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        guard let client = environment["LIKED_SONGS_CLIENT_TOKEN"],
              let admin = environment["LIKED_SONGS_ADMIN_TOKEN"],
              !client.isEmpty, !admin.isEmpty else { return }
        _ = credentialStore.save(client, account: clientCredentialAccount)
        _ = credentialStore.save(admin, account: adminCredentialAccount)
        unsetenv("LIKED_SONGS_CLIENT_TOKEN")
        unsetenv("LIKED_SONGS_ADMIN_TOKEN")
    }

    private static func readServerToken() -> String {
        credentialStore.read(account: clientCredentialAccount) ?? ""
    }

    private static func readServerToken(account: String) -> String {
        credentialStore.read(
            account: account == adminCredentialAccount ? adminCredentialAccount : clientCredentialAccount
        ) ?? ""
    }

    private static func saveServerToken(_ token: String) {
        _ = credentialStore.save(token, account: clientCredentialAccount)
    }

    private static func saveServerToken(_ token: String, account: String) {
        _ = credentialStore.save(
            token,
            account: account == adminCredentialAccount ? adminCredentialAccount : clientCredentialAccount
        )
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
