import CryptoKit
import Foundation

enum MobileUploadMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case localFile = "local_file"
    case serverSourceLink = "server_source_link"
    case reviewedMatch = "reviewed_match"

    var id: Self { self }

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
            "Registers the direct source link preserved when this device downloaded the song."
        case .serverSourceLink:
            "Registers the direct source link preserved after downloading the song."
        case .reviewedMatch:
            "Lets you review a match, download it, and register its preserved source link."
        }
    }
}

enum MobileDownloadMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case verifiedFileCache = "verified_file_cache"
    case streamOnly = "stream_only"

    var id: Self { self }

    var title: String {
        switch self {
        case .verifiedFileCache: "Verified offline file"
        case .streamOnly: "Stream only"
        }
    }

    var detail: String {
        switch self {
        case .verifiedFileCache:
            "Downloads a size- and SHA-256-verified file for offline playback."
        case .streamOnly:
            "Buffers through the server resolver for playback and never adds a song file to the library."
        }
    }
}

enum MobileConfiguredOfflineMode: String, Decodable, Sendable {
    case verifiedFileCache = "verified_file_cache"
    case streamOnly = "stream_only"
}

enum MobileConfiguredPlaybackMode: String, Decodable, Sendable {
    case sameOriginResolver = "same_origin_resolver"
}

enum MobileMatcherMode: String, Decodable, Sendable {
    case off
    case shadow
    case review
}

enum MobileStorageReadMode: String, Decodable, Sendable {
    case r2Only = "r2_only"
    case externalWithR2Fallback = "external_with_r2_fallback"
}

struct MobileClientConfigAudience: Decodable, Equatable, Sendable {
    let origin: String
    let profileID: String
    let platform: String
    let appVersion: String
    let appBuild: Int
    let cohortBucket: Int

    enum CodingKeys: String, CodingKey {
        case origin
        case profileID = "profile_id"
        case platform
        case appVersion = "app_version"
        case appBuild = "app_build"
        case cohortBucket = "cohort_bucket"
    }
}

struct MobileClientConfigValues: Decodable, Equatable, Sendable {
    let uploadLocalFile: Bool
    let uploadServerSourceLink: Bool
    let uploadReviewedMatch: Bool
    let uploadExternalObject: Bool
    let downloadOfflineMode: MobileConfiguredOfflineMode
    let downloadPlaybackMode: MobileConfiguredPlaybackMode
    let matcherMode: MobileMatcherMode
    let storageReadMode: MobileStorageReadMode
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

struct MobileClientConfigKillSwitches: Decodable, Equatable, Sendable {
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

struct MobileClientConfigPayload: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int
    let issuedAt: String
    let notBefore: String
    let expiresAt: String
    let audience: MobileClientConfigAudience
    let values: MobileClientConfigValues
    let killSwitches: MobileClientConfigKillSwitches

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case revision
        case issuedAt = "issued_at"
        case notBefore = "not_before"
        case expiresAt = "expires_at"
        case audience
        case values
        case killSwitches = "kill_switches"
    }
}

struct MobileClientConfigExpectedAudience: Equatable, Sendable {
    let origin: String
    let profileID: String
    let appVersion: String
    let appBuild: Int
    let cohortKey: String

    var audience: MobileClientConfigAudience {
        MobileClientConfigAudience(
            origin: origin,
            profileID: profileID,
            platform: "ios",
            appVersion: appVersion,
            appBuild: appBuild,
            cohortBucket: MobileClientConfigCohort.bucket(for: cohortKey)
        )
    }
}

struct MobileClientRequestContext: Equatable, Sendable {
    let profileID: String
    let platform: String
    let appVersion: String
    let appBuild: Int
    let cohortKey: String

    var isComplete: Bool {
        !profileID.isEmpty
            && platform == "ios"
            && !appVersion.isEmpty
            && appBuild > 0
            && MobileClientConfigCohort.isValidKey(cohortKey)
    }

    func apply(to request: inout URLRequest) {
        request.setValue(profileID, forHTTPHeaderField: "X-Resonance-Profile")
        request.setValue(platform, forHTTPHeaderField: "X-Resonance-Client-Platform")
        request.setValue(appVersion, forHTTPHeaderField: "X-Resonance-App-Version")
        request.setValue(String(appBuild), forHTTPHeaderField: "X-Resonance-App-Build")
        request.setValue(cohortKey, forHTTPHeaderField: "X-Resonance-Cohort-Key")
        request.setValue("1", forHTTPHeaderField: "X-Resonance-Config-Protocol")
    }
}

struct MobileVerifiedClientConfiguration: Equatable, Sendable {
    let payload: MobileClientConfigPayload
    let issuedAt: Date
    let notBefore: Date
    let expiresAt: Date

    func isUsable(at date: Date) -> Bool {
        date >= notBefore && date < expiresAt
    }
}

