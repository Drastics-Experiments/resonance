import CryptoKit
import Foundation
import Testing
@testable import Resonance

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

private final class LockedRegressionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class DelayedCatalogRegressionURLProtocol: URLProtocol {
    static var catalogStarted: AsyncSignal?
    static var releaseCatalog: DispatchSemaphore?
    static var uploadStarted: AsyncSignal?
    static var releaseUpload: DispatchSemaphore?
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        if request.httpMethod == "GET", url.path == "/api/v1/songs" {
            Self.catalogStarted?.signal()
            DispatchQueue.global().async { [self] in
                _ = Self.releaseCatalog?.wait(timeout: .now() + 5)
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"count":0,"songs":[]}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        if request.httpMethod == "PUT",
           let uploadStarted = Self.uploadStarted,
           let releaseUpload = Self.releaseUpload {
            uploadStarted.signal()
            DispatchQueue.global().async { [self] in
                _ = releaseUpload.wait(timeout: .now() + 5)
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
            return
        }
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

    static func reset() {
        catalogStarted = nil
        releaseCatalog = nil
        uploadStarted = nil
        releaseUpload = nil
        handler = nil
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

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
        let defaultSongID = UUID().uuidString.lowercased()
        let otherProfileSongID = UUID().uuidString.lowercased()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(
            try JSONEncoder().encode([
                ListeningHistoryEntry(
                    id: defaultEventID,
                    trackID: localTrack.id,
                    startedAt: startedAt,
                    listenedSeconds: 42,
                    serverOrigin: "https://music.test",
                    syncProfileID: "default",
                    remoteSongID: defaultSongID,
                    title: "Mac song",
                    artist: "Mac artist",
                    originatedOnThisDevice: true
                ),
                ListeningHistoryEntry(
                    id: otherProfileEventID,
                    trackID: localTrack.id,
                    startedAt: startedAt.addingTimeInterval(30),
                    listenedSeconds: 18,
                    serverOrigin: "https://music.test",
                    syncProfileID: "profile-b",
                    remoteSongID: otherProfileSongID,
                    title: "Other profile song",
                    originatedOnThisDevice: true
                ),
            ]),
            forKey: "Resonance.listeningHistory.v1"
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
                #expect(Set(body.keys) == ["entries"])
                let entries = try #require(body["entries"] as? [[String: Any]])
                #expect(entries.count == 1)
                #expect(entries[0]["track_id"] as? String == localTrack.id.uuidString.lowercased())
                #expect(entries[0]["song_id"] as? String == (
                    profileID == "default" ? defaultSongID : otherProfileSongID
                ))
                #expect(entries[0]["title"] as? String == (
                    profileID == "default" ? "Mac song" : "Other profile song"
                ))
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
                    "song_id": remoteTrackID.uuidString.lowercased(),
                    "started_at": formatter.string(from: startedAt.addingTimeInterval(60)),
                    "listened_seconds": 75,
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
        #expect(remoteEntry.remoteSongID == remoteTrackID.uuidString.lowercased())
        #expect(remoteEntry.title == nil)
        #expect(remoteEntry.artist == nil)
        model.queueTab = .history
        #expect(!model.queueTracks.contains(where: { $0.id == remoteTrackID }))
        #expect(model.queueTracks.contains(where: { $0.id == localTrack.id }))

