import Foundation
import XCTest
@testable import Resonance

final class MobileUnlinkedDownloadMigrationPolicyTests: XCTestCase {
    private func track(
        sourceURL: String? = nil,
        downloadSourceURL: String? = nil,
        preservesUnlinkedImport: Bool? = nil
    ) -> MobileTrack {
        MobileTrack(
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 120,
            relativePath: "song.m4a",
            remoteID: "remote-song",
            sourceServer: "https://music.example",
            sourceURL: sourceURL,
            downloadSourceURL: downloadSourceURL,
            preservesUnlinkedImport: preservesUnlinkedImport
        )
    }

    func testUnlinkedManagedDownloadIsSelectedForCleanup() {
        let decision = MobileUnlinkedDownloadMigrationPolicy.decision(
            for: track(),
            legacyDownloadOwned: true
        )

        XCTAssertTrue(decision.shouldDelete)
        XCTAssertEqual(decision.track.preservesUnlinkedImport, false)
    }

    func testEitherPreservedSourceLinkKeepsDownload() {
        XCTAssertFalse(MobileUnlinkedDownloadMigrationPolicy.decision(
            for: track(sourceURL: "https://source.example/song"),
            legacyDownloadOwned: true
        ).shouldDelete)
        XCTAssertFalse(MobileUnlinkedDownloadMigrationPolicy.decision(
            for: track(downloadSourceURL: "https://media.example/song.m4a"),
            legacyDownloadOwned: true
        ).shouldDelete)
    }

    func testExplicitImportFlagWinsAfterRemoteAssociation() {
        let decision = MobileUnlinkedDownloadMigrationPolicy.decision(
            for: track(preservesUnlinkedImport: true),
            legacyDownloadOwned: true
        )

        XCTAssertFalse(decision.shouldDelete)
        XCTAssertEqual(decision.track.preservesUnlinkedImport, true)
    }

    func testLegacyNonDownloadFileBecomesProtectedImport() {
        let decision = MobileUnlinkedDownloadMigrationPolicy.decision(
            for: track(),
            legacyDownloadOwned: false
        )

        XCTAssertFalse(decision.shouldDelete)
        XCTAssertEqual(decision.track.preservesUnlinkedImport, true)
    }
}

final class MobilePlaylistArtworkPolicyTests: XCTestCase {
    func testUsesOnlyTheFirstFourCustomPlaylistTracks() {
        let trackIDs = (0..<5).map { _ in UUID() }
        let playlist = MobilePlaylist(name: "Mix", trackIDs: trackIDs)
        let likedSongs = MobilePlaylist(name: "Liked Songs", trackIDs: trackIDs, isSystem: true)

        XCTAssertEqual(playlist.automaticArtworkTrackIDs, Array(trackIDs.prefix(4)))
        XCTAssertTrue(likedSongs.automaticArtworkTrackIDs.isEmpty)
    }
}

final class MobileAccountEmailPrivacyTests: XCTestCase {
    func testEmailIsCensoredUntilExplicitlyRevealed() {
        let email = "private@example.com"
        XCTAssertEqual(
            ResonanceEmailPrivacy.displayedAddress(email, isRevealed: false),
            ResonanceEmailPrivacy.censoredAddress
        )
        XCTAssertEqual(ResonanceEmailPrivacy.displayedAddress(email, isRevealed: true), email)
        XCTAssertEqual(
            ResonanceEmailPrivacy.safeDisplayName(email, email: email),
            "Clerk account"
        )
    }


    func testAccountScopeSupportsTheDeployedLegacyResponseUntilCoreMigratesIt() {
        XCTAssertEqual(
            ResonanceAccountScopePolicy.resolvedProfileID(
                accountID: "user_listener",
                serverProfileID: nil,
                requestedLegacyProfileID: "legacy-library"
            ),
            "legacy-library"
        )
        XCTAssertEqual(
            ResonanceAccountScopePolicy.resolvedProfileID(
                accountID: "user_listener",
                serverProfileID: nil,
                requestedLegacyProfileID: nil
            ),
            "default"
        )
        XCTAssertEqual(
            ResonanceAccountScopePolicy.resolvedProfileID(
                accountID: "user_listener",
                serverProfileID: "user_listener",
                requestedLegacyProfileID: "legacy-library"
            ),
            "user_listener"
        )
        XCTAssertNil(
            ResonanceAccountScopePolicy.resolvedProfileID(
                accountID: "user_listener",
                serverProfileID: "someone_else",
                requestedLegacyProfileID: "legacy-library"
            )
        )
    }
}

