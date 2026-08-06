import Foundation
import Testing
@testable import LikedSongsFocus

private final class RegressionURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
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

private final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if signaled {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func signal() {
        lock.lock()
        signaled = true
        let waiting = continuations
        continuations.removeAll()
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}

private final class LockedPlaylistServerState: @unchecked Sendable {
    private let lock = NSLock()
    private var document: RemotePlaylistsDocument
    private var putCount = 0

    init(document: RemotePlaylistsDocument = RemotePlaylistsDocument(revision: 0, playlists: [])) {
        self.document = document
    }

    func currentDocument() -> RemotePlaylistsDocument {
        lock.withLock { document }
    }

    func beginPut() -> Int {
        lock.withLock {
            putCount += 1
            return putCount
        }
    }

    func accept(_ uploaded: RemotePlaylistsDocument) -> RemotePlaylistsDocument {
        lock.withLock {
            var accepted = uploaded
            accepted.revision = document.revision + 1
            document = accepted
            return accepted
        }
    }

    func snapshot() -> (putCount: Int, document: RemotePlaylistsDocument) {
        lock.withLock { (putCount, document) }
    }

    func replace(with document: RemotePlaylistsDocument) {
        lock.withLock {
            self.document = document
        }
    }
}

private func regressionRequestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { throw URLError(.cannotDecodeContentData) }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }
        result.append(buffer, count: count)
    }
    return result
}

private struct LegacyListeningHistoryEntry: Encodable {
    let id: UUID
    let trackID: UUID
    let startedAt: Date
    let listenedSeconds: TimeInterval
}

@MainActor
@Suite(.serialized)
struct PlayerModelRegressionTests {
    private let glass = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
    private let ping = URL(fileURLWithPath: "/System/Library/Sounds/Ping.aiff")
    private let hero = URL(fileURLWithPath: "/System/Library/Sounds/Hero.aiff")

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "PlayerModelRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayerModelRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func copiedAudioFixtures(in directory: URL) throws -> [URL] {
        let sources = [glass, ping, hero]
        return try sources.enumerated().map { index, source in
            let destination = directory.appendingPathComponent("fixture-\(index).aiff")
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        }
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RegressionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func response(for request: URLRequest, status: Int = 200) throws -> HTTPURLResponse {
        HTTPURLResponse(
            url: try #require(request.url),
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    @Test
    func listeningHistoryUploadsEveryLocalProfileAndMergesTheActiveProfile() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let seed = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await seed.importLocalFiles(at: [hero])
        let localTrack = try #require(seed.tracks.first)
        let defaultEventID = UUID()
        let otherProfileEventID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(
            try JSONEncoder().encode([
                ListeningHistoryEntry(
                    id: defaultEventID,
                    trackID: localTrack.id,
                    startedAt: startedAt,
                    listenedSeconds: 42,
                    syncProfileID: "default",
                    title: "Mac song",
                    artist: "Mac artist",
                    originatedOnThisDevice: true
                ),
                ListeningHistoryEntry(
                    id: otherProfileEventID,
                    trackID: localTrack.id,
                    startedAt: startedAt.addingTimeInterval(30),
                    listenedSeconds: 18,
                    syncProfileID: "profile-b",
                    title: "Other profile song",
                    originatedOnThisDevice: true
                ),
            ]),
            forKey: "LikedSongsFocus.listeningHistory.v1"
        )

        let remoteEventID = UUID()
        let remoteTrackID = UUID()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var postedProfiles: [String] = []
        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/listening-history")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            let profileID = try #require(request.value(forHTTPHeaderField: "X-Resonance-Profile"))
            if request.httpMethod == "POST" {
                postedProfiles.append(profileID)
                let body = try #require(
                    try JSONSerialization.jsonObject(with: regressionRequestBody(request)) as? [String: Any]
                )
                #expect(body["client"] as? String == "macos")
                #expect(!(body["device_id"] as? String ?? "").isEmpty)
                let entries = try #require(body["entries"] as? [[String: Any]])
                #expect(entries.count == 1)
                #expect(((entries[0]["listened_seconds"] as? Double) ?? 0) > 0)
                return (
                    try response(for: request),
                    Data("{\"profile_id\":\"\(profileID)\",\"accepted\":1}".utf8)
                )
            }

            #expect(request.httpMethod == "GET")
            #expect(profileID == "default")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "limit" })?.value == "2000")
            let document: [String: Any] = [
                "profile_id": "default",
                "entries": [[
                    "id": remoteEventID.uuidString.lowercased(),
                    "track_id": remoteTrackID.uuidString.lowercased(),
                    "started_at": formatter.string(from: startedAt.addingTimeInterval(60)),
                    "listened_seconds": 75,
                    "title": "Windows song",
                    "artist": "Windows artist",
                    "duration_seconds": 180,
                ]],
            ]
            return (
                try response(for: request),
                try JSONSerialization.data(withJSONObject: document)
            )
        }