enum MobileClientConfigVerificationError: LocalizedError, Equatable {
    case missingDigest
    case malformedDigest
    case digestMismatch
    case missingSignature
    case malformedSignature
    case signatureMismatch
    case malformedPayload
    case unsupportedSchema
    case invalidRevision
    case invalidAppBuild
    case wrongAudience
    case invalidTimeWindow
    case notYetValid
    case expired
    case unsafeExternalObject
    case unsafeExternalRead
    case unsafeReclaim

    var errorDescription: String? {
        switch self {
        case .missingDigest: "The feature response did not include Content-Digest."
        case .malformedDigest: "The feature response Content-Digest was malformed."
        case .digestMismatch: "The feature response body did not match Content-Digest."
        case .missingSignature: "The feature response did not include its signature."
        case .malformedSignature: "The feature response signature was malformed."
        case .signatureMismatch: "The feature response signature was invalid."
        case .malformedPayload: "The feature response JSON did not match protocol 1."
        case .unsupportedSchema: "The feature response used an unsupported schema."
        case .invalidRevision: "The feature response revision was invalid."
        case .invalidAppBuild: "The feature response app build was invalid."
        case .wrongAudience: "The feature response was issued for a different client context."
        case .invalidTimeWindow: "The feature response lifetime was invalid."
        case .notYetValid: "The feature response is not valid yet."
        case .expired: "The feature response expired."
        case .unsafeExternalObject: "Direct external-object uploads are not supported by this client."
        case .unsafeExternalRead: "External-object reads are not supported by this client."
        case .unsafeReclaim: "R2 reclaim cannot be enabled by a client feature response."
        }
    }
}

enum MobileClientConfigCohort {
    static func isValidKey(_ value: String) -> Bool {
        guard value.count == 22,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return false }
        var standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - standard.count % 4) % 4
        standard += String(repeating: "=", count: padding)
        guard let decoded = Data(base64Encoded: standard), decoded.count == 16 else { return false }
        let canonical = decoded.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value
    }

    static func bucket(for key: String) -> Int {
        let input = Data("resonance-client-config-cohort-v1\n\(key)".utf8)
        let digest = SHA256.hash(data: input)
        let bytes = Array(digest.prefix(4))
        let value = UInt32(bytes[0]) << 24
            | UInt32(bytes[1]) << 16
            | UInt32(bytes[2]) << 8
            | UInt32(bytes[3])
        return Int(value % 10_000)
    }
}

enum MobileClientConfigOrigin {
    static func normalized(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port,
           !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            components.port = port
        }
        return components.string
    }
}

enum MobileClientConfigVerifier {
    static let maximumLifetime: TimeInterval = 15 * 60

    static func verify(
        body: Data,
        contentDigest: String?,
        signature: String?,
        accessToken: String,
        expected: MobileClientConfigExpectedAudience,
        now: Date = .now
    ) throws -> MobileVerifiedClientConfiguration {
        guard let contentDigest else { throw MobileClientConfigVerificationError.missingDigest }
        guard let expectedDigest = parseWrappedBase64(contentDigest, prefix: "sha-256=:") else {
            throw MobileClientConfigVerificationError.malformedDigest
        }
        let actualDigest = Data(SHA256.hash(data: body))
        guard constantTimeEqual(expectedDigest, actualDigest) else {
            throw MobileClientConfigVerificationError.digestMismatch
        }

        let payload: MobileClientConfigPayload
        do {
            payload = try JSONDecoder().decode(MobileClientConfigPayload.self, from: body)
        } catch {
            throw MobileClientConfigVerificationError.malformedPayload
        }
        guard payload.schemaVersion == 1 else {
            throw MobileClientConfigVerificationError.unsupportedSchema
        }
        guard payload.revision >= 0 else {
            throw MobileClientConfigVerificationError.invalidRevision
        }
        guard payload.audience.appBuild > 0 else {
            throw MobileClientConfigVerificationError.invalidAppBuild
        }
        guard payload.audience == expected.audience else {
            throw MobileClientConfigVerificationError.wrongAudience
        }

        guard let signature else { throw MobileClientConfigVerificationError.missingSignature }
        guard let expectedSignature = parseWrappedBase64(signature, prefix: "v1=:") else {
            throw MobileClientConfigVerificationError.malformedSignature
        }
        let signingInput = [
            "resonance-client-config-v1",
            payload.audience.origin,
            payload.audience.profileID,
            payload.audience.platform,
            String(payload.audience.appBuild),
            contentDigest,
        ].joined(separator: "\n")
        let key = SymmetricKey(data: Data(accessToken.utf8))
        let actualSignature = Data(HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: key
        ))
        guard constantTimeEqual(expectedSignature, actualSignature) else {
            throw MobileClientConfigVerificationError.signatureMismatch
        }