final class MobileServerEndpointPolicyTests: XCTestCase {
    func testRequiresHTTPSOutsideLoopback() throws {
        XCTAssertEqual(
            ResonanceSocialAuthClient.accountSignInBaseURL.absoluteString,
            "https://resonance-core.blithe-haven-9710.chatgpt.site/"
        )
        let secure = try MobileServerEndpointPolicy.resolve(" HTTPS://Music.Example.test/root/ ")
        XCTAssertEqual(secure.url.absoluteString, "https://music.example.test/root")
        XCTAssertFalse(secure.usesInsecureLocalHTTP)

        let local = try MobileServerEndpointPolicy.resolve("http://127.0.0.1:8787")
        XCTAssertTrue(local.usesInsecureLocalHTTP)

        XCTAssertThrowsError(try MobileServerEndpointPolicy.resolve("http://music.example.test")) {
            XCTAssertEqual($0 as? MobileServerEndpointError, .insecureRemoteHTTP)
        }
        XCTAssertThrowsError(try MobileServerEndpointPolicy.resolve("https://token@music.example.test")) {
            XCTAssertEqual($0 as? MobileServerEndpointError, .credentialsInURL)
        }
    }

    func testOriginNormalizationIncludesEffectivePortAndIgnoresPath() throws {
        let first = try XCTUnwrap(URL(string: "https://MUSIC.example.test/library"))
        let second = try XCTUnwrap(URL(string: "https://music.example.test:443/other"))
        XCTAssertEqual(
            MobileServerEndpointPolicy.normalizedOrigin(of: first),
            MobileServerEndpointPolicy.normalizedOrigin(of: second)
        )
        XCTAssertNotEqual(
            MobileServerEndpointPolicy.normalizedOrigin(of: first),
            MobileServerEndpointPolicy.normalizedOrigin(of: URL(string: "https://music.example.test:8443")!)
        )
    }

    func testLegacyProductionOriginMigratesWithoutChangingProfileIdentity() throws {
        let legacy = try MobileServerEndpointPolicy.resolve("https://music.unblocked.mov")
        XCTAssertEqual(
            legacy.url.absoluteString,
            "https://resonance-core.blithe-haven-9710.chatgpt.site"
        )
        let context = MobileServerContext(
            origin: "https://music.unblocked.mov:443",
            profileID: "clerk-profile"
        )
        XCTAssertEqual(
            MobileServerEndpointPolicy.canonicalContext(context),
            MobileServerContext(
                origin: "https://resonance-core.blithe-haven-9710.chatgpt.site:443",
                profileID: "clerk-profile"
            )
        )
    }
}