        let reloaded = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )
        #expect(reloaded.listeningHistoryEntries.contains(where: { $0.id == remoteEventID }))
    }

    @Test
    func listeningHistoryFromAnotherServerIsNeverUploadedOrShownInTheActiveScope() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let seed = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await seed.importLocalFiles(at: [glass])
        let trackID = try #require(seed.tracks.first?.id)
        let oldEntry = ListeningHistoryEntry(
            trackID: trackID,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            listenedSeconds: 30,
            serverOrigin: "https://old-music.test",
            syncProfileID: "default",
            title: "Old server song",
            originatedOnThisDevice: true
        )
        defaults.set(
            try JSONEncoder().encode([oldEntry]),
            forKey: "Resonance.listeningHistory.v1"
        )
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        var posted = false
        RegressionURLProtocol.handler = { request in
            if request.httpMethod == "POST" { posted = true }
            let payload = Data(#"{"profile_id":"default","entries":[]}"#.utf8)
            return (try response(for: request), payload)
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

        #expect(!posted)
        #expect(model.activeProfileListeningHistoryEntries.isEmpty)
        #expect(model.listeningHistoryEntries.first?.serverOrigin == "https://old-music.test")
    }

    private func catalog(
        id: String,
        filename: String = "Glass.aiff",
        size: Int,
        downloadURL: String,
        contentSHA256: String? = nil
    ) throws -> Data {
        var song: [String: Any] = [
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
        ]
        if let contentSHA256 { song["content_sha256"] = contentSHA256 }
        return try JSONSerialization.data(withJSONObject: [
            "count": 1,
            "songs": [song],
        ])
    }

    private func emptyCatalog() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["count": 0, "songs": []])
    }

    private func emptyPlaylists() throws -> Data {
        try JSONEncoder().encode(RemotePlaylistsDocument(revision: 0, playlists: []))
    }

    @Test
    func completedDownloadReleasesUploadActionsBeforePlaylistSyncFinishes() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        let playlistFetchStarted = AsyncSignal()
        let releasePlaylistFetch = DispatchSemaphore(value: 0)
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (try response(for: request), try emptyCatalog())
            }
            if url.path == "/api/v1/playlists" {
                playlistFetchStarted.signal()
                _ = releasePlaylistFetch.wait(timeout: .now() + 5)
                return (try response(for: request), try emptyPlaylists())
            }
            throw URLError(.unsupportedURL)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        let download = Task { await model.syncServerLibrary() }
        await playlistFetchStarted.wait()

        #expect(!model.isSyncingServer)
        #expect(model.isSyncingPlaylists)
        #expect(!model.serverUploadActionsDisabled)

        releasePlaylistFetch.signal()
        await download.value
    }

    @Test
    func catalogRefreshLandingPreservesAnUploadThatCompletedWhileItWasInFlight() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedCatalogRegressionURLProtocol.self]
        let network = URLSession(configuration: configuration)
        let catalogFetchStarted = AsyncSignal()
        let releaseCatalogFetch = DispatchSemaphore(value: 0)
        defer {
            releaseCatalogFetch.signal()
            network.invalidateAndCancel()
            DelayedCatalogRegressionURLProtocol.reset()
        }
        DelayedCatalogRegressionURLProtocol.catalogStarted = catalogFetchStarted
        DelayedCatalogRegressionURLProtocol.releaseCatalog = releaseCatalogFetch
        DelayedCatalogRegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "PUT", url.path == "/api/v1/admin/songs" {
                let data = Data(#"{"id":"race-upload","filename":"Glass.aiff","title":"Glass","artist":"System","album":"Sounds","size":1,"modified_at":"now","content_type":"audio/aiff","download_url":"/download/race-upload","stream_url":"/stream/race-upload"}"#.utf8)
                return (try response(for: request, status: 201), data)
            }
            throw URLError(.unsupportedURL)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.tracks = [Track(
            title: "Glass",
            artist: "System",
            album: "Sounds",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            downloadSourceURL: "https://media.example/glass.aiff"
        )]

        let refresh = Task { await model.refreshServerCatalogNow() }
        await catalogFetchStarted.wait()
        model.serverAdminToken = "admin-token"
        await model.uploadSongsToServer([glass])
        #expect(model.remoteSongs.map(\.id) == ["race-upload"])

        releaseCatalogFetch.signal()
        await refresh.value

        #expect(model.remoteSongs.map(\.id) == ["race-upload"])
        #expect(model.uploadStatus == "Uploaded 1 songs")
    }

    @Test
    func catalogRefreshRemainsReadOnlyEvenWhenAnAdminKeyIsConfigured() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        var requests: [(method: String, path: String)] = []
        RegressionURLProtocol.handler = { request in
            requests.append((request.httpMethod ?? "GET", request.url?.path ?? ""))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
            return (try response(for: request), try emptyCatalog())
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"

        await model.refreshServerCatalogNow()

        #expect(requests.count == 1)
        #expect(requests.first?.method == "GET")
        #expect(requests.first?.path == "/api/v1/songs")
    }

    @Test
    func catalogRefreshPublishesLinkOnlyRowsBeforeDeviceMetadataFinishes() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        let metadataStarted = AsyncSignal()
        let releaseMetadata = AsyncSignal()
        defer {
            releaseMetadata.signal()
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/songs")
            let data = Data(#"{"count":1,"songs":[{"id":"link-only","source_url":"https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8","media_kind":"audio","size":0,"modified_at":"now","content_type":"application/octet-stream","download_url":"/api/v1/songs/link-only/file","stream_url":"/api/v1/songs/link-only/stream"}]}"#.utf8)
            return (try response(for: request), data)
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false,
            remoteSongMetadataResolver: { source, mediaMode in
                #expect(source == "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8")
                #expect(mediaMode == .audio)
                metadataStarted.signal()
                await releaseMetadata.wait()
                return LocalImportSpotifyTrack(
                    provider: "spotify",
                    type: "track",
                    trackID: "4PTG3Z6ehGkBFwjybzWkR8",
                    title: "Resolved Song",
                    artist: "Resolved Artist",
                    album: "Resolved Album",
                    trackNumber: 1,
                    durationSeconds: 123,
                    artworkURL: "https://i.scdn.co/image/resolved",
                    embedURL: "https://open.spotify.com/embed/track/4PTG3Z6ehGkBFwjybzWkR8",
                    sourceURL: source
                )
            }
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        await model.refreshServerCatalogNow()
        await metadataStarted.wait()

        #expect(!model.isRefreshingServerCatalog)
        #expect(model.remoteSongs.count == 1)
        #expect(model.remoteSongs.first?.id == "link-only")
        #expect(model.remoteSongs.first?.isMetadataLoading == true)
        #expect(model.remoteSongs.first?.title == "Resolving metadata…")
        #expect(model.pendingRemoteSongMetadataCount == 1)

        releaseMetadata.signal()
        for _ in 0..<100 where model.pendingRemoteSongMetadataCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.pendingRemoteSongMetadataCount == 0)
        #expect(model.remoteSongs.first?.isMetadataLoading == false)
        #expect(model.remoteSongs.first?.title == "Resolved Song")
        #expect(model.remoteSongs.first?.artist == "Resolved Artist")
        #expect(model.remoteSongs.first?.durationSeconds == 123)
    }

    @Test
    func linkOnlyCatalogMetadataRetriesTransientFailuresAutomatically() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        let resolverCalls = LockedRegressionCounter()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        RegressionURLProtocol.handler = { request in
            let data = Data(#"{"count":1,"songs":[{"id":"retry-link","source_url":"https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8","media_kind":"audio","size":0,"modified_at":"now","content_type":"application/octet-stream","download_url":"/api/v1/songs/retry-link/file","stream_url":"/api/v1/songs/retry-link/stream"}]}"#.utf8)
            return (try response(for: request), data)
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false,
            remoteSongMetadataResolver: { source, _ in
                guard resolverCalls.increment() >= 3 else { throw URLError(.timedOut) }
                return LocalImportSpotifyTrack(
                    provider: "spotify",
                    type: "track",
                    trackID: "4PTG3Z6ehGkBFwjybzWkR8",
                    title: "Recovered Song",
                    artist: "Recovered Artist",
                    album: "Recovered Album",
                    trackNumber: 1,
                    durationSeconds: 180,
                    artworkURL: nil,
                    embedURL: "",
                    sourceURL: source
                )
            },
            remoteSongMetadataRetryDelays: [.zero, .zero]
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        await model.refreshServerCatalogNow()
        for _ in 0..<100 where model.pendingRemoteSongMetadataCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(resolverCalls.value == 3)
        #expect(model.remoteSongs.first?.isMetadataLoading == false)
        #expect(model.remoteSongs.first?.title == "Recovered Song")
    }

    @Test
    func exhaustedMetadataWindowStaysNeutralAndCanRetryWithoutCatalogRefresh() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        let resolverCalls = LockedRegressionCounter()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        RegressionURLProtocol.handler = { request in
            let data = Data(#"{"count":1,"songs":[{"id":"pending-link","source_url":"https://www.youtube.com/watch?v=jNQXAC9IVRw","media_kind":"audio","size":0,"modified_at":"now","content_type":"application/octet-stream","download_url":"/api/v1/songs/pending-link/file","stream_url":"/api/v1/songs/pending-link/stream"}]}"#.utf8)
            return (try response(for: request), data)
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false,
            remoteSongMetadataResolver: { _, _ in
                resolverCalls.increment()
                throw URLError(.cannotConnectToHost)
            },
            remoteSongMetadataRetryDelays: [.zero, .zero]
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"

        await model.refreshServerCatalogNow()
        for _ in 0..<100 where model.pendingRemoteSongMetadataCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(resolverCalls.value == 3)
        #expect(model.remoteSongs.first?.isMetadataLoading == true)
        #expect(model.remoteSongs.first?.title == "Resolving metadata…")

        model.retryPendingRemoteSongMetadata()
        for _ in 0..<100 where model.pendingRemoteSongMetadataCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(resolverCalls.value == 6)
        #expect(model.remoteSongs.first?.title != "Metadata unavailable")
    }

    @Test
    func catalogRefreshReusesPersistedDeviceMetadataWithoutResolvingAgain() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        let resolverCalls = LockedRegressionCounter()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }

        let source = "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"
        RegressionURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/songs")
            let data = Data(
                #"{"count":1,"songs":[{"id":"cached-link","source_url":"https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8","media_kind":"audio","size":0,"modified_at":"now","content_type":"application/octet-stream","download_url":"/api/v1/songs/cached-link/file","stream_url":"/api/v1/songs/cached-link/stream"}]}"#.utf8
            )
            return (try response(for: request), data)
        }
        let resolver: PlayerModel.RemoteSongMetadataResolver = { receivedSource, mediaMode in
            resolverCalls.increment()
            #expect(receivedSource == source)
            #expect(mediaMode == .audio)
            return LocalImportSpotifyTrack(
                provider: "spotify",
                type: "track",
                trackID: "4PTG3Z6ehGkBFwjybzWkR8",
                title: "Cached Song",
                artist: "Cached Artist",
                album: "Cached Album",
                trackNumber: 1,
                durationSeconds: 321,
                artworkURL: "https://i.scdn.co/image/cached",
                embedURL: "https://open.spotify.com/embed/track/4PTG3Z6ehGkBFwjybzWkR8",
                sourceURL: receivedSource
            )
        }

        let initial = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false,
            remoteSongMetadataResolver: resolver
        )
        initial.serverURLString = "https://music.test"
        initial.serverToken = "access-token"
        await initial.refreshServerCatalogNow()
        for _ in 0..<100 where initial.pendingRemoteSongMetadataCount > 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        initial.flushPersistence()
        #expect(resolverCalls.value == 1)
        #expect(initial.remoteSongs.first?.title == "Cached Song")

        let relaunched = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false,
            remoteSongMetadataResolver: resolver
        )
        relaunched.serverURLString = "https://music.test"
        relaunched.serverToken = "access-token"
        await relaunched.refreshServerCatalogNow()

        #expect(resolverCalls.value == 1)
        #expect(relaunched.pendingRemoteSongMetadataCount == 0)
        #expect(relaunched.remoteSongs.first?.isMetadataLoading == false)
        #expect(relaunched.remoteSongs.first?.title == "Cached Song")
        #expect(relaunched.remoteSongs.first?.artist == "Cached Artist")
        #expect(relaunched.remoteSongs.first?.durationSeconds == 321)
    }

    @Test
    func repairsAnExpiredSavedDownloadLinkFromTheAssociatedLocalSourcePage() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        let songID = "0a9b8b5c-19f0-4be0-bca0-b3b3c9418353"
        let sourcePage = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        var patchCount = 0
        RegressionURLProtocol.handler = { request in
            patchCount += 1
            #expect(request.httpMethod == "PATCH")
            #expect(request.url?.path == "/api/v1/admin/songs/\(songID)")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "default")
            let body = try regressionRequestBody(request)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["schema_version"] as? Int == 3)
            #expect(object["source_url"] as? String == sourcePage)
            #expect(object["media_kind"] as? String == "audio")
            return (try response(for: request), Data(#"{"status":"updated"}"#.utf8))
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "https://music.test"
        model.serverToken = "access-token"
        model.serverAdminToken = "admin-token"
        model.tracks = [Track(
            title: "Recovered title",
            artist: "Recovered artist",
            album: "Imported",
            duration: 120,
            artwork: .liked,
            remoteID: songID,
            sourceServer: "https://music.test",
            syncProfileID: "default",
            sourceURL: sourcePage
        )]
        let song = try JSONDecoder().decode(RemoteSong.self, from: Data(
            """
            {
              "id": "\(songID)",
              "source_url": "https://rr1.example.googlevideo.com/videoplayback?expire=1",
              "download_url": "/api/v1/songs/\(songID)/file",
              "stream_url": "/api/v1/songs/\(songID)/stream"
            }
            """.utf8
        ))

        let repaired = await model.repairLegacyRemoteSourceLinks(
            in: [song],
            base: try #require(URL(string: "https://music.test"))
        )

        #expect(repaired)
        #expect(patchCount == 1)
    }

    @Test
    func insecureServerURLIsRejectedBeforeAnyBearerRequestIsCreated() async throws {
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
            return (try response(for: request), try emptyCatalog())
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        model.serverURLString = "http://music.test"
        model.serverToken = "must-not-leak"

        await model.refreshServerCatalogNow()

        #expect(!requestWasSent)
        #expect(model.serverMessage.contains("HTTPS"))
    }

    @Test
    func localImportDoesNotApplyAnUploadResponseAfterItsReservedContextChanges() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedCatalogRegressionURLProtocol.self]
        let network = URLSession(configuration: configuration)
        let uploadStarted = AsyncSignal()
        let releaseUpload = DispatchSemaphore(value: 0)
        defer {
            releaseUpload.signal()
            network.invalidateAndCancel()
            DelayedCatalogRegressionURLProtocol.reset()
        }
        DelayedCatalogRegressionURLProtocol.uploadStarted = uploadStarted
        DelayedCatalogRegressionURLProtocol.releaseUpload = releaseUpload
        DelayedCatalogRegressionURLProtocol.handler = { request in
            _ = try #require(request.url)
            let data = Data(#"{"id":"late-upload","filename":"Glass.aiff","title":"Late","artist":"Server","album":"Catalog","size":1,"modified_at":"now","content_type":"audio/aiff","download_url":"/download/late-upload","stream_url":"/stream/late-upload"}"#.utf8)
            return (try response(for: request, status: 201), data)
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: network,
            persistServerCredentials: false
        )
        let track = Track(
            title: "Local Context",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            downloadSourceURL: "https://media.example/local-context.aiff"
        )
        model.tracks = [track]
        model.serverURLString = "https://music.test"
        model.serverAdminToken = "admin-token"
        let context = try model.beginLocalImportTransfer(reservingUpload: true)
        defer { model.endLocalImportTransfer(context) }

        let upload = Task {
            try await model.uploadLocalImportToActiveProfile(track, context: context)
        }
        await uploadStarted.wait()
        model.serverURLString = "https://other-music.test"
        releaseUpload.signal()

        var rejectedChangedContext = false
        do {
            _ = try await upload.value
        } catch is LocalImportTransferContextError {
            rejectedChangedContext = true
        }

        #expect(rejectedChangedContext)
        #expect(model.remoteSongs.isEmpty)
        #expect(model.tracks.first?.remoteID == nil)
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
            forKey: "Resonance.listeningHistory.v1"
        )

        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )

        #expect(relaunched.listeningHistoryEntries.count == 1)
        #expect(relaunched.listeningHistoryEntries.first?.syncProfileID == "default")
        #expect(relaunched.activeProfileListeningHistoryEntries.count == 1)
        relaunched.flushPersistence()
        let migratedData = try #require(
            defaults.data(forKey: "Resonance.listeningHistory.v1")
        )
        let migrated = try JSONDecoder().decode(
            [ListeningHistoryEntry].self,
            from: migratedData
        )
        #expect(migrated.first?.syncProfileID == "default")
    }

    @Test
    func legacyListeningHistoryUsesTheConfiguredServerWhenNoPlaylistContextWasSaved() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await initial.importLocalFiles(at: [hero])
        initial.flushPersistence()
        let track = try #require(initial.tracks.first)
        defaults.set("https://MUSIC.test:443/path", forKey: "Resonance.serverURL.v1")
        defaults.set(
            try JSONEncoder().encode([
                LegacyListeningHistoryEntry(
                    id: UUID(),
                    trackID: track.id,
                    startedAt: .now,
                    listenedSeconds: 42
                ),
            ]),
            forKey: "Resonance.listeningHistory.v1"
        )

        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )

        #expect(relaunched.listeningHistoryEntries.first?.serverOrigin == "https://music.test")
        #expect(relaunched.activeProfileListeningHistoryEntries.count == 1)
    }

    @Test
    func duplicateTrackReconciliationRemapsListeningHistoryBeforeRemovingTheDuplicate() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        await model.importLocalFiles(at: [glass])
        let localTrack = try #require(model.tracks.first)
        let downloadedTrack = Track(
            title: "Downloaded",
            artist: "Artist",
            album: "Album",
            duration: localTrack.duration,
            artwork: .electric,
            fileURL: glass,
            remoteID: "remote-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        model.tracks.append(downloadedTrack)
        model.serverURLString = "https://music.test"
        model.selectAndPlay(downloadedTrack)

        #expect(model.reconcileUploadedLocalTrack(
            trackID: localTrack.id,
            remoteID: "remote-id",
            sourceServer: "https://music.test",
            profileID: "default"
        ))

        #expect(!model.tracks.contains(where: { $0.id == downloadedTrack.id }))
        #expect(model.listeningHistoryEntries.first?.trackID == localTrack.id)
        if model.isPlaying { model.togglePlay() }
        model.flushPersistence()
        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )
        #expect(relaunched.listeningHistoryEntries.first?.trackID == localTrack.id)
    }

    @Test
    func reconciliationNeverRebindsAcrossServerOrProfileContexts() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let track = Track(
            title: "Linked",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            remoteID: "original-id",
            sourceServer: "https://music.test",
            syncProfileID: "profile-a"
        )
        model.tracks = [track]

        #expect(throws: LocalImportTransferContextError.self) {
            try model.reconcileUploadedLocalTrackForImport(
                trackID: track.id,
                remoteID: "import-match-id",
                sourceServer: "https://archive.test",
                profileID: "profile-a"
            )
        }
        #expect(!model.reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: "other-server-id",
            sourceServer: "https://archive.test",
            profileID: "profile-a"
        ))
        #expect(!model.reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: "other-profile-id",
            sourceServer: "https://music.test",
            profileID: "profile-b"
        ))
        #expect(model.tracks.first?.remoteID == "original-id")
        #expect(model.tracks.first?.sourceServer == "https://music.test")
        #expect(model.tracks.first?.syncProfileID == "profile-a")
        #expect(model.serverMessage.contains("already linked"))

        #expect(try model.reconcileUploadedLocalTrackForImport(
            trackID: track.id,
            remoteID: "replacement-id",
            sourceServer: "https://MUSIC.test:443/path",
            profileID: "profile-a"
        ))
        #expect(model.tracks.first?.remoteID == "replacement-id")
        #expect(model.tracks.first?.sourceServer == "https://music.test")
        #expect(model.tracks.first?.syncProfileID == "profile-a")
    }

    @Test
    func sourceOnlyRemoteAssociationNeverRebindsAndCanAdoptWithinItsContext() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let track = Track(
            title: "Partially linked",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            sourceServer: "https://archive.test",
            syncProfileID: "profile-a"
        )
        model.tracks = [track]

        #expect(throws: LocalImportTransferContextError.self) {
            try model.reconcileUploadedLocalTrackForImport(
                trackID: track.id,
                remoteID: "other-server-id",
                sourceServer: "https://music.test",
                profileID: "profile-a"
            )
        }
        #expect(!model.reconcileUploadedLocalTrack(
            trackID: track.id,
            remoteID: "other-profile-id",
            sourceServer: "https://archive.test",
            profileID: "profile-b"
        ))
        #expect(model.tracks.first?.remoteID == nil)
        #expect(model.tracks.first?.sourceServer == "https://archive.test")
        #expect(model.tracks.first?.syncProfileID == "profile-a")

        #expect(try model.reconcileUploadedLocalTrackForImport(
            trackID: track.id,
            remoteID: "adopted-id",
            sourceServer: "https://ARCHIVE.test:443/path",
            profileID: "profile-a"
        ))
        #expect(model.tracks.first?.remoteID == "adopted-id")
        #expect(model.tracks.first?.sourceServer == "https://archive.test")
        #expect(model.tracks.first?.syncProfileID == "profile-a")
    }

    @Test
    func cachedUploadReconciliationRejectsAmbiguousExactHashes() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false
        )
        let hash = String(repeating: "a", count: 64)
        let local = Track(
            title: "Local",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: glass,
            contentSHA256: hash
        )
        let firstRemote = Track(
            title: "First remote",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .electric,
            fileURL: glass,
            remoteID: "first",
            sourceServer: "https://music.test",
            syncProfileID: "default",
            contentSHA256: hash
        )
        let secondRemote = Track(
            title: "Second remote",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .echoes,
            fileURL: glass,
            remoteID: "second",
            sourceServer: "https://music.test",
            syncProfileID: "default",
            contentSHA256: hash
        )
        model.tracks = [local, firstRemote, secondRemote]
        model.serverURLString = "https://music.test"

        #expect(!(await model.reconcileCachedUploadedLocalTracks()))
        #expect(model.tracks.map(\.id) == [local.id, firstRemote.id, secondRemote.id])
        #expect(model.tracks.first?.remoteID == nil)
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
            if url.path == "/api/v1/client-config" {
                return (
                    HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
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
    func identicalSongIDsFromDifferentProfilesUseDifferentCacheFiles() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        let defaultAudio = try Data(contentsOf: glass)
        let otherAudio = try Data(contentsOf: ping)
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            let profileID = request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default"
            if url.path == "/api/v1/profiles" {
                let payload: [String: Any] = [
                    "default_profile_id": "default",
                    "profiles": [
                        ["id": "default", "name": "Default", "is_default": true],
                        ["id": "profile-b", "name": "Profile B", "is_default": false],
                    ],
                ]
                return (try response(for: request), try JSONSerialization.data(withJSONObject: payload))
            }
            if url.path == "/api/v1/songs" {
                let audio = profileID == "profile-b" ? otherAudio : defaultAudio
                return (
                    try response(for: request),
                    try catalog(
                        id: "shared-song-id",
                        size: audio.count,
                        downloadURL: "/download/\(profileID).aiff",
                        contentSHA256: sha256(audio)
                    )
                )
            }
            if url.path == "/download/default.aiff" {
                return (try response(for: request), defaultAudio)
            }
            if url.path == "/download/profile-b.aiff" {
                return (try response(for: request), otherAudio)
            }
            if url.path == "/api/v1/playlists" {
                return (
                    try response(for: request),
                    try JSONEncoder().encode(RemotePlaylistsDocument(
                        profileID: profileID,
                        revision: 0,
                        playlists: []
                    ))
                )
            }
            throw URLError(.unsupportedURL)
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
        let defaultTrack = try #require(model.tracks.first(where: { $0.syncProfileID == "default" }))
        let defaultURL = try #require(defaultTrack.fileURL)
        #expect(try Data(contentsOf: defaultURL) == defaultAudio)

        #expect(await model.selectSyncProfile(matching: "Profile B"))
        await model.syncServerLibrary()
        let otherTrack = try #require(model.tracks.first(where: { $0.syncProfileID == "profile-b" }))
        let otherURL = try #require(otherTrack.fileURL)

        #expect(defaultURL.standardizedFileURL != otherURL.standardizedFileURL)
        #expect(try Data(contentsOf: defaultURL) == defaultAudio)
        #expect(try Data(contentsOf: otherURL) == otherAudio)
        #expect(model.tracks.count == 2)
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
            remoteID: "first-remote-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let second = Track(
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .golden,
            fileURL: ping,
            remoteID: "second-remote-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
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
            remoteID: "remote-like-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
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
            remoteID: "remote-like-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
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
            remoteID: "first-remote-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
        )
        let second = Track(
            title: "Second",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .golden,
            fileURL: ping,
            remoteID: "second-remote-id",
            sourceServer: "https://music.test",
            syncProfileID: "default"
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
    func corruptLibraryBytesAreNotCopiedIntoRecovery() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let corrupt = Data("not valid library json".utf8)
        defaults.set(corrupt, forKey: "Resonance.library.v2")

        let model = PlayerModel(loadPersistedLibrary: true, defaults: defaults, persistServerCredentials: false)

        #expect(model.tracks.isEmpty)
        #expect(defaults.data(forKey: "Resonance.library.v2") == corrupt)
        #expect(defaults.data(forKey: "Resonance.library.v2.recovery") == nil)
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
        model.serverURLString = "https://music.test"
        model.toggleFavorite(track)
        let playlist = try #require(model.createPlaylist(named: "Keep membership"))
        model.addTrack(track, to: playlist)
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
    func catalogChecksumMismatchNeverInstallsOrPersistsTheDownload() async throws {
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
                        id: "checksum-mismatch-id",
                        size: audio.count,
                        downloadURL: "/checksum.aiff",
                        contentSHA256: String(repeating: "0", count: 64)
                    )
                )
            }
            if url.path == "/checksum.aiff" {
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

        #expect(downloadCount == 1)
        #expect(model.tracks.isEmpty)
        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
        let cachedFiles = FileManager.default.enumerator(
            at: cacheRoot,
            includingPropertiesForKeys: nil
        )?.allObjects.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(cachedFiles.isEmpty)
        let relaunched = PlayerModel(
            loadPersistedLibrary: true,
            defaults: defaults,
            persistServerCredentials: false
        )
        #expect(relaunched.tracks.isEmpty)
    }

    @Test
    func failedReplacementKeepsThePreviouslyInstalledCacheFile() async throws {
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
        let originalHash = sha256(audio)
        var downloadData = audio
        var catalogHash = originalHash
        var failDownload = false
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (
                    try response(for: request),
                    try catalog(
                        id: "replace-cache-id",
                        size: downloadData.count,
                        downloadURL: "/replace-cache.aiff",
                        contentSHA256: catalogHash
                    )
                )
            }
            if url.path == "/replace-cache.aiff" {
                if failDownload { throw URLError(.networkConnectionLost) }
                return (try response(for: request), downloadData)
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
        #expect(try Data(contentsOf: cachedURL) == audio)

        catalogHash = String(repeating: "0", count: 64)
        failDownload = true
        await model.refreshServerCatalogNow()
        await model.syncServerLibrary()

        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
        #expect(FileManager.default.fileExists(atPath: cachedURL.path))
        #expect(try Data(contentsOf: cachedURL) == audio)
        #expect(model.tracks.first?.fileURL == cachedURL)

        let replacement = try Data(contentsOf: ping)
        downloadData = replacement
        catalogHash = sha256(replacement)
        failDownload = false
        await model.refreshServerCatalogNow()
        await model.syncServerLibrary()

        #expect(model.downloadStatus == "Downloaded 1 songs")
        #expect(try Data(contentsOf: cachedURL) == replacement)
        #expect(model.tracks.first?.contentSHA256 == catalogHash)
    }

    @Test
    func oversizedCatalogEntryIsRejectedBeforeDownload() async throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let network = session()
        defer {
            network.invalidateAndCancel()
            RegressionURLProtocol.handler = nil
        }
        var downloadWasRequested = false
        RegressionURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/songs" {
                return (
                    try response(for: request),
                    try catalog(
                        id: "oversized-audio-id",
                        size: 256 * 1_024 * 1_024 + 1,
                        downloadURL: "/oversized.aiff"
                    )
                )
            }
            if url.path == "/oversized.aiff" { downloadWasRequested = true }
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

        #expect(!downloadWasRequested)
        #expect(model.tracks.isEmpty)
        #expect(model.downloadStatus == "Downloaded 0; 1 failed")
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


