import XCTest
@testable import Resonance

final class MobileListenAlongTests: XCTestCase {
    func testArtworkPolicySelectsTheLargestProviderImage() {
        let videoID = "jNQXAC9IVRw"
        let highest = "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"
        XCTAssertEqual(
            LocalImportArtworkPolicy.highestQualityYouTubeThumbnail([
                ["url": highest, "width": 1_280, "height": 720],
                ["url": "https://i.ytimg.com/vi/\(videoID)/default.jpg", "width": 120, "height": 90],
                ["url": "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg", "width": 480, "height": 360],
            ]),
            highest
        )
        XCTAssertEqual(
            LocalImportArtworkPolicy.preferredArtwork(
                metadataURL: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
                resolvedYouTubeURL: highest
            ),
            highest
        )
        XCTAssertEqual(
            LocalImportArtworkPolicy.preferredArtwork(
                metadataURL: "https://i.scdn.co/image/album",
                resolvedYouTubeURL: highest
            ),
            "https://i.scdn.co/image/album"
        )
    }

    func testSnapshotUsesCoreSnakeCasePayload() throws {
        XCTAssertEqual(MobileListenAlongPollingPolicy.normalInterval, .milliseconds(250))
        XCTAssertEqual(MobileListenAlongPollingPolicy.maximumFailureInterval, 30)
        let snapshot = MobileListenAlongSnapshot(
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            mediaKind: "audio",
            positionSeconds: 12.5,
            isPlaying: true
        )
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["source_url"] as? String, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(object["media_kind"] as? String, "audio")
        XCTAssertEqual(object["position_seconds"] as? Double, 12.5)
        XCTAssertEqual(object["is_playing"] as? Bool, true)
    }