final class MobileCompoundIdentityTests: XCTestCase {
    func testSameRemoteIDDoesNotAliasAcrossProfileOrOrigin() throws {
        let server = try XCTUnwrap(URL(string: "https://music.example.test"))
        let defaultContext = try XCTUnwrap(MobileServerEndpointPolicy.context(serverURL: server, profileID: "default"))
        let otherProfile = try XCTUnwrap(MobileServerEndpointPolicy.context(serverURL: server, profileID: "other"))
        let otherServer = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: URL(string: "https://other.example.test")!,
            profileID: "default"
        ))

        XCTAssertNotEqual(
            MobileRemoteIdentity(context: defaultContext, remoteID: "song-1"),
            MobileRemoteIdentity(context: otherProfile, remoteID: "song-1")
        )
        XCTAssertNotEqual(
            MobileRemoteIdentity(context: defaultContext, remoteID: "song-1"),
            MobileRemoteIdentity(context: otherServer, remoteID: "song-1")
        )
    }

    func testAssociationPolicyBlocksRebindingAcrossProfilesAndOrigins() throws {
        let server = try XCTUnwrap(URL(string: "https://music.example.test"))
        let originalContext = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: server,
            profileID: "original"
        ))
        let originalTrack = track(
            remoteID: "original-song",
            sourceServer: server.absoluteString,
            syncProfileID: originalContext.profileID
        )
        let targets = [
            try XCTUnwrap(MobileServerEndpointPolicy.context(serverURL: server, profileID: "other")),
            try XCTUnwrap(MobileServerEndpointPolicy.context(
                serverURL: URL(string: "https://other.example.test")!,
                profileID: "original"
            )),
        ]

        for targetContext in targets {
            XCTAssertThrowsError(try MobileRemoteAssociationPolicy.validateAdoption(
                track: originalTrack,
                targetContext: targetContext
            )) { thrown in
                guard let associationError = thrown as? MobileRemoteAssociationError,
                      case .contextConflict(let existingContext, let attemptedContext) = associationError else {
                    return XCTFail("Expected a context-conflict error, got \(thrown)")
                }
                XCTAssertEqual(existingContext, originalContext)
                XCTAssertEqual(attemptedContext, targetContext)
                XCTAssertTrue(thrown.localizedDescription.contains("Import a separate local copy"))
            }
        }
    }

    func testAssociationPolicyTreatsSourceAndProfileWithoutRemoteIDAsOwnership() throws {
        let server = try XCTUnwrap(URL(string: "https://music.example.test"))
        let existingContext = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: server,
            profileID: "original"
        ))
        let otherContext = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: server,
            profileID: "other"
        ))
        let sourceScopedTrack = track(
            remoteID: nil,
            sourceServer: server.absoluteString,
            syncProfileID: existingContext.profileID
        )

        XCTAssertNoThrow(try MobileRemoteAssociationPolicy.validateAdoption(
            track: sourceScopedTrack,
            targetContext: existingContext
        ))
        XCTAssertThrowsError(try MobileRemoteAssociationPolicy.validateAdoption(
            track: sourceScopedTrack,
            targetContext: otherContext
        )) { thrown in
            XCTAssertEqual(
                thrown as? MobileRemoteAssociationError,
                .contextConflict(existingContext: existingContext, targetContext: otherContext)
            )
        }
    }

    func testAssociationPolicyAllowsLocalTracksAndSameContextReconciliation() throws {
        let server = try XCTUnwrap(URL(string: "https://music.example.test"))
        let context = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: server,
            profileID: "default"
        ))
        let localTrack = track(remoteID: nil, sourceServer: nil, syncProfileID: nil)
        let profileOnlyTrack = track(
            remoteID: nil,
            sourceServer: nil,
            syncProfileID: "default"
        )
        let associatedTrack = track(
            remoteID: "old-song",
            sourceServer: server.absoluteString,
            syncProfileID: context.profileID
        )

        XCTAssertNoThrow(try MobileRemoteAssociationPolicy.validateAdoption(
            track: localTrack,
            targetContext: context
        ))
        XCTAssertNoThrow(try MobileRemoteAssociationPolicy.validateAdoption(
            track: profileOnlyTrack,
            targetContext: context
        ))
        XCTAssertNoThrow(try MobileRemoteAssociationPolicy.validateAdoption(
            track: associatedTrack,
            targetContext: context
        ))
    }

    func testAssociationPolicyFailsClosedForIncompleteExistingIdentity() throws {
        let context = try XCTUnwrap(MobileServerEndpointPolicy.context(
            serverURL: URL(string: "https://music.example.test")!,
            profileID: "default"
        ))
        let malformedTracks = [
            track(remoteID: "existing-song", sourceServer: nil, syncProfileID: "default"),
            track(
                remoteID: "existing-song",
                sourceServer: "https://music.example.test",
                syncProfileID: nil
            ),
            track(
                remoteID: nil,
                sourceServer: "https://music.example.test",
                syncProfileID: nil
            ),
        ]

        for malformedTrack in malformedTracks {
            XCTAssertThrowsError(try MobileRemoteAssociationPolicy.validateAdoption(
                track: malformedTrack,
                targetContext: context
            )) { thrown in
                XCTAssertEqual(
                    thrown as? MobileRemoteAssociationError,
                    .incompleteExistingIdentity(remoteID: malformedTrack.remoteID)
                )
            }
        }
    }

    func testManualUploadRecognizesCanonicalManagedTrackPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonanceAssociation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let track = track(
            remoteID: "existing-song",
            sourceServer: "https://music.example.test",
            syncProfileID: "default"
        )
        let managedURL = root.appendingPathComponent(track.relativePath)
        XCTAssertTrue(FileManager.default.createFile(atPath: managedURL.path, contents: Data([0x01])))
        let aliasURL = root.appendingPathComponent("selected.m4a")
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: managedURL)

        XCTAssertEqual(
            MobileManagedTrackUploadPolicy.managedTrack(
                matching: aliasURL,
                tracks: [track],
                musicDirectory: root
            )?.id,
            track.id
        )
        XCTAssertNil(MobileManagedTrackUploadPolicy.managedTrack(
            matching: root.deletingLastPathComponent().appendingPathComponent("untracked.m4a"),
            tracks: [track],
            musicDirectory: root
        ))
    }
}

