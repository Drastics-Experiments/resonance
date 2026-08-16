import CryptoKit
import Foundation
import XCTest
@testable import Resonance

final class MobileCrossfadePolicyTests: XCTestCase {
    func testCrossfadeRangeAndShortTrackLimit() {
        XCTAssertEqual(MobileCrossfadePolicy.normalizedSeconds(-2), 1)
        XCTAssertEqual(MobileCrossfadePolicy.normalizedSeconds(30), 12)
        XCTAssertEqual(
            MobileCrossfadePolicy.effectiveDuration(
                requestedSeconds: 12,
                currentDuration: 4,
                nextDuration: 20
            ),
            2
        )
        XCTAssertEqual(MobileCrossfadePolicy.progress(remaining: 2.5, duration: 5), 0.5)
    }

    func testMetadataRetryWindowUsesBoundedBackoff() {
        XCTAssertEqual(MobileRemoteMetadataRetryPolicy.maximumImmediateAttempts, 4)
        XCTAssertEqual(MobileRemoteMetadataRetryPolicy.delaySeconds(afterFailureCount: 1), 1)
        XCTAssertEqual(MobileRemoteMetadataRetryPolicy.delaySeconds(afterFailureCount: 2), 3)
        XCTAssertEqual(MobileRemoteMetadataRetryPolicy.delaySeconds(afterFailureCount: 99), 10)
    }
}

final class MobileNowPlayingPolicyTests: XCTestCase {
    private let track = MobileTrack(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        title: "Control Center Song",
        artist: "Resonance",
        album: "Now Playing",
        duration: 200,
        relativePath: "control-center.m4a"
    )

    func testSnapshotPublishesClipRelativeElapsedDurationAndRate() {
        let snapshot = MobileNowPlayingPolicy.snapshot(
            for: track,
            position: 25,
            bounds: .init(start: 10, end: 70),
            playbackRate: 1.25,
            isPlaying: true,
            allowsTrackNavigation: true
        )

        XCTAssertEqual(snapshot.identifier, track.id.uuidString)
        XCTAssertEqual(snapshot.title, track.title)
        XCTAssertEqual(snapshot.artist, track.artist)
        XCTAssertEqual(snapshot.album, track.album)
        XCTAssertEqual(snapshot.duration, 60)
        XCTAssertEqual(snapshot.elapsed, 15)
        XCTAssertEqual(snapshot.playbackRate, 1.25)
        XCTAssertEqual(snapshot.defaultPlaybackRate, 1.25)
        XCTAssertTrue(snapshot.allowsTrackNavigation)
    }

    func testSnapshotClampsElapsedAndPublishesZeroRateWhenPaused() {
        let snapshot = MobileNowPlayingPolicy.snapshot(
            for: track,
            position: 500,
            bounds: .init(start: 10, end: 70),
            playbackRate: .nan,
            isPlaying: false,
            allowsTrackNavigation: false
        )

        XCTAssertEqual(snapshot.elapsed, 60)
        XCTAssertEqual(snapshot.playbackRate, 0)
        XCTAssertEqual(snapshot.defaultPlaybackRate, 1)
        XCTAssertFalse(snapshot.allowsTrackNavigation)
    }

    func testControlCenterPositionMapsToClipRelativeSeekFraction() {
        let bounds = MobileClipPlaybackPolicy.Bounds(start: 10, end: 70)
        XCTAssertEqual(MobileNowPlayingPolicy.seekFraction(elapsedTime: -10, bounds: bounds), 0)
        XCTAssertEqual(MobileNowPlayingPolicy.seekFraction(elapsedTime: 30, bounds: bounds), 0.5)
        XCTAssertEqual(MobileNowPlayingPolicy.seekFraction(elapsedTime: 90, bounds: bounds), 1)
        XCTAssertEqual(MobileNowPlayingPolicy.seekFraction(elapsedTime: .nan, bounds: bounds), 0)
    }
}

final class MobileCatalogRefreshFailurePolicyTests: XCTestCase {
    func testRefreshFailurePreservesAnExistingConnectionOrCatalog() {
        XCTAssertTrue(MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
            wasConnected: true,
            hadCatalog: false,
            wasCancelled: false,
            isAuthenticationFailure: false
        ))
        XCTAssertTrue(MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
            wasConnected: false,
            hadCatalog: true,
            wasCancelled: false,
            isAuthenticationFailure: false
        ))
    }

    func testCancelledNativeRefreshNeverTearsDownConnectionState() {
        XCTAssertTrue(MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
            wasConnected: false,
            hadCatalog: false,
            wasCancelled: true,
            isAuthenticationFailure: false
        ))
        XCTAssertFalse(MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
            wasConnected: false,
            hadCatalog: false,
            wasCancelled: false,
            isAuthenticationFailure: false
        ))
    }

    func testAuthenticationFailureAlwaysRequiresARealReconnect() {
        XCTAssertFalse(MobileCatalogRefreshFailurePolicy.preservesLastKnownCatalog(
            wasConnected: true,
            hadCatalog: true,
            wasCancelled: false,
            isAuthenticationFailure: true
        ))
    }
}

final class MobileFullCatalogAuthorityPolicyTests: XCTestCase {
    private let context = MobileServerContext(
        origin: "https://music.example:443",
        profileID: "listener"
    )

    func testUploadOnlyPartialCatalogNeverBecomesAuthority() {
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.completedFetch(
            context: context,
            requestGeneration: 7,
            currentRequestGeneration: 7,
            credentialIsCurrent: true,
            catalogMutationGenerationUnchanged: false,
            hasPendingCatalogMerges: true,
            songIDs: ["catalog-song"]
        ))
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.completedFetch(
            context: context,
            requestGeneration: 7,
            currentRequestGeneration: 7,
            credentialIsCurrent: true,
            catalogMutationGenerationUnchanged: true,
            hasPendingCatalogMerges: true,
            songIDs: ["catalog-song", "upload-response-only-song"]
        ))
    }

    func testSuccessfulCurrentFullCatalogBecomesExactContextAuthority() throws {
        let snapshot = try XCTUnwrap(MobileFullCatalogAuthorityPolicy.completedFetch(
            context: context,
            requestGeneration: 8,
            currentRequestGeneration: 8,
            credentialIsCurrent: true,
            catalogMutationGenerationUnchanged: true,
            hasPendingCatalogMerges: false,
            songIDs: ["catalog-a", "catalog-b"]
        ))

        XCTAssertEqual(
            MobileFullCatalogAuthorityPolicy.songIDsIfCurrent(
                snapshot,
                context: context,
                requestGeneration: 8
            ),
            Set(["catalog-a", "catalog-b"])
        )
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.songIDsIfCurrent(
            snapshot,
            context: MobileServerContext(
                origin: context.origin,
                profileID: "other-profile"
            ),
            requestGeneration: 8
        ))
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.songIDsIfCurrent(
            snapshot,
            context: context,
            requestGeneration: 9
        ))
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.completedFetch(
            context: context,
            requestGeneration: 8,
            currentRequestGeneration: 8,
            credentialIsCurrent: false,
            catalogMutationGenerationUnchanged: true,
            hasPendingCatalogMerges: false,
            songIDs: ["catalog-a", "catalog-b"]
        ))
        XCTAssertNil(MobileFullCatalogAuthorityPolicy.completedFetch(
            context: context,
            requestGeneration: 8,
            currentRequestGeneration: 9,
            credentialIsCurrent: true,
            catalogMutationGenerationUnchanged: true,
            hasPendingCatalogMerges: false,
            songIDs: ["catalog-a", "catalog-b"]
        ))
    }
}

final class MobilePlaylistPresentationMovePolicyTests: XCTestCase {
    func testUnavailableRemoteEntryMovesWithoutCorruptingPersistedOrders() {
        let localTrack = MobileTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Local",
            duration: 120,
            relativePath: "Local.m4a"
        )
        let downloadedTrack = MobileTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Downloaded",
            duration: 180,
            relativePath: "Downloaded.m4a",
            remoteID: "remote-downloaded"
        )
        let entries = [
            MobilePlaylistPresentationEntry(
                id: .local(localTrack.id),
                track: localTrack,
                remoteSongID: nil,
                remoteSong: nil
            ),
            MobilePlaylistPresentationEntry(
                id: .remote("remote-downloaded"),
                track: downloadedTrack,
                remoteSongID: "remote-downloaded",
                remoteSong: nil
            ),
            MobilePlaylistPresentationEntry(
                id: .remote("remote-unavailable"),
                track: nil,
                remoteSongID: "remote-unavailable",
                remoteSong: nil
            ),
        ]

        let reordered = MobilePlaylistPresentationMovePolicy.move(
            entries,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0
        )
        XCTAssertEqual(
            reordered.map(\.id),
            [.remote("remote-unavailable"), .local(localTrack.id), .remote("remote-downloaded")]
        )

        let persisted = MobilePlaylistPresentationMovePolicy.persistedOrder(for: reordered)
        XCTAssertEqual(persisted.trackIDs, [localTrack.id, downloadedTrack.id])
        XCTAssertEqual(persisted.remoteSongIDs, ["remote-unavailable", "remote-downloaded"])
        XCTAssertEqual(
            persisted.entryOrder,
            [
                "remote:remote-unavailable",
                "local:\(localTrack.id.uuidString.lowercased())",
                "remote:remote-downloaded",
            ]
        )

        let roundTrippedPlaylist = MobilePlaylist(
            name: "Mixed",
            trackIDs: persisted.trackIDs,
            remoteSongIDs: persisted.remoteSongIDs,
            entryOrder: ["remote:stale"] + persisted.entryOrder
        )
        XCTAssertEqual(
            MobilePlaylistPresentationPolicy.entries(
                in: roundTrippedPlaylist,
                tracks: [localTrack, downloadedTrack],
                remoteSongs: []
            ).map(\.id),
            reordered.map(\.id)
        )
    }

    func testPlaylistEntryOrderCodableRemainsBackwardCompatible() throws {
        let playlist = MobilePlaylist(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Ordered",
            entryOrder: ["remote:a", "local:00000000-0000-0000-0000-000000000001"]
        )
        let encoded = try JSONEncoder().encode(playlist)
        XCTAssertEqual(try JSONDecoder().decode(MobilePlaylist.self, from: encoded).entryOrder, playlist.entryOrder)

        let legacy = Data(#"{"id":"00000000-0000-0000-0000-000000000003","name":"Legacy","trackIDs":[],"isSystem":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MobilePlaylist.self, from: legacy).entryOrder)
    }
}

