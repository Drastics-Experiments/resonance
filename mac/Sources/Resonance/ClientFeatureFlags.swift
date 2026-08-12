import CryptoKit
import Foundation

final class MacRejectRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum MacBoundedResponseError: Error {
    case invalidResponse
    case responseTooLarge
}

enum MacUploadMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case localFile = "local_file"
    case serverSourceLink = "server_source_link"
    case reviewedMatch = "reviewed_match"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .localFile: "Preserved source link"
        case .serverSourceLink: "Preserved source link"
        case .reviewedMatch: "Reviewed source link"
        }
    }

    var detail: String {
        switch self {
        case .localFile:
            "Register the direct source link preserved when this Mac downloaded the song."
        case .serverSourceLink:
            "Register the direct source link preserved after downloading the song."
        case .reviewedMatch:
            "Review a matched source, save it locally, and register its preserved link."
        }
    }
}

enum MacDownloadMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case verifiedFileCache = "verified_file_cache"
    case streamOnly = "stream_only"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .verifiedFileCache: "Verified file cache"
        case .streamOnly: "Stream only"
        }
    }

    var detail: String {
        switch self {
        case .verifiedFileCache:
            "Download from Resonance and verify the file size and SHA-256 before installing it."
        case .streamOnly:
            "Play through Resonance without keeping an offline library file on this Mac."
        }
    }
}

enum MacMatcherMode: String, Decodable, Sendable {
    case off
    case shadow
    case review
}

enum MacOfflineMode: String, Decodable, Sendable {
    case verifiedFileCache = "verified_file_cache"
    case streamOnly = "stream_only"
}

enum MacPlaybackMode: String, Decodable, Sendable {
    case sameOriginResolver = "same_origin_resolver"
}

enum MacStorageReadMode: String, Decodable, Sendable {
    case r2Only = "r2_only"
    case externalWithR2Fallback = "external_with_r2_fallback"
}

struct MacClientConfigDocument: Decodable, Sendable {
    struct Audience: Decodable, Equatable, Sendable {
        let origin: String
        let profileID: String
        let platform: String
        let appVersion: String
        let appBuild: Int
        let cohortBucket: Int

        enum CodingKeys: String, CodingKey {
            case origin, platform
            case profileID = "profile_id"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case cohortBucket = "cohort_bucket"
        }
    }

    struct KillSwitches: Decodable, Sendable {
        let allUploads: Bool
        let linkImports: Bool
        let offlineDownloads: Bool
        let externalReads: Bool
        let r2Reclaim: Bool

        enum CodingKeys: String, CodingKey {
            case allUploads = "all_uploads"
            case linkImports = "link_imports"
            case offlineDownloads = "offline_downloads"
            case externalReads = "external_reads"
            case r2Reclaim = "r2_reclaim"
        }
    }

    struct Values: Decodable, Sendable {
        let uploadLocalFile: Bool
        let uploadServerSourceLink: Bool
        let uploadReviewedMatch: Bool
        let uploadExternalObject: Bool
        let downloadOfflineMode: MacOfflineMode
        let downloadPlaybackMode: MacPlaybackMode
        let matcherMode: MacMatcherMode
        let storageReadMode: MacStorageReadMode
        let storageR2Reclaim: Bool

        enum CodingKeys: String, CodingKey {
            case uploadLocalFile = "upload.local_file"
            case uploadServerSourceLink = "upload.server_source_link"
            case uploadReviewedMatch = "upload.reviewed_match"
            case uploadExternalObject = "upload.external_object"
            case downloadOfflineMode = "download.offline_mode"
            case downloadPlaybackMode = "download.playback_mode"
            case matcherMode = "matcher.mode"
            case storageReadMode = "storage.read_mode"
            case storageR2Reclaim = "storage.r2_reclaim"
        }
    }

    let schemaVersion: Int
    let revision: Int
    let issuedAt: String
    let notBefore: String
    let expiresAt: String
    let audience: Audience
    let values: Values
    let killSwitches: KillSwitches

    enum CodingKeys: String, CodingKey {
        case revision, audience, values
        case killSwitches = "kill_switches"
        case schemaVersion = "schema_version"
        case issuedAt = "issued_at"
        case notBefore = "not_before"
        case expiresAt = "expires_at"
    }
}

struct MacClientConfigContext: Codable, Equatable, Hashable, Sendable {
    static let platform = "macos"
    static let protocolVersion = "1"

    let origin: String
    let profileID: String
    let appVersion: String
    let appBuild: Int
    let cohortKey: String
    let cohortBucket: Int
    let tokenFingerprint: String

