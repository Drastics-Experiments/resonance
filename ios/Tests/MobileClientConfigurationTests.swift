import CryptoKit
import Foundation
import XCTest
@testable import Resonance

final class MobileClientConfigurationTests: XCTestCase {
    private let token = "test-access-token"
    private let cohortKey = "AAECAwQFBgcICQoLDA0ODw"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testVerifierAcceptsExactDigestSignatureAndAudience() throws {
        let signed = try signedResponse()
        let result = try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )

        XCTAssertEqual(result.payload.schemaVersion, 1)
        XCTAssertEqual(result.payload.audience, expectedAudience.audience)
        XCTAssertTrue(result.isUsable(at: now))
    }

    func testVerifierRejectsTamperingFutureSnapshotsAndInvalidOrdering() throws {
        let signed = try signedResponse()
        var tampered = signed.body
        tampered.append(0x20)
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: tampered,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .digestMismatch)
        }

        let future = try signedResponse(issuedAt: now.addingTimeInterval(1))
        XCTAssertThrowsError(try verify(future)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidTimeWindow)
        }

        let invalidOrder = try signedResponse(
            issuedAt: now.addingTimeInterval(-5),
            notBefore: now.addingTimeInterval(-10)
        )
        XCTAssertThrowsError(try verify(invalidOrder)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidTimeWindow)
        }
    }

    func testVerifierRequiresCanonicalStandardBase64Headers() throws {
        let signed = try signedResponse()
        let unpaddedDigest = signed.digest.replacingOccurrences(of: "=:", with: ":")
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: unpaddedDigest,
            signature: signed.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .malformedDigest)
        }

        let unpaddedSignature = signed.signature.replacingOccurrences(of: "=:", with: ":")
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: unpaddedSignature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .malformedSignature)
        }
    }

    func testVerifierRejectsExpiryAndWrongAudience() throws {
        let expired = try signedResponse(
            issuedAt: now.addingTimeInterval(-700),
            notBefore: now.addingTimeInterval(-700),
            expiresAt: now
        )
        XCTAssertThrowsError(try verify(expired)) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .expired)
        }

        let signed = try signedResponse()
        let wrong = MobileClientConfigExpectedAudience(
            origin: expectedAudience.origin,
            profileID: "other-profile",
            appVersion: expectedAudience.appVersion,
            appBuild: expectedAudience.appBuild,
            cohortKey: cohortKey
        )
        XCTAssertThrowsError(try MobileClientConfigVerifier.verify(
            body: signed.body,
            contentDigest: signed.digest,
            signature: signed.signature,
            accessToken: token,
            expected: wrong,
            now: now
        )) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .wrongAudience)
        }
    }

    func testVerifierRejectsNegativeRevisionAndNonpositiveBuild() throws {
        XCTAssertThrowsError(try verify(try signedResponse(revision: -1))) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidRevision)
        }
        XCTAssertThrowsError(try verify(try signedResponse(audienceAppBuild: 0))) { error in
            XCTAssertEqual(error as? MobileClientConfigVerificationError, .invalidAppBuild)
        }
    }

    func testSafeDefaultsAndDisabledPreferencesFailClosed() {
        let safe = MobileClientFeatureConfiguration.safeDefaults
        XCTAssertEqual(
            MobileTransferModePolicy.availableUploadModes(configuration: safe, at: now),
            [.localFile]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: safe, at: now),
            [.verifiedFileCache]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveUploadMode(
                preferred: .serverSourceLink,
                configuration: safe,
                at: now
            ),
            .localFile
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveDownloadMode(
                preferred: .streamOnly,
                configuration: safe,
                at: now
            ),
            .verifiedFileCache
        )
    }

    func testStreamOnlyPolicyDoesNotExposeOfflineCache() throws {
        let signed = try signedResponse(offlineMode: "stream_only")
        let verified = try verify(signed)
        let configuration = MobileClientFeatureConfiguration(verified: verified)

        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: configuration, at: now),
            [.streamOnly]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.effectiveDownloadMode(
                preferred: .verifiedFileCache,
                configuration: configuration,
                at: now
            ),
            .streamOnly
        )
    }

    func testReviewedMatchRequiresLocalFileAndDoesNotDependOnLinkImports() throws {
        let enabled = try verify(try signedResponse(
            localFile: true,
            reviewedMatch: true,
            matcherMode: "review",
            killLinkImports: true
        ))
        XCTAssertTrue(MobileTransferModePolicy.availableUploadModes(
            configuration: MobileClientFeatureConfiguration(verified: enabled),
            at: now
        ).contains(.reviewedMatch))

        let withoutLocalUpload = try verify(try signedResponse(
            localFile: false,
            reviewedMatch: true,
            matcherMode: "review"
        ))
        XCTAssertFalse(MobileTransferModePolicy.availableUploadModes(
            configuration: MobileClientFeatureConfiguration(verified: withoutLocalUpload),
            at: now
        ).contains(.reviewedMatch))
    }

    func testExpiredConfigurationFallsBackToSafeModes() throws {
        let signed = try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            sourceLink: true,
            offlineMode: "stream_only"
        )
        let configuration = MobileClientFeatureConfiguration(verified: try verify(signed))
        let afterExpiry = now.addingTimeInterval(11)

        XCTAssertEqual(
            MobileTransferModePolicy.availableUploadModes(configuration: configuration, at: afterExpiry),
            [.localFile]
        )
        XCTAssertEqual(
            MobileTransferModePolicy.availableDownloadModes(configuration: configuration, at: afterExpiry),
            [.verifiedFileCache]
        )
    }

    func testCacheScopeIncludesEveryRequiredBoundaryAndAge() {
        let base = MobileClientConfigCacheScope(
            origin: "https://music.example",
            profileID: "default",
            platform: "ios",
            appVersion: "1.1.4",
            appBuild: "15",
            tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint("one")
        )
        let variants = [
            MobileClientConfigCacheScope(origin: "https://other.example", profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "other", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "android", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.5", appBuild: "15", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "16", tokenFingerprint: base.tokenFingerprint),
            MobileClientConfigCacheScope(origin: base.origin, profileID: "default", platform: "ios", appVersion: "1.1.4", appBuild: "15", tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint("two")),
        ]
        XCTAssertTrue(variants.allSatisfy { $0.storageKey != base.storageKey })
        XCTAssertTrue(variants.allSatisfy { $0.highestRevisionKey != base.highestRevisionKey })

        let record = MobileClientConfigCacheRecord(
            body: Data(),
            contentDigest: "digest",
            signature: "signature",
            cachedAt: now
        )
        XCTAssertTrue(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(899)))
        XCTAssertFalse(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(901)))
        XCTAssertFalse(MobileClientConfigCachePolicy.isFresh(record, now: now.addingTimeInterval(-1)))
    }

    func testRevisionHighWatermarkRejectsReplayPerExactScope() {
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 7, highestVerified: nil))
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 7, highestVerified: 7))
        XCTAssertTrue(MobileClientConfigRevisionPolicy.accepts(candidate: 8, highestVerified: 7))
        XCTAssertFalse(MobileClientConfigRevisionPolicy.accepts(candidate: 6, highestVerified: 7))
        XCTAssertFalse(MobileClientConfigRevisionPolicy.accepts(candidate: -1, highestVerified: nil))
    }

    func testCohortKeysMustBeExactly128BitBase64URL() {
        XCTAssertTrue(MobileClientConfigCohort.isValidKey(cohortKey))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey("not a key"))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey("AAECAw"))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey(cohortKey + "=="))
        XCTAssertFalse(MobileClientConfigCohort.isValidKey(String(cohortKey.dropLast()) + "x"))
        XCTAssertEqual(MobileClientConfigCohort.bucket(for: cohortKey), expectedAudience.audience.cohortBucket)
    }

    func testHTTPDispositionOnlyUsesCacheForServerOutage() {
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 200, contentType: "application/json; charset=utf-8"),
            .verify
        )
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 503, contentType: "text/plain"),
            .useFreshCache
        )
        for status in [201, 302, 400, 404] {
            XCTAssertEqual(
                MobileClientConfigHTTPPolicy.disposition(status: status, contentType: "application/json"),
                .evictAndUseSafeDefaults
            )
        }
        XCTAssertEqual(
            MobileClientConfigHTTPPolicy.disposition(status: 200, contentType: "text/html"),
            .evictAndUseSafeDefaults
        )

        for code in [
            URLError.timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
        ] {
            XCTAssertTrue(MobileClientConfigTransportPolicy.mayUseFreshCache(
                for: URLError(code)
            ))
        }
        for code in [
            URLError.badServerResponse,
            .cancelled,
            .dataNotAllowed,
            .serverCertificateUntrusted,
            .cannotDecodeContentData,
        ] {
            XCTAssertFalse(MobileClientConfigTransportPolicy.mayUseFreshCache(
                for: URLError(code)
            ))
        }
        XCTAssertFalse(MobileClientConfigTransportPolicy.mayUseFreshCache(
            for: MobileClientConfigVerificationError.unsupportedSchema
        ))
    }

    func testBoundedResponsesAndSameOriginPolicyFailClosed() {
        XCTAssertTrue(MobileBoundedResponsePolicy.accepts(currentCount: 9, adding: 1, maximum: 10))
        XCTAssertFalse(MobileBoundedResponsePolicy.accepts(currentCount: 10, adding: 1, maximum: 10))
        XCTAssertFalse(MobileBoundedResponsePolicy.accepts(currentCount: Int.max, adding: 1, maximum: Int.max))

        XCTAssertTrue(MobileSameOriginPolicy.matches(
            URL(string: "https://MUSIC.example/file"),
            URL(string: "https://music.example:443/root")
        ))
        XCTAssertFalse(MobileSameOriginPolicy.matches(
            URL(string: "https://cdn.example/file"),
            URL(string: "https://music.example/root")
        ))
        XCTAssertFalse(MobileSameOriginPolicy.matches(
            URL(string: "https://music.example:8443/file"),
            URL(string: "https://music.example/root")
        ))
    }

    func testSourceImportPreservesOnlyCanonicalUserEnteredYouTubePage() {
        let original = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        XCTAssertEqual(MobileSourcePagePolicy.validatedOriginalYouTubePage("  \(original)\n"), original)
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"))
        XCTAssertNil(MobileSourcePagePolicy.validatedOriginalYouTubePage("https://www.youtube.com/embed/dQw4w9WgXcQ"))
    }

    func testRequestContextAppliesEveryRequiredHeader() {
        let context = MobileClientRequestContext(
            profileID: "default",
            platform: "ios",
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohortKey
        )
        var request = URLRequest(url: URL(string: "https://music.example/api/v1/admin/debrid/resolve")!)
        context.apply(to: &request)

        XCTAssertTrue(context.isComplete)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Profile"), "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Client-Platform"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-App-Version"), "1.1.4")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-App-Build"), "15")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Cohort-Key"), cohortKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Resonance-Config-Protocol"), "1")
    }

    func testTransferLeaseRejectsExpiryRevisionAndPreferenceChanges() throws {
        let first = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            offlineMode: "stream_only"
        )))
        let lease = try XCTUnwrap(MobileTransferPolicyLeasePolicy.captureDownload(
            .streamOnly,
            configuration: first,
            preferredMode: .streamOnly,
            at: now
        ))
        XCTAssertTrue(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        let renewed = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(20),
            offlineMode: "stream_only"
        )))
        XCTAssertTrue(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: renewed,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now.addingTimeInterval(10)
        ))

        let next = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10),
            offlineMode: "stream_only",
            revision: 8
        )))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: next,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .streamOnly,
            at: now
        ))
        XCTAssertFalse(MobileTransferPolicyLeasePolicy.isCurrent(
            lease,
            configuration: first,
            preferredUploadMode: .localFile,
            preferredDownloadMode: .verifiedFileCache,
            at: now
        ))
    }

    func testRefreshRunsBeforeExpiryAndTransientOwnershipIsNarrow() {
        XCTAssertEqual(
            MobileClientConfigRefreshPolicy.delay(
                until: now.addingTimeInterval(600),
                now: now
            ),
            540
        )
        XCTAssertEqual(
            MobileClientConfigRefreshPolicy.delay(
                until: now.addingTimeInterval(100),
                now: now
            ),
            50
        )
        XCTAssertNil(MobileClientConfigRefreshPolicy.delay(until: now, now: now))
        XCTAssertTrue(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/resonance-download-123")
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/resonance-download")
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.owns(
            URL(fileURLWithPath: "/tmp/other-resonance-download-123")
        ))
        XCTAssertTrue(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-download-123"),
            isRegularFile: true,
            isDirectory: false,
            isSymbolicLink: false
        ))
        XCTAssertTrue(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-import-123"),
            isRegularFile: false,
            isDirectory: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileTransientDownloadPolicy.ownsTemporaryEntry(
            URL(fileURLWithPath: "/tmp/resonance-import-123"),
            isRegularFile: false,
            isDirectory: true,
            isSymbolicLink: true
        ))

        let staging = URL(fileURLWithPath: "/app/LikedSongsMobile/LocalImports", isDirectory: true)
        XCTAssertTrue(MobileLocalImportStagingPolicy.ownsStagedFile(
            staging.appendingPathComponent("finished.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileLocalImportStagingPolicy.ownsStagedFile(
            URL(fileURLWithPath: "/app/LikedSongsMobile/Music/finished.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: false
        ))
        XCTAssertFalse(MobileLocalImportStagingPolicy.ownsStagedFile(
            staging.appendingPathComponent("link.m4a"),
            stagingDirectory: staging,
            isRegularFile: true,
            isSymbolicLink: true
        ))
    }

    func testOwnedTransferArtifactCleanerOnlyRemovesExactCrashArtifacts() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("resonance-cleaner-test-\(UUID().uuidString)", isDirectory: true)
        let temporaryDirectory = testRoot.appendingPathComponent("tmp", isDirectory: true)
        let supportDirectory = testRoot.appendingPathComponent("LikedSongsMobile", isDirectory: true)
        let stagingDirectory = supportDirectory.appendingPathComponent("LocalImports", isDirectory: true)
        let musicDirectory = supportDirectory.appendingPathComponent("Music", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: musicDirectory, withIntermediateDirectories: true)

        let ownedDownload = temporaryDirectory.appendingPathComponent("resonance-download-abandoned")
        let ownedImport = temporaryDirectory.appendingPathComponent("resonance-import-abandoned", isDirectory: true)
        let unrelatedTemporaryFile = temporaryDirectory.appendingPathComponent("unrelated-audio.m4a")
        let wrongDownloadType = temporaryDirectory.appendingPathComponent("resonance-download-directory", isDirectory: true)
        let wrongImportType = temporaryDirectory.appendingPathComponent("resonance-import-file")
        let ownedNameSymlink = temporaryDirectory.appendingPathComponent("resonance-download-link")

        try Data("download".utf8).write(to: ownedDownload)
        try fileManager.createDirectory(at: ownedImport, withIntermediateDirectories: false)
        try Data("unrelated".utf8).write(to: unrelatedTemporaryFile)
        try fileManager.createDirectory(at: wrongDownloadType, withIntermediateDirectories: false)
        try Data("wrong type".utf8).write(to: wrongImportType)
        try fileManager.createSymbolicLink(
            at: ownedNameSymlink,
            withDestinationURL: unrelatedTemporaryFile
        )

        let stagedFile = stagingDirectory.appendingPathComponent("finished.m4a")
        let hiddenStagedFile = stagingDirectory.appendingPathComponent(".unfinished.m4a")
        let stagedDirectory = stagingDirectory.appendingPathComponent("nested", isDirectory: true)
        let stagedNestedFile = stagedDirectory.appendingPathComponent("keep.m4a")
        let musicFile = musicDirectory.appendingPathComponent("library-track.m4a")
        try Data("staged".utf8).write(to: stagedFile)
        try Data("hidden".utf8).write(to: hiddenStagedFile)
        try fileManager.createDirectory(at: stagedDirectory, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: stagedNestedFile)
        try Data("music".utf8).write(to: musicFile)

        MobileOwnedTransferArtifactCleaner.removeOrphans(
            temporaryDirectory: temporaryDirectory,
            stagingDirectory: stagingDirectory,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: ownedDownload.path))
        XCTAssertFalse(fileManager.fileExists(atPath: ownedImport.path))
        XCTAssertFalse(fileManager.fileExists(atPath: stagedFile.path))
        XCTAssertFalse(fileManager.fileExists(atPath: hiddenStagedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTemporaryFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongDownloadType.path))
        XCTAssertTrue(fileManager.fileExists(atPath: wrongImportType.path))
        XCTAssertTrue(fileManager.fileExists(atPath: ownedNameSymlink.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedDirectory.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedNestedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: musicFile.path))
    }

    func testBoundedDownloadRevocationStopsInFlightAndRemovesTemporaryFile() async throws {
        let firstChunk = expectation(description: "first chunk received")
        let stopped = expectation(description: "protocol stopped")
        MobileChunkedDownloadProtocol.state.configure(
            onFirstChunk: { firstChunk.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let authorization = MobileTransferAuthorization(expiresAt: nil)
        let operation = try MobileBoundedDownloadOperation(
            maximumSize: 1_024,
            authorization: authorization,
            sessionConfiguration: chunkedSessionConfiguration()
        )
        let task = Task {
            try await operation.run(request: URLRequest(url: URL(string: "https://music.example/audio")!))
        }

        await fulfillment(of: [firstChunk], timeout: 2)
        authorization.revoke()
        do {
            _ = try await task.value
            XCTFail("A revoked transfer must not complete")
        } catch {
            XCTAssertTrue(error is MobileTransferPolicyChangedError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(MobileChunkedDownloadProtocol.state.secondChunkWasDelivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.temporaryURL.path))
    }

    func testBoundedDownloadExpiryStopsInFlightAndRemovesTemporaryFile() async throws {
        let firstChunk = expectation(description: "first chunk received")
        let stopped = expectation(description: "protocol stopped")
        MobileChunkedDownloadProtocol.state.configure(
            onFirstChunk: { firstChunk.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let authorization = MobileTransferAuthorization(
            expiresAt: Date().addingTimeInterval(0.1)
        )
        let operation = try MobileBoundedDownloadOperation(
            maximumSize: 1_024,
            authorization: authorization,
            sessionConfiguration: chunkedSessionConfiguration()
        )
        let task = Task {
            try await operation.run(request: URLRequest(url: URL(string: "https://music.example/audio")!))
        }

        await fulfillment(of: [firstChunk], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("An expired transfer must not complete")
        } catch {
            XCTAssertTrue(error is MobileTransferPolicyChangedError)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(MobileChunkedDownloadProtocol.state.secondChunkWasDelivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operation.temporaryURL.path))
    }

    func testCommittedReviewedUploadReconcilesAfterLeaseExpiryOnlyInSameContext() {
        XCTAssertTrue(MobileReviewedUploadCompletionPolicy.shouldReconcileCommittedResponse(
            requestContextCurrent: true,
            leaseStillCurrent: false
        ))
        XCTAssertFalse(MobileReviewedUploadCompletionPolicy.shouldReconcileCommittedResponse(
            requestContextCurrent: false,
            leaseStillCurrent: true
        ))
    }

    func testQueuedRawUploadRevalidatesExpiredLeaseAfterSerialGate() async throws {
        let configuration = MobileClientFeatureConfiguration(verified: try verify(try signedResponse(
            expiresAt: now.addingTimeInterval(10)
        )))
        let lease = try XCTUnwrap(MobileTransferPolicyLeasePolicy.captureUpload(
            .localFile,
            configuration: configuration,
            preferredMode: .localFile,
            at: now
        ))
        let gate = MobileAsyncSerialGate()
        await gate.acquire()

        let queuedUpload = Task {
            await gate.acquire()
            await gate.release()
            return MobileTransferPolicyLeasePolicy.isCurrent(
                lease,
                configuration: configuration,
                preferredUploadMode: .localFile,
                preferredDownloadMode: .verifiedFileCache,
                at: now.addingTimeInterval(11)
            )
        }
        await Task.yield()
        await gate.release()

        let canStartRequest = await queuedUpload.value
        XCTAssertFalse(canStartRequest)
    }

    func testAuthenticatedStreamBuildsExactBoundedRangeRequest() throws {
        let source = try XCTUnwrap(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let assetURL = try MobileAuthenticatedStreamPolicy.assetURL(for: source)
        XCTAssertEqual(assetURL.scheme, "resonance-authenticated-stream")
        XCTAssertEqual(assetURL.host, source.host)
        XCTAssertEqual(assetURL.path, source.path)
        XCTAssertFalse(assetURL.absoluteString.contains(token))

        let plan = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [
                "Authorization": "Bearer \(token)",
                "X-Resonance-Profile": "default",
            ],
            offset: 100,
            requestedLength: 200,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        XCTAssertEqual(plan.offset, 100)
        XCTAssertEqual(plan.end, 299)
        XCTAssertEqual(plan.responseLength, 200)
        XCTAssertEqual(plan.request.url, source)
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Range"), "bytes=100-299")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(plan.request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")

        let clamped = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [:],
            offset: 900,
            requestedLength: 500,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        XCTAssertEqual(clamped.request.value(forHTTPHeaderField: "Range"), "bytes=900-999")
        XCTAssertEqual(clamped.responseLength, 100)
    }

    func testAuthenticatedStreamRequiresExactCoherent206Response() throws {
        let source = try XCTUnwrap(URL(string: "https://music.example/api/v1/songs/song-1/stream"))
        let plan = try MobileAuthenticatedStreamPolicy.requestPlan(
            sourceURL: source,
            headers: [:],
            offset: 100,
            requestedLength: 200,
            requestsAllDataToEnd: false,
            expectedContentLength: 1_000
        )
        let valid = try XCTUnwrap(HTTPURLResponse(
            url: source,
            statusCode: 206,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "audio/mp4",
                "Content-Length": "200",
                "Content-Range": "bytes 100-299/1000",
            ]
        ))
        let metadata = try MobileAuthenticatedStreamPolicy.validate(
            response: valid,
            sourceURL: source,
            requestPlan: plan,
            expectedContentLength: 1_000,
            expectedContentType: "audio/mp4"
        )
        XCTAssertEqual(metadata.contentLength, 1_000)
        XCTAssertEqual(metadata.responseLength, 200)
        XCTAssertTrue(metadata.supportsByteRanges)

        let invalidResponses: [(HTTPURLResponse, MobileAuthenticatedStreamError)] = [
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 200,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "199",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 0-199/1000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/2000",
                ]
            )), .invalidRange),
            (try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "video/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .unsupportedContentType),
            (try XCTUnwrap(HTTPURLResponse(
                url: URL(string: "https://objects.example/song.m4a")!,
                statusCode: 206,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "audio/mp4",
                    "Content-Length": "200",
                    "Content-Range": "bytes 100-299/1000",
                ]
            )), .crossOriginResponse),
        ]
        for (response, expectedError) in invalidResponses {
            XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validate(
                response: response,
                sourceURL: source,
                requestPlan: plan,
                expectedContentLength: 1_000,
                expectedContentType: "audio/mp4"
            )) { error in
                XCTAssertEqual(error as? MobileAuthenticatedStreamError, expectedError)
            }
        }
    }

    func testAuthenticatedStreamPinsCatalogDescriptorToAudioObject() throws {
        let hash = String(repeating: "a", count: 64)
        XCTAssertEqual(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4; charset=binary",
            locationLength: 1_000,
            locationSHA256: hash.uppercased(),
            locationContentType: "audio/mp4",
            supportsRanges: true,
            state: "active"
        ), "audio/mp4")

        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4",
            locationLength: 999,
            locationSHA256: hash,
            locationContentType: "audio/mp4",
            supportsRanges: true,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .resourceMismatch)
        }
        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "audio/mp4",
            locationLength: 1_000,
            locationSHA256: hash,
            locationContentType: "audio/mp4",
            supportsRanges: false,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .resourceMismatch)
        }
        XCTAssertThrowsError(try MobileAuthenticatedStreamPolicy.validateDescriptor(
            catalogLength: 1_000,
            catalogSHA256: hash,
            catalogContentType: "video/mp4",
            locationLength: 1_000,
            locationSHA256: hash,
            locationContentType: "video/mp4",
            supportsRanges: true,
            state: "active"
        )) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .unsupportedContentType)
        }
    }

    func testAuthenticatedStreamSessionCannotPersistMediaOrCredentials() {
        let session = MobileAuthenticatedStreamSession.makeEphemeral()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(
            session.configuration.requestCachePolicy,
            .reloadIgnoringLocalAndRemoteCacheData
        )
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.urlCredentialStorage)
    }

    func testAuthenticatedStreamLeaseAdoptsEarlierEqualAndLaterExpiryInExactContext() throws {
        let context = authenticatedStreamContext(profileID: "default")
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now
        )
        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(30))
        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(60),
            now: now.addingTimeInterval(2)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(60))

        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: now.addingTimeInterval(50),
            now: now.addingTimeInterval(3)
        ))
        XCTAssertEqual(lease.expiration, now.addingTimeInterval(50))
        XCTAssertNoThrow(try lease.authorize(at: now.addingTimeInterval(49)))
        XCTAssertThrowsError(try lease.authorize(at: now.addingTimeInterval(50))) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }

        let changedContext = authenticatedStreamContext(profileID: "other")
        let changedContextLease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: now.addingTimeInterval(30),
            now: now
        )
        XCTAssertFalse(changedContextLease.renew(
            context: changedContext,
            expiresAt: now.addingTimeInterval(90),
            now: now.addingTimeInterval(2)
        ))
        XCTAssertThrowsError(try changedContextLease.authorize(at: now.addingTimeInterval(3))) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testAuthenticatedStreamLeaseEarlierExpiryReschedulesInvalidation() async throws {
        let invalidated = expectation(description: "shortened stream lease invalidated")
        let context = authenticatedStreamContext(profileID: "default")
        let startedAt = Date.now
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: context,
            expiresAt: startedAt.addingTimeInterval(2),
            now: startedAt
        )
        lease.setInvalidationHandler { invalidated.fulfill() }

        XCTAssertTrue(lease.renew(
            context: context,
            expiresAt: startedAt.addingTimeInterval(0.05),
            now: startedAt.addingTimeInterval(0.01)
        ))
        XCTAssertEqual(lease.expiration, startedAt.addingTimeInterval(0.05))

        await fulfillment(of: [invalidated], timeout: 1)
        XCTAssertThrowsError(try lease.authorize()) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testAuthenticatedStreamLeaseExpiryInvalidatesInFlightWork() async throws {
        let invalidated = expectation(description: "stream work invalidated")
        let lease = try MobileAuthenticatedStreamAuthorizationLease(
            context: authenticatedStreamContext(profileID: "default"),
            expiresAt: Date.now.addingTimeInterval(0.05)
        )
        lease.setInvalidationHandler { invalidated.fulfill() }

        await fulfillment(of: [invalidated], timeout: 2)
        XCTAssertThrowsError(try lease.authorize()) { error in
            XCTAssertEqual(error as? MobileAuthenticatedStreamError, .authorizationExpired)
        }
    }

    func testReviewedMatchResponseOnlyExposesExplicitReviewCandidates() throws {
        let object: [String: Any] = [
            "provider": "spotify",
            "type": "track",
            "source": "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
            "track_id": "4uLU6hMCjMI75M1A2tKUQC",
            "title": "Track",
            "artist": "Artist",
            "duration_seconds": 180,
            "review_candidates": [
                reviewedCandidate(videoID: "reviewme001", requiresReview: true, autoSelectable: false),
                reviewedCandidate(videoID: "donotuse001", requiresReview: false, autoSelectable: true),
                reviewedCandidate(
                    videoID: "preauth0001",
                    requiresReview: true,
                    autoSelectable: false,
                    actionable: true
                ),
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        let resolution = try JSONDecoder().decode(MobileReviewedMatchResponse.self, from: data)
            .reviewedResolution()

        XCTAssertEqual(resolution.candidates.map(\.videoID), ["reviewme001"])
        XCTAssertEqual(resolution.track.sourceURL, "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC")
    }

    func testReviewedYouTubeRequiresAndConsumesOneExplicitSafeCandidate() throws {
        let videoID = "reviewme001"
        let object: [String: Any] = [
            "provider": "youtube",
            "type": "video",
            "source": "https://www.youtube.com/watch?v=\(videoID)",
            "video_id": videoID,
            "title": "Candidate \(videoID)",
            "author": "Uploader",
            "duration_seconds": 180,
            "review_candidates": [
                reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false),
            ],
        ]
        let resolution = try decodeReviewedResolution(object)
        XCTAssertEqual(resolution.kind, .youtube)
        XCTAssertEqual(resolution.track.sourceURL, "https://www.youtube.com/watch?v=\(videoID)")
        XCTAssertEqual(resolution.candidates.count, 1)
        XCTAssertEqual(resolution.candidates.first?.videoID, videoID)

        var missingCandidate = object
        missingCandidate.removeValue(forKey: "review_candidates")
        XCTAssertThrowsError(try decodeReviewedResolution(missingCandidate)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }

        for unsafeCandidate in [
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false, actionable: true),
            reviewedCandidate(videoID: videoID, requiresReview: false, autoSelectable: false),
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: true),
        ] {
            var unsafe = object
            unsafe["review_candidates"] = [unsafeCandidate]
            XCTAssertThrowsError(try decodeReviewedResolution(unsafe)) { error in
                XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
            }
        }

        var multiple = object
        multiple["review_candidates"] = [
            reviewedCandidate(videoID: videoID, requiresReview: true, autoSelectable: false),
            reviewedCandidate(videoID: "reviewme002", requiresReview: true, autoSelectable: false),
        ]
        XCTAssertThrowsError(try decodeReviewedResolution(multiple)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }

        var mismatchedTopLevelSource = object
        mismatchedTopLevelSource["source"] = "https://www.youtube.com/watch?v=reviewme002"
        XCTAssertThrowsError(try decodeReviewedResolution(mismatchedTopLevelSource)) { error in
            XCTAssertEqual(error as? MobileReviewedMatchResponseError, .invalidResponse)
        }
    }

    func testEditedImportSourceInvalidatesPreviouslyResolvedIdentity() {
        let resolved = "https://www.youtube.com/watch?v=reviewme001"
        XCTAssertTrue(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: resolved,
            displayedInput: resolved
        ))
        XCTAssertFalse(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: resolved,
            displayedInput: "https://www.youtube.com/watch?v=reviewme002"
        ))
        XCTAssertFalse(LocalImportSourceIdentityPolicy.isCurrent(
            resolvedInput: nil,
            displayedInput: resolved
        ))
    }

    func testClipPlaybackPolicyKeepsStreamingInsideConfiguredBounds() {
        let bounds = MobileClipPlaybackPolicy.bounds(
            range: MobileClipRange(startSeconds: 30, endSeconds: 90),
            duration: 180
        )
        XCTAssertEqual(bounds, .init(start: 30, end: 90))
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 0, within: bounds), 30)
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 0.5, within: bounds), 60)
        XCTAssertEqual(MobileClipPlaybackPolicy.position(fraction: 1, within: bounds), 90)
        XCTAssertTrue(MobileClipPlaybackPolicy.reachedEnd(position: 89.99, bounds: bounds))
        XCTAssertFalse(MobileClipPlaybackPolicy.reachedEnd(position: 89.9, bounds: bounds))
        XCTAssertFalse(MobileClipPlaybackPolicy.reachedEnd(
            position: 0,
            bounds: .init(start: 0, end: 0)
        ))

        XCTAssertEqual(
            MobileClipPlaybackPolicy.bounds(
                range: MobileClipRange(startSeconds: 30, endSeconds: 30.1),
                duration: 180
            ),
            .init(start: 0, end: 180)
        )
    }

    private var expectedAudience: MobileClientConfigExpectedAudience {
        MobileClientConfigExpectedAudience(
            origin: "https://music.example",
            profileID: "default",
            appVersion: "1.1.4",
            appBuild: 15,
            cohortKey: cohortKey
        )
    }

    private func verify(_ response: SignedResponse) throws -> MobileVerifiedClientConfiguration {
        try MobileClientConfigVerifier.verify(
            body: response.body,
            contentDigest: response.digest,
            signature: response.signature,
            accessToken: token,
            expected: expectedAudience,
            now: now
        )
    }

    private func signedResponse(
        issuedAt: Date? = nil,
        notBefore: Date? = nil,
        expiresAt: Date? = nil,
        localFile: Bool = true,
        sourceLink: Bool = false,
        reviewedMatch: Bool = false,
        matcherMode: String = "off",
        offlineMode: String = "verified_file_cache",
        killLinkImports: Bool = false,
        revision: Int = 7,
        audienceAppBuild: Int? = nil
    ) throws -> SignedResponse {
        let issuedAt = issuedAt ?? now.addingTimeInterval(-10)
        let notBefore = notBefore ?? now.addingTimeInterval(-5)
        let expiresAt = expiresAt ?? now.addingTimeInterval(600)
        let audience = expectedAudience.audience
        let signedAppBuild = audienceAppBuild ?? audience.appBuild
        let object: [String: Any] = [
            "schema_version": 1,
            "revision": revision,
            "issued_at": iso8601(issuedAt),
            "not_before": iso8601(notBefore),
            "expires_at": iso8601(expiresAt),
            "audience": [
                "origin": audience.origin,
                "profile_id": audience.profileID,
                "platform": audience.platform,
                "app_version": audience.appVersion,
                "app_build": signedAppBuild,
                "cohort_bucket": audience.cohortBucket,
            ],
            "values": [
                "upload.local_file": localFile,
                "upload.server_source_link": sourceLink,
                "upload.reviewed_match": reviewedMatch,
                "upload.external_object": false,
                "download.offline_mode": offlineMode,
                "download.playback_mode": "same_origin_resolver",
                "matcher.mode": matcherMode,
                "storage.read_mode": "r2_only",
                "storage.r2_reclaim": false,
            ],
            "kill_switches": [
                "all_uploads": false,
                "link_imports": killLinkImports,
                "offline_downloads": false,
                "external_reads": true,
                "r2_reclaim": true,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let digest = "sha-256=:\(Data(SHA256.hash(data: body)).base64EncodedString()):"
        let signingInput = [
            "resonance-client-config-v1",
            audience.origin,
            audience.profileID,
            audience.platform,
            String(signedAppBuild),
            digest,
        ].joined(separator: "\n")
        let signatureBytes = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(token.utf8))
        )
        let signature = "v1=:\(Data(signatureBytes).base64EncodedString()):"
        return SignedResponse(body: body, digest: digest, signature: signature)
    }

    private func reviewedCandidate(
        videoID: String,
        requiresReview: Bool,
        autoSelectable: Bool,
        actionable: Bool = false
    ) -> [String: Any] {
        [
            "provider": "youtube",
            "source_url": "https://www.youtube.com/watch?v=\(videoID)",
            "video_id": videoID,
            "title": "Candidate \(videoID)",
            "artist": "Uploader",
            "duration_seconds": 180,
            "score": 0.9,
            "confidence": "review",
            "actionable": actionable,
            "requires_review": requiresReview,
            "auto_selectable": autoSelectable,
            "match": [
                "title": 0.9,
                "artist": 0.8,
                "duration": 1.0,
                "duration_delta_seconds": 0,
            ],
        ]
    }

    private func decodeReviewedResolution(_ object: [String: Any]) throws -> LocalImportResolution {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MobileReviewedMatchResponse.self, from: data)
            .reviewedResolution()
    }

    private func authenticatedStreamContext(profileID: String) -> MobileAuthenticatedStreamLeaseContext {
        MobileAuthenticatedStreamLeaseContext(
            origin: "https://music.example:443",
            requestContext: MobileClientRequestContext(
                profileID: profileID,
                platform: "ios",
                appVersion: "1.1.4",
                appBuild: 15,
                cohortKey: cohortKey
            ),
            tokenFingerprint: MobileClientConfigCacheScope.tokenFingerprint(token)
        )
    }

    private func chunkedSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileChunkedDownloadProtocol.self]
        return configuration
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SignedResponse {
    let body: Data
    let digest: String
    let signature: String
}