final class MobileMissingServerUploadPolicyTests: XCTestCase {
    private let activeServer = URL(string: "https://music.example.test")!

    func testPlannerOnlyConsidersDownloadsFromActiveContext() throws {
        let otherProfileTrack = track(
            remoteID: "other-profile-id",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "other-profile"
        )
        let crossServerTrack = track(
            remoteID: "cross-server-id",
            sourceServer: "https://old.example.test",
            syncProfileID: "default"
        )
        let localOnlyTrack = track(remoteID: nil, sourceServer: nil, syncProfileID: nil)

        let plan = MobileMissingServerUploadPolicy.plan(
            tracks: [otherProfileTrack, crossServerTrack, localOnlyTrack],
            catalog: [],
            activeProfileID: "default",
            activeServerURL: activeServer
        )

        XCTAssertTrue(plan.uploadTrackIDs.isEmpty)
        XCTAssertTrue(plan.existingRemoteIDsByTrackID.isEmpty)
    }

    func testPlannerSuppressesLiveIDAndUploadsMissingActiveDownload() throws {
        let liveTrack = track(
            remoteID: "live-id",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "default"
        )
        let missingTrack = track(
            title: "Missing",
            remoteID: "missing-id",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "default"
        )
        let liveSong = try remoteSong(id: "live-id", title: "Renamed", artist: "Someone")

        let plan = MobileMissingServerUploadPolicy.plan(
            tracks: [liveTrack, missingTrack],
            catalog: [liveSong],
            activeProfileID: "default",
            activeServerURL: activeServer
        )

        XCTAssertEqual(plan.uploadTrackIDs, [missingTrack.id])
    }

    func testPlannerReconcilesHashButNeverMetadataAlone() throws {
        let matchingHashTrack = track(
            remoteID: "old-id",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "default",
            contentSHA256: String(repeating: "a", count: 64)
        )
        let matchingHashSong = try remoteSong(
            id: "new-id",
            title: "Renamed",
            artist: "Renamed",
            contentSHA256: String(repeating: "A", count: 64)
        )
        let metadataOnlyTrack = track(
            title: "Same title",
            artist: "Same artist",
            remoteID: "missing-metadata-id",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "default"
        )
        let metadataOnlySong = try remoteSong(
            id: "different-recording",
            title: metadataOnlyTrack.title,
            artist: metadataOnlyTrack.artist
        )

        let plan = MobileMissingServerUploadPolicy.plan(
            tracks: [matchingHashTrack, metadataOnlyTrack],
            catalog: [matchingHashSong, metadataOnlySong],
            activeProfileID: "default",
            activeServerURL: activeServer
        )

        XCTAssertEqual(plan.existingRemoteIDsByTrackID[matchingHashTrack.id], matchingHashSong.id)
        XCTAssertEqual(plan.uploadTrackIDs, [metadataOnlyTrack.id])
    }

    func testLocalImportOnlyTrustsRemoteAssociationInActiveContext() throws {
        let imported = spotifyTrack(title: "Imported song", artist: "Import artist")
        let crossServerTrack = track(
            title: imported.title,
            artist: imported.artist,
            remoteID: "collision",
            sourceServer: "https://old.example.test",
            syncProfileID: "default"
        )
        let collision = try remoteSong(id: "collision", title: "Other", artist: "Other")
        let untrusted = LocalImportExistingSongPolicy.match(
            spotifyTrack: imported,
            deviceTracks: [crossServerTrack],
            activeServerSongs: [collision],
            activeServerURL: activeServer,
            activeProfileID: "default"
        )
        XCTAssertEqual(untrusted.deviceTrackID, crossServerTrack.id)
        XCTAssertNil(untrusted.serverSongID)

        let trustedTrack = track(
            title: imported.title,
            artist: imported.artist,
            remoteID: "trusted",
            sourceServer: activeServer.absoluteString,
            syncProfileID: "default"
        )
        let trustedSong = try remoteSong(id: "trusted", title: "Server rename", artist: "Server artist")
        let trusted = LocalImportExistingSongPolicy.match(
            spotifyTrack: imported,
            deviceTracks: [trustedTrack],
            activeServerSongs: [trustedSong],
            activeServerURL: activeServer,
            activeProfileID: "default"
        )
        XCTAssertEqual(trusted.serverSongID, trustedSong.id)
    }
}