        let model = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        await model.syncListeningHistoryNow()

        #expect(Set(postedProfiles) == Set(["default", "profile-b"]))
        #expect(model.activeProfileListeningHistoryEntries.count == 2)
        #expect(model.listeningHistoryEntries.contains(where: {
            $0.id == otherProfileEventID && $0.syncProfileID == "profile-b"
        }))
        let remoteEntry = try #require(
            model.listeningHistoryEntries.first(where: { $0.id == remoteEventID })
        )
        #expect(remoteEntry.originatedOnThisDevice == false)
        #expect(remoteEntry.title == "Windows song")
        model.queueTab = .history
        let serverOnlyQueueTrack = try #require(model.queueTracks.first)
        #expect(serverOnlyQueueTrack.id == remoteTrackID)
        #expect(serverOnlyQueueTrack.title == "Windows song")
        #expect(serverOnlyQueueTrack.artist == "Windows artist")
        #expect(serverOnlyQueueTrack.fileURL == nil)

        let reloaded = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )
        #expect(reloaded.listeningHistoryEntries.contains(where: { $0.id == remoteEventID }))
    }

    private func catalog(
        id: String,
        filename: String = "Glass.aiff",
        size: Int,
        downloadURL: String
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "count": 1,
            "songs": [[
                "id": id,
                "filename": filename,
                "title": "Remote song",
                "artist": "Remote artist",
                "album": "Remote album",
                "size": size,
                "modified_at": "2026-07-16T00:00:00Z",
                "content_type": "audio/aiff",
                "download_url": downloadURL,
                "stream_url": "/stream/\(id)",
            ]],
        ])
    }

    private func emptyCatalog() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["count": 0, "songs": []])
    }

    private func emptyPlaylists() throws -> Data {
        try JSONEncoder().encode(RemotePlaylistsDocument(revision: 0, playlists: []))
    }

    @Test
    func metadataBackfillUsesAdminAuthorizationAndDefaultServerContextUntilComplete() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        var requestCount = 0
        RegressionURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.url?.path == "/api/v1/admin/metadata")
            #expect(request.url?.query == "limit=8")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "default")
            let payload: [String: Any] = requestCount == 1
                ? ["processed": 8, "remaining": 2]
                : ["processed": 2, "remaining": 0]
            return (
                try response(for: request),
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverAdminToken = "admin-token"

        let processed = try await model.backfillServerMetadataIfAvailable(
            base: URL(string: "https://music.test")!
        )

        #expect(processed == 10)
        #expect(requestCount == 2)
    }

    @Test
    func selectedServerProfilePersistsAcrossModelRelaunch() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/profiles")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == nil)
            let payload: [String: Any] = [
                "default_profile_id": "default",
                "profiles": [
                    ["id": "default", "name": "Default", "is_default": true],
                    ["id": "drastic-id", "name": "Drastic", "is_default": false],
                ],
            ]
            return (
                try response(for: request),
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        #expect(await model.selectSyncProfile(matching: "Drastic"))
        #expect(model.syncProfileID == "drastic-id")
        #expect(model.activeSyncProfileName == "Drastic")

        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        #expect(relaunched.syncProfileID == "drastic-id")
        #expect(relaunched.activeSyncProfileName == "Drastic")
    }

    @Test
    func missingRequestedProfileFallsBackToDefaultWithoutSendingItsStaleHeader() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        var includeDrastic = true
        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/profiles")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == nil)
            var profiles: [[String: Any]] = [
                ["id": "default", "name": "Default", "is_default": true],
            ]
            if includeDrastic {
                profiles.append(["id": "drastic-id", "name": "Drastic", "is_default": false])
            }
            let payload: [String: Any] = [
                "default_profile_id": "default",
                "profiles": profiles,
            ]
            return (
                try response(for: request),
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        #expect(await model.selectSyncProfile(matching: "Drastic"))
        #expect(model.createPlaylist(named: "Unsynced Drastic playlist") != nil)
        includeDrastic = false

        #expect(await model.selectSyncProfile(matching: "Drastic"))
        #expect(model.syncProfileID == "default")
        #expect(model.activeSyncProfileName == "Default")
        #expect(model.serverMessage == "Profile “Drastic” was not found • Switched to Default")
    }

    @Test
    func legacyListeningHistoryMigratesToTheRestoredProfile() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await initial.importLocalFiles(at: [hero])
        let track = try #require(initial.tracks.first)
        let legacyEntry = LegacyListeningHistoryEntry(
            id: UUID(),
            trackID: track.id,
            startedAt: .now,
            listenedSeconds: 42
        )
        defaults.set(
            try JSONEncoder().encode([legacyEntry]),
            forKey: "LikedSongsFocus.listeningHistory.v1"
        )

        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )

        #expect(relaunched.listeningHistoryEntries.count == 1)
        #expect(relaunched.listeningHistoryEntries.first?.syncProfileID == "default")
        #expect(relaunched.activeProfileListeningHistoryEntries.count == 1)
        let migratedData = try #require(
            defaults.data(forKey: "LikedSongsFocus.listeningHistory.v1")
        )
        let migrated = try JSONDecoder().decode(
            [ListeningHistoryEntry].self,
            from: migratedData
        )
        #expect(migrated.first?.syncProfileID == "default")
    }

    @Test
    func listeningHistoryIsIsolatedWhenSwitchingProfiles() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/profiles")
            let payload: [String: Any] = [
                "default_profile_id": "default",
                "profiles": [
                    ["id": "default", "name": "Default", "is_default": true],
                    ["id": "drastic-id", "name": "Drastic", "is_default": false],
                ],
            ]
            return (
                try response(for: request),
                try JSONSerialization.data(withJSONObject: payload)
            )
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [hero])
        let track = try #require(model.tracks.first)
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        model.selectAndPlay(track)
        try await Task.sleep(for: .milliseconds(300))
        model.togglePlay()
        #expect(model.listeningHistoryEntries.count == 1)
        #expect(model.activeProfileListeningHistoryEntries.count == 1)
        #expect(model.activeProfileListeningHistoryEntries.first?.syncProfileID == "default")

        #expect(await model.selectSyncProfile(matching: "Drastic"))
        #expect(model.activeProfileListeningHistoryEntries.isEmpty)

        model.togglePlay()
        try await Task.sleep(for: .milliseconds(300))
        model.togglePlay()
        #expect(model.listeningHistoryEntries.count == 2)
        #expect(model.activeProfileListeningHistoryEntries.count == 1)
        #expect(model.activeProfileListeningHistoryEntries.first?.syncProfileID == "drastic-id")

        #expect(await model.selectSyncProfile(matching: "Default"))
        #expect(model.activeProfileListeningHistoryEntries.count == 1)
        #expect(model.activeProfileListeningHistoryEntries.first?.syncProfileID == "default")
    }

    @Test
    func traversalSongIdentifierIsRejectedBeforeCacheOrNetworkUse() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        var downloadRequested = false
        let unsafeID = "../../../escaped"
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (try response(for: request), try catalog(id: unsafeID, size: 4, downloadURL: "/file"))
            }
            if url.path == "/api/v1/playlists" {
                return (try response(for: request), try emptyPlaylists())
            }
            downloadRequested = true
            return (try response(for: request), Data("evil".utf8))
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "token"
        await model.syncServerLibrary()

        #expect(!downloadRequested)
        #expect(model.tracks.isEmpty)
        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("escaped.aiff").path))
    }

    @Test
    func crossOriginDownloadIsRejectedBeforeAuthorizationIsAttached() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        var evilServerWasContacted = false
        var leakedAuthorization: String?
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.host == "evil.test" {
                evilServerWasContacted = true
                leakedAuthorization = request.value(forHTTPHeaderField: "Authorization")
                return (try response(for: request), try Data(contentsOf: glass))
            }
            if url.path == "/api/v1/songs" {
                return (
                    try response(for: request),
                    try catalog(id: "safe-id", size: 1, downloadURL: "https://evil.test/stolen.aiff")
                )
            }
            return (try response(for: request), try emptyPlaylists())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "secret-token"
        await model.syncServerLibrary()

        #expect(!evilServerWasContacted)
        #expect(leakedAuthorization == nil)
        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
    }

    @Test
    func traversalSongIdentifierIsRejectedBeforeAdminDeleteRequest() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        var requestWasSent = false
        RegressionURLProtocol.handler = { request in
            requestWasSent = true
            return (try response(for: request), Data())
        }
        let maliciousCatalog = try catalog(
            id: "../../playlists",
            size: 1,
            downloadURL: "/unused"
        )
        let song = try #require(try JSONDecoder().decode(RemoteCatalog.self, from: maliciousCatalog).songs.first)
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverAdminToken = "admin-token"

        model.deleteRemoteSong(song)
        for _ in 0..<100 where model.serverMessage == "Not connected" {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!requestWasSent)
        #expect(model.serverMessage.contains("unsafe song identifier"))
    }

    @Test
    func playlistMutationsDuringPutSurviveTheStaleResponse() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let first = Track(
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "first-remote-id"
        )
        let second = Track(
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .golden,
            fileURL: ping,
            remoteID: "second-remote-id"
        )
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.tracks = [first, second]
        let playlist = try #require(model.createPlaylist(named: "Keep edits"))
        model.addTrack(first, to: playlist)
        let doomed = try #require(model.createPlaylist(named: "Delete during sync"))
        model.addTrack(first, to: doomed)

        let putStarted = AsyncSignal()
        let releaseFirstPut = DispatchSemaphore(value: 0)
        let serverState = LockedPlaylistServerState()
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            guard url.path == "/api/v1/playlists" else {
                return (try response(for: request, status: 404), Data())
            }
            if request.httpMethod == "GET" {
                return (
                    try response(for: request),
                    try JSONEncoder().encode(serverState.currentDocument())
                )
            }

            let uploaded = try JSONDecoder().decode(
                RemotePlaylistsDocument.self,
                from: regressionRequestBody(request)
            )
            let thisPut = serverState.beginPut()
            if thisPut == 1 {
                putStarted.signal()
                _ = releaseFirstPut.wait(timeout: .now() + 5)
            }
            let accepted = serverState.accept(uploaded)
            return (try response(for: request), try JSONEncoder().encode(accepted))
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        let sync = Task { await model.syncPlaylistsNow() }
        await putStarted.wait()

        model.addTrack(second, to: try #require(model.playlists.first { $0.id == playlist.id }))
        model.moveTrack(second.id, to: 0, in: playlist.id)
        model.deletePlaylist(try #require(model.playlists.first { $0.id == doomed.id }))
        releaseFirstPut.signal()
        await sync.value

        for _ in 0..<200 {
            let snapshot = serverState.snapshot()
            let isFinal = snapshot.putCount >= 2 && snapshot.document.revision >= 2
            if isFinal { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        while model.isSyncingPlaylists {
            try await Task.sleep(for: .milliseconds(10))
        }

        let preserved = try #require(model.playlists.first { $0.id == playlist.id })
        #expect(preserved.trackIDs == [second.id, first.id])
        #expect(!model.playlists.contains { $0.id == doomed.id })
        let finalSnapshot = serverState.snapshot()
        let finalPutCount = finalSnapshot.putCount
        let finalServerDocument = finalSnapshot.document
        #expect(finalPutCount == 2)
        #expect(finalServerDocument.playlists.count == 1)
        #expect(finalServerDocument.playlists.first?.id == playlist.id)
        #expect(finalServerDocument.playlists.first?.songIDs == [second.remoteID, first.remoteID].compactMap { $0 })
        try await Task.sleep(for: .milliseconds(30))
        let putCountAfterSettling = serverState.snapshot().putCount
        #expect(putCountAfterSettling == finalPutCount)
    }

    @Test
    func serverLikesPopulateAndRemoveTracksFromLikedSongs() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let remote = Track(
            title: "Remote",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "remote-like-id"
        )
        let local = Track(
            title: "Local",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .golden,
            fileURL: ping
        )
        let serverState = LockedPlaylistServerState(
            document: RemotePlaylistsDocument(
                revision: 1,
                playlists: [],
                likedSongIDs: ["remote-like-id"]
            )
        )
        RegressionURLProtocol.handler = { request in
            let document = serverState.currentDocument()
            return (try response(for: request), try JSONEncoder().encode(document))
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.tracks = [remote, local]
        model.toggleFavorite(local)
        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"

        await model.syncPlaylistsNow()

        #expect(model.favorites == [remote.id, local.id])
        #expect(Set(model.playlists[0].trackIDs) == [remote.id, local.id])

        serverState.replace(
            with: RemotePlaylistsDocument(
                revision: 2,
                playlists: [],
                likedSongIDs: []
            )
        )
        await model.syncPlaylistsNow()

        #expect(model.favorites == [local.id])
        #expect(model.playlists[0].trackIDs == [local.id])
    }

    @Test
    func unrelatedPlaylistUploadPreservesServerLikes() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let track = Track(
            title: "Remote",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "remote-like-id"
        )
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.tracks = [track]
        _ = try #require(model.createPlaylist(named: "Local edit"))

        var uploaded: RemotePlaylistsDocument?
        RegressionURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                var document = try JSONDecoder().decode(
                    RemotePlaylistsDocument.self,
                    from: regressionRequestBody(request)
                )
                uploaded = document
                document.revision += 1
                return (try response(for: request), try JSONEncoder().encode(document))
            }
            let remote = RemotePlaylistsDocument(
                revision: 4,
                playlists: [],
                likedSongIDs: ["remote-like-id", "not-downloaded-like-id"]
            )
            return (try response(for: request), try JSONEncoder().encode(remote))
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        await model.syncPlaylistsNow()

        #expect(uploaded?.likedSongIDs == ["remote-like-id", "not-downloaded-like-id"])
        #expect(model.favorites == [track.id])
        #expect(model.playlists[0].trackIDs == [track.id])
    }

    @Test
    func likeChangedDuringPutSurvivesTheStaleResponse() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let first = Track(
            title: "First",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "first-remote-id"
        )
        let second = Track(
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .golden,
            fileURL: ping,
            remoteID: "second-remote-id"
        )
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.tracks = [first, second]
        model.toggleFavorite(first)

        let putStarted = AsyncSignal()
        let releaseFirstPut = DispatchSemaphore(value: 0)
        let serverState = LockedPlaylistServerState()
        RegressionURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (
                    try response(for: request),
                    try JSONEncoder().encode(serverState.currentDocument())
                )
            }
            let uploaded = try JSONDecoder().decode(
                RemotePlaylistsDocument.self,
                from: regressionRequestBody(request)
            )
            let thisPut = serverState.beginPut()
            if thisPut == 1 {
                putStarted.signal()
                _ = releaseFirstPut.wait(timeout: .now() + 5)
            }
            let accepted = serverState.accept(uploaded)
            return (try response(for: request), try JSONEncoder().encode(accepted))
        }

        model.serverURLString = "https://music.test"
        model.serverToken = "playlist-token"
        let sync = Task { await model.syncPlaylistsNow() }
        await putStarted.wait()

        model.toggleFavorite(second)
        releaseFirstPut.signal()
        await sync.value

        for _ in 0..<200 {
            if serverState.snapshot().putCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        while model.isSyncingPlaylists {
            try await Task.sleep(for: .milliseconds(10))
        }

        let snapshot = serverState.snapshot()
        #expect(snapshot.putCount == 2)
        #expect(snapshot.document.likedSongIDs == ["first-remote-id", "second-remote-id"])
        #expect(model.favorites == [first.id, second.id])
        #expect(model.playlists[0].trackIDs == [first.id, second.id])
    }

    @Test
    func unavailableTrackAndMembershipRemainPersistedAcrossLaunch() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporarilyUnavailable = directory.appendingPathComponent("external.aiff")
        try FileManager.default.copyItem(at: glass, to: temporarilyUnavailable)

        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let track = Track(
            title: "External",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: temporarilyUnavailable
        )
        model.tracks = [track]
        model.currentTrackID = track.id
        model.toggleFavorite(track)
        let playlist = try #require(model.createPlaylist(named: "External playlist"))
        model.addTrack(track, to: playlist)
        try FileManager.default.removeItem(at: temporarilyUnavailable)

        let relaunched = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(relaunched.tracks.map(\.id) == [track.id])
        #expect(relaunched.favorites == [track.id])
        #expect(relaunched.playlists.first(where: { $0.id == playlist.id })?.trackIDs == [track.id])
    }

    @Test
    func corruptLibraryBytesArePreservedForRecovery() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = Data("not valid library json".utf8)
        defaults.set(corrupt, forKey: "LikedSongsFocus.library.v2")

        let model = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)

        #expect(model.tracks.isEmpty)
        #expect(defaults.data(forKey: "LikedSongsFocus.library.v2") == corrupt)
        #expect(defaults.data(forKey: "LikedSongsFocus.library.v2.recovery") == corrupt)
    }

    @Test
    func downloadAllNeverRemovesCatalogAbsentTracksOrMemberships() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (try response(for: request), try emptyCatalog())
            }
            if request.httpMethod == "PUT" {
                var document = try JSONDecoder().decode(
                    RemotePlaylistsDocument.self,
                    from: regressionRequestBody(request)
                )
                document.revision += 1
                return (try response(for: request), try JSONEncoder().encode(document))
            }
            return (try response(for: request), try emptyPlaylists())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        let track = Track(
            title: "Catalog absent",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "absent-id",
            sourceServer: "https://music.test"
        )
        model.tracks = [track]
        model.toggleFavorite(track)
        let playlist = try #require(model.createPlaylist(named: "Keep membership"))
        model.addTrack(track, to: playlist)
        model.serverURLString = "https://music.test"
        model.serverToken = "token"

        await model.syncServerLibrary(reconcile: true)

        #expect(model.tracks.map(\.id) == [track.id])
        #expect(model.favorites.contains(track.id))
        #expect(model.playlists.first(where: { $0.id == playlist.id })?.trackIDs == [track.id])
    }

    @Test
    func invalidDownloadIsCleanedUpCountedFailedAndRetried() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let invalid = Data("this is not audio".utf8)
        var downloadCount = 0
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (
                    try response(for: request),
                    try catalog(
                        id: "invalid-media-id",
                        filename: "invalid.aiff",
                        size: invalid.count,
                        downloadURL: "/invalid.aiff"
                    )
                )
            }
            if url.path == "/invalid.aiff" {
                downloadCount += 1
                return (try response(for: request), invalid)
            }
            return (try response(for: request), try emptyPlaylists())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "token"
        await model.syncServerLibrary()
        await model.syncServerLibrary()

        #expect(downloadCount == 2)
        #expect(model.tracks.isEmpty)
        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
        let files = FileManager.default.enumerator(at: cacheRoot, includingPropertiesForKeys: nil)?
            .allObjects.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(files.isEmpty)
    }

    @Test
    func validSameSizeCacheRepairsAStaleTrackURLWithoutRedownloading() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let audio = try Data(contentsOf: glass)
        var downloadCount = 0
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (
                    try response(for: request),
                    try catalog(
                        id: "cached-song-id",
                        size: audio.count,
                        downloadURL: "/cached.aiff"
                    )
                )
            }
            if url.path == "/cached.aiff" {
                downloadCount += 1
                return (try response(for: request), audio)
            }
            return (try response(for: request), try emptyPlaylists())
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            serverCacheRoot: cacheRoot,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "token"
        await model.syncServerLibrary()
        let cachedURL = try #require(model.tracks.first?.fileURL)
        model.tracks[0].fileURL = cacheRoot.appendingPathComponent("stale-location.aiff")

        await model.syncServerLibrary()

        #expect(downloadCount == 1)
        #expect(model.tracks.first?.fileURL?.standardizedFileURL == cachedURL.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        let relaunched = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(relaunched.tracks.first?.fileURL?.standardizedFileURL == cachedURL.standardizedFileURL)
    }

    @Test
    func shufflePreviousUsesHistoryAndPreservesRemainingQueue() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])
        let original = try #require(model.currentTrackID)
        model.selectAndPlay(try #require(model.currentTrack))
        model.toggleShuffle()
        let initialQueue = model.queueTracks.map(\.id)

        model.next()
        let departed = try #require(model.currentTrackID)
        model.position = 0
        model.previous()

        #expect(model.currentTrackID == original)
        #expect(model.queueTracks.map(\.id) == [departed] + Array(initialQueue.dropFirst()))
        model.next()
        #expect(model.currentTrackID == departed)
        if model.isPlaying { model.togglePlay() }
    }

    @Test
    func navigationAndPlaylistSyncPreserveAnActiveShuffleQueue() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        RegressionURLProtocol.handler = { request in
            (try response(for: request), try emptyPlaylists())
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [glass, ping, hero])
        model.selectAndPlay(try #require(model.currentTrack))
        model.toggleShuffle()
        let originalQueue = model.queueTracks.map(\.id)

        model.selectSection(.server)
        #expect(model.queueTracks.map(\.id) == originalQueue)
        model.serverURLString = "https://music.test"
        model.serverToken = "token"
        await model.syncPlaylistsNow()

        #expect(model.queueTracks.map(\.id) == originalQueue)
        if model.isPlaying { model.togglePlay() }
    }

    @Test
    func failedFilesystemDeletionKeepsTheLibraryRecord() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        let track = Track(
            title: "Missing file",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        model.tracks = [track]

        let deleted = model.deleteOriginalFile(track)

        #expect(!deleted)
        #expect(model.tracks == [track])
        #expect(model.fileOperationError?.contains("Couldn’t delete") == true)
    }

    @Test
    func playlistContextAndRemainingShuffleQueueRestoreAcrossRelaunch() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping, hero])
        let playlist = try #require(model.createPlaylist(named: "Persistent queue"))
        for track in model.tracks { model.addTrack(track, to: playlist) }
        model.selectPlaylist(try #require(model.playlists.first { $0.id == playlist.id }))
        model.selectAndPlay(try #require(model.displayedTracks.first))
        model.toggleShuffle()
        let initialQueue = model.queueTracks.map(\.id)
        model.next()
        let currentAfterNext = model.currentTrackID
        let remainingQueue = Array(initialQueue.dropFirst())
        if model.isPlaying { model.togglePlay() }

        let relaunched = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(relaunched.currentTrackID == currentAfterNext)
        #expect(relaunched.shuffleEnabled)
        #expect(relaunched.queueTracks.map(\.id) == remainingQueue)
        if let nextID = remainingQueue.first {
            relaunched.next()
            #expect(relaunched.currentTrackID == nextID)
        }
        if relaunched.isPlaying { relaunched.togglePlay() }
    }

    @Test
    func reversedSubsetPlaylistContextRestoresForNonShuffleNext() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures = try copiedAudioFixtures(in: directory)
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: fixtures)
        let firstInLibrary = try #require(model.tracks.first)
        let lastInLibrary = try #require(model.tracks.last)
        let playlist = try #require(model.createPlaylist(named: "Reversed subset"))
        model.addTrack(lastInLibrary, to: playlist)
        model.addTrack(firstInLibrary, to: try #require(model.playlists.first { $0.id == playlist.id }))
        model.selectPlaylist(try #require(model.playlists.first { $0.id == playlist.id }))
        model.selectAndPlay(lastInLibrary)
        if model.isPlaying { model.togglePlay() }

        let relaunched = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(!relaunched.shuffleEnabled)
        #expect(relaunched.currentTrackID == lastInLibrary.id)
        relaunched.next()
        #expect(relaunched.currentTrackID == firstInLibrary.id)
        if relaunched.isPlaying { relaunched.togglePlay() }
    }

    @Test
    func removingCurrentTrackPersistsReplacementAndZeroPosition() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(loadPersistedLibrary: false, defaults: defaults, persistServerCredentials: false)
        await model.importLocalFiles(at: [glass, ping])
        let removed = try #require(model.tracks.first)
        let replacement = try #require(model.tracks.last)
        model.selectAndPlay(removed)
        model.seek(to: 0.5)
        model.removeTrackFromLibrary(removed)

        #expect(model.currentTrackID == replacement.id)
        #expect(model.position == 0)
        let relaunched = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)
        #expect(relaunched.currentTrackID == replacement.id)
        #expect(relaunched.position == 0)
        #expect(!relaunched.tracks.contains { $0.id == removed.id })
    }
}
