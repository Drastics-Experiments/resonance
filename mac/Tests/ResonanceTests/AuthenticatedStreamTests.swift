import Foundation
import Testing
@testable import Resonance

@Suite
struct AuthenticatedStreamTests {
    @Test("authenticated stream requests retain headers and exact byte ranges")
    func buildsAuthenticatedRangeRequest() throws {
        let source = try #require(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let assetURL = try MacAuthenticatedStreamPolicy.assetURL(for: source)
        #expect(assetURL.scheme == "resonance-authenticated-stream")
        #expect(assetURL.host == source.host)
        #expect(assetURL.path == source.path)
        #expect(!assetURL.absoluteString.contains("token"))

        let request = try MacAuthenticatedStreamPolicy.request(
            sourceURL: source,
            headers: [
                "Authorization": "Bearer access-token",
                "X-Resonance-Profile": "profile-b",
                "X-Resonance-Client-Platform": "macos",
                "X-Resonance-App-Version": "1.1.4",
                "X-Resonance-App-Build": "15",
                "X-Resonance-Cohort-Key": "AAECAwQFBgcICQoLDA0ODw",
                "X-Resonance-Config-Protocol": "1",
            ],
            offset: 4_096,
            requestedLength: 8_192,
            requestsAllDataToEnd: false
        )
        #expect(request.url == source)
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=4096-12287")
        #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "profile-b")
        #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
        #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")

        let throughEnd = try MacAuthenticatedStreamPolicy.request(
            sourceURL: source,
            headers: [:],
            offset: 12_288,
            requestedLength: 1,
            requestsAllDataToEnd: true
        )
        #expect(throughEnd.value(forHTTPHeaderField: "Range") == "bytes=12288-")
    }