    var audience: MacClientConfigDocument.Audience {
        .init(
            origin: origin,
            profileID: profileID,
            platform: Self.platform,
            appVersion: appVersion,
            appBuild: appBuild,
            cohortBucket: cohortBucket
        )
    }

    var cacheKey: String {
        let scope = [
            origin,
            profileID,
            Self.platform,
            appVersion,
            String(appBuild),
            cohortKey,
            String(cohortBucket),
            tokenFingerprint,
        ]
            .joined(separator: "\u{0}")
        return "Resonance.clientConfig.cache.v1.\(Self.sha256Hex(scope))"
    }

    var highestRevisionKey: String {
        cacheKey + ".highestRevision"
    }

    var transferModeScope: String {
        Self.transferModeScope(origin: origin, profileID: profileID)
    }

    static func transferModeScope(origin: String, profileID: String) -> String {
        sha256Hex([origin, profileID].joined(separator: "\u{0}"))
    }

    static func cohortBucket(for cohortKey: String) -> Int {
        let input = Data("resonance-client-config-cohort-v1\n\(cohortKey)".utf8)
        let digest = SHA256.hash(data: input)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Int(value % 10_000)
    }

    static func tokenFingerprint(_ token: String) -> String {
        sha256Hex(token)
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum MacClientConfigVerificationError: Error, Equatable {
    case invalidDigest
    case invalidSignature
    case invalidJSON
    case unsupportedSchema
    case wrongAudience
    case invalidTime
    case unsafeValue
}

enum MacClientConfigVerifier {
    static let maximumLifetime: TimeInterval = 15 * 60

    static func verify(
        body: Data,
        contentDigest: String?,
        signature: String?,
        context: MacClientConfigContext,
        accessToken: String,
        now: Date = .now
    ) throws -> MacClientConfigDocument {
        let expectedDigest = "sha-256=:\(Data(SHA256.hash(data: body)).base64EncodedString()):"
        guard contentDigest == expectedDigest else {
            throw MacClientConfigVerificationError.invalidDigest
        }

        let decoder = JSONDecoder()
        guard let document = try? decoder.decode(MacClientConfigDocument.self, from: body) else {
            throw MacClientConfigVerificationError.invalidJSON
        }
        guard document.schemaVersion == 1 else {
            throw MacClientConfigVerificationError.unsupportedSchema
        }
        guard document.audience == context.audience else {
            throw MacClientConfigVerificationError.wrongAudience
        }

        guard let signatureData = signatureBytes(signature) else {
            throw MacClientConfigVerificationError.invalidSignature
        }
        let input = [
            "resonance-client-config-v1",
            document.audience.origin,
            document.audience.profileID,
            document.audience.platform,
            String(document.audience.appBuild),
            expectedDigest,
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(accessToken.utf8))
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signatureData,
            authenticating: Data(input.utf8),
            using: key
        ) else {
            throw MacClientConfigVerificationError.invalidSignature
        }

        guard hasValidTime(document, now: now) else {
            throw MacClientConfigVerificationError.invalidTime
        }

        // These capabilities are intentionally unimplemented on clients. A signed
        // configuration cannot opt this build into direct provider objects or R2 deletion.
        guard document.values.uploadExternalObject == false,
              document.values.storageR2Reclaim == false,
              document.values.storageReadMode == .r2Only,
              document.revision >= 0,
              document.audience.appBuild > 0 else {
            throw MacClientConfigVerificationError.unsafeValue
        }
        return document
    }

    static func hasValidTime(_ document: MacClientConfigDocument, now: Date = .now) -> Bool {
        guard let issuedAt = date(document.issuedAt),
              let notBefore = date(document.notBefore),
              let expiresAt = date(document.expiresAt),
              issuedAt <= notBefore,
              issuedAt <= now,
              issuedAt <= expiresAt,
              notBefore <= expiresAt,
              expiresAt.timeIntervalSince(issuedAt) > 0,
              expiresAt.timeIntervalSince(issuedAt) <= maximumLifetime,
              now >= notBefore,
              now < expiresAt else { return false }
        return true
    }

    static func expirationDate(_ document: MacClientConfigDocument) -> Date? {
        date(document.expiresAt)
    }

    static func signatureHeader(
        body: Data,
        audience: MacClientConfigDocument.Audience,
        accessToken: String
    ) -> (contentDigest: String, signature: String) {
        let digest = "sha-256=:\(Data(SHA256.hash(data: body)).base64EncodedString()):"
        let input = [
            "resonance-client-config-v1",
            audience.origin,
            audience.profileID,
            audience.platform,
            String(audience.appBuild),
            digest,
        ].joined(separator: "\n")
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(input.utf8),
            using: SymmetricKey(data: Data(accessToken.utf8))
        )
        return (digest, "v1=:\(Data(authenticationCode).base64EncodedString()):")
    }