final class MobileDownloadIntegrityPolicyTests: XCTestCase {
    func testAcceptsMatchingSizeAndHash() throws {
        XCTAssertNoThrow(try MobileDownloadIntegrityPolicy.validate(
            expectedSize: 4,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSize: 4,
            actualSHA256: String(repeating: "a", count: 64)
        ))
    }

    func testRejectsSizeHashAndSafetyLimitMismatches() {
        XCTAssertThrowsError(try MobileDownloadIntegrityPolicy.validate(
            expectedSize: 4,
            expectedSHA256: nil,
            actualSize: 3,
            actualSHA256: "ignored"
        )) {
            XCTAssertEqual($0 as? MobileDownloadIntegrityError, .sizeMismatch(expected: 4, actual: 3))
        }
        XCTAssertThrowsError(try MobileDownloadIntegrityPolicy.validate(
            expectedSize: 4,
            expectedSHA256: String(repeating: "a", count: 64),
            actualSize: 4,
            actualSHA256: String(repeating: "b", count: 64)
        )) {
            XCTAssertEqual($0 as? MobileDownloadIntegrityError, .hashMismatch)
        }
        XCTAssertThrowsError(try MobileDownloadIntegrityPolicy.validate(
            expectedSize: 0,
            expectedSHA256: nil,
            actualSize: 11,
            actualSHA256: "ignored",
            maximumSize: 10
        )) {
            XCTAssertEqual($0 as? MobileDownloadIntegrityError, .tooLarge(actual: 11, limit: 10))
        }
        XCTAssertThrowsError(try MobileDownloadIntegrityPolicy.validate(
            expectedSize: 4,
            expectedSHA256: nil,
            actualSize: 4,
            actualSHA256: String(repeating: "a", count: 64)
        )) {
            XCTAssertEqual($0 as? MobileDownloadIntegrityError, .missingHash)
        }
    }

    func testByteLimitPolicyStopsDeclaredOrObservedOversizedResponses() {
        XCTAssertNil(MobileDownloadByteLimitPolicy.oversizedByteCount(
            totalBytesWritten: 10,
            totalBytesExpected: 20,
            maximumSize: 20
        ))
        XCTAssertEqual(MobileDownloadByteLimitPolicy.oversizedByteCount(
            totalBytesWritten: 1,
            totalBytesExpected: 21,
            maximumSize: 20
        ), 21)
        XCTAssertEqual(MobileDownloadByteLimitPolicy.oversizedByteCount(
            totalBytesWritten: 21,
            totalBytesExpected: NSURLSessionTransferSizeUnknown,
            maximumSize: 20
        ), 21)
    }
}

final class MobileTransferFailurePersistenceTests: XCTestCase {
    func testPerItemFailureAndRetryTargetRoundTrip() throws {
        let failure = MobileTransferFailure(
            operation: .download,
            item: "Track",
            reason: "Server returned HTTP 503.",
            retryTarget: .download(remoteSongID: "song-1")
        )

        let restored = try JSONDecoder().decode(
            MobileTransferFailure.self,
            from: JSONEncoder().encode(failure)
        )

        XCTAssertEqual(restored, failure)
    }
}

final class MobileLibraryNormalizationTests: XCTestCase {
    func testPlaybackCompletionWrapsTheLastQueueItemToTheFirst() {
        XCTAssertEqual(MobileQueueCompletionPolicy.nextIndex(count: 3, currentIndex: 2), 0)
        XCTAssertEqual(MobileQueueCompletionPolicy.nextIndex(count: 3, currentIndex: 0), 1)
        XCTAssertEqual(MobileQueueCompletionPolicy.nextIndex(count: 1, currentIndex: 0), 0)
        XCTAssertNil(MobileQueueCompletionPolicy.nextIndex(count: 0, currentIndex: 0))
    }

    func testPlaylistOrderMergeKeepsDeviceOnlyAndUnresolvedItemsInStableSlots() {
        XCTAssertEqual(
            MobilePlaylistOrderPolicy.merge(
                previous: ["remote-a", "local", "remote-b"],
                ordered: ["remote-b", "remote-c", "remote-a"],
                preserving: ["local"]
            ),
            ["remote-b", "local", "remote-c", "remote-a"]
        )
        XCTAssertEqual(
            MobilePlaylistOrderPolicy.merge(
                previous: ["remote-a", "unresolved", "remote-b"],
                ordered: ["remote-b", "remote-a"],
                preserving: ["unresolved"]
            ),
            ["remote-b", "unresolved", "remote-a"]
        )
    }

