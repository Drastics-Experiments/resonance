import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Security
import UIKit

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
    @Published var tracks: [MobileTrack] = []
    @Published var playlists: [MobilePlaylist] = [MobilePlaylist(name: "Liked Songs", isSystem: true)]
    @Published var favorites: Set<UUID> = []
    @Published var currentTrackID: UUID?
    @Published var isPlaying = false
    @Published var position: TimeInterval = 0
    @Published var volume: Double = 0.8 { didSet { player?.volume = Float(volume); UserDefaults.standard.set(volume, forKey: "Resonance.volume") } }
    @Published var playbackRate: Float = 1 { didSet { player?.rate = playbackRate; UserDefaults.standard.set(Double(playbackRate), forKey: "Resonance.rate") } }
    @Published var shuffleEnabled = false { didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "Resonance.shuffle") } }
    @Published var repeatEnabled = false { didSet { UserDefaults.standard.set(repeatEnabled, forKey: "Resonance.repeat") } }
    @Published var searchText = ""
    @Published var serverURL = "https://music.unblocked.mov"
    @Published var serverToken = "" { didSet { if !serverToken.isEmpty { Self.saveToken(serverToken, account: "client") } } }
    @Published var serverAdminToken = "" { didSet { if !serverAdminToken.isEmpty { Self.saveToken(serverAdminToken, account: "admin") } } }
    @Published var remoteSongs: [MobileRemoteSong] = []
    @Published var selectedRemoteSongIDs: Set<String> = []
    @Published var serverMessage = "Not connected"
    @Published var isSyncing = false
    @Published var isDownloading = false
    @Published var isUploading = false
    @Published var isRefreshingCatalog = false
    @Published var downloadProgress = 0.0
    @Published var uploadProgress = 0.0
    @Published var downloadDetail = "Idle"
    @Published var uploadDetail = "Idle"
    @Published var isSyncingPlaylists = false
    @Published var playlistSyncDetail = "Not synced"

    private let fileManager = FileManager.default
    private let root: URL
    private let musicDirectory: URL
    private let artworkDirectory: URL
    private let stateURL: URL
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
    private var knownRemotePlaylistIDs: Set<UUID> = []
    private var dirtyPlaylistIDs: Set<UUID> = []
    private var deletedPlaylistIDs: Set<UUID> = []
    private var playlistSyncServerURL: String?
    private var playlistSyncTask: Task<Void, Never>?

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
        super.init()
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        load()
        if UserDefaults.standard.object(forKey: "Resonance.volume") != nil { volume = UserDefaults.standard.double(forKey: "Resonance.volume") }
        if UserDefaults.standard.object(forKey: "Resonance.rate") != nil { playbackRate = Float(UserDefaults.standard.double(forKey: "Resonance.rate")) }
        shuffleEnabled = UserDefaults.standard.bool(forKey: "Resonance.shuffle")
        repeatEnabled = UserDefaults.standard.bool(forKey: "Resonance.repeat")
        serverToken = Self.readToken(account: "client")
        serverAdminToken = Self.readToken(account: "admin")
        configureAudioSession()
        observeAudioSession()
        configureRemoteCommands()
        Task { [weak self] in
            await self?.refreshEmbeddedMetadata()
        }
    }

    deinit {
        timer?.invalidate()
        playlistSyncTask?.cancel()
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var currentTrack: MobileTrack? {
        guard let currentTrackID else { return nil }
        return tracks.first { $0.id == currentTrackID }
    }

    var filteredTracks: [MobileTrack] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    func fileURL(for track: MobileTrack) -> URL {
        musicDirectory.appendingPathComponent(track.relativePath)
    }

    func artwork(for track: MobileTrack) -> UIImage? {
        guard let filename = track.artworkFilename else { return nil }
        if let cached = artworkCache[filename] { return cached }
        guard let image = UIImage(contentsOfFile: artworkDirectory.appendingPathComponent(filename).path) else { return nil }
        artworkCache[filename] = image
        return image
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
        if currentTrackID == nil { currentTrackID = tracks.first?.id }
        save()
    }

    func play(_ track: MobileTrack) {
        play(track, in: tracks)
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
        if recordHistory, currentTrackID != track.id, let currentTrackID {
            history.append(currentTrackID)
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: fileURL(for: track))
            next.delegate = self
            next.enableRate = true
            next.volume = Float(volume)
            next.rate = playbackRate
            next.prepareToPlay()
            let resumePosition = min(max(requestedPosition, 0), next.duration)
            next.currentTime = resumePosition
            guard next.play() else {
                isPlaying = false
                return
            }
            player = next
            currentTrackID = track.id
            UserDefaults.standard.set(track.id.uuidString, forKey: "Resonance.currentTrack")
            isPlaying = true
            position = resumePosition
            startTimer()
            updateNowPlaying()
        } catch {
            isPlaying = false
        }
    }

    func togglePlay() {
        if player?.isPlaying == true || isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard let player else {
            if let track = currentTrack ?? tracks.first { play(track) }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            player.rate = playbackRate
            isPlaying = player.play()
            if isPlaying { startTimer() }
        } catch {
            isPlaying = false
        }
        updateNowPlaying()
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
        position = player.currentTime
        updateNowPlaying()
    }

    func next() {
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
        if let player, player.currentTime > 3 {
            player.currentTime = 0
            position = 0
            updateNowPlaying()
            return
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

    private var activeQueue: [MobileTrack] {
        let queuedTracks = playbackQueue.compactMap { id in tracks.first { $0.id == id } }
        if playbackPlaylistID != nil { return queuedTracks }
        return queuedTracks.isEmpty ? tracks : queuedTracks
    }

    func toggleFavorite(_ track: MobileTrack) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        normalizeSystemPlaylist()
        save()
    }

    func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = MobilePlaylist(name: trimmed, remoteSongIDs: [])
        playlists.append(playlist)
        dirtyPlaylistIDs.insert(playlist.id)
        save()
        schedulePlaylistSync()
    }

    func deletePlaylist(_ playlist: MobilePlaylist) {
        guard !playlist.isSystem,
              playlists.contains(where: { $0.id == playlist.id }) else { return }

        playlists.removeAll { $0.id == playlist.id }
        dirtyPlaylistIDs.remove(playlist.id)
        deletedPlaylistIDs.insert(playlist.id)

        if playbackPlaylistID == playlist.id {
            playbackPlaylistID = nil
            playbackQueue = tracks.map(\.id)
        }

        save()
        schedulePlaylistSync()
    }

    func add(_ track: MobileTrack, to playlist: MobilePlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }), !playlists[index].isSystem else { return }
        if !playlists[index].trackIDs.contains(track.id) {
            playlists[index].trackIDs.append(track.id)
            updateRemoteSongIDs(forPlaylistAt: index)
            dirtyPlaylistIDs.insert(playlist.id)
            if playbackPlaylistID == playlist.id {
                playbackQueue = playlists[index].trackIDs
            }
        }
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
        if currentTrackID == track.id { player?.stop(); player = nil; isPlaying = false }
        try? fileManager.removeItem(at: fileURL(for: track))
        if let artworkFilename = track.artworkFilename {
            try? fileManager.removeItem(at: artworkDirectory.appendingPathComponent(artworkFilename))
            artworkCache.removeValue(forKey: artworkFilename)
        }
        tracks.removeAll { $0.id == track.id }
        playbackQueue.removeAll { $0 == track.id }
        history.removeAll { $0 == track.id }
        favorites.remove(track.id)
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == track.id } }
        currentTrackID = tracks.first?.id
        position = 0
        normalizeSystemPlaylist()
        save()
    }

    func refreshCatalog() async {
        guard !isRefreshingCatalog else { return }
        isRefreshingCatalog = true
        defer { isRefreshingCatalog = false }
        await sync(songIDs: [])
        await syncPlaylistsNow()
    }
    func downloadSelected() async {
        guard !selectedRemoteSongIDs.isEmpty else { downloadDetail = "Select one or more songs first"; return }
        await sync(songIDs: selectedRemoteSongIDs)
        await syncPlaylistsNow()
    }
    func download(_ song: MobileRemoteSong) async {
        await sync(songIDs: [song.id])
        await syncPlaylistsNow()
    }
    func downloadAll() async {
        await sync(songIDs: nil)
        await syncPlaylistsNow()
    }

    func toggleRemoteSelection(_ song: MobileRemoteSong) {
        if selectedRemoteSongIDs.contains(song.id) { selectedRemoteSongIDs.remove(song.id) }
        else { selectedRemoteSongIDs.insert(song.id) }
    }

    func isSynced(_ song: MobileRemoteSong) -> Bool {
        tracks.contains { $0.remoteID == song.id }
    }

    private func sync(songIDs: Set<String>?) async {
        guard let baseURL = normalizedServer() else { serverMessage = "Enter a valid server URL."; return }
        guard !serverToken.isEmpty else { serverMessage = "Enter the access token."; return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            var catalogRequest = URLRequest(url: baseURL.appendingPathComponent("api/v1/songs"))
            catalogRequest.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
            let (catalogData, response) = try await URLSession.shared.data(for: catalogRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try JSONDecoder().decode(MobileRemoteCatalog.self, from: catalogData)
            remoteSongs = catalog.songs
            selectedRemoteSongIDs.formIntersection(Set(catalog.songs.map(\.id)))
            if songIDs == nil || !(songIDs?.isEmpty ?? true) {
                let requestedSongs = songIDs.map { ids in catalog.songs.filter { ids.contains($0.id) } } ?? catalog.songs
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
                for song in songs {
                    downloadDetail = "Downloading \(completed + 1) of \(songs.count) • \(song.filename)"
                    guard let remoteURL = URL(string: song.downloadURL, relativeTo: baseURL)?.absoluteURL else { continue }
                    var request = URLRequest(url: remoteURL)
                    request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
                    let (data, downloadResponse) = try await URLSession.shared.data(for: request)
                    guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let filename = uniqueFilename(song.filename)
                    let destination = musicDirectory.appendingPathComponent(filename)
                    try data.write(to: destination, options: .atomic)
                    let audio = try AVAudioPlayer(contentsOf: destination)
                    let metadata = await embeddedMetadata(at: destination)
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
                        artworkFilename: saveArtwork(metadata.artworkData, for: trackID),
                        artworkScanComplete: true
                    ))
                    completed += 1
                    downloadProgress = Double(completed) / Double(max(songs.count, 1))
                }
                normalizeSystemPlaylist()
                hydrateRemotePlaylistTracks()
                save()
                selectedRemoteSongIDs.subtract(Set(songs.map(\.id)))
                downloadDetail = "Downloaded \(completed) song\(completed == 1 ? "" : "s")"
                serverMessage = "Synced \(completed) song\(completed == 1 ? "" : "s")"
            } else {
                serverMessage = "Connected • \(catalog.count) song\(catalog.count == 1 ? "" : "s")"
            }
            Self.saveToken(serverToken, account: "client")
            if !serverAdminToken.isEmpty { Self.saveToken(serverAdminToken, account: "admin") }
        } catch {
            serverMessage = "Connection failed: \(error.localizedDescription)"
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

    func uploadFiles(_ urls: [URL]) async {
        guard let baseURL = normalizedServer(), !serverAdminToken.isEmpty else { uploadDetail = "Enter the server admin key"; return }
        isUploading = true
        uploadProgress = 0
        defer { isUploading = false }
        var completed = 0
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            do {
                uploadDetail = "Uploading \(completed + 1) of \(urls.count) • \(source.lastPathComponent)"
                var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/admin/songs"), resolvingAgainstBaseURL: false)
                components?.queryItems = [URLQueryItem(name: "filename", value: source.lastPathComponent)]
                guard let url = components?.url else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "PUT"
                request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
                let (_, response) = try await URLSession.shared.upload(for: request, fromFile: source)
                guard (response as? HTTPURLResponse)?.statusCode == 201 else { continue }
                completed += 1
                uploadProgress = Double(completed) / Double(max(urls.count, 1))
            } catch { continue }
        }
        Self.saveToken(serverAdminToken, account: "admin")
        uploadDetail = "Uploaded \(completed) song\(completed == 1 ? "" : "s")"
        await refreshCatalog()
    }

    func deleteRemoteSong(_ song: MobileRemoteSong) async {
        guard let baseURL = normalizedServer(), !serverAdminToken.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/admin/songs/\(song.id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(serverAdminToken)", forHTTPHeaderField: "Authorization")
        if let (_, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 204 {
            remoteSongs.removeAll { $0.id == song.id }
            selectedRemoteSongIDs.remove(song.id)
        }
    }

    func syncPlaylistsNow() async {
        guard !isSyncingPlaylists else { return }
        guard let baseURL = normalizedServer() else {
            playlistSyncDetail = "Enter a valid server URL"
            return
        }
        guard !serverToken.isEmpty else {
            playlistSyncDetail = "Enter the access token"
            return
        }

        let serverKey = baseURL.absoluteString
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
            var attempts = 0

            while attempts < 2 {
                let merge = mergedPlaylistDocument(from: remoteDocument)
                if !merge.needsUpload {
                    applyRemotePlaylists(remoteDocument)
                    playlistSyncDetail = "Synced \(remoteDocument.playlists.count) playlist\(remoteDocument.playlists.count == 1 ? "" : "s")"
                    return
                }

                switch try await putRemotePlaylists(merge.document, to: baseURL) {
                case .updated(let updated):
                    dirtyPlaylistIDs.removeAll()
                    deletedPlaylistIDs.removeAll()
                    applyRemotePlaylists(updated)
                    playlistSyncDetail = "Synced \(updated.playlists.count) playlist\(updated.playlists.count == 1 ? "" : "s")"
                    return
                case .conflict(let current):
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

    private func mergedPlaylistDocument(
        from remote: MobileRemotePlaylistsDocument
    ) -> (document: MobileRemotePlaylistsDocument, needsUpload: Bool) {
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
            MobileRemotePlaylistsDocument(revision: remote.revision, playlists: merged),
            needsUpload
        )
    }

    private func remotePlaylist(from playlist: MobilePlaylist) -> MobileRemotePlaylist {
        var songIDs: [String] = []
        for trackID in playlist.trackIDs {
            guard let remoteID = tracks.first(where: { $0.id == trackID })?.remoteID,
                  !songIDs.contains(remoteID) else { continue }
            songIDs.append(remoteID)
        }
        for remoteID in playlist.remoteSongIDs ?? [] where !songIDs.contains(remoteID) {
            songIDs.append(remoteID)
        }
        return MobileRemotePlaylist(id: playlist.id, name: playlist.name, songIDs: songIDs)
    }

    private func applyRemotePlaylists(_ document: MobileRemotePlaylistsDocument) {
        let existing = Dictionary(uniqueKeysWithValues: playlists.filter { !$0.isSystem }.map { ($0.id, $0) })
        let systemPlaylists = playlists.filter(\.isSystem)
        let remotePlaylists = document.playlists.map { remote -> MobilePlaylist in
            let localOnlyTrackIDs = existing[remote.id]?.trackIDs.filter { trackID in
                tracks.first(where: { $0.id == trackID })?.remoteID == nil
            } ?? []
            let downloadedTrackIDs = remote.songIDs.compactMap { remoteID in
                tracks.first(where: { $0.remoteID == remoteID })?.id
            }
            var combined = downloadedTrackIDs
            combined.append(contentsOf: localOnlyTrackIDs.filter { !combined.contains($0) })
            return MobilePlaylist(
                id: remote.id,
                name: remote.name,
                trackIDs: combined,
                remoteSongIDs: remote.songIDs
            )
        }

        playlists = systemPlaylists + remotePlaylists
        playlistRevision = document.revision
        knownRemotePlaylistIDs = Set(document.playlists.map(\.id))
        dirtyPlaylistIDs.subtract(knownRemotePlaylistIDs)
        normalizeSystemPlaylist()
        save()
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
        guard !serverToken.isEmpty else { return }
        playlistSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.syncPlaylistsNow()
        }
    }

    private func normalizedServer() -> URL? {
        guard var components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https" || components.scheme == "http",
              components.host != nil else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.url
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
        let stored = MobileStoredLibrary(
            tracks: tracks,
            playlists: playlists,
            favorites: favorites,
            serverURL: serverURL,
            playlistRevision: playlistRevision,
            knownRemotePlaylistIDs: knownRemotePlaylistIDs,
            dirtyPlaylistIDs: dirtyPlaylistIDs,
            deletedPlaylistIDs: deletedPlaylistIDs,
            playlistSyncServerURL: playlistSyncServerURL
        )
        if let data = try? JSONEncoder().encode(stored) { try? data.write(to: stateURL, options: .atomic) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL), let stored = try? JSONDecoder().decode(MobileStoredLibrary.self, from: data) else { return }
        var seenRemoteIDs = Set<String>()
        tracks = stored.tracks.filter { fileManager.fileExists(atPath: musicDirectory.appendingPathComponent($0.relativePath).path) }
            .filter { track in guard let remoteID = track.remoteID else { return true }; return seenRemoteIDs.insert(remoteID).inserted }
        playlists = stored.playlists
        favorites = stored.favorites.intersection(Set(tracks.map(\.id)))
        serverURL = stored.serverURL
        playlistRevision = stored.playlistRevision ?? 0
        knownRemotePlaylistIDs = stored.knownRemotePlaylistIDs ?? []
        dirtyPlaylistIDs = stored.dirtyPlaylistIDs ?? []
        deletedPlaylistIDs = stored.deletedPlaylistIDs ?? []
        playlistSyncServerURL = stored.playlistSyncServerURL
        hydrateRemotePlaylistTracks()
        normalizeSystemPlaylist()
        let savedID = UserDefaults.standard.string(forKey: "Resonance.currentTrack").flatMap(UUID.init(uuidString:))
        currentTrackID = savedID.flatMap { wanted in tracks.first(where: { $0.id == wanted })?.id } ?? tracks.first?.id
        position = UserDefaults.standard.double(forKey: "Resonance.position")
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
            wasPlayingBeforeInterruption = player?.isPlaying == true || isPlaying
            isPlaying = false
            updateNowPlaying()

        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            let shouldResume = wasPlayingBeforeInterruption && options.contains(.shouldResume)
            wasPlayingBeforeInterruption = false
            guard shouldResume, let player else { return }

            do {
                try AVAudioSession.sharedInstance().setActive(true)
                player.rate = playbackRate
                isPlaying = player.play()
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
        timer?.invalidate()
        let playbackTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                UserDefaults.standard.set(self.position, forKey: "Resonance.position")
                self.isPlaying = player.isPlaying
                self.updateNowPlaying()
            }
        }
        timer = playbackTimer
        RunLoop.main.add(playbackTimer, forMode: .common)
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
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
            if self.repeatEnabled, let track = self.currentTrack {
                self.startPlayback(track, recordHistory: false)
            } else {
                self.next()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.isPlaying = false
            if self.activeQueue.count > 1 {
                self.next()
            } else {
                self.updateNowPlaying()
            }
        }
    }

    private static let keychainService = "com.gavindietrich.LikedSongsMobile"
    private static func saveToken(_ token: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var value = query
        value[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(value as CFDictionary, nil)
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
        return String(data: data, encoding: .utf8) ?? ""
    }
}
