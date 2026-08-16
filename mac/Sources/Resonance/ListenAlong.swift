import Foundation

enum MacListenAlongRole: String, Equatable, Sendable {
    case host
    case guest
}

enum MacListenAlongMediaKind: String, Codable, Sendable {
    case audio
    case video
}

struct MacListenAlongSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let code: String
    var revision: Int
    var sourceURL: String?
    var mediaKind: MacListenAlongMediaKind
    var positionSeconds: TimeInterval
    var isPlaying: Bool
    var updatedAt: String?
    var expiresAt: String?
    var serverTime: String?
    var role: String?
    var hostToken: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case code, revision
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
        case updatedAt = "updated_at"
        case expiresAt = "expires_at"
        case serverTime = "server_time"
        case role
        case hostToken = "host_token"
    }

    var normalizedRole: MacListenAlongRole? {
        guard let role else { return nil }
        return MacListenAlongRole(rawValue: role.lowercased())
    }

    var updatedDate: Date? { MacListenAlongDate.parse(updatedAt) }
    var expiresDate: Date? { MacListenAlongDate.parse(expiresAt) }
    var serverDate: Date? { MacListenAlongDate.parse(serverTime) }
}

private struct MacListenAlongCreatePayload: Encodable {
    let sourceURL: String?
    let mediaKind: MacListenAlongMediaKind
    let positionSeconds: TimeInterval
    let isPlaying: Bool

    enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
    }
}

private struct MacListenAlongHostUpdatePayload: Encodable {
    let sourceURL: String?
    let mediaKind: MacListenAlongMediaKind
    let positionSeconds: TimeInterval
    let isPlaying: Bool
    let revision: Int

    enum CodingKeys: String, CodingKey {
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
        case positionSeconds = "position_seconds"
        case isPlaying = "is_playing"
        case revision
    }
}

enum MacListenAlongDate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

enum MacListenAlongPositionProjection {
    static func position(
        for snapshot: MacListenAlongSnapshot,
        now: Date = .now
    ) -> TimeInterval {
        let base = max(snapshot.positionSeconds.isFinite ? snapshot.positionSeconds : 0, 0)
        guard snapshot.isPlaying,
              let serverDate = snapshot.serverDate else { return base }
        let localServerOffset = serverDate.timeIntervalSince(now)
        let projectedNow = now.addingTimeInterval(localServerOffset)
        let updated = snapshot.updatedDate ?? serverDate
        return max(base + max(projectedNow.timeIntervalSince(updated), 0), 0)
    }
}

enum MacListenAlongPollingPolicy {
    /// Listen Along is intentionally short-polled because the Core API exposes
    /// a revisioned snapshot rather than a long-lived socket. Keep the normal
    /// interval low enough that host actions feel immediate while retaining
    /// exponential backoff when the server or network is unavailable.
    static let normalInterval: Duration = .milliseconds(250)
    static let maximumFailureInterval: Double = 8
}

enum MacListenAlongSourcePolicy {
    static func canonical(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 0,
              trimmed.count <= 8_192,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              let url = components.url else { return nil }

        var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)
        canonical?.scheme = "https"
        canonical?.host = host.lowercased()
        return canonical?.url?.absoluteString
    }

    static func code(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count >= 6,
              trimmed.count <= 64,
              trimmed.first != "-",
              trimmed.last != "-",
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return trimmed
    }
}

enum MacListenAlongError: LocalizedError, Equatable {
    case invalidContext
    case invalidCode
    case invalidSource
    case invalidResponse
    case unsupportedSchema(Int)
    case server(Int, String?)
    case hostAuthorizationMissing
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .invalidContext:
            return "Listen Along is unavailable until a server account is connected."
        case .invalidCode:
            return "Enter a valid Listen Along code."
        case .invalidSource:
            return "This song has no supported source link."
        case .invalidResponse:
            return "The Listen Along server returned an invalid response."
        case .unsupportedSchema(let version):
            return "This Listen Along session uses an unsupported protocol version (\(version))."
        case .server(let status, let message):
            if let message, !message.isEmpty { return "Listen Along server error \(status): \(message)" }
            return "Listen Along server error \(status)."
        case .hostAuthorizationMissing:
            return "The host session authorization has expired."
        case .sessionExpired:
            return "This Listen Along session has ended."
        }
    }
}