final class MobileLocalTrackRemovalPlaylistPolicyTests: XCTestCase {
    private let remoteTrack = MobileTrack(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        title: "Downloaded A",
        duration: 120,
        relativePath: "A.m4a",
        remoteID: "remote-a"
    )
    private let localTrack = MobileTrack(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
        title: "Local",
        duration: 120,
        relativePath: "Local.m4a"
    )
    private let secondRemoteTrack = MobileTrack(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
        title: "Downloaded B",
        duration: 120,
        relativePath: "B.m4a",
        remoteID: "remote-b"
    )

    func testRemovingDownloadPreservesRemoteMembershipAndExactPresentationSlot() {
        let playlist = MobilePlaylist(
            name: "Mixed",
            trackIDs: [remoteTrack.id, localTrack.id, secondRemoteTrack.id],
            remoteSongIDs: ["remote-a", "remote-b"],
            entryOrder: [
                "remote:remote-b",
                "local:\(localTrack.id.uuidString.lowercased())",
                "remote:remote-a",
            ]
        )
        let before = MobilePlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: [remoteTrack, localTrack, secondRemoteTrack],
            remoteSongs: []
        )

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .confirmedPresent,
            from: playlist,
            presentationOrder: before.map(\.id)
        )

        XCTAssertEqual(result.playlist.trackIDs, [localTrack.id, secondRemoteTrack.id])
        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-a", "remote-b"])
        XCTAssertEqual(result.playlist.entryOrder, playlist.entryOrder)
        XCTAssertFalse(result.remoteMembershipChanged)

        let after = MobilePlaylistPresentationPolicy.entries(
            in: result.playlist,
            tracks: [localTrack, secondRemoteTrack],
            remoteSongs: []
        )
        XCTAssertEqual(after.map(\.id), before.map(\.id))
        XCTAssertNil(after.last?.track)
    }

    func testRemovingDownloadDropsMembershipOnlyWhenRemoteSongIsMissing() {
        let playlist = MobilePlaylist(
            name: "Server Playlist",
            trackIDs: [remoteTrack.id, secondRemoteTrack.id],
            remoteSongIDs: ["remote-a", "remote-b"],
            entryOrder: ["remote:remote-a", "remote:remote-b"]
        )
        let before = MobilePlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: [remoteTrack, secondRemoteTrack],
            remoteSongs: []
        )

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .confirmedAbsent,
            from: playlist,
            presentationOrder: before.map(\.id)
        )

        XCTAssertEqual(result.playlist.trackIDs, [secondRemoteTrack.id])
        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-b"])
        XCTAssertEqual(result.playlist.entryOrder, ["remote:remote-b"])
        XCTAssertTrue(result.remoteMembershipChanged)
    }

    func testLegacyLocalEntryBecomesRemotePlaceholderWithoutMoving() {
        let playlist = MobilePlaylist(
            name: "Legacy Mixed",
            trackIDs: [remoteTrack.id, localTrack.id],
            remoteSongIDs: []
        )
        let before = MobilePlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: [remoteTrack, localTrack],
            remoteSongs: []
        )
        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .confirmedPresent,
            from: playlist,
            presentationOrder: before.map(\.id)
        )

        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-a"])
        XCTAssertEqual(result.playlist.entryOrder, [
            "remote:remote-a",
            "local:\(localTrack.id.uuidString.lowercased())",
        ])
        XCTAssertEqual(
            MobilePlaylistPresentationPolicy.entries(
                in: result.playlist,
                tracks: [localTrack],
                remoteSongs: []
            ).map(\.id),
            [.remote("remote-a"), .local(localTrack.id)]
        )
    }

    func testRawLegacyLocalSlotWinsWhenCanonicalMembershipAlreadyExists() {
        let legacyLocalKey = "local:\(remoteTrack.id.uuidString.lowercased())"
        let playlist = MobilePlaylist(
            name: "Raw legacy order",
            trackIDs: [remoteTrack.id, localTrack.id, secondRemoteTrack.id],
            remoteSongIDs: ["remote-a", "remote-b"],
            entryOrder: [
                "remote:remote-a",
                "local:\(localTrack.id.uuidString.lowercased())",
                legacyLocalKey,
                "remote:remote-b",
            ]
        )
        let presentation = MobilePlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: [remoteTrack, localTrack, secondRemoteTrack],
            remoteSongs: []
        )
        XCTAssertFalse(presentation.map(\.id).contains(.local(remoteTrack.id)))

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .confirmedPresent,
            from: playlist,
            presentationOrder: presentation.map(\.id)
        )

        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-a", "remote-b"])
        XCTAssertEqual(result.playlist.entryOrder, [
            "local:\(localTrack.id.uuidString.lowercased())",
            "remote:remote-a",
            "remote:remote-b",
        ])
        XCTAssertFalse(result.remoteMembershipChanged)
    }

    func testUnprovenBackingPreservesExistingCanonicalTokenInPlace() {
        let playlist = MobilePlaylist(
            name: "Offline canonical order",
            trackIDs: [remoteTrack.id, localTrack.id],
            remoteSongIDs: ["remote-a"],
            entryOrder: [
                "remote:remote-a",
                "local:\(remoteTrack.id.uuidString.lowercased())",
                "local:\(localTrack.id.uuidString.lowercased())",
            ]
        )

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .unproven,
            from: playlist,
            presentationOrder: []
        )

        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-a"])
        XCTAssertEqual(result.playlist.entryOrder, [
            "remote:remote-a",
            "local:\(localTrack.id.uuidString.lowercased())",
        ])
        XCTAssertFalse(result.remoteMembershipChanged)
    }

    func testOfflineLocalOnlyMembershipNeverSynthesizesRemoteMembership() {
        let playlist = MobilePlaylist(
            name: "Offline legacy",
            trackIDs: [remoteTrack.id, localTrack.id],
            remoteSongIDs: [],
            entryOrder: [
                "local:\(remoteTrack.id.uuidString.lowercased())",
                "local:\(localTrack.id.uuidString.lowercased())",
            ]
        )

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: remoteTrack.id,
            remoteSongID: "remote-a",
            remoteBackingAuthority: .unproven,
            from: playlist,
            presentationOrder: []
        )

        XCTAssertEqual(result.playlist.remoteSongIDs, [])
        XCTAssertEqual(result.playlist.entryOrder, [
            "local:\(localTrack.id.uuidString.lowercased())",
        ])
        XCTAssertFalse(result.remoteMembershipChanged)
    }

    func testForeignContextDeletionCannotRemoveSameIDActiveMembership() {
        let foreignTrack = MobileTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            title: "Foreign A",
            duration: 120,
            relativePath: "Foreign.m4a",
            remoteID: "remote-a",
            sourceServer: "https://foreign.example",
            syncProfileID: "foreign"
        )
        let playlist = MobilePlaylist(
            name: "Context scoped",
            trackIDs: [foreignTrack.id, localTrack.id],
            remoteSongIDs: ["remote-a"],
            entryOrder: [
                "remote:remote-a",
                "local:\(foreignTrack.id.uuidString.lowercased())",
                "local:\(localTrack.id.uuidString.lowercased())",
            ]
        )
        let backing = MobileLocalTrackRemovalAuthorityPolicy.resolve(
            track: foreignTrack,
            activeContext: MobileServerContext(
                origin: "https://active.example",
                profileID: "active"
            ),
            catalogIsAuthoritative: true,
            catalogRemoteSongIDs: ["remote-a"]
        )
        XCTAssertNil(backing.remoteSongID)
        XCTAssertEqual(backing.authority, .unproven)

        let result = MobileLocalTrackRemovalPlaylistPolicy.removing(
            trackID: foreignTrack.id,
            remoteSongID: backing.remoteSongID,
            remoteBackingAuthority: backing.authority,
            from: playlist,
            presentationOrder: []
        )

        XCTAssertEqual(result.playlist.remoteSongIDs, ["remote-a"])
        XCTAssertEqual(result.playlist.entryOrder, [
            "remote:remote-a",
            "local:\(localTrack.id.uuidString.lowercased())",
        ])
        XCTAssertFalse(result.remoteMembershipChanged)
    }

    func testExactContextNeedsAuthoritativeCatalogToConfirmBacking() {
        let activeTrack = MobileTrack(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000015")!,
            title: "Active A",
            duration: 120,
            relativePath: "Active.m4a",
            remoteID: "remote-a",
            sourceServer: "https://active.example",
            syncProfileID: "active"
        )
        let activeContext = MobileServerContext(
            origin: "https://active.example:443",
            profileID: "active"
        )

        XCTAssertEqual(
            MobileLocalTrackRemovalAuthorityPolicy.resolve(
                track: activeTrack,
                activeContext: activeContext,
                catalogIsAuthoritative: false,
                catalogRemoteSongIDs: ["remote-a"]
            ),
            MobileLocalTrackRemovalRemoteBacking(
                remoteSongID: "remote-a",
                authority: .unproven
            )
        )
        XCTAssertEqual(
            MobileLocalTrackRemovalAuthorityPolicy.resolve(
                track: activeTrack,
                activeContext: activeContext,
                catalogIsAuthoritative: true,
                catalogRemoteSongIDs: ["remote-a"]
            ),
            MobileLocalTrackRemovalRemoteBacking(
                remoteSongID: "remote-a",
                authority: .confirmedPresent
            )
        )
        XCTAssertEqual(
            MobileLocalTrackRemovalAuthorityPolicy.resolve(
                track: activeTrack,
                activeContext: activeContext,
                catalogIsAuthoritative: true,
                catalogRemoteSongIDs: []
            ),
            MobileLocalTrackRemovalRemoteBacking(
                remoteSongID: "remote-a",
                authority: .confirmedAbsent
            )
        )
    }
}

final class MobileTransferDisplayPolicyTests: XCTestCase {
    func testSubOnePercentProgressNeverDisplaysAsZero() {
        XCTAssertEqual(MobileTransferDisplayPolicy.percentageLabel(0.001), "<1%")
        XCTAssertEqual(MobileTransferDisplayPolicy.percentageLabel(0.42), "42%")
    }

    func testDownloadCardCannotAppearBeforeTheFirstMediaByte() {
        XCTAssertFalse(MobileDownloadTransferPresentationPolicy.shouldPresent(
            completedBytes: 0,
            fallbackProgress: nil
        ))
        XCTAssertFalse(MobileDownloadTransferPresentationPolicy.shouldPresent(
            completedBytes: 0,
            fallbackProgress: 1,
            hasReceivedBytes: false
        ), "A setup/completion signal must not manufacture a popup when no media byte was observed")
        XCTAssertTrue(MobileDownloadTransferPresentationPolicy.shouldPresent(
            completedBytes: 1,
            fallbackProgress: nil
        ))
        XCTAssertTrue(MobileDownloadTransferPresentationPolicy.shouldPresent(
            completedBytes: 0,
            fallbackProgress: 1,
            hasReceivedBytes: true
        ))
        XCTAssertFalse(MobileDownloadTransferPresentationPolicy.shouldEndBytePresentation(
            for: .downloading
        ))
        XCTAssertTrue(MobileDownloadTransferPresentationPolicy.shouldEndBytePresentation(
            for: .processing
        ), "Local validation ends the current item's byte operation")
        XCTAssertTrue(MobileDownloadTransferPresentationPolicy.shouldPreserveBetweenItems(
            currentItem: 1,
            totalItems: 2
        ))
        XCTAssertFalse(MobileDownloadTransferPresentationPolicy.shouldPreserveBetweenItems(
            currentItem: 2,
            totalItems: 2
        ))
    }

