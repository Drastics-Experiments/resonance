import Combine
import Foundation

enum MobileListenAlongRole: String, Codable, Equatable, Sendable {
    case host
    case guest
}

struct MobileListenAlongSnapshot: Codable, Equatable, Sendable {
    var sourceURL: String?
    var mediaKind: String
    var positionSeconds: TimeInterval
    var isPlaying: Bool

    init(
        sourceURL: String?,
        mediaKind: String = "audio",
        positionSeconds: TimeInterval,
        isPlaying: Bool
    ) {
        self.sourceURL = sourceURL
        self.mediaKind = mediaKind == "video" ? "video" : "audio"
        self.positionSeconds = positionSeconds.isFinite ? max(positionSeconds, 0) : 0
        self.isPlaying = isPlaying
    }

    private enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let sourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mediaKind = try values.decodeIfPresent(String.self, forKey: .mediaKind) ?? "audio"
        let position = try values.decodeIfPresent(TimeInterval.self, forKey: .positionSeconds) ?? 0
        let isPlaying = try values.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        self.init(
            sourceURL: sourceURL.flatMap { $0.isEmpty ? nil : $0 },
            mediaKind: mediaKind,
            positionSeconds: position,
            isPlaying: isPlaying
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sourceURL, forKey: .sourceURL)
        try values.encode(mediaKind, forKey: .mediaKind)
        try values.encode(positionSeconds, forKey: .positionSeconds)
        try values.encode(isPlaying, forKey: .isPlaying)
    }
}

struct MobileListenAlongRoom: Equatable, Sendable {
    let code: String
    let revision: Int
    let snapshot: MobileListenAlongSnapshot
    let updatedAt: Date?
    let expiresAt: Date?
    let serverTime: Date?
    let role: MobileListenAlongRole

    func projectedPosition(now: Date = .now) -> TimeInterval {
        guard snapshot.isPlaying else {
            return snapshot.positionSeconds
        }
        // `server_time` is the server's receipt clock for this response. Use
        // it with `updated_at` so the first frame is aligned without assuming
        // that the device clock is synchronized. Polling supplies the next
        // correction; a local receipt offset would need an explicit monotonic
        // timestamp to extrapolate between polls safely.
        let serverNow = serverTime ?? now
        let updated = updatedAt ?? serverNow
        let elapsed = max(serverNow.timeIntervalSince(updated), 0)
        return snapshot.positionSeconds + elapsed
    }
}

struct MobileListenAlongResponse: Decodable, Sendable {
    let schemaVersion: Int
    let code: String?
    let revision: Int
    let snapshot: MobileListenAlongSnapshot
    let updatedAt: Date?
    let expiresAt: Date?
    let serverTime: Date?
    let role: MobileListenAlongRole?
    let hostToken: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code
        case formattedCode = "formatted_code"
        case sessionCode = "session_code"
        case revision, snapshot
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
        case role
        case hostToken = "host_token"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        code = try values.decodeIfPresent(String.self, forKey: .code)
            ?? values.decodeIfPresent(String.self, forKey: .formattedCode)
            ?? values.decodeIfPresent(String.self, forKey: .sessionCode)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        // The Core API returns a nested snapshot. Accepting the flat shape as
        // well keeps the client compatible with older development servers.
        snapshot = try values.decodeIfPresent(MobileListenAlongSnapshot.self, forKey: .snapshot)
            ?? MobileListenAlongSnapshot(from: decoder)
        updatedAt = MobileListenAlongDate.parse(try values.decodeIfPresent(String.self, forKey: .updatedAt))
        expiresAt = MobileListenAlongDate.parse(try values.decodeIfPresent(String.self, forKey: .expiresAt))
        serverTime = MobileListenAlongDate.parse(try values.decodeIfPresent(String.self, forKey: .serverTime))
        role = try values.decodeIfPresent(MobileListenAlongRole.self, forKey: .role)
        hostToken = try values.decodeIfPresent(String.self, forKey: .hostToken)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MobileListenAlongUpdateRequest: Encodable, Equatable, Sendable {
    let revision: Int
    let snapshot: MobileListenAlongSnapshot

    private enum CodingKeys: String, CodingKey {
        case revision
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(revision, forKey: .revision)
        try values.encode(snapshot.sourceURL, forKey: .sourceURL)
        try values.encode(snapshot.mediaKind, forKey: .mediaKind)
        try values.encode(snapshot.positionSeconds, forKey: .positionSeconds)
        try values.encode(snapshot.isPlaying, forKey: .isPlaying)
    }
}

enum MobileListenAlongDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum MobileListenAlongPollingPolicy {
    /// Listen Along uses revisioned snapshots over HTTP, so a short poll keeps
    /// host actions responsive without introducing another realtime transport.
    static let normalInterval: Duration = .milliseconds(250)
    static let maximumFailureInterval: Double = 30
}

enum MobileListenAlongSourcePolicy {
    private static let temporaryStreamHosts = [
        "googlevideo.com",
        "googleusercontent.com",
        "scdn.co",
        "sndcdn.com",
        "spotifycdn.com",
    ]