        guard let issuedAt = parseDate(payload.issuedAt),
              let notBefore = parseDate(payload.notBefore),
              let expiresAt = parseDate(payload.expiresAt),
              issuedAt <= now,
              issuedAt <= notBefore,
              issuedAt < expiresAt,
            notBefore < expiresAt,
            expiresAt.timeIntervalSince(issuedAt) <= maximumLifetime else {
            throw MobileClientConfigVerificationError.invalidTimeWindow
        }
        guard now >= notBefore else { throw MobileClientConfigVerificationError.notYetValid }
        guard now < expiresAt else { throw MobileClientConfigVerificationError.expired }
        guard payload.values.uploadExternalObject == false else {
            throw MobileClientConfigVerificationError.unsafeExternalObject
        }
        guard payload.values.storageReadMode == .r2Only else {
            throw MobileClientConfigVerificationError.unsafeExternalRead
        }
        guard payload.values.storageR2Reclaim == false else {
            throw MobileClientConfigVerificationError.unsafeReclaim
        }
        return MobileVerifiedClientConfiguration(
            payload: payload,
            issuedAt: issuedAt,
            notBefore: notBefore,
            expiresAt: expiresAt
        )
    }

    private static func parseWrappedBase64(_ value: String, prefix: String) -> Data? {
        guard value.hasPrefix(prefix), value.hasSuffix(":"), value.count > prefix.count + 1 else {
            return nil
        }
        let encoded = String(value.dropFirst(prefix.count).dropLast())
        guard let decoded = Data(base64Encoded: encoded),
              decoded.count == SHA256.byteCount,
              decoded.base64EncodedString() == encoded else { return nil }
        return decoded
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

struct MobileClientFeatureConfiguration: Equatable, Sendable {
    let revision: Int?
    let expiresAt: Date?
    let uploadLocalFile: Bool
    let uploadServerSourceLink: Bool
    let uploadReviewedMatch: Bool
    let configuredOfflineMode: MobileConfiguredOfflineMode
    let matcherMode: MobileMatcherMode
    let storageReadMode: MobileStorageReadMode
    let killSwitches: MobileClientConfigKillSwitches

    static let safeDefaults = MobileClientFeatureConfiguration(
        revision: nil,
        expiresAt: nil,
        uploadLocalFile: true,
        uploadServerSourceLink: false,
        uploadReviewedMatch: false,
        configuredOfflineMode: .verifiedFileCache,
        matcherMode: .off,
        storageReadMode: .r2Only,
        killSwitches: MobileClientConfigKillSwitches(
            allUploads: false,
            linkImports: true,
            offlineDownloads: false,
            externalReads: true,
            r2Reclaim: true
        )
    )

    init(verified: MobileVerifiedClientConfiguration) {
        let payload = verified.payload
        revision = payload.revision
        expiresAt = verified.expiresAt
        uploadLocalFile = payload.values.uploadLocalFile
        uploadServerSourceLink = payload.values.uploadServerSourceLink
        uploadReviewedMatch = payload.values.uploadReviewedMatch
        configuredOfflineMode = payload.values.downloadOfflineMode
        matcherMode = payload.values.matcherMode
        storageReadMode = payload.values.storageReadMode
        killSwitches = payload.killSwitches
    }

    private init(
        revision: Int?,
        expiresAt: Date?,
        uploadLocalFile: Bool,
        uploadServerSourceLink: Bool,
        uploadReviewedMatch: Bool,
        configuredOfflineMode: MobileConfiguredOfflineMode,
        matcherMode: MobileMatcherMode,
        storageReadMode: MobileStorageReadMode,
        killSwitches: MobileClientConfigKillSwitches
    ) {
        self.revision = revision
        self.expiresAt = expiresAt
        self.uploadLocalFile = uploadLocalFile
        self.uploadServerSourceLink = uploadServerSourceLink
        self.uploadReviewedMatch = uploadReviewedMatch
        self.configuredOfflineMode = configuredOfflineMode
        self.matcherMode = matcherMode
        self.storageReadMode = storageReadMode
        self.killSwitches = killSwitches
    }

    func current(at date: Date = .now) -> MobileClientFeatureConfiguration {
        guard let expiresAt else { return self }
        return date < expiresAt ? self : .safeDefaults
    }

    func hasSamePolicy(as other: MobileClientFeatureConfiguration) -> Bool {
        revision == other.revision
            && uploadLocalFile == other.uploadLocalFile
            && uploadServerSourceLink == other.uploadServerSourceLink
            && uploadReviewedMatch == other.uploadReviewedMatch
            && configuredOfflineMode == other.configuredOfflineMode
            && matcherMode == other.matcherMode
            && storageReadMode == other.storageReadMode
            && killSwitches == other.killSwitches
    }
}

enum MobileTransferModePolicy {
    static func availableUploadModes(
        configuration: MobileClientFeatureConfiguration,
        at date: Date = .now
    ) -> [MobileUploadMode] {
        let configuration = configuration.current(at: date)
        guard !configuration.killSwitches.allUploads else { return [] }
        var result: [MobileUploadMode] = []
        if configuration.uploadLocalFile { result.append(.localFile) }
        if configuration.uploadServerSourceLink, !configuration.killSwitches.linkImports {
            result.append(.serverSourceLink)
        }
        if configuration.uploadLocalFile,
           configuration.uploadReviewedMatch,
           configuration.matcherMode == .review {
            result.append(.reviewedMatch)
        }
        return result
    }

    static func effectiveUploadMode(
        preferred: MobileUploadMode?,
        configuration: MobileClientFeatureConfiguration,
        at date: Date = .now
    ) -> MobileUploadMode? {
        let available = availableUploadModes(configuration: configuration, at: date)
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }

    static func availableDownloadModes(
        configuration: MobileClientFeatureConfiguration,
        at date: Date = .now
    ) -> [MobileDownloadMode] {
        let configuration = configuration.current(at: date)
        switch configuration.configuredOfflineMode {
        case .verifiedFileCache:
            return configuration.killSwitches.offlineDownloads ? [] : [.verifiedFileCache]
        case .streamOnly:
            return [.streamOnly]
        }
    }

    static func effectiveDownloadMode(
        preferred: MobileDownloadMode?,
        configuration: MobileClientFeatureConfiguration,
        at date: Date = .now
    ) -> MobileDownloadMode? {
        let available = availableDownloadModes(configuration: configuration, at: date)
        if let preferred, available.contains(preferred) { return preferred }
        return available.first
    }
}

struct MobileTransferPolicyLease: Equatable, Sendable {
    let configuration: MobileClientFeatureConfiguration
    let preferredUploadMode: MobileUploadMode?
    let preferredDownloadMode: MobileDownloadMode?
    let requiredUploadMode: MobileUploadMode?
    let requiredDownloadMode: MobileDownloadMode?
}

final class MobileTransferAuthorization: @unchecked Sendable {
    typealias RevocationHandler = @Sendable () -> Void

    private let lock = NSLock()
    private let expiresAt: Date?
    private let expiryTimer: DispatchSourceTimer?
    private var valid: Bool
    private var handlers: [UUID: RevocationHandler] = [:]

    init(expiresAt: Date?, now: Date = .now) {
        self.expiresAt = expiresAt
        valid = expiresAt.map { now < $0 } ?? true
        if valid, expiresAt != nil {
            expiryTimer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "mov.unblocked.resonance.ios.transfer-authorization")
            )
        } else {
            expiryTimer = nil
        }
        expiryTimer?.setEventHandler { [weak self] in
            self?.expireIfNeeded()
        }
        scheduleExpiryCheck(now: now)
        expiryTimer?.resume()
    }

    deinit {
        expiryTimer?.setEventHandler {}
        expiryTimer?.cancel()
    }

    func isAuthorized(at now: Date = .now) -> Bool {
        var callbacks: [RevocationHandler] = []
        lock.lock()
        if valid, let expiresAt, now >= expiresAt {
            valid = false
            callbacks = Array(handlers.values)
            handlers.removeAll()
        }
        let result = valid
        lock.unlock()
        callbacks.forEach { $0() }
        return result
    }

    func register(_ handler: @escaping RevocationHandler, now: Date = .now) -> UUID? {
        let id = UUID()
        var callbacks: [RevocationHandler] = []
        lock.lock()
        if valid, let expiresAt, now >= expiresAt {
            valid = false
            callbacks = Array(handlers.values)
            handlers.removeAll()
        }
        let registered = valid
        if registered { handlers[id] = handler }
        lock.unlock()
        callbacks.forEach { $0() }
        return registered ? id : nil
    }

    func unregister(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }

    func revoke() {
        var callbacks: [RevocationHandler] = []
        lock.lock()
        if valid {
            valid = false
            callbacks = Array(handlers.values)
            handlers.removeAll()
        }
        lock.unlock()
        callbacks.forEach { $0() }
    }

    private func scheduleExpiryCheck(now: Date) {
        guard let expiresAt, let expiryTimer else { return }
        let remaining = max(expiresAt.timeIntervalSince(now), 0)
        let nanoseconds = max(Int(remaining * 1_000_000_000), 1)
        expiryTimer.schedule(
            deadline: .now() + .nanoseconds(nanoseconds),
            leeway: .milliseconds(10)
        )
    }

    private func expireIfNeeded() {
        if isAuthorized() {
            scheduleExpiryCheck(now: .now)
        }
    }
}