    func testLoadedCatalogSnapshotPlansUnhydratedSongsWithoutARefresh() throws {
        let first = try decodedRemoteSong(id: "one", title: "Already loaded one")
        let second = try decodedRemoteSong(id: "two", title: "Already loaded two")
        let unresolved = try decodedRemoteSong(
            id: "three",
            title: nil,
            artist: nil
        )
        let planned = MobileLoadedCatalogDownloadPolicy.pendingSongs(
            from: [first, second, unresolved],
            requestedSongIDs: ["one", "two", "three"],
            syncedSongIDs: ["two"]
        )

        XCTAssertEqual(planned.map(\.id), ["one", "three"])
        XCTAssertEqual(planned.first?.title, "Already loaded one")
        XCTAssertTrue(planned.last?.isMetadataLoading == true)
    }

    func testCurrentSongBytesAndBatchPositionAreIndependent() {
        let state = MobileTransferDisplayState(
            kind: .download,
            itemID: "catalog-song-id",
            songTitle: "Catalog Song Title",
            detail: "Downloading song",
            currentItem: 3,
            totalItems: 10,
            completedBytes: 25,
            totalBytes: 100,
            fallbackProgress: nil
        )

        XCTAssertEqual(state.songTitle, "Catalog Song Title")
        XCTAssertEqual(state.displayTitle, "Downloading")
        XCTAssertEqual(state.batchPosition, "3/10")
        XCTAssertEqual(state.progress, 0.25)

        let preparing = MobileTransferDisplayState(
            kind: .download,
            itemID: "catalog-song-id",
            songTitle: "Loading song metadata",
            detail: "Preparing download",
            currentItem: 1,
            totalItems: 10,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        )
        XCTAssertEqual(preparing.displayTitle, "Preparing download")
        XCTAssertNil(preparing.progress)
    }

    func testNoPendingTransfersUsesZeroBatchPosition() {
        let state = MobileTransferDisplayState(
            kind: .download,
            itemID: "cached-song-id",
            songTitle: "Cached Song",
            detail: "All requested songs are already on this device",
            currentItem: 0,
            totalItems: 0,
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: 1
        )

        XCTAssertEqual(state.batchPosition, "0/0")
        XCTAssertEqual(state.progress, 1)
    }

    func testProgressClampsAndStaysIndeterminateWithoutByteOrFallbackTotal() {
        XCTAssertNil(MobileTransferDisplayPolicy.progress(
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: nil
        ))
        XCTAssertNil(MobileTransferDisplayPolicy.progress(
            completedBytes: 0,
            totalBytes: 100,
            fallbackProgress: nil
        ), "A catalog or response size must not render as a stalled zero-percent download")
        XCTAssertEqual(MobileTransferDisplayPolicy.progress(
            completedBytes: 500,
            totalBytes: 100,
            fallbackProgress: nil
        ), 1)
        XCTAssertEqual(MobileTransferDisplayPolicy.progress(
            completedBytes: 0,
            totalBytes: 0,
            fallbackProgress: -1
        ), 0)
    }

    func testLoadedCatalogMetadataIsReusedForSavedLinkDownloads() {
        XCTAssertTrue(MobileRemoteSourceMetadataReusePolicy.canReuseCatalogMetadata(
            isMetadataLoading: false,
            title: "Catalog Title",
            artist: "Catalog Artist"
        ))
        XCTAssertFalse(MobileRemoteSourceMetadataReusePolicy.canReuseCatalogMetadata(
            isMetadataLoading: true,
            title: "Resolving metadata…",
            artist: "On-device lookup"
        ))
        XCTAssertFalse(MobileRemoteSourceMetadataReusePolicy.canReuseCatalogMetadata(
            isMetadataLoading: false,
            title: " ",
            artist: "Catalog Artist"
        ))
        XCTAssertFalse(MobileRemoteSourceMetadataReusePolicy.canReuseCatalogMetadata(
            isMetadataLoading: false,
            title: String(repeating: "x", count: 513),
            artist: "Catalog Artist"
        ))
    }

    func testUnhydratedSpotifyCannotFabricateSearchMetadata() throws {
        let spotify = try decodedRemoteSong(
            id: "spotify-row",
            title: nil,
            artist: nil,
            sourceURL: "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"
        )
        let youtube = try decodedRemoteSong(
            id: "youtube-row",
            title: nil,
            artist: nil,
            sourceURL: "https://www.youtube.com/watch?v=abcdefghijk"
        )
        let unsupported = try decodedRemoteSong(
            id: "unsupported-row",
            title: nil,
            artist: nil,
            sourceURL: "https://example.com/audio"
        )

        XCTAssertNil(MobileRemoteSourceMetadataReusePolicy.acquisitionTrack(for: spotify))
        XCTAssertNotNil(MobileRemoteSourceMetadataReusePolicy.acquisitionTrack(for: youtube))
        XCTAssertNil(MobileRemoteSourceMetadataReusePolicy.acquisitionTrack(for: unsupported))
    }

    func testPendingRemoteMetadataCannotBlockBatchAdvanceOrFinalization() throws {
        let unresolved = try decodedRemoteSong(
            id: "pending-row",
            title: nil,
            artist: nil
        )
        let finalized = MobileSourceImportFinalMetadataPolicy.resolve(
            localTitle: "Provider title",
            localArtist: "Provider artist",
            localAlbum: "Provider album",
            localDuration: 187,
            currentRemoteSong: unresolved
        )

        XCTAssertEqual(finalized.title, "Provider title")
        XCTAssertEqual(finalized.artist, "Provider artist")
        XCTAssertEqual(finalized.album, "Provider album")
        XCTAssertEqual(finalized.duration, 187)

        let titleOnlyCatalogRow = try decodedRemoteSong(
            id: "title-only-row",
            title: "Catalog title",
            artist: "Catalog artist"
        )
        let titleOnlyFinalized = MobileSourceImportFinalMetadataPolicy.resolve(
            localTitle: "Provider title",
            localArtist: "Provider artist",
            localAlbum: "Provider album",
            localDuration: 187,
            currentRemoteSong: titleOnlyCatalogRow
        )
        XCTAssertEqual(titleOnlyFinalized.title, "Catalog title")
        XCTAssertEqual(titleOnlyFinalized.artist, "Catalog artist")
        XCTAssertEqual(titleOnlyFinalized.album, "Provider album")
    }

