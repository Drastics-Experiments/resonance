import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Security

@MainActor
final class MusicLibrary: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
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
    @Published var isUploading = false
    @Published var downloadProgress = 0.0
    @Published var uploadProgress = 0.0
    @Published var downloadDetail = "Idle"
    @Published var uploadDetail = "Idle"

    private let fileManager = FileManager.default
    private let root: URL
    private let musicDirectory: URL
    private let stateURL: URL
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var history: [UUID] = []

    override init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("LikedSongsMobile", isDirectory: true)
        musicDirectory = root.appendingPathComponent("Music", isDirectory: true)
        stateURL = root.appendingPathComponent("library.json")
        super.init()
        try? fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        load()
        if UserDefaults.standard.object(forKey: "Resonance.volume") != nil { volume = UserDefaults.standard.double(forKey: "Resonance.volume") }
        if UserDefaults.standard.object(forKey: "Resonance.rate") != nil { playbackRate = Float(UserDefaults.standard.double(forKey: "Resonance.rate")) }
        shuffleEnabled = UserDefaults.standard.bool(forKey: "Resonance.shuffle")
        repeatEnabled = UserDefaults.standard.bool(forKey: "Resonance.repeat")
        serverToken = Self.readToken(account: "client")
        serverAdminToken = Self.readToken(account: "admin")
        if ProcessInfo.processInfo.environment["RESONANCE_PREVIEW_DATA"] == "1" {
            configurePreviewLibrary()
        }
        configureAudioSession()
        configureRemoteCommands()
    }

    deinit { timer?.invalidate() }

    private func configurePreviewLibrary() {
        tracks = [
            MobileTrack(title: "Glass", artist: "System Sounds", album: "Waveforms", duration: 222, relativePath: "Glass.aiff"),
            MobileTrack(title: "Soft Focus", artist: "Autumn Keys", album: "In Between", duration: 258, relativePath: "Soft Focus.m4a"),
            MobileTrack(title: "Late Night", artist: "Midnight Drive", album: "City Lights", duration: 235, relativePath: "Late Night.m4a"),
            MobileTrack(title: "On Repeat", artist: "Golden Coast", album: "Echoes", duration: 247, relativePath: "On Repeat.m4a"),
        ]
        favorites = [tracks[0].id, tracks[3].id]
        playlists = [
            MobilePlaylist(name: "Liked Songs", trackIDs: [tracks[0].id, tracks[3].id], isSystem: true),
            MobilePlaylist(name: "Late Night", trackIDs: [tracks[1].id, tracks[2].id]),
        ]
        currentTrackID = tracks[0].id
        isPlaying = true
        position = 94
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

    func importFiles(_ urls: [URL]) async {
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let filename = uniqueFilename(source.lastPathComponent)
            let destination = musicDirectory.appendingPathComponent(filename)
            do {
                try fileManager.copyItem(at: source, to: destination)
                let audio = try AVAudioPlayer(contentsOf: destination)
                tracks.append(MobileTrack(
                    title: source.deletingPathExtension().lastPathComponent,
                    duration: audio.duration,
                    relativePath: filename
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
        if currentTrackID != track.id, let currentTrackID { history.append(currentTrackID) }
        do {
            let next = try AVAudioPlayer(contentsOf: fileURL(for: track))
            next.delegate = self
            next.enableRate = true
            next.volume = Float(volume)
            next.rate = playbackRate
            next.prepareToPlay()
            next.play()
            player = next
            currentTrackID = track.id
            UserDefaults.standard.set(track.id.uuidString, forKey: "Resonance.currentTrack")
            isPlaying = true
            position = 0
            startTimer()
            updateNowPlaying()
        } catch {
            isPlaying = false
        }
    }

    func togglePlay() {
        guard let player else {
            if let track = currentTrack ?? tracks.first { play(track) }
            return
        }
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying = player.isPlaying
        updateNowPlaying()
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = player.duration * min(max(fraction, 0), 1)
        position = player.currentTime
        updateNowPlaying()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        if shuffleEnabled, let next = tracks.filter({ $0.id != currentTrackID }).randomElement() {
            play(next)
            return
        }
        let index = tracks.firstIndex { $0.id == currentTrackID } ?? -1
        play(tracks[(index + 1) % tracks.count])
    }

    func previous() {
        if let previousID = history.popLast(), let track = tracks.first(where: { $0.id == previousID }) {
            play(track)
        } else if let player, player.currentTime > 3 {
            player.currentTime = 0
        }
    }

    func toggleFavorite(_ track: MobileTrack) {
        if favorites.contains(track.id) { favorites.remove(track.id) } else { favorites.insert(track.id) }
        normalizeSystemPlaylist()
        save()
    }

    func createPlaylist(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        playlists.append(MobilePlaylist(name: trimmed))
        save()
    }

    func add(_ track: MobileTrack, to playlist: MobilePlaylist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }), !playlists[index].isSystem else { return }
        if !playlists[index].trackIDs.contains(track.id) { playlists[index].trackIDs.append(track.id) }
        save()
    }

    func tracks(in playlist: MobilePlaylist) -> [MobileTrack] {
        playlist.trackIDs.compactMap { id in tracks.first { $0.id == id } }
    }

    func remove(_ track: MobileTrack) {
        if currentTrackID == track.id { player?.stop(); player = nil; isPlaying = false }
        try? fileManager.removeItem(at: fileURL(for: track))
        tracks.removeAll { $0.id == track.id }
        favorites.remove(track.id)
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == track.id } }
        currentTrackID = tracks.first?.id
        position = 0
        normalizeSystemPlaylist()
        save()
    }

    func refreshCatalog() async { await sync(songIDs: []) }
    func downloadSelected() async {
        guard !selectedRemoteSongIDs.isEmpty else { downloadDetail = "Select one or more songs first"; return }
        await sync(songIDs: selectedRemoteSongIDs)
    }
    func downloadAll() async { await sync(songIDs: nil) }

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
                let songs = songIDs.map { ids in catalog.songs.filter { ids.contains($0.id) } } ?? catalog.songs
                var completed = 0
                for song in songs {
                    downloadDetail = "Downloading \(completed + 1) of \(songs.count) • \(song.filename)"
                    if isSynced(song) { completed += 1; downloadProgress = Double(completed) / Double(max(songs.count, 1)); continue }
                    guard let remoteURL = URL(string: song.downloadURL, relativeTo: baseURL)?.absoluteURL else { continue }
                    var request = URLRequest(url: remoteURL)
                    request.setValue("Bearer \(serverToken)", forHTTPHeaderField: "Authorization")
                    let (data, downloadResponse) = try await URLSession.shared.data(for: request)
                    guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    let filename = uniqueFilename(song.filename)
                    let destination = musicDirectory.appendingPathComponent(filename)
                    try data.write(to: destination, options: .atomic)
                    let audio = try AVAudioPlayer(contentsOf: destination)
                    tracks.append(MobileTrack(
                        title: song.title,
                        artist: song.artist,
                        album: song.album,
                        duration: audio.duration,
                        relativePath: filename,
                        remoteID: song.id,
                        sourceServer: baseURL.absoluteString
                    ))
                    completed += 1
                    downloadProgress = Double(completed) / Double(max(songs.count, 1))
                }
                normalizeSystemPlaylist()
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
        let stored = MobileStoredLibrary(tracks: tracks, playlists: playlists, favorites: favorites, serverURL: serverURL)
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
        normalizeSystemPlaylist()
        let savedID = UserDefaults.standard.string(forKey: "Resonance.currentTrack").flatMap(UUID.init(uuidString:))
        currentTrackID = savedID.flatMap { wanted in tracks.first(where: { $0.id == wanted })?.id } ?? tracks.first?.id
        position = UserDefaults.standard.double(forKey: "Resonance.position")
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                UserDefaults.standard.set(self.position, forKey: "Resonance.position")
                self.isPlaying = player.isPlaying
                self.updateNowPlaying()
            }
        }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0,
        ]
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.repeatEnabled, let track = self.currentTrack { self.play(track) } else { self.next() }
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