    func testRepairsDuplicateTrackPlaylistAndCompoundRemoteIdentifiers() throws {
        let duplicateTrackID = UUID()
        let duplicatePlaylistID = UUID()
        let server = "https://music.example.test"
        let first = track(
            id: duplicateTrackID,
            title: "First",
            remoteID: "same-remote",
            sourceServer: server,
            syncProfileID: "default"
        )
        let second = track(
            id: duplicateTrackID,
            title: "Second",
            remoteID: "same-remote",
            sourceServer: server,
            syncProfileID: "default"
        )
        let result = MobileCollectionNormalization.normalize(
            tracks: [first, second],
            playlists: [
                MobilePlaylist(id: duplicatePlaylistID, name: "Liked Songs", isSystem: true),
                MobilePlaylist(id: duplicatePlaylistID, name: "Liked Songs", isSystem: true),
            ],
            fallbackServerURL: URL(string: server)
        )

        XCTAssertEqual(Set(result.tracks.map(\.id)).count, 2)
        XCTAssertEqual(result.tracks.compactMap(\.remoteID), ["same-remote"])
        XCTAssertEqual(Set(result.playlists.map(\.id)).count, 2)
        XCTAssertEqual(result.playlists.filter(\.isSystem).count, 1)
        XCTAssertEqual(result.repairCount, 4)
    }

    func testDeduplicatesMalformedServerCollectionsWithoutDictionaryTrap() throws {
        let song = try remoteSong(id: "song", title: "Song", artist: "Artist")
        XCTAssertEqual(MobileCollectionNormalization.uniqueRemoteSongs([song, song]).count, 1)

        let playlist = MobileRemotePlaylist(id: UUID(), name: "List", songIDs: [])
        XCTAssertEqual(MobileCollectionNormalization.uniqueRemotePlaylists([playlist, playlist]).count, 1)
    }
}

final class MobilePlaybackSnapshotPolicyTests: XCTestCase {
    func testRestoresPlaylistQueueAndRemapsRemoteTrackByCompoundIdentity() throws {
        let server = URL(string: "https://music.example.test")!
        let context = try XCTUnwrap(MobileServerEndpointPolicy.context(serverURL: server, profileID: "default"))
        let oldID = UUID()
        let currentID = UUID()
        let playlistID = UUID()
        let currentTrack = track(
            id: currentID,
            remoteID: "remote",
            sourceServer: server.absoluteString,
            syncProfileID: "default"
        )
        let snapshot = MobilePlaybackSnapshot(
            version: MobilePlaybackSnapshot.currentVersion,
            queue: [
                MobilePlaybackQueueReference(
                    trackID: oldID,
                    remoteIdentity: MobileRemoteIdentity(context: context, remoteID: "remote")
                ),
            ],
            playlistID: playlistID,
            currentTrack: MobilePlaybackQueueReference(
                trackID: oldID,
                remoteIdentity: MobileRemoteIdentity(context: context, remoteID: "remote")
            ),
            history: [
                MobilePlaybackQueueReference(
                    trackID: oldID,
                    remoteIdentity: MobileRemoteIdentity(context: context, remoteID: "remote")
                ),
            ]
        )

        let restored = MobilePlaybackSnapshotPolicy.restore(
            snapshot: snapshot,
            tracks: [currentTrack],
            activeTrackIDs: [currentID],
            playlistIDs: [playlistID]
        )

        XCTAssertEqual(restored.queue, [currentID])
        XCTAssertEqual(restored.currentTrackID, currentID)
        XCTAssertEqual(restored.playlistID, playlistID)
        XCTAssertEqual(restored.history, [currentID])
    }

    func testRestoresVersionOneSnapshotWithoutShuffleHistory() throws {
        let trackID = UUID()
        let snapshot = MobilePlaybackSnapshot(
            version: 1,
            queue: [MobilePlaybackQueueReference(trackID: trackID, remoteIdentity: nil)],
            playlistID: nil,
            currentTrack: MobilePlaybackQueueReference(trackID: trackID, remoteIdentity: nil)
        )

        let restored = MobilePlaybackSnapshotPolicy.restore(
            snapshot: snapshot,
            tracks: [track(id: trackID, remoteID: nil, sourceServer: nil, syncProfileID: nil)],
            activeTrackIDs: [trackID],
            playlistIDs: []
        )

        XCTAssertEqual(restored.queue, [trackID])
        XCTAssertEqual(restored.currentTrackID, trackID)
        XCTAssertTrue(restored.history.isEmpty)
    }

