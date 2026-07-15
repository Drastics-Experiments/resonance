import AppKit
import AVFoundation
import Combine
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
    }

    private struct StoredServerCredentials: Codable {
        var clientToken = ""
        var adminToken = ""
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

    private enum ServerSyncError: LocalizedError {
        case invalidURL
        case missingToken
        case missingAdminToken
        case invalidResponse
        case server(Int)
        case serverMessage(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a complete http:// or https:// server URL."
            case .missingToken: "Enter the server access token."
            case .missingAdminToken: "Enter the server admin key to upload songs."
            case .invalidResponse: "The server returned an invalid response."
            case .server(let status): "The server returned HTTP \(status)."
            case .serverMessage(let status, let message): "The server returned HTTP \(status): \(message)"
            }
        }
    }

    private static let libraryKey = "LikedSongsFocus.library.v2"
    private static let legacyTracksKey = "LikedSongsFocus.importedTracks.v1"
    private static let serverURLKey = "LikedSongsFocus.serverURL.v1"
    private static let adminKeychainAccount = "music-server-admin-token"
    private static let volumeKey = "LikedSongsFocus.volume.v1"
    private static let playbackRateKey = "LikedSongsFocus.playbackRate.v1"
    private static let shuffleKey = "LikedSongsFocus.shuffle.v1"
    private static let repeatKey = "LikedSongsFocus.repeat.v1"
    private static let currentTrackKey = "LikedSongsFocus.currentTrack.v1"
    private static let positionKey = "LikedSongsFocus.position.v1"
    private static let historyKey = "LikedSongsFocus.history.v1"

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

    private let defaults: UserDefaults
    private let networkSession: URLSession
    private let serverCacheRoot: URL?
    private let shouldPersistServerCredentials: Bool
    private var audioPlayer: AVAudioPlayer?
    private var loadedAudioTrackID: UUID?
    private var playbackTimer: Timer?
    private var playbackContextTrackIDs: [UUID] = []
    private var shuffledTrackIDs: [UUID] = []
    private var historyTrackIDs: [UUID] = []
    private var navigationHistory: [NavigationLocation] = []
    private var navigationIndex = 0
    private var downloadTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var playlistSyncTask: Task<Void, Never>?
    private var playlistRevision = 0
    private var knownRemotePlaylistIDs: Set<UUID> = []
    private var dirtyPlaylistIDs: Set<UUID> = []
    private var deletedPlaylistIDs: Set<UUID> = []
    private var playlistSyncServerURL: String?

    init(
        loadPersistedLibrary: Bool = true,
        defaults: UserDefaults = .standard,
        networkSession: URLSession = .shared,
        serverCacheRoot: URL? = nil,
        persistServerCredentials: Bool = true
    ) {
        self.defaults = defaults
        self.networkSession = networkSession
        self.serverCacheRoot = serverCacheRoot
        self.shouldPersistServerCredentials = persistServerCredentials

        if persistServerCredentials { Self.bootstrapCredentialStoreFromEnvironment() }

        let stored = loadPersistedLibrary ? Self.loadLibrary(from: defaults) : nil
        let existingTracks = (stored?.tracks ?? []).filter { track in
            guard let url = track.fileURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
        var seenRemoteIDs = Set<String>()
        let availableTracks = existingTracks.filter { track in
            guard let remoteID = track.remoteID else { return true }
            return seenRemoteIDs.insert(remoteID).inserted
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
        serverAdminToken = persistServerCredentials ? Self.readServerToken(account: Self.adminKeychainAccount) : ""
        playlistRevision = stored?.playlistRevision ?? 0
        knownRemotePlaylistIDs = stored?.knownRemotePlaylistIDs ?? []
        dirtyPlaylistIDs = stored?.dirtyPlaylistIDs ?? []
        deletedPlaylistIDs = stored?.deletedPlaylistIDs ?? []
        playlistSyncServerURL = stored?.playlistSyncServerURL

        super.init()

        if defaults.object(forKey: Self.volumeKey) != nil { volume = defaults.double(forKey: Self.volumeKey) }
        if defaults.object(forKey: Self.playbackRateKey) != nil { playbackRate = Float(defaults.double(forKey: Self.playbackRateKey)) }
        shuffleEnabled = defaults.bool(forKey: Self.shuffleKey)
        repeatEnabled = defaults.bool(forKey: Self.repeatKey)
        position = defaults.double(forKey: Self.positionKey)
        historyTrackIDs = (defaults.stringArray(forKey: Self.historyKey) ?? [])
            .compactMap(UUID.init(uuidString:))
            .filter(validIDs.contains)
        navigationHistory = [NavigationLocation(section: .library, playlistID: nil)]
        defaults.set(volume, forKey: Self.volumeKey)
        defaults.set(Double(playbackRate), forKey: Self.playbackRateKey)
        persistPlaybackPosition()
        hydrateRemotePlaylistTracks()

        if loadPersistedLibrary, stored == nil {
            migrateLegacyLibraryIfNeeded()
        } else if loadPersistedLibrary, availableTracks.count != stored?.tracks.count {
            persistLibrary()
        }
    }

    deinit {
        playlistSyncTask?.cancel()
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
            return tracks
        }
    }

    var hasActiveLibraryFilter: Bool {
        filter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var queueTracks: [Track] {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        if queueTab == .history {
            return historyTrackIDs.reversed().compactMap { tracksByID[$0] }
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
        rebuildShuffleOrderIfNeeded()
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
        dirtyPlaylistIDs.insert(playlist.id)
        selectedPlaylistID = playlist.id
        section = .playlists
        persistLibrary()
        schedulePlaylistSync()
        return playlist
    }

    func deletePlaylist(_ playlist: Playlist) {
        guard !playlist.isSystem else { return }
        playlists.removeAll { $0.id == playlist.id }
        dirtyPlaylistIDs.remove(playlist.id)
        if knownRemotePlaylistIDs.contains(playlist.id) {
            deletedPlaylistIDs.insert(playlist.id)
        }
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
        dirtyPlaylistIDs.insert(playlist.id)
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
        dirtyPlaylistIDs.insert(playlistID)
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
            dirtyPlaylistIDs.insert(playlistID)
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
            dirtyPlaylistIDs.insert(playlistID)
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
        shuffledTrackIDs.removeAll { $0 == track.id }

        if removingCurrentTrack {
            currentTrackID = tracks.first?.id
            position = 0
        }
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

    func deleteDownloadedCopy(_ track: Track) {
        guard track.remoteID != nil, let fileURL = track.fileURL else { return }
        if currentTrackID == track.id { stopCurrentPlayback() }
        try? FileManager.default.removeItem(at: fileURL)
        removeTrackFromLibrary(track)
    }

    func deleteOriginalFile(_ track: Track) {
        guard track.remoteID == nil, let fileURL = track.fileURL else { return }
        if currentTrackID == track.id { stopCurrentPlayback() }
        try? FileManager.default.removeItem(at: fileURL)
        removeTrackFromLibrary(track)
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
        }
    }

    func connectAndSyncServer() {
        refreshServerCatalog()
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
        downloadTask = Task { await syncServerLibrary(songIDs: nil, reconcile: true) }
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
                var request = URLRequest(url: base.appendingPathComponent("api/v1/admin/songs/\(song.id)"))
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(adminToken)", forHTTPHeaderField: "Authorization")
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
            remoteSongs = try await fetchRemoteCatalog(base: base)
            selectedRemoteSongIDs.formIntersection(Set(remoteSongs.map(\.id)))
            serverMessage = "Connected • \(remoteSongs.count) \(remoteSongs.count == 1 ? "song" : "songs") available"
        } catch {
            serverMessage = error.localizedDescription
        }
    }

    func syncServerLibrary(songIDs: Set<String>? = nil, reconcile: Bool = false) async {
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
            let songs = songIDs.map { ids in catalogSongs.filter { ids.contains($0.id) } } ?? catalogSongs
            downloadStatus = songs.isEmpty ? "Nothing to download" : "Checking \(songs.count) songs"
            let cache = try serverCacheDirectory(for: base)
            var changedCount = 0
            var failedCount = 0

            for (index, remote) in songs.enumerated() {
                try Task.checkCancellation()
                downloadCurrentFile = remote.filename
                downloadStatus = "Downloading \(index + 1) of \(songs.count)"
                let ext = PathExtension.safe(remote.filename)
                let destination = cache.appendingPathComponent(remote.id + ext)
                let existingIndex = tracks.firstIndex { $0.remoteID == remote.id }
                let previousCachedURL = existingIndex.flatMap { tracks[$0].fileURL }
                let localSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

                if existingIndex != nil, localSize == remote.size {
                    downloadProgress = Double(index + 1) / Double(max(songs.count, 1))
                    continue
                }

                do {
                    if localSize != remote.size {
                        let downloadURL = try remoteURL(remote.downloadURL, relativeTo: base)
                        var request = authenticatedRequest(url: downloadURL)
                        request.timeoutInterval = 120
                        let (temporaryURL, response) = try await networkSession.download(for: request)
                        try Self.validate(response)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.moveItem(at: temporaryURL, to: destination)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedCount += 1
                    downloadProgress = Double(index + 1) / Double(max(songs.count, 1))
                    continue
                }

                guard let player = try? AVAudioPlayer(contentsOf: destination) else { continue }
                let metadata = await Self.metadata(for: destination)
                let fallbackStem = destination.deletingPathExtension().lastPathComponent
                let track = Track(
                    id: existingIndex.map { tracks[$0].id } ?? UUID(),
                    title: metadata.title == fallbackStem ? remote.title : metadata.title,
                    artist: metadata.artist == "Unknown Artist" ? remote.artist : metadata.artist,
                    album: metadata.album == "Unknown Album" ? remote.album : metadata.album,
                    duration: player.duration,
                    artwork: existingIndex.map { tracks[$0].artwork } ?? ArtworkStyle.allCases[tracks.count % ArtworkStyle.allCases.count],
                    artworkData: metadata.artworkData,
                    fileURL: destination,
                    remoteID: remote.id,
                    sourceServer: base.absoluteString,
                    dateAdded: existingIndex.map { tracks[$0].dateAdded } ?? .now
                )

                if let existingIndex {
                    tracks[existingIndex] = track
                    if let previousCachedURL,
                       previousCachedURL.standardizedFileURL != destination.standardizedFileURL,
                       previousCachedURL.path.contains("ServerCache") {
                        try? FileManager.default.removeItem(at: previousCachedURL)
                    }
                } else {
                    tracks.append(track)
                }
                changedCount += 1
                downloadProgress = Double(index + 1) / Double(max(songs.count, 1))
            }

            if reconcile {
                let liveIDs = Set(catalogSongs.map(\.id))
                let stale = tracks.filter { $0.remoteID.map { !liveIDs.contains($0) } ?? false }
                for track in stale { removeTrackFromLibrary(track) }
            }

            if currentTrackID == nil { currentTrackID = tracks.first?.id }
            hydrateRemotePlaylistTracks()
            persistLibrary()
            rebuildShuffleOrderIfNeeded()
            serverMessage = changedCount == 0
                ? "Up to date • \(songs.count) server \(songs.count == 1 ? "song" : "songs")"
                : "Synced \(changedCount) \(changedCount == 1 ? "song" : "songs")"
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
        persistLibrary()
    }

    func toggleShuffle() {
        shuffleEnabled.toggle()
        shuffleEnabled ? rebuildShuffleOrder() : shuffledTrackIDs.removeAll()
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
        position = track.duration * fraction.clamped(to: 0...1)
        if loadedAudioTrackID == track.id {
            audioPlayer?.currentTime = position
        }
        persistPlaybackPosition()
    }

    func importLocalFiles() {
        let panel = NSOpenPanel()
        panel.title = "Add Music to Your Library"
        panel.message = "Choose audio files or folders. Your files stay where they are on this Mac."
        panel.prompt = "Add Music"
        panel.allowedContentTypes = [.audio, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importLocalFiles(at: urls) }
    }

    func importLocalFiles(at selectedURLs: [URL]) async {
        let urls = Self.expandedAudioURLs(from: selectedURLs)
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
        rebuildShuffleOrderIfNeeded()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        position = currentTrack?.duration ?? player.duration
        isPlaying = false
        stopPlaybackTimer()
        next()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        isPlaying = false
        stopPlaybackTimer()
    }

    private var playbackTracks: [Track] {
        section == .storage ? tracks : displayedTracks
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
    }

    private func ensurePlaybackContext(containing trackID: UUID) {
        guard !activePlaybackTracks.contains(where: { $0.id == trackID }) || playbackContextTrackIDs.isEmpty else { return }
        setPlaybackContext(playbackTracks, ensuring: trackID)
    }

    private func captureFallbackPlaybackContextIfNeeded(_ context: [Track]) {
        guard playbackContextTrackIDs.isEmpty else { return }
        playbackContextTrackIDs = context.map(\.id)
    }

    private func startTrack(_ trackID: UUID, preservingShuffleQueue: Bool) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        recordCurrentTrackInHistory(whenSwitchingTo: track.id)
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
        if isPlaying { startPlaybackTimer() }
    }

    private func pausePlayback() {
        audioPlayer?.pause()
        position = audioPlayer?.currentTime ?? position
        isPlaying = false
        stopPlaybackTimer()
        persistPlaybackPosition()
    }

    private func stopCurrentPlayback() {
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

    private func rebuildShuffleOrderIfNeeded() {
        if shuffleEnabled { rebuildShuffleOrder() }
    }

    private func rebuildShuffleOrder() {
        shuffledTrackIDs = activePlaybackTracks.map(\.id).filter { $0 != currentTrackID }.shuffled()
    }

    private func recordCurrentTrackInHistory(whenSwitchingTo newTrackID: UUID) {
        guard let currentTrackID, currentTrackID != newTrackID else { return }
        historyTrackIDs.append(currentTrackID)
        if historyTrackIDs.count > 100 { historyTrackIDs.removeFirst(historyTrackIDs.count - 100) }
        defaults.set(historyTrackIDs.map(\.uuidString), forKey: Self.historyKey)
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
            playlistSyncServerURL: playlistSyncServerURL
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
        if !token.isEmpty {
            Self.saveServerToken(token)
        }
        let adminToken = serverAdminToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !adminToken.isEmpty {
            Self.saveServerToken(adminToken, account: Self.adminKeychainAccount)
        }
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

    func syncPlaylistsNow() async {
        guard !isSyncingPlaylists else { return }

        do {
            let base = try normalizedServerURL()
            try saveServerConfiguration(base: base)
            let serverKey = base.absoluteString
            if playlistSyncServerURL != serverKey {
                playlistSyncServerURL = serverKey
                playlistRevision = 0
                knownRemotePlaylistIDs.removeAll()
                deletedPlaylistIDs.removeAll()
                dirtyPlaylistIDs.formUnion(playlists.filter { !$0.isSystem }.map(\.id))
            }

            isSyncingPlaylists = true
            playlistSyncStatus = "Syncing playlists…"
            defer { isSyncingPlaylists = false }

            var remoteDocument = try await fetchRemotePlaylists(base: base)
            var attempts = 0
            while attempts < 2 {
                let merge = mergedPlaylistDocument(from: remoteDocument)
                if !merge.needsUpload {
                    applyRemotePlaylists(remoteDocument)
                    playlistSyncStatus = "Synced \(remoteDocument.playlists.count) playlist\(remoteDocument.playlists.count == 1 ? "" : "s")"
                    return
                }

                switch try await putRemotePlaylists(merge.document, base: base) {
                case .updated(let updated):
                    dirtyPlaylistIDs.removeAll()
                    deletedPlaylistIDs.removeAll()
                    applyRemotePlaylists(updated)
                    playlistSyncStatus = "Synced \(updated.playlists.count) playlist\(updated.playlists.count == 1 ? "" : "s")"
                    return
                case .conflict(let current):
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
            isSyncingPlaylists = false
            playlistSyncStatus = "Playlist sync failed: \(error.localizedDescription)"
        }
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
        guard status == 200 else { throw Self.playlistServerError(status: status, data: data) }
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
        throw Self.playlistServerError(status: status, data: data)
    }

    private static func playlistServerError(status: Int, data: Data) -> ServerSyncError {
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
        var needsUpload = !deletedPlaylistIDs.isEmpty

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

        return (
            RemotePlaylistsDocument(revision: remote.revision, playlists: merged),
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

    private func applyRemotePlaylists(_ document: RemotePlaylistsDocument) {
        let existing = Dictionary(uniqueKeysWithValues: playlists.filter { !$0.isSystem }.map { ($0.id, $0) })
        let systemPlaylists = playlists.filter(\.isSystem)
        let styles: [ArtworkStyle] = [.lateNight, .softFocus, .onRepeat, .electric, .golden, .falling]
        let syncedPlaylists = document.playlists.enumerated().map { offset, remote -> Playlist in
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

        playlists = systemPlaylists + syncedPlaylists
        playlistRevision = document.revision
        knownRemotePlaylistIDs = Set(document.playlists.map(\.id))
        dirtyPlaylistIDs.subtract(knownRemotePlaylistIDs)
        if let selectedPlaylistID, !playlists.contains(where: { $0.id == selectedPlaylistID }) {
            self.selectedPlaylistID = nil
            section = .playlists
        }
        persistLibrary()
        rebuildShuffleOrderIfNeeded()
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

    private func schedulePlaylistSync() {
        playlistSyncTask?.cancel()
        guard !serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        playlistSyncTask = Task { [weak self] in
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

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func remoteURL(_ path: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else {
            throw ServerSyncError.invalidResponse
        }
        return url
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ServerSyncError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ServerSyncError.server(http.statusCode) }
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

    private static var credentialStoreURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("Liked Songs", isDirectory: true)
            .appendingPathComponent("server-credentials.json")
    }

    private static func readCredentials() -> StoredServerCredentials {
        guard let data = try? Data(contentsOf: credentialStoreURL) else { return StoredServerCredentials() }
        return (try? JSONDecoder().decode(StoredServerCredentials.self, from: data)) ?? StoredServerCredentials()
    }

    private static func writeCredentials(_ credentials: StoredServerCredentials) {
        let url = credentialStoreURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func bootstrapCredentialStoreFromEnvironment() {
        let environment = ProcessInfo.processInfo.environment
        guard let client = environment["LIKED_SONGS_CLIENT_TOKEN"],
              let admin = environment["LIKED_SONGS_ADMIN_TOKEN"],
              !client.isEmpty, !admin.isEmpty else { return }
        writeCredentials(StoredServerCredentials(clientToken: client, adminToken: admin))
        unsetenv("LIKED_SONGS_CLIENT_TOKEN")
        unsetenv("LIKED_SONGS_ADMIN_TOKEN")
    }

    private static func readServerToken() -> String {
        readCredentials().clientToken
    }

    private static func readServerToken(account: String) -> String {
        account == adminKeychainAccount ? readCredentials().adminToken : readCredentials().clientToken
    }

    private static func saveServerToken(_ token: String) {
        var credentials = readCredentials()
        credentials.clientToken = token
        writeCredentials(credentials)
    }

    private static func saveServerToken(_ token: String, account: String) {
        var credentials = readCredentials()
        if account == adminKeychainAccount { credentials.adminToken = token }
        else { credentials.clientToken = token }
        writeCredentials(credentials)
    }

    private enum PathExtension {
        static func safe(_ filename: String) -> String {
            let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
            let safe = ext.filter { $0.isLetter || $0.isNumber }
            return safe.isEmpty ? "" : "." + safe
        }
    }

    private static func loadLibrary(from defaults: UserDefaults) -> StoredLibrary? {
        guard
            let data = defaults.data(forKey: libraryKey),
            let stored = try? JSONDecoder().decode(StoredLibrary.self, from: data)
        else { return nil }
        return stored
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

    private nonisolated static func expandedAudioURLs(from selectedURLs: [URL]) -> [URL] {
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
                    if isSupportedAudioFile(item) { results.append(item) }
                }
            } else if isSupportedAudioFile(url) {
                results.append(url)
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private nonisolated static func isSupportedAudioFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio)
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