    static func identity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8_192,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              !host.isEmpty,
              !temporaryStreamHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

        if let youtubeID = try? LocalImportURL.youtubeVideoID(trimmed) {
            return "youtube:\(youtubeID)"
        }
        if let spotify = try? LocalImportURL.spotifyTrack(trimmed) {
            return "spotify:\(spotify.trackID)"
        }

        var normalized = components
        normalized.scheme = "https"
        normalized.host = host
        normalized.fragment = nil
        while normalized.path.count > 1, normalized.path.hasSuffix("/") {
            normalized.path.removeLast()
        }
        return normalized.string
    }

    static func validatedSource(_ value: String?) -> String? {
        guard let value,
              let identity = identity(value),
              !identity.isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MobileListenAlongInvite {
    static func code(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "resonance" else { return nil }
        let host = url.host?.lowercased()
        let components = url.pathComponents.filter { $0 != "/" }
        let candidate: String?
        if host == "listen-along" {
            candidate = components.last
        } else if components.first?.lowercased() == "listen-along" {
            candidate = components.dropFirst().last
        } else {
            candidate = nil
        }
        guard let candidate else { return nil }
        let normalized = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.count >= 5,
              normalized.count <= 32,
              normalized.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }),
              normalized.contains("-") else { return nil }
        return normalized
    }
}

enum MobileListenAlongError: LocalizedError, Equatable {
    case notSignedIn
    case invalidCode
    case invalidSource
    case noCurrentSource
    case invalidResponse
    case unsupportedSource
    case server(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to Resonance before starting or joining a Listen Along room."
        case .invalidCode:
            return "Enter a valid Listen Along room code."
        case .invalidSource:
            return "The room contains an invalid source link."
        case .noCurrentSource:
            return "This track has no shareable source link. Upload or import it from a source link first."
        case .invalidResponse:
            return "The Listen Along server returned an invalid room response."
        case .unsupportedSource:
            return "This source cannot be resolved for Listen Along playback on iOS."
        case .server(let status, let message):
            if let message, !message.isEmpty { return message }
            return "Listen Along returned HTTP \(status)."
        }
    }
}

