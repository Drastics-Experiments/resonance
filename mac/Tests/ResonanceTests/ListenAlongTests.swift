import Foundation
import Testing
@testable import Resonance

private final class ListenAlongURLProtocol: URLProtocol {
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

@MainActor
@Suite(.serialized)
struct ListenAlongTests {
    private let baseURL = URL(string: "https://music.test")!

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ListenAlongURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBuilder(
        _ url: URL,
        _ method: String,
        _ body: Data?,
        _ headers: [String: String]
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer access-token", forHTTPHeaderField: "Authorization")
        request.setValue("default", forHTTPHeaderField: "X-Resonance-Profile")
        request.setValue("macOS", forHTTPHeaderField: "X-Resonance-Client-Platform")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func response(
        for request: URLRequest,
        status: Int = 200,
        body: Data
    ) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            body
        )
    }

    private func snapshotJSON(
        code: String = "ABCD-EFGH",
        revision: Int = 0,
        role: String,
        hostToken: String? = nil,
        sourceURL: String? = "https://www.youtube.com/watch?v=abc123",
        isPlaying: Bool = true
    ) throws -> Data {
        var object: [String: Any] = [
            "schema_version": 1,
            "code": code,
            "revision": revision,
            "source_url": sourceURL as Any,
            "media_kind": "audio",
            "position_seconds": 12.5,
            "is_playing": isPlaying,
            "updated_at": "2026-08-15T19:00:00Z",
            "expires_at": "2026-08-16T03:00:00Z",
            "server_time": "2026-08-15T19:00:01Z",
            "role": role,
        ]
        if let hostToken {
            object["host_token"] = hostToken
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func canonicalSourceAndProjectionAreSafeForProviderLinks() throws {
        #expect(MacListenAlongPollingPolicy.normalInterval == .milliseconds(250))
        #expect(MacListenAlongPollingPolicy.maximumFailureInterval == 8)
        #expect(
            MacListenAlongSourcePolicy.canonical(" HTTPS://YouTube.com/watch?v=abc123 ")
                == "https://youtube.com/watch?v=abc123"
        )
        #expect(MacListenAlongSourcePolicy.canonical("http://youtube.com/watch?v=abc123") == nil)
        #expect(MacListenAlongSourcePolicy.canonical("https://user:pass@example.com/song") == nil)
        #expect(MacListenAlongSourcePolicy.code("abcd-efgh") == "ABCD-EFGH")
        #expect(MacListenAlongSourcePolicy.code("bad code") == nil)

        let snapshot = MacListenAlongSnapshot(
            schemaVersion: 1,
            code: "ABCD-EFGH",
            revision: 2,
            sourceURL: "https://youtube.com/watch?v=abc123",
            mediaKind: .audio,
            positionSeconds: 10,
            isPlaying: true,
            updatedAt: "2026-08-15T19:00:00Z",
            expiresAt: "2026-08-16T03:00:00Z",
            serverTime: "2026-08-15T19:00:02Z",
            role: "guest",
            hostToken: nil
        )
        let projected = MacListenAlongPositionProjection.position(
            for: snapshot,
            now: Date(timeIntervalSince1970: 1_755_278_400)
        )
        #expect(projected >= 10)
    }

    @Test
    func hostLifecycleUsesExactEndpointsHeadersAndRevision() async throws {
        let requests = LockedListenAlongRequests()
        ListenAlongURLProtocol.handler = { request in
            requests.append(request)
            switch request.httpMethod {
            case "POST":
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(role: "host", hostToken: "host-secret")
                )
            case "PUT":
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(revision: 1, role: "host", hostToken: nil)
                )
            case "DELETE":
                return self.response(for: request, status: 204, body: Data())
            default:
                throw URLError(.badURL)
            }
        }
        defer { ListenAlongURLProtocol.handler = nil }

        let controller = MacListenAlongController(
            networkSession: session(),
            requestBuilder: requestBuilder
        )
        let created = try await controller.startHost(
            baseURL: baseURL,
            sourceURL: "https://www.youtube.com/watch?v=abc123",
            mediaKind: .audio,
            positionSeconds: 12,
            isPlaying: true
        )
        #expect(created.code == "ABCD-EFGH")
        #expect(controller.role == .host)

        controller.enqueueHostUpdate(
            sourceURL: created.sourceURL,
            mediaKind: .audio,
            positionSeconds: 15,
            isPlaying: false
        )
        try await Task.sleep(for: .milliseconds(100))
        await controller.endHost()