    private static func signatureBytes(_ value: String?) -> Data? {
        guard let value,
              value.hasPrefix("v1=:") && value.hasSuffix(":"),
              !value.dropFirst(4).dropLast().isEmpty else { return nil }
        let encoded = String(value.dropFirst(4).dropLast())
        guard let data = Data(base64Encoded: encoded),
              data.count == SHA256.byteCount,
              data.base64EncodedString() == encoded else { return nil }
        return data
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct MacCachedClientConfig: Codable, Sendable {
    let body: Data
    let contentDigest: String
    let signature: String
    let context: MacClientConfigContext
    let cachedAt: Date
}

enum MacClientConfigSource: Equatable, Sendable {
    case safeDefaults
    case legacyServer
    case verifiedServer
    case verifiedCache
}

struct MacEffectiveClientConfig: Sendable {
    let document: MacClientConfigDocument?
    let source: MacClientConfigSource

    static let safeDefaults = MacEffectiveClientConfig(document: nil, source: .safeDefaults)

    private var validDocument: MacClientConfigDocument? {
        guard let document,
              source == .verifiedServer || source == .verifiedCache,
              MacClientConfigVerifier.hasValidTime(document) else { return nil }
        return document
    }

    var statusText: String {
        switch source {
        case .safeDefaults: "Safe defaults"
        case .legacyServer: "Legacy server defaults"
        case .verifiedServer: "Verified server configuration"
        case .verifiedCache: "Verified cached configuration"
        }
    }

    var allowsLocalFileUpload: Bool {
        guard let document = validDocument else { return true }
        return document.values.uploadLocalFile && document.killSwitches.allUploads == false
    }

    var allowsServerSourceLink: Bool {
        guard let document = validDocument else { return false }
        return document.values.uploadServerSourceLink
            && document.killSwitches.allUploads == false
            && document.killSwitches.linkImports == false
    }

    var allowsReviewedMatch: Bool {
        guard let document = validDocument else { return false }
        return document.values.uploadReviewedMatch
            && document.values.uploadLocalFile
            && document.values.matcherMode == .review
            && document.killSwitches.allUploads == false
    }

    var allowsOfflineDownload: Bool {
        guard let document = validDocument else { return true }
        return document.values.downloadOfflineMode == .verifiedFileCache
            && document.killSwitches.offlineDownloads == false
    }

    var allowsStreamOnlyPlayback: Bool {
        guard let document = validDocument else { return false }
        return document.values.downloadOfflineMode == .streamOnly
            && document.values.downloadPlaybackMode == .sameOriginResolver
    }

    var allowsMatcherReview: Bool {
        validDocument?.values.matcherMode == .review
    }

    var requestedStreamOnly: Bool {
        validDocument?.values.downloadOfflineMode == .streamOnly
            || validDocument?.killSwitches.offlineDownloads == true
    }

    var permittedUploadModes: [MacUploadMode] {
        var modes: [MacUploadMode] = []
        if allowsLocalFileUpload { modes.append(.localFile) }
        if allowsServerSourceLink { modes.append(.serverSourceLink) }
        if allowsReviewedMatch { modes.append(.reviewedMatch) }
        return modes
    }

    var permittedDownloadModes: [MacDownloadMode] {
        if allowsOfflineDownload { return [.verifiedFileCache] }
        if allowsStreamOnlyPlayback { return [.streamOnly] }
        return []
    }

    func resolvedUploadMode(_ persisted: MacUploadMode?) -> MacUploadMode {
        if let persisted, permittedUploadModes.contains(persisted) { return persisted }
        if permittedUploadModes.contains(.localFile) { return .localFile }
        return permittedUploadModes.first ?? .localFile
    }

    func resolvedDownloadMode(_ persisted: MacDownloadMode?) -> MacDownloadMode {
        if let persisted, permittedDownloadModes.contains(persisted) { return persisted }
        return permittedDownloadModes.first ?? .verifiedFileCache
    }
}

enum MacClientConfigIdentity {
    static let cohortKeyDefaultsKey = "Resonance.clientConfig.cohortKey.v1"

    static func cohortKey(defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: cohortKeyDefaultsKey),
           stored.count == 22,
           let decoded = decodedBase64URL(stored),
           decoded.count == 16,
           base64URL(decoded) == stored {
            return stored
        }
        var uuid = UUID().uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        let generated = base64URL(data)
        defaults.set(generated, forKey: cohortKeyDefaultsKey)
        return generated
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodedBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return nil }
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        return Data(base64Encoded: standard)
    }
}