private final class MobileChunkedDownloadProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var onFirstChunk: (() -> Void)?
    private var onStop: (() -> Void)?
    private var deliveredSecondChunk = false

    var secondChunkWasDelivered: Bool {
        lock.lock()
        let result = deliveredSecondChunk
        lock.unlock()
        return result
    }

    func configure(onFirstChunk: @escaping () -> Void, onStop: @escaping () -> Void) {
        lock.lock()
        self.onFirstChunk = onFirstChunk
        self.onStop = onStop
        deliveredSecondChunk = false
        lock.unlock()
    }

    func didSendFirstChunk() {
        lock.lock()
        let callback = onFirstChunk
        lock.unlock()
        callback?()
    }

    func didSendSecondChunk() {
        lock.lock()
        deliveredSecondChunk = true
        lock.unlock()
    }

    func didStop() {
        lock.lock()
        let callback = onStop
        onFirstChunk = nil
        onStop = nil
        lock.unlock()
        callback?()
    }
}

private final class MobileChunkedDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let state = MobileChunkedDownloadProtocolState()

    private let lifecycleLock = NSLock()
    private var stopped = false
    private var delayedChunk: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "8", "Content-Type": "audio/mp4"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("aaaa".utf8))
        Self.state.didSendFirstChunk()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lifecycleLock.lock()
            let shouldDeliver = !self.stopped
            self.lifecycleLock.unlock()
            guard shouldDeliver else { return }
            Self.state.didSendSecondChunk()
            self.client?.urlProtocol(self, didLoad: Data("bbbb".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        lifecycleLock.lock()
        delayedChunk = work
        lifecycleLock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    override func stopLoading() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        let delayedChunk = delayedChunk
        self.delayedChunk = nil
        lifecycleLock.unlock()
        delayedChunk?.cancel()
        Self.state.didStop()
    }
}
