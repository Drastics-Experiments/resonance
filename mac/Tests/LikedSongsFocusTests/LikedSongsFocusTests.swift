import Foundation
import Testing
@testable import LikedSongsFocus

private final class MockMusicURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class MockUpdateURLProtocol: URLProtocol {
    static var responseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
struct LikedSongsFocusTests {
    private let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    private let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private let hero = URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff")

    private func defaults() throws -> (UserDefaults, String) {
        let suiteName = "LikedSongsFocusTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test
    func updateVersionsCompareNumericallyAndPreferStableReleases() {
        #expect(MacUpdateVersion.compare("1.9.0", "1.10.0") == .orderedAscending)
        #expect(MacUpdateVersion.compare("v2.0.0", "2.0") == .orderedSame)
        #expect(MacUpdateVersion.compare("2.0.0-beta.2", "2.0.0") == .orderedAscending)
        #expect(MacUpdateVersion.compare("2.0.1", "2.0.0") == .orderedDescending)
    }

    @Test
    func updateManifestRequiresGitHubHTTPSAndAFullChecksum() throws {
        let good = MacUpdateManifest(
            version: "1.2.0",
            build: "12",
            url: try #require(URL(string: "https://github.com/Drastics-Experiments/resonance/releases/download/v1.2.0/Resonance-macOS.zip")),
            sha256: String(repeating: "a", count: 64)
        )
        #expect(throws: Never.self) { try UpdateManager.validate(good) }

        let untrusted = MacUpdateManifest(
            version: "1.2.0",
            build: "12",
            url: try #require(URL(string: "https://example.com/Resonance-macOS.zip")),
            sha256: String(repeating: "a", count: 64)
        )
        #expect(throws: (any Error).self) { try UpdateManager.validate(untrusted) }
    }

    @Test
    func updateChecksumUsesSHA256() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("resonance".utf8).write(to: url)
        #expect(try UpdateManager.sha256(of: url) == "2972f9afb85ba78fdc5aa4970eef30ddecc4ed690bdef28dcfdb494543b6f401")
    }

    @Test
    func updateCheckReadsTheGitHubManifestAndFindsANewerVersion() async throws {
        let manifestURL = try #require(URL(string: "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json"))
        let archiveURL = try #require(URL(string: "https://github.com/Drastics-Experiments/resonance/releases/download/v99.0.0/Resonance-macOS.zip"))
        MockUpdateURLProtocol.responseData = try JSONEncoder().encode(MacUpdateManifest(
            version: "99.0.0",
            build: "99",
            url: archiveURL,
            sha256: String(repeating: "b", count: 64)
        ))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let manager = UpdateManager(manifestURL: manifestURL, session: session)
        await manager.checkForUpdates()
        #expect(manager.availableVersion == "99.0.0")
        #expect(manager.status == "Version 99.0.0 available")
        #expect(manager.errorMessage == nil)
    }

    @Test
    func timeFormattingHandlesBoundaries() {
        #expect(Track.timeText(-1) == "0:00")
        #expect(Track.timeText(.nan) == "0:00")
        #expect(Track.timeText(59.99) == "0:59")
        #expect(Track.timeText(60) == "1:00")
        #expect(Track.timeText(222) == "3:42")
    }

    @Test
    func newLibraryStartsEmptyAndReadyForRealFiles() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)

        #expect(model.tracks.isEmpty)
        #expect(model.playlists.count == 1)
        #expect(model.playlists[0].isSystem)
        #expect(model.playlists[0].name == "Liked Songs")
        #expect(model.currentTrack == nil)
        #expect(!model.isPlaying)