enum MobileTransferPolicyLeasePolicy {
    static func captureUpload(
        _ requiredMode: MobileUploadMode,
        configuration: MobileClientFeatureConfiguration,
        preferredMode: MobileUploadMode?,
        at date: Date = .now
    ) -> MobileTransferPolicyLease? {
        guard configuration.current(at: date) == configuration,
              MobileTransferModePolicy.effectiveUploadMode(
                preferred: preferredMode,
                configuration: configuration,
                at: date
              ) == requiredMode else { return nil }
        return MobileTransferPolicyLease(
            configuration: configuration,
            preferredUploadMode: preferredMode,
            preferredDownloadMode: nil,
            requiredUploadMode: requiredMode,
            requiredDownloadMode: nil
        )
    }

    static func captureDownload(
        _ requiredMode: MobileDownloadMode,
        configuration: MobileClientFeatureConfiguration,
        preferredMode: MobileDownloadMode?,
        at date: Date = .now
    ) -> MobileTransferPolicyLease? {
        guard configuration.current(at: date) == configuration,
              MobileTransferModePolicy.effectiveDownloadMode(
                preferred: preferredMode,
                configuration: configuration,
                at: date
              ) == requiredMode else { return nil }
        return MobileTransferPolicyLease(
            configuration: configuration,
            preferredUploadMode: nil,
            preferredDownloadMode: preferredMode,
            requiredUploadMode: nil,
            requiredDownloadMode: requiredMode
        )
    }

