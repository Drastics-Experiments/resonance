import Foundation
import Testing
@testable import LikedSongsFocus

@Suite("Resonance Preview regressions")
struct PreviewRegressionTests {
    @MainActor
    @Test
    func previewUpdaterNeverChecksProductionReleases() async {
        let manager = UpdateManager(updatesEnabled: false)

        await manager.checkForUpdates()

        #expect(!manager.hasUpdate)
        #expect(!manager.canInstall)
        #expect(manager.status == "Updates are disabled in Preview builds")
    }

    @Test
    func downloadedVideosUseTheirContentTypeOrExtension() {
        #expect(MediaKindClassifier.kind(contentType: "video/mp4", filename: "untitled.bin") == .video)
        #expect(MediaKindClassifier.kind(contentType: "application/octet-stream", filename: "movie.MOV") == .video)
        #expect(MediaKindClassifier.kind(contentType: "audio/mpeg", filename: "song.mp3") == .audio)
    }

    @Test
    func serverSongDecodesCatalogArtworkAndDuration() throws {
        let song = try JSONDecoder().decode(
            RemoteSong.self,
            from: Data(
                """
                {
                  "id": "catalog-song",
                  "filename": "catalog-song.mp3",
                  "title": "Catalog Song",
                  "artist": "Catalog Artist",
                  "album": "Catalog Album",
                  "size": 2048,
                  "modified_at": "2026-07-30T00:00:00Z",
                  "content_type": "audio/mpeg",
                  "duration_seconds": 259.265,
                  "artwork_url": "https://music.example.com/api/v1/songs/catalog-song/artwork?signature=signed",
                  "download_url": "/api/v1/songs/catalog-song/file",
                  "stream_url": "/api/v1/songs/catalog-song/stream"
                }
                """.utf8
            )
        )

        #expect(song.durationSeconds == 259.265)
        #expect(song.durationText == "4:19")
        #expect(song.artworkURL?.contains("/artwork?") == true)
    }

    @Test
    func profileSwitcherMatchesAnExistingProfileByNameOrID() {
        let profiles = [
            SyncProfile(id: "default", name: "Default", isDefault: true),
            SyncProfile(id: "drastic-id", name: "Drastic", isDefault: false),
        ]

        #expect(PlayerModel.syncProfile(matching: "drastic-id", in: profiles)?.id == "drastic-id")
        #expect(PlayerModel.syncProfile(matching: " drastic ", in: profiles)?.id == "drastic-id")
        #expect(PlayerModel.syncProfile(matching: "missing", in: profiles) == nil)
    }