private actor MacBatchConcurrencyProbe {
    private var active = 0
    private var peak = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }

    func maximum() -> Int { peak }
}

@Suite
struct MacBatchDownloadPolicyTests {
    @Test("desktop batch pool preserves order and caps active downloads")
    func boundedPool() async {
        let probe = MacBatchConcurrencyProbe()
        let values = Array(0..<16)
        let results = await MacBatchDownloadPolicy.orderedMap(
            values,
            maximumConcurrent: 4
        ) { value in
            await probe.begin()
            try? await Task.sleep(for: .milliseconds(5 + value % 3))
            await probe.end()
            return value * 2
        }
        let peak = await probe.maximum()
        #expect(peak == 4)
        #expect(results == values.map { $0 * 2 })
    }

    @Test("catalog fast path requires resolved descriptive metadata")
    func catalogFastPath() {
        #expect(MacBatchDownloadPolicy.maximumConcurrentDownloads == 4)
        #expect(MacBatchDownloadPolicy.canUseCatalogMetadata(
            title: "Catalog title",
            artist: "Catalog artist",
            duration: 211,
            isMetadataLoading: false
        ))
        #expect(!MacBatchDownloadPolicy.canUseCatalogMetadata(
            title: "Catalog title",
            artist: "Catalog artist",
            duration: nil,
            isMetadataLoading: false
        ))
        #expect(!MacBatchDownloadPolicy.canUseCatalogMetadata(
            title: "Resolving metadata…",
            artist: "On-device lookup",
            duration: 211,
            isMetadataLoading: true
        ))
    }
}