    private func decodedRemoteSong(
        id: String,
        title: String?,
        artist: String? = "Catalog Artist",
        sourceURL: String = "https://www.youtube.com/watch?v=abcdefghijk"
    ) throws -> MobileRemoteSong {
        var object: [String: Any] = [
            "id": id,
            "filename": "\(id).m4a",
            "source_url": sourceURL,
            "media_kind": "audio",
            "download_url": "/api/v1/songs/\(id)/file",
            "stream_url": "/api/v1/songs/\(id)/stream",
        ]
        if let title { object["title"] = title }
        if let artist { object["artist"] = artist }
        return try JSONDecoder().decode(
            MobileRemoteSong.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    func testSourceResolutionKeysAreScopedToCanonicalServerProfileAndAccount() throws {
        let source = "https://www.youtube.com/watch?v=abcdefghijk"
        let context = MobileServerContext(
            origin: "https://Music.Example/library",
            profileID: "profile-a"
        )
        let key = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: context,
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))
        let sameCanonicalContext = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: MobileServerContext(
                origin: "https://music.example:443/other-path",
                profileID: "profile-a"
            ),
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))

        let otherProfileKey = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: MobileServerContext(origin: context.origin, profileID: "profile-b"),
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))
        let otherAccountKey = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: context,
            accountScope: "account-b",
            mediaKind: "audio",
            sourceURL: source
        ))
        let otherServerKey = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: MobileServerContext(origin: "https://other.example", profileID: "profile-a"),
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))
        let videoKey = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: context,
            accountScope: "account-a",
            mediaKind: "video",
            sourceURL: source
        ))

        XCTAssertEqual(key, sameCanonicalContext)
        XCTAssertNotEqual(key, otherProfileKey)
        XCTAssertNotEqual(key, otherAccountKey)
        XCTAssertNotEqual(key, otherServerKey)
        XCTAssertNotEqual(key, videoKey)
        XCTAssertNil(MobileRemoteSourceResolutionCachePolicy.key(
            context: context,
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: "https://user:secret@www.youtube.com/watch?v=abcdefghijk"
        ))
    }

    func testCorrectedCatalogMetadataInvalidatesSameSourceResolution() throws {
        let source = "https://www.youtube.com/watch?v=abcdefghijk"
        let context = MobileServerContext(origin: "https://music.example", profileID: "profile-a")
        let key = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: context,
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))
        let metadata = LocalImportSpotifyTrack(
            provider: "server",
            type: "track",
            trackID: "server-song",
            title: "Original title",
            artist: "Artist",
            album: nil,
            trackNumber: nil,
            durationSeconds: nil,
            artworkURL: nil,
            embedURL: "",
            sourceURL: source
        )
        let resolution = LocalImportResolution(
            kind: .youtube,
            track: metadata,
            candidates: [LocalImportAudioSourceMatch(
                videoID: "abcdefghijk",
                title: metadata.title,
                artist: metadata.artist,
                album: nil,
                durationSeconds: nil,
                thumbnailURL: nil,
                sourceProvider: .youtube,
                officialArtist: false,
                sourceURL: source,
                score: 1,
                confidence: "catalog",
                match: .init(
                    title: 1,
                    artist: 1,
                    album: nil,
                    duration: nil,
                    durationDeltaSeconds: nil
                )
            )]
        )

        XCTAssertTrue(MobileRemoteSourceResolutionCachePolicy.canReuse(
            resolution,
            cachedKey: key,
            expectedKey: key,
            knownCatalogMetadata: metadata
        ))
        let corrected = LocalImportSpotifyTrack(
            provider: metadata.provider,
            type: metadata.type,
            trackID: metadata.trackID,
            title: "Corrected title",
            artist: metadata.artist,
            album: metadata.album,
            trackNumber: metadata.trackNumber,
            durationSeconds: metadata.durationSeconds,
            artworkURL: metadata.artworkURL,
            embedURL: metadata.embedURL,
            sourceURL: metadata.sourceURL
        )
        XCTAssertFalse(MobileRemoteSourceResolutionCachePolicy.canReuse(
            resolution,
            cachedKey: key,
            expectedKey: key,
            knownCatalogMetadata: corrected
        ))
        let otherProfileKey = try XCTUnwrap(MobileRemoteSourceResolutionCachePolicy.key(
            context: MobileServerContext(origin: context.origin, profileID: "profile-b"),
            accountScope: "account-a",
            mediaKind: "audio",
            sourceURL: source
        ))
        XCTAssertFalse(MobileRemoteSourceResolutionCachePolicy.canReuse(
            resolution,
            cachedKey: key,
            expectedKey: otherProfileKey,
            knownCatalogMetadata: metadata
        ))
    }

    func testFirstReceivedBytesPublishProgressImmediatelyThenThrottle() {
        XCTAssertTrue(MobileTransferByteProgressPolicy.shouldReport(
            completedBytes: 16 * 1_024,
            lastReportedBytes: 0,
            totalBytes: 1_024 * 1_024
        ))
        XCTAssertFalse(MobileTransferByteProgressPolicy.shouldReport(
            completedBytes: 32 * 1_024,
            lastReportedBytes: 16 * 1_024,
            totalBytes: 1_024 * 1_024
        ))
        XCTAssertTrue(MobileTransferByteProgressPolicy.shouldReport(
            completedBytes: 272 * 1_024,
            lastReportedBytes: 16 * 1_024,
            totalBytes: 1_024 * 1_024
        ))
    }

    func testRangeProgressIsAbsoluteAndClampedAcrossChunks() {
        XCTAssertEqual(LocalImportRangeProgressPolicy.absoluteCompleted(
            completedBeforeRange: 10 * 1_024 * 1_024,
            receivedInRange: 256 * 1_024,
            total: 25 * 1_024 * 1_024
        ), 10 * 1_024 * 1_024 + 256 * 1_024)
        XCTAssertEqual(LocalImportRangeProgressPolicy.absoluteCompleted(
            completedBeforeRange: 24 * 1_024 * 1_024,
            receivedInRange: 2 * 1_024 * 1_024,
            total: 25 * 1_024 * 1_024
        ), 25 * 1_024 * 1_024)
        XCTAssertEqual(LocalImportRangeProgressPolicy.absoluteCompleted(
            completedBeforeRange: Int64.max,
            receivedInRange: Int64.max,
            total: 100
        ), 100)
    }

    func testYouTubeDownloadPreparationBuildsFromCatalogMetadata() async throws {
        let source = "https://www.youtube.com/watch?v=abcdefghijk"
        let metadata = LocalImportSpotifyTrack(
            provider: "server",
            type: "track",
            trackID: "server-song",
            title: "Already Loaded Title",
            artist: "Already Loaded Artist",
            album: "Already Loaded Album",
            trackNumber: nil,
            durationSeconds: 181,
            artworkURL: nil,
            embedURL: "",
            sourceURL: source
        )
        let service = LocalDeviceImportService(
            localRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        let resolution = try await service.resolveUsingCatalogMetadata(
            source: source,
            metadata: metadata
        ) { _ in }

        XCTAssertEqual(resolution.track.title, metadata.title)
        XCTAssertEqual(resolution.track.artist, metadata.artist)
        XCTAssertEqual(resolution.candidates.count, 1)
        XCTAssertEqual(resolution.candidates.first?.videoID, "abcdefghijk")
        XCTAssertEqual(resolution.candidates.first?.sourceURL, source)
    }

    func testOnlyActiveTransferSessionCanPublishOrClearTheOverlay() {
        let staleSessionID = UUID()
        let activeSessionID = UUID()

        XCTAssertFalse(MobileTransferSessionPolicy.accepts(
            staleSessionID,
            activeSessionID: activeSessionID
        ))
        XCTAssertTrue(MobileTransferSessionPolicy.accepts(
            activeSessionID,
            activeSessionID: activeSessionID
        ))
        XCTAssertFalse(MobileTransferSessionPolicy.accepts(
            activeSessionID,
            activeSessionID: nil
        ))
    }

    func testActiveTransferOwnerBlocksEveryOtherProducer() {
        let activeSessionID = UUID()

        XCTAssertTrue(MobileTransferSessionPolicy.canBegin(activeSessionID: nil))
        XCTAssertFalse(MobileTransferSessionPolicy.canBegin(
            activeSessionID: activeSessionID
        ))
    }

    func testCancelledDownloadCallbackCannotUpdateSameSongRetry() {
        let cancelledSessionID = UUID()
        let cancelledOperationID = UUID()
        let retrySessionID = UUID()
        let retryOperationID = UUID()

        XCTAssertFalse(MobileTransferSessionPolicy.acceptsOperation(
            sessionID: cancelledSessionID,
            operationID: cancelledOperationID,
            activeSessionID: retrySessionID,
            activeOperationID: retryOperationID
        ))
        XCTAssertFalse(MobileTransferSessionPolicy.acceptsOperation(
            sessionID: retrySessionID,
            operationID: cancelledOperationID,
            activeSessionID: retrySessionID,
            activeOperationID: retryOperationID
        ))
        XCTAssertTrue(MobileTransferSessionPolicy.acceptsOperation(
            sessionID: retrySessionID,
            operationID: retryOperationID,
            activeSessionID: retrySessionID,
            activeOperationID: retryOperationID
        ))
    }

    func testLateFinalByteCallbackCannotReopenACompletedTransferCard() {
        let operationID = UUID()

        XCTAssertTrue(MobileTransferSessionPolicy.acceptsBytePresentation(
            operationID: operationID,
            activePresentationOperationID: operationID
        ))
        XCTAssertFalse(MobileTransferSessionPolicy.acceptsBytePresentation(
            operationID: operationID,
            activePresentationOperationID: nil
        ))
    }

    func testBoundedDownloadRejectsResponseAfterCancellation() {
        XCTAssertTrue(MobileBoundedDownloadCallbackPolicy.acceptsResponse(
            isFinished: false
        ))
        XCTAssertFalse(MobileBoundedDownloadCallbackPolicy.acceptsResponse(
            isFinished: true
        ))
    }
}

final class MobileClientConfigurationTests: XCTestCase {
    func testPlayableDurationOverridesStaleStoredAndMismatchedVideoTimelines() {
        XCTAssertEqual(
            MobilePlayableMediaDurationPolicy.preferred(
                storedDuration: 7_200,
                playableDurations: [217.4, 216.9]
            ),
            216.9
        )
        XCTAssertEqual(
            MobilePlayableMediaDurationPolicy.preferred(
                storedDuration: 245,
                playableDurations: [.nan, nil]
            ),
            245
        )
        XCTAssertNil(MobilePlayableMediaDurationPolicy.remoteDuration(172_000))
        XCTAssertEqual(MobilePlayableMediaDurationPolicy.remoteDuration(1_686), 1_686)
    }

