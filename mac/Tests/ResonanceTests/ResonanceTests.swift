import Combine
import AVFoundation
import Foundation
import MediaPlayer
import Testing
@testable import Resonance

private final class MockMusicURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try #require(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func requestBodyData(_ request: URLRequest) throws -> Data {
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

@MainActor
private final class RecordingMacSystemPlaybackController: MacSystemPlaybackControlling {
    var handlers = MacSystemPlaybackHandlers()
    private(set) var lastSnapshot: MacNowPlayingSnapshot?
    private(set) var publishCount = 0
    private(set) var invalidated = false

    func publish(_ snapshot: MacNowPlayingSnapshot?) {
        lastSnapshot = snapshot
        publishCount += 1
    }

    func invalidate() {
        invalidated = true
        lastSnapshot = nil
    }
}

@MainActor
@Suite(.serialized)
struct ResonanceTests {
    @Test
    func accountEmailIsCensoredUntilExplicitlyRevealed() {
        let email = "private@example.com"
        #expect(ResonanceEmailPrivacy.displayedAddress(email, isRevealed: false)
            == ResonanceEmailPrivacy.censoredAddress)
        #expect(ResonanceEmailPrivacy.displayedAddress(email, isRevealed: true) == email)
        #expect(ResonanceEmailPrivacy.safeDisplayName(email, email: email) == "Clerk account")
    }

    @Test
    func accountScopeSupportsTheDeployedLegacyResponseUntilCoreMigratesIt() {
        #expect(ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: "user_listener",
            serverProfileID: nil,
            requestedLegacyProfileID: "legacy-library"
        ) == "legacy-library")
        #expect(ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: "user_listener",
            serverProfileID: nil,
            requestedLegacyProfileID: nil
        ) == "default")
        #expect(ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: "user_listener",
            serverProfileID: "user_listener",
            requestedLegacyProfileID: "legacy-library"
        ) == "user_listener")
        #expect(ResonanceAccountScopePolicy.resolvedProfileID(
            accountID: "user_listener",
            serverProfileID: "someone_else",
            requestedLegacyProfileID: "legacy-library"
        ) == nil)
    }

    @Test
    func confirmedProfileMigrationSignalIsNeverPersistedWithTheClerkSession() throws {
        let session = ResonanceAccountSession(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
            email: "listener@example.com",
            role: "admin",
            baseURL: try #require(URL(string: "https://music.example")),
            accountID: "user_listener",
            profileID: "user_listener",
            displayName: "Listener",
            imageURL: nil,
            migratedProfileID: "default"
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ResonanceAccountSession.self, from: encoded)
        #expect(decoded.profileID == "user_listener")
        #expect(decoded.migratedProfileID == nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("migratedProfileID"))
    }

    private let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    private let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private let hero = URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff")

    private func defaults() throws -> (UserDefaults, String) {
        let suiteName = "ResonanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test
    func timeFormattingHandlesBoundaries() {
        #expect(Track.timeText(-1) == "0:00")
        #expect(Track.timeText(.nan) == "0:00")
        #expect(Track.timeText(59.99) == "0:59")
        #expect(Track.timeText(60) == "1:00")
        #expect(Track.timeText(222) == "3:42")
    }

    @Test
    func automaticPlaylistArtworkUsesOnlyTheFirstFourCustomPlaylistTracks() {
        let trackIDs = (0..<5).map { _ in UUID() }
        let playlist = Playlist(name: "Mix", artwork: .electric, trackIDs: trackIDs)
        let likedSongs = Playlist.library(trackIDs: trackIDs)

        #expect(playlist.automaticArtworkTrackIDs == Array(trackIDs.prefix(4)))
        #expect(likedSongs.automaticArtworkTrackIDs.isEmpty)
    }

    @Test
    func serverUploadNamesUseTrackTitlesInsteadOfManagedCacheHashes() {
        let cached = URL(fileURLWithPath: "/ServerCache/980026786a7d6c4928bb9b3fdd9e42b9b53eb7432473cac2b.m4a")
        #expect(ServerUploadNaming.filename(for: cached, title: "No Dogs Allowed") == "No Dogs Allowed.m4a")
        #expect(ServerUploadNaming.filename(for: cached, title: "Real/Song?.m4a") == "Real-Song-.m4a")
        #expect(ServerUploadNaming.filename(for: URL(fileURLWithPath: "/Music/Real Song.mp3")) == "Real Song.mp3")
    }

    @Test
    func uploadActionsIgnoreRefreshAndPlaylistSyncButStillBlockTransfers() throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)

        model.isSyncingServer = true
        model.isRefreshingServerCatalog = true
        model.isSyncingPlaylists = true
        #expect(!model.serverUploadActionsDisabled)

        model.isRefreshingServerCatalog = false
        #expect(model.serverUploadActionsDisabled)

        model.isSyncingServer = false
        model.isUploadingServer = true
        #expect(model.serverUploadActionsDisabled)
    }

    @Test
    func localImportReservationSynchronouslyLocksProfileAndManualUploadContext() async throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"

        let context = try model.beginLocalImportTransfer(reservingUpload: true)
        defer { model.endLocalImportTransfer(context) }

        #expect(model.isUploadingLocalImport)
        #expect(model.serverUploadActionsDisabled)
        #expect(context.profileID == "default")
        #expect(context.baseURL?.absoluteString == "https://music.test")
        #expect(throws: LocalImportTransferContextError.self) {
            _ = try model.beginLocalImportTransfer(reservingUpload: true)
        }

        await model.uploadSongsToServer([glass])
        #expect(model.uploadStatus == "Idle")
        #expect(await model.selectSyncProfile(matching: "other") == false)
        #expect(model.serverMessage == "Wait for the current server transfer or sync to finish")

        model.serverAdminToken = "changed-admin-token"
        #expect(throws: LocalImportTransferContextError.self) {
            try model.validateLocalImportTransfer(context)
        }
    }

    @Test
    func localOnlyImportReservesTransferContextWithoutServerCredentials() async throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)

        let context = try model.beginLocalImportTransfer(reservingUpload: false)
        defer { model.endLocalImportTransfer(context) }

        #expect(context.baseURL == nil)
        #expect(context.adminToken == nil)
        #expect(!context.reservesUpload)
        #expect(model.isUploadingLocalImport)
        #expect(model.serverUploadActionsDisabled)
        #expect(throws: LocalImportTransferContextError.self) {
            _ = try model.beginLocalImportTransfer(reservingUpload: false)
        }
        #expect(throws: LocalImportTransferContextError.self) {
            _ = try model.beginLocalImportTransfer(reservingUpload: true)
        }

        await model.uploadSongsToServer([glass])
        #expect(model.uploadStatus == "Idle")
        #expect(await model.selectSyncProfile(matching: "other") == false)
        #expect(model.serverMessage == "Wait for the current server transfer or sync to finish")
        #expect(throws: Never.self) {
            try model.validateLocalImportTransfer(context)
        }

        model.endLocalImportTransfer(context)
        #expect(!model.isUploadingLocalImport)
        #expect(!model.serverUploadActionsDisabled)
        #expect(throws: LocalImportTransferContextError.self) {
            try model.validateLocalImportTransfer(context)
        }
    }

    @Test
    func serverConnectionCanSaveEitherSyncOrAdminCredentials() {
        #expect(ServerConnectionPolicy.canSave(
            serverURL: "https://music.test",
            accessToken: "",
            adminToken: "admin-token"
        ))
        #expect(ServerConnectionPolicy.canSave(
            serverURL: "https://music.test",
            accessToken: "access-token",
            adminToken: ""
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "https://music.test",
            accessToken: "",
            adminToken: ""
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "",
            accessToken: "access-token",
            adminToken: "admin-token"
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "not-a-server",
            accessToken: "",
            adminToken: "admin-token"
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "http://music.test",
            accessToken: "access-token",
            adminToken: ""
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "http://localhost:8765",
            accessToken: "access-token",
            adminToken: ""
        ))
        #expect(ServerConnectionPolicy.canSave(
            serverURL: "http://localhost:8765",
            accessToken: "access-token",
            adminToken: "",
            allowsInsecurePreviewLoopback: true
        ))
        #expect(ServerConnectionPolicy.canSave(
            serverURL: "http://[::1]:8765",
            accessToken: "access-token",
            adminToken: "",
            allowsInsecurePreviewLoopback: true
        ))
        #expect(!ServerConnectionPolicy.canSave(
            serverURL: "http://music.test",
            accessToken: "access-token",
            adminToken: "",
            allowsInsecurePreviewLoopback: true
        ))
        #expect(ServerEndpointPolicy.normalizedURL("https://MUSIC.test:443/base/")?.absoluteString
            == "https://music.test/base")
        #expect(ServerEndpointPolicy.normalizedURL("https://music.unblocked.mov")?.absoluteString
            == "https://resonance-core.blithe-haven-9710.chatgpt.site")
        #expect(ServerEndpointPolicy.normalizedURL("https://user:secret@music.test") == nil)
        #expect(ResonanceSocialAuthClient.accountSignInBaseURL.absoluteString
            == "https://resonance-core.blithe-haven-9710.chatgpt.site/")
    }

    @Test
    func remoteSongIdentityIncludesNormalizedOriginAndProfile() throws {
        let active = try #require(ServerSongIdentity(
            serverURLString: "https://MUSIC.test:443/api/v1",
            profileID: "profile-a",
            songID: "same-id"
        ))
        let sameOrigin = try #require(ServerSongIdentity(
            serverURLString: "https://music.test/another/path",
            profileID: "profile-a",
            songID: "same-id"
        ))
        let otherProfile = try #require(ServerSongIdentity(
            serverURLString: "https://music.test",
            profileID: "profile-b",
            songID: "same-id"
        ))
        let otherServer = try #require(ServerSongIdentity(
            serverURLString: "https://archive.test",
            profileID: "profile-a",
            songID: "same-id"
        ))

        #expect(active == sameOrigin)
        #expect(active != otherProfile)
        #expect(active != otherServer)
        #expect(ServerSongIdentity.normalizedOrigin("https://music.unblocked.mov")
            == "https://resonance-core.blithe-haven-9710.chatgpt.site")
    }

    @Test
    func changingServerOriginInvalidatesTheCachedUploadCatalog() throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let catalog = try JSONDecoder().decode(RemoteCatalog.self, from: Data("""
        {
          "songs":[{"id":"old-id","filename":"old.m4a","title":"Old","artist":"Artist","album":"Album","size":1,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/old","stream_url":"/stream/old"}],
          "count":1
        }
        """.utf8))

        model.serverURLString = "https://old.example"
        model.remoteSongs = catalog.songs
        model.selectedRemoteSongIDs = ["old-id"]
        model.serverURLString = "https://new.example"

        #expect(model.remoteSongs.isEmpty)
        #expect(model.selectedRemoteSongIDs.isEmpty)
    }

    @Test
    func missingServerUploadPolicyRequiresTheActiveIdentityAndAnExactHashMatch() throws {
        let exactHash = String(repeating: "a", count: 64)
        let catalogData = Data("""
        {"songs":[
          {"id":"live-id","filename":"live.m4a","title":"Live","artist":"Artist","album":"Album","size":10,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/live","stream_url":"/stream/live"},
          {"id":"hash-id","filename":"hash.m4a","title":"Hash","artist":"Artist","album":"Album","size":10,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/hash","stream_url":"/stream/hash","content_sha256":"\(exactHash)"},
          {"id":"metadata-id","filename":"All for You - Radio Version.m4a","title":"All for You Radio Version","artist":"Ace of Base","album":"Imported","size":10,"modified_at":"now","content_type":"audio/mp4","download_url":"/download/metadata","stream_url":"/stream/metadata","duration_seconds":217.9}
        ],"count":3}
        """.utf8)
        let catalog = try JSONDecoder().decode(RemoteCatalog.self, from: catalogData).songs
        let fileURL = URL(fileURLWithPath: "/tmp/downloaded.m4a")
        let present = Track(
            title: "Present", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "live-id", sourceServer: "https://music.test/",
            syncProfileID: "profile-a"
        )
        let hashMatch = Track(
            title: "Hash", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "deleted-id", sourceServer: "https://music.test",
            syncProfileID: "profile-a", contentSHA256: exactHash.uppercased()
        )
        let missing = Track(
            title: "Missing", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "missing-id", sourceServer: "https://music.test",
            syncProfileID: "profile-a"
        )
        let metadataMatch = Track(
            title: "All for You - Radio Version", artist: "Ace of Base", album: "The Golden Ratio",
            duration: 217.1, artwork: .liked, fileURL: fileURL, remoteID: "stale-metadata-id",
            sourceServer: "https://music.test", syncProfileID: "profile-a"
        )
        let localImport = Track(
            title: "Local", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, syncProfileID: "profile-a"
        )
        let anotherProfile = Track(
            title: "Other Profile", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "other-profile", sourceServer: "https://music.test",
            syncProfileID: "profile-b"
        )
        let anotherServerWithCollidingID = Track(
            title: "Other Server", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "live-id", sourceServer: "https://archive.test",
            syncProfileID: "profile-b"
        )
        let anotherServerHashMatch = Track(
            title: "Hash", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "old-hash-id", sourceServer: "https://archive.test",
            syncProfileID: "profile-b", contentSHA256: exactHash
        )
        let legacyRemoteOnly = Track(
            title: "Legacy Download", artist: "Artist", album: "Album", duration: 1, artwork: .liked,
            fileURL: fileURL, remoteID: "legacy-missing-id", syncProfileID: "profile-b"
        )

        let plan = MissingServerUploadPolicy.plan(
            tracks: [
                present,
                hashMatch,
                metadataMatch,
                missing,
                localImport,
                anotherProfile,
                anotherServerWithCollidingID,
                anotherServerHashMatch,
                legacyRemoteOnly,
            ],
            catalog: catalog,
            activeProfileID: "profile-a",
            activeServerURL: try #require(URL(string: "https://music.test"))
        )

        #expect(plan.uploadTrackIDs == [metadataMatch.id, missing.id])
        #expect(plan.existingRemoteIDsByTrackID == [
            hashMatch.id: "hash-id",
        ])
        #expect(plan.ambiguousTrackIDs.isEmpty)
        #expect(!plan.uploadTrackIDs.contains(localImport.id))
        #expect(plan.existingRemoteIDsByTrackID[localImport.id] == nil)
    }

    @Test
    func ambiguousCatalogHashesAreNeverAutoReconciled() throws {
        let hash = String(repeating: "b", count: 64)
        let catalog = try JSONDecoder().decode(RemoteCatalog.self, from: Data("""
        {"songs":[
          {"id":"first","filename":"first.m4a","title":"First","artist":"Artist","album":"Album","size":10,"modified_at":"now","content_type":"audio/mp4","download_url":"/first","stream_url":"/first","content_sha256":"\(hash)"},
          {"id":"second","filename":"second.m4a","title":"Second","artist":"Artist","album":"Album","size":10,"modified_at":"now","content_type":"audio/mp4","download_url":"/second","stream_url":"/second","content_sha256":"\(hash)"}
        ],"count":2}
        """.utf8)).songs
        let track = Track(
            title: "Local",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            remoteID: "missing",
            sourceServer: "https://music.test",
            syncProfileID: "default",
            contentSHA256: hash
        )

        let plan = MissingServerUploadPolicy.plan(
            tracks: [track],
            catalog: catalog,
            activeProfileID: "default",
            activeServerURL: try #require(URL(string: "https://music.test"))
        )

        #expect(plan.uploadTrackIDs.isEmpty)
        #expect(plan.existingRemoteIDsByTrackID.isEmpty)
        #expect(plan.ambiguousTrackIDs == [track.id])
    }

    @Test
    func downloadedUploadContinuesDuringRefreshWithoutWaitingForTheCatalog() async throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/client-config" {
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            #expect(request.httpMethod == "PUT")
            #expect(url.path == "/api/v1/admin/songs")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "default")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")
            #expect(!(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key") ?? "").isEmpty)
            let data = Data(#"{"duplicate_of":{"id":"uploaded-id","filename":"Glass.aiff","title":"Downloaded","artist":"Artist","album":"Album","size":1,"modified_at":"now","content_type":"audio/aiff","download_url":"/download/uploaded-id","stream_url":"/stream/uploaded-id"}}"#.utf8)
            return (HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!, data)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        let track = Track(
            title: "Downloaded",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            remoteID: "old-id",
            sourceServer: "https://music.test",
            syncProfileID: "default",
            downloadSourceURL: "https://media.example/downloaded.aiff"
        )
        model.tracks = [track]
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"
        model.isSyncingServer = true
        model.isRefreshingServerCatalog = true
        model.isSyncingPlaylists = true

        model.uploadMissingDownloadedSongs()
        for _ in 0..<200 where model.uploadStatus != "Uploaded 1; matched 0 already on the server" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.uploadStatus == "Uploaded 1; matched 0 already on the server")
        #expect(model.tracks.first?.remoteID == "uploaded-id")
        #expect(model.tracks.first?.syncProfileID == "default")
        #expect(model.isSyncingServer)
        #expect(model.isSyncingPlaylists)
    }

    @Test
    func fileUploadRefusesToDuplicateATrackLinkedToAnotherContext() async throws {
        let (defaults, suiteName) = try defaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }
        MockMusicURLProtocol.handler = { _ in
            Issue.record("A conflicting library file must be rejected before upload")
            throw URLError(.unsupportedURL)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = ""
        model.serverAdminToken = "admin-token"
        let linkedTrack = Track(
            title: "Glass",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            sourceServer: "https://archive.test",
            syncProfileID: "profile-a"
        )
        model.tracks = [linkedTrack]

        await model.uploadSongsToServer([glass])

        #expect(model.uploadStatus.contains("already linked"))
        #expect(model.uploadStatus.contains("import a separate local copy"))
        #expect(model.serverMessage == model.uploadStatus)
        #expect(model.remoteSongs.isEmpty)
        #expect(model.tracks.first?.remoteID == nil)
        #expect(model.tracks.first?.sourceServer == "https://archive.test")
        #expect(model.tracks.first?.syncProfileID == "profile-a")
        #expect(!model.isUploadingServer)
    }

    @Test
    func clipTimeFieldsParseSecondsMinutesAndHours() throws {
        #expect(clipTimeValue(from: "24.7") == 24.7)
        #expect(clipTimeValue(from: "0:24.7") == 24.7)
        #expect(clipTimeValue(from: "1:31.6") == 91.6)
        #expect(clipTimeValue(from: "1:02:03.5") == 3_723.5)
        #expect(clipTimeValue(from: " 1:02,5 ") == 62.5)
        #expect(clipTimeValue(from: "") == nil)
        #expect(clipTimeValue(from: "one minute") == nil)
        #expect(clipTimeValue(from: "-1") == nil)
    }

    @Test
    func updaterRestoresAValidatedDownloadedArchiveAfterRelaunch() async throws {
        let updateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: updateDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: updateDirectory) }

        let version = "99.0.0"
        let archive = updateDirectory.appendingPathComponent("Resonance-macOS-\(version).zip")
        try Data("complete update archive".utf8).write(to: archive)
        let manifest = MacUpdateManifest(
            version: version,
            build: "1",
            url: URL(string: "https://github.com/Drastics-Experiments/resonance/releases/download/v\(version)/Resonance-macOS.zip")!,
            sha256: try UpdateManager.sha256(of: archive)
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try JSONEncoder().encode(manifest)
            )
        }

        let firstLaunch = UpdateManager(session: session, updateDirectory: updateDirectory)
        await firstLaunch.checkForUpdates(silent: true)
        #expect(firstLaunch.canInstall)
        #expect(firstLaunch.downloadedArchive == archive)

        let relaunched = UpdateManager(session: session, updateDirectory: updateDirectory)
        await relaunched.checkForUpdates(silent: true)
        #expect(relaunched.canInstall)
        #expect(relaunched.downloadedArchive == archive)
        #expect(relaunched.status == "Version \(version) ready")
    }

    @Test
    func playlistPayloadUsesServerCompatibleLowercaseUUIDs() throws {
        let id = try #require(UUID(uuidString: "12345678-1234-ABCD-9876-ABCDEF123456"))
        let payload = RemotePlaylist(id: id, name: "Case Test", songIDs: [])
        let json = try #require(String(data: JSONEncoder().encode(payload), encoding: .utf8))
        #expect(json.contains("12345678-1234-abcd-9876-abcdef123456"))
        #expect(!json.contains("ABCD"))
    }

    @Test
    func newLibraryStartsEmptyAndReadyForRealFiles() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)

        #expect(model.tracks.isEmpty)
        #expect(model.playlists.count == 1)
        #expect(model.playlists[0].isSystem)
        #expect(model.playlists[0].name == "Liked Songs")
        #expect(model.currentTrack == nil)
        #expect(!model.isPlaying)

        model.selectSection(.playlists)
        #expect(model.selectedPlaylistID == nil)
        model.setPlaybackRate(1.5)
        #expect(model.playbackRate == 1.5)
    }

    @Test
    func importsActualAudioMetadataAndPersistsLibraryState() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(FileManager.default.fileExists(atPath: glass.path))
        #expect(FileManager.default.fileExists(atPath: ping.path))

        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, glass])
        #expect(model.tracks.count == 2)
        #expect(model.tracks.allSatisfy { $0.duration > 0 && $0.fileURL != nil })
        #expect(model.playlists[0].trackIDs.isEmpty)

        let first = model.tracks[0]
        model.toggleFavorite(first)
        #expect(model.playlists[0].trackIDs == [first.id])
        let playlist = try #require(model.createPlaylist(named: "Favorites for Work"))
        model.addTrack(first, to: playlist)

        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(reloaded.tracks.map(\.id) == model.tracks.map(\.id))
        #expect(reloaded.favorites.contains(first.id))
        #expect(reloaded.customPlaylists.first?.name == "Favorites for Work")
        #expect(reloaded.customPlaylists.first?.trackIDs == [first.id])
    }

    @Test
    func clipRangeClampsToTheSourceAndRejectsTinySelections() throws {
        let range = try ClipRangePolicy.normalized(start: -4, end: 12, sourceDuration: 10)
        #expect(range.lowerBound == 0)
        #expect(range.upperBound == 10)
        #expect(throws: ClipEditorError.self) {
            try ClipRangePolicy.normalized(start: 1, end: 1.1, sourceDuration: 10)
        }
    }

    @Test
    func savesClipRangeAsPlaybackMetadataWithoutCreatingAFile() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clipDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResonanceClipRangeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: clipDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: clipDirectory) }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [hero])
        let source = try #require(model.tracks.first)
        let selectionEnd = min(source.duration, max(ClipRangePolicy.minimumDuration, source.duration * 0.75))
        #expect(selectionEnd >= ClipRangePolicy.minimumDuration)

        model.saveClipRange(for: source, start: 0, end: selectionEnd)

        #expect(model.tracks.count == 1)
        #expect(model.tracks.first?.fileURL == source.fileURL)
        #expect(model.clipRange(for: source) == ClipRange(startSeconds: 0, endSeconds: selectionEnd))
        #expect(try FileManager.default.contentsOfDirectory(atPath: clipDirectory.path).isEmpty)

        let reloaded = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )
        let reloadedSource = try #require(reloaded.tracks.first)
        #expect(reloaded.clipRange(for: reloadedSource) == ClipRange(startSeconds: 0, endSeconds: selectionEnd))

        reloaded.clearClipRange(for: reloadedSource)
        #expect(reloaded.clipRange(for: reloadedSource) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clipDirectory.path).isEmpty)
    }

    @Test
    func actualAudioCanPlayPauseAndSeek() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [hero])
        let track = try #require(model.tracks.first)
        var playbackDiscontinuities: [TimeInterval] = []
        let playbackDiscontinuityObserver = model.playbackDiscontinuities.sink {
            playbackDiscontinuities.append($0)
        }
        defer { playbackDiscontinuityObserver.cancel() }

        model.selectAndPlay(track)
        #expect(model.isPlaying)
        try await Task.sleep(for: .milliseconds(300))
        #expect(playbackDiscontinuities.isEmpty)
        #expect(model.listeningHistoryEntries.count == 1)
        #expect(model.listeningHistoryEntries.first?.trackID == track.id)
        #expect(model.listeningHistoryEntries.first?.syncProfileID == "default")
        model.seek(to: 0.5)
        #expect(abs(model.position - track.duration * 0.5) < 0.02)
        #expect(playbackDiscontinuities.count == 1)
        #expect(abs((playbackDiscontinuities.first ?? 0) - model.position) < 0.001)
        model.togglePlay()
        #expect(!model.isPlaying)
        #expect((model.listeningHistoryEntries.first?.listenedSeconds ?? 0) > 0)
        model.togglePlay()
        #expect(model.isPlaying)
        model.togglePlay()
    }

    @Test
    func repeatingAudioStartsANewListeningHistoryPlayOnEveryLoop() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [glass])
        let track = try #require(model.tracks.first)

        model.toggleRepeat()
        model.selectAndPlay(track)
        try await Task.sleep(for: .milliseconds(2_050))
        if model.isPlaying { model.togglePlay() }

        #expect(model.listeningHistoryEntries.count >= 2)
        #expect(ListeningHistoryPlayPolicy.qualifies(
            try #require(model.listeningHistoryEntries.first),
            track: track
        ))
    }

    @Test
    func playbackUsesThePlayableAudioDurationInsteadOfStaleTrackMetadata() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [hero])
        let imported = try #require(model.tracks.first)
        let playableDuration = imported.duration
        var stale = imported
        stale.duration = playableDuration * 2
        model.tracks = [stale]

        model.selectAndPlay(stale)

        #expect(abs(model.playbackDuration - playableDuration) < 0.02)
        #expect(abs((model.currentTrack?.duration ?? 0) - playableDuration) < 0.02)
        model.togglePlay()
    }

    @Test
    func playbackProgressDoesNotInvalidateTheWholeLibraryGraph() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [hero])
        let track = try #require(model.tracks.first)
        model.selectAndPlay(track)

        var modelUpdates = 0
        var positionUpdates = 0
        let modelObservation = model.objectWillChange.sink { modelUpdates += 1 }
        let positionObservation = model.playbackPositionState.objectWillChange.sink {
            positionUpdates += 1
        }
        let startingPosition = model.playbackPositionState.position

        for _ in 0..<100 where positionUpdates < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(modelUpdates == 0)
        #expect(positionUpdates >= 2)
        #expect(model.playbackPositionState.position > startingPosition)
        _ = (modelObservation, positionObservation)
        model.togglePlay()
    }

    @Test
    func nativeMacPlaybackPublishesMetadataAndHandlesSystemControls() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingMacSystemPlaybackController()
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false,
            systemPlaybackController: controller
        )
        await model.importLocalFiles(at: [glass, ping])
        let first = try #require(model.tracks.first)

        model.selectAndPlay(first)
        var snapshot = try #require(controller.lastSnapshot)
        #expect(snapshot.trackID == first.id)
        #expect(snapshot.title == first.title)
        #expect(snapshot.artist == first.artist)
        #expect(snapshot.album == first.album)
        #expect(snapshot.isPlaying)
        #expect(snapshot.queueCount == 2)
        #expect(snapshot.assetURL == first.fileURL)

        controller.handlers.seek(first.duration * 0.5)
        snapshot = try #require(controller.lastSnapshot)
        #expect(abs(snapshot.elapsedTime - first.duration * 0.5) < 0.02)
        controller.handlers.changeRate(1.5)
        #expect(model.playbackRate == 1.5)
        #expect(controller.lastSnapshot?.playbackRate == 1.5)
        controller.handlers.setFavorite(true)
        #expect(model.favorites.contains(first.id))
        #expect(controller.lastSnapshot?.isFavorite == true)

        controller.handlers.next()
        let second = try #require(model.currentTrack)
        #expect(second.id != first.id)
        #expect(controller.lastSnapshot?.trackID == second.id)
        controller.handlers.pause()
        #expect(!model.isPlaying)
        #expect(controller.lastSnapshot?.isPlaying == false)
        controller.handlers.play()
        #expect(model.isPlaying)
        #expect(controller.lastSnapshot?.isPlaying == true)
        controller.handlers.pause()
    }

    @Test
    func nativeMacPlaybackSnapshotSanitizesSystemMetadata() {
        let track = Track(
            title: "  ",
            artist: "",
            album: "Album",
            duration: 120,
            kind: .video,
            artwork: .electric,
            remoteID: "server-song",
            sourceServer: "https://music.test",
            syncProfileID: "profile-a"
        )
        let snapshot = MacNowPlayingSnapshot(
            track: track,
            position: 500,
            playbackRate: -.infinity,
            isPlaying: false,
            queue: [],
            isFavorite: false,
            shuffleEnabled: false,
            repeatEnabled: true,
            profileID: "default"
        )

        #expect(snapshot.title == "Unknown song")
        #expect(snapshot.artist == "Unknown artist")
        #expect(snapshot.elapsedTime == 120)
        #expect(snapshot.playbackRate == 1)
        #expect(snapshot.isVideo)
        #expect(snapshot.contentIdentifier
            == "https://music.test#profile=profile-a#song=server-song")
        #expect(snapshot.profileID == "profile-a")
        #expect(snapshot.queueIndex == 0)
        #expect(snapshot.queueCount == 1)
    }

    @Test
    func nativeMacPlaybackControllerPublishesToMediaPlayer() throws {
        let track = Track(
            title: "Native Song",
            artist: "Native Artist",
            album: "Native Album",
            duration: 180,
            artwork: .midnight,
            remoteID: "native-song",
            syncProfileID: "default"
        )
        let snapshot = MacNowPlayingSnapshot(
            track: track,
            position: 45,
            playbackRate: 1.25,
            isPlaying: true,
            queue: [track],
            isFavorite: true,
            shuffleEnabled: false,
            repeatEnabled: true,
            profileID: "default"
        )
        let controller = MacSystemPlaybackController()
        defer { controller.invalidate() }

        controller.publish(snapshot)

        let info = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Native Song")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Native Artist")
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 45)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.25)
        #expect(info[MPMediaItemPropertyArtwork] is MPMediaItemArtwork)
        #expect(MPNowPlayingInfoCenter.default().playbackState == .playing)
        #expect(!MPRemoteCommandCenter.shared().playCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().pauseCommand.isEnabled)
        #expect(MPRemoteCommandCenter.shared().likeCommand.isActive)
        #expect(MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType == .one)
    }

    @Test
    func playlistPlaybackStaysInsideSelectedPlaylist() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])

        let playlist = try #require(model.createPlaylist(named: "Two Songs"))
        model.addTrack(model.tracks[1], to: playlist)
        model.addTrack(model.tracks[2], to: playlist)
        model.selectPlaylist(model.playlists.first { $0.id == playlist.id }!)

        model.toggleCollectionPlayback()
        #expect(model.currentTrackID == model.tracks[1].id)
        model.next()
        #expect(model.currentTrackID == model.tracks[2].id)
        model.next()
        #expect(model.currentTrackID == model.tracks[1].id)
        model.togglePlay()
    }

    @Test
    func customPlaylistSongOrderCanBeRearrangedAndPersists() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])

        let playlist = try #require(model.createPlaylist(named: "Reorder Me"))
        for track in model.tracks {
            model.addTrack(track, to: playlist)
        }
        let originalOrder = model.tracks.map(\.id)

        model.moveTrack(originalOrder[0], over: originalOrder[2], in: playlist.id)
        #expect(model.customPlaylists.first?.trackIDs == [originalOrder[1], originalOrder[2], originalOrder[0]])
        model.moveTrack(originalOrder[0], to: 0, in: playlist.id)
        #expect(model.customPlaylists.first?.trackIDs == originalOrder)
        model.moveTrack(originalOrder[0], to: 2, in: playlist.id)
        #expect(model.customPlaylists.first?.trackIDs == [originalOrder[1], originalOrder[2], originalOrder[0]])

        let likedSongs = model.playlists[0]
        model.tracks.forEach(model.toggleFavorite)
        model.moveTrack(originalOrder[0], over: originalOrder[2], in: likedSongs.id)
        #expect(model.playlists[0].trackIDs == [originalOrder[1], originalOrder[2], originalOrder[0]])

        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(reloaded.customPlaylists.first?.trackIDs == [originalOrder[1], originalOrder[2], originalOrder[0]])
        #expect(reloaded.playlists[0].trackIDs == [originalOrder[1], originalOrder[2], originalOrder[0]])
    }

    @Test
    func playlistOrderMergeKeepsDeviceOnlyAndUnresolvedItemsInStableSlots() {
        #expect(PlaylistOrderPolicy.merge(
            previous: ["remote-a", "local", "remote-b"],
            ordered: ["remote-b", "remote-c", "remote-a"],
            preserving: ["local"]
        ) == ["remote-b", "local", "remote-c", "remote-a"])
        #expect(PlaylistOrderPolicy.merge(
            previous: ["remote-a", "unresolved", "remote-b"],
            ordered: ["remote-b", "remote-a"],
            preserving: ["unresolved"]
        ) == ["remote-b", "unresolved", "remote-a"])
    }

    @Test
    func playlistPresentationIncludesUndownloadedRemoteSongsInOrder() {
        let local = Track(
            title: "Local",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked
        )
        let remoteA = Track(
            title: "Downloaded A",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "remote-a"
        )
        let remoteB = Track(
            title: "Downloaded B",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "remote-b"
        )
        let playlist = Playlist(
            name: "Shared",
            artwork: .liked,
            trackIDs: [remoteA.id, local.id, remoteB.id],
            remoteSongIDs: ["remote-b", "remote-missing", "remote-a"]
        )

        let entries = PlaylistPresentationPolicy.entries(
            in: playlist,
            tracks: [local, remoteA, remoteB],
            remoteSongs: []
        )

        #expect(entries.map(\.id) == [
            .remote("remote-b"),
            .local(local.id),
            .remote("remote-missing"),
            .remote("remote-a")
        ])
        #expect(entries.map(\.isDownloaded) == [true, true, false, true])
        #expect(entries[2].title == "Unavailable song")
    }

    @Test
    func serverDownloadProgressUsesCurrentSongBytesAndSeparateBatchPosition() {
        #expect(MacServerDownloadProgressPolicy.fraction(completedBytes: 42, totalBytes: 100) == 0.42)
        #expect(MacServerDownloadProgressPolicy.fraction(completedBytes: 0, totalBytes: 100) == 0)
        #expect(MacServerDownloadProgressPolicy.fraction(completedBytes: 120, totalBytes: 100) == 1)
        #expect(MacServerDownloadProgressPolicy.presentationFraction(completedBytes: 0, totalBytes: 100) == nil)
        #expect(MacServerDownloadProgressPolicy.presentationFraction(completedBytes: 42, totalBytes: 100) == 0.42)
        #expect(!MacServerDownloadProgressPolicy.transferHasStarted(completedBytes: 0))
        #expect(MacServerDownloadProgressPolicy.transferHasStarted(completedBytes: 1))
        #expect(MacServerDownloadProgressPolicy.percentageLabel(0.001) == "<1%")
        #expect(MacServerDownloadProgressPolicy.percentageLabel(0.42) == "42%")
        #expect(MacServerDownloadProgressPolicy.batchCounter(position: 3, total: 10) == "3/10")
        #expect(MacServerDownloadProgressPolicy.batchCounter(position: 0, total: 0) == nil)
    }

    @Test
    func serverDownloadTransferReleaseIsScopedToTheFailedOrCancelledItem() {
        let stateGeneration: UInt64 = 7
        let failedTransferGeneration: UInt64 = 11
        let nextTransferGeneration: UInt64 = 12

        #expect(MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: stateGeneration,
            transferGeneration: failedTransferGeneration,
            currentTransferGeneration: failedTransferGeneration
        ))

        var transferIsVisible = true
        if MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: stateGeneration,
            transferGeneration: failedTransferGeneration,
            currentTransferGeneration: failedTransferGeneration
        ) {
            transferIsVisible = false
        }
        #expect(!transferIsVisible) // A failed item is hidden before a cache-reused next row.

        transferIsVisible = true
        if MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: stateGeneration,
            transferGeneration: failedTransferGeneration,
            currentTransferGeneration: nextTransferGeneration
        ) {
            transferIsVisible = false
        }
        #expect(transferIsVisible) // A late failed-item defer cannot hide a newer transfer.

        if MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: stateGeneration,
            transferGeneration: nextTransferGeneration,
            currentTransferGeneration: nextTransferGeneration
        ) {
            transferIsVisible = false
        }
        #expect(!transferIsVisible) // Cancellation/failure of the final item leaves no stale card.
        #expect(!MacServerDownloadTransferStatePolicy.owns(
            stateGeneration: stateGeneration,
            currentStateGeneration: stateGeneration + 1,
            transferGeneration: nextTransferGeneration,
            currentTransferGeneration: nextTransferGeneration
        ))
    }

    @Test
    func serverDownloadReusesHydratedMetadataOnlyForTheAuthoritativeMatchingSong() throws {
        let source = "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"
        let fetched = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "server-song",
              "source_url": "\(source)",
              "media_kind": "audio",
              "size": 0,
              "download_url": "/api/v1/songs/server-song/file",
              "stream_url": "/api/v1/songs/server-song/stream"
            }
            """.utf8
        ))
        let known = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "server-song",
              "source_url": "\(source)",
              "media_kind": "audio",
              "size": 0,
              "title": "Already hydrated",
              "artist": "Catalog artist",
              "album": "Catalog album",
              "duration_seconds": 123,
              "artwork_url": "https://i.scdn.co/image/current",
              "download_url": "/api/v1/songs/server-song/file",
              "stream_url": "/api/v1/songs/server-song/stream"
            }
            """.utf8
        ))

        #expect(MacServerDownloadMetadataPolicy.immediateCatalog(
            knownSongs: [known],
            catalogIsAuthoritative: true
        )?.first?.id == known.id)
        #expect(MacServerDownloadMetadataPolicy.immediateCatalog(
            knownSongs: [known],
            catalogIsAuthoritative: false
        ) == nil)

        let reused = try #require(MacServerDownloadMetadataPolicy.reusingKnownMetadata(
            in: [fetched],
            knownSongs: [known],
            catalogIsAuthoritative: true
        ).first)
        #expect(reused.title == "Already hydrated")
        #expect(reused.artist == "Catalog artist")
        #expect(reused.isMetadataLoading == false)

        let untrusted = try #require(MacServerDownloadMetadataPolicy.reusingKnownMetadata(
            in: [fetched],
            knownSongs: [known],
            catalogIsAuthoritative: false
        ).first)
        #expect(untrusted.isMetadataLoading)
    }

    @Test
    func metadataHydrationContinuesOnlyForTheExactContextAndRequestedSources() {
        #expect(MacRemoteMetadataHydrationPolicy.canReuse(
            activeContext: "https://music.test|profile-a",
            activeRequestKeys: ["audio:https://youtu.be/one", "audio:https://youtu.be/two"],
            requestedContext: "https://music.test|profile-a",
            requestedRequestKeys: ["audio:https://youtu.be/one"]
        ))
        #expect(!MacRemoteMetadataHydrationPolicy.canReuse(
            activeContext: "https://music.test|profile-a",
            activeRequestKeys: ["audio:https://youtu.be/one"],
            requestedContext: "https://music.test|profile-b",
            requestedRequestKeys: ["audio:https://youtu.be/one"]
        ))
        #expect(!MacRemoteMetadataHydrationPolicy.canReuse(
            activeContext: "https://music.test|profile-a",
            activeRequestKeys: ["audio:https://youtu.be/one"],
            requestedContext: "https://music.test|profile-a",
            requestedRequestKeys: ["audio:https://youtu.be/two"]
        ))
    }

    @Test
    func savedSourceResolutionCacheIsProfileScopedAndRejectsCorrectedMetadata() throws {
        let source = "https://youtu.be/jNQXAC9IVRw"
        let song = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "server-song",
              "source_url": "\(source)",
              "media_kind": "audio",
              "size": 0,
              "title": "Original title",
              "artist": "Original artist",
              "download_url": "/api/v1/songs/server-song/file",
              "stream_url": "/api/v1/songs/server-song/stream"
            }
            """.utf8
        ))
        let resolution = LocalImportResolution(
            kind: .youtube,
            track: LocalImportSpotifyTrack(
                provider: "youtube",
                type: "track",
                trackID: "jNQXAC9IVRw",
                title: "Original title",
                artist: "Original artist",
                album: "Catalog album",
                trackNumber: nil,
                durationSeconds: 123,
                artworkURL: nil,
                embedURL: "",
                sourceURL: source
            ),
            candidates: [],
            releases: []
        )
        let profileA = "https://music.test|profile-a"
        let profileB = "https://music.test|profile-b"
        let keyA = MacRemoteSourceResolutionCachePolicy.key(
            serverContext: profileA,
            source: source,
            mediaMode: .audio
        )
        let keyB = MacRemoteSourceResolutionCachePolicy.key(
            serverContext: profileB,
            source: source,
            mediaMode: .audio
        )
        #expect(keyA != keyB)
        #expect(MacRemoteSourceResolutionCachePolicy.isReusable(
            resolution,
            key: keyA,
            serverContext: profileA,
            song: song,
            mediaMode: .audio
        ))
        #expect(!MacRemoteSourceResolutionCachePolicy.isReusable(
            resolution,
            key: keyA,
            serverContext: profileB,
            song: song,
            mediaMode: .audio
        ))
        #expect(!MacRemoteSourceResolutionCachePolicy.isReusable(
            resolution,
            key: keyA,
            serverContext: profileA,
            song: song,
            mediaMode: .video
        ))

        let correctedSong = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "server-song",
              "source_url": "\(source)",
              "media_kind": "audio",
              "size": 0,
              "title": "Corrected title",
              "artist": "Corrected artist",
              "download_url": "/api/v1/songs/server-song/file",
              "stream_url": "/api/v1/songs/server-song/stream"
            }
            """.utf8
        ))
        #expect(!MacRemoteSourceResolutionCachePolicy.isReusable(
            resolution,
            key: keyA,
            serverContext: profileA,
            song: correctedSong,
            mediaMode: .audio
        ))
    }

    @Test
    func cachedServerDownloadValidationIsReusableOnlyForTheExactFileSnapshot() {
        let snapshot = MacServerDownloadFileSnapshot(
            size: 4_096,
            modificationDate: Date(timeIntervalSince1970: 100),
            systemNumber: 7,
            systemFileNumber: 11
        )
        #expect(MacServerDownloadValidationPolicy.isReusable(
            validated: snapshot,
            current: snapshot
        ))
        #expect(!MacServerDownloadValidationPolicy.isReusable(
            validated: snapshot,
            current: MacServerDownloadFileSnapshot(
                size: 4_097,
                modificationDate: snapshot.modificationDate,
                systemNumber: snapshot.systemNumber,
                systemFileNumber: snapshot.systemFileNumber
            )
        ))
        #expect(!MacServerDownloadValidationPolicy.isReusable(
            validated: snapshot,
            current: MacServerDownloadFileSnapshot(
                size: snapshot.size,
                modificationDate: snapshot.modificationDate.addingTimeInterval(1),
                systemNumber: snapshot.systemNumber,
                systemFileNumber: snapshot.systemFileNumber
            )
        ))
        #expect(!MacServerDownloadValidationPolicy.isReusable(
            validated: snapshot,
            current: MacServerDownloadFileSnapshot(
                size: snapshot.size,
                modificationDate: snapshot.modificationDate,
                systemNumber: snapshot.systemNumber,
                systemFileNumber: 12
            )
        ))
        #expect(!MacServerDownloadValidationPolicy.isReusable(
            validated: snapshot,
            current: nil
        ))
    }

    @Test
    func removingDownloadPreservesPlaylistSlotOnlyWhileSongRemainsOnServer() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        let keptRemoteID = "0123456789abcdef01234567"
        let removedRemoteID = "89abcdef0123456701234567"
        let kept = Track(
            title: "Kept server song",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: keptRemoteID,
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let missing = Track(
            title: "Gone server song",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: removedRemoteID,
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let local = Track(title: "Local", artist: "Artist", album: "Album", duration: 120, artwork: .liked)
        let playlist = Playlist(
            name: "Shared",
            artwork: .liked,
            trackIDs: [local.id, kept.id, missing.id],
            remoteSongIDs: [keptRemoteID, removedRemoteID],
            entryOrder: [
                "local:\(local.id.uuidString.lowercased())",
                "remote:\(keptRemoteID)",
                "remote:\(removedRemoteID)",
            ]
        )
        model.tracks = [local, kept, missing]
        model.playlists = [.library(), playlist]
        model.remoteSongs = [try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "\(keptRemoteID)",
              "title": "Kept server song",
              "artist": "Artist",
              "download_url": "/api/v1/songs/\(keptRemoteID)/file",
              "stream_url": "/api/v1/songs/\(keptRemoteID)/stream"
            }
            """.utf8
        ))]
        model.remoteCatalogIsAuthoritative = true

        model.removeTrackFromLibrary(kept)
        var updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.trackIDs == [local.id, missing.id])
        #expect(updated.remoteSongIDs == [keptRemoteID, removedRemoteID])
        #expect(updated.entryOrder == playlist.entryOrder)
        #expect(model.playlistEntries(in: updated).map(\.id) == [
            .local(local.id),
            .remote(keptRemoteID),
            .remote(removedRemoteID),
        ])

        model.removeTrackFromLibrary(missing)
        updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.trackIDs == [local.id])
        #expect(updated.remoteSongIDs == [keptRemoteID])
        #expect(updated.entryOrder == [
            "local:\(local.id.uuidString.lowercased())",
            "remote:\(keptRemoteID)",
        ])
    }

    @Test
    func unavailableCatalogDoesNotRemoveRemotePlaylistMembership() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        let remoteID = "0123456789abcdef01234567"
        let track = Track(
            title: "Downloaded",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: remoteID,
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let playlist = Playlist(
            name: "Shared",
            artwork: .liked,
            trackIDs: [track.id],
            remoteSongIDs: [remoteID],
            entryOrder: ["remote:\(remoteID)"]
        )
        model.tracks = [track]
        model.playlists = [.library(), playlist]
        model.remoteSongs = []
        model.remoteCatalogIsAuthoritative = false

        model.removeTrackFromLibrary(track)

        let updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.remoteSongIDs == [remoteID])
        #expect(updated.entryOrder == ["remote:\(remoteID)"])
    }

    @Test
    func catalogAuthorityResetsWhenTheServerOrAccountContextChanges() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        model.remoteCatalogIsAuthoritative = true

        model.serverURLString = "https://other-music.test"
        #expect(!model.remoteCatalogIsAuthoritative)

        model.remoteCatalogIsAuthoritative = true
        model.serverToken = "different-access-token"
        #expect(!model.remoteCatalogIsAuthoritative)

        model.remoteCatalogIsAuthoritative = true
        model.clearServerCredentials()
        #expect(!model.remoteCatalogIsAuthoritative)
    }

    @MainActor
    @Test
    func committedCatalogMutationInvalidatesAuthorityBeforeMalformedResponseDecoding() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        let base = try #require(URL(string: "https://music.test"))

        model.remoteCatalogIsAuthoritative = true
        #expect(model.invalidateRemoteCatalogAuthorityAfterCommittedMutation(
            base: base,
            profileID: "default",
            statusCode: 201
        ))
        #expect(!model.remoteCatalogIsAuthoritative)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RemoteSong.self, from: Data("{".utf8))
        }

        model.remoteCatalogIsAuthoritative = true
        #expect(model.invalidateRemoteCatalogAuthorityAfterCommittedMutation(
            base: base,
            profileID: "default",
            statusCode: 409
        ))
        #expect(!model.remoteCatalogIsAuthoritative)

        model.remoteCatalogIsAuthoritative = true
        #expect(!model.invalidateRemoteCatalogAuthorityAfterCommittedMutation(
            base: base,
            profileID: "default",
            statusCode: 500
        ))
        #expect(model.remoteCatalogIsAuthoritative)

        let otherBase = try #require(URL(string: "https://other-music.test"))
        #expect(!model.invalidateRemoteCatalogAuthorityAfterCommittedMutation(
            base: otherBase,
            profileID: "default",
            statusCode: 204
        ))
        #expect(model.remoteCatalogIsAuthoritative)
    }

    @Test
    func libraryRemovalPreservesRawPlaylistOrderAndCanonicalRemoteOrder() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let local = Track(title: "X", artist: "Artist", album: "Album", duration: 120, artwork: .liked)
        let playlist = Playlist(
            name: "Raw order",
            artwork: .liked,
            trackIDs: [local.id],
            remoteSongIDs: ["A", "B"],
            entryOrder: [
                "remote:B",
                "local:\(local.id.uuidString.lowercased())",
                "remote:A",
            ]
        )
        model.tracks = [local]
        model.playlists = [.library(), playlist]

        model.removeTrackFromLibrary(local)

        let updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.remoteSongIDs == ["A", "B"])
        #expect(updated.entryOrder == ["remote:B", "remote:A"])
    }

    @Test
    func libraryRemovalAppendsConvertedRemoteMembershipWithoutReorderingExistingIDs() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        let downloaded = Track(
            title: "Downloaded C",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "C",
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let playlist = Playlist(
            name: "Converted order",
            artwork: .liked,
            trackIDs: [downloaded.id],
            remoteSongIDs: ["A", "B"],
            entryOrder: [
                "remote:B",
                "local:\(downloaded.id.uuidString.lowercased())",
                "remote:A",
            ]
        )
        model.tracks = [downloaded]
        model.playlists = [.library(), playlist]
        model.remoteSongs = [try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "C",
              "title": "Downloaded C",
              "artist": "Artist",
              "download_url": "/api/v1/songs/C/file",
              "stream_url": "/api/v1/songs/C/stream"
            }
            """.utf8
        ))]
        model.remoteCatalogIsAuthoritative = true

        model.removeTrackFromLibrary(downloaded)

        let updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.remoteSongIDs == ["A", "B", "C"])
        #expect(updated.entryOrder == ["remote:B", "remote:C", "remote:A"])
    }

    @Test
    func libraryRemovalDoesNotSynthesizeMembershipFromAnUnprovenCatalog() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        model.serverURLString = "https://music.test"
        let downloaded = Track(
            title: "Downloaded C",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "C",
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let playlist = Playlist(
            name: "Unproven conversion",
            artwork: .liked,
            trackIDs: [downloaded.id],
            remoteSongIDs: ["A", "B"],
            entryOrder: [
                "remote:B",
                "local:\(downloaded.id.uuidString.lowercased())",
                "remote:A",
            ]
        )
        model.tracks = [downloaded]
        model.playlists = [.library(), playlist]
        model.remoteSongs = []
        model.remoteCatalogIsAuthoritative = false

        model.removeTrackFromLibrary(downloaded)

        let updated = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(updated.remoteSongIDs == ["A", "B"])
        #expect(updated.entryOrder == ["remote:B", "remote:A"])
    }

    @Test
    func clipEditorPrefersTheExplicitContextMenuSong() throws {
        let current = Track(
            title: "Current", artist: "Artist", album: "Album", duration: 30,
            artwork: .midnight, fileURL: URL(fileURLWithPath: "/tmp/current.mp3")
        )
        let requested = Track(
            title: "Requested", artist: "Artist", album: "Album", duration: 30,
            artwork: .midnight, fileURL: URL(fileURLWithPath: "/tmp/requested.mp3")
        )

        #expect(ClipEditorTrackPolicy.initialTrack(
            from: [current, requested],
            requestedTrackID: requested.id,
            currentTrackID: current.id
        )?.id == requested.id)
        #expect(ClipEditorTrackPolicy.isEditable(requested) { $0 == "/tmp/requested.mp3" })

        let unavailable = Track(
            title: "Unavailable", artist: "Artist", album: "Album", duration: 30,
            artwork: .midnight
        )
        #expect(!ClipEditorTrackPolicy.isEditable(unavailable) { _ in true })
    }

    @Test
    func mixedPlaylistReordersUndownloadedSongsAndPersistsCombinedOrder() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let local = Track(title: "Local", artist: "Artist", album: "Album", duration: 120, artwork: .liked)
        let remoteA = Track(
            title: "Downloaded A",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "remote-a"
        )
        let remoteB = Track(
            title: "Downloaded B",
            artist: "Artist",
            album: "Album",
            duration: 120,
            artwork: .liked,
            remoteID: "remote-b"
        )
        let playlist = Playlist(
            name: "Shared",
            artwork: .liked,
            trackIDs: [remoteA.id, local.id, remoteB.id],
            remoteSongIDs: ["remote-b", "remote-missing", "remote-a"]
        )
        model.tracks = [local, remoteA, remoteB]
        model.playlists = [.library(), playlist]

        model.movePlaylistEntry(.remote("remote-missing"), to: 0, in: playlist.id)

        let reordered = try #require(model.playlists.first(where: { $0.id == playlist.id }))
        #expect(reordered.trackIDs == [remoteB.id, local.id, remoteA.id])
        #expect(reordered.remoteSongIDs == ["remote-missing", "remote-b", "remote-a"])
        #expect(reordered.entryOrder == [
            "remote:remote-missing",
            "remote:remote-b",
            "local:\(local.id.uuidString.lowercased())",
            "remote:remote-a",
        ])
        #expect(model.playlistEntries(in: reordered).map(\.id) == [
            .remote("remote-missing"),
            .remote("remote-b"),
            .local(local.id),
            .remote("remote-a"),
        ])

        let reloaded = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        let persisted = try #require(reloaded.playlists.first(where: { $0.id == playlist.id }))
        #expect(persisted.entryOrder == reordered.entryOrder)
        #expect(reloaded.playlistEntries(in: persisted).map(\.id) == model.playlistEntries(in: reordered).map(\.id))
    }

    @Test
    func playbackControlsKeepTheirQueueAfterNavigationAndFiltering() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])

        let first = model.tracks[0]
        let second = model.tracks[1]
        model.selectAndPlay(first)

        model.selectSection(.server)
        model.searchText = "no matching songs"
        model.filter = .video
        #expect(model.displayedTracks.isEmpty)

        model.next()
        #expect(model.currentTrackID == second.id)
        model.previous()
        #expect(model.currentTrackID == first.id)
        model.togglePlay()
    }

    @Test
    func shuffleConsumesQueueAndHistoryReflectsPlayback() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])
        let original = model.currentTrackID

        model.toggleShuffle()
        let initialQueue = model.queueTracks.map(\.id)
        #expect(initialQueue.count == 2)
        model.next()
        #expect(model.currentTrackID == initialQueue[0])
        #expect(model.queueTracks.map(\.id) == Array(initialQueue.dropFirst()))

        model.queueTab = .history
        #expect(model.queueTracks.first?.id == original)
        model.togglePlay()
    }

    @Test
    func searchFiltersAndPlaylistRemovalWorkOnRealFiles() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping])

        model.searchText = "glass"
        #expect(model.displayedTracks.count == 1)
        #expect(model.displayedTracks[0].fileURL == glass)
        model.searchText = ""
        model.filter = .video
        #expect(model.displayedTracks.isEmpty)
        model.filter = .audio
        #expect(model.displayedTracks.count == 2)

        let playlist = try #require(model.createPlaylist(named: "Temporary"))
        let track = model.tracks[0]
        model.addTrack(track, to: playlist)
        model.selectPlaylist(model.playlists.first { $0.id == playlist.id }!)
        model.removeTrackFromSelectedPlaylist(track)
        #expect(model.selectedPlaylist?.trackIDs.isEmpty == true)
        #expect(model.tracks.contains(track))

        model.removeTrackFromLibrary(track)
        #expect(model.tracks.count == 1)
        #expect(FileManager.default.fileExists(atPath: glass.path))
    }

    @Test
    func folderImportFindsSupportedAudioFiles() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: glass, to: folder.appendingPathComponent("Glass.aiff"))
        try FileManager.default.copyItem(at: ping, to: folder.appendingPathComponent("Ping.aiff"))
        try Data("not music".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [folder])
        #expect(model.tracks.count == 2)
    }

    @Test
    func authenticatedServerCatalogDownloadsIntoTheLibrary() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let audioData = try Data(contentsOf: glass)
        let identifier = "0123456789abcdef01234567"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        MockMusicURLProtocol.handler = { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer client-token-123" else {
                throw URLError(.userAuthenticationRequired)
            }
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")
            #expect(!(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key") ?? "").isEmpty)
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                let payload: [String: Any] = [
                    "count": 1,
                    "songs": [[
                        "id": identifier,
                        "filename": "Glass.aiff",
                        "title": "Glass",
                        "artist": "System Sounds",
                        "album": "Shared Library",
                        "size": audioData.count,
                        "modified_at": "2026-07-11T00:00:00+00:00",
                        "content_type": "audio/aiff",
                        "source_url": "https://media.example/Glass.aiff?token=preserved",
                        "download_url": "/api/v1/songs/\(identifier)/file",
                        "stream_url": "/api/v1/songs/\(identifier)/stream",
                    ]],
                ]
                let data = try JSONSerialization.data(withJSONObject: payload)
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
            }
            if url.path == "/api/v1/songs/\(identifier)/file" {
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/aiff"])!, audioData)
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test:8765"
        model.serverToken = "client-token-123"
        await model.syncServerLibrary()

        #expect(model.remoteSongs.count == 1)
        #expect(model.tracks.count == 1)
        #expect(model.tracks[0].remoteID == identifier)
        #expect(model.tracks[0].sourceServer == "https://music.test:8765")
        #expect(model.tracks[0].downloadSourceURL == "https://media.example/Glass.aiff?token=preserved")
        #expect(model.tracks[0].fileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        #expect(model.serverMessage == "Synced 1 song")
    }

    @Test
    func playlistSyncBootstrapsLocalStateAndPreservesSongOrder() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        let firstRemoteID = "0123456789abcdef01234567"
        let secondRemoteID = "89abcdef0123456701234567"
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        let first = Track(title: "First", artist: "Artist", album: "Album", duration: 1, artwork: .electric, fileURL: glass, remoteID: firstRemoteID, sourceServer: "https://music.test", syncProfileID: "default")
        let second = Track(title: "Second", artist: "Artist", album: "Album", duration: 1, artwork: .golden, fileURL: ping, remoteID: secondRemoteID, sourceServer: "https://music.test", syncProfileID: "default")
        let localOnly = Track(title: "Local", artist: "Artist", album: "Album", duration: 1, artwork: .softFocus, fileURL: hero)
        model.tracks = [first, localOnly, second]
        let playlist = try #require(model.createPlaylist(named: "Synced Order"))
        model.addTrack(second, to: playlist)
        model.addTrack(localOnly, to: model.playlists.first { $0.id == playlist.id }!)
        model.addTrack(first, to: model.playlists.first { $0.id == playlist.id }!)

        var uploadedDocument: RemotePlaylistsDocument?
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer playlist-token" else {
                throw URLError(.userAuthenticationRequired)
            }
            if request.httpMethod == "GET", url.path == "/api/v1/playlists" {
                let document = RemotePlaylistsDocument(revision: 0, playlists: [])
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            if request.httpMethod == "PUT", url.path == "/api/v1/playlists" {
                let body = try requestBodyData(request)
                var document = try JSONDecoder().decode(RemotePlaylistsDocument.self, from: body)
                uploadedDocument = document
                document.revision = 1
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        await model.syncPlaylistsNow()

        #expect(uploadedDocument?.revision == 0)
        #expect(uploadedDocument?.playlists.first?.name == "Synced Order")
        #expect(uploadedDocument?.playlists.first?.songIDs == [secondRemoteID, firstRemoteID])
        #expect(model.customPlaylists.first?.trackIDs == [second.id, localOnly.id, first.id])
        #expect(model.playlistSyncStatus == "Synced 1 playlist")
    }

    @Test
    func playlistSyncRetriesARevisionConflictAndAppliesRemoteMembership() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockMusicURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MockMusicURLProtocol.handler = nil
        }

        let remoteID = "fedcba9876543210fedcba98"
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false
        )
        let track = Track(title: "Remote", artist: "Artist", album: "Album", duration: 1, artwork: .electric, fileURL: glass, remoteID: remoteID, sourceServer: "https://music.test", syncProfileID: "default")
        model.tracks = [track]
        let playlist = try #require(model.createPlaylist(named: "Conflict Safe"))
        model.addTrack(track, to: playlist)

        var putCount = 0
        MockMusicURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                let document = RemotePlaylistsDocument(revision: 4, playlists: [])
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            if request.httpMethod == "PUT" {
                putCount += 1
                let body = try requestBodyData(request)
                var document = try JSONDecoder().decode(RemotePlaylistsDocument.self, from: body)
                if putCount == 1 {
                    let conflict = RemotePlaylistsDocument(revision: 5, playlists: [])
                    return (HTTPURLResponse(url: url, statusCode: 409, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(conflict))
                }
                #expect(document.revision == 5)
                document.revision = 6
                return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, try JSONEncoder().encode(document))
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        await model.syncPlaylistsNow()

        #expect(putCount == 2)
        #expect(model.customPlaylists.first?.trackIDs == [track.id])
        #expect(model.customPlaylists.first?.remoteSongIDs == [remoteID])
        #expect(model.playlistSyncStatus == "Synced 1 playlist")
    }
}