        let captured = requests.all()
        #expect(captured.map(\.httpMethod) == ["POST", "PUT", "DELETE"])
        #expect(captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-token" })
        #expect(captured.allSatisfy { $0.value(forHTTPHeaderField: "X-Resonance-Profile") == "default" })
        #expect(captured[1].value(forHTTPHeaderField: "X-Resonance-Listen-Host") == "host-secret")
        let body = try #require(captured[1].httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["revision"] as? Int == 0)
        #expect(object["is_playing"] as? Bool == false)
    }

    @Test
    func guestJoinStartsPollingAndDoesNotSendHostToken() async throws {
        let requests = LockedListenAlongRequests()
        ListenAlongURLProtocol.handler = { request in
            requests.append(request)
            return self.response(
                for: request,
                body: try self.snapshotJSON(role: "guest")
            )
        }
        defer { ListenAlongURLProtocol.handler = nil }

        let controller = MacListenAlongController(
            networkSession: session(),
            requestBuilder: requestBuilder
        )
        let snapshot = try await controller.joinGuest(baseURL: baseURL, code: "abcd-efgh")
        #expect(snapshot.code == "ABCD-EFGH")
        #expect(controller.role == .guest)
        #expect(requests.all().first?.url?.path == "/api/v1/listen-along/ABCD-EFGH")
        #expect(requests.all().first?.value(forHTTPHeaderField: "X-Resonance-Listen-Host") == nil)
        controller.leaveGuest()
    }

    @Test
    func hostPutConflictRecoversRevisionAndRetriesNewestStateOnce() async throws {
        let requests = LockedListenAlongRequests()
        ListenAlongURLProtocol.handler = { request in
            requests.append(request)
            switch request.httpMethod {
            case "POST":
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(role: "host", hostToken: "host-secret")
                )
            case "GET":
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(revision: 1, role: "guest")
                )
            case "PUT":
                let putCount = requests.all().filter { $0.httpMethod == "PUT" }.count
                if putCount == 1 {
                    return self.response(
                        for: request,
                        status: 409,
                        body: try self.snapshotJSON(revision: 1, role: "guest")
                    )
                }
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(revision: 2, role: "host", hostToken: nil)
                )
            default:
                throw URLError(.badURL)
            }
        }
        defer { ListenAlongURLProtocol.handler = nil }

        let controller = MacListenAlongController(
            networkSession: session(),
            requestBuilder: requestBuilder
        )
        _ = try await controller.startHost(
            baseURL: baseURL,
            sourceURL: "https://www.youtube.com/watch?v=abc123",
            mediaKind: .audio,
            positionSeconds: 12,
            isPlaying: true
        )
        controller.enqueueHostUpdate(
            sourceURL: "https://www.youtube.com/watch?v=abc123",
            mediaKind: .audio,
            positionSeconds: 18,
            isPlaying: false
        )
        try await Task.sleep(for: .milliseconds(200))

        let captured = requests.all()
        #expect(captured.map(\.httpMethod) == ["POST", "PUT", "GET", "PUT"])
        #expect(controller.snapshot?.revision == 2)
        let retriedBody = try #require(captured[3].httpBody)
        let retriedObject = try #require(JSONSerialization.jsonObject(with: retriedBody) as? [String: Any])
        #expect(retriedObject["revision"] as? Int == 1)
    }

    @Test
    func sourceLessHostTransitionBestEffortEndsTheServerRoom() async throws {
        let requests = LockedListenAlongRequests()
        ListenAlongURLProtocol.handler = { request in
            requests.append(request)
            switch request.httpMethod {
            case "POST":
                return self.response(
                    for: request,
                    body: try self.snapshotJSON(role: "host", hostToken: "host-secret")
                )
            case "DELETE":
                return self.response(for: request, status: 204, body: Data())
            default:
                throw URLError(.badURL)
            }
        }
        defer { ListenAlongURLProtocol.handler = nil }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            networkSession: session(),
            persistServerCredentials: false
        )
        model.serverURLString = baseURL.absoluteString
        model.serverToken = "access-token"
        let hosted = Track(
            title: "Hosted",
            artist: "Artist",
            album: "Album",
            duration: 60,
            artwork: .midnight,
            sourceURL: "https://www.youtube.com/watch?v=abc123"
        )
        model.tracks = [hosted]
        model.currentTrackID = hosted.id
        await model.startListenAlongHost()
        #expect(model.listenAlongRole == .host)

        let sourceLess = Track(
            title: "Local only",
            artist: "Artist",
            album: "Album",
            duration: 60,
            artwork: .midnight
        )
        model.tracks = [sourceLess]
        model.currentTrackID = sourceLess.id
        model.selectAndPlay(sourceLess)
        try await Task.sleep(for: .milliseconds(150))

        #expect(requests.all().map(\.httpMethod) == ["POST", "DELETE"])
        #expect(model.listenAlongRole == nil)
        #expect(model.listenAlongError == MacListenAlongError.invalidSource.localizedDescription)
    }
}

private final class LockedListenAlongRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = data
        }
        lock.withLock { requests.append(captured) }
    }

    func all() -> [URLRequest] {
        lock.withLock { requests }
    }
}