    private let token = "test-access-token"
    private let cohortKey = "AAECAwQFBgcICQoLDA0ODw"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfirmedProfileMigrationSignalIsNeverPersistedWithTheClerkSession() throws {
        let session = ResonanceAccountSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            email: "listener@example.com",
            role: "admin",
            baseURL: try XCTUnwrap(URL(string: "https://music.example")),
            accountID: "user_listener",
            profileID: "user_listener",
            displayName: "Listener",
            imageURL: nil,
            migratedProfileID: "default"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ResonanceAccountSession.self, from: encoded)
        XCTAssertEqual(decoded.profileID, "user_listener")
        XCTAssertNil(decoded.migratedProfileID)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("migratedProfileID"))
    }

    func testLocalTrackPersistenceAssociatesBothLinksWithItsFile() throws {
        let track = MobileTrack(
            title: "Local song",
            artist: "Device",
            album: "Imported",
            duration: 120,
            relativePath: "Device - Local song.m4a",
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            downloadSourceURL: "https://media.example/local-song.m4a"
        )

        let decoded = try JSONDecoder().decode(
            MobileTrack.self,
            from: JSONEncoder().encode(track)
        )
        XCTAssertEqual(decoded.relativePath, track.relativePath)
        XCTAssertEqual(decoded.sourceURL, track.sourceURL)
        XCTAssertEqual(decoded.downloadSourceURL, track.downloadSourceURL)
    }

    func testMinimalServerCatalogKeepsMetadataOnDevice() throws {
        let data = try XCTUnwrap("""
        {
          "id": "saved-song-uuid",
          "source_url": "https://media.example/Local%20Title.m4a?token=preserved",
          "download_url": "/api/v1/songs/saved-song-uuid/file",
          "stream_url": "/api/v1/songs/saved-song-uuid/stream"
        }
        """.data(using: .utf8))
        let song = try JSONDecoder().decode(MobileRemoteSong.self, from: data)

        XCTAssertEqual(song.id, "saved-song-uuid")
        XCTAssertEqual(song.filename, "Local Title.m4a")
        XCTAssertEqual(song.title, "Resolving metadata…")
        XCTAssertEqual(song.artist, "On-device lookup")
        XCTAssertEqual(song.album, "Link only")
        XCTAssertEqual(song.size, 0)
        XCTAssertEqual(song.sourceURL, "https://media.example/Local%20Title.m4a?token=preserved")
        XCTAssertEqual(song.mediaKind, "audio")
        XCTAssertTrue(song.isSourceLinkRecord)
        XCTAssertTrue(song.isMetadataLoading)
    }

    func testRichServerCatalogDoesNotShowMetadataPlaceholder() throws {
        let data = try XCTUnwrap("""
        {
          "id": "saved-song-uuid",
          "filename": "Example.m4a",
          "title": "Example",
          "artist": "Artist",
          "album": "Album",
          "source_url": "https://www.youtube.com/watch?v=jNQXAC9IVRw",
          "media_kind": "audio",
          "download_url": "/api/v1/songs/saved-song-uuid/file",
          "stream_url": "/api/v1/songs/saved-song-uuid/stream"
        }
        """.data(using: .utf8))
        let song = try JSONDecoder().decode(MobileRemoteSong.self, from: data)

        XCTAssertTrue(song.isSourceLinkRecord)
        XCTAssertFalse(song.isMetadataLoading)
    }

    func testRemoteMetadataCacheKeepsOnlyFreshMatchingSafeEntries() throws {
        let source = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        let key = try XCTUnwrap(MobileRemoteSongMetadataCachePolicy.key(sourceURL: source, mediaKind: "audio"))
        let metadata = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: "jNQXAC9IVRw",
            title: "Me at the zoo",
            artist: "jawed",
            album: nil,
            trackNumber: nil,
            durationSeconds: nil,
            artworkURL: "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
            embedURL: "",
            sourceURL: source
        )
        let fresh = MobileRemoteSongMetadataCacheEntry(
            sourceURL: source,
            mediaKind: "audio",
            metadata: metadata,
            cachedAt: now.addingTimeInterval(-60)
        )
        let stale = MobileRemoteSongMetadataCacheEntry(
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            mediaKind: "audio",
            metadata: metadata,
            cachedAt: now.addingTimeInterval(-MobileRemoteSongMetadataCachePolicy.lifetime - 1)
        )

        let normalized = MobileRemoteSongMetadataCachePolicy.normalized(
            [
                key: fresh,
                "audio:https://www.youtube.com/watch?v=dQw4w9WgXcQ": stale,
                "audio:https://wrong.example/track": fresh,
            ],
            now: now
        )

        XCTAssertEqual(normalized, [key: fresh])
        XCTAssertNil(MobileRemoteSongMetadataCachePolicy.key(sourceURL: "http://example.com/song", mediaKind: "audio"))
    }

    func testOrdinaryTextSearchFallsBackToDeviceOnlyForServerLinkModes() {
        for mode in [MobileUploadMode.serverSourceLink, .reviewedMatch] {
            let preparation = MobileLocalImportSearchPolicy.prepare(
                input: "Test Song Test Artist",
                explicitlyReviewedServerMatch: false,
                syncAfterImport: true,
                activeUploadMode: mode
            )
            XCTAssertTrue(preparation.searchesProviders)
            XCTAssertFalse(preparation.syncAfterImport)
            XCTAssertFalse(preparation.usesReviewedServerMatch)
        }

        let explicitReview = MobileLocalImportSearchPolicy.prepare(
            input: "Test Song Test Artist",
            explicitlyReviewedServerMatch: true,
            syncAfterImport: true,
            activeUploadMode: .reviewedMatch
        )
        XCTAssertTrue(explicitReview.searchesProviders)
        XCTAssertTrue(explicitReview.syncAfterImport)
        XCTAssertTrue(explicitReview.usesReviewedServerMatch)

        let reviewedLink = MobileLocalImportSearchPolicy.prepare(
            input: "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            explicitlyReviewedServerMatch: false,
            syncAfterImport: true,
            activeUploadMode: .reviewedMatch
        )
        XCTAssertFalse(reviewedLink.searchesProviders)
        XCTAssertTrue(reviewedLink.syncAfterImport)
        XCTAssertTrue(reviewedLink.usesReviewedServerMatch)
    }

    func testLocalImportSearchRequestsDesktopProviderDocuments() {
        let userAgent = MobileLocalImportSearchRequestPolicy.webUserAgent
        XCTAssertTrue(userAgent.contains("Macintosh"))
        XCTAssertTrue(userAgent.contains("Chrome/"))
        XCTAssertFalse(userAgent.contains("iPhone"))
        XCTAssertFalse(userAgent.contains(" Mobile/"))
    }

    func testYouTubeMetadataResolutionUsesOneLightweightOEmbedRequest() async throws {
        MobileMetadataURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileMetadataURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = LocalDeviceImportService(
            sessions: .testing(session),
            localRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            temporaryRoot: FileManager.default.temporaryDirectory
        )

        let metadata = try await service.resolveMetadata(
            source: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )

        XCTAssertEqual(metadata.title, "Me at the zoo")
        XCTAssertEqual(metadata.artist, "jawed")
        XCTAssertEqual(metadata.durationSeconds, nil)
        XCTAssertEqual(MobileMetadataURLProtocol.state.requestedPaths, ["/oembed"])
    }

    func testProfilePicturesUseCanonicalPerProfileScopes() {
        XCTAssertEqual(
            MobileProfilePictureScope.contextKey(
                serverURL: "https://MUSIC.example/library/",
                profileID: "  "
            ),
            "https://music.example:443#profile=default"
        )
        XCTAssertNotEqual(
            MobileProfilePictureScope.filename(serverURL: "https://music.example", profileID: "default"),
            MobileProfilePictureScope.filename(serverURL: "https://music.example", profileID: "family")
        )
    }

    func testSavedSoundCloudSongWithoutDirectRenditionFallsBackToMatchedYouTubeAudio() async throws {
        let source = "https://soundcloud.com/the-weeknd/save-your-tears"
        let metadata = LocalImportSpotifyTrack(
            provider: "soundcloud",
            type: "track",
            trackID: "saved-soundcloud-track",
            title: "Save Your Tears",
            artist: "The Weeknd",
            album: "After Hours",
            trackNumber: nil,
            durationSeconds: 216,
            artworkURL: nil,
            embedURL: "",
            sourceURL: source
        )
        let alternate = LocalImportAudioSourceMatch(
            videoID: "LIIDh-qI9oI",
            title: "The Weeknd - Save Your Tears (Official Audio)",
            artist: "The Weeknd",
            album: "After Hours",
            durationSeconds: 216,
            thumbnailURL: "https://i.ytimg.com/vi/LIIDh-qI9oI/maxresdefault.jpg",
            sourceProvider: .youtube,
            officialArtist: true,
            sourceURL: "https://www.youtube.com/watch?v=LIIDh-qI9oI",
            score: 0.99,
            confidence: "high",
            match: .init(title: 1, artist: 1, album: 1, duration: 1, durationDeltaSeconds: 0)
        )
        let service = LocalDeviceImportService(
            soundCloudOperations: LocalImportSoundCloudOperations(
                resolveAudio: { _, _ in
                    throw LocalImportError(
                        stage: .inspectingSource,
                        code: "SOUNDCLOUD_STREAM_UNAVAILABLE",
                        message: "No direct rendition"
                    )
                }
            ),
            candidateSearch: { track in
                guard track.title == metadata.title, track.artist == metadata.artist else { return [] }
                return [alternate]
            }
        )

        let resolution = try await service.resolveUsingCatalogMetadata(
            source: source,
            metadata: metadata
        ) { _ in }

        XCTAssertEqual(resolution.kind, .soundCloud)
        XCTAssertEqual(resolution.track, metadata)
        XCTAssertEqual(resolution.candidates, [alternate])
    }

    func testVerifierAcceptsExactDigestSignatureAndAudience() throws {
        let signed = try signedResponse()
        let result = try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )

        XCTAssertEqual(result.payload.schemaVersion, 1)
        XCTAssertEqual(result.payload.audience, expectedAudience.audience)
        XCTAssertTrue(result.isUsable(at: now))
    }

    func testVerifierRejectsTamperingFutureSnapshotsAndInvalidOrdering() throws {
        let signed = try signedResponse()
        var tampered = signed.body
        tampered.append(0x20)
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: tampered,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .digestMismatch)
        }

        let future = try signedResponse(issuedAt: now.addingTimeInterval(1))
        XCTAssertThrowsError(try verify(future)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidTimeWindow)
        }

        let invalidOrder = try signedResponse(
            issuedAt: now.addingTimeInterval(-5),
            notBefore: now.addingTimeInterval(-10)
        )
        XCTAssertThrowsError(try verify(invalidOrder)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidTimeWindow)
        }
    }

    func testVerifierRequiresCanonicalStandardBase64Headers() throws {
        let signed = try signedResponse()
        let unpaddedDigest = signed.digest.replacingOccurrences(of: "=:", with: ":")
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: unpaddedDigest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .malformedDigest)
        }

        let unpaddedSignature = signed.signature.replacingOccurrences(of: "=:", with: ":")
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: unpaddedSignature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .malformedSignature)
        }
    }

    func testVerifierRejectsExpiryAndWrongAudience() throws {
        let expired = try signedResponse(
            issuedAt: now.addingTimeInterval(-700),
            notBefore: now.addingTimeInterval(-700),
            expiresAt: now
        )
        XCTAssertThrowsError(try verify(expired)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .expired)
        }

        let signed = try signedResponse()
        let wrong = MobileClientConfigExpectedAudience(
            origin: expectedAudience.origin,
            profileID: "other-profile",
            appVersion: expectedAudience.appVersion,
            appBuild: expectedAudience.appBuild,
            cohortKey: cohortKey
        )
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: wrong,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .wrongAudience)
        }
    }

    func testVerifierRejectsNegativeRevisionAndNonpositiveBuild() throws {
        XCTAssertThrowsError(try verify(try signedResponse(revision: -1))) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidRevision)
        }
        XCTAssertThrowsError(try verify(try signedResponse(audienceAppBuild: 0))) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidAppBuild)
        }
    }

    func testSafeDefaultsAndDisabledPreferencesFailClosed() {
        let safe = MobileClientFeatureConfiguration.safeDefaults
        XCTAssertEqual(
            MobileTransferModePolicy.availableUploadModes(configuration: safe, at: now),
            [.localFile]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: safe, at: now),
            [.verifiedFileCache]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveUploadMode(
                preferred: .serverSourceLink,
                configuration: safe,
                at: now
            ),
            .localFile
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveDownloadMode(
                preferred: .streamOnly,
                configuration: safe,
                at: now
            ),
            .verifiedFileCache
        )
    }

    func testStreamOnlyPolicyDoesNotExposeOfflineCache() throws {
        let signed = try signedResponse(offlineMode: "stream_only")
        let verified = try verify(signed)
        let configuration = MobileClientFeatureConfiguration(verified: verified)

        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: configuration, at: now),
            [.streamOnly]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveDownloadMode(
                preferred: .verifiedFileCache,
                configuration: configuration,
                at: now
            ),
            .streamOnly
        )
    }

    func testReviewedMatchRequiresLocalFileAndDoesNotDependOnLinkImports() throws {
        let enabled = try verify(try signedResponse(
            localFile: true,
            reviewedMatch: true,
            matcherMode: "review",
            killLinkImports: true
        ))
        XCTAssertTrue(MobileTransferModePolicy.availableUploadModes(
            configuration: MobileClientFeatureConfiguration(verified: enabled),
            at: now
        ).contains(.reviewedMatch))

        let withoutLocalUpload = try verify(try signedResponse(
            localFile: false,
            reviewedMatch: true,
            matcherMode: "review"
        ))
        XCTAssertFalse(MobileTransferModePolicy.availableUploadModes(
            configuration: MobileClientFeatureConfiguration(verified: withoutLocalUpload),
            at: now
        ).contains(.reviewedMatch))
    }

    func testExpiredConfigurationFallsBackToSafeModes() throws {
        let signed = try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            sourceLink: true,
            offlineMode: "stream_only"
        )
        let configuration = MobileClientFeatureConfiguration(verified: try verify(signed))
        let afterExpiry = now.addingTimeInterval(11)

        XCTAssertEqual(
            MobileTransferModePolicy.availableUploadModes(configuration: configuration, at: afterExpiry),
            [.localFile]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: configuration, at: afterExpiry),
            [.verifiedFileCache]
        )
    }

    func testCacheScopeIncludesEveryRequiredBoundaryAndAge() {
        let base = MobileClientConfigCacheScope(
            origin: "https://music.example",
            profileID: "default",
            platform: "ios",
            appVersion: "1.1.4",
            appBuild: "15",
            tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint("one")
        )
        let variants = [
            MobileClientConfigCacheScope(origin: "https://other.example", profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "other", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "android", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.5", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "16", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint("two")),
        ]
        XCTAssertTrue(variants.allSatisfy { $0.storageKey != base.storageKey })
        XCTAssertTrue(variants.allSatisfy { $0.highestRevisionKey != base.highestRevisionKey })

        let record = MobileClientConfigCacheRecord(
            body: Data(),
            contentDigest: "digest",
            signature: "signature",
            cachedAt: now
        )
        XCTAssertTrue(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(899)))
        XCTAssertFalse(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(901)))
        XCTAssertFalse(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(-1)))
    }

    func testRevisionHighWatermarkRejectsReplayPerExactScope() {
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 7, highestVerified: nil))
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 7, highestVerified: 7))
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 8, highestVerified: 7))
        XCTAssertFalse(MobileClientConfigRevisionPolicy.accepts(candidate: 6, highestVerified: 7))
        XCTAssertFalse(MobileClientConfigRevisionPolicy.accepts(candidate: -1, highestVerified: nil))
    }

    func testCohortKeysMustBeExactly128BitBase64URL() {
        XCTAssertTrue(MobileClientConfigCohort.isValidKey(cohortKey))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey("not a key"))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey("AAECAw"))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey(cohortKey + "=="))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey(String(cohortKey.dropLast()) + "x"))
        XCTAssertEqual(MobileClientConfigCohort.bucket(for: cohortKey), expectedAudience.audience.cohortBucket)
    }

    func testHTTPDispositionOnlyUsesCacheForServerOutage() {
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 200, contentType: "application/json; charset=utf-8"),
            .verify
        )
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 503, contentType: "text/plain"),
            .useFreshCache
        )
        for status in [201, 302, 400, 404] {
            XCTAssertEqual(
                MobileClientConfigHTTPPolicy.disposition(status: status, contentType: "application/json"),
                .evictAndUseSafeDefaults
            )
        }
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 200, contentType: "text/html"),
            .evictAndUseSafeDefaults
        )

        for code in [
            URLError.timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
        ] {
            XCTAssertTrue(MobileClientConfigTransportPolicy.mayUseFreshCache(
                for: URLError(code)
            ))
        }
        for code in [
            URLError.badServerResponse,
            .cancelled,
            .dataNotAllowed,
            .serverCertificateUntrusted,
            .cannotDecodeContentData,
        ] {
            XCTAssertFalse(MobileClientConfigTransportPolicy.mayUseFreshCache(
                for: URLError(code)
            ))
        }
        XCTAssertFalse(MobileClientConfigTransportPolicy.mayUseFreshCache(
            for: MobileClientConfigVerificationError.unsupportedSchema
        ))
    }

    func testBoundedResponsesAndSameOriginPolicyFailClosed() {
        XCTAssertTrue(MobileBoundedResponsePolicy.accepts(currentCount: 9, adding: 1, maximum: 10))
        XCTAssertFalse(MobileBoundedResponsePolicy.accepts(currentCount: 10, adding: 1, maximum: 10))
        XCTAssertFalse(MobileBoundedResponsePolicy.accepts(currentCount: Int.max, adding: 1, maximum: Int.max))

        XCTAssertTrue(MobileSameOriginPolicy.matches(
            URL(string: "https://MUSIC.example/file"),
            URL(string: "https://music.example:443/root")
        ))
        XCTAssertFalse(MobileSameOriginPolicy.matches(
            URL(string: "https://cdn.example/file"),
            URL(string: "https://music.example/root")
        ))
        XCTAssertFalse(MobileSameOriginPolicy.matches(
            URL(string: "https://music.example:8443/file"),
            URL(string: "https://music.example/root")
        ))
    }

    func testSourceImportPreservesOnlyCanonicalUserEnteredYouTubePage() {
        let original = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        XCTAssertEqual(MobileSourcePagePolicy.validatedOriginalYouTubePage("  \(original)\n"), original)
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"))
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://www.youtube.com/embed/dQw4w9WgXcQ"))
    }

    func testRequestContextAppliesEveryRequiredHeader() {
        let context = MobileClientRequestContext(
            profileID: "default",
            platform: "ios",
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohortKey
        )
        var request = URLRequest(url: URL(string: "https://music.example/api/v1/admin/debrid/resolve")!)
        context.apply(to: &request)

        XCTAssertTrue(context.isComplete)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Profile"), "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-App-Version"), "1.1.4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-App-Build"), "15")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"), cohortKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol"), "1")
    }

    func testTransferLeaseRejectsExpiryRevisionAndPreferenceChanges() throws {
        let first = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            offlineMode: "stream_only"
        )))
        let lease = try XCTUnwrap(MobileTransferPolicyLeasePolicy.captureDownload(
            .streamOnly,
            configuration: first,
            preferredMode: .streamOnly,
            at: now
        ))
        XCTAssertTrue(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        let renewed = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(20),
            offlineMode: "stream_only"
        )))
        XCTAssertTrue(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: renewed,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now.addingTimeInterval(10)
        ))

        let next = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            offlineMode: "stream_only",
            revision: 8
        )))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: next,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .verifiedFileCache,
            at: now
        ))
    }

    func testRefreshRunsBeforeExpiryAndTransientOwnershipIsNarrow() {
        XCTAssertEqual(
            MobileClientConfigRefreshPolicy.delay(
                until: now.addingTimeInterval(600),
                now: now
            ),
            540
        )
        XCTAssertEqual(
            MobileClientConfigRefreshPolicy.delay(
                until: now.addingTimeInterval(100),
                now: now
            ),
            50
        )
        XCTAssertNil(MobileClientConfigRefreshPolicy.delay(until: now, now: now))
        XCTAssertTrue(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/resonance-download-123")
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/resonance-download")
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/other-resonance-download-123")
        ))
        XCTAssertTrue(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-download-123"),
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false
        ))
        XCTAssertTrue(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-import-123"),
            isRegularFile: false,
            isDirectory: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-import-123"),
            isRegularFile: false,
            isDirectory: true,
            isSymbolicLink: true
        ))

        let staging = URL(fileURLWithPath: "/app/Resonance/LocalImports", isDirectory: true)
        XCTAssertTrue(MobileLocalImportStagingPolicy.ownsStagedFile(
            staging.appendingPathComponent("finished.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileLocalImportStagingPolicy.ownsStagedFile(
            URL(fileURLWithPath: "/app/Resonance/Music/finished.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileLocalImportStagingPolicy.ownsStagedFile(
            staging.appendingPathComponent("link.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: true
        ))
    }

    func testOwnedTransferArtifactCleanerOnlyRemovesExactCrashArtifacts() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-cleaner-test-\(UUID().uuidString)", isDirectory: true)
        let temporaryDirectory = testRoot.appendingPathComponent("tmp", isDirectory: true)
        let supportDirectory = testRoot.appendingPathComponent("Resonance", isDirectory: true)
        let stagingDirectory = supportDirectory.appendingPathComponent("LocalImports", isDirectory: true)
        let musicDirectory = supportDirectory.appendingPathComponent("Music", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)

        let ownedDownload = temporaryDirectory.appendingPathComponent("resonance-download-abandoned")
        let ownedImport = temporaryDirectory.appendingPathComponent("resonance-import-abandoned", isDirectory: true)
        let unrelatedTemporaryFile = temporaryDirectory.appendingPathComponent("unrelated-audio.m4a")
        let wrongDownloadType = temporaryDirectory.appendingPathComponent("resonance-download-directory", isDirectory: true)
        let wrongImportType = temporaryDirectory.appendingPathComponent("resonance-import-file")
        let ownedNameSymlink = temporaryDirectory.appendingPathComponent("resonance-download-link")

        try Data("download".utf8).write(to: ownedDownload)
        try fileManager.createDirectory(at: ownedImport, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: unrelatedTemporaryFile)
        try fileManager.createDirectory(at: wrongDownloadType, withIntermediateDirectories: false)
        try Data("wrong type".utf8).write(to: wrongImportType)
        try fileManager.createSymbolicLink(
            at: ownedNameSymlink,
            withDestinationURL: unrelatedTemporaryFile
        )

        let stagedFile = stagingDirectory.appendingPathComponent("finished.m4a")
        let hiddenStagedFile = stagingDirectory.appendingPathComponent(".unfinished.m4a")
        let stagedDirectory = stagingDirectory.appendingPathComponent("nested", isDirectory: true)
        let stagedNestedFile = stagedDirectory.appendingPathComponent("keep.m4a")
        let musicFile = musicDirectory.appendingPathComponent("library-track.m4a")
        try Data("staged".utf8).write(to: stagedFile)
        try Data("hidden".utf8).write(to: hiddenStagedFile)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: stagedNestedFile)
        try Data("music".utf8).write(to: musicFile)

        MobileOwnedTransferArtifactCleaner.removeOrphans(
            temporaryDirectory: temporaryDirectory,
            stagingDirectory: stagingDirectory,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: ownedDownload.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ownedImport.path))
        XCTAssertFalse(fileManager.fileExists(atPath: stagedFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: hiddenStagedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTemporaryFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongDownloadType.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongImportType.path))
        XCTAssertTrue(fileManager.fileExists(atPath: ownedNameSymlink.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedNestedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: musicFile.path))
    }

    func testBoundedDownloadRevocationStopsInFlightAndRemovesTemporaryFile() async throws {
        let firstChunk = expectation(description: "first chunk received")
        let stopped = expectation(description: "protocol stopped")
        MobileChunkedDownloadProtocol.state.configure(
            onFirstChunk: { firstChunk.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let authorization = MobileTransferAuthorization(expiresAt: nil)
        let operation = try MobileBoundedDownloadOperation(
            maximumSize: 1_024,
            authorization: authorization,
            sessionConfiguration: chunkedSessionConfiguration()
        )
        let task = Task {
            try await operation.run(request: URLRequest(url: URL(string: "https://music.example/audio")!))
        }

        await fulfillment(of: [firstChunk], timeout: 2)
        authorization.revoke()
        do {
            _ = try await task.value
            XCTFail("A revoked transfer must not complete")
        } catch {
            XCTAssertTrue(error is MobileTransferPolicyChangedError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(MobileChunkedDownloadProtocol.state.secondChunkWasDelivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.temporaryURL.path))
    }

    func testBoundedDownloadExpiryStopsInFlightAndRemovesTemporaryFile() async throws {
        let firstChunk = expectation(description: "first chunk received")
        let stopped = expectation(description: "protocol stopped")
        MobileChunkedDownloadProtocol.state.configure(
            onFirstChunk: { firstChunk.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let authorization = MobileTransferAuthorization(
            expiresAt: Date().addingTimeInterval(0.1)
        )
        let operation = try MobileBoundedDownloadOperation(
            maximumSize: 1_024,
            authorization: authorization,
            sessionConfiguration: chunkedSessionConfiguration()
        )
        let task = Task {
            try await operation.run(request: URLRequest(url: URL(string: "https://music.example/audio")!))
        }

        await fulfillment(of: [firstChunk], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("An expired transfer must not complete")
        } catch {
            XCTAssertTrue(error is MobileTransferPolicyChangedError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(MobileChunkedDownloadProtocol.state.secondChunkWasDelivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.temporaryURL.path))
    }

    func testLocalImportRangeDownloadAggregatesURLSessionChunks() async throws {
        MobileChunkedDownloadProtocol.state.configure(onFirstChunk: {}, onStop: {})
        let session = URLSession(configuration: chunkedSessionConfiguration())
        defer { session.invalidateAndCancel() }
        let progress = LocalImportByteProgressRecorder()
        let operation = LocalImportBoundedDataOperation(
            session: session,
            maximumSize: 8,
            redirectValidator: { _ in true },
            progress: { progress.record($0) }
        )

        let (data, response) = try await operation.run(
            request: URLRequest(url: URL(string: "https://music.example/audio")!)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, Data("aaaabbbb".utf8))
        let updates = progress.values
        XCTAssertEqual(updates.first, 4, "The first nonzero URLSession chunk must publish immediately")
        XCTAssertEqual(updates.last, 8, "A final exact range-byte event must always publish")
        XCTAssertTrue(updates.allSatisfy { $0 > 0 })
        XCTAssertEqual(updates, updates.sorted())
    }

    func testCancelledLocalImportRangeCannotPublishDelayedChunks() async throws {
        let firstProgress = expectation(description: "first local-import range progress")
        let stopped = expectation(description: "local-import range stopped")
        MobileChunkedDownloadProtocol.state.configure(
            onFirstChunk: {},
            onStop: { stopped.fulfill() }
        )
        let session = URLSession(configuration: chunkedSessionConfiguration())
        defer { session.invalidateAndCancel() }
        let progress = LocalImportByteProgressRecorder()
        let operation = LocalImportBoundedDataOperation(
            session: session,
            maximumSize: 8,
            redirectValidator: { _ in true },
            progress: {
                progress.record($0)
                if $0 == 4 { firstProgress.fulfill() }
            }
        )
        let task = Task {
            try await operation.run(
                request: URLRequest(url: URL(string: "https://music.example/audio")!)
            )
        }

        await fulfillment(of: [firstProgress], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled range must not complete")
        } catch {
            XCTAssertTrue(
                error is CancellationError || (error as? URLError)?.code == .cancelled
            )
        }
        await fulfillment(of: [stopped], timeout: 2)

        XCTAssertFalse(MobileChunkedDownloadProtocol.state.secondChunkWasDelivered)
        XCTAssertEqual(progress.values.last, 4)
    }

    func testLocalImportRangeDownloadRejectsDeclaredOverflow() async throws {
        MobileChunkedDownloadProtocol.state.configure(onFirstChunk: {}, onStop: {})
        let session = URLSession(configuration: chunkedSessionConfiguration())
        defer { session.invalidateAndCancel() }
        let operation = LocalImportBoundedDataOperation(
            session: session,
            maximumSize: 4,
            redirectValidator: { _ in true }
        )

        do {
            _ = try await operation.run(
                request: URLRequest(url: URL(string: "https://music.example/audio")!)
            )
            XCTFail("A declared range larger than the operation bound must fail")
        } catch {
            XCTAssertTrue(error is LocalImportBoundedDataError)
        }
    }

    func testCommittedReviewedUploadReconcilesAfterLeaseExpiryOnlyInSameContext() {
        XCTAssertTrue(MobileReviewedUploadCompletionPolicy.shouldReconcileCommittedResponse(
            requestContextCurrent: true,
            leaseStillCurrent: false
        ))
        XCTAssertFalse(MobileReviewedUploadCompletionPolicy.shouldReconcileCommittedResponse(
            requestContextCurrent: false,
            leaseStillCurrent: true
        ))
    }

    func testQueuedRawUploadRevalidatesExpiredLeaseAfterSerialGate() async throws {
        let configuration = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10)
        )))
        let lease = try XCTUnwrap(MobileTransferPolicyLeasePolicy.captureUpload(
            .localFile,
            configuration: configuration,
            preferredMode: .localFile,
            at: now
        ))
        let gate = MobileAsyncSerialGate()
        await gate.acquire()

        let queuedUpload = Task {
            await gate.acquire()
            await gate.release()
            return MobileTransferPolicyLeasePolicy.isCurrent(
                lease,
                configuration: configuration,
                preferredUploadMode: .localFile,
                preferredDownloadMode: .verifiedFileCache,
                at: now.addingTimeInterval(11)
            )
        }
        await Task.yield()
        await gate.release()

        let canStartRequest = await queuedUpload.value
        XCTAssertFalse(canStartRequest)
    }

    func testAuthenticatedStreamBuildsExactBoundedRangeRequest() throws {
        let source = try XCTUnwrap(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let assetURL = try MobileAuthenticatedStreamPolicy.assetURL(for: source)
        XCTAssertEqual(assetURL.scheme, "resonance-authenticated-stream")
        XCTAssertEqual(assetURL.host, source.host)
        XCTAssertEqual(assetURL.path, source.path)
        XCTAssertFalse(assetURL.absoluteString.contains(token))

        let plan = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [
                "Authorization": "Bearer \(token)",
                "X-Resonance-Profile": "default",
            ],
            offset: 100,
            requestedLength: 200,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        XCTAssertEqual(plan.offset, 100)
        XCTAssertEqual(plan.end, 299)
        XCTAssertEqual(plan.responseLength, 200)
        XCTAssertEqual(plan.request.url, source)
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Range"), "bytes=100-299")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        let clamped = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [:],
            offset: 900,
            requestedLength: 500,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        XCTAssertEqual(clamped.request.value(forHTTPHeaderField: "Range"), "bytes=900-999")
        XCTAssertEqual(clamped.responseLength, 100)
    }

    func testAuthenticatedStreamRequiresExactCoherent206Response() throws {
        let source = try XCTUnwrap(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let plan = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [:],
            offset: 100,
            requestedLength: 200,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        let valid = try XCTUnwrap(HTTPURLResponse(
            url: source,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "200",
                "Content-Range": "bytes 100-299/1000",
            ]
        ))
        let metadata = try MobileAuthenticatedStreamPolicy.validate(
            response: valid,
            sourceURL: source,
            requestPlan: plan,
            expectedContentLength: 1_000,
            expectedContentType: "audio/mp4"
        )
        XCTAssertEqual(metadata.contentLength, 1_000)
        XCTAssertEqual(metadata.responseLength, 200)
        XCTAssertTrue(metadata.supportsByteRanges)

        let invalidResponses: [(HTTPURLResponse, MobileAuthenticatedStreamError)] = [
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "199",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 0-199/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/2000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .unsupportedContentType),
            (try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://objects.example/song.m4a")!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .crossOriginResponse),
        ]
        for (response, expectedError) in invalidResponses {
            XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validate(
                response: response,
                sourceURL: source,
                requestPlan: plan,
                expectedContentLength: 1_000,
                expectedContentType: "audio/mp4"
            )) { error in
                XCTAssertEqual(error as? MobileAuthenticatedStreamError, expectedError)
            }
        }
    }

    func testAuthenticatedStreamPinsCatalogDescriptorToAudioObject() throws {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4; charset=binary",
            locationLength: 1_000,
            locationSHA256: hash.uppercased(),
            locationContentType: "audio/mp4",
            supportsRanges: true,
            state: "active"
        ), "audio/mp4")

        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4",
            locationLength: 999,
            locationSHA256: hash,
            locationContentType: "audio/mp4",
            supportsRanges: true,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .resourceMismatch)
        }
        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4",
            locationLength: 1_000,
            locationSHA256: hash,
            locationContentType: "audio/mp4",
            supportsRanges: false,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .resourceMismatch)
        }
        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "video/mp4",
            locationLength: 1_000,
            locationSHA256: hash,
            locationContentType: "video/mp4",
            supportsRanges: true,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .unsupportedContentType)
        }
    }

    func testAuthenticatedStreamSessionCannotPersistMediaOrCredentials() {
        let session = MobileAuthenticatedStreamSession.makeEphemeral()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testAuthenticatedStreamLeaseAdoptsEarlierEqualAndLaterExpiryInExactContext() throws {
        let context = authenticatedStreamContext(profileID: "default")
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now
        )
        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(30))
        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(2)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(60))

        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(50),
            now: now.addingTimeInterval(3)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(50))
        XCTAssertNoThrow(try lease.authorize(at: now.addingTimeInterval(49)))
        XCTAssertThrowsError(try lease.authorize(at: now.addingTimeInterval(50))) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }

        let changedContext = authenticatedStreamContext(profileID: "other")
        let changedContextLease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now
        )
        XCTAssertFalse(changedContextLease.renew(
            context: changedContext,
            expiresAt: now.addingTimeInterval(90),
            now: now.addingTimeInterval(2)
        ))
        XCTAssertThrowsError(try changedContextLease.authorize(at: now.addingTimeInterval(3))) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testAuthenticatedStreamLeaseEarlierExpiryReschedulesInvalidation() async throws {
        let invalidated = expectation(description: "shortened stream lease invalidated")
        let context = authenticatedStreamContext(profileID: "default")
        let startedAt = Date.now
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: startedAt.addingTimeInterval(2),
            now: startedAt
        )
        lease.setInvalidationHandler { invalidated.fulfill() }

        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: startedAt.addingTimeInterval(0.05),
            now: startedAt.addingTimeInterval(0.01)
        ))
        XCTAssertEqual(lease.expiration, startedAt.addingTimeInterval(0.05))

        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertThrowsError(try lease.authorize()) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testAuthenticatedStreamLeaseExpiryInvalidatesInFlightWork() async throws {
        let invalidated = expectation(description: "stream work invalidated")
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: authenticatedStreamContext(profileID: "default"),
            expiresAt: Date.now.addingTimeInterval(0.05)
        )
        lease.setInvalidationHandler { invalidated.fulfill() }

        await fulfillment(of: [invalidated], timeout: 2)
        XCTAssertThrowsError(try lease.authorize()) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testReviewedMatchResponseOnlyExposesExplicitReviewCandidates() throws {
        let object: [String: Any] = [
            "provider": "spotify",
            "type": "track",
            "source": "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
            "track_id": "4uLU6hMCjMI75M1A2tKUQC",
            "title": "Track",
            "artist": "Artist",
            "duration_seconds": 180,
            "review_candidates": [
                reviewedCandidate(videoID: "reviewme001", requiresReview: true, autoSelectable: false),
                reviewedCandidate(videoID: "donotuse001", requiresReview: false, autoSelectable: true),
                reviewedCandidate(
                    videoID: "preauth0001",
                    requiresReview: true,
                    autoSelectable: false,
                    actionable: true
                ),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let resolution = try JSONDecoder().decode(MobileReviewedMatchResponse.self, from: data)
            .reviewedResolution()

        XCTAssertEqual(resolution.candidates.map(\.videoID), ["reviewme001"])
        XCTAssertEqual(resolution.track.sourceURL, "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    func testReviewedYouTubeRequiresAndConsumesOneExplicitSafeCandidate() throws {
        let videoID = "reviewme001"
        let object: [String: Any] = [
            "provider": "youtube",
            "type": "video",
            "source": "https://www.youtube.com/watch?v=\(videoID)",
            "video_id": videoID,
            "title": "Candidate \(videoID)",
            "author": "Uploader",
            "duration_seconds": 180,
            "review_candidates": [
                reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false),
            ],
        ]
        let resolution = try decodeReviewedResolution(object)
        XCTAssertEqual(resolution.kind, .youtube)
        XCTAssertEqual(resolution.track.sourceURL, "https://www.youtube.com/watch?v=\(videoID)")
        XCTAssertEqual(resolution.candidates.count, 1)
        XCTAssertEqual(resolution.candidates.first?.videoID, videoID)

        var missingCandidate = object
        missingCandidate.removeValue(forKey: "review_candidates")
        XCTAssertThrowsError(try decodeReviewedResolution(missingCandidate)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }

        for unsafeCandidate in [
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false, actionable: true),
            reviewedCandidate(videoID: videoID, requiresReview: false, autoSelectable: false),
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: true),
        ] {
            var unsafe = object
            unsafe["review_candidates"] = [unsafeCandidate]
            XCTAssertThrowsError(try decodeReviewedResolution(unsafe)) { error in
                XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
            }
        }

        var multiple = object
        multiple["review_candidates"] = [
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false),
            reviewedCandidate(videoID: "reviewme002", requiresReview: true, autoSelectable: false),
        ]
        XCTAssertThrowsError(try decodeReviewedResolution(multiple)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }

        var mismatchedTopLevelSource = object
        mismatchedTopLevelSource["source"] = "https://www.youtube.com/watch?v=reviewme002"
        XCTAssertThrowsError(try decodeReviewedResolution(mismatchedTopLevelSource)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }
    }

    func testEditedImportSourceInvalidatesPreviouslyResolvedIdentity() {
        let resolved = "https://www.youtube.com/watch?v=reviewme001"
        XCTAssertTrue(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: resolved,
            displayedInput: resolved
        ))
        XCTAssertFalse(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: resolved,
            displayedInput: "https://www.youtube.com/watch?v=reviewme002"
        ))
        XCTAssertFalse(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: nil,
            displayedInput: resolved
        ))
    }

    func testClipPlaybackPolicyKeepsStreamingInsideConfiguredBounds() {
        let bounds = MobileClipPlaybackPolicy.bounds(
            range: MobileClipRange(startSeconds: 30, endSeconds: 90),
            duration: 180
        )
        XCTAssertEqual(bounds, .init(start: 30, end: 90))
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 0, within: bounds), 30)
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 0.5, within: bounds), 60)
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 1, within: bounds), 90)
        XCTAssertTrue(MobileClipPlaybackPolicy.reachedEnd(position: 89.99, bounds: bounds))
        XCTAssertFalse(MobileClipPlaybackPolicy.reachedEnd(position: 89.9, bounds: bounds))
        XCTAssertFalse(MobileClipPlaybackPolicy.reachedEnd(
            position: 0,
            bounds: .init(start: 0, end: 0)
        ))

        XCTAssertEqual(
            MobileClipPlaybackPolicy.bounds(
                range: MobileClipRange(startSeconds: 30, endSeconds: 30.1),
                duration: 180
            ),
            .init(start: 0, end: 180)
        )
    }

    private var expectedAudience: MobileClientConfigExpectedAudience {
        MobileClientConfigExpectedAudience(
            origin: "https://music.example",
            profileID: "default",
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohortKey
        )
    }

    private func verify(_ response: SignedResponse) throws -> MobileVerifiedClientConfiguration {
        try MobileClientConfigVerifier.verify(
            body: response.body,
            contentDigest: response.digest,
            signature: response.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )
    }

    private func signedResponse(
        issuedAt: Date? = nil,
        notBefore: Date? = nil,
        expiresAt: Date? = nil,
        localFile: Bool = true,
        sourceLink: Bool = false,
        reviewedMatch: Bool = false,
        matcherMode: String = "off",
        offlineMode: String = "verified_file_cache",
        killLinkImports: Bool = false,
        revision: Int = 7,
        audienceAppBuild: Int? = nil
    ) throws -> SignedResponse {
        let issuedAt = issuedAt ?? now.addingTimeInterval(-10)
        let notBefore = notBefore ?? now.addingTimeInterval(-5)
        let expiresAt = expiresAt ?? now.addingTimeInterval(600)
        let audience = expectedAudience.audience
        let signedAppBuild = audienceAppBuild ?? audience.appBuild
        let object: [String: Any] = [
            "schema_version": 1,
            "revision": revision,
            "issued_at": iso8601(issuedAt),
            "not_before": iso8601(notBefore),
            "expires_at": iso8601(expiresAt),
            "audience": [
                "origin": audience.origin,
                "profile_id": audience.profileID,
                "platform": audience.platform,
                "app_version": audience.appVersion,
                "app_build": signedAppBuild,
                "cohort_bucket": audience.cohortBucket,
            ],
            "values": [
                "upload.local_file": localFile,
                "upload.server_source_link": sourceLink,
                "upload.reviewed_match": reviewedMatch,
                "upload.external_object": false,
                "download.offline_mode": offlineMode,
                "download.playback_mode": "same_origin_resolver",
                "matcher.mode": matcherMode,
                "storage.read_mode": "r2_only",
                "storage.r2_reclaim": false,
            ],
            "kill_switches": [
                "all_uploads": false,
                "link_imports": killLinkImports,
                "offline_downloads": false,
                "external_reads": true,
                "r2_reclaim": true,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = "sha-256=:\(Data(SHA256.hash(data: body)).base64EncodedString()):"
        let signingInput = [
            "resonance-client-config-v1",
            audience.origin,
            audience.profileID,
            audience.platform,
            String(signedAppBuild),
            digest,
        ].joined(separator: "\n")
        let signatureBytes = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        let signature = "v1=:\(Data(signatureBytes).base64EncodedString()):"
        return SignedResponse(body: body, digest: digest, signature: signature)
    }

    private func reviewedCandidate(
        videoID: String,
        requiresReview: Bool,
        autoSelectable: Bool,
        actionable: Bool = false
    ) -> [String: Any] {
        [
            "provider": "youtube",
            "source_url": "https://www.youtube.com/watch?v=\(videoID)",
            "video_id": videoID,
            "title": "Candidate \(videoID)",
            "artist": "Uploader",
            "duration_seconds": 180,
            "score": 0.9,
            "confidence": "review",
            "actionable": actionable,
            "requires_review": requiresReview,
            "auto_selectable": autoSelectable,
            "match": [
                "title": 0.9,
                "artist": 0.8,
                "duration": 1.0,
                "duration_delta_seconds": 0,
            ],
        ]
    }

    private func decodeReviewedResolution(_ object: [String: Any]) throws -> LocalImportResolution {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MobileReviewedMatchResponse.self, from: data)
            .reviewedResolution()
    }

    private func authenticatedStreamContext(profileID: String) -> MobileAuthenticatedStreamLeaseContext {
        MobileAuthenticatedStreamLeaseContext(
            origin: "https://music.example:443",
            requestContext: MobileClientRequestContext(
                profileID: profileID,
                platform: "ios",
                appVersion: "1.1.4",
                appBuild: 15,
                cohortKey: cohortKey
            ),
            tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint(token)
        )
    }

    private func chunkedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileChunkedDownloadProtocol.self]
        return configuration
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SignedResponse {
    let body: Data
    let digest: String
    let signature: String
}