    func testDropsUnavailableQueueEntriesAndInvalidPlaylistContext() {
        let available = UUID()
        let unavailable = UUID()
        let restored = MobilePlaybackSnapshotPolicy.restore(
            queue: [unavailable, available, available],
            playlistID: UUID(),
            currentTrackID: available,
            activeTrackIDs: [available],
            playlistIDs: []
        )
        XCTAssertEqual(restored.queue, [available])
        XCTAssertEqual(restored.currentTrackID, available)
        XCTAssertNil(restored.playlistID)
    }
}

final class MobileStoredLibraryRecoveryPolicyTests: XCTestCase {
    func testProfileStatesRoundTripIndependentlyByOriginAndProfile() throws {
        let firstContext = MobileServerContext(origin: "https://one.example.test:443", profileID: "default")
        let secondContext = MobileServerContext(origin: "https://one.example.test:443", profileID: "other")
        let firstPlaylistID = UUID()
        let secondPlaylistID = UUID()
        var stored = storedLibrary(serverURL: "https://one.example.test")
        stored.profileStates = [
            firstContext: MobileProfileSyncState(
                playlists: [MobilePlaylist(id: firstPlaylistID, name: "First")],
                playlistRevision: 2,
                knownRemotePlaylistIDs: [],
                dirtyPlaylistIDs: [firstPlaylistID],
                deletedPlaylistIDs: [],
                playlistSyncServerURL: nil,
                remoteLikedSongIDs: ["first-liked"],
                dirtyRemoteLikeSongIDs: ["first-liked"],
                likesDirty: true
            ),
            secondContext: MobileProfileSyncState(
                playlists: [MobilePlaylist(id: secondPlaylistID, name: "Second")],
                playlistRevision: 9,
                knownRemotePlaylistIDs: [secondPlaylistID],
                dirtyPlaylistIDs: [],
                deletedPlaylistIDs: [],
                playlistSyncServerURL: nil,
                remoteLikedSongIDs: ["second-liked"],
                dirtyRemoteLikeSongIDs: [],
                likesDirty: false
            ),
        ]

        let decoded = try JSONDecoder().decode(
            MobileStoredLibrary.self,
            from: JSONEncoder().encode(stored)
        )

        XCTAssertEqual(decoded.profileStates?[firstContext]?.dirtyPlaylistIDs, [firstPlaylistID])
        XCTAssertEqual(decoded.profileStates?[firstContext]?.dirtyRemoteLikeSongIDs, ["first-liked"])
        XCTAssertEqual(decoded.profileStates?[secondContext]?.playlistRevision, 9)
        XCTAssertEqual(decoded.profileStates?[secondContext]?.dirtyPlaylistIDs, [])
    }

    func testPrefersValidPrimary() throws {
        let primary = storedLibrary(serverURL: "https://primary.example.test")
        let backup = storedLibrary(serverURL: "https://backup.example.test")
        let recovered = MobileStoredLibraryRecoveryPolicy.recover(
            primaryData: try JSONEncoder().encode(primary),
            backupData: try JSONEncoder().encode(backup)
        )
        XCTAssertEqual(recovered.source, .primary)
        XCTAssertEqual(recovered.library, primary)
        XCTAssertFalse(recovered.primaryWasCorrupt)
    }

    func testRecoversBackupAndReportsCorruptPrimary() throws {
        let backup = storedLibrary(serverURL: "https://backup.example.test")
        let recovered = MobileStoredLibraryRecoveryPolicy.recover(
            primaryData: Data("not-json".utf8),
            backupData: try JSONEncoder().encode(backup)
        )
        XCTAssertEqual(recovered.source, .backup)
        XCTAssertEqual(recovered.library, backup)
        XCTAssertTrue(recovered.primaryWasCorrupt)
    }

    func testKeepsCorruptionVisibleWhenNoBackupExists() {
        let recovered = MobileStoredLibraryRecoveryPolicy.recover(
            primaryData: Data("not-json".utf8),
            backupData: nil
        )
        XCTAssertEqual(recovered.source, .empty)
        XCTAssertNil(recovered.library)
        XCTAssertTrue(recovered.primaryWasCorrupt)
    }
}