@MainActor
final class MacListenAlongController {
    typealias RequestBuilder = (URL, String, Data?, [String: String]) throws -> URLRequest

    private struct PendingHostUpdate {
        var sourceURL: String?
        var mediaKind: MacListenAlongMediaKind
        var positionSeconds: TimeInterval
        var isPlaying: Bool
    }

    private let networkSession: URLSession
    private let requestBuilder: RequestBuilder
    private(set) var role: MacListenAlongRole?
    private(set) var snapshot: MacListenAlongSnapshot?
    private(set) var code: String?
    private var baseURL: URL?
    private var hostToken: String?
    private var pollingTask: Task<Void, Never>?
    private var hostUpdateTask: Task<Void, Never>?
    private var pendingHostUpdate: PendingHostUpdate?
    private var generation: UInt64 = 0

    var onSnapshot: ((MacListenAlongSnapshot, MacListenAlongRole) -> Void)?
    var onStatus: ((String) -> Void)?
    var onEnded: ((String) -> Void)?

    init(networkSession: URLSession, requestBuilder: @escaping RequestBuilder) {
        self.networkSession = networkSession
        self.requestBuilder = requestBuilder
    }

    deinit {
        pollingTask?.cancel()
        hostUpdateTask?.cancel()
    }

    func startHost(
        baseURL: URL,
        sourceURL: String,
        mediaKind: MacListenAlongMediaKind,
        positionSeconds: TimeInterval,
        isPlaying: Bool
    ) async throws -> MacListenAlongSnapshot {
        resetLocalState()
        guard let canonicalSource = MacListenAlongSourcePolicy.canonical(sourceURL) else {
            throw MacListenAlongError.invalidSource
        }
        let endpoint = baseURL.appendingPathComponent("api/v1/listen-along")
        let payload = MacListenAlongCreatePayload(
            sourceURL: canonicalSource,
            mediaKind: mediaKind,
            positionSeconds: max(positionSeconds.isFinite ? positionSeconds : 0, 0),
            isPlaying: isPlaying
        )
        let data = try JSONEncoder().encode(payload)
        let request = try requestBuilder(endpoint, "POST", data, ["Content-Type": "application/json"])
        let response = try await perform(request)
        let decoded = try decodeSnapshot(response.data)
        guard let token = decoded.hostToken, !token.isEmpty else {
            throw MacListenAlongError.hostAuthorizationMissing
        }
        let accepted = try accept(
            decoded,
            role: .host,
            baseURL: baseURL,
            hostToken: token,
            notify: false
        )
        onSnapshot?(accepted, .host)
        onStatus?("Hosting \(accepted.code)")
        return accepted
    }

    func joinGuest(baseURL: URL, code rawCode: String) async throws -> MacListenAlongSnapshot {
        resetLocalState()
        guard let code = MacListenAlongSourcePolicy.code(rawCode) else {
            throw MacListenAlongError.invalidCode
        }
        let endpoint = baseURL
            .appendingPathComponent("api/v1/listen-along")
            .appendingPathComponent(code)
        let request = try requestBuilder(endpoint, "GET", nil, [:])
        let response = try await perform(request)
        let decoded = try decodeSnapshot(response.data)
        let accepted = try accept(
            decoded,
            role: .guest,
            baseURL: baseURL,
            hostToken: nil,
            notify: false
        )
        onSnapshot?(accepted, .guest)
        onStatus?("Following \(accepted.code)")
        startPolling(baseURL: baseURL, code: accepted.code)
        return accepted
    }

