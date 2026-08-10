import Foundation
import Testing
@testable import Resonance

private final class LocalImportSearchMockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            Self.lock.lock()
            if let url = request.url { Self.requests.append(url) }
            let handler = Self.handler
            Self.lock.unlock()
            guard let handler else { throw URLError(.badServerResponse) }
            let resolved = try handler(request)
            client?.urlProtocol(self, didReceive: resolved.0, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: resolved.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    static func requestedPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(requests.compactMap { url in
            guard let host = url.host else { return nil }
            return host + url.path
        })
    }
}

@Suite(.serialized)
struct LocalImportSearchTests {
    private let spotifyID = "4PTG3Z6ehGkBFwjybzWkR8"
    private let youtubeID = "jNQXAC9IVRw"

    @Test
    func distinguishesSearchTextFromLinks() {
        #expect(!LocalImportInput.looksLikeLink("Test Song Test Artist"))
        #expect(LocalImportInput.looksLikeLink("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"))
        #expect(LocalImportInput.looksLikeLink("www.youtube.com/watch?v=jNQXAC9IVRw"))
        #expect(LocalImportInput.looksLikeLink("example.com/song"))
    }

    @Test
    func parsesPublicSpotifySearchMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "data": [
                "tracks": [[
                    "id": spotifyID,
                    "title": "Test Song",
                    "artist": "Test Artist",
                    "album": "Test Album",
                    "duration": 214,
                    "artworkURL": "https://i.scdn.co/image/cover",
                ]],
            ],
        ])
        let track = try #require(LocalImportSearchParser.spotifyTracks(data).first)
        #expect(track.sourceURL == "https://open.spotify.com/track/\(spotifyID)")
        #expect(track.durationSeconds == 214)
    }

    @Test
    func queriesEveryProviderAndReturnsPreviewableGroups() async throws {
        LocalImportSearchMockURLProtocol.reset()
        defer { LocalImportSearchMockURLProtocol.reset() }
        let spotifyID = spotifyID
        let youtubeID = youtubeID
        LocalImportSearchMockURLProtocol.handler = { request in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": url.path.contains("search") ? "application/json" : "text/html"]
                  ) else { throw URLError(.badServerResponse) }
            switch (url.host, url.path) {
            case ("debridvault.elfhosted.com", "/api/search"):
                let data = try JSONSerialization.data(withJSONObject: [
                    "success": true,
                    "data": ["tracks": [[
                        "id": spotifyID,
                        "title": "Test Song",
                        "artist": "Test Artist",
                        "album": "Test Album",
                        "duration": 214,
                        "artworkURL": "https://i.scdn.co/image/cover",
                    ]]],
                ])
                return (response, data)
            case ("soundcloud.com", "/search/sounds"):
                let hydration = try JSONSerialization.data(withJSONObject: [[
                    "hydratable": "apiClient",
                    "data": ["id": "TwElDfIgW9RpAzLMUSy9g1VvI2Kao7my"],
                ]])
                let json = try #require(String(data: hydration, encoding: .utf8))
                return (response, Data("<script>window.__sc_hydration = \(json);</script>".utf8))
            case ("api-v2.soundcloud.com", "/search/tracks"):
                let data = try JSONSerialization.data(withJSONObject: ["collection": [[
                    "kind": "track",
                    "id": 123,
                    "title": "Test Song",
                    "permalink_url": "https://soundcloud.com/test-artist/test-song",
                    "duration": 214_000,
                    "streamable": true,
                    "policy": "ALLOW",
                    "track_authorization": "authorization",
                    "user": [
                        "username": "Test Artist",
                        "avatar_url": "https://i1.sndcdn.com/avatars-test-large.jpg",
                    ],
                    "publisher_metadata": [
                        "artist": "Test Artist",
                        "album_title": "Test Album",
                    ],
                    "media": ["transcodings": [[
                        "url": "https://api-v2.soundcloud.com/media/test/stream/progressive",
                        "snipped": false,
                        "format": ["protocol": "progressive", "mime_type": "audio/mpeg"],
                    ]]],
                ]]])
                return (response, data)
            case ("music.youtube.com", "/search"):
                return (response, Data(try youtubeSearchHTML(videoID: youtubeID).utf8))
            case ("www.youtube.com", "/results"):
                return (response, Data("<html></html>".utf8))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportSearchMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let result = try await LocalImportSearchEngine(sessions: .testing(session)).search("Test Song Test Artist")

        #expect(result.results(for: .spotify).count == 1)
        #expect(result.results(for: .soundcloud).count == 1)
        #expect(result.results(for: .youtube).count == 1)
        #expect(result.results.allSatisfy { !$0.candidates.isEmpty })
        let paths = LocalImportSearchMockURLProtocol.requestedPaths()
        #expect(paths.contains("debridvault.elfhosted.com/api/search"))
        #expect(paths.contains("soundcloud.com/search/sounds"))
        #expect(paths.contains("api-v2.soundcloud.com/search/tracks"))
        #expect(paths.contains("music.youtube.com/search"))
        #expect(paths.contains("www.youtube.com/results"))

        let videoResult = try await LocalImportSearchEngine(sessions: .testing(session)).search(
            "Test Song Test Artist",
            mediaMode: .video
        )
        #expect(videoResult.results(for: .spotify).count == 1)
        #expect(videoResult.results(for: .soundcloud).count == 1)
        #expect(videoResult.results(for: .youtube).count == 1)
        #expect(videoResult.results.allSatisfy { result in
            result.candidates.allSatisfy { $0.sourceProvider != .soundcloud }
        })
    }

    private func youtubeSearchHTML(videoID: String) throws -> String {
        let root: [String: Any] = [
            "contents": [[
                "musicResponsiveListItemRenderer": [
                    "playlistItemData": ["videoId": videoID],
                    "flexColumns": [
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [["text": "Test Song"]]]]],
                        ["musicResponsiveListItemFlexColumnRenderer": ["text": ["runs": [
                            ["text": "Test Artist", "navigationEndpoint": ["browseEndpoint": ["browseId": "UCtest"]]],
                            ["text": " • "],
                            ["text": "Test Album", "navigationEndpoint": ["browseEndpoint": ["browseId": "MPREtest"]]],
                            ["text": " • "],
                            ["text": "3:34"],
                        ]]]],
                    ],
                    "thumbnail": ["musicThumbnailRenderer": ["thumbnail": ["thumbnails": [[
                        "url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                    ]]]]],
                ],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let json = try #require(String(data: data, encoding: .utf8))
        return "<script>var ytInitialData = \(json);</script>"
    }
}