final class MobileConcurrencyPolicyTests: XCTestCase {
    func testUploadAndResponseGenerationPolicies() {
        XCTAssertFalse(MobileUploadBlockingPolicy.blocksUpload(
            isUploading: false,
            isDownloading: false,
            isSyncing: true,
            isRefreshingCatalog: true,
            isSyncingPlaylists: true
        ))
        XCTAssertTrue(MobileUploadBlockingPolicy.blocksUpload(
            isUploading: false,
            isDownloading: true,
            isSyncing: false,
            isRefreshingCatalog: false,
            isSyncingPlaylists: false
        ))
        XCTAssertFalse(MobilePlaylistSyncResponsePolicy.shouldApplyResponse(
            submittedMutationGeneration: 4,
            currentMutationGeneration: 5
        ))
        XCTAssertTrue(MobilePlaylistSyncResponsePolicy.shouldApplyResponse(
            submittedMutationGeneration: 5,
            currentMutationGeneration: 5
        ))
    }

    func testCatalogMergePreservesConcurrentUploadWithoutDuplication() throws {
        let catalogSong = try remoteSong(id: "catalog", title: "Catalog", artist: "Artist")
        let uploaded = try remoteSong(id: "uploaded", title: "Uploaded", artist: "Artist")
        let merged = MobileCatalogRefreshMergePolicy.merge(
            catalog: [catalogSong],
            uploadedSongsAwaitingCatalog: [uploaded.id: uploaded]
        )
        XCTAssertEqual(Set(merged.map(\.id)), [catalogSong.id, uploaded.id])

        let caughtUp = MobileCatalogRefreshMergePolicy.merge(
            catalog: [catalogSong, uploaded],
            uploadedSongsAwaitingCatalog: [uploaded.id: uploaded]
        )
        XCTAssertEqual(caughtUp.filter { $0.id == uploaded.id }.count, 1)
    }
}

private func track(
    id: UUID = UUID(),
    title: String = "Downloaded song",
    artist: String = "Test artist",
    remoteID: String?,
    sourceServer: String?,
    syncProfileID: String?,
    contentSHA256: String? = nil
) -> MobileTrack {
    MobileTrack(
        id: id,
        title: title,
        artist: artist,
        album: "Test album",
        duration: 180,
        relativePath: "\(id.uuidString).m4a",
        remoteID: remoteID,
        sourceServer: sourceServer,
        syncProfileID: syncProfileID,
        contentSHA256: contentSHA256
    )
}

private func remoteSong(
    id: String,
    title: String,
    artist: String,
    contentSHA256: String? = nil
) throws -> MobileRemoteSong {
    var payload: [String: Any] = [
        "id": id,
        "filename": "remote.m4a",
        "title": title,
        "artist": artist,
        "album": "Test album",
        "size": 1,
        "modified_at": "2026-08-05T00:00:00Z",
        "content_type": "audio/mp4",
        "download_url": "/api/v1/songs/\(id)/download",
        "stream_url": "/api/v1/songs/\(id)/stream",
        "duration_seconds": 180,
    ]
    if let contentSHA256 { payload["content_sha256"] = contentSHA256 }
    let data = try JSONSerialization.data(withJSONObject: payload)
    return try JSONDecoder().decode(MobileRemoteSong.self, from: data)
}

private func spotifyTrack(title: String, artist: String) -> LocalImportSpotifyTrack {
    LocalImportSpotifyTrack(
        provider: "spotify",
        type: "track",
        trackID: "test-track",
        title: title,
        artist: artist,
        album: "Test album",
        trackNumber: 1,
        durationSeconds: 180,
        artworkURL: nil,
        embedURL: "https://open.spotify.com/embed/track/test-track",
        sourceURL: "https://open.spotify.com/track/test-track"
    )
}

private func storedLibrary(serverURL: String) -> MobileStoredLibrary {
    MobileStoredLibrary(
        tracks: [],
        playlists: [MobilePlaylist(name: "Liked Songs", isSystem: true)],
        favorites: [],
        serverURL: serverURL,
        playlistRevision: 0,
        knownRemotePlaylistIDs: [],
        dirtyPlaylistIDs: [],
        deletedPlaylistIDs: [],
        playlistSyncServerURL: nil,
        syncProfileID: "default",
        syncProfileName: "Default",
        remoteLikedSongIDs: [],
        dirtyRemoteLikeSongIDs: [],
        likesDirty: false,
        clipRanges: [:],
        dirtyClipRangeKeys: [],
        deletedClipRangeKeys: []
    )
}