    static func isCurrent(
        _ lease: MobileTransferPolicyLease,
        configuration: MobileClientFeatureConfiguration,
        preferredUploadMode: MobileUploadMode?,
        preferredDownloadMode: MobileDownloadMode?,
        at date: Date = .now
    ) -> Bool {
        guard lease.configuration.current(at: date) == lease.configuration,
              configuration.current(at: date) == configuration,
              configuration.hasSamePolicy(as: lease.configuration) else { return false }
        if let requiredUploadMode = lease.requiredUploadMode {
            guard preferredUploadMode == lease.preferredUploadMode,
                  MobileTransferModePolicy.effectiveUploadMode(
                    preferred: preferredUploadMode,
                    configuration: configuration,
                    at: date
                  ) == requiredUploadMode else { return false }
        }
        if let requiredDownloadMode = lease.requiredDownloadMode {
            guard preferredDownloadMode == lease.preferredDownloadMode,
                  MobileTransferModePolicy.effectiveDownloadMode(
                    preferred: preferredDownloadMode,
                    configuration: configuration,
                    at: date
                  ) == requiredDownloadMode else { return false }
        }
        return true
    }
}

enum MobileClientConfigRefreshPolicy {
    static func delay(until expiresAt: Date, now: Date = .now) -> TimeInterval? {
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        return remaining > 120 ? remaining - 60 : remaining * 0.5
    }
}

enum MobileReviewedUploadCompletionPolicy {
    static func shouldReconcileCommittedResponse(
        requestContextCurrent: Bool,
        leaseStillCurrent: Bool
    ) -> Bool {
        _ = leaseStillCurrent
        return requestContextCurrent
    }
}

struct MobileClientConfigCacheScope: Equatable, Sendable {
    let origin: String
    let profileID: String
    let platform: String
    let appVersion: String
    let appBuild: String
    let tokenFingerprint: String

