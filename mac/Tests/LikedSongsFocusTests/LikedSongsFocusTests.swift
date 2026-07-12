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

private func requestBodyData(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

@MainActor
@Suite(.serialized)
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
    func timeFormattingHandlesBoundaries() {
        #expect(Track.timeText(-1) == "0:00")
        #expect(Track.timeText(.nan) == "0:00")
        #expect(Track.timeText(59.99) == "0:59")
        #expect(Track.timeText(60) == "1:00")
        #expect(Track.timeText(222) == "3:42")
    }

    @Test
    func playlistPayloadUsesServerCompatibleLowercaseUUIDs() throws {
        let id = try #require(UUID(uuidString: "12345678-1234-ABCD-9876-ABCDEF123456"))
        let payload = RemotePlaylist(id: id, name: "Case Test", songIDs: [])
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(json.contains("12345678-1234-abcd-9876-abcdef123456"))
        #expect(!json.contains("ABCD"))
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

    @Test
    func playlistSyncBootstrapsLocalStateAndPreservesSongOrder() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        let firstRemoteID = "0123456789abcdef01234567"
        let secondRemoteID = "89abcdef0123456701234567"
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        let first = Track(title: "First", artist: "Artist", album: "Album", duration: 1, artwork: .electric, fileURL: glass, remoteID: firstRemoteID)
        let second = Track(title: "Second", artist: "Artist", album: "Album", duration: 1, artwork: .golden, fileURL: ping, remoteID: secondRemoteID)
        model.tracks = [first, second]
        let playlist = try #require(model.createPlaylist(named: "Synced Order"))
        model.addTrack(second, to: playlist)
        model.addTrack(first, to: model.playlists.first { $0.id == playlist.id }!)

        var uploadedDocument: RemotePlaylistsDocument?
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer playlist-token" else {
                throw URLError(.userAuthenticationRequired)
            }
            if request.httpMethod == "GET", url.path == "/api/v1/playlists" {
                let document = RemotePlaylistsDocument(revision: 0, playlists: [])
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            if request.httpMethod == "PUT", url.path == "/api/v1/playlists" {
                let body = try requestBodyData(request)
                var document = try JSONDecoder().decode(RemotePlaylistsDocument.self, from: body)
                uploadedDocument = document
                document.revision = 1
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        await model.syncPlaylistsNow()

        #expect(uploadedDocument?.revision == 0)
        #expect(uploadedDocument?.playlists.first?.name == "Synced Order")
        #expect(uploadedDocument?.playlists.first?.songIDs == [secondRemoteID, firstRemoteID])
        #expect(model.playlistSyncStatus == "Synced 1 playlist")
    }

    @Test
    func playlistSyncRetriesARevisionConflictAndAppliesRemoteMembership() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        let remoteID = "fedcba9876543210fedcba98"
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        let track = Track(title: "Remote", artist: "Artist", album: "Album", duration: 1, artwork: .electric, fileURL: glass, remoteID: remoteID)
        model.tracks = [track]
        let playlist = try #require(model.createPlaylist(named: "Conflict Safe"))
        model.addTrack(track, to: playlist)

        var putCount = 0
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let document = RemotePlaylistsDocument(revision: 4, playlists: [])
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            if request.httpMethod == "PUT" {
                putCount += 1
                let body = try requestBodyData(request)
                var document = try JSONDecoder().decode(RemotePlaylistsDocument.self, from: body)
                if putCount == 1 {
                    let conflict = RemotePlaylistsDocument(revision: 5, playlists: [])
                    return (HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(conflict))
                }
                #expect(document.revision == 5)
                document.revision = 6
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        await model.syncPlaylistsNow()

        #expect(putCount == 2)
        #expect(model.customPlaylists.first?.trackIDs == [track.id])
        #expect(model.customPlaylists.first?.remoteSongIDs == [remoteID])
        #expect(model.playlistSyncStatus == "Synced 1 playlist")
    }
}
