import AVFoundation
import AppKit
import Foundation
import Testing
@testable import Resonance

@Suite("Resonance Preview regressions")
struct PreviewRegressionTests {
    @Test
    func profilePicturesAreScopedToTheCanonicalServerAndProfile() {
        let defaultScope = ProfilePictureScope.contextKey(
            serverURL: "https://MUSIC.example/library/",
            profileID: "  "
        )
        #expect(defaultScope == "https://music.example#profile=default")
        #expect(ProfilePictureScope.contextKey(
            serverURL: "https://music.example/another-path",
            profileID: "family"
        ) == "https://music.example#profile=family")
        let filename = ProfilePictureScope.filename(
            serverURL: "https://music.example",
            profileID: "family"
        )
        #expect(filename.count == 68)
        #expect(filename.hasSuffix(".jpg"))
        #expect(filename.dropLast(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test
    func nativeMenuCommandsUseStableNotificationRoutes() {
        #expect(Notification.Name.focusMusicSearch.rawValue == "focusMusicSearch")
        #expect(Notification.Name.newMusicPlaylist.rawValue == "newMusicPlaylist")
        #expect(Notification.Name.focusMusicSearch != .newMusicPlaylist)
        #expect(Notification.Name.openResonanceSettings.rawValue == "openResonanceSettings")
        #expect(Notification.Name.openClipEditor.rawValue == "openClipEditor")
    }

    @Test
    func discordIPCUsesValidatedApplicationIDsAndDocumentedSocketPaths() throws {
        #expect(MacDiscordRPCClient.validApplicationID(" 123456789012345678 ") == "123456789012345678")
        #expect(MacDiscordRPCClient.validApplicationID("not-an-id") == nil)
        #expect(MacDiscordRPCClient.socketPaths(environment: ["TMPDIR": "/private/tmp/resonance-test"]).prefix(2) == [
            "/private/tmp/resonance-test/discord-ipc-0",
            "/private/tmp/resonance-test/discord-ipc-1",
        ])

        let frame = try #require(DiscordIPCFrame.encode(
            opcode: 0,
            payload: ["v": 1, "client_id": "123456789012345678"]
        ))
        let header = try #require(DiscordIPCFrame.decodeHeader(frame))
        #expect(header.opcode == 0)
        #expect(header.length == frame.count - 8)
    }

    @Test
    func discordPresenceClearsWhilePausedAndUsesTrustedAlbumArtwork() throws {
        let paused = DiscordPresencePayload(
            title: "Night Drive",
            artist: "Resonance",
            album: "After Dark",
            playing: false,
            position: 12,
            duration: 180,
            artworkURL: "https://i.scdn.co/image/cover"
        )
        #expect(paused.rpcActivity(now: 1_000) == nil)

        let playing = DiscordPresencePayload(
            title: "Night Drive",
            artist: "Resonance",
            album: "After Dark",
            playing: true,
            position: 12,
            duration: 180,
            artworkURL: "https://i.scdn.co/image/cover"
        )
        let activity = try #require(playing.rpcActivity(now: 1_000))
        let assets = try #require(activity["assets"] as? [String: String])
        let timestamps = try #require(activity["timestamps"] as? [String: Int])
        #expect(assets["large_image"] == "https://i.scdn.co/image/cover")
        #expect(assets["large_text"] == nil)
        #expect(timestamps["start"] == 988)
        #expect(timestamps["end"] == 1_168)
        #expect(DiscordArtworkAsset.externalURL(from: "https://attacker.example/cover.jpg") == nil)
        #expect(DiscordArtworkAsset.externalURL(
            from: "https://i.ytimg.com/vi/jNQXAC9IVRw/maxresdefault.jpg"
        ) == "https://img.youtube.com/vi/jNQXAC9IVRw/maxresdefault.jpg")

        let legacyYouTubeTrack = Track(
            title: "Video Song",
            artist: "Uploader",
            album: "Imported",
            duration: 60,
            artwork: .midnight,
            sourceURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        )
        #expect(DiscordArtworkAsset.externalURL(for: legacyYouTubeTrack) == "https://img.youtube.com/vi/jNQXAC9IVRw/maxresdefault.jpg")
    }

    @Test
    func linkImporterChromeUsesProviderRailAndIconOnlyMediaModes() {
        #expect(MacLocalImportChrome.providerOrder == [.youtube, .spotify, .soundcloud])
        #expect(MacLocalImportChrome.mediaIcon(for: .audio) == "music.note")
        #expect(MacLocalImportChrome.mediaIcon(for: .video) == "play.rectangle.fill")
    }

    @Test
    func minimalServerCatalogKeepsMetadataOnDevice() throws {
        let data = try #require("""
        {
          "id": "saved-song-uuid",
          "source_url": "https://media.example/Local%20Title.m4a?token=preserved",
          "title": "   ",
          "artist": "",
          "download_url": "/api/v1/songs/saved-song-uuid/file",
          "stream_url": "/api/v1/songs/saved-song-uuid/stream"
        }
        """.data(using: .utf8))
        let song = try JSONDecoder().decode(RemoteSong.self, from: data)

        #expect(song.id == "saved-song-uuid")
        #expect(song.filename == "Local Title.m4a")
        #expect(song.title == "Resolving metadata…")
        #expect(song.artist == "Automatic lookup")
        #expect(song.album == "Link only")
        #expect(song.size == 0)
        #expect(song.sourceURL == "https://media.example/Local%20Title.m4a?token=preserved")
        #expect(song.mediaKind == "audio")
        #expect(song.isSourceLinkRecord)
        #expect(song.isMetadataLoading)

        let encoded = try JSONEncoder().encode(MacSourceImportRequest(
            sourcePageURL: "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        ))
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "source_page_url"])
    }

    @MainActor
    @Test
    func macDesktopPreferencesPersistBackgroundPresenceAndKeybinds() throws {
        let suiteName = "PreviewRegressionTests.desktop.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = MacDesktopPreferences(defaults: defaults)

        preferences.runInBackground = true
        preferences.discordRichPresence = true
        preferences.setKeybind("⌘⇧P", for: .togglePlayback)

        #expect(defaults.bool(forKey: MacDesktopPreferenceKeys.runInBackground))
        #expect(defaults.bool(forKey: MacDesktopPreferenceKeys.discordRichPresence))
        #expect(preferences.keybinds[.togglePlayback] == "⌘⇧P")
        #expect(MacDesktopPreferences.configuredDiscordApplicationID(
            environment: ["RESONANCE_DISCORD_CLIENT_ID": "123456789012345678"],
            bundleValue: nil
        ) == "123456789012345678")
        #expect(MacDesktopPreferences.configuredDiscordApplicationID(
            environment: [:],
            bundleValue: "223456789012345678"
        ) == "223456789012345678")
        #expect(MacDesktopPreferences.configuredDiscordApplicationID(
            environment: [:],
            bundleValue: nil
        ) == "1535574125395841154")
        preferences.stop()
    }

    @Test
    func previewBundlePolicyRecognizesOnlyExpectedIdentifiers() {
        #expect(CredentialStorePolicy.isPreviewBundle(
            bundleIdentifier: CredentialStorePolicy.previewBundleIdentifier
        ))
        #expect(CredentialStorePolicy.isPreviewBundle(
            bundleIdentifier: CredentialStorePolicy.previewBundleIdentifier + ".worktree.w0123456789ab"
        ))
        #expect(!CredentialStorePolicy.isPreviewBundle(
            bundleIdentifier: CredentialStorePolicy.previewBundleIdentifier + ".untrusted"
        ))
        #expect(!CredentialStorePolicy.isPreviewBundle(
            bundleIdentifier: "com.gavindietrich.Resonance"
        ))
        #expect(!CredentialStorePolicy.isPreviewBundle(bundleIdentifier: nil))
    }

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
    func fullscreenVideoActionRequiresAnInstalledLocalVideo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonanceVideoPolicyTests-\(UUID().uuidString)", isDirectory: true)
        let videoURL = directory.appendingPathComponent("installed-video.mp4")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0]).write(to: videoURL)

        let installedVideo = Track(
            title: "Installed video",
            artist: "Artist",
            album: "Album",
            duration: 60,
            kind: .video,
            artwork: .midnight,
            fileURL: videoURL
        )
        let audioFile = Track(
            title: "Audio",
            artist: "Artist",
            album: "Album",
            duration: 60,
            kind: .audio,
            artwork: .midnight,
            fileURL: videoURL
        )
        let missingVideo = Track(
            title: "Missing video",
            artist: "Artist",
            album: "Album",
            duration: 60,
            kind: .video,
            artwork: .midnight,
            fileURL: directory.appendingPathComponent("missing.mp4")
        )

        #expect(installedVideo.installedVideoURL == videoURL)
        #expect(audioFile.installedVideoURL == nil)
        #expect(missingVideo.installedVideoURL == nil)
    }

    @Test
    func fullScreenNowPlayingColumnsAreDerivedOnlyFromTheViewport() {
        let standard = NowPlayingLayoutPolicy.metrics(in: CGSize(width: 1_200, height: 750))
        let compact = NowPlayingLayoutPolicy.metrics(in: CGSize(width: 860, height: 620))

        #expect(!standard.isCompact)
        #expect(abs(standard.artworkSize - 486) < 0.001)
        #expect(abs(standard.detailsWidth - 534) < 0.001)
        #expect(standard.contentHeight == 520)

        #expect(compact.isCompact)
        #expect(abs(compact.artworkSize - 326.8) < 0.001)
        #expect(abs(compact.detailsWidth - 411.2) < 0.001)
        #expect(compact.contentHeight == 400)
    }

    @Test
    func fullscreenVideoExpandsIntoAnEdgeInsetPlaybackSurface() {
        let standardArtwork = InstalledVideoLayoutPolicy.artworkFrame(
            in: CGSize(width: 1_200, height: 750)
        )
        let standardVideo = InstalledVideoLayoutPolicy.videoFrame(
            in: CGSize(width: 1_200, height: 750)
        )
        let tinyVideo = InstalledVideoLayoutPolicy.videoFrame(
            in: CGSize(width: 42, height: 50)
        )

        #expect(InstalledVideoLayoutPolicy.edgeInset == 38)
        #expect(InstalledVideoLayoutPolicy.artworkCornerRadius == 22)
        #expect(InstalledVideoLayoutPolicy.videoCornerRadius == 18)
        #expect(InstalledVideoLayoutPolicy.geometryDuration == 0.40)
        #expect(InstalledVideoLayoutPolicy.revealDuration == 0.14)
        #expect(InstalledVideoLayoutPolicy.chromeFadeDuration == 0.30)
        #expect(InstalledVideoLayoutPolicy.exitArtworkRestoreLeadDuration == 0.19)
        #expect(InstalledVideoLayoutPolicy.chromeRestoreLeadDuration == 0.12)
        #expect(abs(InstalledVideoLayoutPolicy.exitArtworkRestoreDelay(reduceMotion: false) - 0.21) < 0.001)
        #expect(InstalledVideoLayoutPolicy.exitArtworkRestoreDelay(reduceMotion: true) == 0)
        #expect(InstalledVideoLayoutPolicy.duration(0.40, reduceMotion: false) == 0.40)
        #expect(InstalledVideoLayoutPolicy.duration(0.40, reduceMotion: true) == 0)
        #expect(abs(standardArtwork.minX - 70) < 0.001)
        #expect(abs(standardArtwork.minY - 138) < 0.001)
        #expect(abs(standardArtwork.width - 486) < 0.001)
        #expect(abs(standardArtwork.height - 486) < 0.001)
        #expect(standardVideo == CGRect(x: 38, y: 38, width: 1_124, height: 674))
        #expect(tinyVideo == CGRect(x: 38, y: 38, width: 1, height: 1))
    }

    @Test
    func installedVideoArtworkBadgeAppearsForHoverAndKeyboardFocus() {
        #expect(!InstalledVideoLaunchBadgePolicy.isVisible(
            hasVideo: false,
            isHovered: true,
            isFocused: true
        ))
        #expect(InstalledVideoLaunchBadgePolicy.isVisible(
            hasVideo: true,
            isHovered: true,
            isFocused: false
        ))
        #expect(InstalledVideoLaunchBadgePolicy.isVisible(
            hasVideo: true,
            isHovered: false,
            isFocused: true
        ))
        #expect(!InstalledVideoLaunchBadgePolicy.isVisible(
            hasVideo: true,
            isHovered: false,
            isFocused: false
        ))
        #expect(InstalledVideoLaunchBadgePolicy.size(for: 200) == 44)
        #expect(abs(InstalledVideoLaunchBadgePolicy.size(for: 486) - 58.32) < 0.001)
        #expect(InstalledVideoLaunchBadgePolicy.size(for: 700) == 62)
    }

    @MainActor
    @Test
    func fullscreenVideoUsesNativeClippingAndSuspendsTheBlurredArtworkBackdrop() {
        #expect(InstalledVideoRenderingPolicy.showsArtworkBackdrop(
            hasVideoSession: false,
            isRestoringChrome: false
        ))
        #expect(!InstalledVideoRenderingPolicy.showsArtworkBackdrop(
            hasVideoSession: true,
            isRestoringChrome: false
        ))
        #expect(InstalledVideoRenderingPolicy.showsArtworkBackdrop(
            hasVideoSession: true,
            isRestoringChrome: true
        ))

        let playerView = AspectFitPlayerContainerView(frame: .zero)
        playerView.cornerRadius = InstalledVideoLayoutPolicy.videoCornerRadius
        #expect(playerView.layer is AVPlayerLayer)
        #expect(playerView.layer?.cornerRadius == InstalledVideoLayoutPolicy.videoCornerRadius)
        #expect(playerView.layer?.masksToBounds == true)
    }

    @Test
    func fullscreenVideoKeepsAudioAuthoritativeWithoutSteadyStateReseeking() {
        #expect(InstalledVideoSyncPolicy.audioRemainsAudibleOwner)
        #expect(InstalledVideoSyncPolicy.videoRemainsMuted)
        #expect(!InstalledVideoSyncPolicy.allowsSteadyStateReseeking)
        #expect(InstalledVideoSyncPolicy.forcedSeekThreshold == 0.005)
        #expect(InstalledVideoSyncPolicy.rateUpdateInterval == .milliseconds(250))
        #expect(InstalledVideoSyncPolicy.startupSeekTolerance == 0.50)
        #expect(InstalledVideoSyncPolicy.startupTarget(
            audioPosition: 10,
            audioRate: 1.5,
            isPlaying: true
        ) == 10.3)
        #expect(InstalledVideoSyncPolicy.startupTarget(
            audioPosition: 10,
            audioRate: 1.5,
            isPlaying: false
        ) == 10)
        #expect(InstalledVideoSyncPolicy.catchUpRate(
            audioRate: 1,
            audioPosition: 10,
            videoPosition: 9.5
        ) > 1)
        #expect(InstalledVideoSyncPolicy.catchUpRate(
            audioRate: 1,
            audioPosition: 10,
            videoPosition: 10.5
        ) < 1)
        #expect(InstalledVideoSyncPolicy.catchUpRate(
            audioRate: 1.5,
            audioPosition: 10,
            videoPosition: 10.02
        ) == 1.5)
        #expect(!InstalledVideoSyncPolicy.hasMaterialDrift(
            audioPosition: 12.5,
            videoPosition: 12.504
        ))
        #expect(InstalledVideoSyncPolicy.hasMaterialDrift(
            audioPosition: 12.5,
            videoPosition: 12.51
        ))
        #expect(InstalledVideoSyncPolicy.shouldResumeAfterSeek(
            audioIsPlaying: true,
            trackMatches: true,
            videoIsVisible: true,
            isClosing: false
        ))
    }

    @Test
    func fullscreenVideoControlsClampSeekProgressAndUseWindowsTiming() {
        #expect(InstalledVideoControlsPolicy.autoHideDelay == 2.2)
        #expect(InstalledVideoControlsPolicy.progress(position: 30, duration: 120) == 0.25)
        #expect(InstalledVideoControlsPolicy.progress(position: -1, duration: 120) == 0)
        #expect(InstalledVideoControlsPolicy.progress(position: 180, duration: 120) == 1)
        #expect(InstalledVideoControlsPolicy.progress(position: .nan, duration: 120) == 0)
        #expect(InstalledVideoControlsPolicy.seekTime(progress: 0.5, duration: 120) == 60)
        #expect(InstalledVideoControlsPolicy.seekTime(progress: -1, duration: 120) == 0)
        #expect(InstalledVideoControlsPolicy.seekTime(progress: 2, duration: 120) == 120)
        #expect(InstalledVideoControlsPolicy.seekTime(progress: .nan, duration: 120) == 0)
    }

    @Test
    func fullScreenTitleMarqueeOnlyMovesByTheRenderedOverflow() {
        #expect(NowPlayingMarqueePolicy.travel(contentWidth: 420, availableWidth: 500) == 0)
        #expect(NowPlayingMarqueePolicy.duration(for: 0) == 0)

        let travel = NowPlayingMarqueePolicy.travel(contentWidth: 820, availableWidth: 540)
        #expect(travel == 280)
        let loopDistance = NowPlayingMarqueePolicy.loopDistance(contentWidth: 820)
        #expect(loopDistance == 876)
        #expect(abs(NowPlayingMarqueePolicy.duration(for: loopDistance) - (876.0 / 28.0)) < 0.001)
        #expect(NowPlayingMarqueePolicy.duration(for: 28) == 8)
        #expect(NowPlayingMarqueePolicy.offset(progress: 0, contentWidth: 820) == 0)
        #expect(NowPlayingMarqueePolicy.offset(progress: 0.5, contentWidth: 820) == -438)
        #expect(NowPlayingMarqueePolicy.offset(progress: 1, contentWidth: 820) == -876)
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
                  "source_url": "https://media.example/catalog-song.mp3?token=preserved",
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
        #expect(song.sourceURL == "https://media.example/catalog-song.mp3?token=preserved")
        #expect(!song.isMetadataLoading)
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

    @MainActor
    @Test
    func linkImportKeepsVideoSelectedForPlainTextSearches() {
        let suiteName = "LinkImportVideoSearchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let viewModel = MacLocalImportViewModel(model: model)

        viewModel.source = "Test Song Test Artist"
        viewModel.mediaMode = .video
        viewModel.normalizeMediaModeForSource()
        #expect(viewModel.mediaMode == .video)
        #expect(viewModel.resolveButtonTitle == "Search Videos")

        viewModel.source = "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"
        viewModel.normalizeMediaModeForSource()
        #expect(viewModel.mediaMode == .audio)
    }

    @MainActor
    @Test
    func linkImportUploadEligibilityNeedsAdminCredentialsButNotCatalogCredentials() {
        let suiteName = "LinkImportUploadEligibilityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = ""
        model.serverAdminToken = "admin-token"
        let viewModel = MacLocalImportViewModel(model: model)

        #expect(viewModel.canSync)
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
            LocalImportCandidatePreviewPolicy.showsPreviewButtons(
                candidateCount: 1,
                mediaMode: .audio,
                isPlaylist: true
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

        for stage in [
            LocalImportStage.inspectingSource,
            .downloading,
            .processing,
            .savingLocal,
            .localComplete,
        ] {
            #expect(!LocalImportPresentationPolicy.showsGlobalTransfer(
                for: stage,
                downloadStarted: false
            ))
        }
        #expect(LocalImportPresentationPolicy.showsGlobalTransfer(
            for: .syncing,
            downloadStarted: false
        ))

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

    @MainActor
    @Test
    func playlistImportDownloadsEveryItemBeforeStartingUploads() async throws {
        var events: [String] = []
        let downloaded = try await LocalImportPlaylistBatchPipeline.run(
            items: ["first", "skipped", "last"],
            download: { _, _, item in
                events.append("download:\(item)")
                return item == "skipped" ? nil : item
            },
            beforeUpload: { items in
                events.append("save:\(items.joined(separator: ","))")
            },
            upload: { _, _, item in
                events.append("upload:\(item)")
            }
        )

        #expect(downloaded == ["first", "last"])
        #expect(events == [
            "download:first",
            "download:skipped",
            "download:last",
            "save:first,last",
            "upload:first",
            "upload:last",
        ])
        #expect(LocalImportBatchProgressPolicy.overallProgress(
            completedItems: 1,
            totalItems: 4,
            currentItemProgress: 0.5
        ) == 0.375)
        #expect(LocalImportBatchProgressPolicy.overallProgress(
            completedItems: 2,
            totalItems: 4,
            currentItemProgress: nil
        ) == 0.5)
        let transferMatches = [
            LocalImportExistingSongMatch(deviceTrackID: UUID(), serverSongID: "remote-1"),
            LocalImportExistingSongMatch(deviceTrackID: UUID(), serverSongID: "remote-2"),
            LocalImportExistingSongMatch(deviceTrackID: UUID(), serverSongID: nil),
        ]
        #expect(LocalImportBatchProgressPolicy.plannedTransferCount(
            matches: transferMatches,
            requiresTransfer: { !$0.isOnDevice }
        ) == 0)
        #expect(LocalImportBatchProgressPolicy.plannedTransferCount(
            matches: transferMatches,
            requiresTransfer: { !$0.isOnServer }
        ) == 1)

        var candidateAttempts: [String] = []
        let selected = try await LocalImportCandidateFallbackPolicy.firstSuccessful(
            candidates: ["broken-primary", "working-fallback", "unused"]
        ) { candidate in
            candidateAttempts.append(candidate)
            if candidate == "broken-primary" { throw URLError(.cannotDecodeContentData) }
            return candidate
        }
        #expect(selected == "working-fallback")
        #expect(candidateAttempts == ["broken-primary", "working-fallback"])
    }

    @Test
    func playlistImportRecognizesExistingDeviceAndActiveServerSongs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImportExistingSongPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("existing.m4a")
        try Data("existing".utf8).write(to: localFile)

        let spotify = LocalImportSpotifyTrack(
            provider: "spotify",
            type: "track",
            trackID: "4PTG3Z6ehGkBFwjybzWkR8",
            title: "Existing Song",
            artist: "First Artist & Second Artist",
            album: "Album",
            trackNumber: 1,
            durationSeconds: 213,
            artworkURL: nil,
            embedURL: "https://open.spotify.com/embed/track/4PTG3Z6ehGkBFwjybzWkR8",
            sourceURL: "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"
        )
        let local = Track(
            title: "Old Local Metadata",
            artist: "Unknown Artist",
            album: "Imported",
            duration: 999,
            artwork: .midnight,
            fileURL: localFile,
            sourceURL: spotify.sourceURL
        )
        let server = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "existing-server-song",
              "filename": "existing.m4a",
              "title": "Existing Song",
              "artist": "Second Artist / First Artist",
              "album": "Album",
              "size": 8,
              "modified_at": "2026-08-05T00:00:00Z",
              "content_type": "audio/mp4",
              "duration_seconds": 214,
              "download_url": "/api/v1/songs/existing-server-song/file",
              "stream_url": "/api/v1/songs/existing-server-song/stream"
            }
            """.utf8
        ))

        let match = LocalImportExistingSongPolicy.match(
            spotifyTrack: spotify,
            deviceTracks: [local],
            activeServerSongs: [server]
        )
        #expect(match.deviceTrackID == local.id)
        #expect(match.serverSongID == server.id)

        let wrongDuration = Track(
            title: spotify.title,
            artist: spotify.artist,
            album: "Album",
            duration: 240,
            artwork: .echoes,
            fileURL: localFile
        )
        let durationMismatch = LocalImportExistingSongPolicy.match(
            spotifyTrack: spotify,
            deviceTracks: [wrongDuration],
            activeServerSongs: []
        )
        #expect(durationMismatch.deviceTrackID == nil)
    }

    @Test
    func playlistVideoSelectionDoesNotReuseAudioOnlyExistingSongs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalImportVideoMatchPolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let localFile = root.appendingPathComponent("existing.m4a")
        try Data("existing".utf8).write(to: localFile)
        let sourceURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        let playlistTrack = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: "jNQXAC9IVRw",
            title: "Existing Song",
            artist: "Resonance",
            album: nil,
            trackNumber: 1,
            durationSeconds: 60,
            artworkURL: nil,
            embedURL: "",
            sourceURL: sourceURL
        )
        let audioLocal = Track(
            title: playlistTrack.title,
            artist: playlistTrack.artist,
            album: "Imported",
            duration: 60,
            kind: .audio,
            artwork: .midnight,
            fileURL: localFile,
            sourceURL: sourceURL
        )
        let audioServer = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "audio-server-song",
              "filename": "existing.m4a",
              "title": "Existing Song",
              "artist": "Resonance",
              "album": "Imported",
              "size": 8,
              "modified_at": "2026-08-05T00:00:00Z",
              "content_type": "audio/mp4",
              "media_kind": "audio",
              "duration_seconds": 60,
              "download_url": "/api/v1/songs/audio-server-song/file",
              "stream_url": "/api/v1/songs/audio-server-song/stream"
            }
            """.utf8
        ))

        let selectedMode: LocalImportMediaMode = .video
        let match = LocalImportExistingSongPolicy.match(
            spotifyTrack: playlistTrack,
            deviceTracks: [audioLocal],
            activeServerSongs: [audioServer],
            mediaMode: selectedMode
        )

        #expect(selectedMode == .video)
        #expect(match.deviceTrackID == nil)
        #expect(match.serverSongID == nil)
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
    func listeningHistoryDashboardAggregatesPersistedSessionsByDayAndSong() throws {
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

        let serverOnlyID = UUID()
        let duplicateServerOnlyID = UUID()
        let serverOnlyEntries = [
            ListeningHistoryEntry(
                trackID: serverOnlyID,
                startedAt: now,
                listenedSeconds: 90,
                syncProfileID: "default",
                remoteSongID: "server-only-song",
                title: "Server Only",
                artist: "Remote Artist",
                album: "Remote Album",
                duration: 240,
                originatedOnThisDevice: false
            ),
            ListeningHistoryEntry(
                trackID: duplicateServerOnlyID,
                startedAt: now,
                listenedSeconds: 30,
                syncProfileID: "default",
                remoteSongID: "server-only-song",
                title: "Server Only",
                artist: "Remote Artist",
                album: "Remote Album",
                duration: 240,
                originatedOnThisDevice: false
            ),
        ]
        let serverOnlySummary = ListeningHistoryCalendarSummary(
            entries: serverOnlyEntries,
            tracks: [],
            dayCount: 7,
            now: now,
            calendar: calendar
        )
        #expect(serverOnlySummary.songs == 1)
        #expect(serverOnlySummary.songSeries.count == 1)
        #expect(serverOnlySummary.songSeries[0].track.title == "Server Only")
        #expect(serverOnlySummary.songSeries[0].track.fileURL == nil)
        #expect(serverOnlySummary.songSeries[0].seconds == 120)

        let serverOnlyStats = ListeningHistoryStatsSummary(
            entries: serverOnlyEntries,
            tracks: []
        )
        #expect(serverOnlyStats.songs == 1)
        #expect(serverOnlyStats.topArtist == "Remote Artist")
        #expect(serverOnlyStats.songRanking.first?.track.album == "Remote Album")
        #expect(serverOnlyStats.songRanking.first?.seconds == 120)

        let catalogSong = try JSONDecoder().decode(RemoteSong.self, from: Data(
            #"{"id":"catalog-song","filename":"catalog-song.m4a","title":"Catalog title","artist":"Catalog artist","album":"Catalog album","size":0,"modified_at":"now","content_type":"audio/mp4","duration_seconds":300,"artwork_url":"https://music.example/api/v1/songs/catalog-song/artwork?token=signed","download_url":"/api/v1/songs/catalog-song/file","stream_url":"/api/v1/songs/catalog-song/stream"}"#.utf8
        ))
        let catalogOnlyEntry = ListeningHistoryEntry(
            trackID: UUID(),
            startedAt: now,
            listenedSeconds: 60,
            syncProfileID: "default",
            remoteSongID: "catalog-song",
            originatedOnThisDevice: false
        )
        let catalogSummary = ListeningHistoryStatsSummary(
            entries: [catalogOnlyEntry],
            tracks: [],
            remoteSongs: [catalogSong]
        )
        #expect(catalogSummary.songRanking.first?.track.title == "Catalog title")
        #expect(catalogSummary.songRanking.first?.track.artist == "Catalog artist")
        #expect(catalogSummary.songRanking.first?.track.album == "Catalog album")
        #expect(catalogSummary.songRanking.first?.track.artworkURL == catalogSong.artworkURL)
        #expect(catalogSummary.plays == 1)

        let placeholderCatalogSong = try JSONDecoder().decode(RemoteSong.self, from: Data(
            #"{"id":"placeholder-song","title":"Resolving metadata…","artist":"Automatic lookup","album":"Link only","source_url":"https://open.spotify.com/track/example","download_url":"/api/v1/songs/placeholder-song/file","stream_url":"/api/v1/songs/placeholder-song/stream"}"#.utf8
        ))
        #expect(placeholderCatalogSong.isMetadataLoading)
        let snapshotEntry = ListeningHistoryEntry(
            trackID: UUID(),
            startedAt: now,
            listenedSeconds: 60,
            syncProfileID: "default",
            remoteSongID: "placeholder-song",
            title: "Snapshot title",
            artist: "Snapshot artist",
            album: "Snapshot album",
            duration: 240,
            originatedOnThisDevice: false
        )
        let placeholderSummary = ListeningHistoryStatsSummary(
            entries: [snapshotEntry],
            tracks: [],
            remoteSongs: [placeholderCatalogSong]
        )
        #expect(placeholderSummary.songRanking.first?.track.title == "Snapshot title")
        #expect(placeholderSummary.songRanking.first?.track.artist == "Snapshot artist")
        #expect(placeholderSummary.songRanking.first?.track.album == "Snapshot album")
    }

    @Test
    func listeningHistoryRequiresMoreThanTenPercentForEachPlay() {
        let track = Track(
            title: "Threshold",
            artist: "Test",
            album: "Album",
            duration: 200,
            artwork: .midnight
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [19.99, 20, 20.01].map { seconds in
            ListeningHistoryEntry(
                trackID: track.id,
                startedAt: now,
                listenedSeconds: seconds,
                duration: track.duration
            )
        }

        #expect(!ListeningHistoryPlayPolicy.qualifies(entries[0], track: track))
        #expect(!ListeningHistoryPlayPolicy.qualifies(entries[1], track: track))
        #expect(ListeningHistoryPlayPolicy.qualifies(entries[2], track: track))
        #expect(ListeningHistoryStatsSummary(entries: entries, tracks: [track]).plays == 1)
        #expect(ListeningHistoryCalendarSummary(
            entries: entries,
            tracks: [track],
            dayCount: 1,
            now: now
        ).plays == 1)
    }

    @Test
    func downloadedLocalCopyHydratesLegacyListeningHistoryWithoutGuessing() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let artwork = Data([0x89, 0x50, 0x4E, 0x47])
        let downloaded = Track(
            title: "Candle - Light/Speed (Geometry Dash / FUNHOUSE)",
            artist: "EDMS and Candle / Audio",
            album: "Current Local Metadata",
            duration: 276,
            artwork: .electric,
            artworkData: artwork,
            fileURL: URL(fileURLWithPath: "/private/tmp/candle-history-copy.m4a")
        )
        let entry = ListeningHistoryEntry(
            trackID: UUID(),
            startedAt: now,
            listenedSeconds: 120,
            serverOrigin: "https://resonance.example",
            syncProfileID: "default",
            remoteSongID: "old-server-song",
            title: "Candle - Light/Speed (Geometry Dash / FUNHOUSE)",
            artist: "Candle and EDMS / Audio",
            album: "Imported",
            duration: 276,
            originatedOnThisDevice: false
        )

        let summary = ListeningHistoryCalendarSummary(
            entries: [entry],
            tracks: [downloaded],
            dayCount: 1,
            now: now
        )
        let hydrated = try #require(summary.songSeries.first?.track)
        #expect(hydrated.id == downloaded.id)
        #expect(hydrated.artworkData == artwork)
        #expect(hydrated.album == "Current Local Metadata")
        #expect(ListeningHistoryStatsSummary(entries: [entry], tracks: [downloaded]).songRanking.first?.track.id == downloaded.id)

        let ambiguousCopy = Track(
            title: downloaded.title,
            artist: downloaded.artist,
            album: "Different Copy",
            duration: downloaded.duration,
            artwork: .golden,
            artworkData: Data([0x01]),
            fileURL: URL(fileURLWithPath: "/private/tmp/candle-history-copy-2.m4a")
        )
        let unresolved = ListeningHistoryCalendarSummary(
            entries: [entry],
            tracks: [downloaded, ambiguousCopy],
            dayCount: 1,
            now: now
        )
        #expect(unresolved.songSeries.first?.track.id == entry.trackID)
        #expect(unresolved.songSeries.first?.track.artworkData == nil)
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
        let key = "credential-round-trip"
        let store = FileServerCredentialStore(storeURL: storeURL)
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        #expect(store.save("preview-test-token", key: key))
        #expect(store.read(key: key) == "preview-test-token")
        #expect(store.save("preview-test-token", key: key))
        #expect(store.save("updated-preview-test-token", key: key))
        #expect(store.read(key: key) == "updated-preview-test-token")
        let permissions = try? FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        #expect(store.delete(key: key))
        #expect(store.read(key: key) == nil)
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
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeURL.path)

        let store = FileServerCredentialStore(storeURL: storeURL)
        #expect(store.read(key: "music-server-client-token") == "legacy-client")
        #expect(store.read(key: "music-server-admin-token") == "legacy-admin")
        let directoryPermissions = try #require(
            FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        )
        let filePermissions = try #require(
            FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions] as? NSNumber
        )
        #expect(directoryPermissions.intValue == 0o700)
        #expect(filePermissions.intValue == 0o600)
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
