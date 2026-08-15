import CryptoKit
import Foundation
import Testing
@testable import Resonance

private final class SoundCloudMockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lock.lock()
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else { throw URLError(.unsupportedURL) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }
}

private final class SoundCloudOperationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
@Suite(.serialized)
struct SoundCloudImportTests {
    private let clientID = "abcdefghijklmnopqrstuvwxyz123456"

    @Test
    func validatesOnlyExactSecureSoundCloudHosts() throws {
        #expect(LocalImportURL.isSoundCloud("https://soundcloud.com/artist/song"))
        #expect(LocalImportURL.isSoundCloud("https://on.soundcloud.com/short-link"))
        #expect(!LocalImportURL.isSoundCloud("http://soundcloud.com/artist/song"))
        #expect(!LocalImportURL.isSoundCloud("https://soundcloud.example/artist/song"))
        #expect(!LocalImportURL.isSoundCloud("https://soundcloud.com.example/artist/song"))
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportURL.soundCloudSource("https://user:secret@soundcloud.com/artist/song")
        }
        #expect(LocalImportURL.soundCloudArtwork("https://i1.sndcdn.com/artworks-cover-large.jpg") != nil)
        #expect(LocalImportURL.soundCloudArtwork("https://sndcdn.example/artwork.jpg") == nil)
    }

    @Test
    func parsesPublicTrackHydrationAndDirectProgressiveAudio() throws {
        let track = soundCloudTrack(id: 101, title: "Direct Song", permalink: "https://soundcloud.com/artist/direct-song")
        let html = try hydrationHTML([
            ["hydratable": "apiClient", "data": ["id": clientID]],
            ["hydratable": "sound", "data": track],
        ])
        let hydration = try LocalImportSoundCloudParser.hydration(html)
        #expect(LocalImportSoundCloudParser.clientID(hydration) == clientID)
        let parsed = try #require(LocalImportSoundCloudParser.track(hydration["sound"]))
        #expect(parsed.metadata.provider == "soundcloud")
        #expect(parsed.metadata.trackID == "101")
        #expect(parsed.metadata.title == "Direct Song")
        #expect(parsed.metadata.artist == "Test Artist")
        #expect(parsed.metadata.durationSeconds == 123)
        #expect(parsed.directlyImportable)
        #expect(parsed.directCandidate?.sourceProvider == .soundcloud)
        var unavailable = track
        unavailable["track_authorization"] = nil
        #expect(LocalImportSoundCloudParser.track(unavailable)?.directlyImportable == false)
    }

    @Test
    func resolvesPlaylistStubsInOrderAndCountsUnavailableTracks() async throws {
        let session = mockSession()
        defer {
            SoundCloudMockURLProtocol.reset()
            session.invalidateAndCancel()
        }
        let fullTrack = soundCloudTrack(id: 101, title: "First", permalink: "https://soundcloud.com/artist/first")
        let hydratedTrack = soundCloudTrack(id: 202, title: "Second", permalink: "https://soundcloud.com/artist/second")
        let playlist: [String: Any] = [
            "kind": "playlist",
            "id": 77,
            "title": "Two Songs",
            "permalink_url": "https://soundcloud.com/artist/sets/two-songs",
            "track_count": 3,
            "artwork_url": "https://i1.sndcdn.com/artworks-playlist-large.jpg",
            "user": ["username": "Test Artist"],
            "tracks": [fullTrack, ["kind": "track", "id": 202]],
        ]
        let page = try hydrationData([
            ["hydratable": "apiClient", "data": ["id": clientID]],
            ["hydratable": "playlist", "data": playlist],
        ])
        let hydrated = try JSONSerialization.data(withJSONObject: [hydratedTrack])
        SoundCloudMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "soundcloud.com" {
                return Self.response(url: url, data: page, contentType: "text/html")
            }
            if url.host == "api-v2.soundcloud.com", url.path == "/tracks" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "ids" && $0.value == "202" }) == true)
                return Self.response(url: url, data: hydrated, contentType: "application/json")
            }
            throw URLError(.unsupportedURL)
        }

        let resolved = try await LocalImportSoundCloud.resolve(
            source: "https://soundcloud.com/artist/sets/two-songs",
            session: session
        )
        guard case .playlist(let result) = resolved else {
            Issue.record("Expected a SoundCloud playlist")
            return
        }
        #expect(result.tracks.map(\.metadata.trackID) == ["101", "202"])
        #expect(result.tracks.map(\.metadata.trackNumber) == [1, 2])
        #expect(result.unavailableCount == 1)
        #expect(result.tracks.map(\.directlyImportable) == [true, true])
    }

    @Test
    func resolvesAndDownloadsAnExactBoundedPublicAudioStream() async throws {
        let session = mockSession()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundCloudImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            SoundCloudMockURLProtocol.reset()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: temporary)
        }
        let audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00])
        let track = soundCloudTrack(id: 101, title: "Direct Song", permalink: "https://soundcloud.com/artist/direct-song")
        let page = try hydrationData([
            ["hydratable": "apiClient", "data": ["id": clientID]],
            ["hydratable": "sound", "data": track],
        ])
        let streamPayload = Data(#"{"url":"https://cf-media.sndcdn.com/direct-song.mp3"}"#.utf8)
        SoundCloudMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "soundcloud.com" {
                return Self.response(url: url, data: page, contentType: "text/html")
            }
            if url.host == "api-v2.soundcloud.com" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                #expect(query.contains { $0.name == "client_id" && $0.value == clientID })
                #expect(query.contains { $0.name == "track_authorization" && $0.value == "authorization-101" })
                return Self.response(url: url, data: streamPayload, contentType: "application/json")
            }
            if url.host == "cf-media.sndcdn.com" {
                if request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
                    return (
                        HTTPURLResponse(
                            url: url,
                            statusCode: 206,
                            httpVersion: nil,
                            headerFields: [
                                "Content-Type": "audio/mpeg",
                                "Content-Length": "1",
                                "Content-Range": "bytes 0-0/\(audio.count)",
                            ]
                        )!,
                        Data(audio.prefix(1))
                    )
                }
                let body = audio
                return Self.response(url: url, data: body, contentType: "audio/mpeg", contentLength: audio.count)
            }
            throw URLError(.unsupportedURL)
        }

        let stream = try await LocalImportSoundCloud.resolveAudio(
            source: "https://soundcloud.com/artist/direct-song",
            session: session
        )
        #expect(stream.contentLength == Int64(audio.count))
        let destination = temporary.appendingPathComponent("source.mp3")
        let hash = try await LocalImportSoundCloud.download(
            stream,
            to: destination,
            session: session
        ) { _ in }
        #expect(try Data(contentsOf: destination) == audio)
        #expect(hash == SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined())
    }

    @Test
    func savedDownloadUsesCatalogMetadataAndPreparedAudioExactlyOnce() async throws {
        let session = mockSession()
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundCloudPreparedDownloadTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            SoundCloudMockURLProtocol.reset()
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: temporary)
        }
        SoundCloudMockURLProtocol.handler = { _ in
            throw URLError(.cannotLoadFromNetwork)
        }

        let source = "https://soundcloud.com/artist/direct-song"
        let metadata = LocalImportSpotifyTrack(
            provider: "soundcloud",
            type: "track",
            trackID: "101",
            title: "Catalog title",
            artist: "Catalog artist",
            album: "Catalog album",
            trackNumber: nil,
            durationSeconds: 123,
            artworkURL: nil,
            embedURL: "",
            sourceURL: source
        )
        let preparedStream = LocalImportSoundCloudAudioStream(
            track: metadata,
            streamingURL: URL(string: "https://cf-media.sndcdn.com/direct-song.mp3")!,
            contentLength: 8
        )
        let metadataCalls = SoundCloudOperationCounter()
        let audioCalls = SoundCloudOperationCounter()
        let operations = LocalImportSoundCloudOperations(
            resolveSource: { _, _ in
                metadataCalls.increment()
                throw URLError(.unsupportedURL)
            },
            resolveAudio: { _, _ in
                audioCalls.increment()
                return preparedStream
            }
        )
        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: temporary.appendingPathComponent("library", isDirectory: true),
            temporaryRoot: temporary.appendingPathComponent("temporary", isDirectory: true),
            soundCloudOperations: operations
        )
        let context = "https://music.test#profile=listener"
        let resolution = try await service.resolveSavedDownload(
            source: source,
            metadata: metadata,
            mediaMode: .audio,
            preparationContext: context
        ) { _ in }

        #expect(resolution.track == metadata)
        #expect(resolution.candidates.first?.sourceProvider == .soundcloud)
        #expect(metadataCalls.value == 0)
        #expect(audioCalls.value == 1)

        let candidate = try #require(resolution.candidates.first)
        do {
            _ = try await service.importCandidate(
                candidate,
                metadata: LocalImportMetadata(
                    title: metadata.title,
                    artist: metadata.artist,
                    album: metadata.album,
                    artworkURL: nil,
                    sourceURL: source
                ),
                existingTracks: [],
                mediaMode: .audio,
                preparationContext: context
            ) { _ in }
            Issue.record("The intentionally unavailable mock stream should stop the import")
        } catch {
            // The transfer request is intentionally unavailable. Reaching it
            // proves import consumed the prepared stream without resolving it.
        }

        #expect(metadataCalls.value == 0)
        #expect(audioCalls.value == 1)
    }

    @Test
    func preparedAudioHandoffIsBoundedScopedSingleUseAndExpires() throws {
        let source = "https://soundcloud.com/artist/direct-song"
        let secondSource = "https://soundcloud.com/artist/second-song"
        let thirdSource = "https://soundcloud.com/artist/third-song"
        let metadata = LocalImportSpotifyTrack(
            provider: "soundcloud",
            type: "track",
            trackID: "101",
            title: "Prepared song",
            artist: "Prepared artist",
            album: nil,
            trackNumber: nil,
            durationSeconds: 123,
            artworkURL: nil,
            embedURL: "",
            sourceURL: source
        )
        let stream = LocalImportSoundCloudAudioStream(
            track: metadata,
            streamingURL: URL(string: "https://cf-media.sndcdn.com/direct-song.mp3")!,
            contentLength: 8
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let context = "https://music.test#profile=listener"
        var cache = LocalImportPreparedSoundCloudStreamCache(maximumCount: 2, lifetime: 5)
        #expect(throws: LocalImportError.self) {
            try cache.store(
                stream,
                source: source,
                mediaMode: .audio,
                preparationContext: "https://music.test#profile=listener\nAuthorization: Bearer secret",
                now: now
            )
        }
        #expect(throws: LocalImportError.self) {
            try cache.store(
                stream,
                source: source,
                mediaMode: .audio,
                preparationContext: "https://music.test#profile=listener&token=secret",
                now: now
            )
        }
        try cache.store(stream, source: source, mediaMode: .audio, preparationContext: context, now: now)

        #expect(cache.take(
            source: source,
            mediaMode: .audio,
            preparationContext: "https://music.test#profile=someone-else",
            now: now
        ) == nil)
        #expect(cache.take(
            source: secondSource,
            mediaMode: .audio,
            preparationContext: context,
            now: now
        ) == nil)
        #expect(cache.take(
            source: source,
            mediaMode: .video,
            preparationContext: context,
            now: now
        ) == nil)
        #expect(cache.take(
            source: source,
            mediaMode: .audio,
            preparationContext: context,
            now: now
        ) == stream)
        #expect(cache.take(
            source: source,
            mediaMode: .audio,
            preparationContext: context,
            now: now
        ) == nil)

        try cache.store(stream, source: source, mediaMode: .audio, preparationContext: context, now: now)
        #expect(cache.take(
            source: source,
            mediaMode: .audio,
            preparationContext: context,
            now: now.addingTimeInterval(5)
        ) == nil)

        try cache.store(stream, source: source, mediaMode: .audio, preparationContext: context, now: now)
        try cache.store(stream, source: secondSource, mediaMode: .audio, preparationContext: context, now: now)
        try cache.store(stream, source: thirdSource, mediaMode: .audio, preparationContext: context, now: now)
        #expect(cache.cachedCount(now: now) == 2)
    }

    private func soundCloudTrack(id: Int, title: String, permalink: String) -> [String: Any] {
        [
            "kind": "track",
            "id": id,
            "title": title,
            "permalink_url": permalink,
            "duration": 123_400,
            "full_duration": 123_400,
            "streamable": true,
            "policy": "ALLOW",
            "track_authorization": "authorization-\(id)",
            "artwork_url": "https://i1.sndcdn.com/artworks-\(id)-large.jpg",
            "user": ["username": "Test Artist"],
            "publisher_metadata": ["artist": "Test Artist", "album_title": "Test Album"],
            "media": [
                "transcodings": [[
                    "url": "https://api-v2.soundcloud.com/media/sound/\(id)/progressive",
                    "snipped": false,
                    "format": ["protocol": "progressive", "mime_type": "audio/mpeg"],
                ]],
            ],
        ]
    }

    private func hydrationHTML(_ values: [[String: Any]]) throws -> String {
        String(decoding: try hydrationData(values), as: UTF8.self)
    }

    private func hydrationData(_ values: [[String: Any]]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: values)
        return Data("<script>window.__sc_hydration = \(String(decoding: data, as: UTF8.self));</script>".utf8)
    }

    private func mockSession() -> URLSession {
        SoundCloudMockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SoundCloudMockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(
        url: URL,
        data: Data,
        contentType: String,
        contentLength: Int? = nil
    ) -> (HTTPURLResponse, Data) {
        let headers = [
            "Content-Type": contentType,
            "Content-Length": String(contentLength ?? data.count),
        ]
        return (
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!,
            data
        )
    }
}