    @Test
    func currentRecentlyAddedTrackDoesNotKeepTheHoverOverlayVisible() {
        #expect(
            !RecentlyAddedArtworkOverlayPolicy.shouldShow(
                isHovering: false,
                isCurrent: true
            )
        )
        #expect(
            RecentlyAddedArtworkOverlayPolicy.shouldShow(
                isHovering: true,
                isCurrent: false
            )
        )
    }

    @Test
    func recentlyAddedCardTogglesTheCurrentTrackInsteadOfRestartingIt() {
        #expect(
            RecentlyAddedArtworkActionPolicy.action(isCurrent: true) == .togglePlayback
        )
        #expect(
            RecentlyAddedArtworkActionPolicy.action(isCurrent: false) == .selectAndPlay
        )
    }

    @MainActor
    @Test
    func linkImportHidesTheIdleReadyCard() {
        let suiteName = "LinkImportIdleCardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let viewModel = MacLocalImportViewModel(model: model)

        #expect(viewModel.stage == .idle)
        #expect(!viewModel.showsStageCard)
    }

    @Test
    func linkImportShowsPreviewButtonsOnlyForMultipleAudioMatches() {
        #expect(
            LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                candidateCount: 2,
                mediaMode: .audio
            )
        )
        #expect(
            !LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                candidateCount: 1,
                mediaMode: .audio
            )
        )
        #expect(
            !LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                candidateCount: 2,
                mediaMode: .video
            )
        )
    }

    @Test
    func linkImportTransfersLeaveTheSheetAndUseTheGlobalBottomOverlay() {
        let backgroundStages: [LocalImportStage] = [
            .inspectingSource,
            .downloading,
            .processing,
            .savingLocal,
            .localComplete,
            .syncing,
        ]

        for stage in backgroundStages {
            #expect(LocalImportPresentationPolicy.showsGlobalTransfer(for: stage))
            #expect(LocalImportPresentationPolicy.continuesAfterSheetDismissal(for: stage))
        }

        #expect(!LocalImportPresentationPolicy.showsGlobalTransfer(for: .awaitingSelection))
        #expect(!LocalImportPresentationPolicy.continuesAfterSheetDismissal(for: .failed))
        #expect(!LocalImportPresentationPolicy.continuesAfterSheetDismissal(for: .cancelled))
        #expect(LocalImportPresentationPolicy.showsGlobalFailure(
            for: .failed,
            hasCompletedTrack: true,
            failedStage: .syncing
        ))
        #expect(!LocalImportPresentationPolicy.showsGlobalFailure(
            for: .failed,
            hasCompletedTrack: false,
            failedStage: .syncing
        ))
    }

    @Test
    func libraryRootUsesWindowsLayoutWhilePlaylistsKeepTheirHero() {
        #expect(!LibraryCollectionLayoutPolicy.showsHero(for: .library))
        #expect(LibraryCollectionLayoutPolicy.showsHero(for: .playlists))
    }

    @Test
    func recentlyAddedShelfKeepsEveryTrackInNewestFirstOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldest = Track(
            title: "Oldest",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .midnight,
            dateAdded: now.addingTimeInterval(-300)
        )
        let tiedZulu = Track(
            title: "Zulu",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .electric,
            dateAdded: now
        )
        let tiedAlpha = Track(
            title: "Alpha",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .golden,
            dateAdded: now
        )
        let middle = Track(
            title: "Middle",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .echoes,
            dateAdded: now.addingTimeInterval(-100)
        )

        let ordered = LibraryCollectionLayoutPolicy.recentlyAddedTracks(
            from: [oldest, tiedZulu, middle, tiedAlpha]
        )

        #expect(ordered.map(\.id) == [tiedAlpha.id, tiedZulu.id, middle.id, oldest.id])
        #expect(ordered.count == 4)
    }

    @Test
    func listeningHistoryDashboardAggregatesPersistedSessionsByDayAndSong() {
        let firstID = UUID()
        let first = Track(
            id: firstID,
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .midnight
        )
        let second = Track(
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artwork: .electric
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 30,
                hour: 12
            )
        )!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let outsideRange = calendar.date(byAdding: .day, value: -8, to: now)!
        let entries = [
            ListeningHistoryEntry(
                trackID: first.id,
                startedAt: yesterday,
                listenedSeconds: 120
            ),
            ListeningHistoryEntry(
                trackID: second.id,
                startedAt: now,
                listenedSeconds: 180
            ),
            ListeningHistoryEntry(
                trackID: first.id,
                startedAt: now,
                listenedSeconds: 60
            ),
            ListeningHistoryEntry(
                trackID: first.id,
                startedAt: outsideRange,
                listenedSeconds: 600
            ),
        ]

        let summary = ListeningHistoryCalendarSummary(
            entries: entries,
            tracks: [first, second],
            dayCount: 7,
            now: now,
            calendar: calendar
        )

        #expect(summary.days.count == 7)
        #expect(summary.granularity == .day)
        #expect(summary.totalSeconds == 360)
        #expect(summary.plays == 3)
        #expect(summary.todaySeconds == 240)
        #expect(summary.todayPlays == 2)
        #expect(summary.songs == 2)
        #expect(summary.days.suffix(2).map(\.seconds) == [120, 240])
        #expect(summary.mostActiveDay?.date == calendar.startOfDay(for: now))
        #expect(summary.songSeries.map(\.track.id) == [first.id, second.id])
        #expect(summary.songSeries.map(\.plays) == [2, 1])
        #expect(summary.songSeries.map(\.seconds) == [180, 180])
        #expect(summary.songSeries[0].days.suffix(2).map(\.seconds) == [120, 60])
        #expect(summary.songSeries[1].days.suffix(2).map(\.seconds) == [0, 180])

        let today = ListeningHistoryCalendarSummary(
            entries: entries,
            tracks: [first, second],
            dayCount: 1,
            now: now,
            calendar: calendar
        )
        #expect(today.granularity == .hour)
        #expect(today.days.count == 24)
        #expect(today.days[12].seconds == 240)
        #expect(today.days[12].plays == 2)

        let previousDay = ListeningHistoryCalendarSummary(
            entries: entries,
            tracks: [first, second],
            dayCount: 1,
            windowOffset: 1,
            now: now,
            calendar: calendar
        )
        #expect(previousDay.totalSeconds == 120)
        #expect(previousDay.plays == 1)
        #expect(previousDay.todayPlays == 2)

        let allTime = ListeningHistoryStatsSummary(
            entries: entries,
            tracks: [first, second]
        )
        #expect(allTime.totalSeconds == 960)
        #expect(allTime.plays == 4)
        #expect(allTime.songs == 2)
        #expect(allTime.topArtist == "Artist")
        #expect(allTime.songRanking.map(\.track.id) == [first.id, second.id])
        #expect(allTime.songRanking.map(\.seconds) == [780, 180])
    }

    @Test
    func listeningHistoryHoverUsesTheActualRenderedBarCenters() {
        let renderedCenters: [CGFloat] = [12, 31, 77, 143]

        #expect(
            ListeningHistoryChartHitTesting.nearestIndex(
                to: 10,
                positions: renderedCenters
            ) == 0
        )
        #expect(
            ListeningHistoryChartHitTesting.nearestIndex(
                to: 65,
                positions: renderedCenters
            ) == 2
        )
        #expect(
            ListeningHistoryChartHitTesting.nearestIndex(
                to: 138,
                positions: renderedCenters
            ) == 3
        )
        #expect(
            ListeningHistoryChartHitTesting.nearestIndex(
                to: 20,
                positions: []
            ) == nil
        )
    }

    @Test
    func serverCredentialsRoundTripInUserOnlyLocalStore() {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonancePreviewTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("server-credentials.json")
        let account = "credential-round-trip"
        let store = LocalServerCredentialStore(storeURL: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        #expect(store.save("preview-test-token", account: account))
        #expect(store.read(account: account) == "preview-test-token")
        #expect(store.save("preview-test-token", account: account))
        #expect(store.save("updated-preview-test-token", account: account))
        #expect(store.read(account: account) == "updated-preview-test-token")
        let permissions = try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(store.delete(account: account))
        #expect(store.read(account: account) == nil)
    }

    @Test
    func localCredentialStoreReadsTheLegacyPreviewFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonancePreviewTests-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("server-credentials.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"clientToken":"legacy-client","adminToken":"legacy-admin"}"#.utf8)
            .write(to: storeURL)

        let store = LocalServerCredentialStore(storeURL: storeURL)
        #expect(store.read(account: "music-server-client-token") == "legacy-client")
        #expect(store.read(account: "music-server-admin-token") == "legacy-admin")
    }

    @Test
    func localImporterAcceptsVideoTypes() {
        #expect(PlayerModel.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/movie.mp4")))
        #expect(PlayerModel.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/movie.mov")))
        #expect(PlayerModel.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/song.mp3")))
        #expect(PlayerModel.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/sound.aiff")))
        #expect(!PlayerModel.isSupportedMediaFile(URL(fileURLWithPath: "/tmp/notes.txt")))
    }

    @Test
    func storageSelectionDropsTracksHiddenByTheCurrentScope() {
        let downloadedID = UUID()
        let importedID = UUID()
        let selection: Set<UUID> = [downloadedID, importedID]

        #expect(
            StorageSelectionPolicy.visibleSelection(
                from: selection,
                visibleTrackIDs: [importedID]
            ) == [importedID]
        )
        #expect(
            StorageSelectionPolicy.visibleSelection(
                from: selection,
                visibleTrackIDs: []
            ).isEmpty
        )
    }

    @MainActor
    @Test
    func playlistCreationRejectsBlankAndDuplicateNames() throws {
        let suiteName = "PreviewRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )

        #expect(model.createPlaylist(named: "   ") == nil)
        #expect(model.createPlaylist(named: "Focus") != nil)
        #expect(model.createPlaylist(named: " focus ") == nil)
    }

    @MainActor
    @Test
    func forgettingServerCredentialsClearsEveryCredentialField() throws {
        let suiteName = "PreviewRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.example.com"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"
        model.serverMessage = "Connected"

        model.clearServerCredentials()

        #expect(model.serverURLString.isEmpty)
        #expect(model.serverToken.isEmpty)
        #expect(model.serverAdminToken.isEmpty)
        #expect(model.serverMessage == "Not connected")
    }

    @MainActor
    @Test
    func catalogMetadataRepairsAnExistingDownloadedTracksKind() throws {
        let suiteName = "PreviewRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let trackID = UUID()
        model.tracks = [
            Track(
                id: trackID,
                title: "Cached movie",
                artist: "Unknown Artist",
                album: "Server Library",
                duration: 10,
                kind: .audio,
                artwork: .midnight,
                remoteID: "movie-id"
            )
        ]

        let remoteSong = try JSONDecoder().decode(
            RemoteSong.self,
            from: Data(
                """
                {
                  "id": "movie-id",
                  "filename": "cached-audio-name.mp3",
                  "title": "Cached movie",
                  "artist": "Unknown Artist",
                  "album": "Server Library",
                  "size": 42,
                  "modified_at": "",
                  "content_type": "video/mp4",
                  "download_url": "/download/movie-id",
                  "stream_url": "/stream/movie-id"
                }
                """.utf8
            )
        )

        #expect(model.reconcileDownloadedMediaKinds(with: [remoteSong]))
        #expect(model.tracks.first?.id == trackID)
        #expect(model.tracks.first?.kind == .video)
    }
}