        model.selectSection(.playlists)
        #expect(model.selectedPlaylistID == nil)
        model.setPlaybackRate(1.5)
        #expect(model.playbackRate == 1.5)
    }

    @Test
    func importsActualAudioMetadataAndPersistsLibraryState() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FileManager.default.fileExists(atPath: glass.path))
        #expect(FileManager.default.fileExists(atPath: ping.path))

        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, glass])
        #expect(model.tracks.count == 2)
        #expect(model.tracks.allSatisfy { $0.duration > 0 && $0.fileURL != nil })
        #expect(model.playlists[0].trackIDs.isEmpty)

        let first = model.tracks[0]
        model.toggleFavorite(first)
        #expect(model.playlists[0].trackIDs == [first.id])
        let playlist = try #require(model.createPlaylist(named: "Favorites for Work"))
        model.addTrack(first, to: playlist)

        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(reloaded.tracks.map(\.id) == model.tracks.map(\.id))
        #expect(reloaded.favorites.contains(first.id))
        #expect(reloaded.customPlaylists.first?.name == "Favorites for Work")
        #expect(reloaded.customPlaylists.first?.trackIDs == [first.id])
    }

    @Test
    func actualAudioCanPlayPauseAndSeek() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [hero])
        let track = try #require(model.tracks.first)

        model.selectAndPlay(track)
        #expect(model.isPlaying)
        model.seek(to: 0.5)
        #expect(abs(model.position - track.duration * 0.5) < 0.02)
        model.togglePlay()
        #expect(!model.isPlaying)
        model.togglePlay()
        #expect(model.isPlaying)
        model.togglePlay()
    }

    @Test
    func playlistPlaybackStaysInsideSelectedPlaylist() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])

        let playlist = try #require(model.createPlaylist(named: "Two Songs"))
        model.addTrack(model.tracks[1], to: playlist)
        model.addTrack(model.tracks[2], to: playlist)
        model.selectPlaylist(model.playlists.first { $0.id == playlist.id }!)

        model.toggleCollectionPlayback()
        #expect(model.currentTrackID == model.tracks[1].id)
        model.next()
        #expect(model.currentTrackID == model.tracks[2].id)
        model.next()
        #expect(model.currentTrackID == model.tracks[1].id)
        model.togglePlay()
    }

    @Test
    func shuffleConsumesQueueAndHistoryReflectsPlayback() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])
        let original = model.currentTrackID

        model.toggleShuffle()
        let initialQueue = model.queueTracks.map(\.id)
        #expect(initialQueue.count == 2)
        model.next()
        #expect(model.currentTrackID == initialQueue[0])
        #expect(model.queueTracks.map(\.id) == Array(initialQueue.dropFirst()))

        model.queueTab = .history
        #expect(model.queueTracks.first?.id == original)
        model.togglePlay()
    }

    @Test
    func searchFiltersAndPlaylistRemovalWorkOnRealFiles() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping])

        model.searchText = "glass"
        #expect(model.displayedTracks.count == 1)
        #expect(model.displayedTracks[0].fileURL == glass)
        model.searchText = ""
        model.filter = .video
        #expect(model.displayedTracks.isEmpty)
        model.filter = .audio
        #expect(model.displayedTracks.count == 2)

        let playlist = try #require(model.createPlaylist(named: "Temporary"))
        let track = model.tracks[0]
        model.addTrack(track, to: playlist)
        model.selectPlaylist(model.playlists.first { $0.id == playlist.id }!)
        model.removeTrackFromSelectedPlaylist(track)
        #expect(model.selectedPlaylist?.trackIDs.isEmpty == true)
        #expect(model.tracks.contains(track))

        model.removeTrackFromLibrary(track)
        #expect(model.tracks.count == 1)
        #expect(FileManager.default.fileExists(atPath: glass.path))
    }

    @Test
    func folderImportFindsSupportedAudioFiles() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: glass, to: folder.appendingPathComponent("Glass.aiff"))
        try FileManager.default.copyItem(at: ping, to: folder.appendingPathComponent("Ping.aiff"))
        try Data("not music".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [folder])
        #expect(model.tracks.count == 2)
    }

    @Test
    func authenticatedServerCatalogDownloadsIntoTheLibrary() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let audioData = try Data(contentsOf: glass)
        let identifier = "0123456789abcdef01234567"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        MockMusicURLProtocol.handler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer client-token-123" else {
                throw URLError(.userAuthenticationRequired)
            }
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                let payload: [String: Any] = [
                    "count": 1,
                    "songs": [[
                        "id": identifier,
                        "filename": "Glass.aiff",
                        "title": "Glass",
                        "artist": "System Sounds",
                        "album": "Shared Library",
                        "size": audioData.count,
                        "modified_at": "2026-07-11T00:00:00+00:00",
                        "content_type": "audio/aiff",
                        "download_url": "/api/v1/songs/\(identifier)/file",
                        "stream_url": "/api/v1/songs/\(identifier)/stream",
                    ]],
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            if url.path == "/api/v1/songs/\(identifier)/file" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/aiff"])!, audioData)
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "http://music.test:8765"
        model.serverToken = "client-token-123"
        await model.syncServerLibrary()

        #expect(model.remoteSongs.count == 1)
        #expect(model.tracks.count == 1)
        #expect(model.tracks[0].remoteID == identifier)
        #expect(model.tracks[0].sourceServer == "http://music.test:8765")
        #expect(model.tracks[0].fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(model.serverMessage == "Synced 1 song")
    }
}
