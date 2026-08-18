import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import Testing
@testable import Resonance

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

private func localImportRequestBody(_ request: URLRequest) throws -> Data {
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

private final class LocalImportRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private func makeLocalImportVideoFixture(at url: URL, lastFrameSecond: Int = 1) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 64_000],
        ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64,
        ]
    )
    guard writer.canAdd(input) else { throw CocoaError(.featureUnsupported) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    writer.startSession(atSourceTime: .zero)

    for frame in 0...lastFrameSecond {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(5))
        }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw CocoaError(.fileWriteUnknown)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, frame == 0 ? 0x22 : 0x88, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: Double(frame), preferredTimescale: 600)) else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    input.markAsFinished()
    await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
    }
    guard writer.status == .completed else {
        throw writer.error ?? CocoaError(.fileWriteUnknown)
    }
}

@MainActor
@Suite(.serialized)
struct LocalImportTests {
    private let spotifyID = "4PTG3Z6ehGkBFwjybzWkR8"
    private let videoID = "jNQXAC9IVRw"
    private let m4a = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")

    private func playlistTestTrack(_ trackID: String, trackNumber: Int? = nil) -> LocalImportSpotifyTrack {
        LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: trackID,
            title: trackID,
            artist: "Artist",
            album: nil,
            trackNumber: trackNumber,
            durationSeconds: 60,
            artworkURL: nil,
            embedURL: "",
            sourceURL: "https://www.youtube.com/watch?v=\(trackID)"
        )
    }

    private func playlistTestItem(position: Int, trackID: String) -> LocalImportPlaylistItem {
        let sourceURL = "https://www.youtube.com/watch?v=\(trackID)"
        let track = playlistTestTrack(trackID, trackNumber: position)
        let candidate = LocalImportAudioSourceMatch(
            videoID: trackID,
            title: track.title,
            artist: track.artist,
            album: nil,
            durationSeconds: track.durationSeconds,
            thumbnailURL: nil,
            sourceProvider: .youtube,
            officialArtist: false,
            sourceURL: sourceURL,
            score: 1,
            confidence: "high",
            match: .init(
                title: 1,
                artist: 1,
                album: nil,
                duration: 1,
                durationDeltaSeconds: 0
            )
        )
        return LocalImportPlaylistItem(position: position, track: track, candidate: candidate)
    }

    @Test
    func validatesExactSpotifyTracksAndIndividualHTTPSYouTubeURLs() throws {
        #expect(LocalImportURL.isSpotify("https://open.spotify.com/track/\(spotifyID)"))
        #expect(!LocalImportURL.isSpotify("https://open.spotify.example/track/\(spotifyID)"))
        #expect(try LocalImportURL.spotifyTrack("https://open.spotify.com/intl-en/track/\(spotifyID)?si=test")?.trackID == spotifyID)
        #expect(try LocalImportURL.spotifyTrack("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M") == nil)
        #expect(try LocalImportURL.spotifyPlaylist("https://open.spotify.com/intl-en/playlist/37i9dQZF1DXcBWIGoYBM5M?si=test")?.playlistID == "37i9dQZF1DXcBWIGoYBM5M")
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
    func parsesOrderedYouTubePlaylistItemsAndContinuationMetadata() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstVideoID = "jNQXAC9IVRw"
        let secondVideoID = "dQw4w9WgXcQ"
        func video(_ id: String, _ title: String, _ index: Int) -> [String: Any] {
            [
                "videoId": id,
                "title": ["runs": [["text": title]]],
                "shortBylineText": ["runs": [["text": "Playlist Artist"]]],
                "lengthText": ["simpleText": index == 1 ? "3:33" : "4:05"],
                "index": ["simpleText": String(index)],
                "thumbnail": ["thumbnails": [[
                    "url": "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
                    "width": 480,
                ]]],
                "isPlayable": true,
            ]
        }
        let initial: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Road Trip"],
            ]],
            "header": ["playlistHeaderRenderer": [
                "ownerText": ["runs": [["text": "Lily"]]],
            ]],
            "contents": [
                ["playlistVideoRenderer": video(firstVideoID, "Me at the zoo", 1)],
                ["playlistVideoRenderer": [
                    "videoId": "private-video",
                    "title": ["runs": [["text": "Private item"]]],
                    "index": ["simpleText": "2"],
                    "isPlayable": false,
                ]],
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                ]],
            ],
        ]
        let parsed = try LocalImportParser.youtubePlaylistData(
            initial,
            expectedPlaylistID: playlistID
        )
        #expect(parsed.title == "Road Trip")
        #expect(parsed.author == "Lily")
        #expect(parsed.tracks.map(\.trackID) == [firstVideoID])
        #expect(parsed.tracks.first?.durationSeconds == 213)
        #expect(parsed.tracks.first?.trackNumber == 1)
        #expect(parsed.skippedItems.count == 1)
        #expect(parsed.skippedItems.first?.position == 2)
        #expect(parsed.continuation == "next-page")
        #expect(parsed.lastPlaylistPosition == 2)

        let continuation: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [["playlistVideoRenderer": video(secondVideoID, "Never Gonna Give You Up", 3)]],
                ],
            ]],
        ]
        let next = try LocalImportParser.youtubePlaylistData(
            continuation,
            expectedPlaylistID: playlistID,
            positionOffset: parsed.lastPlaylistPosition
        )
        #expect(next.tracks.map(\.trackID) == [secondVideoID])
        #expect(next.tracks.first?.durationSeconds == 245)
        #expect(next.tracks.first?.trackNumber == 3)
        #expect(next.lastPlaylistPosition == 3)

        let html = "<script>ytcfg.set({\"INNERTUBE_API_KEY\":\"test-key\",\"INNERTUBE_CLIENT_VERSION\":\"2.20260801.00.00\"});</script>"
        #expect(LocalImportParser.youtubeConfigurationValue(html, key: "INNERTUBE_API_KEY") == "test-key")
        #expect(try LocalImportURL.youtubePlaylistID("https://www.youtube.com/playlist?list=\(playlistID)") == playlistID)
        #expect(try LocalImportURL.youtubePlaylistID("https://www.youtube.com/watch?v=\(firstVideoID)&list=\(playlistID)") == playlistID)
        #expect(try LocalImportURL.youtubePlaylistID("https://youtu.be/\(firstVideoID)") == nil)
        #expect(throws: LocalImportError.self) {
            _ = try LocalImportURL.youtubePlaylistID("https://www.youtube.com/playlist?list=short")
        }
    }

    @Test
    func keepsGlobalPositionsAcrossMalformedAndRepeatedLockupRows() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstVideoID = "jNQXAC9IVRw"
        let secondVideoID = "dQw4w9WgXcQ"
        let thirdVideoID = "9bZkp7q19f0"

        func lockup(_ videoID: String, _ title: String) -> [String: Any] {
            [
                "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
                "contentId": videoID,
                "metadata": ["lockupMetadataViewModel": [
                    "title": ["content": title],
                    "metadata": ["contentMetadataViewModel": [
                        "metadataRows": [[
                            "metadataParts": [["text": ["content": "Playlist Artist"]]],
                        ]],
                    ]],
                ]],
            ]
        }

        let initial: [String: Any] = [
            "contents": [
                ["lockupViewModel": lockup(firstVideoID, "First song")],
                ["lockupViewModel": lockup("invalid", "Unavailable song")],
                ["lockupViewModel": lockup(firstVideoID, "Duplicate song")],
                ["playlistVideoRenderer": [
                    "videoId": secondVideoID,
                    "title": ["simpleText": "Second song"],
                    "shortBylineText": ["simpleText": "Playlist Artist"],
                    "isPlayable": true,
                ]],
            ],
        ]
        let firstPage = try LocalImportParser.youtubePlaylistData(
            initial,
            expectedPlaylistID: playlistID
        )

        #expect(firstPage.tracks.map(\.trackID) == [firstVideoID, firstVideoID, secondVideoID])
        #expect(firstPage.tracks.map(\.trackNumber) == [1, 3, 4])
        #expect(firstPage.skippedItems.map(\.position) == [2])
        #expect(firstPage.lastPlaylistPosition == 4)

        let continuation: [String: Any] = [
            "contents": [
                ["lockupViewModel": lockup(thirdVideoID, "Third song")],
            ],
        ]
        let nextPage = try LocalImportParser.youtubePlaylistData(
            continuation,
            expectedPlaylistID: playlistID,
            positionOffset: firstPage.lastPlaylistPosition
        )

        #expect(nextPage.tracks.map(\.trackID) == [thirdVideoID])
        #expect(nextPage.tracks.first?.trackNumber == 5)
        #expect(nextPage.lastPlaylistPosition == 5)
    }

    @Test
    func preservesRepeatedYouTubeRowsAtDistinctPositions() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let repeatedVideoID = "jNQXAC9IVRw"

        func video(_ title: String, _ index: Int) -> [String: Any] {
            [
                "videoId": repeatedVideoID,
                "title": ["simpleText": title],
                "shortBylineText": ["simpleText": "Playlist Artist"],
                "index": ["simpleText": String(index)],
                "isPlayable": true,
            ]
        }

        let parsed = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    ["playlistVideoRenderer": video("First appearance", 1)],
                    ["playlistVideoRenderer": video("Second appearance", 2)],
                ],
            ] as [String: Any],
            expectedPlaylistID: playlistID
        )

        #expect(parsed.tracks.map(\.trackID) == [repeatedVideoID, repeatedVideoID])
        #expect(parsed.tracks.map(\.title) == ["First appearance", "Second appearance"])
        #expect(parsed.tracks.map(\.trackNumber) == [1, 2])
        #expect(parsed.skippedItems.isEmpty)
    }

    @Test
    func keepsPlaylistRowsSelectableButDeduplicatesDownloadItems() {
        let first = playlistTestItem(position: 1, trackID: videoID)
        let second = playlistTestItem(position: 2, trackID: videoID)
        let playlist = LocalImportPlaylist(
            playlistID: "PL1234567890abcdefghijklmnop",
            title: "Repeated",
            author: "Artist",
            artworkURL: nil,
            sourceURL: "https://www.youtube.com/playlist?list=PL1234567890abcdefghijklmnop",
            items: [first, second],
            skippedItems: [],
            truncated: false
        )

        #expect(first.id != second.id)
        var selectedIDs = LocalImportPlaylistSelectionPolicy.allItemIDs(in: playlist.items)
        selectedIDs = LocalImportPlaylistSelectionPolicy.toggledItemIDs(selectedIDs, item: first)
        #expect(LocalImportPlaylistSelectionPolicy.selectedItems(in: playlist, itemIDs: selectedIDs).map(\.id) == [second.id])
        #expect(LocalImportPlaylistDownloadPolicy.uniqueItems([first, second]).map(\.position) == [1])
    }

    @Test
    func explicitPlaylistIndicesCannotMoveFallbackCursorBackwards() throws {
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstVideoID = "jNQXAC9IVRw"
        let secondVideoID = "dQw4w9WgXcQ"
        let thirdVideoID = "9bZkp7q19f0"
        let fourthVideoID = "aqz-KE-bpKQ"

        func video(_ id: String, _ title: String, index: Int? = nil) -> [String: Any] {
            var result: [String: Any] = [
                "videoId": id,
                "title": ["simpleText": title],
                "shortBylineText": ["simpleText": "Playlist Artist"],
                "isPlayable": true,
            ]
            if let index {
                result["index"] = ["simpleText": String(index)]
            }
            return result
        }

        let firstPage = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    ["playlistVideoRenderer": video(firstVideoID, "First song", index: 10)],
                    ["playlistVideoRenderer": video(secondVideoID, "Second song")],
                ],
            ] as [String: Any],
            expectedPlaylistID: playlistID
        )
        #expect(firstPage.tracks.map(\.trackNumber) == [10, 11])
        #expect(firstPage.lastPlaylistPosition == 11)

        let nextPage = try LocalImportParser.youtubePlaylistData(
            [
                "contents": [
                    // This explicit index is stale/page-local. It must not
                    // move the global cursor behind the previous page.
                    ["playlistVideoRenderer": video(thirdVideoID, "Third song", index: 2)],
                    ["playlistVideoRenderer": video(fourthVideoID, "Fourth song")],
                ],
            ] as [String: Any],
            expectedPlaylistID: playlistID,
            positionOffset: firstPage.lastPlaylistPosition
        )

        #expect(nextPage.tracks.map(\.trackNumber) == [12, 13])
        #expect(nextPage.lastPlaylistPosition == 13)
    }

    @Test
    func playlistLimitReportsOverflowAndRemainingContinuation() {
        let tracks = (0...LocalImportPlaylistLimitPolicy.maxItems).map { playlistTestTrack("video-\($0)") }

        let initial = LocalImportPlaylistLimitPolicy.takeInitial(tracks)
        #expect(initial.tracks.count == LocalImportPlaylistLimitPolicy.maxItems)
        #expect(initial.overflowed)
        #expect(!LocalImportPlaylistLimitPolicy.takeInitial(Array(tracks.prefix(LocalImportPlaylistLimitPolicy.maxItems))).overflowed)

        let existing = (0..<LocalImportPlaylistLimitPolicy.maxItems - 1).map {
            playlistTestTrack("existing-\($0)", trackNumber: $0 + 1)
        }
        let incoming = [
            existing[0],
            playlistTestTrack("new-at-limit", trackNumber: LocalImportPlaylistLimitPolicy.maxItems),
            playlistTestTrack("new-beyond-limit", trackNumber: LocalImportPlaylistLimitPolicy.maxItems + 1),
        ]
        let additions = LocalImportPlaylistLimitPolicy.append(existing: existing, incoming: incoming)
        #expect(additions.tracks.map(\.trackID) == ["new-at-limit"])
        #expect(additions.overflowed)
        #expect(LocalImportPlaylistLimitPolicy.hasRemainingContinuation("next-page"))
        #expect(!LocalImportPlaylistLimitPolicy.hasRemainingContinuation(nil))
    }

    @Test
    func resolvesYouTubePlaylistIntoDirectSelectableAudioItems() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }
        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstVideoID = "jNQXAC9IVRw"
        let secondVideoID = "dQw4w9WgXcQ"
        let firstData: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Road Trip"],
            ]],
            "header": ["playlistHeaderRenderer": [
                "ownerText": ["runs": [["text": "Lily"]]],
            ]],
            "contents": [
                ["playlistVideoRenderer": [
                    "videoId": firstVideoID,
                    "title": ["runs": [["text": "First song"]]],
                    "shortBylineText": ["runs": [["text": "Artist"]]],
                    "lengthText": ["simpleText": "3:33"],
                    "index": ["simpleText": "1"],
                    "isPlayable": true,
                ]],
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                ]],
            ],
        ]
        let continuationData: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [["playlistVideoRenderer": [
                        "videoId": secondVideoID,
                        "title": ["runs": [["text": "Second song"]]],
                        "shortBylineText": ["runs": [["text": "Artist"]]],
                        "lengthText": ["simpleText": "4:05"],
                        "isPlayable": true,
                    ]]],
                ],
            ]],
        ]
        let initialJSON = String(data: try JSONSerialization.data(withJSONObject: firstData), encoding: .utf8)!
        let continuationJSON = try JSONSerialization.data(withJSONObject: continuationData)
        let html = "<script>var ytInitialData = \(initialJSON);</script><script>ytcfg.set({\"INNERTUBE_API_KEY\":\"test-key\",\"INNERTUBE_CLIENT_VERSION\":\"2.20260801.00.00\",\"VISITOR_DATA\":\"visitor\"});</script>"
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "www.youtube.com", url.path == "/playlist" {
                let data = Data(html.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.host == "www.youtube.com", url.path == "/youtubei/v1/browse" {
                #expect(request.httpMethod == "POST")
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "key" && $0.value == "test-key" } == true)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(continuationJSON.count)])!,
                    continuationJSON
                )
            }
            Issue.record("Unexpected YouTube playlist request: \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        var stages: [LocalImportStage] = []
        let result = try await service.resolve(
            source: "https://www.youtube.com/watch?v=\(firstVideoID)&list=\(playlistID)",
            progress: { progress in stages.append(progress.stage) }
        )

        #expect(result.kind == .youtubePlaylist)
        #expect(result.track.title == "Road Trip")
        #expect(result.playlist?.items.map { $0.track.trackID } == [firstVideoID, secondVideoID])
        #expect(result.playlist?.items.map(\.position) == [1, 2])
        #expect(result.playlist?.truncated == false)
        #expect(result.playlist?.items.allSatisfy { $0.candidate.sourceProvider == .youtube } == true)
        #expect(result.playlist?.items.map { $0.candidate.sourceURL } == [
            "https://www.youtube.com/watch?v=\(firstVideoID)",
            "https://www.youtube.com/watch?v=\(secondVideoID)",
        ])
        #expect(stages == [.resolvingMetadata])
    }

    @Test
    func resolvesEmptyInitialYouTubePlaylistPageWithPlayableContinuation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }

        let playlistID = "PL1234567890abcdefghijklmnop"
        let unavailableVideoID = "jNQXAC9IVRw"
        let continuationVideoID = "dQw4w9WgXcQ"
        let firstData: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Road Trip"],
            ]],
            "header": ["playlistHeaderRenderer": [
                "ownerText": ["runs": [["text": "Lily"]]],
            ]],
            "contents": [
                ["playlistVideoRenderer": [
                    "videoId": unavailableVideoID,
                    "title": ["simpleText": "Unavailable song"],
                    "shortBylineText": ["simpleText": "Artist"],
                    "isPlayable": false,
                ]],
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                ]],
            ],
        ]
        let continuationData: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [["playlistVideoRenderer": [
                        "videoId": continuationVideoID,
                        "title": ["simpleText": "Second song"],
                        "shortBylineText": ["simpleText": "Artist"],
                        "isPlayable": true,
                    ]]],
                ],
            ]],
        ]
        let initialJSON = String(data: try JSONSerialization.data(withJSONObject: firstData), encoding: .utf8)!
        let continuationJSON = try JSONSerialization.data(withJSONObject: continuationData)
        let html = "<script>var ytInitialData = \(initialJSON);</script><script>ytcfg.set({\"INNERTUBE_API_KEY\":\"test-key\",\"INNERTUBE_CLIENT_VERSION\":\"2.20260801.00.00\"});</script>"
        let requestCounter = LocalImportRequestCounter()
        LocalImportMockURLProtocol.handler = { request in
            _ = requestCounter.increment()
            let url = try #require(request.url)
            if url.path == "/playlist" {
                let data = Data(html.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.path == "/youtubei/v1/browse" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(continuationJSON.count)])!,
                    continuationJSON
                )
            }
            Issue.record("Unexpected YouTube playlist request: \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        let result = try await service.resolve(
            source: "https://www.youtube.com/playlist?list=\(playlistID)",
            progress: { _ in }
        )

        #expect(result.kind == .youtubePlaylist)
        #expect(result.track.title == "Road Trip")
        #expect(result.playlist?.items.map { $0.track.trackID } == [continuationVideoID])
        #expect(result.playlist?.items.map(\.position) == [2])
        #expect(result.playlist?.skippedItems.map(\.position) == [1])
        #expect(result.playlist?.truncated == false)
        #expect(requestCounter.value == 2)
    }

    @Test
    func marksYouTubePlaylistTruncatedWhenContinuationRepeats() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }

        let playlistID = "PL1234567890abcdefghijklmnop"
        let firstVideoID = "jNQXAC9IVRw"
        let secondVideoID = "dQw4w9WgXcQ"
        let firstData: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Road Trip"],
            ]],
            "contents": [
                ["playlistVideoRenderer": [
                    "videoId": firstVideoID,
                    "title": ["simpleText": "First song"],
                    "shortBylineText": ["simpleText": "Artist"],
                    "isPlayable": true,
                ]],
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                ]],
            ],
        ]
        let continuationData: [String: Any] = [
            "onResponseReceivedActions": [[
                "appendContinuationItemsAction": [
                    "continuationItems": [
                        ["playlistVideoRenderer": [
                            "videoId": secondVideoID,
                            "title": ["simpleText": "Second song"],
                            "shortBylineText": ["simpleText": "Artist"],
                            "isPlayable": true,
                        ]],
                        ["continuationItemRenderer": [
                            "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                        ]],
                    ],
                ],
            ]],
        ]
        let initialJSON = String(data: try JSONSerialization.data(withJSONObject: firstData), encoding: .utf8)!
        let continuationJSON = try JSONSerialization.data(withJSONObject: continuationData)
        let html = "<script>var ytInitialData = \(initialJSON);</script><script>ytcfg.set({\"INNERTUBE_API_KEY\":\"test-key\",\"INNERTUBE_CLIENT_VERSION\":\"2.20260801.00.00\"});</script>"
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/playlist" {
                let data = Data(html.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.path == "/youtubei/v1/browse" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(continuationJSON.count)])!,
                    continuationJSON
                )
            }
            Issue.record("Unexpected YouTube playlist request: \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        let result = try await service.resolve(
            source: "https://www.youtube.com/playlist?list=\(playlistID)",
            progress: { _ in }
        )

        #expect(result.playlist?.items.map { $0.track.trackID } == [firstVideoID, secondVideoID])
        #expect(result.playlist?.truncated == true)
    }

    @Test
    func marksYouTubePlaylistTruncatedWhenContinuationFetchFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }

        let playlistID = "PL1234567890abcdefghijklmnop"
        let videoID = "jNQXAC9IVRw"
        let firstData: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Road Trip"],
            ]],
            "contents": [
                ["playlistVideoRenderer": [
                    "videoId": videoID,
                    "title": ["simpleText": "First song"],
                    "shortBylineText": ["simpleText": "Artist"],
                    "isPlayable": true,
                ]],
                ["continuationItemRenderer": [
                    "continuationEndpoint": ["continuationCommand": ["token": "next-page"]],
                ]],
            ],
        ]
        let initialJSON = String(data: try JSONSerialization.data(withJSONObject: firstData), encoding: .utf8)!
        let html = "<script>var ytInitialData = \(initialJSON);</script><script>ytcfg.set({\"INNERTUBE_API_KEY\":\"test-key\",\"INNERTUBE_CLIENT_VERSION\":\"2.20260801.00.00\"});</script>"
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/playlist" {
                let data = Data(html.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.path == "/youtubei/v1/browse" {
                return (
                    HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Content-Length": "0"])!,
                    Data()
                )
            }
            Issue.record("Unexpected YouTube playlist request: \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        let result = try await service.resolve(
            source: "https://www.youtube.com/playlist?list=\(playlistID)",
            progress: { _ in }
        )

        #expect(result.playlist?.items.map { $0.track.trackID } == [videoID])
        #expect(result.playlist?.truncated == true)
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
    func parsesOrderedPublicSpotifyPlaylistTracksAndSkipsUnavailableItems() throws {
        let playlistID = "37i9dQZF1DXcBWIGoYBM5M"
        let secondTrackID = "11dFghVXANMlKmJXsNCbNl"
        let artworkURL = "https://i.scdn.co/image/playlist-cover"
        let entity: [String: Any] = [
            "type": "playlist",
            "id": playlistID,
            "title": "Road Trip",
            "subtitle": "Lily",
            "coverArt": ["sources": [["url": artworkURL, "width": 640]]],
            "trackList": [
                ["uri": "spotify:track:\(spotifyID)", "title": "First Song", "subtitle": "First Artist", "duration": 123_000, "entityType": "track", "isPlayable": true],
                ["uri": "spotify:episode:ignored", "title": "Podcast", "subtitle": "Host", "duration": 1_000, "entityType": "episode", "isPlayable": true],
                ["uri": "spotify:track:\(secondTrackID)", "title": "Second Song", "subtitle": "Second Artist", "duration": 245_000, "entityType": "track", "isPlayable": true],
            ],
        ]
        let root: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
        let json = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
        let html = "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>"
        let parsed = try LocalImportParser.spotifyPlaylistEmbed(html, expectedPlaylistID: playlistID)

        #expect(parsed.title == "Road Trip")
        #expect(parsed.author == "Lily")
        #expect(parsed.tracks.map(\.trackID) == [spotifyID, secondTrackID])
        #expect(parsed.tracks.map(\.trackNumber) == [1, 3])
        #expect(parsed.tracks[1].durationSeconds == 245)
        #expect(parsed.artworkURL == artworkURL)
        #expect(parsed.tracks.allSatisfy { $0.artworkURL == nil })
        #expect(parsed.skippedItems.count == 1)
        #expect(parsed.skippedItems[0].position == 2)
        #expect(parsed.skippedItems[0].title == "Podcast")
        #expect(parsed.skippedItems[0].artist == "Host")
        #expect(parsed.skippedItems[0].reason == "Not a Spotify song")

        let oEmbed: [String: Any] = [
            "provider_name": "Spotify",
            "type": "rich",
            "title": "Road Trip",
            "thumbnail_url": artworkURL,
            "html": "<iframe src=\"https://open.spotify.com/embed/playlist/\(playlistID)?utm_source=oembed\"></iframe>",
        ]
        let preview = try LocalImportParser.spotifyPlaylistOEmbed(
            JSONSerialization.data(withJSONObject: oEmbed),
            expectedPlaylistID: playlistID
        )
        #expect(preview.title == "Road Trip")
        #expect(preview.artworkURL == artworkURL)
        #expect(preview.embedURL == "https://open.spotify.com/embed/playlist/\(playlistID)")
    }

    @Test
    func metadataOnlySpotifyResolutionStopsBeforeImportCandidateSearch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }
        LocalImportMockURLProtocol.reset()

        let spotifyID = self.spotifyID
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "open.spotify.com", url.path == "/oembed" {
                let payload: [String: Any] = [
                    "provider_name": "Spotify",
                    "type": "rich",
                    "title": "Never Gonna Give You Up",
                    "thumbnail_url": "https://image-cdn-ak.spotifycdn.com/image/cover",
                    "html": "<iframe src=\"https://open.spotify.com/embed/track/\(spotifyID)\"></iframe>",
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Length": String(data.count)]
                    )!,
                    data
                )
            }
            if url.host == "open.spotify.com", url.path == "/embed/track/\(spotifyID)" {
                let entity: [String: Any] = [
                    "type": "track",
                    "id": spotifyID,
                    "title": "Never Gonna Give You Up",
                    "artists": [["name": "Rick Astley"]],
                    "duration": 213_573,
                    "visualIdentity": [
                        "image": [[
                            "url": "https://image-cdn-fa.spotifycdn.com/image/cover",
                            "maxWidth": 640,
                        ]],
                    ],
                ]
                let root: [String: Any] = [
                    "props": ["pageProps": ["state": ["data": ["entity": entity]]]],
                ]
                let json = String(
                    data: try JSONSerialization.data(withJSONObject: root),
                    encoding: .utf8
                )!
                let data = Data(
                    "<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8
                )
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Length": String(data.count)]
                    )!,
                    data
                )
            }
            Issue.record("Metadata-only Spotify resolution made an import-preparation request to \(url)")
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        let metadata = try await service.resolveMetadata(
            source: "https://open.spotify.com/track/\(spotifyID)"
        )

        #expect(metadata.title == "Never Gonna Give You Up")
        #expect(metadata.artist == "Rick Astley")
        #expect(metadata.durationSeconds == 214)
        #expect(LocalImportMockURLProtocol.hosts() == ["open.spotify.com", "open.spotify.com"])
    }

    @Test
    func metadataOnlyYouTubeResolutionUsesOneOEmbedRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }
        LocalImportMockURLProtocol.reset()

        let videoID = self.videoID
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.host == "www.youtube.com")
            #expect(url.path == "/oembed")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            #expect(query?.first(where: { $0.name == "format" })?.value == "json")
            #expect(query?.first(where: { $0.name == "url" })?.value == "https://www.youtube.com/watch?v=\(videoID)")
            let payload: [String: Any] = [
                "type": "video",
                "provider_name": "YouTube",
                "title": "Metadata Song",
                "author_name": "Metadata Artist",
                "thumbnail_url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": String(data.count)]
                )!,
                data
            )
        }

        let service = LocalDeviceImportService(sessions: .testing(session))
        let metadata = try await service.resolveMetadata(
            source: "https://youtu.be/\(videoID)",
            mediaMode: .video
        )

        #expect(metadata.title == "Metadata Song")
        #expect(metadata.artist == "Metadata Artist")
        #expect(metadata.durationSeconds == nil)
        #expect(metadata.sourceURL == "https://www.youtube.com/watch?v=\(videoID)")
        #expect(LocalImportMockURLProtocol.hosts() == ["www.youtube.com"])
    }

    @Test
    @MainActor
    func savedYouTubeDownloadReusesCatalogMetadataBeforeStreamResolution() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-known-download-\(UUID().uuidString)", isDirectory: true)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            Issue.record("Known YouTube metadata unexpectedly made a request to \(String(describing: request.url))")
            throw URLError(.unsupportedURL)
        }

        let source = "https://youtu.be/\(videoID)"
        let metadata = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: videoID,
            title: "Already hydrated",
            artist: "Catalog artist",
            album: "Catalog album",
            trackNumber: nil,
            durationSeconds: 123,
            artworkURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            embedURL: "",
            sourceURL: source
        )
        var stages: [LocalImportStage] = []
        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: root.appendingPathComponent("library", isDirectory: true),
            temporaryRoot: root.appendingPathComponent("temporary", isDirectory: true)
        )
        let resolution = try await service.resolveSavedDownload(
            source: source,
            metadata: metadata,
            mediaMode: .audio,
            preparationContext: "https://music.test#profile=default"
        ) { progress in
            stages.append(progress.stage)
        }

        #expect(resolution.track.title == "Already hydrated")
        #expect(resolution.candidates.first?.sourceURL == source)
        #expect(stages == [.inspectingSource])
        #expect(LocalImportMockURLProtocol.hosts().isEmpty)
    }

    @Test
    func parsesOnlyValidatedDebridVaultReleaseSources() throws {
        let infoHash = String(repeating: "a", count: 40)
        let payload: [String: Any] = [
            "success": true,
            "data": [
                [
                    "title": "Rick Astley - Never Gonna Give You Up 12&#39;&#39; [FLAC]",
                    "infoHash": infoHash.uppercased(),
                    "magnetLink": "magnet:?xt=urn:btih:\(infoHash)&dn=release",
                    "size": 543_210_987,
                    "seeders": 42,
                    "leechers": 3,
                    "indexer": "Music",
                    "uploadDate": "2026-07-31",
                    "quality": "FLAC",
                ],
                [
                    "title": "Duplicate hash",
                    "infoHash": infoHash,
                    "magnetLink": "magnet:?xt=urn:btih:\(infoHash)&dn=duplicate",
                ],
                [
                    "title": "Unsafe magnet",
                    "infoHash": String(repeating: "b", count: 40),
                    "magnetLink": "https://example.invalid/file",
                ],
            ],
        ]
        let releases = try LocalImportParser.debridVaultReleases(JSONSerialization.data(withJSONObject: payload))
        let release = try #require(releases.first)
        #expect(releases.count == 1)
        #expect(release.infoHash == infoHash)
        #expect(release.title.contains("12''"))
        #expect(!release.title.contains("&#39;"))
        #expect(release.seeders == 42)
        #expect(release.size == 543_210_987)
        #expect(LocalImportURL.isDebridVaultDocument(URL(string: "https://debridvault.elfhosted.com/api/torrents/search")!))
        #expect(!LocalImportURL.isDebridVaultDocument(URL(string: "https://evil.debridvault.elfhosted.com/api/torrents/search")!))
    }

    @Test
    func spotifyResolutionCanReturnDebridSourcesWhenYouTubeHasNoMatch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalImportDebridSearch-\(UUID().uuidString)", isDirectory: true)
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

        let spotifyID = self.spotifyID
        let infoHash = String(repeating: "c", count: 40)
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "open.spotify.com", url.path == "/oembed" {
                let payload: [String: Any] = [
                    "provider_name": "Spotify",
                    "type": "rich",
                    "title": "Never Gonna Give You Up",
                    "thumbnail_url": "https://image-cdn-ak.spotifycdn.com/image/cover",
                    "html": "<iframe src=\"https://open.spotify.com/embed/track/\(spotifyID)\"></iframe>",
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "open.spotify.com", url.path == "/embed/track/\(spotifyID)" {
                let entity: [String: Any] = [
                    "type": "track",
                    "id": spotifyID,
                    "title": "Never Gonna Give You Up",
                    "artists": [["name": "Rick Astley"]],
                    "duration": 213_573,
                    "visualIdentity": ["image": [["url": "https://image-cdn-fa.spotifycdn.com/image/cover", "maxWidth": 640]]],
                ]
                let embedded: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
                let json = String(data: try JSONSerialization.data(withJSONObject: embedded), encoding: .utf8)!
                let data = Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "debridvault.elfhosted.com", url.path == "/api/torrents/search" {
                #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "artist" })?.value == "Rick Astley")
                let payload: [String: Any] = [
                    "success": true,
                    "data": [[
                        "title": "Rick Astley - Whenever You Need Somebody [FLAC]",
                        "infoHash": infoHash,
                        "magnetLink": "magnet:?xt=urn:btih:\(infoHash)&dn=release",
                        "size": 543_210_987,
                        "seeders": 42,
                        "quality": "FLAC",
                    ]],
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "music.youtube.com" || url.host == "www.youtube.com" {
                let data = Data("<html></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let resolution = try await service.resolve(source: "https://open.spotify.com/track/\(spotifyID)") { _ in }
        #expect(resolution.candidates.isEmpty)
        #expect(resolution.releases.count == 1)
        #expect(resolution.releases.first?.infoHash == infoHash)
        let hosts = LocalImportMockURLProtocol.hosts()
        #expect(hosts.contains("debridvault.elfhosted.com"))
        #expect(!hosts.contains("music.test"))
    }

    @Test
    func spotifyTrackSurfacesServerReviewCandidatesWithSnapshottedClientContext() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImportServerPlaylist-\(UUID().uuidString)", isDirectory: true)
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

        let playlistID = "37i9dQZF1DXcBWIGoYBM5M"
        let spotifyID = self.spotifyID
        let videoID = self.videoID
        let unsafeVideoID = "9bZkp7q19f0"
        let trackArtworkURL = "https://image-cdn-fa.spotifycdn.com/image/track-cover"
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "open.spotify.com", url.path == "/oembed" {
                let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "url" })?.value
                if target == "https://open.spotify.com/track/\(spotifyID)" {
                    let payload: [String: Any] = [
                        "provider_name": "Spotify",
                        "type": "rich",
                        "title": "Never Gonna Give You Up",
                        "thumbnail_url": trackArtworkURL,
                        "html": "<iframe src=\"https://open.spotify.com/embed/track/\(spotifyID)\"></iframe>",
                    ]
                    let data = try JSONSerialization.data(withJSONObject: payload)
                    return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
                }
                let payload: [String: Any] = [
                    "provider_name": "Spotify",
                    "type": "rich",
                    "title": "Road Trip",
                    "thumbnail_url": "https://i.scdn.co/image/playlist-cover",
                    "html": "<iframe src=\"https://open.spotify.com/embed/playlist/\(playlistID)\"></iframe>",
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "open.spotify.com", url.path == "/embed/playlist/\(playlistID)" {
                let entity: [String: Any] = [
                    "type": "playlist",
                    "id": playlistID,
                    "title": "Road Trip",
                    "subtitle": "Lily",
                    "coverArt": ["sources": [["url": "https://i.scdn.co/image/playlist-cover", "width": 640]]],
                    "trackList": [[
                        "uri": "spotify:track:\(spotifyID)",
                        "title": "Never Gonna Give You Up",
                        "subtitle": "Rick Astley",
                        "duration": 213_000,
                        "entityType": "track",
                        "isPlayable": true,
                    ]],
                ]
                let embedded: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
                let json = String(data: try JSONSerialization.data(withJSONObject: embedded), encoding: .utf8)!
                let data = Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "open.spotify.com", url.path == "/embed/track/\(spotifyID)" {
                let entity: [String: Any] = [
                    "type": "track",
                    "id": spotifyID,
                    "title": "Never Gonna Give You Up",
                    "artists": [["name": "Rick Astley"]],
                    "duration": 213_573,
                    "visualIdentity": ["image": [["url": trackArtworkURL, "maxWidth": 640]]],
                ]
                let embedded: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
                let json = String(data: try JSONSerialization.data(withJSONObject: embedded), encoding: .utf8)!
                let data = Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "music.youtube.com" || url.host == "www.youtube.com" {
                let data = Data("<html></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "music.example.test", url.path == "/api/v1/admin/debrid/resolve" {
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer preview-admin")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-App-Version") == "1.1.4")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-App-Build") == "15")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key") == "AAECAwQFBgcICQoLDA0ODw")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")
                let body = try localImportRequestBody(request)
                let input = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(input["source"] == "https://open.spotify.com/track/\(spotifyID)")
                let payload: [String: Any] = [
                    "audio_sources": [],
                    "review_candidates": [
                        [
                            "provider": "youtube",
                            "source_url": "https://www.youtube.com/watch?v=\(unsafeVideoID)",
                            "video_id": unsafeVideoID,
                            "title": "Unsafe automatic candidate",
                            "artist": "Rick Astley",
                            "score": 0.99,
                            "confidence": "high",
                            "actionable": true,
                            "auto_selectable": true,
                            "requires_review": false,
                            "match": [
                                "title": 1.0,
                                "artist": 1.0,
                                "duration_delta_seconds": 0,
                            ],
                        ],
                        [
                            "provider": "youtube_music",
                            "source_url": "https://www.youtube.com/watch?v=\(videoID)",
                            "video_id": videoID,
                            "title": "Never Gonna Give You Up",
                            "artist": "Rick Astley",
                            "album": "Whenever You Need Somebody",
                            "duration_seconds": 213,
                            "thumbnail_url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                            "score": 0.98,
                            "confidence": "possible",
                            "actionable": false,
                            "auto_selectable": false,
                            "requires_review": true,
                            "match": [
                                "title": 1.0,
                                "artist": 1.0,
                                "album": 1.0,
                                "duration": 1.0,
                                "duration_delta_seconds": 0,
                            ],
                        ],
                    ],
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Length": String(data.count),
                ])!, data)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let resolution = try await service.resolve(
            source: "https://open.spotify.com/track/\(spotifyID)",
            serverConfiguration: .init(
                baseURL: URL(string: "https://music.example.test")!,
                adminToken: "preview-admin",
                profileID: "profile-b",
                clientContext: .init(
                    origin: "https://music.example.test",
                    profileID: "profile-b",
                    appVersion: "1.1.4",
                    appBuild: 15,
                    cohortKey: "AAECAwQFBgcICQoLDA0ODw",
                    cohortBucket: MacClientConfigContext.cohortBucket(for: "AAECAwQFBgcICQoLDA0ODw"),
                    tokenFingerprint: MacClientConfigContext.tokenFingerprint("preview-admin")
                )
            )
        ) { _ in }

        #expect(resolution.kind == .spotify)
        #expect(resolution.playlist == nil)
        #expect(resolution.track.artworkURL == trackArtworkURL)
        #expect(resolution.candidates.count == 1)
        #expect(resolution.candidates[0].videoID == videoID)
        #expect(resolution.candidates[0].sourceProvider == .youtubeMusic)
        #expect(resolution.candidates[0].sourceURL == "https://www.youtube.com/watch?v=\(videoID)")
        #expect(resolution.reviewCandidateVideoIDs == [videoID])
        #expect(LocalImportMockURLProtocol.hosts().contains("music.example.test"))
    }

    @Test
    func spotifyPlaylistRetriesTransientlyEmptyYouTubeSearches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImportPlaylistRetry-\(UUID().uuidString)", isDirectory: true)
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

        let playlistID = "37i9dQZF1DXcBWIGoYBM5M"
        let spotifyID = self.spotifyID
        let videoID = self.videoID
        let fallbackVideoID = "9bZkp7q19f0"
        let webRequests = LocalImportRequestCounter()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "open.spotify.com", url.path == "/oembed" {
                let payload: [String: Any] = [
                    "provider_name": "Spotify",
                    "type": "rich",
                    "title": "Retry Mix",
                    "html": "<iframe src=\"https://open.spotify.com/embed/playlist/\(playlistID)\"></iframe>",
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "open.spotify.com", url.path == "/embed/playlist/\(playlistID)" {
                let entity: [String: Any] = [
                    "type": "playlist",
                    "id": playlistID,
                    "title": "Retry Mix",
                    "subtitle": "Lily",
                    "trackList": [[
                        "uri": "spotify:track:\(spotifyID)",
                        "title": "Never Gonna Give You Up",
                        "subtitle": "Rick Astley",
                        "duration": 213_000,
                        "entityType": "track",
                        "isPlayable": true,
                    ]],
                ]
                let embedded: [String: Any] = ["props": ["pageProps": ["state": ["data": ["entity": entity]]]]]
                let json = String(data: try JSONSerialization.data(withJSONObject: embedded), encoding: .utf8)!
                let data = Data("<html><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "music.youtube.com" {
                let data = Data("<html></html>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "www.youtube.com" {
                let attempt = webRequests.increment()
                let data: Data
                if attempt == 1 {
                    data = Data("<html></html>".utf8)
                } else {
                    let renderer: [String: Any] = [
                        "videoId": videoID,
                        "title": ["runs": [["text": "Never Gonna Give You Up"]]],
                        "ownerText": ["runs": [["text": "Rick Astley"]]],
                        "lengthText": ["simpleText": "3:33"],
                    ]
                    let fallbackRenderer: [String: Any] = [
                        "videoId": fallbackVideoID,
                        "title": ["runs": [["text": "Never Gonna Give You Up (Audio)"]]],
                        "ownerText": ["runs": [["text": "Rick Astley"]]],
                        "lengthText": ["simpleText": "3:37"],
                    ]
                    let root: [String: Any] = [
                        "contents": [
                            ["videoRenderer": renderer],
                            ["videoRenderer": fallbackRenderer],
                        ],
                    ]
                    let json = String(data: try JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
                    data = Data("<script>ytInitialData = \(json);</script>".utf8)
                }
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host == "music.example.test" {
                Issue.record("Playlist matching must not auto-select server review candidates")
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let resolution = try await service.resolve(
            source: "https://open.spotify.com/playlist/\(playlistID)",
            serverConfiguration: .init(
                baseURL: URL(string: "https://music.example.test")!,
                adminToken: "preview-admin",
                profileID: "profile-b",
                clientContext: .init(
                    origin: "https://music.example.test",
                    profileID: "profile-b",
                    appVersion: "1.1.4",
                    appBuild: 15,
                    cohortKey: "AAECAwQFBgcICQoLDA0ODw",
                    cohortBucket: MacClientConfigContext.cohortBucket(for: "AAECAwQFBgcICQoLDA0ODw"),
                    tokenFingerprint: MacClientConfigContext.tokenFingerprint("preview-admin")
                )
            )
        ) { _ in }

        let playlist = try #require(resolution.playlist)
        #expect(webRequests.value == 2)
        #expect(playlist.items.count == 1)
        #expect(playlist.items[0].candidate.videoID == videoID)
        #expect(playlist.items[0].fallbackCandidates.map(\.videoID) == [fallbackVideoID])
        #expect(playlist.skippedItems.isEmpty)
    }

    @Test
    func productionYouTubeSessionKeepsVisitorCookiesInEphemeralStorage() {
        let sessions = LocalImportSessions.production()
        defer {
            sessions.spotify.invalidateAndCancel()
            sessions.youtube.invalidateAndCancel()
            sessions.debridVault.invalidateAndCancel()
            sessions.server.invalidateAndCancel()
            sessions.googleVideo.invalidateAndCancel()
            sessions.artwork.invalidateAndCancel()
        }

        #expect(sessions.youtube.configuration.httpShouldSetCookies)
        #expect(sessions.youtube.configuration.httpCookieStorage != nil)
        #expect(sessions.youtube.configuration.httpCookieStorage !== HTTPCookieStorage.shared)
        #expect(!sessions.spotify.configuration.httpShouldSetCookies)
        #expect(sessions.spotify.configuration.httpCookieStorage == nil)
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
    func resolvesDownloadsAndSavesWithoutWaitingForUnfinishedMetadataEnrichment() async throws {
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
                let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
                let end = isProbe ? 0 : fixture.count - 1
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(end)")
                let body = isProbe ? Data(fixture.prefix(1)) : fixture
                return (HTTPURLResponse(
                    url: url,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Range": "bytes 0-\(end)/\(fixture.count)",
                        "Content-Length": String(body.count),
                        "Content-Type": "audio/mp4",
                    ]
                )!, body)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let metadataEnrichment = LocalImportMetadataEnrichment {
            try? await Task.sleep(for: .seconds(3_600))
            return nil
        }
        defer { metadataEnrichment.cancel() }
        let authorizationChecks = LocalImportRequestCounter()
        let prematureInstallations = LocalImportRequestCounter()
        var stages: [LocalImportStage] = []
        let resolution = try await service.resolve(source: "https://youtu.be/\(videoID)") { progress in
            stages.append(progress.stage)
        }
        let candidate = try #require(resolution.candidates.first)
        let preview = try await service.previewStream(for: candidate)
        #expect(preview.url.host?.hasSuffix("googlevideo.com") == true)
        #expect(preview.httpHeaders["Origin"] == "https://www.youtube.com")
        #expect(preview.httpHeaders["User-Agent"]?.isEmpty == false)
        let outcome = try await service.importCandidate(
            candidate,
            metadata: LocalImportMetadata(
                title: "Local Test Audio",
                artist: "Resonance",
                album: "Device Library",
                artworkURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                sourceURL: "https://youtu.be/\(videoID)"
            ),
            metadataEnrichment: metadataEnrichment,
            finalizeAuthorization: {
                _ = authorizationChecks.increment()
                if (try? FileManager.default.contentsOfDirectory(atPath: library.path))?.isEmpty != true {
                    _ = prematureInstallations.increment()
                }
            },
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
        #expect(metadataEnrichment.availableMetadata == nil)
        #expect(authorizationChecks.value == 1)
        #expect(prematureInstallations.value == 0)
        #expect(imported.downloadSourceURL?.absoluteString == "https://rr1.example.googlevideo.com/videoplayback")
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
        guard case .duplicate(let duplicateID, let duplicateSource) = duplicate else {
            Issue.record("Expected SHA-256 duplicate detection")
            return
        }
        #expect(duplicateID == duplicateTrack.id)
        #expect(duplicateSource.sourceURL == imported.metadata.sourceURL)
        #expect(duplicateSource.downloadSourceURL == imported.downloadSourceURL)
        let localFiles = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        #expect(localFiles.count == 1)
    }

    @MainActor
    @Test
    func playlistVideoSelectionUsesVideoTransferMode() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalPlaylistVideoImport-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let videoFixtureURL = root.appendingPathComponent("video-only.mp4")
        try await makeLocalImportVideoFixture(at: videoFixtureURL)
        let videoFixture = try Data(contentsOf: videoFixtureURL)
        let audioFixture = try Data(contentsOf: m4a)
        let playlistID = "PL1234567890abcdefghijklmnop"
        let videoID = self.videoID
        let initialData: [String: Any] = [
            "metadata": ["playlistMetadataRenderer": [
                "playlistId": playlistID,
                "title": ["simpleText": "Video Playlist"],
            ]],
            "header": ["playlistHeaderRenderer": [
                "ownerText": ["runs": [["text": "Resonance"]]],
            ]],
            "contents": [["playlistVideoRenderer": [
                "videoId": videoID,
                "title": ["simpleText": "Local Playlist Video"],
                "shortBylineText": ["simpleText": "Resonance"],
                "lengthText": ["simpleText": "0:01"],
                "index": ["simpleText": "1"],
                "isPlayable": true,
            ]]],
        ]
        let initialJSON = try JSONSerialization.data(withJSONObject: initialData)
        let initialDocument = String(data: initialJSON, encoding: .utf8)!
        let html = "<script>var ytInitialData = \(initialDocument);</script><script>ytcfg.set({\"VISITOR_DATA\":\"visitor_playlist_video\"});</script>"

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "www.youtube.com", url.path == "/playlist" {
                let data = Data(html.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.host == "www.youtube.com",
               (url.path == "/watch" || url.path.hasPrefix("/embed/")) {
                let data = Data("<script>ytcfg.set({\"VISITOR_DATA\":\"visitor_playlist_video\"});</script>".utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.host == "www.youtube.com", url.path == "/youtubei/v1/player" {
                let player: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": [
                        "videoId": videoID,
                        "title": "Local Playlist Video",
                        "author": "Resonance",
                        "lengthSeconds": "1",
                    ],
                    "streamingData": ["adaptiveFormats": [
                        [
                            "itag": 137,
                            "url": "https://rr1.example.googlevideo.com/video-only",
                            "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                            "bitrate": 5_000_000,
                            "contentLength": String(videoFixture.count),
                            "qualityLabel": "1080p",
                            "height": 1080,
                        ],
                        [
                            "itag": 140,
                            "url": "https://rr1.example.googlevideo.com/audio-only",
                            "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                            "bitrate": 129_000,
                            "contentLength": String(audioFixture.count),
                            "audioQuality": "AUDIO_QUALITY_MEDIUM",
                            "audioChannels": 2,
                        ],
                    ]],
                ]
                let data = try JSONSerialization.data(withJSONObject: player)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!,
                    data
                )
            }
            if url.host?.hasSuffix("googlevideo.com") == true {
                let fixture = url.path == "/audio-only" ? audioFixture : videoFixture
                let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
                let end = isProbe ? 0 : fixture.count - 1
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(end)")
                let body = isProbe ? Data(fixture.prefix(1)) : fixture
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Range": "bytes 0-\(end)/\(fixture.count)",
                            "Content-Length": String(body.count),
                            "Content-Type": url.path == "/audio-only" ? "audio/mp4" : "video/mp4",
                        ]
                    )!,
                    body
                )
            }
            throw URLError(.unsupportedURL)
        }

        let suiteName = "LocalPlaylistVideoImport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let viewModel = MacLocalImportViewModel(model: model, service: service)
        viewModel.source = "https://www.youtube.com/playlist?list=\(playlistID)"
        viewModel.mediaMode = .video
        viewModel.syncAfterImport = false
        viewModel.resolve()
        for _ in 0..<200 {
            if viewModel.stage == .awaitingSelection { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(viewModel.stage == .awaitingSelection)
        #expect(viewModel.selectedPlaylistItems.count == 1)
        #expect(viewModel.importSelected())
        for _ in 0..<400 {
            if !viewModel.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(viewModel.stage == .complete)
        let imported = try #require(model.tracks.first)
        #expect(imported.kind == .video)
        #expect(imported.fileURL?.pathExtension == "mp4")
    }

    @Test
    func youtubeVideoModeDownloadsPlayableMP4AndAddsAVideoTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalVideoImport-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let fixtureURL = root.appendingPathComponent("fixture.mp4")
        try await makeLocalImportVideoFixture(at: fixtureURL)
        let fixture = try Data(contentsOf: fixtureURL)
        #expect(!fixture.isEmpty)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        let videoID = self.videoID
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/watch" || url.path.hasPrefix("/embed/") {
                let data = Data("<script>ytcfg.set({\"VISITOR_DATA\":\"visitor_video\"});</script>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.path == "/youtubei/v1/player" {
                let player: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": [
                        "videoId": videoID,
                        "title": "Local Test Video",
                        "author": "Resonance",
                        "lengthSeconds": "1",
                    ],
                    "streamingData": ["formats": [[
                        "itag": 18,
                        "url": "https://rr1.example.googlevideo.com/videoplayback",
                        "mimeType": "video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"",
                        "bitrate": 500_000,
                        "contentLength": String(fixture.count),
                        "qualityLabel": "360p",
                        "height": 360,
                        "audioQuality": "AUDIO_QUALITY_MEDIUM",
                        "audioChannels": 2,
                    ]]],
                ]
                let data = try JSONSerialization.data(withJSONObject: player)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host?.hasSuffix("googlevideo.com") == true {
                let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
                let end = isProbe ? 0 : fixture.count - 1
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(end)")
                let body = isProbe ? Data(fixture.prefix(1)) : fixture
                return (HTTPURLResponse(
                    url: url,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Range": "bytes 0-\(end)/\(fixture.count)",
                        "Content-Length": String(body.count),
                        "Content-Type": "video/mp4",
                    ]
                )!, body)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let resolution = try await service.resolve(
            source: "https://youtu.be/\(videoID)",
            mediaMode: .video
        ) { _ in }
        let candidate = try #require(resolution.candidates.first)
        let outcome = try await service.importCandidate(
            candidate,
            metadata: .init(
                title: "Local Test Video",
                artist: "Resonance",
                album: "Device Videos",
                artworkURL: nil,
                sourceURL: "https://youtu.be/\(videoID)"
            ),
            existingTracks: [],
            mediaMode: .video
        ) { _ in }
        guard case .created(let imported) = outcome else {
            Issue.record("Expected a newly downloaded video")
            return
        }

        #expect(imported.mediaMode == .video)
        #expect(imported.downloadSourceURL?.absoluteString == "https://rr1.example.googlevideo.com/videoplayback")
        #expect(imported.fileURL.pathExtension == "mp4")
        #expect(imported.duration > 0)
        #expect(FileManager.default.fileExists(atPath: imported.fileURL.path))
        let asset = AVURLAsset(url: imported.fileURL)
        #expect(!(try await asset.loadTracks(withMediaType: .video)).isEmpty)

        let suiteName = "LocalVideoImport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let track = model.insertLocalImportedAudio(imported)
        #expect(track.kind == .video)
        #expect(track.fileURL == imported.fileURL)
        #expect(track.downloadSourceURL == nil)
    }

    @Test
    func youtubeVideoModeDownloadsAndMuxesSeparateAdaptiveStreams() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalAdaptiveVideoImport-\(UUID().uuidString)", isDirectory: true)
        let library = root.appendingPathComponent("Library", isDirectory: true)
        let temporary = root.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }

        let videoFixtureURL = root.appendingPathComponent("video-only.mp4")
        try await makeLocalImportVideoFixture(at: videoFixtureURL, lastFrameSecond: 5)
        let videoFixture = try Data(contentsOf: videoFixtureURL)
        let audioFixture = try Data(contentsOf: m4a)
        #expect(!videoFixture.isEmpty)
        #expect(!audioFixture.isEmpty)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        let videoID = self.videoID
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/watch" || url.path.hasPrefix("/embed/") {
                let data = Data("<script>ytcfg.set({\"VISITOR_DATA\":\"visitor_adaptive_video\"});</script>".utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.path == "/youtubei/v1/player" {
                let player: [String: Any] = [
                    "playabilityStatus": ["status": "OK"],
                    "videoDetails": [
                        "videoId": videoID,
                        "title": "Local Adaptive Video",
                        "author": "Resonance",
                        "lengthSeconds": "1",
                    ],
                    "streamingData": ["adaptiveFormats": [
                        [
                            "itag": 137,
                            "url": "https://rr1.example.googlevideo.com/video-only",
                            "mimeType": "video/mp4; codecs=\"avc1.640028\"",
                            "bitrate": 5_000_000,
                            "contentLength": String(videoFixture.count),
                            "qualityLabel": "1080p",
                            "height": 1080,
                        ],
                        [
                            "itag": 140,
                            "url": "https://rr1.example.googlevideo.com/audio-only",
                            "mimeType": "audio/mp4; codecs=\"mp4a.40.2\"",
                            "bitrate": 129_000,
                            "contentLength": String(audioFixture.count),
                            "audioQuality": "AUDIO_QUALITY_MEDIUM",
                            "audioChannels": 2,
                        ],
                    ]],
                ]
                let data = try JSONSerialization.data(withJSONObject: player)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!, data)
            }
            if url.host?.hasSuffix("googlevideo.com") == true {
                let fixture = url.path == "/audio-only" ? audioFixture : videoFixture
                let isProbe = request.value(forHTTPHeaderField: "Range") == "bytes=0-0"
                let end = isProbe ? 0 : fixture.count - 1
                #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-\(end)")
                let body = isProbe ? Data(fixture.prefix(1)) : fixture
                return (HTTPURLResponse(
                    url: url,
                    statusCode: 206,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Range": "bytes 0-\(end)/\(fixture.count)",
                        "Content-Length": String(body.count),
                        "Content-Type": url.path == "/audio-only" ? "audio/mp4" : "video/mp4",
                    ]
                )!, body)
            }
            throw URLError(.unsupportedURL)
        }

        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: library,
            temporaryRoot: temporary
        )
        let resolution = try await service.resolve(
            source: "https://youtu.be/\(videoID)",
            mediaMode: .video
        ) { _ in }
        let candidate = try #require(resolution.candidates.first)
        let outcome = try await service.importCandidate(
            candidate,
            metadata: .init(
                title: "Local Adaptive Video",
                artist: "Resonance",
                album: "Device Videos",
                artworkURL: nil,
                sourceURL: "https://youtu.be/\(videoID)"
            ),
            existingTracks: [],
            mediaMode: .video
        ) { _ in }
        guard case .created(let imported) = outcome else {
            Issue.record("Expected a newly muxed adaptive video")
            return
        }

        let asset = AVURLAsset(url: imported.fileURL)
        #expect(imported.mediaMode == .video)
        #expect(imported.downloadSourceURL == nil)
        #expect(imported.fileURL.pathExtension == "mp4")
        #expect(!(try await asset.loadTracks(withMediaType: .video)).isEmpty)
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty)
        let videoDuration = try #require(
            try await asset.loadTracks(withMediaType: .video).first?.load(.timeRange).duration.seconds
        )
        let audioDuration = try #require(
            try await asset.loadTracks(withMediaType: .audio).first?.load(.timeRange).duration.seconds
        )
        #expect(abs(videoDuration - audioDuration) < 0.1)
        #expect(abs(imported.duration - audioDuration) < 0.1)
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
    func localImportRemainsVisibleAndUnownedAcrossProfileChanges() async throws {
        let suiteName = "LocalImportProfiles.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            LocalImportMockURLProtocol.reset()
            session.invalidateAndCancel()
        }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(url.path == "/api/v1/profiles")
            let data = Data(#"{"default_profile_id":"default","profiles":[{"id":"default","name":"Default","is_default":true,"song_count":0,"playlist_count":0,"liked_count":0},{"id":"another-profile","name":"Another Profile","is_default":false,"song_count":0,"playlist_count":0,"liked_count":0}]}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        let imported = LocalImportedAudio(
            fileURL: m4a,
            metadata: .init(title: "Local", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/\(videoID)"),
            duration: 4,
            artworkData: nil,
            downloadSourceURL: URL(string: "https://media.example/local-profile-import.m4a"),
            sourceSHA256: "source-hash",
            contentSHA256: "content-hash"
        )
        let track = model.insertLocalImportedAudio(imported)
        #expect(track.remoteID == nil)
        #expect(track.syncProfileID == nil)
        #expect(track.sourceURL == "https://youtu.be/\(videoID)")
        #expect(track.downloadSourceURL == "https://media.example/local-profile-import.m4a")
        #expect(await model.selectSyncProfile(matching: "another-profile"))
        #expect(model.visibleTracks.contains(where: { $0.id == track.id }))

        model.flushPersistence()
        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(reloaded.visibleTracks.contains(where: { $0.id == track.id }))
        let reloadedTrack = try #require(reloaded.tracks.first(where: { $0.id == track.id }))
        #expect(reloadedTrack.syncProfileID == nil)
        #expect(reloadedTrack.fileURL == track.fileURL)
        #expect(reloadedTrack.sourceURL == "https://youtu.be/\(videoID)")
        #expect(reloadedTrack.downloadSourceURL == "https://media.example/local-profile-import.m4a")
    }

    @Test
    func duplicateLocalImportBackfillsLinksBesideTheExistingFile() throws {
        let suiteName = "LocalImportSourceBackfill.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let existing = Track(
            title: "Existing",
            artist: "Device",
            album: "Imported",
            duration: 4,
            artwork: .midnight,
            fileURL: m4a,
            sourceSHA256: "same-source",
            contentSHA256: "same-content"
        )
        model.tracks = [existing]

        let associated = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: m4a,
            metadata: .init(
                title: "Existing",
                artist: "Device",
                album: "Imported",
                artworkURL: nil,
                sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
            ),
            duration: 4,
            artworkData: nil,
            downloadSourceURL: URL(string: "https://media.example/existing.m4a"),
            sourceSHA256: "same-source",
            contentSHA256: "same-content"
        ))

        #expect(associated.id == existing.id)
        #expect(associated.fileURL == existing.fileURL)
        #expect(associated.sourceURL == "https://www.youtube.com/watch?v=\(videoID)")
        #expect(associated.downloadSourceURL == "https://media.example/existing.m4a")
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
        var uploadSchemas: [Int] = []
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET", url.path == "/api/v1/profiles" {
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == nil)
                let data = Data(#"{"default_profile_id":"default","profiles":[{"id":"default","name":"Default","is_default":true,"song_count":0,"playlist_count":0,"liked_count":0},{"id":"profile-b","name":"Profile B","is_default":false,"song_count":0,"playlist_count":0,"liked_count":0}]}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
            if request.httpMethod == "PUT", url.path == "/api/v1/admin/songs" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try localImportRequestBody(request)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let schema = try #require(object["schema_version"] as? Int)
                uploadSchemas.append(schema)
                #expect(object["source_url"] as? String == "https://youtu.be/\(videoID)")
                if schema == 3 {
                    #expect(Set(object.keys) == ["schema_version", "source_url", "media_kind"])
                    #expect(object["media_kind"] as? String == "audio")
                    let data = Data(#"{"error":"Unsupported source-link schema_version"}"#.utf8)
                    return (HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, data)
                }
                #expect(schema == 2)
                #expect(Set(object.keys) == ["schema_version", "source_url"])
                let data = Data(#"{"id":"uploaded-audio","source_url":"https://media.example/local-upload.m4a","profile_id":"profile-b","download_url":"/api/v1/songs/uploaded-audio/file","stream_url":"/api/v1/songs/uploaded-audio/stream"}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!, data)
            }
            if request.httpMethod == "GET", url.path == "/api/v1/songs" {
                Issue.record("An admin upload must not require a catalog refresh")
                throw URLError(.unsupportedURL)
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
        #expect(await model.selectSyncProfile(matching: "profile-b"))
        model.serverToken = ""
        let track = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: localFile,
            metadata: .init(title: "Local Upload", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/\(videoID)"),
            duration: 4,
            artworkData: nil,
            downloadSourceURL: URL(string: "https://media.example/local-upload.m4a"),
            sourceSHA256: "upload-source-hash",
            contentSHA256: "upload-content-hash"
        ))

        #expect(try await model.uploadLocalImportToActiveProfile(track))
        #expect(uploadSchemas == [3, 2])
        #expect(model.tracks.first(where: { $0.id == track.id })?.remoteID == "uploaded-audio")
        #expect(model.tracks.first(where: { $0.id == track.id })?.syncProfileID == "profile-b")

        LocalImportMockURLProtocol.handler = { _ in
            Issue.record("A song already present in the active catalog must not be uploaded again")
            throw URLError(.unsupportedURL)
        }
        #expect(try await model.uploadLocalImportToActiveProfile(track) == false)

        let failedFile = root.appendingPathComponent("Failed Upload.m4a")
        try FileManager.default.copyItem(at: m4a, to: failedFile)
        let failedTrack = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: failedFile,
            metadata: .init(title: "Failed Upload", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/failure-upload"),
            duration: 4,
            artworkData: nil,
            downloadSourceURL: URL(string: "https://media.example/failed-upload.m4a"),
            sourceSHA256: "failed-upload-source-hash",
            contentSHA256: "failed-upload-content-hash"
        ))
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
            return (HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        var uploadFailed = false
        do {
            try await model.uploadLocalImportToActiveProfile(failedTrack)
        } catch {
            uploadFailed = true
        }
        #expect(uploadFailed)
        #expect(FileManager.default.fileExists(atPath: failedFile.path))
        #expect(model.visibleTracks.contains(where: { $0.id == failedTrack.id }))
        #expect(model.tracks.first(where: { $0.id == track.id })?.syncProfileID == "profile-b")
    }

    @Test
    func optionalUploadRefusesToReplaceAnotherServerAssociation() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            LocalImportMockURLProtocol.reset()
        }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { _ in
            Issue.record("A conflicting remote association must be rejected before upload")
            throw URLError(.unsupportedURL)
        }

        let suiteName = "LocalImportAssociationConflict.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverAdminToken = "admin-token"
        let track = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: m4a,
            metadata: .init(
                title: "Already linked",
                artist: "Device",
                album: "Only",
                artworkURL: nil,
                sourceURL: "https://youtu.be/\(videoID)"
            ),
            duration: 4,
            artworkData: nil,
            sourceSHA256: "linked-source-hash",
            contentSHA256: "linked-content-hash"
        ))
        #expect(model.reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: "old-server-audio",
            sourceServer: "https://old-music.test/",
            profileID: "default"
        ))

        var rejectedConflict = false
        do {
            _ = try await model.uploadLocalImportToActiveProfile(track)
        } catch LocalImportTransferContextError.remoteAssociationConflict {
            rejectedConflict = true
        }

        #expect(rejectedConflict)
        let preserved = try #require(model.tracks.first(where: { $0.id == track.id }))
        #expect(preserved.remoteID == "old-server-audio")
        #expect(preserved.sourceServer == "https://old-music.test")
        #expect(preserved.syncProfileID == "default")
        #expect(!model.isUploadingLocalImport)
    }

    @Test
    func localImportOnlyTrustsCachedRemoteIDsFromTheActiveContextAndNeverRebindsOthers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImportCachedRemoteID-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suiteName = "LocalImportCachedRemoteID.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverAdminToken = "admin-token"
        model.remoteSongs = try JSONDecoder().decode(RemoteCatalog.self, from: Data(#"""
        {
          "songs":[
            {"id":"cross-collision","filename":"cross.m4a","title":"Different Cross Song","artist":"Different Artist","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/cross","stream_url":"/stream/cross"},
            {"id":"unknown-collision","filename":"unknown.m4a","title":"Different Unknown Song","artist":"Different Artist","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/unknown","stream_url":"/stream/unknown"},
            {"id":"inactive-collision","filename":"inactive.m4a","title":"Different Inactive Song","artist":"Different Artist","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/inactive","stream_url":"/stream/inactive"},
            {"id":"active-id","filename":"active.m4a","title":"Different Active Song","artist":"Different Artist","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/active","stream_url":"/stream/active"},
            {"id":"hash-active","filename":"hash.m4a","title":"Different Hash Song","artist":"Different Artist","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/mp4","content_sha256":"MATCH-HASH","download_url":"/download/hash","stream_url":"/stream/hash"}
          ],
          "count":5
        }
        """#.utf8)).songs

        func importedTrack(named name: String, hash: String) throws -> Track {
            let file = root.appendingPathComponent("\(name).m4a")
            try FileManager.default.copyItem(at: m4a, to: file)
            return model.insertLocalImportedAudio(LocalImportedAudio(
                fileURL: file,
                metadata: .init(
                    title: name,
                    artist: "Local Artist",
                    album: "Local Album",
                    artworkURL: nil,
                    sourceURL: "https://youtu.be/\(name)"
                ),
                duration: 4,
                artworkData: nil,
                sourceSHA256: "source-\(hash)",
                contentSHA256: hash
            ))
        }

        let crossServer = try importedTrack(named: "Cross Server", hash: "cross-hash")
        let unknownOrigin = try importedTrack(named: "Unknown Origin", hash: "unknown-hash")
        let inactiveProfile = try importedTrack(named: "Inactive Profile", hash: "inactive-hash")
        let activeIdentity = try importedTrack(named: "Active Identity", hash: "active-hash")
        let hashMatch = try importedTrack(named: "Hash Match", hash: "match-hash")
        let crossIndex = try #require(model.tracks.firstIndex(where: { $0.id == crossServer.id }))
        model.tracks[crossIndex].remoteID = "cross-collision"
        model.tracks[crossIndex].sourceServer = "https://archive.test"
        model.tracks[crossIndex].syncProfileID = "default"
        let unknownIndex = try #require(model.tracks.firstIndex(where: { $0.id == unknownOrigin.id }))
        model.tracks[unknownIndex].remoteID = "unknown-collision"
        model.tracks[unknownIndex].sourceServer = nil
        model.tracks[unknownIndex].syncProfileID = "default"
        let inactiveIndex = try #require(model.tracks.firstIndex(where: { $0.id == inactiveProfile.id }))
        model.tracks[inactiveIndex].remoteID = "inactive-collision"
        model.tracks[inactiveIndex].sourceServer = "https://music.test"
        model.tracks[inactiveIndex].syncProfileID = "old-profile"
        let activeIndex = try #require(model.tracks.firstIndex(where: { $0.id == activeIdentity.id }))
        model.tracks[activeIndex].remoteID = "active-id"
        model.tracks[activeIndex].sourceServer = "https://music.test"
        model.tracks[activeIndex].syncProfileID = "default"
        let hashIndex = try #require(model.tracks.firstIndex(where: { $0.id == hashMatch.id }))
        model.tracks[hashIndex].remoteID = "stale-hash-id"
        model.tracks[hashIndex].sourceServer = "https://archive.test"
        model.tracks[hashIndex].syncProfileID = "default"

        let requestCount = LocalImportRequestCounter()
        LocalImportMockURLProtocol.handler = { request in
            _ = requestCount.increment()
            Issue.record("A track linked to another context must not be uploaded")
            throw URLError(.unsupportedURL)
        }

        var conflictCount = 0
        for track in [crossServer, unknownOrigin, inactiveProfile, hashMatch] {
            do {
                _ = try await model.uploadLocalImportToActiveProfile(track)
            } catch LocalImportTransferContextError.remoteAssociationConflict {
                conflictCount += 1
            }
        }
        #expect(try await model.uploadLocalImportToActiveProfile(activeIdentity) == false)

        #expect(conflictCount == 4)
        #expect(requestCount.value == 0)
        #expect(model.tracks.first(where: { $0.id == crossServer.id })?.remoteID == "cross-collision")
        #expect(model.tracks.first(where: { $0.id == unknownOrigin.id })?.remoteID == "unknown-collision")
        #expect(model.tracks.first(where: { $0.id == inactiveProfile.id })?.remoteID == "inactive-collision")
        #expect(model.tracks.first(where: { $0.id == hashMatch.id })?.remoteID == "stale-hash-id")
    }

    @Test
    func cachedServerCopyReconcilesIntoOriginalPlaylistTrack() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CachedUploadReconciliation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("Local.m4a")
        let serverFile = root.appendingPathComponent("Server.m4a")
        let bytes = Data(repeating: 0x5a, count: 8_192)
        try bytes.write(to: localFile, options: .atomic)
        try bytes.write(to: serverFile, options: .atomic)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        let suiteName = "CachedUploadReconciliation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            serverCacheRoot: root,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        let local = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: localFile,
            metadata: .init(title: "Shared song", artist: "Artist", album: "Album", artworkURL: nil, sourceURL: "https://youtu.be/reconcile"),
            duration: 4,
            artworkData: nil,
            sourceSHA256: hash,
            contentSHA256: hash
        ))
        let playlist = try #require(model.createPlaylist(named: "Shared mix"))
        model.addTrack(local, to: playlist)
        let duplicate = Track(
            title: local.title,
            artist: local.artist,
            album: local.album,
            duration: local.duration,
            artwork: .electric,
            fileURL: serverFile,
            remoteID: "remote-song",
            sourceServer: "https://music.test/",
            syncProfileID: "default"
        )
        model.tracks.append(duplicate)
        model.favorites.insert(duplicate.id)

        #expect(await model.reconcileCachedUploadedLocalTracks())
        let reconciled = try #require(model.tracks.first(where: { $0.id == local.id }))
        #expect(reconciled.remoteID == "remote-song")
        #expect(reconciled.syncProfileID == "default")
        #expect(!model.tracks.contains(where: { $0.id == duplicate.id }))
        let reconciledPlaylist = try #require(model.playlists.first(where: { $0.id == playlist.id }))
        #expect(reconciledPlaylist.trackIDs == [local.id])
        #expect(reconciledPlaylist.remoteSongIDs == ["remote-song"])
        #expect(model.favorites.contains(local.id))
        #expect(!model.favorites.contains(duplicate.id))
    }

    @Test
    func optionalVideoUploadRegistersPreservedSourceLinkForActiveProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalVideoUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            LocalImportMockURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let localFile = root.appendingPathComponent("Local Upload.mp4")
        try Data(repeating: 0x44, count: 64).write(to: localFile, options: .atomic)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalImportMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        LocalImportMockURLProtocol.reset()
        LocalImportMockURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET", url.path == "/api/v1/profiles" {
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == nil)
                let data = Data(#"{"default_profile_id":"default","profiles":[{"id":"default","name":"Default","is_default":true,"song_count":0,"playlist_count":0,"liked_count":0},{"id":"profile-b","name":"Profile B","is_default":false,"song_count":0,"playlist_count":0,"liked_count":0}]}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
            if request.httpMethod == "PUT", url.path == "/api/v1/admin/songs" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
                #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")
                #expect(!(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key") ?? "").isEmpty)
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                let body = try localImportRequestBody(request)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                #expect(Set(object.keys) == ["schema_version", "source_url", "media_kind"])
                #expect(object["schema_version"] as? Int == 3)
                #expect(object["source_url"] as? String == "https://youtu.be/\(videoID)")
                #expect(object["media_kind"] as? String == "video")
                let data = Data(#"""
                {
                  "id":"uploaded-video",
                  "source_url":"https://media.example/local-video-upload.mp4",
                  "profile_id":"profile-b",
                  "download_url":"/api/v1/songs/uploaded-video/file",
                  "stream_url":"/api/v1/songs/uploaded-video/stream"
                }
                """#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!, data)
            }
            if request.httpMethod == "GET", url.path == "/api/v1/songs" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
                let data = Data(#"{"songs":[],"count":0}"#.utf8)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            throw URLError(.unsupportedURL)
        }

        let suiteName = "LocalVideoUpload.\(UUID().uuidString)"
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
        #expect(await model.selectSyncProfile(matching: "profile-b"))
        let track = model.insertLocalImportedAudio(LocalImportedAudio(
            fileURL: localFile,
            metadata: .init(title: "Local Video Upload", artist: "Device", album: "Only", artworkURL: nil, sourceURL: "https://youtu.be/\(videoID)"),
            duration: 1,
            artworkData: nil,
            downloadSourceURL: URL(string: "https://media.example/local-video-upload.mp4"),
            sourceSHA256: "video-upload-source-hash",
            contentSHA256: "video-upload-content-hash",
            mediaMode: .video
        ))

        #expect(track.kind == .video)
        try await model.uploadLocalImportToActiveProfile(track)
        #expect(model.remoteSongs.map(\.id) == ["uploaded-video"])
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
    @Test
    func artworkPolicySelectsTheLargestProviderImageWithoutLossyPreference() throws {
        let videoID = "jNQXAC9IVRw"
        let highest = "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"
        let selected = LocalImportArtworkPolicy.highestQualityYouTubeThumbnail([
            ["url": highest, "width": 1_280, "height": 720],
            ["url": "https://i.ytimg.com/vi/\(videoID)/default.jpg", "width": 120, "height": 90],
            ["url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg", "width": 480, "height": 360],
        ])
        #expect(selected == highest)
        #expect(LocalImportArtworkPolicy.preferredArtwork(
            metadataURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
            resolvedYouTubeURL: highest
        ) == highest)
        #expect(LocalImportArtworkPolicy.preferredArtwork(
            metadataURL: "https://i.scdn.co/image/album",
            resolvedYouTubeURL: highest
        ) == "https://i.scdn.co/image/album")
    }