    func enqueueHostUpdate(
        sourceURL: String?,
        mediaKind: MacListenAlongMediaKind,
        positionSeconds: TimeInterval,
        isPlaying: Bool
    ) {
        guard role == .host, snapshot != nil, hostToken != nil else { return }
        pendingHostUpdate = PendingHostUpdate(
            sourceURL: sourceURL.flatMap(MacListenAlongSourcePolicy.canonical),
            mediaKind: mediaKind,
            positionSeconds: max(positionSeconds.isFinite ? positionSeconds : 0, 0),
            isPlaying: isPlaying
        )
        guard hostUpdateTask == nil else { return }
        let taskGeneration = generation
        hostUpdateTask = Task { [weak self] in
            guard let self else { return }
            var recoveredRevisionForPendingUpdate = false
            while !Task.isCancelled, self.generation == taskGeneration {
                guard let pending = self.pendingHostUpdate else { break }
                self.pendingHostUpdate = nil
                do {
                    let updated = try await self.sendHostUpdate(pending)
                    guard self.generation == taskGeneration else { return }
                    self.snapshot = updated
                    self.onSnapshot?(updated, .host)
                    self.onStatus?("Hosting \(updated.code)")
                    recoveredRevisionForPendingUpdate = false
                } catch is CancellationError {
                    return
                } catch let error as MacListenAlongError {
                    guard case .server(409, _) = error,
                          !recoveredRevisionForPendingUpdate else {
                        self.onStatus?(error.localizedDescription)
                        recoveredRevisionForPendingUpdate = false
                        continue
                    }
                    do {
                        let recovered = try await self.fetchCurrentHostSnapshot()
                        guard self.generation == taskGeneration,
                              let recoveredBase = self.baseURL else { return }
                        let accepted = try self.accept(
                            recovered,
                            role: .host,
                            baseURL: recoveredBase,
                            hostToken: self.hostToken,
                            notify: false
                        )
                        self.snapshot = accepted
                        self.onSnapshot?(accepted, .host)
                        if self.pendingHostUpdate == nil {
                            self.pendingHostUpdate = pending
                        }
                        recoveredRevisionForPendingUpdate = true
                    } catch {
                        self.onStatus?(error.localizedDescription)
                        recoveredRevisionForPendingUpdate = false
                    }
                } catch {
                    self.onStatus?(error.localizedDescription)
                    recoveredRevisionForPendingUpdate = false
                }
            }
            if self.generation == taskGeneration {
                self.hostUpdateTask = nil
            }
        }
    }

    func endHost() async {
        guard role == .host,
              let baseURL,
              let code,
              let hostToken,
              !hostToken.isEmpty else {
            resetLocalState()
            return
        }
        let endpoint = baseURL
            .appendingPathComponent("api/v1/listen-along")
            .appendingPathComponent(code)
        do {
            let request = try requestBuilder(
                endpoint,
                "DELETE",
                nil,
                ["X-Resonance-Listen-Host": hostToken]
            )
            _ = try await perform(request)
        } catch {
            onStatus?(error.localizedDescription)
        }
        onEnded?("Listen Along ended")
        resetLocalState()
    }

    func leaveGuest() {
        guard role == .guest else {
            resetLocalState()
            return
        }
        onEnded?("Left Listen Along")
        resetLocalState()
    }

    func resetLocalState() {
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        hostUpdateTask?.cancel()
        hostUpdateTask = nil
        pendingHostUpdate = nil
        role = nil
        snapshot = nil
        code = nil
        baseURL = nil
        hostToken = nil
    }

    private func sendHostUpdate(_ pending: PendingHostUpdate) async throws -> MacListenAlongSnapshot {
        guard let baseURL,
              let code,
              let hostToken,
              !hostToken.isEmpty,
              let snapshot else { throw MacListenAlongError.hostAuthorizationMissing }
        let endpoint = baseURL
            .appendingPathComponent("api/v1/listen-along")
            .appendingPathComponent(code)
        let payload = MacListenAlongHostUpdatePayload(
            sourceURL: pending.sourceURL,
            mediaKind: pending.mediaKind,
            positionSeconds: pending.positionSeconds,
            isPlaying: pending.isPlaying,
            revision: snapshot.revision
        )
        let data = try JSONEncoder().encode(payload)
        let request = try requestBuilder(
            endpoint,
            "PUT",
            data,
            [
                "Content-Type": "application/json",
                "X-Resonance-Listen-Host": hostToken,
            ]
        )
        let response = try await perform(request)
        return try accept(
            try decodeSnapshot(response.data),
            role: .host,
            baseURL: baseURL,
            hostToken: hostToken,
            notify: false
        )
    }

    private func fetchCurrentHostSnapshot() async throws -> MacListenAlongSnapshot {
        guard let baseURL,
              let code else { throw MacListenAlongError.hostAuthorizationMissing }
        let endpoint = baseURL
            .appendingPathComponent("api/v1/listen-along")
            .appendingPathComponent(code)
        let request = try requestBuilder(endpoint, "GET", nil, [:])
        let response = try await perform(request)
        return try decodeSnapshot(response.data)
    }

