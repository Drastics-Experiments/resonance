import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import LikedSongsFocus

private final class LocalImportMockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestedHosts: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lock.lock()
            Self.requestedHosts.append(request.url?.host ?? "")
            let handler = Self.handler
            Self.lock.unlock()
            let resolvedHandler = try #require(handler)
            let response = try resolvedHandler(request)
            client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        handler = nil
        requestedHosts = []
        lock.unlock()
    }

    static func hosts() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedHosts
    }
}

@MainActor
@Suite(.serialized)
struct LocalImportTests {
    private let spotifyID = "4PTG3Z6ehGkBFwjybzWkR8"
    private let videoID = "jNQXAC9IVRw"
    private let m4a = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")

    @Test
    func validatesExactSpotifyTracksAndIndividualHTTPSYouTubeURLs() throws {
        #expect(LocalImportURL.isSpotify("https://open.spotify.com/track/\(spotifyID)"))
        #expect(!LocalImportURL.isSpotify("https://open.spotify.example/track/\(spotifyID)"))
        #expect(try LocalImportURL.spotifyTrack("https://open.spotify.com/intl-en/track/\(spotifyID)?si=test")?.trackID == spotifyID)
        #expect(try LocalImportURL.youtubeVideoID("https://www.youtube.com/watch?v=\(videoID)") == videoID)
        #expect(try LocalImportURL.youtubeVideoID("https://youtu.be/\(videoID)?t=3") == videoID)
        #expect(try LocalImportURL.youtubeVideoID("https://music.youtube.com/watch?v=\(videoID)") == videoID)
        #expect(try LocalImportURL.youtubeVideoID("https://www.youtube.com/shorts/\(videoID)") == videoID)
        #expect(try LocalImportURL.youtubeVideoID("http://www.youtube.com/watch?v=\(videoID)") == nil)
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportURL.youtubeVideoID("https://www.youtube.com/watch?v=\(videoID)&list=PLexample")
        }
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportURL.youtubeVideoID("https://user:secret@youtube.com/watch?v=\(videoID)")
        }
    }

    @Test
    func preservesSpotifyEmbedNormalizationAndRejectsMismatchedTracks() throws {
        let oEmbed: [String: Any] = [
            "provider_name": "Spotify",
            "type": "rich",
            "title": "Never Gonna Give You Up",
            "thumbnail_url": "https://image-cdn-ak.spotifycdn.com/image/cover",
            "html": "<iframe src=\"https://open.spotify.com/embed/track/\(spotifyID)?utm_source=oembed\"></iframe>",
        ]
        let parsedOEmbed = try LocalImportParser.spotifyOEmbed(
            JSONSerialization.data(withJSONObject: oEmbed),
            expectedTrackID: spotifyID
        )
        #expect(parsedOEmbed.title == "Never Gonna Give You Up")
        #expect(parsedOEmbed.embedURL == "https://open.spotify.com/embed/track/\(spotifyID)")

        let entity: [String: Any] = [
            "type": "track",
            "id": spotifyID,
            "title": "Never Gonna Give You Up",
            "artists": [["name": "Rick Astley"]],
            "duration": 213_573,
            "visualIdentity": ["image": [["url": "https://image-cdn-fa.spotifycdn.com/image/cover", "maxWidth": 640]]],
        ]
        let root: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
        let parsed = try LocalImportParser.spotifyEmbed(html, expectedTrackID: spotifyID)
        #expect(parsed.title == "Never Gonna Give You Up")
        #expect(parsed.artist == "Rick Astley")
        #expect(parsed.durationSeconds == 214)

        #expect(throws: LocalImportError.self) {
            _ = try LocalImportParser.spotifyEmbed(html, expectedTrackID: "11dFghVXANMlKmJXsNCbNl")
        }
    }

    @Test
    func parsesBothSearchProvidersAndPreservesScoringGates() throws {
        let musicRenderer: [String: Any] = [
            "playlistItemData": ["videoId": videoID],
            "flexColumns": [
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Never Gonna Give You Up"]]]]],
                ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                    ["text": "Rick Astley", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCexample"]]],
                    ["text": " • "],
                    ["text": "Whenever You Need Somebody", "navigationEndpoint": ["browseEndpoint": ["browseId": "MPREexample"]]],
                    ["text": " • "],
                    ["text": "3:34"],
                ]]]],
            ],
            "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"]]]]],
        ]
        let musicRoot: [String: Any] = ["contents": ["musicResponsiveListItemRenderer": musicRenderer]]
        let musicJSON = String(data: try JSONSerialization.data(withJSONObject: musicRoot), encoding: .utf8)!
        let musicHTML = "<script>var ytInitialData = \(musicJSON);</script>"
        let music = try #require(LocalImportParser.youtubeMusicSearch(musicHTML).first)
        #expect(music.album == "Whenever You Need Somebody")
        #expect(music.durationSeconds == 214)

        let webRenderer: [String: Any] = [
            "videoId": videoID,
            "title": ["runs": [["text": "Rick Astley - Never Gonna Give You Up"]]],
            "ownerText": ["runs": [["text": "Rick Astley"]]],
            "lengthText": ["simpleText": "3:33"],
        ]
        let webRoot: [String: Any] = ["contents": ["videoRenderer": webRenderer]]
        let webJSON = String(data: try JSONSerialization.data(withJSONObject: webRoot), encoding: .utf8)!
        let web = try #require(LocalImportParser.youtubeWebSearch("<script>ytInitialData = \(webJSON);</script>").first)
        #expect(web.durationSeconds == 213)

        let track = spotifyTrack()
        let exact = try #require(LocalImportMatcher.score(track: track, candidate: LocalImportSearchCandidate(
            videoID: videoID,
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            album: "Whenever You Need Somebody",
            durationSeconds: 214,
            thumbnailURL: nil,
            sourceProvider: .youtubeMusic,
            officialArtist: true
        )))
        #expect(exact.confidence == "high")
        #expect(exact.match.durationDeltaSeconds == 0)
        #expect(LocalImportMatcher.score(track: track, candidate: LocalImportSearchCandidate(
            videoID: videoID,
            title: "Never Gonna Give You Up (Karaoke Cover)",
            artist: "A Tribute Band",
            album: nil,
            durationSeconds: 255,
            thumbnailURL: nil,
            sourceProvider: .youtube,
            officialArtist: false
        )) == nil)
        #expect(LocalImportMatcher.normalize("Never Gonna Give You Up (Official Audio)") == "never gonna give you up")
    }

    @Test
    func verifiesExactContentRanges() throws {
        #expect(try LocalImportRangeVerifier.expectedLength("bytes 0-4/5", start: 0, end: 4, total: 5) == 5)
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportRangeVerifier.expectedLength("bytes 1-4/5", start: 0, end: 4, total: 5)
        }
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportRangeVerifier.expectedLength("bytes 0-3/5", start: 0, end: 4, total: 5)
        }
    }

    @Test
    func extractsAnonymousYouTubeVisitorData() {
        let html = "<script>ytcfg.set({\"VISITOR_DATA\":\"visitor_123\"});</script>"
        #expect(LocalDeviceImportService.youtubeVisitorData(html) == "visitor_123")
    }

    @Test
    func resolvesDownloadsRemuxesAndSavesLocallyWithoutAResonanceAPIRequest() async throws {
        #expect(FileManager.default.fileExists(atPath: m4a.path))
        let fixture = try Data(contentsOf: m4a)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImportTests-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let abandoned = temporary.appendingPathComponent("resonance-import-abandoned", isDirectory: true)
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: abandoned.appendingPathComponent("source.m4a"))
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        let videoID = self.videoID
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/watch" || url.path.hasPrefix("/embed/") {
                let data = Data("<script>ytcfg.set({\"VISITOR_DATA\":\"visitor_123\"});</script>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.path == "/youtubei/v1/player" {
                let player: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": [
                        "videoId": videoID,
                        "title": "Local Test Audio",
                        "author": "Resonance",
                        "lengthSeconds": "4",
                    ],
                    "streamingData": ["adaptiveFormats": [[
                        "itag": 140,
                        "url": "https://rr1.example.googlevideo.com/videoplayback",
                        "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                        "bitrate": 129_000,
                        "contentLength": String(fixture.count),
                        "audioTrack": ["displayName": "English original", "audioIsDefault": true],
                    ]]],
                ]
                let data = try JSONSerialization.data(withJSONObject: player)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "i.ytimg.com" {
                return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!, Data("unavailable".utf8))
            }
            if url.host?.hasSuffix("googlevideo.com") == true {
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(fixture.count - 1)")
                return (HTTPURLResponse(
                    url: url,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Range": "bytes 0-\(fixture.count - 1)/\(fixture.count)",
                        "Content-Length": String(fixture.count),
                    ]
                )!, fixture)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        var stages: [LocalImportStage] = []
        let resolution = try await service.resolve(source: "https://youtu.be/\(videoID)") { progress in
            stages.append(progress.stage)
        }
        let candidate = try #require(resolution.candidates.first)
        let outcome = try await service.importCandidate(
            candidate,
            metadata: LocalImportMetadata(
                title: "Local Test Audio",
                artist: "Resonance",
                album: "Device Library",
                artworkURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                sourceURL: "https://youtu.be/\(videoID)"
            ),
            existingTracks: []
        ) { progress in
            stages.append(progress.stage)
        }
        guard case .created(let imported) = outcome else {
            Issue.record("Expected a newly created local import")
            return
        }
        #expect(FileManager.default.fileExists(atPath: imported.fileURL.path))
        let player = try AVAudioPlayer(contentsOf: imported.fileURL)
        #expect(player.duration > 0)
        #expect(imported.metadata.title == "Local Test Audio")
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(stages.contains(.downloading))
        #expect(stages.contains(.processing))
        #expect(stages.contains(.savingLocal))

        let hosts = LocalImportMockURLProtocol.hosts()
        #expect(!hosts.contains("music.test"))
        #expect(hosts.allSatisfy { $0.contains("youtube") || $0.hasSuffix("googlevideo.com") || $0.hasSuffix("ytimg.com") })

        let duplicateTrack = Track(
            title: "Existing Local Test Audio",
            artist: "Resonance",
            album: "Device Library",
            duration: imported.duration,
            artwork: .midnight,
            fileURL: imported.fileURL,
            sourceSHA256: imported.sourceSHA256,
            contentSHA256: imported.contentSHA256
        )
        let duplicate = try await service.importCandidate(
            candidate,
            metadata: imported.metadata,
            existingTracks: [duplicateTrack]
        ) { _ in }
        guard case .duplicate(let duplicateID) = duplicate else {
            Issue.record("Expected SHA-256 duplicate detection")
            return
        }
        #expect(duplicateID == duplicateTrack.id)
        let localFiles = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(localFiles.count == 1)
    }

    @Test
    func nativeMetadataRemuxProducesPlayableTaggedM4A() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalMediaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("input.m4a")
        let output = root.appendingPathComponent("output.m4a")
        try FileManager.default.copyItem(at: m4a, to: input)
        try await LocalImportMediaProcessor.remuxM4A(
            input: input,
            output: output,
            metadata: .init(title: "Tagged Title", artist: "Tagged Artist", album: "Tagged Album", artworkURL: nil, sourceURL: "https://example.invalid"),
            artwork: nil
        )
        let player = try AVAudioPlayer(contentsOf: output)
        #expect(player.duration > 0)
        let asset = AVURLAsset(url: output)
        let metadata = try await asset.load(.commonMetadata)
        var values: [String: String] = [:]
        for item in metadata {
            if let key = item.commonKey?.rawValue, let value = try? await item.load(.stringValue) { values[key] = value }
        }
        #expect(values[AVMetadataKey.commonKeyTitle.rawValue] == "Tagged Title")
        #expect(values[AVMetadataKey.commonKeyArtist.rawValue] == "Tagged Artist")
        #expect(values[AVMetadataKey.commonKeyAlbumName.rawValue] == "Tagged Album")
    }

    @Test
    func localImportRemainsVisibleAndUnownedAcrossProfileChanges() throws {
        let suiteName = "LocalImportProfiles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let imported = LocalImportedAudio(
            fileURL: m4a,
            metadata: .init(title: "Local", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/\(videoID)"),
            duration: 4,
            artworkData: nil,
            sourceSHA256: "source-hash",
            contentSHA256: "content-hash"
        )
        let track = model.insertLocalImportedAudio(imported)
        #expect(track.remoteID == nil)
        #expect(track.syncProfileID == nil)
        model.selectSyncProfile("another-profile")
        #expect(model.visibleTracks.contains(where: { $0.id == track.id }))

        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(reloaded.visibleTracks.contains(where: { $0.id == track.id }))
        #expect(reloaded.tracks.first(where: { $0.id == track.id })?.syncProfileID == nil)
    }

    @Test
    func cancelledImportStopsBeforeProviderOrFilesystemWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImportCancellation-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { _ in
            Issue.record("A cancelled import must not make a provider request")
            throw URLError(.cancelled)
        }
        let service = LocalDeviceImportService(sessions: .testing(session), localRoot: library, temporaryRoot: temporary)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.resolve(source: "https://youtu.be/\(videoID)") { _ in }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        #expect(LocalImportMockURLProtocol.hosts().isEmpty)
        #expect((try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)).isEmpty)
    }

    @Test
    func optionalUploadUsesActiveProfileAndFailureKeepsLocalSong() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImportUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let localFile = root.appendingPathComponent("Local Upload.m4a")
        try FileManager.default.copyItem(at: m4a, to: localFile)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
            if request.httpMethod == "PUT", url.path == "/api/v1/admin/songs" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                #expect(query?.first(where: { $0.name == "filename" })?.value == "Local Upload.m4a")
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!, Data())
            }
            if request.httpMethod == "GET", url.path == "/api/v1/songs" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
                let data = Data(#"{"songs":[],"count":0}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            throw URLError(.unsupportedURL)
        }

        let suiteName = "LocalImportUpload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            serverCacheRoot: root,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"
        model.selectSyncProfile("profile-b")
        let track = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: localFile,
            metadata: .init(title: "Local Upload", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/\(videoID)"),
            duration: 4,
            artworkData: nil,
            sourceSHA256: "upload-source-hash",
            contentSHA256: "upload-content-hash"
        ))

        try await model.uploadLocalImportToActiveProfile(track)
        #expect(model.tracks.first(where: { $0.id == track.id })?.remoteID == nil)
        #expect(model.tracks.first(where: { $0.id == track.id })?.syncProfileID == nil)

        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
            return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        var uploadFailed = false
        do {
            try await model.uploadLocalImportToActiveProfile(track)
        } catch {
            uploadFailed = true
        }
        #expect(uploadFailed)
        #expect(FileManager.default.fileExists(atPath: localFile.path))
        #expect(model.visibleTracks.contains(where: { $0.id == track.id }))
        #expect(model.tracks.first(where: { $0.id == track.id })?.syncProfileID == nil)
    }

    private func spotifyTrack() -> LocalImportSpotifyTrack {
        LocalImportSpotifyTrack(
            provider: "spotify",
            type: "track",
            trackID: spotifyID,
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            album: "Whenever You Need Somebody",
            trackNumber: 1,
            durationSeconds: 214,
            artworkURL: nil,
            embedURL: "https://open.spotify.com/embed/track/\(spotifyID)",
            sourceURL: "https://open.spotify.com/track/\(spotifyID)"
        )
    }
}