private final class MobileMetadataURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func reset() {
        lock.lock()
        paths = []
        lock.unlock()
    }

    func record(_ path: String) {
        lock.lock()
        paths.append(path)
        lock.unlock()
    }
}

private final class MobileMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = MobileMetadataURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.record(url.path)
        let body = Data("""
        {
          "type": "video",
          "provider_name": "YouTube",
          "title": "Me at the zoo",
          "author_name": "jawed",
          "thumbnail_url": "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg"
        }
        """.utf8)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(body.count),
            ]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LocalImportByteProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Int64] = []

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: Int64) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private final class MobileChunkedDownloadProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var onFirstChunk: (() -> Void)?
    private var onStop: (() -> Void)?
    private var deliveredSecondChunk = false

    var secondChunkWasDelivered: Bool {
        lock.lock()
        let result = deliveredSecondChunk
        lock.unlock()
        return result
    }

    func configure(onFirstChunk: @escaping () -> Void, onStop: @escaping () -> Void) {
        lock.lock()
        self.onFirstChunk = onFirstChunk
        self.onStop = onStop
        deliveredSecondChunk = false
        lock.unlock()
    }

    func didSendFirstChunk() {
        lock.lock()
        let callback = onFirstChunk
        lock.unlock()
        callback?()
    }

    func didSendSecondChunk() {
        lock.lock()
        deliveredSecondChunk = true
        lock.unlock()
    }

    func didStop() {
        lock.lock()
        let callback = onStop
        onFirstChunk = nil
        onStop = nil
        lock.unlock()
        callback?()
    }
}

private final class MobileChunkedDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let state = MobileChunkedDownloadProtocolState()

    private let lifecycleLock = NSLock()
    private var stopped = false
    private var delayedChunk: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "8", "Content-Type": "audio/mp4"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("aaaa".utf8))
        Self.state.didSendFirstChunk()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let shouldDeliver = !self.stopped
            self.lifecycleLock.unlock()
            guard shouldDeliver else { return }
            Self.state.didSendSecondChunk()
            self.client?.urlProtocol(self, didLoad: Data("bbbb".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        lifecycleLock.lock()
        delayedChunk = work
        lifecycleLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func stopLoading() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        let delayedChunk = delayedChunk
        self.delayedChunk = nil
        lifecycleLock.unlock()
        delayedChunk?.cancel()
        Self.state.didStop()
    }
}