    private var digest: String {
        let value = [origin, profileID, platform, appVersion, appBuild, tokenFingerprint].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var storageKey: String { "Resonance.clientConfig.cache." + digest }
    var highestRevisionKey: String { "Resonance.clientConfig.highestRevision." + digest }

    static func tokenFingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum MobileClientConfigRevisionPolicy {
    static func accepts(candidate: Int, highestVerified: Int?) -> Bool {
        guard candidate >= 0 else { return false }
        guard let highestVerified else { return true }
        return candidate >= highestVerified
    }
}

struct MobileTransferPreferenceScope: Equatable, Sendable {
    let origin: String
    let profileID: String

    private var digest: String {
        SHA256.hash(data: Data("\(origin)\n\(profileID)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    var uploadKey: String { "Resonance.transferMode.upload.\(digest)" }
    var downloadKey: String { "Resonance.transferMode.download.\(digest)" }
}

struct MobileClientConfigCacheRecord: Codable, Equatable, Sendable {
    let body: Data
    let contentDigest: String
    let signature: String
    let cachedAt: Date
}

enum MobileClientConfigCachePolicy {
    static func isFresh(
        _ record: MobileClientConfigCacheRecord,
        now: Date = .now
    ) -> Bool {
        record.cachedAt <= now
            && now.timeIntervalSince(record.cachedAt) <= MobileClientConfigVerifier.maximumLifetime
    }
}

enum MobileClientConfigHTTPDisposition: Equatable {
    case verify
    case useFreshCache
    case evictAndUseSafeDefaults
}

enum MobileClientConfigHTTPPolicy {
    static func disposition(status: Int, contentType: String?) -> MobileClientConfigHTTPDisposition {
        if (500...599).contains(status) { return .useFreshCache }
        guard status == 200 else { return .evictAndUseSafeDefaults }
        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json" ? .verify : .evictAndUseSafeDefaults
    }
}

enum MobileClientConfigTransportPolicy {
    static func mayUseFreshCache(for error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive:
            return true
        default:
            return false
        }
    }
}

enum MobileBoundedResponsePolicy {
    static let clientConfigMaximumBytes = 256 * 1_024
    static let sourceImportMaximumBytes = 256 * 1_024
    static let mediaLocationMaximumBytes = 64 * 1_024
    static let authMaximumBytes = 256 * 1_024
    static let catalogMaximumBytes = 16 * 1_024 * 1_024
    static let playlistMaximumBytes = 4 * 1_024 * 1_024
    static let profileMaximumBytes = 1 * 1_024 * 1_024
    static let listenAlongMaximumBytes = 256 * 1_024
    static let artworkMaximumBytes = 10 * 1_024 * 1_024

    static func accepts(currentCount: Int, adding additionalCount: Int, maximum: Int) -> Bool {
        guard currentCount >= 0, additionalCount >= 0, maximum >= 0 else { return false }
        let sum = currentCount.addingReportingOverflow(additionalCount)
        return !sum.overflow && sum.partialValue <= maximum
    }
}

enum MobileSensitiveResponseError: LocalizedError, Equatable {
    case tooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            "The response exceeded the \(limit)-byte safety limit."
        }
    }
}

private final class MobileSensitiveRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if MobileSameOriginPolicy.matches(request.url, origin) {
            completionHandler(request)
        } else {
            // Passing nil rejects the redirect, but a custom URLProtocol can
            // otherwise leave the task alive until its request timeout.
            completionHandler(nil)
            task.cancel()
        }
    }
}

enum MobileSensitiveNetworkPolicy {
    /// Performs a body-bounded request whose URL and every redirect must stay
    /// on the supplied origin. The caller should pass the origin appropriate
    /// for the endpoint (the API origin for server calls, or the issuer origin
    /// for Clerk token/user calls).
    static func data(
        for request: URLRequest,
        origin: URL,
        maximumBytes: Int,
        using sourceSession: URLSession = .shared
    ) async throws -> (Data, HTTPURLResponse) {
        guard MobileSameOriginPolicy.matches(request.url, origin) else {
            throw URLError(.dataNotAllowed)
        }

        let sourceConfiguration = sourceSession.configuration
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = sourceConfiguration.timeoutIntervalForRequest
        configuration.timeoutIntervalForResource = sourceConfiguration.timeoutIntervalForResource
        configuration.protocolClasses = sourceConfiguration.protocolClasses
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let delegate = MobileSensitiveRedirectDelegate(origin: origin)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              MobileSameOriginPolicy.matches(response.url, origin) else {
            throw URLError(.dataNotAllowed)
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw MobileSensitiveResponseError.tooLarge(limit: maximumBytes)
        }
        var body = Data()
        if response.expectedContentLength > 0 {
            let declaredLength = min(response.expectedContentLength, Int64(maximumBytes))
            body.reserveCapacity(Int(declaredLength))
        }
        for try await byte in bytes {
            guard MobileBoundedResponsePolicy.accepts(
                currentCount: body.count,
                adding: 1,
                maximum: maximumBytes
            ) else {
                throw MobileSensitiveResponseError.tooLarge(limit: maximumBytes)
            }
            body.append(byte)
        }
        return (body, response)
    }
}

enum MobileSourcePagePolicy {
    private static let canonicalYouTubePage = try! NSRegularExpression(
        pattern: #"^https://www\.youtube\.com/watch\?v=[A-Za-z0-9_-]{11}$"#
    )

    static func validatedOriginalYouTubePage(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= MobileDurableURLPolicy.maximumCharacters else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard canonicalYouTubePage.firstMatch(in: trimmed, range: range)?.range == range else {
            return nil
        }
        return trimmed
    }
}

enum MobileReviewedMatchResponseError: LocalizedError, Equatable {
    case invalidResponse
    case noReviewCandidates

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid reviewed-match response."
        case .noReviewCandidates:
            "The server did not return any audio candidates to review."
        }
    }
}

struct MobileReviewedMatchResponse: Decodable, Sendable {
    struct Candidate: Decodable, Sendable {
        struct Match: Decodable, Sendable {
            let title: Double?
            let artist: Double?
            let album: Double?
            let duration: Double?
            let durationDeltaSeconds: Int?

            enum CodingKeys: String, CodingKey {
                case title, artist, album, duration
                case durationDeltaSeconds = "duration_delta_seconds"
            }
        }