    func testHostUpdateUsesCoreFlatSnapshotPayload() throws {
        let request = MobileListenAlongUpdateRequest(
            revision: 4,
            snapshot: MobileListenAlongSnapshot(
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                mediaKind: "audio",
                positionSeconds: 37.5,
                isPlaying: true
            )
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["revision"] as? Int, 4)
        XCTAssertEqual(object["source_url"] as? String, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(object["media_kind"] as? String, "audio")
        XCTAssertEqual(object["position_seconds"] as? Double, 37.5)
        XCTAssertEqual(object["is_playing"] as? Bool, true)
        XCTAssertNil(object["snapshot"])

        let empty = MobileListenAlongUpdateRequest(
            revision: 5,
            snapshot: MobileListenAlongSnapshot(
                sourceURL: nil,
                mediaKind: "audio",
                positionSeconds: 0,
                isPlaying: false
            )
        )
        let emptyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(empty)) as? [String: Any]
        )
        XCTAssertTrue(emptyObject["source_url"] is NSNull)
    }

    func testResponseDecodesNestedSnapshotAndDates() throws {
        let data = Data(#"""
        {
          "schema_version": 1,
          "code": "ABCD-1234",
          "revision": 7,
          "snapshot": {
            "source_url": "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8",
            "media_kind": "audio",
            "position_seconds": 4.25,
            "is_playing": true
          },
          "updated_at": "2026-08-15T12:00:00.000Z",
          "expires_at": "2026-08-15T13:00:00Z",
          "server_time": "2026-08-15T12:00:01Z",
          "participant_count": 3,
          "role": "guest"
        }
        """#.utf8)

        let response = try JSONDecoder().decode(MobileListenAlongResponse.self, from: data)
        XCTAssertEqual(response.schemaVersion, 1)
        XCTAssertEqual(response.code, "ABCD-1234")
        XCTAssertEqual(response.revision, 7)
        XCTAssertEqual(response.snapshot.mediaKind, "audio")
        XCTAssertEqual(response.snapshot.positionSeconds, 4.25)
        XCTAssertTrue(response.snapshot.isPlaying)
        XCTAssertEqual(response.role, .guest)
        XCTAssertEqual(response.participantCount, 3)
        XCTAssertNotNil(response.serverTime)
    }

    func testResponseAcceptsFlatSnapshotForDevelopmentServers() throws {
        let data = Data(#"""
        {
          "code": "ABCD-1234",
          "revision": 2,
          "source_url": "https://youtu.be/dQw4w9WgXcQ",
          "media_kind": "audio",
          "position_seconds": 3,
          "is_playing": false
        }
        """#.utf8)

        let response = try JSONDecoder().decode(MobileListenAlongResponse.self, from: data)
        XCTAssertEqual(response.snapshot.sourceURL, "https://youtu.be/dQw4w9WgXcQ")
        XCTAssertEqual(response.snapshot.positionSeconds, 3)
        XCTAssertFalse(response.snapshot.isPlaying)
    }

    func testProjectedPositionUsesServerClockOnlyWhilePlaying() {
        let serverTime = Date(timeIntervalSince1970: 1_000)
        let room = MobileListenAlongRoom(
            code: "ABCD-1234",
            revision: 1,
            snapshot: MobileListenAlongSnapshot(
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                positionSeconds: 10,
                isPlaying: true
            ),
            updatedAt: serverTime.addingTimeInterval(-1),
            expiresAt: nil,
            serverTime: serverTime,
            role: .guest,
            participantCount: 2
        )

        XCTAssertEqual(room.projectedPosition(now: serverTime.addingTimeInterval(2)), 11, accuracy: 0.001)

        let paused = MobileListenAlongRoom(
            code: room.code,
            revision: room.revision,
            snapshot: MobileListenAlongSnapshot(
                sourceURL: room.snapshot.sourceURL,
                positionSeconds: 10,
                isPlaying: false
            ),
            updatedAt: room.updatedAt,
            expiresAt: room.expiresAt,
            serverTime: room.serverTime,
            role: .guest,
            participantCount: room.participantCount
        )
        XCTAssertEqual(paused.projectedPosition(now: serverTime.addingTimeInterval(2)), 10, accuracy: 0.001)
    }

    func testSourceIdentityCanonicalizesYouTubeAndSpotifyVariants() {
        XCTAssertEqual(
            MobileListenAlongSourcePolicy.identity("https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
            MobileListenAlongSourcePolicy.identity("https://youtu.be/dQw4w9WgXcQ")
        )
        XCTAssertEqual(
            MobileListenAlongSourcePolicy.identity("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8?si=tracking"),
            "spotify:4PTG3Z6ehGkBFwjybzWkR8"
        )
        XCTAssertNil(MobileListenAlongSourcePolicy.identity("https://user:secret@example.com/song"))
        XCTAssertNil(MobileListenAlongSourcePolicy.identity("https://r1---sn.googlevideo.com/videoplayback"))
    }

    func testUndownloadedCatalogSongsContinueToProviderResolution() {
        XCTAssertFalse(
            MobileListenAlongPlaybackPolicy.shouldUseServerStream(
                hasStoredBytes: false,
                isAudio: true,
                streamOnlyEnabled: true
            )
        )
        XCTAssertFalse(
            MobileListenAlongPlaybackPolicy.shouldUseServerStream(
                hasStoredBytes: true,
                isAudio: true,
                streamOnlyEnabled: false
            )
        )
        XCTAssertTrue(
            MobileListenAlongPlaybackPolicy.shouldUseServerStream(
                hasStoredBytes: true,
                isAudio: true,
                streamOnlyEnabled: true
            )
        )
    }

    func testYouTubeListenAlongUsesAnExplicitRangeLoader() throws {
        let source = try XCTUnwrap(URL(string: "https://r1---sn.example.googlevideo.com/videoplayback?id=public"))
        let asset = try MobileYouTubeStreamResourceLoader.assetURL(for: source)
        XCTAssertEqual(asset.scheme, "resonance-youtube")
        XCTAssertEqual(asset.host, source.host)
        XCTAssertThrowsError(
            try MobileYouTubeStreamResourceLoader.assetURL(
                for: XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
            )
        )
        XCTAssertThrowsError(
            try MobileYouTubeStreamResourceLoader(
                sourceURL: source,
                headers: ["Cookie": "must-not-leak"],
                contentLength: 100,
                contentType: "audio/mp4"
            )
        )
    }

    func testOnlyGuestsReplacePlaybackControlsWithParticipantIndicator() {
        XCTAssertTrue(MobileListenAlongPresentationPolicy.replacesPlaybackControls(for: .guest))
        XCTAssertFalse(MobileListenAlongPresentationPolicy.replacesPlaybackControls(for: .host))
        XCTAssertFalse(MobileListenAlongPresentationPolicy.replacesPlaybackControls(for: nil))
    }

    func testInviteCodeParsesResonanceListenAlongURL() {
        XCTAssertEqual(
            MobileListenAlongInvite.code(from: URL(string: "resonance://listen-along/abcd-1234")!),
            "ABCD-1234"
        )
        XCTAssertEqual(
            MobileListenAlongInvite.code(from: URL(string: "resonance:///listen-along/abcd-1234")!),
            "ABCD-1234"
        )
        XCTAssertNil(MobileListenAlongInvite.code(from: URL(string: "resonance://auth/callback?code=abc")!))
    }
}