    private func startPolling(baseURL: URL, code: String) {
        pollingTask?.cancel()
        let taskGeneration = generation
        pollingTask = Task { [weak self] in
            guard let self else { return }
            var delay: Double = 0.25
            while !Task.isCancelled, self.generation == taskGeneration {
                do {
                    let endpoint = baseURL
                        .appendingPathComponent("api/v1/listen-along")
                        .appendingPathComponent(code)
                    let request = try self.requestBuilder(endpoint, "GET", nil, [:])
                    let response = try await self.perform(request)
                    let decoded = try self.decodeSnapshot(response.data)
                    guard self.generation == taskGeneration else { return }
                    if let expires = decoded.expiresDate,
                       let serverDate = decoded.serverDate,
                       expires <= serverDate {
                        self.onEnded?(MacListenAlongError.sessionExpired.localizedDescription)
                        self.resetLocalState()
                        return
                    }
                    if self.shouldAccept(decoded) {
                        let accepted = try self.accept(
                            decoded,
                            role: .guest,
                            baseURL: baseURL,
                            hostToken: nil,
                            notify: false
                        )
                        self.onSnapshot?(accepted, .guest)
                        self.onStatus?("Following \(accepted.code)")
                    }
                    delay = 0.25
                } catch is CancellationError {
                    return
                } catch let error as MacListenAlongError {
                    if case .server(let status, _) = error, status == 404 || status == 410 {
                        self.onEnded?(MacListenAlongError.sessionExpired.localizedDescription)
                        self.resetLocalState()
                        return
                    }
                    self.onStatus?(error.localizedDescription)
                    delay = min(delay * 2, MacListenAlongPollingPolicy.maximumFailureInterval)
                } catch {
                    self.onStatus?(error.localizedDescription)
                    delay = min(delay * 2, MacListenAlongPollingPolicy.maximumFailureInterval)
                }
                do {
                    if delay == 0.25 {
                        try await Task.sleep(for: MacListenAlongPollingPolicy.normalInterval)
                    } else {
                        try await Task.sleep(for: .seconds(delay))
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func shouldAccept(_ incoming: MacListenAlongSnapshot) -> Bool {
        guard let current = snapshot else { return true }
        if incoming.revision > current.revision { return true }
        guard incoming.revision == current.revision else { return false }
        return incoming.updatedAt != current.updatedAt
    }

    @discardableResult
    private func accept(
        _ incoming: MacListenAlongSnapshot,
        role: MacListenAlongRole,
        baseURL: URL,
        hostToken: String?,
        notify: Bool
    ) throws -> MacListenAlongSnapshot {
        guard incoming.schemaVersion == 1 else {
            throw MacListenAlongError.unsupportedSchema(incoming.schemaVersion)
        }
        guard let code = MacListenAlongSourcePolicy.code(incoming.code) else {
            throw MacListenAlongError.invalidCode
        }
        let source = incoming.sourceURL.flatMap(MacListenAlongSourcePolicy.canonical)
        var accepted = incoming
        accepted.sourceURL = source
        accepted.role = role.rawValue
        accepted.hostToken = hostToken ?? incoming.hostToken
        accepted.mediaKind = incoming.mediaKind
        accepted.positionSeconds = max(
            incoming.positionSeconds.isFinite ? incoming.positionSeconds : 0,
            0
        )
        self.role = role
        self.snapshot = accepted
        self.code = code
        self.baseURL = baseURL
        if let hostToken { self.hostToken = hostToken }
        if notify { onSnapshot?(accepted, role) }
        return accepted
    }

    private func decodeSnapshot(_ data: Data) throws -> MacListenAlongSnapshot {
        do {
            return try JSONDecoder().decode(MacListenAlongSnapshot.self, from: data)
        } catch {
            throw MacListenAlongError.invalidResponse
        }
    }

    private func perform(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = request
        // A successful snapshot may be followed by another revision within
        // the same second. Bypass URLSession's cache so guests never wait for
        // a stale response before applying the host's latest action.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        let (data, rawResponse) = try await networkSession.data(
            for: request,
            delegate: MacRejectRedirectDelegate()
        )
        guard let response = rawResponse as? HTTPURLResponse else {
            throw MacListenAlongError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(2_048), encoding: .utf8)
            throw MacListenAlongError.server(response.statusCode, message)
        }
        return (data, response)
    }
}