        let provider: String?
        let sourceURL: String?
        let videoID: String?
        let title: String?
        let artist: String?
        let album: String?
        let durationSeconds: Int?
        let thumbnailURL: String?
        let score: Double?
        let confidence: String?
        let actionable: Bool?
        let requiresReview: Bool?
        let autoSelectable: Bool?
        let match: Match?

        enum CodingKeys: String, CodingKey {
            case provider
            case sourceURL = "source_url"
            case videoID = "video_id"
            case title, artist, album
            case durationSeconds = "duration_seconds"
            case thumbnailURL = "thumbnail_url"
            case score, confidence, actionable
            case requiresReview = "requires_review"
            case autoSelectable = "auto_selectable"
            case match
        }

        var localCandidate: LocalImportAudioSourceMatch? {
            guard actionable == false,
                  requiresReview == true,
                  autoSelectable == false,
                  let sourceURL,
                  let canonicalSource = MobileSourcePagePolicy.validatedOriginalYouTubePage(sourceURL),
                  let resolvedVideoID = try? LocalImportURL.youtubeVideoID(canonicalSource),
                  videoID == nil || videoID == resolvedVideoID,
                  let rawTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty,
                  let score,
                  score.isFinite,
                  (0...1).contains(score) else { return nil }
            let sourceProvider: LocalImportAudioSourceMatch.Provider
            switch provider {
            case "youtube_music": sourceProvider = .youtubeMusic
            case "youtube": sourceProvider = .youtube
            default: return nil
            }
            guard durationSeconds.map({ (1...86_400).contains($0) }) ?? true else { return nil }
            let matchTitle = match?.title.flatMap(normalizedScore) ?? score
            let matchArtist = match?.artist.flatMap(normalizedScore) ?? score
            return LocalImportAudioSourceMatch(
                videoID: resolvedVideoID,
                playlistPosition: nil,
                title: String(rawTitle.prefix(500)),
                artist: boundedText(artist),
                album: boundedText(album),
                durationSeconds: durationSeconds,
                thumbnailURL: validatedHTTPSURL(thumbnailURL),
                sourceProvider: sourceProvider,
                officialArtist: false,
                sourceURL: canonicalSource,
                score: score,
                confidence: String((confidence ?? "review").prefix(32)),
                match: LocalImportAudioSourceMatch.MatchDetails(
                    title: matchTitle,
                    artist: matchArtist,
                    album: match?.album.flatMap(normalizedScore),
                    duration: match?.duration.flatMap(normalizedScore),
                    durationDeltaSeconds: match?.durationDeltaSeconds
                )
            )
        }

        private func normalizedScore(_ value: Double) -> Double? {
            value.isFinite && (0...1).contains(value) ? value : nil
        }

        private func boundedText(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return String(trimmed.prefix(500))
        }

        private func validatedHTTPSURL(_ value: String?) -> String? {
            guard let value,
                  value.utf8.count <= 2_048,
                  let url = URL(string: value),
                  url.scheme?.lowercased() == "https",
                  url.host != nil,
                  url.user == nil,
                  url.password == nil else { return nil }
            return value
        }
    }

    let provider: String
    let type: String
    let source: String
    let trackID: String?
    let videoID: String?
    let title: String?
    let artist: String?
    let author: String?
    let album: String?
    let trackNumber: Int?
    let durationSeconds: Int?
    let artworkURL: String?
    let thumbnailURL: String?
    let embedURL: String?
    let reviewCandidates: [Candidate]?

    enum CodingKeys: String, CodingKey {
        case provider, type, source, title, artist, author, album
        case trackID = "track_id"
        case videoID = "video_id"
        case trackNumber = "track_number"
        case durationSeconds = "duration_seconds"
        case artworkURL = "artwork_url"
        case thumbnailURL = "thumbnail_url"
        case embedURL = "embed_url"
        case reviewCandidates = "review_candidates"
    }

