import Foundation
import XCTest
@testable import Resonance

final class MobileListeningHistoryTests: XCTestCase {
    private let origin = "https://music.example"
    private let profileID = "profile-a"
    private let accountID = "user-a"
    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(id: UUID, remoteID: String? = nil) -> MobileTrack {
        MobileTrack(
            id: id,
            title: "Song title",
            artist: "Song artist",
            album: "Album title",
            duration: 120,
            relativePath: "song.m4a",
            remoteID: remoteID,
            sourceServer: remoteID == nil ? nil : origin,
            syncProfileID: remoteID == nil ? nil : profileID,
            dateAdded: startedAt
        )
    }

    private func entry(
        id: UUID = UUID(),
        trackID: UUID = UUID(),
        accountID: String? = "user-a",
        remoteSongID: String? = nil,
        originatedOnThisDevice: Bool? = true
    ) -> MobileListeningHistoryEntry {
        MobileListeningHistoryEntry(
            id: id,
            trackID: trackID,
            startedAt: startedAt,
            listenedSeconds: 20,
            serverOrigin: origin,
            syncProfileID: profileID,
            accountID: accountID,
            remoteSongID: remoteSongID,
            title: "Song title",
            artist: "Song artist",
            album: "Album title",
            duration: 120,
            originatedOnThisDevice: originatedOnThisDevice
        )
    }

    func testUploadContractIncludesMetadataWithoutInstalledSongID() throws {
        let trackID = UUID()
        let upload = try XCTUnwrap(MobileListeningHistoryPolicy.uploadEntry(
            entry(trackID: trackID),
            track: track(id: trackID),
            origin: origin,
            profileID: profileID,
            accountID: accountID
        ))
        XCTAssertEqual(upload.trackID, trackID.uuidString.lowercased())
        XCTAssertNil(upload.songID)
        XCTAssertEqual(upload.title, "Song title")
        XCTAssertEqual(upload.artist, "Song artist")
        XCTAssertEqual(upload.album, "Album title")
        XCTAssertEqual(upload.durationSeconds, 120)
    }

    func testUploadRejectsAnotherSignedInAccount() {
        let trackID = UUID()
        XCTAssertNil(MobileListeningHistoryPolicy.uploadEntry(
            entry(trackID: trackID, accountID: "user-b"),
            track: track(id: trackID),
            origin: origin,
            profileID: profileID,
            accountID: accountID
        ))
    }

    func testMergeKeepsMetadataForAnUninstalledSong() throws {
        let eventID = UUID()
        let trackID = UUID()
        let document = MobileRemoteListeningHistoryDocument(
            profileID: profileID,
            entries: [MobileRemoteListeningHistoryEntry(
                id: eventID.uuidString,
                trackID: trackID.uuidString,
                songID: "server-song",
                startedAt: MobileListeningHistoryPolicy.timestamp(startedAt),
                listenedSeconds: 45,
                title: "Shared title",
                artist: "Shared artist",
                album: "Shared album",
                durationSeconds: 180,
                artworkURL: "https://music.example/api/v1/songs/server-song/artwork?token=signed"
            )]
        )

        let merged = MobileListeningHistoryPolicy.merge(
            document,
            into: [],
            tracks: [],
            origin: origin,
            profileID: profileID,
            accountID: accountID
        )
        let shared = try XCTUnwrap(merged.first)
        XCTAssertEqual(shared.title, "Shared title")
        XCTAssertEqual(shared.artist, "Shared artist")
        XCTAssertEqual(shared.album, "Shared album")
        XCTAssertEqual(shared.artworkURL, "https://music.example/api/v1/songs/server-song/artwork?token=signed")
        XCTAssertEqual(shared.remoteSongID, "server-song")
        XCTAssertFalse(shared.originatedOnThisDevice ?? true)
    }

    func testMergeHydratesAnUninstalledSongFromTheServerCatalog() throws {
        let eventID = UUID()
        let trackID = UUID()
        let catalog = try JSONDecoder().decode(MobileRemoteSong.self, from: Data(
            #"{"id":"server-song","filename":"server-song.m4a","title":"Catalog title","artist":"Catalog artist","album":"Catalog album","size":0,"modified_at":"now","content_type":"audio/mp4","duration_seconds":300,"download_url":"/api/v1/songs/server-song/file","stream_url":"/api/v1/songs/server-song/stream","artwork_url":"https://music.example/api/v1/songs/server-song/artwork?token=signed"}"#.utf8
        ))
        let document = MobileRemoteListeningHistoryDocument(
            profileID: profileID,
            entries: [MobileRemoteListeningHistoryEntry(
                id: eventID.uuidString,
                trackID: trackID.uuidString,
                songID: catalog.id,
                startedAt: MobileListeningHistoryPolicy.timestamp(startedAt),
                listenedSeconds: 45,
                title: nil,
                artist: nil,
                album: nil,
                durationSeconds: nil,
                artworkURL: nil
            )]
        )

        let merged = MobileListeningHistoryPolicy.merge(
            document,
            into: [],
            tracks: [],
            catalog: [catalog],
            origin: origin,
            profileID: profileID,
            accountID: accountID
        )
        let shared = try XCTUnwrap(merged.first)
        XCTAssertEqual(shared.title, "Catalog title")
        XCTAssertEqual(shared.artist, "Catalog artist")
        XCTAssertEqual(shared.album, "Catalog album")
        XCTAssertEqual(shared.duration, 300)
        XCTAssertEqual(shared.artworkURL, catalog.artworkURL?.absoluteString)
    }

    func testHistoryIsBoundedAndBatched() {
        let entries = (0...MobileListeningHistoryPolicy.maximumEntries).map { index in
            MobileListeningHistoryEntry(
                trackID: UUID(),
                startedAt: startedAt.addingTimeInterval(TimeInterval(index)),
                listenedSeconds: 1,
                duration: 1
            )
        }
        XCTAssertEqual(MobileListeningHistoryPolicy.bounded(entries).count, 2_000)
        XCTAssertEqual(MobileListeningHistoryPolicy.batches(Array(0..<1_201)).map(\.count), [500, 500, 201])
    }
}