@MainActor
@Suite(.serialized)
struct MacMixedProviderDownloadPolicyTests {
    @Test
    func byteActiveItemReplacesEarlierProviderPreparation() {
        let preparing = MacBatchDownloadPreparationDisplay(
            index: 0,
            title: "Slow YouTube song",
            detail: "Inspecting YouTube",
            completedBytes: 0,
            totalBytes: 0
        )
        let downloading = MacBatchDownloadPreparationDisplay(
            index: 1,
            title: "Direct song",
            detail: "Downloading from server",
            completedBytes: 512,
            totalBytes: 1_024
        )
        #expect(MacMixedDownloadPresentationPolicy.shouldPromote(
            current: preparing,
            candidate: downloading
        ))
        #expect(!MacMixedDownloadPresentationPolicy.shouldPromote(
            current: downloading,
            candidate: preparing
        ))
    }

    @Test
    func providerPreparationNamesEverySupportedSource() {
        #expect(MacProviderDownloadPreparationPolicy.detail(
            sourceURL: "https://www.youtube.com/watch?v=abcdefghijk",
            stage: .inspectingSource
        ) == "Inspecting YouTube")
        #expect(MacProviderDownloadPreparationPolicy.detail(
            sourceURL: "https://soundcloud.com/artist/song",
            stage: .resolvingMetadata
        ) == "Resolving SoundCloud")
        #expect(MacProviderDownloadPreparationPolicy.detail(
            sourceURL: "https://open.spotify.com/track/0123456789012345678901",
            stage: .searchingCandidates
        ) == "Finding a YouTube match")
    }

    @Test
    func preparationCoordinatorPrioritizesRealBytes() {
        var published: [MacBatchDownloadPreparationDisplay?] = []
        let coordinator = MacBatchDownloadPresentationCoordinator(itemCount: 3) {
            published.append($0)
        }
        coordinator.update(MacBatchDownloadPreparationDisplay(
            index: 0,
            title: "YouTube",
            detail: "Inspecting YouTube",
            completedBytes: 0,
            totalBytes: 0
        ))
        coordinator.update(MacBatchDownloadPreparationDisplay(
            index: 1,
            title: "Direct",
            detail: "Downloading from server",
            completedBytes: 256,
            totalBytes: 1_024
        ))
        #expect(coordinator.currentIndex == 1)
        #expect(published.compactMap { $0 }.last?.title == "Direct")
    }
}