    func reviewedResolution() throws -> LocalImportResolution {
        guard let title = boundedRequiredText(title),
              !source.isEmpty,
              source.count <= MobileDurableURLPolicy.maximumCharacters else {
            throw MobileReviewedMatchResponseError.invalidResponse
        }
        if provider == "spotify", type == "track" {
            guard let parsed = try? LocalImportURL.spotifyTrack(source),
                  trackID == nil || trackID == parsed.trackID,
                  let artist = boundedRequiredText(artist) else {
                throw MobileReviewedMatchResponseError.invalidResponse
            }
            let candidates = (reviewCandidates ?? []).compactMap(\.localCandidate)
            guard !candidates.isEmpty else {
                throw MobileReviewedMatchResponseError.noReviewCandidates
            }
            return LocalImportResolution(
                kind: .spotify,
                track: LocalImportSpotifyTrack(
                    provider: provider,
                    type: type,
                    trackID: parsed.trackID,
                    title: title,
                    artist: artist,
                    album: boundedOptionalText(album),
                    trackNumber: trackNumber.flatMap { $0 > 0 ? $0 : nil },
                    durationSeconds: validDuration(durationSeconds),
                    artworkURL: validatedHTTPSURL(artworkURL),
                    embedURL: validatedHTTPSURL(embedURL) ?? "",
                    sourceURL: parsed.url.absoluteString
                ),
                candidates: candidates
            )
        }
        if provider == "youtube", type == "video",
           let author = boundedRequiredText(author),
           let reviewCandidates,
           reviewCandidates.count == 1,
           let candidate = reviewCandidates.first?.localCandidate,
           candidate.sourceProvider == .youtube,
           let parsedVideoID = try? LocalImportURL.youtubeVideoID(candidate.sourceURL),
           source == candidate.sourceURL,
           candidate.videoID == parsedVideoID,
           videoID == nil || videoID == parsedVideoID,
           candidate.title == title,
           candidate.artist == author {
            return LocalImportResolution(
                kind: .youtube,
                track: LocalImportSpotifyTrack(
                    provider: provider,
                    type: "track",
                    trackID: parsedVideoID,
                    title: title,
                    artist: author,
                    album: nil,
                    trackNumber: nil,
                    durationSeconds: validDuration(durationSeconds),
                    artworkURL: validatedHTTPSURL(thumbnailURL),
                    embedURL: "",
                    sourceURL: candidate.sourceURL
                ),
                candidates: [candidate]
            )
        }
        throw MobileReviewedMatchResponseError.invalidResponse
    }

    private func boundedRequiredText(_ value: String?) -> String? {
        guard let value = boundedOptionalText(value) else { return nil }
        return value
    }

    private func boundedOptionalText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(500))
    }

    private func validDuration(_ value: Int?) -> Int? {
        value.flatMap { (1...86_400).contains($0) ? $0 : nil }
    }

    private func validatedHTTPSURL(_ value: String?) -> String? {
        guard let value,
              value.utf8.count <= 2_048,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        return value
    }
}

enum MobileTransientDownloadPolicy {
    static let filenamePrefix = "resonance-download-"
    static let importDirectoryPrefix = "resonance-import-"

    static func owns(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(filenamePrefix)
    }

    static func ownsTemporaryEntry(
        _ url: URL,
        isRegularFile: Bool,
        isDirectory: Bool,
        isSymbolicLink: Bool
    ) -> Bool {
        guard !isSymbolicLink else { return false }
        if url.lastPathComponent.hasPrefix(filenamePrefix) { return isRegularFile }
        if url.lastPathComponent.hasPrefix(importDirectoryPrefix) { return isDirectory }
        return false
    }
}

enum MobileLocalImportStagingPolicy {
    static func ownsStagedFile(
        _ url: URL,
        stagingDirectory: URL,
        isRegularFile: Bool,
        isSymbolicLink: Bool
    ) -> Bool {
        guard isRegularFile, !isSymbolicLink else { return false }
        return url.standardizedFileURL.deletingLastPathComponent()
            == stagingDirectory.standardizedFileURL
    }
}

enum MobileOwnedTransferArtifactCleaner {
    static func removeOrphans(
        temporaryDirectory: URL,
        stagingDirectory: URL,
        fileManager: FileManager = .default
    ) {
        if let entries = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                guard let values = try? entry.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                ), MobileTransientDownloadPolicy.ownsTemporaryEntry(
                    entry,
                    isRegularFile: values.isRegularFile == true,
                    isDirectory: values.isDirectory == true,
                    isSymbolicLink: values.isSymbolicLink == true
                ) else { continue }
                try? fileManager.removeItem(at: entry)
            }
        }

        guard let stagedEntries = try? fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return }
        for entry in stagedEntries {
            guard let values = try? entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), MobileLocalImportStagingPolicy.ownsStagedFile(
                entry,
                stagingDirectory: stagingDirectory,
                isRegularFile: values.isRegularFile == true,
                isSymbolicLink: values.isSymbolicLink == true
            ) else { continue }
            try? fileManager.removeItem(at: entry)
        }
    }
}

struct MobileRemoteMediaLocation: Decodable, Sendable {
    let streamURL: String
    let byteLength: Int64
    let contentSHA256: String?
    let contentType: String
    let supportsRanges: Bool
    let state: String

    enum CodingKeys: String, CodingKey {
        case streamURL = "stream_url"
        case byteLength = "byte_length"
        case contentSHA256 = "content_sha256"
        case contentType = "content_type"
        case supportsRanges = "supports_ranges"
        case state
    }
}

struct MobileRemoteMediaLocationResponse: Decodable, Sendable {
    let mediaLocation: MobileRemoteMediaLocation

    enum CodingKeys: String, CodingKey {
        case mediaLocation = "media_location"
    }
}

enum MobileSameOriginPolicy {
    static func matches(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased() else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