private final class MobileListenAlongRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: String?

    init(origin: URL) {
        self.origin = MobileServerEndpointPolicy.normalizedOrigin(of: origin)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let origin,
              let redirectURL = request.url,
              MobileServerEndpointPolicy.normalizedOrigin(of: redirectURL) == origin else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class MobileListenAlongController: ObservableObject {
    @Published private(set) var room: MobileListenAlongRoom?
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?

    private struct StartRequest: Encodable {
        let sourceURL: String?
        let mediaKind: String
        let positionSeconds: TimeInterval
        let isPlaying: Bool

        enum CodingKeys: String, CodingKey {
            case sourceURL = "source_url"
            case mediaKind = "media_kind"
            case positionSeconds = "position_seconds"
            case isPlaying = "is_playing"
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sourceURL, forKey: .sourceURL)
            try values.encode(mediaKind, forKey: .mediaKind)
            try values.encode(positionSeconds, forKey: .positionSeconds)
            try values.encode(isPlaying, forKey: .isPlaying)
        }
    }

    private struct ErrorPayload: Decodable {
        let error: String?
        let message: String?
    }

    private weak var library: MusicLibrary?
    private let importService = LocalDeviceImportService()
    private var hostToken: String?
    private var pollTask: Task<Void, Never>?
    private var hostPublishTask: Task<Void, Never>?
    private var lastAppliedRevision = -1
    private var pendingInviteCode: String?
    private var isApplyingRemoteSnapshot = false
    private var pollFailureCount = 0
    private var hostPublishGeneration: UInt64 = 0

    deinit {
        pollTask?.cancel()
        hostPublishTask?.cancel()
    }

    var isHosting: Bool { room?.role == .host }
    var isParticipant: Bool { room?.role == .guest }
    var controlsLocked: Bool { isParticipant && !isApplyingRemoteSnapshot }
    var roomCode: String? { room?.code }

    func bind(to library: MusicLibrary) {
        guard self.library !== library else { return }
        self.library = library
        library.attachListenAlongController(self)
        if let pendingInviteCode {
            self.pendingInviteCode = nil
            Task { [weak self] in await self?.join(code: pendingInviteCode) }
        }
    }

    func handleOpenURL(_ url: URL) {
        guard let code = MobileListenAlongInvite.code(from: url) else { return }
        pendingInviteCode = code
        Task { [weak self] in await self?.join(code: code) }
    }

    func startHosting() async {
        guard room == nil else {
            message = "Leave the current room before starting another one."
            return
        }
        do {
            let snapshot = try currentHostSnapshot()
            let context = try networkContext()
            isWorking = true
            defer { isWorking = false }
            var request = URLRequest(url: context.baseURL.appendingPathComponent("api/v1/listen-along"))
            request.httpMethod = "POST"
            applyHeaders(to: &request, context: context)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(StartRequest(
                sourceURL: snapshot.sourceURL,
                mediaKind: snapshot.mediaKind,
                positionSeconds: snapshot.positionSeconds,
                isPlaying: snapshot.isPlaying
            ))
            let (data, response) = try await perform(request, context: context)
            let payload = try decodeResponse(data, response: response)
            guard let code = normalizedCode(payload.code) else {
                throw MobileListenAlongError.invalidResponse
            }
            guard let token = payload.hostToken, !token.isEmpty else {
                throw MobileListenAlongError.invalidResponse
            }
            hostToken = token
            room = makeRoom(
                from: payload,
                code: code,
                role: .host,
                roleOverride: .host
            )
            library?.refreshListenAlongControlState()
            lastAppliedRevision = room?.revision ?? -1
            message = "Hosting room (\(code))"
            startPolling()
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    func join(code rawCode: String) async {
        guard let code = normalizedCode(rawCode) else {
            message = MobileListenAlongError.invalidCode.localizedDescription
            return
        }
        guard room == nil else {
            message = "Leave the current room before joining another one."
            return
        }
        do {
            let context = try networkContext()
            isWorking = true
            defer { isWorking = false }
            let endpoint = context.baseURL
                .appendingPathComponent("api/v1/listen-along")
                .appendingPathComponent(code)
            var request = URLRequest(url: endpoint)
            applyHeaders(to: &request, context: context)
            let (data, response) = try await perform(request, context: context)
            let payload = try decodeResponse(data, response: response)
            room = makeRoom(from: payload, code: code, role: .guest)
            library?.refreshListenAlongControlState()
            hostToken = nil
            lastAppliedRevision = -1
            message = "Joined room (\(code))"
            startPolling()
            await applyLatestSnapshot()
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    func leave() {
        guard !isHosting else {
            message = "The host must end the room for everyone."
            return
        }
        clearRoom(message: "Left Listen Along room")
    }

    func end() async {
        guard let room, room.role == .host else {
            leave()
            return
        }
        do {
            let context = try networkContext()
            isWorking = true
            defer { isWorking = false }
            var request = URLRequest(url: context.baseURL
                .appendingPathComponent("api/v1/listen-along")
                .appendingPathComponent(room.code))
            request.httpMethod = "DELETE"
            applyHeaders(to: &request, context: context)
            if let hostToken { request.setValue(hostToken, forHTTPHeaderField: "X-Resonance-Listen-Host") }
            _ = try await perform(request, context: context)
            clearRoom(message: "Ended Listen Along room")
        } catch is CancellationError {
            return
        } catch {
            clearRoom(message: "Listen Along room ended locally")
        }
    }

    func hostPlaybackDidChange() {
        guard isHosting, !isApplyingRemoteSnapshot else { return }
        hostPublishGeneration &+= 1
        let generation = hostPublishGeneration
        hostPublishTask?.cancel()
        hostPublishTask = Task { [weak self] in
            // Coalesce changes made by one UI gesture, but publish quickly so
            // guests do not perceive a pause/skip as delayed.
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { return }
            await self?.publishCurrentHostState(generation: generation)
        }
    }

    func profileOrServerContextDidChange() {
        guard room != nil else { return }
        clearRoom(message: "Listen Along stopped because the server profile changed")
    }

    private func publishCurrentHostState(generation: UInt64) async {
        var conflictAttempts = 0
        while !Task.isCancelled, generation == hostPublishGeneration {
            guard let room, room.role == .host, let hostToken else { return }
            do {
                let snapshot = try currentHostSnapshot()
                let context = try networkContext()
                var request = URLRequest(url: context.baseURL
                    .appendingPathComponent("api/v1/listen-along")
                    .appendingPathComponent(room.code))
                request.httpMethod = "PUT"
                applyHeaders(to: &request, context: context)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue(hostToken, forHTTPHeaderField: "X-Resonance-Listen-Host")
                request.httpBody = try JSONEncoder().encode(MobileListenAlongUpdateRequest(
                    revision: room.revision,
                    snapshot: snapshot
                ))
                let (data, response) = try await perform(request, context: context)
                guard !Task.isCancelled, generation == hostPublishGeneration else { return }
                let payload = try decodeResponse(data, response: response)
                guard let currentRoom = self.room,
                      currentRoom.code == room.code else { return }
                let updatedRoom = makeRoom(
                    from: payload,
                    code: room.code,
                    role: .host,
                    roleOverride: .host
                )
                guard updatedRoom.revision >= room.revision,
                      updatedRoom.revision >= currentRoom.revision else { return }
                self.room = updatedRoom
                message = "Hosting room (\(room.code))"
                return
            } catch is CancellationError {
                return
            } catch MobileListenAlongError.noCurrentSource {
                // A host can move from a linked track to a source-less local
                // file through normal queue controls. End the room instead of
                // leaving guests on a stale source snapshot.
                await end()
                return
            } catch let error as MobileListenAlongError {
                guard case .server(let status, _) = error, status == 409,
                      conflictAttempts < 3 else {
                    message = error.localizedDescription
                    return
                }
                do {
                    let context = try networkContext()
                    let latestPayload = try await fetchRoomResponse(
                        code: room.code,
                        context: context
                    )
                    guard !Task.isCancelled, generation == hostPublishGeneration else { return }
                    guard let currentRoom = self.room,
                          currentRoom.code == room.code else { return }
                    let latestRoom = makeRoom(
                        from: latestPayload,
                        code: room.code,
                        role: .host,
                        roleOverride: .host
                    )
                    guard latestRoom.revision >= room.revision,
                          latestRoom.revision >= currentRoom.revision else { return }
                    self.room = latestRoom
                    conflictAttempts += 1
                } catch is CancellationError {
                    return
                } catch {
                    message = error.localizedDescription
                    return
                }
            } catch {
                message = error.localizedDescription
                return
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollFailureCount = 0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await self?.pollOnce()
                    self?.pollFailureCount = 0
                    try await Task.sleep(for: MobileListenAlongPollingPolicy.normalInterval)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.pollFailureCount += 1
                    let delay = min(
                        pow(2.0, Double(max(self.pollFailureCount - 1, 0))),
                        MobileListenAlongPollingPolicy.maximumFailureInterval
                    )
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    private func pollOnce() async throws {
        guard let room else { return }
        do {
            let context = try networkContext()
            let endpoint = context.baseURL
                .appendingPathComponent("api/v1/listen-along")
                .appendingPathComponent(room.code)
            var request = URLRequest(url: endpoint)
            applyHeaders(to: &request, context: context)
            let (data, response) = try await perform(request, context: context)
            let payload = try decodeResponse(data, response: response)
            let nextRoom = makeRoom(
                from: payload,
                code: room.code,
                role: room.role,
                roleOverride: room.role
            )
            if let expiresAt = nextRoom.expiresAt,
               let serverTime = nextRoom.serverTime,
               expiresAt <= serverTime {
                clearRoom(message: "Listen Along room expired")
                return
            }
            guard nextRoom.revision >= room.revision else { return }
            self.room = nextRoom
            if room.role == .guest, nextRoom.revision > lastAppliedRevision {
                await applySnapshot(nextRoom)
            }
        } catch let error as MobileListenAlongError {
            if case .server(let status, _) = error, status == 404 || status == 410 {
                clearRoom(message: "Listen Along room expired")
            }
            throw error
        } catch {
            throw error
        }
    }

    private func applyLatestSnapshot() async {
        guard let room else { return }
        await applySnapshot(room)
    }

    private func applySnapshot(_ room: MobileListenAlongRoom) async {
        guard room.revision > lastAppliedRevision else { return }
        lastAppliedRevision = room.revision
        guard let source = MobileListenAlongSourcePolicy.validatedSource(room.snapshot.sourceURL) else {
            message = "The host is not sharing a playable source link."
            return
        }
        guard let library else { return }
        let position = room.projectedPosition()
        let sourceIdentity = MobileListenAlongSourcePolicy.identity(source)

        isApplyingRemoteSnapshot = true
        defer { isApplyingRemoteSnapshot = false }

        if library.followListenAlongCurrentStream(
            sourceIdentity: sourceIdentity,
            position: position,
            isPlaying: room.snapshot.isPlaying
        ) {
            return
        }

        if let localTrack = library.tracksForActiveProfile.first(where: {
            MobileListenAlongSourcePolicy.identity($0.sourceURL) == sourceIdentity
        }) {
            library.followListenAlongLocalTrack(
                localTrack,
                position: position,
                isPlaying: room.snapshot.isPlaying
            )
            return
        }

        if let remoteSong = library.remoteSongs.first(where: {
            MobileListenAlongSourcePolicy.identity($0.sourceURL) == sourceIdentity
        }), remoteSong.size > 0,
           remoteSong.mediaKind == "audio",
           library.activeDownloadMode == .streamOnly,
           await library.followListenAlongRemoteSong(
               remoteSong,
               position: position,
               isPlaying: room.snapshot.isPlaying
           ) {
            return
        }

        do {
            let mediaMode = LocalImportMediaMode(rawValue: room.snapshot.mediaKind) ?? .audio
            let resolution = try await importService.resolve(
                source: source,
                mediaMode: mediaMode,
                progress: { _ in }
            )
            guard let candidate = resolution.candidates.first else {
                throw MobileListenAlongError.unsupportedSource
            }
            let preview = try await importService.previewStream(for: candidate, mediaMode: mediaMode)
            try await library.playListenAlongPreview(
                preview,
                sourceURL: source,
                title: resolution.track.title,
                artist: resolution.track.artist,
                album: resolution.track.album ?? "Listen Along",
                artworkURL: (resolution.track.artworkURL ?? candidate.thumbnailURL)
                    .flatMap(URL.init(string:)),
                duration: TimeInterval(resolution.track.durationSeconds ?? 0),
                position: position,
                isPlaying: room.snapshot.isPlaying
            )
        } catch is CancellationError {
            return
        } catch {
            message = "Could not resolve the host's source: \(error.localizedDescription)"
        }
    }

    private func currentHostSnapshot() throws -> MobileListenAlongSnapshot {
        guard let library,
              let source = MobileListenAlongSourcePolicy.validatedSource(library.listenAlongCurrentSourceURL) else {
            throw MobileListenAlongError.noCurrentSource
        }
        return MobileListenAlongSnapshot(
            sourceURL: source,
            mediaKind: library.listenAlongCurrentMediaKind,
            positionSeconds: library.position,
            isPlaying: library.isPlaying
        )
    }

    private func networkContext() throws -> MobileListenAlongNetworkContext {
        guard let library else { throw MobileListenAlongError.notSignedIn }
        guard let baseURL = library.listenAlongServerURL,
              !library.serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileListenAlongError.notSignedIn
        }
        let requestContext = library.listenAlongRequestContext()
        guard requestContext.isComplete else { throw MobileListenAlongError.notSignedIn }
        return MobileListenAlongNetworkContext(
            baseURL: baseURL,
            accessToken: library.serverToken,
            requestContext: requestContext
        )
    }

    private func applyHeaders(to request: inout URLRequest, context: MobileListenAlongNetworkContext) {
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        context.requestContext.apply(to: &request)
    }

    private func perform(
        _ request: URLRequest,
        context: MobileListenAlongNetworkContext
    ) async throws -> (Data, HTTPURLResponse) {
        guard let requestURL = request.url,
              MobileServerEndpointPolicy.normalizedOrigin(of: requestURL)
                == MobileServerEndpointPolicy.normalizedOrigin(of: context.baseURL) else {
            throw URLError(.dataNotAllowed)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        let delegate = MobileListenAlongRedirectDelegate(origin: context.baseURL)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MobileListenAlongError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let payload = try? JSONDecoder().decode(ErrorPayload.self, from: data)
            throw MobileListenAlongError.server(
                status: httpResponse.statusCode,
                message: payload?.error ?? payload?.message
            )
        }
        guard MobileServerEndpointPolicy.normalizedOrigin(of: httpResponse.url ?? requestURL)
                == MobileServerEndpointPolicy.normalizedOrigin(of: context.baseURL) else {
            throw URLError(.dataNotAllowed)
        }
        return (data, httpResponse)
    }

    private func fetchRoomResponse(
        code: String,
        context: MobileListenAlongNetworkContext
    ) async throws -> MobileListenAlongResponse {
        var request = URLRequest(url: context.baseURL
            .appendingPathComponent("api/v1/listen-along")
            .appendingPathComponent(code))
        applyHeaders(to: &request, context: context)
        let (data, response) = try await perform(request, context: context)
        return try decodeResponse(data, response: response)
    }

    private func decodeResponse(_ data: Data, response: HTTPURLResponse) throws -> MobileListenAlongResponse {
        guard response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") != false else {
            throw MobileListenAlongError.invalidResponse
        }
        let payload = try JSONDecoder().decode(MobileListenAlongResponse.self, from: data)
        guard payload.schemaVersion == 1 else { throw MobileListenAlongError.invalidResponse }
        return payload
    }

    private func makeRoom(
        from response: MobileListenAlongResponse,
        code fallbackCode: String,
        role fallbackRole: MobileListenAlongRole,
        roleOverride: MobileListenAlongRole? = nil
    ) -> MobileListenAlongRoom {
        MobileListenAlongRoom(
            code: normalizedCode(response.code) ?? fallbackCode,
            revision: max(response.revision, 0),
            snapshot: response.snapshot,
            updatedAt: response.updatedAt,
            expiresAt: response.expiresAt,
            serverTime: response.serverTime,
            role: roleOverride ?? response.role ?? fallbackRole
        )
    }

    private func normalizedCode(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard value.count >= 5,
              value.count <= 32,
              value.contains("-"),
              value.allSatisfy({ $0.isNumber || $0.isLetter || $0 == "-" }) else { return nil }
        return value
    }

    private func clearRoom(message: String) {
        hostPublishGeneration &+= 1
        let wasParticipant = room?.role == .guest
        pollTask?.cancel()
        pollTask = nil
        hostPublishTask?.cancel()
        hostPublishTask = nil
        hostToken = nil
        room = nil
        if wasParticipant {
            library?.stopListenAlongPlaybackIfNeeded()
        }
        library?.refreshListenAlongControlState()
        lastAppliedRevision = -1
        isApplyingRemoteSnapshot = false
        self.message = message
    }
}

struct MobileListenAlongNetworkContext: Sendable {
    let baseURL: URL
    let accessToken: String
    let requestContext: MobileClientRequestContext
}
