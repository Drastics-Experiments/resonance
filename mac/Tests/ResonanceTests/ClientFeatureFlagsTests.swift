import Foundation
import Testing
@testable import Resonance

private final class ClientConfigURLProtocol: URLProtocol {
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
struct ClientFeatureFlagsTests {
    private let token = "fixture-access-token-v1"

    @Test("signed snapshots require exact bytes, HMAC, and audience")
    func verifiesSignatureDigestAndAudience() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let context = makeContext(profileID: "profile-a")
        let fixture = try makeFixture(context: context, now: now)

        let verified = try MacClientConfigVerifier.verify(
            body: fixture.body,
            contentDigest: fixture.headers.contentDigest,
            signature: fixture.headers.signature,
            context: context,
            accessToken: token,
            now: now
        )
        #expect(verified.schemaVersion == 1)
        #expect(verified.audience == context.audience)

        var tampered = fixture.body
        tampered.append(0x20)
        #expect(throws: MacClientConfigVerificationError.invalidDigest) {
            try MacClientConfigVerifier.verify(
                body: tampered,
                contentDigest: fixture.headers.contentDigest,
                signature: fixture.headers.signature,
                context: context,
                accessToken: token,
                now: now
            )
        }

        #expect(throws: MacClientConfigVerificationError.invalidSignature) {
            try MacClientConfigVerifier.verify(
                body: fixture.body,
                contentDigest: fixture.headers.contentDigest,
                signature: "v1=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:",
                context: context,
                accessToken: token,
                now: now
            )
        }

        let otherProfile = makeContext(profileID: "profile-b")
        #expect(throws: MacClientConfigVerificationError.wrongAudience) {
            try MacClientConfigVerifier.verify(
                body: fixture.body,
                contentDigest: fixture.headers.contentDigest,
                signature: fixture.headers.signature,
                context: otherProfile,
                accessToken: token,
                now: now
            )
        }
    }

    @Test("unknown enums and unsafe storage capabilities fail closed")
    func rejectsUnknownAndUnsafeValues() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let context = makeContext()
        let unknown = try makeFixture(
            context: context,
            now: now,
            playbackMode: "provider_object"
        )
        #expect(throws: MacClientConfigVerificationError.invalidJSON) {
            try MacClientConfigVerifier.verify(
                body: unknown.body,
                contentDigest: unknown.headers.contentDigest,
                signature: unknown.headers.signature,
                context: context,
                accessToken: token,
                now: now
            )
        }

        let external = try makeFixture(
            context: context,
            now: now,
            storageReadMode: "external_with_r2_fallback"
        )
        #expect(throws: MacClientConfigVerificationError.unsafeValue) {
            try MacClientConfigVerifier.verify(
                body: external.body,
                contentDigest: external.headers.contentDigest,
                signature: external.headers.signature,
                context: context,
                accessToken: token,
                now: now
            )
        }
    }

    @Test("safe defaults expose only verified legacy transfers")
    func safeDefaults() {
        let policy = MacEffectiveClientConfig.safeDefaults
        #expect(policy.allowsLocalFileUpload)
        #expect(policy.allowsOfflineDownload)
        #expect(!policy.allowsServerSourceLink)
        #expect(!policy.allowsReviewedMatch)
        #expect(policy.permittedUploadModes == [.localFile])
    }

    @Test("cache and mode scopes separate profile, version, build, and token")
    func scopesCachesAndPreferences() {
        let base = makeContext(profileID: "profile-a")
        let otherProfile = makeContext(profileID: "profile-b")
        let otherToken = makeContext(profileID: "profile-a", token: "other-token")
        let otherVersion = MacClientConfigContext(
            origin: base.origin,
            profileID: base.profileID,
            appVersion: "9.9.9",
            appBuild: base.appBuild,
            cohortKey: base.cohortKey,
            cohortBucket: base.cohortBucket,
            tokenFingerprint: base.tokenFingerprint
        )
        let otherBuild = MacClientConfigContext(
            origin: base.origin,
            profileID: base.profileID,
            appVersion: base.appVersion,
            appBuild: base.appBuild + 1,
            cohortKey: base.cohortKey,
            cohortBucket: base.cohortBucket,
            tokenFingerprint: base.tokenFingerprint
        )
        let otherCohortKey = "AQECAwQFBgcICQoLDA0ODw"
        let otherCohort = MacClientConfigContext(
            origin: base.origin,
            profileID: base.profileID,
            appVersion: base.appVersion,
            appBuild: base.appBuild,
            cohortKey: otherCohortKey,
            cohortBucket: MacClientConfigContext.cohortBucket(for: otherCohortKey),
            tokenFingerprint: base.tokenFingerprint
        )

        #expect(base.cacheKey != otherProfile.cacheKey)
        #expect(base.cacheKey != otherToken.cacheKey)
        #expect(base.cacheKey != otherVersion.cacheKey)
        #expect(base.cacheKey != otherBuild.cacheKey)
        #expect(base.cacheKey != otherCohort.cacheKey)
    }

    @Test("expired policy reverts to safe modes and future snapshots are rejected")
    func expiryFallsBack() throws {
        let now = Date.now
        let context = makeContext()
        let fixture = try makeFixture(
            context: context,
            now: now,
            issuedAt: now.addingTimeInterval(-900),
            notBefore: now.addingTimeInterval(-900),
            expiresAt: now.addingTimeInterval(-1),
            localFile: false,
            sourceLink: true
        )
        let decoded = try JSONDecoder().decode(MacClientConfigDocument.self, from: fixture.body)
        let expired = MacEffectiveClientConfig(document: decoded, source: .verifiedServer)
        #expect(expired.allowsLocalFileUpload)
        #expect(expired.allowsOfflineDownload)
        #expect(!expired.allowsServerSourceLink)

        #expect(throws: MacClientConfigVerificationError.invalidTime) {
            try MacClientConfigVerifier.verify(
                body: fixture.body,
                contentDigest: fixture.headers.contentDigest,
                signature: fixture.headers.signature,
                context: context,
                accessToken: token,
                now: now
            )
        }

        let future = try makeFixture(
            context: context,
            now: now,
            issuedAt: now.addingTimeInterval(30),
            notBefore: now.addingTimeInterval(30),
            expiresAt: now.addingTimeInterval(300)
        )
        #expect(throws: MacClientConfigVerificationError.invalidTime) {
            try MacClientConfigVerifier.verify(
                body: future.body,
                contentDigest: future.headers.contentDigest,
                signature: future.headers.signature,
                context: context,
                accessToken: token,
                now: now
            )
        }
    }

    @Test("disabled persisted modes fall back while verified stream-only remains playable")
    func modeFallback() throws {
        let now = Date.now
        let context = makeContext()
        let fixture = try makeFixture(
            context: context,
            now: now,
            localFile: false,
            sourceLink: true,
            reviewedMatch: true,
            matcherMode: "review",
            offlineMode: "stream_only"
        )
        let document = try MacClientConfigVerifier.verify(
            body: fixture.body,
            contentDigest: fixture.headers.contentDigest,
            signature: fixture.headers.signature,
            context: context,
            accessToken: token,
            now: now
        )
        let policy = MacEffectiveClientConfig(document: document, source: .verifiedServer)
        #expect(policy.resolvedUploadMode(.localFile) == .serverSourceLink)
        #expect(policy.permittedUploadModes == [.serverSourceLink])
        #expect(policy.requestedStreamOnly)
        #expect(policy.allowsStreamOnlyPlayback)

        let reviewedFixture = try makeFixture(
            context: context,
            now: now,
            localFile: true,
            sourceLink: false,
            reviewedMatch: true,
            matcherMode: "review"
        )
        let reviewedDocument = try MacClientConfigVerifier.verify(
            body: reviewedFixture.body,
            contentDigest: reviewedFixture.headers.contentDigest,
            signature: reviewedFixture.headers.signature,
            context: context,
            accessToken: token,
            now: now
        )
        let reviewedPolicy = MacEffectiveClientConfig(document: reviewedDocument, source: .verifiedServer)
        #expect(reviewedPolicy.permittedUploadModes == [.localFile, .reviewedMatch])

        let linkKilledFixture = try makeFixture(
            context: context,
            now: now,
            localFile: true,
            sourceLink: true,
            reviewedMatch: true,
            matcherMode: "review",
            linkImportsKilled: true
        )
        let linkKilledDocument = try MacClientConfigVerifier.verify(
            body: linkKilledFixture.body,
            contentDigest: linkKilledFixture.headers.contentDigest,
            signature: linkKilledFixture.headers.signature,
            context: context,
            accessToken: token,
            now: now
        )
        let linkKilledPolicy = MacEffectiveClientConfig(document: linkKilledDocument, source: .verifiedServer)
        #expect(!linkKilledPolicy.allowsServerSourceLink)
        #expect(linkKilledPolicy.allowsReviewedMatch)
        #expect(linkKilledPolicy.permittedUploadModes == [.localFile, .reviewedMatch])
    }

    @Test("cohort identity is stable, anonymous, and exactly 128 bits")
    func cohortIdentity() throws {
        let suite = "ClientFeatureFlagsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = MacClientConfigIdentity.cohortKey(defaults: defaults)
        let second = MacClientConfigIdentity.cohortKey(defaults: defaults)
        #expect(first == second)
        #expect(!first.contains("="))
        #expect((0..<10_000).contains(MacClientConfigContext.cohortBucket(for: first)))

        let malformed = String(first.dropLast()) + (first.last == "x" ? "y" : "x")
        defaults.set(malformed, forKey: MacClientConfigIdentity.cohortKeyDefaultsKey)
        let regenerated = MacClientConfigIdentity.cohortKey(defaults: defaults)
        #expect(regenerated != malformed)
        #expect(regenerated.count == 22)
        #expect(defaults.string(forKey: MacClientConfigIdentity.cohortKeyDefaultsKey) == regenerated)
    }

    @Test("client-config request uses exact headers and admin-only fallback")
    func exactRequestHeaders() async throws {
        let suite = "ClientFeatureFlagsNetworkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        ClientConfigURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/client-config")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer admin-only-token")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Profile") == "default")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform") == "macos")
            #expect(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol") == "1")
            #expect(Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 0 > 0)
            #expect(!(request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "").isEmpty)
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            #expect(!cohort.contains("="))
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverAdminToken = "admin-only-token"
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.source == .legacyServer)
        #expect(model.clientConfiguration.permittedUploadModes == [.localFile])
    }

    @Test("server matcher lookup requires the complete effective reviewed-match policy")
    func matcherLookupUsesEffectiveReviewedPolicy() async throws {
        let suite = "ClientFeatureFlagsMatcherGate.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClientConfigURLProtocol.handler = { request in
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
            )
            let fixture = try makeFixture(
                context: context,
                now: .now,
                localFile: defaults.bool(forKey: "local-file"),
                reviewedMatch: defaults.bool(forKey: "reviewed-match"),
                matcherMode: "review",
                allUploadsKilled: defaults.bool(forKey: "all-uploads")
            )
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Digest": fixture.headers.contentDigest,
                    "X-Resonance-Config-Signature": fixture.headers.signature,
                ])!,
                fixture.body
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        model.serverAdminToken = "admin-token"

        defaults.set(true, forKey: "local-file")
        defaults.set(false, forKey: "reviewed-match")
        await model.refreshClientConfigurationNow()
        #expect(model.localImportServerConfiguration == nil)

        defaults.set(false, forKey: "local-file")
        defaults.set(true, forKey: "reviewed-match")
        await model.refreshClientConfigurationNow()
        #expect(model.localImportServerConfiguration == nil)

        defaults.set(true, forKey: "local-file")
        defaults.set(true, forKey: "all-uploads")
        await model.refreshClientConfigurationNow()
        #expect(model.localImportServerConfiguration == nil)
        let importViewModel = MacLocalImportViewModel(model: model)
        #expect(!importViewModel.canSync)
        #expect(importViewModel.syncAvailabilityMessage.contains("Uploads are disabled"))

        defaults.set(false, forKey: "all-uploads")
        await model.refreshClientConfigurationNow()
        let matcherConfiguration = try #require(model.localImportServerConfiguration)
        #expect(matcherConfiguration.profileID == "default")
        #expect(matcherConfiguration.clientContext.origin == "https://music.example")
        #expect(importViewModel.canSync)
    }

    @Test("upload mode selection persists and local-import transfers honor reviewed-match requirements")
    func localImportTransferModePolicy() async throws {
        let suite = "ClientFeatureFlagsTransferPolicy.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClientConfigURLProtocol.handler = { request in
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
            )
            let fixture = try makeFixture(
                context: context,
                now: .now,
                localFile: true,
                sourceLink: true,
                reviewedMatch: true,
                matcherMode: "review"
            )
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Digest": fixture.headers.contentDigest,
                    "X-Resonance-Config-Signature": fixture.headers.signature,
                ])!,
                fixture.body
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        model.serverAdminToken = "admin-token"
        await model.refreshClientConfigurationNow()
        #expect(model.uploadMode == .localFile)

        model.selectUploadMode(.serverSourceLink)
        #expect(model.uploadMode == .serverSourceLink)
        await model.refreshClientConfigurationNow()
        #expect(model.uploadMode == .serverSourceLink)

        let shortLinkContext = try model.beginLocalImportTransfer(
            reservingUpload: true,
            rawSourceInput: "https://youtu.be/dQw4w9WgXcQ",
            mediaMode: .audio
        )
        #expect(shortLinkContext.uploadMode == .serverSourceLink)
        model.endLocalImportTransfer(shortLinkContext)

        let canonical = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let videoContext = try model.beginLocalImportTransfer(
            reservingUpload: true,
            rawSourceInput: canonical,
            mediaMode: .video
        )
        #expect(videoContext.mediaMode == .video)
        model.endLocalImportTransfer(videoContext)

        let sourceContext = try model.beginLocalImportTransfer(
            reservingUpload: true,
            rawSourceInput: canonical,
            mediaMode: .audio
        )
        #expect(sourceContext.rawSourceInput == canonical)
        #expect(sourceContext.uploadMode == .serverSourceLink)
        model.endLocalImportTransfer(sourceContext)

        let reviewedContext = try model.beginLocalImportTransfer(
            reservingUpload: true,
            rawSourceInput: "playlist search",
            mediaMode: .audio,
            requiresReviewedMatch: true
        )
        #expect(reviewedContext.uploadMode == .reviewedMatch)
        #expect(reviewedContext.requiresReviewedMatch)
        model.endLocalImportTransfer(reviewedContext)

        model.selectUploadMode(.localFile)
        #expect(model.uploadMode == .localFile)
    }

    @Test("editing source invalidates source-link and reviewed selections before import")
    func sourceMutationInvalidatesResolvedImportIdentity() throws {
        let suite = "ClientFeatureFlagsSourceMutation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        let viewModel = MacLocalImportViewModel(model: model)

        func result(
            provider: LocalImportSearchProvider,
            sourceURL: String,
            identifier: String
        ) -> LocalImportSearchResult {
            let track = LocalImportSpotifyTrack(
                provider: provider.rawValue,
                type: "track",
                trackID: identifier,
                title: "Resolved \(identifier)",
                artist: "Artist",
                album: "Album",
                trackNumber: 1,
                durationSeconds: 180,
                artworkURL: nil,
                embedURL: sourceURL,
                sourceURL: sourceURL
            )
            let candidate = LocalImportAudioSourceMatch(
                videoID: identifier,
                title: track.title,
                artist: track.artist,
                album: track.album,
                durationSeconds: track.durationSeconds,
                thumbnailURL: nil,
                sourceProvider: .youtube,
                officialArtist: true,
                sourceURL: sourceURL,
                score: 1,
                confidence: "high",
                match: .init(title: 1, artist: 1, album: 1, duration: 1, durationDeltaSeconds: 0)
            )
            return LocalImportSearchResult(provider: provider, track: track, candidates: [candidate])
        }

        let sourceA = "https://www.youtube.com/watch?v=AAAAAAAAAAA"
        viewModel.source = sourceA
        viewModel.selectSearchResult(result(
            provider: .youtube,
            sourceURL: sourceA,
            identifier: "AAAAAAAAAAA"
        ))
        #expect(viewModel.resolvedSourceInput == sourceA)
        #expect(viewModel.resolution?.kind == .youtube)
        #expect(viewModel.selectedCandidate?.videoID == "AAAAAAAAAAA")
        #expect(!viewModel.requiresReviewedMatchForUpload)

        viewModel.source = "https://www.youtube.com/watch?v=BBBBBBBBBBB"
        #expect(viewModel.resolvedSourceInput == nil)
        #expect(viewModel.resolution == nil)
        #expect(viewModel.selectedCandidate == nil)
        #expect(viewModel.stage == .idle)
        #expect(!viewModel.importSelected())

        viewModel.source = "Song A by Artist"
        viewModel.selectSearchResult(result(
            provider: .spotify,
            sourceURL: "https://open.spotify.com/track/AAAAAAAAAAAAAAAAAAAAAA",
            identifier: "reviewed-a"
        ))
        #expect(viewModel.resolvedSourceInput == "Song A by Artist")
        #expect(viewModel.resolution?.kind == .spotify)
        #expect(viewModel.selectedCandidate?.videoID == "reviewed-a")
        #expect(!viewModel.requiresReviewedMatchForUpload)

        viewModel.source = "Song B by Artist"
        #expect(viewModel.resolvedSourceInput == nil)
        #expect(viewModel.resolution == nil)
        #expect(viewModel.selectedCandidate == nil)
        #expect(viewModel.stage == .idle)
        #expect(!viewModel.importSelected())
    }

    @Test("credential-bearing feature and transfer requests reject redirects")
    func rejectsRedirects() throws {
        let original = try #require(URL(string: "https://music.example/api/v1/client-config"))
        let redirected = try #require(URL(string: "https://objects.example/config"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        let response = try #require(
            HTTPURLResponse(
                url: original,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": redirected.absoluteString]
            )
        )
        var completionCalled = false
        var acceptedRequest: URLRequest? = URLRequest(url: redirected)
        MacRejectRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirected)
        ) { request in
            completionCalled = true
            acceptedRequest = request
        }
        #expect(completionCalled)
        #expect(acceptedRequest == nil)
    }

    @Test("4xx and wrong content type evict scoped config cache")
    func invalidResponsesEvictCache() async throws {
        let suite = "ClientFeatureFlagsInvalidResponseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClientConfigURLProtocol.handler = { request in
            let url = try #require(request.url)
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint("access-token")
            )
            defaults.set(Data("cached".utf8), forKey: context.cacheKey)
            defaults.set(context.cacheKey, forKey: "test.cache-key")
            let status = defaults.integer(forKey: "test.status")
            let headers: [String: String]? = if defaults.bool(forKey: "test.oversized") {
                ["Content-Type": "application/json", "Content-Length": "131073"]
            } else if status == 200 {
                ["Content-Type": "text/plain"]
            } else {
                nil
            }
            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!,
                Data("{}".utf8)
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = "access-token"

        defaults.set(401, forKey: "test.status")
        await model.refreshClientConfigurationNow()
        let unauthorizedCacheKey = try #require(defaults.string(forKey: "test.cache-key"))
        #expect(defaults.data(forKey: unauthorizedCacheKey) == nil)
        #expect(model.clientConfiguration.source == .safeDefaults)

        defaults.set(200, forKey: "test.status")
        await model.refreshClientConfigurationNow()
        let contentTypeCacheKey = try #require(defaults.string(forKey: "test.cache-key"))
        #expect(defaults.data(forKey: contentTypeCacheKey) == nil)
        #expect(model.clientConfiguration.source == .safeDefaults)

        defaults.set(true, forKey: "test.oversized")
        await model.refreshClientConfigurationNow()
        let oversizedCacheKey = try #require(defaults.string(forKey: "test.cache-key"))
        #expect(defaults.data(forKey: oversizedCacheKey) == nil)
        #expect(model.clientConfiguration.source == .safeDefaults)
    }

    @Test("cancelled config fetch retains stream policy only through fresh exact-scope cache")
    func cancelledConfigRequestRequiresReverifiedCache() async throws {
        let suite = "ClientFeatureFlagsCancelledConfig.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClientConfigURLProtocol.handler = { request in
            if defaults.bool(forKey: "cancel-request") {
                throw URLError(.cancelled)
            }
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
            )
            defaults.set(context.cacheKey, forKey: "cache-key")
            let fixture = try makeFixture(
                context: context,
                now: .now,
                offlineMode: "stream_only"
            )
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Digest": fixture.headers.contentDigest,
                    "X-Resonance-Config-Signature": fixture.headers.signature,
                ])!,
                fixture.body
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.source == .verifiedServer)
        #expect(model.clientConfiguration.allowsStreamOnlyPlayback)

        defaults.set(true, forKey: "cancel-request")
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.source == .verifiedCache)
        #expect(model.clientConfiguration.allowsStreamOnlyPlayback)

        let cacheKey = try #require(defaults.string(forKey: "cache-key"))
        defaults.removeObject(forKey: cacheKey)
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.source == .safeDefaults)
        #expect(!model.clientConfiguration.allowsStreamOnlyPlayback)
    }

    @Test("higher-revision revoke with unchanged expiry survives automatic renewal")
    func equalExpiryRenewalNeverRestoresRevokedStreamPolicy() async throws {
        let suite = "ClientFeatureFlagsEqualExpiryRevoke.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sharedExpiration = Date.now.addingTimeInterval(6.5)
        ClientConfigURLProtocol.handler = { request in
            let requestNumber = defaults.integer(forKey: "request-count") + 1
            defaults.set(requestNumber, forKey: "request-count")
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
            )
            let fixture = try makeFixture(
                context: context,
                now: .now,
                revision: requestNumber == 1 ? 40 : 41,
                expiresAt: sharedExpiration,
                offlineMode: requestNumber == 1 ? "stream_only" : "verified_file_cache"
            )
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Digest": fixture.headers.contentDigest,
                    "X-Resonance-Config-Signature": fixture.headers.signature,
                ])!,
                fixture.body
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        await model.refreshClientConfigurationNow()
        let initialExpiry = try #require(model.clientConfiguration.document?.expiresAt)
        #expect(model.clientConfiguration.document?.revision == 40)
        #expect(model.clientConfiguration.allowsStreamOnlyPlayback)

        for _ in 0..<500 where model.clientConfiguration.document?.revision != 41 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(defaults.integer(forKey: "request-count") >= 2)
        #expect(model.clientConfiguration.document?.revision == 41)
        #expect(model.clientConfiguration.document?.expiresAt == initialExpiry)
        #expect(!model.clientConfiguration.allowsStreamOnlyPlayback)
        #expect(model.clientConfiguration.allowsOfflineDownload)
    }

    @Test("a signed lower revision cannot replay over the exact verified scope")
    func rejectsSignedRevisionRollback() async throws {
        let suite = "ClientFeatureFlagsRevisionRollback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ClientConfigURLProtocol.handler = { request in
            let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
            let context = MacClientConfigContext(
                origin: "https://music.example",
                profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                cohortKey: cohort,
                cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
            )
            defaults.set(context.cacheKey, forKey: "scope-cache-key")
            defaults.set(context.highestRevisionKey, forKey: "scope-revision-key")
            let fixture = try makeFixture(
                context: context,
                now: .now,
                revision: defaults.integer(forKey: "response-revision")
            )
            return (
                HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: nil, headerFields: [
                    "Content-Type": "application/json",
                    "Content-Digest": fixture.headers.contentDigest,
                    "X-Resonance-Config-Signature": fixture.headers.signature,
                ])!,
                fixture.body
            )
        }
        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token

        defaults.set(9, forKey: "response-revision")
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.document?.revision == 9)
        let cacheKey = try #require(defaults.string(forKey: "scope-cache-key"))
        let revisionKey = try #require(defaults.string(forKey: "scope-revision-key"))
        #expect(defaults.integer(forKey: revisionKey) == 9)
        #expect(defaults.data(forKey: cacheKey) != nil)

        defaults.set(8, forKey: "response-revision")
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.source == .safeDefaults)
        #expect(defaults.integer(forKey: revisionKey) == 9)
        #expect(defaults.data(forKey: cacheKey) == nil)
        #expect(model.clientConfigMessage.contains("revision rolled back"))
    }

    @Test("generic file upload revalidates local-file mode immediately before PUT")
    func genericUploadRevalidatesAtRequestStart() async throws {
        let suite = "ClientFeatureFlagsUploadRequestStart.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-request-start-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 64).write(to: mediaURL, options: .atomic)
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: mediaURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        ClientConfigURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/client-config" {
                let requestNumber = defaults.integer(forKey: "config-request-count") + 1
                defaults.set(requestNumber, forKey: "config-request-count")
                let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
                let context = MacClientConfigContext(
                    origin: "https://music.example",
                    profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                    appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                    appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                    cohortKey: cohort,
                    cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                    tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
                )
                let fixture = try makeFixture(
                    context: context,
                    now: .now,
                    revision: 20 + requestNumber,
                    localFile: !defaults.bool(forKey: "revoke-local-file"),
                    reviewedMatch: true,
                    matcherMode: "review"
                )
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/json",
                        "Content-Digest": fixture.headers.contentDigest,
                        "X-Resonance-Config-Signature": fixture.headers.signature,
                    ])!,
                    fixture.body
                )
            }
            if url.path == "/api/v1/admin/songs", request.httpMethod == "PUT" {
                defaults.set(defaults.integer(forKey: "put-request-count") + 1, forKey: "put-request-count")
            }
            throw URLError(.unsupportedURL)
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        model.serverAdminToken = "admin-token"
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.allowsLocalFileUpload)
        #expect(model.uploadMode == .localFile)
        model.tracks = [Track(
            title: "Managed upload",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: mediaURL,
            remoteID: "missing-managed-upload",
            sourceServer: "https://music.example",
            syncProfileID: "default",
            downloadSourceURL: "https://media.example/managed-upload.m4a"
        )]
        let initialConfigRequestCount = defaults.integer(forKey: "config-request-count")
        defaults.set(true, forKey: "revoke-local-file")

        model.uploadMissingDownloadedSongs()
        for _ in 0..<200
        where defaults.integer(forKey: "config-request-count") <= initialConfigRequestCount
            || model.isUploadingServer {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(defaults.integer(forKey: "config-request-count") > initialConfigRequestCount)
        #expect(defaults.integer(forKey: "put-request-count") == 0)
        #expect(!model.clientConfiguration.allowsLocalFileUpload)
        #expect(model.uploadMode != .localFile)
        #expect(model.uploadStatus.contains("failed"))
    }

    @Test("committed generic upload responses are ignored after credential context changes")
    func genericUploadCompletionRequiresUnchangedContext() async throws {
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-context-change-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 64).write(to: mediaURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: mediaURL) }
        let song = #"{"id":"committed-id","filename":"Committed.m4a","title":"Committed","artist":"Artist","album":"Album","size":64,"modified_at":"now","content_type":"audio/mp4","download_url":"/api/v1/songs/committed-id/download","stream_url":"/api/v1/songs/committed-id/stream"}"#

        for status in [201, 409] {
            let suite = "ClientFeatureFlagsUploadContext.\(status).\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ClientConfigURLProtocol.self]
            let session = URLSession(configuration: configuration)
            ClientConfigURLProtocol.handler = { request in
                let url = try #require(request.url)
                if url.path == "/api/v1/client-config" {
                    return (
                        HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                if url.path == "/api/v1/admin/songs", request.httpMethod == "PUT" {
                    defaults.set(true, forKey: "put-started")
                    Thread.sleep(forTimeInterval: 0.2)
                    let body = status == 409 ? #"{"duplicate_of":\#(song)}"# : song
                    return (
                        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: [
                            "Content-Type": "application/json",
                        ])!,
                        Data(body.utf8)
                    )
                }
                throw URLError(.unsupportedURL)
            }
            let model = PlayerModel(
                loadPersistedLibrary: false,
                defaults: defaults,
                networkSession: session,
                persistServerCredentials: false,
                systemPlaybackController: nil
            )
            model.serverURLString = "https://music.example"
            model.serverToken = token
            model.serverAdminToken = "admin-token"
            model.tracks = [Track(
                title: "Committed",
                artist: "Artist",
                album: "Album",
                duration: 1,
                artwork: .liked,
                fileURL: mediaURL,
                remoteID: "missing-committed-id",
                sourceServer: "https://music.example",
                syncProfileID: "default",
                downloadSourceURL: "https://media.example/committed.m4a"
            )]

            model.uploadMissingDownloadedSongs()
            for _ in 0..<100 where !defaults.bool(forKey: "put-started") {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(defaults.bool(forKey: "put-started"))
            model.clearServerCredentials()
            for _ in 0..<600 where model.isUploadingServer {
                try await Task.sleep(for: .milliseconds(5))
            }

            #expect(model.remoteSongs.isEmpty)
            #expect(model.serverURLString.isEmpty)
            #expect(model.serverAdminToken.isEmpty)
            #expect(model.uploadStatus.contains("1 failed"))
            ClientConfigURLProtocol.handler = nil
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test("a committed upload reconciles after its signed lease expires")
    func committedUploadReconcilesAfterLeaseExpiry() async throws {
        let suite = "ClientFeatureFlagsCommittedUpload.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let mediaURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resonance-committed-upload-\(UUID().uuidString).m4a")
        try Data(repeating: 0x41, count: 64).write(to: mediaURL, options: .atomic)
        defer {
            ClientConfigURLProtocol.handler = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: mediaURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClientConfigURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        ClientConfigURLProtocol.handler = { request in
            let url = try #require(request.url)
            if url.path == "/api/v1/client-config" {
                let cohort = try #require(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"))
                let now = Date.now
                let context = MacClientConfigContext(
                    origin: "https://music.example",
                    profileID: request.value(forHTTPHeaderField: "X-Resonance-Profile") ?? "default",
                    appVersion: request.value(forHTTPHeaderField: "X-Resonance-App-Version") ?? "0.0.0",
                    appBuild: Int(request.value(forHTTPHeaderField: "X-Resonance-App-Build") ?? "") ?? 1,
                    cohortKey: cohort,
                    cohortBucket: MacClientConfigContext.cohortBucket(for: cohort),
                    tokenFingerprint: MacClientConfigContext.tokenFingerprint(self.token)
                )
                let fixture = try makeFixture(
                    context: context,
                    now: now,
                    issuedAt: now.addingTimeInterval(-0.1),
                    notBefore: now.addingTimeInterval(-0.1),
                    expiresAt: now.addingTimeInterval(0.25)
                )
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
                        "Content-Type": "application/json",
                        "Content-Digest": fixture.headers.contentDigest,
                        "X-Resonance-Config-Signature": fixture.headers.signature,
                    ])!,
                    fixture.body
                )
            }
            if url.path == "/api/v1/admin/songs", request.httpMethod == "PUT" {
                Thread.sleep(forTimeInterval: 0.45)
                let data = Data(#"{"id":"committed-id","filename":"Committed.m4a","title":"Committed","artist":"Artist","album":"Album","size":64,"modified_at":"now","content_type":"audio/mp4","download_url":"/api/v1/songs/committed-id/download","stream_url":"/api/v1/songs/committed-id/stream"}"#.utf8)
                return (
                    HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: [
                        "Content-Type": "application/json",
                    ])!,
                    data
                )
            }
            throw URLError(.unsupportedURL)
        }

        let model = PlayerModel(
            loadPersistedLibrary: false,
            defaults: defaults,
            networkSession: session,
            persistServerCredentials: false,
            systemPlaybackController: nil
        )
        model.serverURLString = "https://music.example"
        model.serverToken = token
        model.serverAdminToken = "admin-token"
        await model.refreshClientConfigurationNow()
        #expect(model.clientConfiguration.allowsLocalFileUpload)

        let track = Track(
            title: "Committed",
            artist: "Artist",
            album: "Album",
            duration: 1,
            artwork: .liked,
            fileURL: mediaURL,
            downloadSourceURL: "https://media.example/committed.m4a"
        )
        model.tracks = [track]
        let transfer = try model.beginLocalImportTransfer(reservingUpload: true)
        defer { model.endLocalImportTransfer(transfer) }

        #expect(try await model.uploadLocalImportToActiveProfile(track, context: transfer))
        #expect(model.clientConfiguration.source == .safeDefaults)
        #expect(model.tracks.first?.remoteID == "committed-id")
        #expect(model.remoteSongs.contains(where: { $0.id == "committed-id" }))
    }

    private func makeContext(
        profileID: String = "default",
        token: String = "fixture-access-token-v1"
    ) -> MacClientConfigContext {
        let cohortKey = "AAECAwQFBgcICQoLDA0ODw"
        return MacClientConfigContext(
            origin: "https://music.example",
            profileID: profileID,
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohortKey,
            cohortBucket: MacClientConfigContext.cohortBucket(for: cohortKey),
            tokenFingerprint: MacClientConfigContext.tokenFingerprint(token)
        )
    }

    private func makeFixture(
        context: MacClientConfigContext,
        now: Date,
        revision: Int = 7,
        issuedAt: Date? = nil,
        notBefore: Date? = nil,
        expiresAt: Date? = nil,
        localFile: Bool = true,
        sourceLink: Bool = true,
        reviewedMatch: Bool = false,
        matcherMode: String = "off",
        offlineMode: String = "verified_file_cache",
        playbackMode: String = "same_origin_resolver",
        storageReadMode: String = "r2_only",
        linkImportsKilled: Bool = false,
        allUploadsKilled: Bool = false
    ) throws -> (body: Data, headers: (contentDigest: String, signature: String)) {
        let formatter = ISO8601DateFormatter()
        let body = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "revision": revision,
            "issued_at": formatter.string(from: issuedAt ?? now.addingTimeInterval(-1)),
            "not_before": formatter.string(from: notBefore ?? now.addingTimeInterval(-1)),
            "expires_at": formatter.string(from: expiresAt ?? now.addingTimeInterval(600)),
            "audience": [
                "origin": context.origin,
                "profile_id": context.profileID,
                "platform": MacClientConfigContext.platform,
                "app_version": context.appVersion,
                "app_build": context.appBuild,
                "cohort_bucket": context.cohortBucket,
            ],
            "values": [
                "upload.local_file": localFile,
                "upload.server_source_link": sourceLink,
                "upload.reviewed_match": reviewedMatch,
                "upload.external_object": false,
                "download.offline_mode": offlineMode,
                "download.playback_mode": playbackMode,
                "matcher.mode": matcherMode,
                "storage.read_mode": storageReadMode,
                "storage.r2_reclaim": false,
            ],
            "kill_switches": [
                "all_uploads": allUploadsKilled,
                "link_imports": linkImportsKilled,
                "offline_downloads": false,
                "external_reads": true,
                "r2_reclaim": true,
            ],
        ], options: [.sortedKeys])
        let headers = MacClientConfigVerifier.signatureHeader(
            body: body,
            audience: context.audience,
            accessToken: token
        )
        return (body, headers)
    }
}