    @Test("stream responses require the exact URL and a coherent range")
    func validatesExactStreamResponse() throws {
        let source = try #require(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let response = try #require(HTTPURLResponse(
            url: source,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "8192",
                "Content-Range": "bytes 4096-12287/65536",
                "Accept-Ranges": "bytes",
            ]
        ))
        let metadata = try MacAuthenticatedStreamPolicy.validate(
            response: response,
            sourceURL: source,
            requestedOffset: 4_096,
            expectedContentLength: 65_536
        )
        #expect(metadata.contentLength == 65_536)
        #expect(metadata.responseLength == 8_192)
        #expect(metadata.supportsByteRanges)

        let redirected = try #require(HTTPURLResponse(
            url: URL(string: "https://objects.example/song.m4a")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "8192",
                "Content-Range": "bytes 4096-12287/65536",
            ]
        ))
        #expect(throws: MacAuthenticatedStreamError.crossOriginResponse) {
            try MacAuthenticatedStreamPolicy.validate(
                response: redirected,
                sourceURL: source,
                requestedOffset: 4_096
            )
        }

        let mismatchedRange = try #require(HTTPURLResponse(
            url: source,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "8192",
                "Content-Range": "bytes 0-8191/65536",
            ]
        ))
        #expect(throws: MacAuthenticatedStreamError.invalidRange) {
            try MacAuthenticatedStreamPolicy.validate(
                response: mismatchedRange,
                sourceURL: source,
                requestedOffset: 4_096
            )
        }
    }

    @Test("stream responses stay pinned to catalog size and media MIME")
    func rejectsSubstitutedStreamObjects() throws {
        let source = try #require(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let wrongSize = try #require(HTTPURLResponse(
            url: source,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "8192",
                "Content-Range": "bytes 0-8191/131072",
            ]
        ))
        #expect(throws: MacAuthenticatedStreamError.resourceMismatch) {
            try MacAuthenticatedStreamPolicy.validate(
                response: wrongSize,
                sourceURL: source,
                requestedOffset: 0,
                expectedContentLength: 65_536
            )
        }

        let playlist = try #require(HTTPURLResponse(
            url: source,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "application/vnd.apple.mpegurl",
                "Content-Length": "65536",
            ]
        ))
        #expect(throws: MacAuthenticatedStreamError.unsupportedContentType) {
            try MacAuthenticatedStreamPolicy.validate(
                response: playlist,
                sourceURL: source,
                requestedOffset: 0,
                expectedContentLength: 65_536
            )
        }

        let encoded = try #require(HTTPURLResponse(
            url: source,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Encoding": "gzip",
                "Content-Length": "65536",
            ]
        ))
        #expect(throws: MacAuthenticatedStreamError.invalidResponse) {
            try MacAuthenticatedStreamPolicy.validate(
                response: encoded,
                sourceURL: source,
                requestedOffset: 0,
                expectedContentLength: 65_536
            )
        }

        #expect(throws: MacAuthenticatedStreamError.resourceMismatch) {
            try MacAuthenticatedStreamPolicy.validate(
                response: wrongSize,
                sourceURL: source,
                requestedOffset: 0,
                expectedContentLength: 0
            )
        }
    }

    @Test("stream sessions cannot persist cookies, credentials, or cached media")
    func usesNonPersistentStreamSession() {
        let session = MacAuthenticatedStreamSession.makeEphemeral()
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.urlCredentialStorage == nil)
    }

    @Test("an expiring signed lease cancels in-flight stream work")
    func expiringLeaseCancelsInFlightWork() async throws {
        let now = Date.now
        let probe = StreamCancellationProbe()
        let lease = try MacAuthenticatedStreamAuthorizationLease(
            context: makeContext(),
            expiresAt: now.addingTimeInterval(0.05),
            now: now
        )
        lease.setInvalidationHandler { probe.cancel() }
        try lease.authorize(at: now.addingTimeInterval(0.01))

        try await Task.sleep(for: .milliseconds(150))

        #expect(probe.count == 1)
        #expect(throws: MacAuthenticatedStreamError.authorizationExpired) {
            try lease.authorize()
        }
    }

    @Test("only a valid exact-scope configuration can renew a stream lease")
    func leaseRenewalRequiresExactScope() throws {
        let now = Date.now
        let original = makeContext()
        let lease = try MacAuthenticatedStreamAuthorizationLease(
            context: original,
            expiresAt: now.addingTimeInterval(30),
            now: now
        )
        #expect(lease.renew(
            context: original,
            expiresAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(1)
        ))

        var changedScope = original
        changedScope = MacClientConfigContext(
            origin: changedScope.origin,
            profileID: "another-profile",
            appVersion: changedScope.appVersion,
            appBuild: changedScope.appBuild,
            cohortKey: changedScope.cohortKey,
            cohortBucket: changedScope.cohortBucket,
            tokenFingerprint: changedScope.tokenFingerprint
        )
        #expect(!lease.renew(
            context: changedScope,
            expiresAt: now.addingTimeInterval(90),
            now: now.addingTimeInterval(2)
        ))
        #expect(throws: MacAuthenticatedStreamError.authorizationExpired) {
            try lease.authorize(at: now.addingTimeInterval(3))
        }
    }

    @Test("remote stream media policy rejects videos and unverified sizes")
    func remoteMediaPolicyIsTruthful() {
        #expect(MacRemoteStreamMediaPolicy.unavailableMessage(kind: .audio, size: 1) == nil)
        #expect(MacRemoteStreamMediaPolicy.unavailableMessage(kind: .audio, size: 0)
            == MacRemoteStreamMediaPolicy.unknownSizeMessage)
        #expect(MacRemoteStreamMediaPolicy.unavailableMessage(kind: .video, size: 1)
            == MacRemoteStreamMediaPolicy.videoUnavailableMessage)
    }

    @Test("remote queues preserve ordered wrap, shuffle eligibility, and previous history")
    func remoteQueuePolicyPreservesNavigationSemantics() {
        let eligible = ["a", "b", "c", "d"]
        #expect(MacRemoteStreamQueuePolicy.orderedNextID(current: "d", eligible: eligible) == "a")
        #expect(MacRemoteStreamQueuePolicy.orderedPreviousID(current: "a", eligible: eligible) == "d")
        #expect(MacRemoteStreamQueuePolicy.reconciledShuffleQueue(
            existing: ["c", "gone", "c"],
            history: ["b"],
            current: "a",
            eligible: eligible,
            shuffleMissing: { Array($0.reversed()) }
        ) == ["c", "d"])

        var history = ["gone", "b", "c"]
        #expect(MacRemoteStreamQueuePolicy.popPreviousID(
            history: &history,
            eligible: Set(eligible)
        ) == "c")
        #expect(MacRemoteStreamQueuePolicy.popPreviousID(
            history: &history,
            eligible: Set(["a"])
        ) == nil)
    }

    @Test("stream history keeps remote identity and bounded metadata without retaining media")
    func transientStreamHistoryIsBoundedAndIdentitySafe() {
        let transient = Track(
            title: "Remote title",
            artist: "Remote artist",
            album: "Remote album",
            duration: 123,
            artwork: .weightless,
            remoteID: "remote-song-1",
            sourceServer: "https://music.example/",
            syncProfileID: "profile-a"
        )
        let entry = ListeningHistoryRetentionPolicy.entry(
            for: transient,
            serverOrigin: transient.sourceServer,
            profileID: "profile-a"
        )
        #expect(transient.fileURL == nil)
        #expect(entry.remoteSongID == "remote-song-1")
        #expect(entry.serverOrigin == "https://music.example")
        #expect(entry.syncProfileID == "profile-a")
        #expect(entry.title == transient.title)
        #expect(entry.duration == transient.duration)

        var retained = (0..<ListeningHistoryRetentionPolicy.maximumEntries).map { index in
            ListeningHistoryEntry(trackID: UUID(), title: "Prior \(index)")
        }
        let discardedID = retained[0].id
        ListeningHistoryRetentionPolicy.append(entry, to: &retained)
        #expect(retained.count == ListeningHistoryRetentionPolicy.maximumEntries)
        #expect(!retained.contains(where: { $0.id == discardedID }))
        #expect(retained.last == entry)
    }

    @Test("an expired signed download lease cancels transfer and discards staged bytes")
    func expiredDownloadLeaseCancelsAndRemovesStagingFile() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowDownloadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-expiring-download-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let source = try #require(URL(string: "https://music.example/api/v1/songs/song-1/file"))
        let now = Date.now
        let lease = try MacAuthenticatedStreamAuthorizationLease(
            context: makeContext(),
            expiresAt: now.addingTimeInterval(0.05),
            now: now
        )

        var cancelled = false
        do {
            _ = try await MacLeaseBoundDownloader.download(
                request: URLRequest(url: source),
                to: destination,
                expectedContentLength: 8,
                authorizationLease: lease,
                session: session
            )
        } catch is CancellationError {
            cancelled = true
        } catch MacAuthenticatedStreamError.authorizationExpired {
            cancelled = true
        }

        #expect(cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("same-context config refresh cannot extend a signed offline download deadline")
    func offlineAuthorizationCheckNeverRenewsCapturedExpiration() async throws {
        let now = Date.now
        let context = makeContext()
        let capturedExpiration = now.addingTimeInterval(0.05)
        let laterConfigurationExpiration = now.addingTimeInterval(60)
        let lease = try MacAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: capturedExpiration,
            now: now
        )
        #expect(laterConfigurationExpiration > capturedExpiration)
        #expect(MacOfflineDownloadAuthorizationPolicy.remainsAuthorized(
            lease: lease,
            context: context
        ))

        try await Task.sleep(for: .milliseconds(150))

        #expect(!MacOfflineDownloadAuthorizationPolicy.remainsAuthorized(
            lease: lease,
            context: context
        ))
        #expect(throws: MacAuthenticatedStreamError.authorizationExpired) {
            try lease.authorize()
        }
    }

    @Test("expiry after staging validation prevents atomic download install")
    func expiredFinalizationLeaseCannotAdoptStagedFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-finalization-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("installed.m4a")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date.now
        let lease = try MacAuthenticatedStreamAuthorizationLease(
            context: makeContext(),
            expiresAt: now.addingTimeInterval(0.05),
            now: now
        )
        try await Task.sleep(for: .milliseconds(150))
        var installCalled = false

        #expect(throws: MacAuthenticatedStreamError.authorizationExpired) {
            try MacAuthorizedDownloadFinalizer.finalize(authorizationLease: lease) {
                installCalled = true
                try Data([0x01]).write(to: destination)
            }
        }
        #expect(!installCalled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeContext() -> MacClientConfigContext {
        let cohort = "AAECAwQFBgcICQoLDA0ODw"
        return MacClientConfigContext(
            origin: "https://music.example",
            profileID: "default",
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohort,
            cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
            tokenFingerprint: MacClientConfigContext.tokenFingerprint("access-token")
        )
    }
}

private final class SlowDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: DispatchWorkItem?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "8",
                ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x01, 0x02]))
        let completion = DispatchWorkItem { [weak self] in
            guard let self,
                  self.lock.withLock({ !self.stopped }) else { return }
            self.client?.urlProtocol(self, didLoad: Data([0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        lock.withLock { self.completion = completion }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250), execute: completion)
    }

    override func stopLoading() {
        let completion = lock.withLock { () -> DispatchWorkItem? in
            stopped = true
            defer { self.completion = nil }
            return self.completion
        }
        completion?.cancel()
    }
}

private final class StreamCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func cancel() {
        lock.withLock { value += 1 }
    }
}
