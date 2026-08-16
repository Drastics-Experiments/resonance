import Foundation
import XCTest
@testable import Resonance

private final class BoundedResponseURLProtocol: URLProtocol {
    static var body = Data()
    static var contentType = "application/json"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: [
                "Content-Length": String(Self.body.count),
                "Content-Type": Self.contentType,
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MacSecurityTests: XCTestCase {
    override func tearDown() {
        BoundedResponseURLProtocol.body = Data()
        BoundedResponseURLProtocol.contentType = "application/json"
        super.tearDown()
    }

    func testBoundedResponseRejectsAnOversizedStreamingBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        BoundedResponseURLProtocol.body = Data(repeating: 0x41, count: 1_025)

        let request = URLRequest(url: URL(string: "https://api.example.test/document")!)
        do {
            _ = try await MacBoundedResponse.data(for: session, request: request, limit: 1_024)
            XCTFail("an oversized response must not reach a decoder")
        } catch MacBoundedResponseError.responseTooLarge {
            // Expected.
        }
    }

    func testArtworkURLPolicyAllowsProviderAndConfiguredServerOriginsOnly() {
        XCTAssertNotNil(MacArtworkURLPolicy.allowedURL(URL(string: "https://i.ytimg.com/vi/example/hq.jpg")!))
        XCTAssertNotNil(MacArtworkURLPolicy.allowedURL(
            URL(string: "https://music.example.test/artwork/track.jpg")!,
            serverOrigin: URL(string: "https://music.example.test")!
        ))
        XCTAssertNil(MacArtworkURLPolicy.allowedURL(URL(string: "https://ytimg.com.evil.test/image.jpg")!))
        XCTAssertNil(MacArtworkURLPolicy.allowedURL(URL(string: "https://127.0.0.1/image.jpg")!))
        XCTAssertNil(MacArtworkURLPolicy.allowedURL(URL(string: "https://[::ffff:127.0.0.1]/image.jpg")!))
        XCTAssertNil(MacArtworkURLPolicy.allowedURL(URL(string: "https://localhost/image.jpg")!))
        XCTAssertNil(MacArtworkURLPolicy.allowedURL(
            URL(string: "https://other.example.test/artwork/track.jpg")!,
            serverOrigin: URL(string: "https://music.example.test")!
        ))
    }

    func testProfileImagePolicyAllowsPublicHTTPSAndRejectsUnsafeCandidates() {
        XCTAssertNotNil(MacArtworkURLPolicy.allowedPublicURL(
            URL(string: "https://img.clerk.com/avatar.png")!
        ))
        let rejected = [
            "http://img.clerk.com/avatar.png",
            "https://user:password@img.clerk.com/avatar.png",
            "https://img.clerk.com/avatar.png#fragment",
            "https://127.0.0.1/avatar.png",
            "https://localhost/avatar.png",
            "https://img.clerk.com:8443/avatar.png",
            "https://img.clerk.com/" + String(repeating: "x", count: 8_200),
        ]
        for value in rejected {
            XCTAssertNil(
                URL(string: value).flatMap(MacArtworkURLPolicy.allowedPublicURL),
                "profile image URL should be rejected: \(value.prefix(80))"
            )
        }
    }

    func testDecodedAccountSessionDropsAnUnsafeProfileImageURL() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "expiresAt": Date().timeIntervalSinceReferenceDate,
            "email": "member@example.test",
            "role": "member",
            "baseURL": "https://music.example.test",
            "accountID": "account-1",
            "profileID": "account-1",
            "displayName": "Member",
            "imageURL": "https://127.0.0.1/avatar.png",
        ])
        let session = try JSONDecoder().decode(ResonanceAccountSession.self, from: data)
        XCTAssertNil(session.imageURL)

        let safe = ResonanceAccountSession(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: .now,
            email: "member@example.test",
            role: "member",
            baseURL: URL(string: "https://music.example.test")!,
            accountID: "account-1",
            profileID: "account-1",
            displayName: "Member",
            imageURL: URL(string: "https://img.clerk.com/avatar.png")
        )
        XCTAssertEqual(safe.imageURL?.host, "img.clerk.com")
    }

    func testArtworkPixelBoundsRejectDecompressionBombDimensions() {
        XCTAssertTrue(MacArtworkURLPolicy.isWithinDecodedPixelBounds(width: 4_096, height: 4_096))
        XCTAssertFalse(MacArtworkURLPolicy.isWithinDecodedPixelBounds(width: 4_097, height: 1))
        XCTAssertFalse(MacArtworkURLPolicy.isWithinDecodedPixelBounds(width: 4_096, height: 4_097))
        XCTAssertFalse(MacArtworkURLPolicy.isWithinDecodedPixelBounds(width: 16_777_217, height: 1))
    }

    func testProviderMediaURLsAreRemovedOnlyFromDurableValues() throws {
        XCTAssertNil(MacPersistentMediaURLPolicy.persistentString(
            "https://rr1.example.googlevideo.com/videoplayback?expire=1"
        ))
        XCTAssertNil(MacPersistentMediaURLPolicy.persistentString("https://p.scdn.co/stream/temporary"))
        XCTAssertEqual(
            MacPersistentMediaURLPolicy.persistentString("https://www.youtube.com/watch?v=video123"),
            "https://www.youtube.com/watch?v=video123"
        )
        XCTAssertEqual(
            MacPersistentMediaURLPolicy.persistentString("https://music.example.test/api/v1/songs/1"),
            "https://music.example.test/api/v1/songs/1"
        )

        let payload = try JSONSerialization.data(withJSONObject: [
            "source_url": "https://www.youtube.com/watch?v=video123",
            "download_source_url": "https://rr1.example.googlevideo.com/videoplayback?expire=1",
        ])
        let sanitized = try XCTUnwrap(MacPersistentMediaURLPolicy.sanitizedRecoveryData(payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        XCTAssertEqual(object["source_url"] as? String, "https://www.youtube.com/watch?v=video123")
        XCTAssertTrue(object["download_source_url"] is NSNull)
    }

    func testPersistentMediaURLPolicyRejectsUnsafeURLFormsAndPreservesCanonicalLinks() throws {
        let oversized = "https://music.example.test/" + String(repeating: "x", count: 8_200)
        let rejected = [
            "http://music.example.test/song",
            "file:///Users/lily/song.m4a",
            "https://user:password@music.example.test/song",
            "https://music.example.test/song#fragment",
            "https://127.0.0.1/song",
            "https://127.0.0.1./song",
            "https://2130706433/song",
            "https://[::1]/song",
            "https://localhost/song",
            oversized,
            "https://%invalid",
        ]
        for value in rejected {
            XCTAssertNil(
                MacPersistentMediaURLPolicy.persistentString(value),
                "unsafe URL should not be persisted: \(value.prefix(80))"
            )
        }

        XCTAssertEqual(
            MacPersistentMediaURLPolicy.persistentString("https://www.youtube.com/watch?v=video123"),
            "https://www.youtube.com/watch?v=video123"
        )
        XCTAssertEqual(
            MacPersistentMediaURLPolicy.persistentString("https://music.example.test/api/v1/songs/1"),
            "https://music.example.test/api/v1/songs/1"
        )

        let payload = try JSONSerialization.data(withJSONObject: [
            "canonical": "https://www.youtube.com/watch?v=video123",
            "server": "https://music.example.test/api/v1/songs/1",
            "unsafe": "https://192.168.1.1/private",
            "non_https": "http://music.example.test/song",
            "oversized": oversized,
        ])
        let sanitized = try XCTUnwrap(MacPersistentMediaURLPolicy.sanitizedRecoveryData(payload))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        XCTAssertEqual(object["canonical"] as? String, "https://www.youtube.com/watch?v=video123")
        XCTAssertEqual(object["server"] as? String, "https://music.example.test/api/v1/songs/1")
        XCTAssertTrue(object["unsafe"] is NSNull)
        XCTAssertTrue(object["non_https"] is NSNull)
        XCTAssertTrue(object["oversized"] is NSNull)
    }

    func testUpdaterAllowsTheGitHubReleaseAssetRedirectChainButRejectsEveryForeignHop() throws {
        let hosts = Set([
            "github.com",
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com",
            "github-releases.githubusercontent.com",
        ])
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json")!)
        let delegate = MacBoundedRedirectDelegate { candidate in
            UpdateManager.allowsUpdateURL(candidate, allowedHosts: hosts)
        }

        func follow(_ from: String, to: String) throws -> URLRequest? {
            let source = try XCTUnwrap(URL(string: from))
            let destination = try XCTUnwrap(URL(string: to))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": destination.absoluteString]
            ))
            var accepted: URLRequest?
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: destination)
            ) { request in
                accepted = request
            }
            return accepted
        }

        XCTAssertNotNil(try follow(
            "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-mac.json",
            to: "https://objects.githubusercontent.com/github-production-release-asset/manifest"
        ))
        XCTAssertNotNil(try follow(
            "https://objects.githubusercontent.com/github-production-release-asset/manifest",
            to: "https://release-assets.githubusercontent.com/github-production-release-asset/archive.zip"
        ))
        XCTAssertNil(try follow(
            "https://release-assets.githubusercontent.com/github-production-release-asset/archive.zip",
            to: "https://evil.example.test/archive.zip"
        ))
        XCTAssertNil(try follow(
            "https://release-assets.githubusercontent.com/github-production-release-asset/archive.zip",
            to: "http://release-assets.githubusercontent.com/archive.zip"
        ))
        XCTAssertNil(try follow(
            "https://release-assets.githubusercontent.com/github-production-release-asset/archive.zip",
            to: "https://user:password@release-assets.githubusercontent.com/archive.zip"
        ))
        XCTAssertNil(try follow(
            "https://release-assets.githubusercontent.com/github-production-release-asset/archive.zip",
            to: "https://release-assets.githubusercontent.com:444/archive.zip"
        ))
    }

    func testProductionUpdaterPolicyRequiresAnExactPublisherIdentity() {
        let production = MacUpdateAuthenticityPolicy(
            mode: .production,
            teamIdentifier: "A1B2C3D4E5",
            designatedRequirement: "identifier \"com.example.Resonance\" and anchor apple generic and certificate leaf[subject.OU] = \"A1B2C3D4E5\""
        )
        XCTAssertTrue(production.isProductionConfigured)
        XCTAssertTrue(production.allowsAutomaticChecks(environment: [:]))

        let incomplete = MacUpdateAuthenticityPolicy(
            mode: .production,
            teamIdentifier: "A1B2C3D4E5",
            designatedRequirement: nil
        )
        XCTAssertFalse(incomplete.allowsAutomaticChecks(environment: [:]))

        let development = MacUpdateAuthenticityPolicy(
            mode: .development,
            teamIdentifier: nil,
            designatedRequirement: nil
        )
        XCTAssertFalse(development.allowsAutomaticChecks(environment: [:]))
        XCTAssertTrue(development.allowsAutomaticChecks(environment: [
            "RESONANCE_ALLOW_UNVERIFIED_UPDATES": "1",
        ]))
        XCTAssertFalse(MacUpdateAuthenticityPolicy.isValidTeamIdentifier("a1b2c3d4e5"))
    }
}
