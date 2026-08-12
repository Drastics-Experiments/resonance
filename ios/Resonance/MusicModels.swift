import Foundation

struct MobileServerContext: Codable, Hashable, Sendable {
    let origin: String
    let profileID: String

    var storagePrefix: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedOrigin = origin.addingPercentEncoding(withAllowedCharacters: allowed) ?? origin
        let encodedProfile = profileID.addingPercentEncoding(withAllowedCharacters: allowed) ?? profileID
        return "origin=\(encodedOrigin)&profile=\(encodedProfile)"
    }
}

struct MobileRemoteIdentity: Codable, Hashable, Sendable {
    let context: MobileServerContext
    let remoteID: String
}

struct MobileServerEndpointResolution: Equatable, Sendable {
    let url: URL
    let usesInsecureLocalHTTP: Bool
}

enum MobileServerEndpointError: LocalizedError, Equatable {
    case invalidURL
    case credentialsInURL
    case insecureRemoteHTTP

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid HTTPS server URL."
        case .credentialsInURL:
            "Do not put credentials in the server URL. Sign in through the account section."
        case .insecureRemoteHTTP:
            "HTTPS is required. Unencrypted HTTP is allowed only for localhost development."
        }
    }
}

enum MobileServerEndpointPolicy {
    private static let legacyProductionHost = "music.unblocked.mov"
    private static let productionHost = "resonance-core.blithe-haven-9710.chatgpt.site"

    static func resolve(_ rawValue: String) throws -> MobileServerEndpointResolution {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              scheme == "https" || scheme == "http" else {
            throw MobileServerEndpointError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw MobileServerEndpointError.credentialsInURL
        }
        components.scheme = scheme
        components.host = canonicalHost(host, scheme: scheme, port: components.port)
        components.query = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        let isLoopback = host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "127.0.0.1"
            || host == "::1"
        if scheme == "http", !isLoopback {
            throw MobileServerEndpointError.insecureRemoteHTTP
        }
        guard let url = components.url else { throw MobileServerEndpointError.invalidURL }
        return MobileServerEndpointResolution(url: url, usesInsecureLocalHTTP: scheme == "http")
    }

    static func normalizedOrigin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let canonicalHost = canonicalHost(host, scheme: scheme, port: port)
        var components = URLComponents()
        components.scheme = scheme
        components.host = canonicalHost
        components.port = port
        return components.string
    }

    static func canonicalContext(_ context: MobileServerContext) -> MobileServerContext {
        guard let url = URL(string: context.origin),
              let origin = normalizedOrigin(of: url) else { return context }
        return MobileServerContext(origin: origin, profileID: context.profileID)
    }

    static func canonicalStoredServerKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let legacyOrigin = "https://\(legacyProductionHost)"
        guard value == legacyOrigin || value.hasPrefix("\(legacyOrigin)#profile=") else { return value }
        return "https://\(productionHost)" + value.dropFirst(legacyOrigin.count)
    }

    static func context(serverURL: URL, profileID: String) -> MobileServerContext? {
        guard let origin = normalizedOrigin(of: serverURL), !profileID.isEmpty else { return nil }
        return MobileServerContext(origin: origin, profileID: profileID)
    }

    private static func canonicalHost(_ host: String, scheme: String, port: Int?) -> String {
        let isDefaultHTTPSPort = port == nil || port == 443
        return scheme == "https" && isDefaultHTTPSPort && host == legacyProductionHost
            ? productionHost
            : host
    }
}

enum PlaybackVolumePolicy {
    static func gain(for sliderValue: Double) -> Float {
        guard sliderValue.isFinite else { return 0 }
        let normalized = min(max(sliderValue, 0), 1)
        return Float(normalized * normalized)
    }
}

enum MobileServerUploadNaming {
    static func filename(for sourceURL: URL, title: String? = nil) -> String {
        let fileExtension = sourceURL.pathExtension.filter { $0.isLetter || $0.isNumber }
        var preferredStem = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extensionSuffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        if !extensionSuffix.isEmpty,
           preferredStem.lowercased().hasSuffix(extensionSuffix.lowercased()) {
            preferredStem.removeLast(extensionSuffix.count)
        }
        let sourceStem = sourceURL.deletingPathExtension().lastPathComponent
        let stem = cleanStem(preferredStem).isEmpty ? cleanStem(sourceStem) : cleanStem(preferredStem)
        let resolvedStem = stem.isEmpty ? "Untitled song" : stem
        return fileExtension.isEmpty ? resolvedStem : "\(resolvedStem).\(fileExtension)"
    }

    private static func cleanStem(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let sanitized = value.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
        let collapsed = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(collapsed.prefix(180))
    }
}

enum MobileServerSongIdentityPolicy {
    static func metadataMatches(
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: Double?,
        actualTitle: String,
        actualArtist: String,
        actualDuration: Double?
    ) -> Bool {
        guard normalize(expectedTitle) == normalize(actualTitle) else { return false }
        let expectedArtists = artistTokens(expectedArtist)
        let actualArtists = artistTokens(actualArtist)
        guard !expectedArtists.isEmpty, expectedArtists == actualArtists else { return false }
        if let expectedDuration, expectedDuration > 0,
           let actualDuration, actualDuration > 0 {
            return abs(expectedDuration - actualDuration) <= 5
        }
        return true
    }

    private static func artistTokens(_ value: String) -> Set<Substring> {
        let ignored: Set<Substring> = [
            "and", "feat", "featuring", "ft", "with",
            "unknown", "artist", "local", "file",
        ]
        return Set(normalize(value).split(separator: " ")).subtracting(ignored)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .map { $0.isLetter || $0.isNumber ? String($0) : " " }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

struct MobileTrack: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var relativePath: String
    var remoteID: String?
    var sourceServer: String?
    var syncProfileID: String?
    var sourceURL: String?
    var downloadSourceURL: String?
    var artworkFilename: String?
    var artworkScanComplete: Bool?
    var dateAdded: Date
    var sourceSHA256: String?
    var contentSHA256: String?
    var preservesUnlinkedImport: Bool?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Local file",
        album: String = "Imported",
        duration: TimeInterval,
        relativePath: String,
        remoteID: String? = nil,
        sourceServer: String? = nil,
        syncProfileID: String? = nil,
        sourceURL: String? = nil,
        downloadSourceURL: String? = nil,
        artworkFilename: String? = nil,
        artworkScanComplete: Bool? = false,
        dateAdded: Date = .now,
        sourceSHA256: String? = nil,
        contentSHA256: String? = nil,
        preservesUnlinkedImport: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.relativePath = relativePath
        self.remoteID = remoteID
        self.sourceServer = sourceServer
        self.syncProfileID = syncProfileID
        self.sourceURL = sourceURL
        self.downloadSourceURL = downloadSourceURL
        self.artworkFilename = artworkFilename
        self.artworkScanComplete = artworkScanComplete
        self.dateAdded = dateAdded
        self.sourceSHA256 = sourceSHA256
        self.contentSHA256 = contentSHA256
        self.preservesUnlinkedImport = preservesUnlinkedImport
    }

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "0:00" }
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    func remoteIdentity(fallbackServerURL: URL? = nil) -> MobileRemoteIdentity? {
        guard let remoteID, !remoteID.isEmpty else { return nil }
        let serverURL = sourceServer.flatMap(URL.init(string:)) ?? fallbackServerURL
        guard let serverURL,
              let context = MobileServerEndpointPolicy.context(
                serverURL: serverURL,
                profileID: syncProfileID ?? "default"
              ) else { return nil }
        return MobileRemoteIdentity(context: context, remoteID: remoteID)
    }
}

struct MobileNowPlayingSnapshot: Equatable {
    let identifier: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsed: TimeInterval
    let playbackRate: Double
    let defaultPlaybackRate: Double
    let allowsTrackNavigation: Bool
}

enum MobileNowPlayingPolicy {
    static func seekFraction(
        elapsedTime: TimeInterval,
        bounds: MobileClipPlaybackPolicy.Bounds
    ) -> Double {
        let duration = max(bounds.end - bounds.start, 0.01)
        guard elapsedTime.isFinite else { return 0 }
        return min(max(elapsedTime / duration, 0), 1)
    }

    static func snapshot(
        for track: MobileTrack,
        position: TimeInterval,
        bounds: MobileClipPlaybackPolicy.Bounds,
        playbackRate: Float,
        isPlaying: Bool,
        allowsTrackNavigation: Bool
    ) -> MobileNowPlayingSnapshot {
        let duration = max(bounds.end - bounds.start, 0.01)
        let safePosition = position.isFinite ? position : bounds.start
        let elapsed = min(max(safePosition - bounds.start, 0), duration)
        let normalizedRate = playbackRate.isFinite && playbackRate > 0
            ? Double(playbackRate)
            : 1
        return MobileNowPlayingSnapshot(
            identifier: track.id.uuidString,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: duration,
            elapsed: elapsed,
            playbackRate: isPlaying ? normalizedRate : 0,
            defaultPlaybackRate: normalizedRate,
            allowsTrackNavigation: allowsTrackNavigation
        )
    }
}

enum MobileCatalogRefreshFailurePolicy {
    static func preservesLastKnownCatalog(
        wasConnected: Bool,
        hadCatalog: Bool,
        wasCancelled: Bool,
        isAuthenticationFailure: Bool
    ) -> Bool {
        guard !isAuthenticationFailure else { return false }
        return wasConnected || hadCatalog || wasCancelled
    }
}

struct MobileFullCatalogAuthoritySnapshot: Equatable, Sendable {
    let context: MobileServerContext
    let requestGeneration: UInt64
    let songIDs: Set<String>
}

enum MobileFullCatalogAuthorityPolicy {
    static func completedFetch(
        context: MobileServerContext?,
        requestGeneration: UInt64,
        currentRequestGeneration: UInt64,
        credentialIsCurrent: Bool,
        catalogMutationGenerationUnchanged: Bool,
        hasPendingCatalogMerges: Bool,
        songIDs: Set<String>
    ) -> MobileFullCatalogAuthoritySnapshot? {
        guard let context,
              requestGeneration == currentRequestGeneration,
              credentialIsCurrent,
              catalogMutationGenerationUnchanged,
              !hasPendingCatalogMerges else { return nil }
        return MobileFullCatalogAuthoritySnapshot(
            context: context,
            requestGeneration: requestGeneration,
            songIDs: songIDs
        )
    }

    static func songIDsIfCurrent(
        _ snapshot: MobileFullCatalogAuthoritySnapshot?,
        context: MobileServerContext?,
        requestGeneration: UInt64
    ) -> Set<String>? {
        guard let snapshot,
              snapshot.context == context,
              snapshot.requestGeneration == requestGeneration else { return nil }
        return snapshot.songIDs
    }
}

enum MobileUnlinkedDownloadMigrationPolicy {
    static let identifier = "delete-unlinked-downloads-v1"

    struct Decision: Equatable {
        var track: MobileTrack
        let shouldDelete: Bool
    }

    static func decision(for track: MobileTrack, legacyDownloadOwned: Bool) -> Decision {
        var migrated = track
        if migrated.preservesUnlinkedImport == nil {
            migrated.preservesUnlinkedImport = !legacyDownloadOwned
        }

        let hasRemoteIdentity = [migrated.remoteID, migrated.sourceServer].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        let hasSourceLink = [migrated.sourceURL, migrated.downloadSourceURL].contains { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return Decision(
            track: migrated,
            shouldDelete: (hasRemoteIdentity || legacyDownloadOwned)
                && !hasSourceLink
                && migrated.preservesUnlinkedImport != true
        )
    }
}

enum MobileRemoteAssociationError: LocalizedError, Equatable {
    case incompleteExistingIdentity(remoteID: String?)
    case contextConflict(existingContext: MobileServerContext, targetContext: MobileServerContext)

    var errorDescription: String? {
        switch self {
        case .incompleteExistingIdentity:
            "This song already has a server link, but its server or profile identity is incomplete. Resonance kept the existing link. Re-download it or import a separate local copy before uploading it to another server profile."
        case .contextConflict(let existingContext, let targetContext):
            "This song is already linked to profile \(existingContext.profileID) at \(existingContext.origin). Resonance kept that link instead of reusing this managed copy for profile \(targetContext.profileID) at \(targetContext.origin). Import a separate local copy to upload it there."
        }
    }
}

enum MobileRemoteAssociationPolicy {
    static func validateAdoption(
        track: MobileTrack,
        targetContext: MobileServerContext
    ) throws {
        let hasRemoteID = track.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasSourceServer = track.sourceServer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let hasPersistedAssociation = hasRemoteID || hasSourceServer
        guard hasPersistedAssociation else { return }
        guard let sourceServer = track.sourceServer,
              !sourceServer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let profileID = track.syncProfileID,
              !profileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let serverURL = URL(string: sourceServer),
              let existingContext = MobileServerEndpointPolicy.context(
                  serverURL: serverURL,
                  profileID: profileID
              ) else {
            throw MobileRemoteAssociationError.incompleteExistingIdentity(remoteID: track.remoteID)
        }
        guard existingContext == targetContext else {
            throw MobileRemoteAssociationError.contextConflict(
                existingContext: existingContext,
                targetContext: targetContext
            )
        }
    }
}

enum MobileManagedTrackUploadPolicy {
    static func managedTrack(
        matching sourceURL: URL,
        tracks: [MobileTrack],
        musicDirectory: URL
    ) -> MobileTrack? {
        guard let sourcePath = canonicalPath(for: sourceURL),
              let musicRoot = canonicalPath(for: musicDirectory) else { return nil }
        let rootPrefix = musicRoot.hasSuffix("/") ? musicRoot : musicRoot + "/"

        return tracks.first { track in
            guard !track.relativePath.isEmpty,
                  let managedPath = canonicalPath(
                      for: musicDirectory.appendingPathComponent(track.relativePath)
                  ),
                  managedPath.hasPrefix(rootPrefix) else { return false }
            return managedPath == sourcePath
        }
    }

    private static func canonicalPath(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct MobileMissingServerUploadPlan: Equatable {
    let uploadTrackIDs: [UUID]
    let existingRemoteIDsByTrackID: [UUID: String]
}

struct MobileTransferNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let detail: String
    let isError: Bool
}

struct MobileTransferFailure: Identifiable, Codable, Equatable {
    enum Operation: String, Codable, Equatable {
        case download = "Download"
        case upload = "Upload"
        case delete = "Delete"
    }

    let id: UUID
    let operation: Operation
    let item: String
    let reason: String
    let retryTarget: MobileTransferRetryTarget?

    init(
        id: UUID = UUID(),
        operation: Operation,
        item: String,
        reason: String,
        retryTarget: MobileTransferRetryTarget? = nil
    ) {
        self.id = id
        self.operation = operation
        self.item = item
        self.reason = reason
        self.retryTarget = retryTarget
    }
}

struct MobileLibraryRecoveryNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum MobileTransferRetryTarget: Codable, Equatable {
    case download(remoteSongID: String)
    case uploadTrack(trackID: UUID)
    case uploadFile(URL)
    case delete(remoteSongID: String)
}

enum MobileDownloadIntegrityError: LocalizedError, Equatable {
    case tooLarge(actual: Int64, limit: Int64)
    case sizeMismatch(expected: Int64, actual: Int64)
    case missingHash
    case hashMismatch

    var errorDescription: String? {
        switch self {
        case .tooLarge(let actual, let limit):
            "The downloaded file is \(actual) bytes, above the \(limit)-byte safety limit."
        case .sizeMismatch(let expected, let actual):
            "The downloaded file size was \(actual) bytes; the catalog expected \(expected)."
        case .missingHash:
            "The server catalog did not provide a valid SHA-256 for this file."
        case .hashMismatch:
            "The downloaded file did not match the catalog SHA-256."
        }
    }
}

enum MobileContentHashPolicy {
    static func normalizedSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count == 64, normalized.allSatisfy({ $0.isHexDigit }) else { return nil }
        return normalized
    }
}

enum MobileDownloadIntegrityPolicy {
    static let maximumFileSize: Int64 = 2 * 1_024 * 1_024 * 1_024

    static func validate(
        expectedSize: Int64,
        expectedSHA256: String?,
        actualSize: Int64,
        actualSHA256: String,
        maximumSize: Int64 = maximumFileSize
    ) throws {
        guard actualSize <= maximumSize else {
            throw MobileDownloadIntegrityError.tooLarge(actual: actualSize, limit: maximumSize)
        }
        if expectedSize > 0, expectedSize != actualSize {
            throw MobileDownloadIntegrityError.sizeMismatch(expected: expectedSize, actual: actualSize)
        }
        guard let expected = MobileContentHashPolicy.normalizedSHA256(expectedSHA256) else {
            throw MobileDownloadIntegrityError.missingHash
        }
        if expected != actualSHA256.lowercased() {
            throw MobileDownloadIntegrityError.hashMismatch
        }
    }

}

enum MobileDownloadByteLimitPolicy {
    static func oversizedByteCount(
        totalBytesWritten: Int64,
        totalBytesExpected: Int64,
        maximumSize: Int64 = MobileDownloadIntegrityPolicy.maximumFileSize
    ) -> Int64? {
        if totalBytesExpected > maximumSize { return totalBytesExpected }
        if totalBytesWritten > maximumSize { return totalBytesWritten }
        return nil
    }
}

enum MobileUploadBlockingPolicy {
    static func blocksUpload(
        isUploading: Bool,
        isDownloading: Bool,
        isSyncing: Bool,
        isRefreshingCatalog: Bool,
        isSyncingPlaylists _: Bool
    ) -> Bool {
        isUploading || isDownloading || (isSyncing && !isRefreshingCatalog)
    }
}

enum MobileUploadCredentialPolicy {
    static func canUpload(serverURL: URL?, adminKey: String) -> Bool {
        serverURL != nil && !adminKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum MobilePlaylistSyncResponsePolicy {
    static func shouldApplyResponse(
        submittedMutationGeneration: UInt64,
        currentMutationGeneration: UInt64
    ) -> Bool {
        submittedMutationGeneration == currentMutationGeneration
    }
}

enum MobileCatalogRefreshMergePolicy {
    static func merge(
        catalog: [MobileRemoteSong],
        uploadedSongsAwaitingCatalog: [String: MobileRemoteSong]
    ) -> [MobileRemoteSong] {
        let catalogIDs = Set(catalog.map(\.id))
        return catalog + uploadedSongsAwaitingCatalog.values
            .filter { !catalogIDs.contains($0.id) }
            .sorted { $0.id < $1.id }
    }
}

enum MobileMissingServerUploadPolicy {
    static func plan(
        tracks: [MobileTrack],
        catalog: [MobileRemoteSong],
        activeProfileID: String,
        activeServerURL: URL
    ) -> MobileMissingServerUploadPlan {
        let liveRemoteIDs = Set(catalog.map(\.id))
        let remoteIDByHash = Dictionary(
            catalog.compactMap { song -> (String, String)? in
                guard let hash = MobileContentHashPolicy.normalizedSHA256(song.contentSHA256) else { return nil }
                return (hash, song.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard let activeContext = MobileServerEndpointPolicy.context(
            serverURL: activeServerURL,
            profileID: activeProfileID
        ) else {
            return MobileMissingServerUploadPlan(uploadTrackIDs: [], existingRemoteIDsByTrackID: [:])
        }
        var uploadTrackIDs: [UUID] = []
        var existingRemoteIDsByTrackID: [UUID: String] = [:]

        for track in tracks {
            guard !track.relativePath.isEmpty,
                  let identity = track.remoteIdentity(),
                  identity.context == activeContext else { continue }

            if let remoteID = track.remoteID,
               liveRemoteIDs.contains(remoteID) {
                continue
            }
            if let hash = MobileContentHashPolicy.normalizedSHA256(track.contentSHA256),
               let existingRemoteID = remoteIDByHash[hash] {
                existingRemoteIDsByTrackID[track.id] = existingRemoteID
            } else {
                uploadTrackIDs.append(track.id)
            }
        }

        return MobileMissingServerUploadPlan(
            uploadTrackIDs: uploadTrackIDs,
            existingRemoteIDsByTrackID: existingRemoteIDsByTrackID
        )
    }

}

struct MobileClipRange: Codable, Hashable {
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    var duration: TimeInterval { max(0, endSeconds - startSeconds) }
}

enum MobileClipPlaybackPolicy {
    struct Bounds: Equatable {
        let start: TimeInterval
        let end: TimeInterval
    }

    static func bounds(range: MobileClipRange?, duration: TimeInterval) -> Bounds {
        let maximum = max(duration.isFinite ? duration : 0, 0)
        guard let range else { return Bounds(start: 0, end: maximum) }
        let start = min(max(range.startSeconds.isFinite ? range.startSeconds : 0, 0), maximum)
        let end = min(max(range.endSeconds.isFinite ? range.endSeconds : start, start), maximum)
        guard end - start >= 0.25 else { return Bounds(start: 0, end: maximum) }
        return Bounds(start: start, end: end)
    }

    static func position(fraction: Double, within bounds: Bounds) -> TimeInterval {
        let fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return bounds.start + ((bounds.end - bounds.start) * fraction)
    }

    static func reachedEnd(
        position: TimeInterval,
        bounds: Bounds,
        tolerance: TimeInterval = 0.02
    ) -> Bool {
        bounds.end > bounds.start
            && position.isFinite
            && position + max(tolerance, 0) >= bounds.end
    }
}

struct MobileRemoteClipRange: Codable, Hashable {
    var songID: String
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case songID = "song_id"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct MobilePlaylist: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var trackIDs: [UUID]
    var isSystem: Bool
    var remoteSongIDs: [String]?
    var entryOrder: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [UUID] = [],
        isSystem: Bool = false,
        remoteSongIDs: [String]? = nil,
        entryOrder: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.isSystem = isSystem
        self.remoteSongIDs = remoteSongIDs
        self.entryOrder = entryOrder
    }

    var automaticArtworkTrackIDs: [UUID] {
        isSystem ? [] : Array(trackIDs.prefix(4))
    }
}

struct MobileRemotePlaylist: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String
    var songIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case songIDs = "song_ids"
    }

    init(id: UUID, name: String, songIDs: [String]) {
        self.id = id
        self.name = name
        self.songIDs = songIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = try values.decode(String.self, forKey: .id)
        guard let id = UUID(uuidString: rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: values,
                debugDescription: "Playlist ID is not a UUID."
            )
        }
        self.id = id
        name = try values.decode(String.self, forKey: .name)
        songIDs = try values.decode([String].self, forKey: .songIDs)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id.uuidString.lowercased(), forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(songIDs, forKey: .songIDs)
    }
}

struct MobileRemotePlaylistsDocument: Codable, Hashable {
    var profileID: String?
    var revision: Int
    var playlists: [MobileRemotePlaylist]
    var likedSongIDs: [String]
    var clipRanges: [MobileRemoteClipRange]

    enum CodingKeys: String, CodingKey {
        case revision, playlists
        case profileID = "profile_id"
        case likedSongIDs = "liked_song_ids"
        case clipRanges = "clip_ranges"
    }

    init(
        profileID: String? = nil,
        revision: Int,
        playlists: [MobileRemotePlaylist],
        likedSongIDs: [String] = [],
        clipRanges: [MobileRemoteClipRange] = []
    ) {
        self.profileID = profileID
        self.revision = revision
        self.playlists = playlists
        self.likedSongIDs = likedSongIDs
        self.clipRanges = clipRanges
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        revision = try values.decode(Int.self, forKey: .revision)
        playlists = try values.decode([MobileRemotePlaylist].self, forKey: .playlists)
        likedSongIDs = try values.decodeIfPresent([String].self, forKey: .likedSongIDs) ?? []
        clipRanges = try values.decodeIfPresent([MobileRemoteClipRange].self, forKey: .clipRanges) ?? []
    }
}

struct MobileSyncProfile: Codable, Hashable, Identifiable {
    let id: String
    var name: String
    let isDefault: Bool
    let songCount: Int
    let playlistCount: Int
    let likedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
        case songCount = "song_count"
        case playlistCount = "playlist_count"
        case likedCount = "liked_count"
    }

    init(
        id: String,
        name: String,
        isDefault: Bool = false,
        songCount: Int = 0,
        playlistCount: Int = 0,
        likedCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.songCount = songCount
        self.playlistCount = playlistCount
        self.likedCount = likedCount
    }
}

struct MobileSyncProfilesResponse: Codable {
    let defaultProfileID: String
    let profiles: [MobileSyncProfile]

    enum CodingKeys: String, CodingKey {
        case profiles
        case defaultProfileID = "default_profile_id"
    }
}

struct MobileRemoteSong: Identifiable, Decodable, Hashable, Sendable {
    let id: String
    let filename: String
    var title: String
    var artist: String
    var album: String
    let size: Int64
    let modifiedAt: String
    let contentType: String
    let downloadURL: String
    let streamURL: String
    var duration: TimeInterval?
    var artworkURL: URL?
    let contentSHA256: String?
    let sourceURL: String?
    let mediaKind: String
    let isSourceLinkRecord: Bool
    var isMetadataLoading: Bool

    enum CodingKeys: String, CodingKey {
        case id, filename, name, title, artist, album, size
        case modifiedAt = "modified_at"
        case modifiedUTC = "modified_utc"
        case contentType = "content_type"
        case downloadURL = "download_url"
        case streamURL = "stream_url"
        case durationSeconds = "duration_seconds"
        case duration
        case artworkURL = "artwork_url"
        case artwork
        case contentSHA256 = "content_sha256"
        case sourceURL = "source_url"
        case mediaKind = "media_kind"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        let decodedSourceURL = try values.decodeIfPresent(String.self, forKey: .sourceURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        sourceURL = decodedSourceURL.flatMap { $0.isEmpty ? nil : $0 }
        let declaredMediaKind = try values.decodeIfPresent(String.self, forKey: .mediaKind)
        let decodedSize = try values.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        isSourceLinkRecord = sourceURL != nil && (declaredMediaKind != nil || decodedSize == 0)
        let sourceFilename = sourceURL
            .flatMap(URL.init(string:))?
            .lastPathComponent
            .removingPercentEncoding
        let usefulSourceFilename = sourceFilename.flatMap { candidate in
            ["watch", "videoplayback"].contains(candidate.lowercased()) ? nil : candidate
        }
        filename = try values.decodeIfPresent(String.self, forKey: .filename)
            ?? values.decodeIfPresent(String.self, forKey: .name)
            ?? usefulSourceFilename.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Saved-\(id.prefix(8))"
        let decodedTitle = try values.decodeIfPresent(String.self, forKey: .title).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        let decodedArtist = try values.decodeIfPresent(String.self, forKey: .artist).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        title = decodedTitle
            ?? (isSourceLinkRecord ? "Resolving metadata…" : (filename as NSString).deletingPathExtension)
        artist = decodedArtist
            ?? (isSourceLinkRecord ? "On-device lookup" : "Unknown Artist")
        album = try values.decodeIfPresent(String.self, forKey: .album).flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
            ?? (isSourceLinkRecord ? "Link only" : "Server Library")
        size = decodedSize
        modifiedAt = try values.decodeIfPresent(String.self, forKey: .modifiedAt)
            ?? String(try values.decodeIfPresent(Int64.self, forKey: .modifiedUTC) ?? 0)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        mediaKind = declaredMediaKind == "video"
            || (declaredMediaKind == nil
                && (contentType.lowercased().hasPrefix("video/")
                    || ["mp4", "mov", "m4v", "webm"].contains(fileExtension)))
            ? "video"
            : "audio"
        downloadURL = try values.decode(String.self, forKey: .downloadURL)
        streamURL = try values.decode(String.self, forKey: .streamURL)
        let decodedDuration = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
            ?? values.decodeIfPresent(Double.self, forKey: .duration)
        duration = decodedDuration.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        let decodedArtworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
            ?? values.decodeIfPresent(String.self, forKey: .artwork)
        artworkURL = decodedArtworkURL.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }
        contentSHA256 = try values.decodeIfPresent(String.self, forKey: .contentSHA256)
        isMetadataLoading = isSourceLinkRecord && (decodedTitle == nil || decodedArtist == nil)
    }

    var durationText: String? {
        guard let duration else { return nil }
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    var requiresOriginalSourcePage: Bool {
        guard let sourceURL,
              let url = URL(string: sourceURL),
              let host = url.host?.lowercased() else { return false }
        return host == "googlevideo.com"
            || host.hasSuffix(".googlevideo.com")
            || url.lastPathComponent.lowercased() == "videoplayback"
    }
}

struct MobileRemoteCatalog: Decodable {
    let songs: [MobileRemoteSong]
    let count: Int
}

struct MobileRemoteSongMetadataCacheEntry: Codable, Equatable, Sendable {
    let sourceURL: String
    let mediaKind: String
    let metadata: LocalImportSpotifyTrack
    let cachedAt: Date
}

enum MobileRemoteSongMetadataCachePolicy {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let limit = 2_000

    static func key(sourceURL: String, mediaKind: String) -> String? {
        let source = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty,
              source.utf8.count <= 8_192,
              let url = URL(string: source),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        return "\(mediaKind == "video" ? "video" : "audio"):\(source)"
    }

    static func normalized(
        _ cache: [String: MobileRemoteSongMetadataCacheEntry],
        now: Date = Date()
    ) -> [String: MobileRemoteSongMetadataCacheEntry] {
        let cutoff = now.addingTimeInterval(-lifetime)
        let entries = cache.compactMap { storedKey, entry -> (String, MobileRemoteSongMetadataCacheEntry)? in
            guard entry.cachedAt >= cutoff,
                  entry.cachedAt <= now.addingTimeInterval(5 * 60),
                  !entry.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.metadata.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.metadata.title.utf8.count <= 512,
                  entry.metadata.artist.utf8.count <= 512,
                  let key = key(sourceURL: entry.sourceURL, mediaKind: entry.mediaKind),
                  key == storedKey else { return nil }
            return (key, entry)
        }
        .sorted { $0.1.cachedAt > $1.1.cachedAt }
        .prefix(limit)
        return Dictionary(uniqueKeysWithValues: entries)
    }
}

struct MobileProfileSyncState: Codable, Equatable {
    var playlists: [MobilePlaylist]
    var playlistRevision: Int
    var knownRemotePlaylistIDs: Set<UUID>
    var dirtyPlaylistIDs: Set<UUID>
    var deletedPlaylistIDs: Set<UUID>
    var playlistSyncServerURL: String?
    var remoteLikedSongIDs: Set<String>
    var dirtyRemoteLikeSongIDs: Set<String>
    var likesDirty: Bool
}

struct MobileStoredLibrary: Codable, Equatable {
    var tracks: [MobileTrack]
    var playlists: [MobilePlaylist]
    var favorites: Set<UUID>
    var serverURL: String
    var playlistRevision: Int?
    var knownRemotePlaylistIDs: Set<UUID>?
    var dirtyPlaylistIDs: Set<UUID>?
    var deletedPlaylistIDs: Set<UUID>?
    var playlistSyncServerURL: String?
    var syncProfileID: String?
    var syncProfileName: String?
    var remoteLikedSongIDs: Set<String>?
    var dirtyRemoteLikeSongIDs: Set<String>?
    var likesDirty: Bool?
    var clipRanges: [String: MobileClipRange]?
    var dirtyClipRangeKeys: Set<String>?
    var deletedClipRangeKeys: Set<String>?
    var profileStates: [MobileServerContext: MobileProfileSyncState]? = nil
    var playbackQueue: [UUID]? = nil
    var playbackPlaylistID: UUID? = nil
    var playbackSnapshot: MobilePlaybackSnapshot? = nil
    var transferFailures: [MobileTransferFailure]? = nil
    var completedMigrations: Set<String>? = nil
    var remoteSongMetadataCache: [String: MobileRemoteSongMetadataCacheEntry]? = nil
}

struct MobileLibraryNormalizationResult: Equatable {
    var tracks: [MobileTrack]
    var playlists: [MobilePlaylist]
    var repairedTrackIDs: Int
    var repairedRemoteAssociations: Int
    var repairedPlaylistIDs: Int

    var repairCount: Int {
        repairedTrackIDs + repairedRemoteAssociations + repairedPlaylistIDs
    }
}

enum MobileCollectionNormalization {
    static func normalize(
        tracks: [MobileTrack],
        playlists: [MobilePlaylist],
        fallbackServerURL: URL?
    ) -> MobileLibraryNormalizationResult {
        var normalizedTracks: [MobileTrack] = []
        var seenTrackIDs = Set<UUID>()
        var seenRemoteIdentities = Set<MobileRemoteIdentity>()
        var repairedTrackIDs = 0
        var repairedRemoteAssociations = 0

        for var track in tracks {
            while !seenTrackIDs.insert(track.id).inserted {
                track.id = UUID()
                repairedTrackIDs += 1
            }
            if let identity = track.remoteIdentity(fallbackServerURL: fallbackServerURL),
               !seenRemoteIdentities.insert(identity).inserted {
                track.remoteID = nil
                track.sourceServer = nil
                track.syncProfileID = nil
                repairedRemoteAssociations += 1
            }
            normalizedTracks.append(track)
        }

        var normalizedPlaylists: [MobilePlaylist] = []
        var seenPlaylistIDs = Set<UUID>()
        var hasSystemPlaylist = false
        var repairedPlaylistIDs = 0
        for var playlist in playlists {
            while !seenPlaylistIDs.insert(playlist.id).inserted {
                playlist.id = UUID()
                repairedPlaylistIDs += 1
            }
            if playlist.isSystem {
                if hasSystemPlaylist {
                    playlist.isSystem = false
                    playlist.name = playlist.name == "Liked Songs" ? "Recovered Liked Songs" : "Recovered \(playlist.name)"
                    repairedPlaylistIDs += 1
                } else {
                    hasSystemPlaylist = true
                }
            }
            normalizedPlaylists.append(playlist)
        }

        return MobileLibraryNormalizationResult(
            tracks: normalizedTracks,
            playlists: normalizedPlaylists,
            repairedTrackIDs: repairedTrackIDs,
            repairedRemoteAssociations: repairedRemoteAssociations,
            repairedPlaylistIDs: repairedPlaylistIDs
        )
    }

    static func uniqueRemoteSongs(_ songs: [MobileRemoteSong]) -> [MobileRemoteSong] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    static func uniqueRemotePlaylists(_ playlists: [MobileRemotePlaylist]) -> [MobileRemotePlaylist] {
        var seen = Set<UUID>()
        return playlists.filter { seen.insert($0.id).inserted }
    }
}

enum MobilePlaylistOrderPolicy {
    static func merge<Element: Hashable>(
        previous: [Element],
        ordered: [Element],
        preserving preserved: [Element]
    ) -> [Element] {
        let previous = unique(previous)
        let ordered = unique(ordered)
        let previousSet = Set(previous)
        let orderedSet = Set(ordered)
        let preservedSet = Set(unique(preserved).filter {
            previousSet.contains($0) && !orderedSet.contains($0)
        })
        var merged: [Element] = []
        var orderedIndex = ordered.startIndex

        for previousItem in previous {
            if preservedSet.contains(previousItem) {
                merged.append(previousItem)
            } else if orderedIndex < ordered.endIndex {
                merged.append(ordered[orderedIndex])
                ordered.formIndex(after: &orderedIndex)
            }
        }
        merged.append(contentsOf: ordered[orderedIndex...])
        return unique(merged)
    }

    private static func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum MobilePlaylistPresentationEntryID: Hashable {
    case local(UUID)
    case remote(String)

    var storageKey: String {
        switch self {
        case .local(let id):
            "local:\(id.uuidString.lowercased())"
        case .remote(let songID):
            "remote:\(songID)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("local:"),
           let id = UUID(uuidString: String(storageKey.dropFirst("local:".count))) {
            self = .local(id)
        } else if storageKey.hasPrefix("remote:"),
                  !storageKey.dropFirst("remote:".count).isEmpty {
            self = .remote(String(storageKey.dropFirst("remote:".count)))
        } else {
            return nil
        }
    }
}

struct MobileTransferDisplayState: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case download
        case upload

        var title: String {
            switch self {
            case .download: "Downloading"
            case .upload: "Uploading"
            }
        }

        var symbol: String {
            switch self {
            case .download: "arrow.down"
            case .upload: "arrow.up"
            }
        }
    }

    let kind: Kind
    let itemID: String
    let songTitle: String
    let detail: String
    let currentItem: Int
    let totalItems: Int
    let completedBytes: Int64
    let totalBytes: Int64
    let fallbackProgress: Double?

    var progress: Double? {
        MobileTransferDisplayPolicy.progress(
            completedBytes: completedBytes,
            totalBytes: totalBytes,
            fallbackProgress: fallbackProgress
        )
    }

    var batchPosition: String {
        guard totalItems > 0 else { return "0/0" }
        return "\(min(max(currentItem, 1), totalItems))/\(totalItems)"
    }
}

enum MobileTransferDisplayPolicy {
    static func progress(
        completedBytes: Int64,
        totalBytes: Int64,
        fallbackProgress: Double?
    ) -> Double? {
        // A known catalog or response size is not progress by itself. Keep
        // connection setup and source preparation indeterminate until the
        // downloader has actually received bytes.
        if completedBytes > 0, totalBytes > 0 {
            return min(max(Double(max(completedBytes, 0)) / Double(totalBytes), 0), 1)
        }
        guard let fallbackProgress, fallbackProgress.isFinite else { return nil }
        return min(max(fallbackProgress, 0), 1)
    }

    static func percentageLabel(_ progress: Double) -> String {
        let clamped = min(max(progress, 0), 1)
        return clamped > 0 && clamped < 0.01
            ? "<1%"
            : "\(Int(clamped * 100))%"
    }
}

/// Download reservations are intentionally invisible. A transfer card becomes
/// truthful only once the downloader has received media bytes. A terminal
/// update may keep an already-visible card alive, but cannot create one.
enum MobileDownloadTransferPresentationPolicy {
    static func shouldPresent(
        completedBytes: Int64,
        fallbackProgress: Double?,
        hasReceivedBytes: Bool = false
    ) -> Bool {
        if completedBytes > 0 { return true }
        guard let fallbackProgress, fallbackProgress.isFinite else { return false }
        return hasReceivedBytes && fallbackProgress > 0
    }

    static func shouldEndBytePresentation(for stage: LocalImportStage) -> Bool {
        stage != .downloading
    }
}

enum MobileLoadedCatalogDownloadPolicy {
    static func pendingSongs(
        from catalog: [MobileRemoteSong],
        requestedSongIDs: Set<String>?,
        syncedSongIDs: Set<String>
    ) -> [MobileRemoteSong] {
        catalog.filter { song in
            (requestedSongIDs.map { $0.contains(song.id) } ?? true)
                && !syncedSongIDs.contains(song.id)
        }
    }
}

enum MobileTransferByteProgressPolicy {
    static let minimumUpdateDelta: Int64 = 256 * 1_024

    static func shouldReport(
        completedBytes: Int64,
        lastReportedBytes: Int64,
        totalBytes: Int64
    ) -> Bool {
        guard completedBytes > lastReportedBytes else { return false }
        let delta = completedBytes.subtractingReportingOverflow(lastReportedBytes)
        return lastReportedBytes == 0
            || delta.overflow
            || delta.partialValue >= minimumUpdateDelta
            || (totalBytes > 0 && completedBytes >= totalBytes)
    }
}

enum MobileRemoteSourceMetadataReusePolicy {
    static func canReuseCatalogMetadata(
        isMetadataLoading: Bool,
        title: String,
        artist: String
    ) -> Bool {
        guard !isMetadataLoading else { return false }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty
            && !cleanArtist.isEmpty
            && cleanTitle.utf8.count <= 512
            && cleanArtist.utf8.count <= 512
    }

    static func knownTrack(for song: MobileRemoteSong) -> LocalImportSpotifyTrack? {
        guard canReuseCatalogMetadata(
            isMetadataLoading: song.isMetadataLoading,
            title: song.title,
            artist: song.artist
        ), let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !source.isEmpty else { return nil }
        let durationSeconds = song.duration.flatMap { duration -> Int? in
            guard duration.isFinite,
                  duration > 0,
                  duration < Double(Int.max) else { return nil }
            return Int(duration.rounded())
        }
        let album = song.album.trimmingCharacters(in: .whitespacesAndNewlines)
        return LocalImportSpotifyTrack(
            provider: "server",
            type: "track",
            trackID: song.id,
            title: song.title,
            artist: song.artist,
            album: album.isEmpty || album == "Link only" || album.utf8.count > 512 ? nil : album,
            trackNumber: nil,
            durationSeconds: durationSeconds,
            artworkURL: song.artworkURL?.absoluteString,
            embedURL: "",
            sourceURL: source
        )
    }

    /// Produces an acquisition seed from the catalog row without performing a
    /// provider metadata request. Direct YouTube and SoundCloud media lookup
    /// can start from the source URL alone; a hydrated Spotify row supplies the
    /// search terms needed to locate its audio counterpart.
    static func acquisitionTrack(for song: MobileRemoteSong) -> LocalImportSpotifyTrack? {
        if let known = knownTrack(for: song) { return known }
        guard let source = song.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else { return nil }
        let isDirectYouTube = (try? LocalImportURL.youtubeVideoID(source)) != nil
        guard LocalImportURL.isSoundCloud(source) || isDirectYouTube else { return nil }
        let filenameTitle = (song.filename as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = usefulAcquisitionValue(song.title, rejecting: ["Resolving metadata…"])
            ?? (filenameTitle.isEmpty ? "Saved song" : filenameTitle)
        let artist = usefulAcquisitionValue(
            song.artist,
            rejecting: ["On-device lookup", "Retrying automatically"]
        ) ?? "Unknown Artist"
        let album = usefulAcquisitionValue(song.album, rejecting: ["Link only"])
        let durationSeconds = song.duration.flatMap { duration -> Int? in
            guard duration.isFinite,
                  duration > 0,
                  duration < Double(Int.max) else { return nil }
            return Int(duration.rounded())
        }
        return LocalImportSpotifyTrack(
            provider: "server",
            type: "track",
            trackID: song.id,
            title: title,
            artist: artist,
            album: album,
            trackNumber: nil,
            durationSeconds: durationSeconds,
            artworkURL: song.artworkURL?.absoluteString,
            embedURL: "",
            sourceURL: source
        )
    }

    private static func usefulAcquisitionValue(
        _ value: String,
        rejecting placeholders: Set<String>
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 512,
              !placeholders.contains(trimmed) else { return nil }
        return trimmed
    }
}

struct MobileSourceImportFinalMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

/// Finishes a source import from values that are already available locally.
/// A still-running remote metadata request is never part of this decision: its
/// eventual result can update the saved track through the normal hydrator.
enum MobileSourceImportFinalMetadataPolicy {
    static func resolve(
        localTitle: String,
        localArtist: String,
        localAlbum: String,
        localDuration: TimeInterval,
        currentRemoteSong: MobileRemoteSong?
    ) -> MobileSourceImportFinalMetadata {
        guard let currentRemoteSong, !currentRemoteSong.isMetadataLoading else {
            return MobileSourceImportFinalMetadata(
                title: localTitle,
                artist: localArtist,
                album: localAlbum,
                duration: localDuration
            )
        }
        return MobileSourceImportFinalMetadata(
            title: useful(currentRemoteSong.title, fallback: localTitle),
            artist: useful(currentRemoteSong.artist, fallback: localArtist),
            album: useful(
                currentRemoteSong.album,
                fallback: localAlbum,
                rejecting: ["Link only"]
            ),
            duration: currentRemoteSong.duration ?? localDuration
        )
    }

    private static func useful(
        _ value: String,
        fallback: String,
        rejecting placeholders: Set<String> = []
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || placeholders.contains(trimmed) ? fallback : trimmed
    }
}

struct MobileRemoteSourceResolutionCacheKey: Hashable, Sendable {
    let context: MobileServerContext
    let accountScope: String?
    let mediaMode: LocalImportMediaMode
    let sourceURL: String
}

enum MobileRemoteSourceResolutionCachePolicy {
    static func key(
        context: MobileServerContext?,
        accountScope: String?,
        mediaKind: String,
        sourceURL: String?
    ) -> MobileRemoteSourceResolutionCacheKey? {
        guard let context,
              !context.profileID.isEmpty,
              let originURL = URL(string: context.origin),
              originURL.user == nil,
              originURL.password == nil,
              MobileServerEndpointPolicy.normalizedOrigin(of: originURL) != nil,
              let source = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty,
              source.utf8.count <= 8_192,
              let url = URL(string: source),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else { return nil }
        let scope = accountScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MobileRemoteSourceResolutionCacheKey(
            context: MobileServerEndpointPolicy.canonicalContext(context),
            accountScope: scope.flatMap { $0.isEmpty ? nil : $0 },
            mediaMode: LocalImportMediaMode(rawValue: mediaKind) ?? .audio,
            sourceURL: source
        )
    }

    static func canReuse(
        _ resolution: LocalImportResolution,
        cachedKey: MobileRemoteSourceResolutionCacheKey,
        expectedKey: MobileRemoteSourceResolutionCacheKey,
        knownCatalogMetadata: LocalImportSpotifyTrack?
    ) -> Bool {
        guard cachedKey == expectedKey,
              resolution.playlist == nil,
              !resolution.candidates.isEmpty else { return false }
        switch resolution.kind {
        case .spotifyPlaylist, .soundCloudPlaylist:
            return false
        case .spotify, .soundCloud, .youtube:
            break
        }
        guard let knownCatalogMetadata else { return true }
        guard knownCatalogMetadata.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
            == expectedKey.sourceURL else { return false }
        return resolution.track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            == knownCatalogMetadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
            && resolution.track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            == knownCatalogMetadata.artist.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MobileTransferSessionPolicy {
    static func canBegin(activeSessionID: UUID?) -> Bool {
        activeSessionID == nil
    }

    static func accepts(_ sessionID: UUID, activeSessionID: UUID?) -> Bool {
        sessionID == activeSessionID
    }

    static func acceptsOperation(
        sessionID: UUID,
        operationID: UUID,
        activeSessionID: UUID?,
        activeOperationID: UUID?
    ) -> Bool {
        accepts(sessionID, activeSessionID: activeSessionID)
            && operationID == activeOperationID
    }

    static func acceptsBytePresentation(
        operationID: UUID,
        activePresentationOperationID: UUID?
    ) -> Bool {
        operationID == activePresentationOperationID
    }
}

enum MobileBoundedDownloadCallbackPolicy {
    static func acceptsResponse(isFinished: Bool) -> Bool {
        !isFinished
    }
}

struct MobilePlaylistPresentationEntry: Identifiable, Hashable {
    let id: MobilePlaylistPresentationEntryID
    let track: MobileTrack?
    let remoteSongID: String?
    let remoteSong: MobileRemoteSong?

    var isDownloaded: Bool { track != nil }
    var title: String { track?.title ?? remoteSong?.title ?? "Unavailable song" }
    var artist: String { track?.artist ?? remoteSong?.artist ?? "Not downloaded on this device" }
    var album: String { track?.album ?? remoteSong?.album ?? "Server playlist" }
    var durationText: String { track?.durationText ?? remoteSong?.durationText ?? "—" }
}

struct MobilePlaylistPersistedOrder: Equatable {
    let trackIDs: [UUID]
    let remoteSongIDs: [String]
    let entryOrder: [String]
}

enum MobilePlaylistPresentationMovePolicy {
    static func move(
        _ entries: [MobilePlaylistPresentationEntry],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [MobilePlaylistPresentationEntry] {
        var reordered = entries
        let validOffsets = source.filter { reordered.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return entries }

        let movingEntries = validOffsets.map { reordered[$0] }
        for offset in validOffsets.reversed() {
            reordered.remove(at: offset)
        }
        let removedBeforeDestination = validOffsets.count { $0 < destination }
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), reordered.count)
        reordered.insert(contentsOf: movingEntries, at: insertionIndex)
        return reordered
    }

    static func persistedOrder(
        for entries: [MobilePlaylistPresentationEntry]
    ) -> MobilePlaylistPersistedOrder {
        MobilePlaylistPersistedOrder(
            trackIDs: entries.compactMap { $0.track?.id },
            remoteSongIDs: entries.compactMap(\.remoteSongID),
            entryOrder: entries.map { $0.id.storageKey }
        )
    }
}

struct MobileLocalTrackRemovalPlaylistResult: Equatable {
    let playlist: MobilePlaylist
    let remoteMembershipChanged: Bool
}

enum MobileLocalTrackRemoteBackingAuthority: Equatable {
    case unproven
    case confirmedPresent
    case confirmedAbsent
}

struct MobileLocalTrackRemovalRemoteBacking: Equatable {
    let remoteSongID: String?
    let authority: MobileLocalTrackRemoteBackingAuthority
}

enum MobileLocalTrackRemovalAuthorityPolicy {
    static func resolve(
        track: MobileTrack,
        activeContext: MobileServerContext?,
        catalogIsAuthoritative: Bool,
        catalogRemoteSongIDs: Set<String>
    ) -> MobileLocalTrackRemovalRemoteBacking {
        guard let remoteSongID = track.remoteID,
              let activeContext,
              track.remoteIdentity() == MobileRemoteIdentity(
                  context: activeContext,
                  remoteID: remoteSongID
              ) else {
            return MobileLocalTrackRemovalRemoteBacking(
                remoteSongID: nil,
                authority: .unproven
            )
        }
        guard catalogIsAuthoritative else {
            return MobileLocalTrackRemovalRemoteBacking(
                remoteSongID: remoteSongID,
                authority: .unproven
            )
        }
        return MobileLocalTrackRemovalRemoteBacking(
            remoteSongID: remoteSongID,
            authority: catalogRemoteSongIDs.contains(remoteSongID)
                ? .confirmedPresent
                : .confirmedAbsent
        )
    }
}

enum MobileLocalTrackRemovalPlaylistPolicy {
    static func removing(
        trackID: UUID,
        remoteSongID: String?,
        remoteBackingAuthority: MobileLocalTrackRemoteBackingAuthority,
        from playlist: MobilePlaylist,
        presentationOrder: [MobilePlaylistPresentationEntryID]
    ) -> MobileLocalTrackRemovalPlaylistResult {
        guard playlist.trackIDs.contains(trackID) else {
            return MobileLocalTrackRemovalPlaylistResult(
                playlist: playlist,
                remoteMembershipChanged: false
            )
        }

        var updated = playlist
        updated.trackIDs.removeAll { $0 == trackID }
        guard !playlist.isSystem else {
            return MobileLocalTrackRemovalPlaylistResult(
                playlist: updated,
                remoteMembershipChanged: false
            )
        }

        let previousRemoteIDs = playlist.remoteSongIDs
        let localEntry = MobilePlaylistPresentationEntryID.local(trackID)
        let storedOrder = playlist.entryOrder ?? presentationOrder.map(\.storageKey)
        guard let remoteSongID else {
            updated.entryOrder = removing(localEntry, from: storedOrder)
            return MobileLocalTrackRemovalPlaylistResult(
                playlist: updated,
                remoteMembershipChanged: false
            )
        }

        let remoteEntry = MobilePlaylistPresentationEntryID.remote(remoteSongID)
        switch remoteBackingAuthority {
        case .confirmedPresent:
            let promotedOrder = promoting(
                localEntry: localEntry,
                to: remoteEntry,
                in: storedOrder,
                appendIfMissing: true
            )
            updated.entryOrder = promotedOrder
            var remoteIDs = playlist.remoteSongIDs ?? []
            if !remoteIDs.contains(remoteSongID) {
                insert(
                    remoteSongID,
                    into: &remoteIDs,
                    followingOrder: promotedOrder
                )
            }
            updated.remoteSongIDs = remoteIDs
        case .unproven:
            // Without an authoritative catalog, deleting a local-only track
            // must neither create nor relocate server playlist membership.
            // Preserve any existing canonical remote token exactly as stored.
            updated.entryOrder = removing(localEntry, from: storedOrder)
        case .confirmedAbsent:
            if playlist.remoteSongIDs != nil {
                updated.remoteSongIDs?.removeAll { $0 == remoteSongID }
            }
            updated.entryOrder = removing(
                [localEntry, remoteEntry],
                from: storedOrder
            )
        }

        return MobileLocalTrackRemovalPlaylistResult(
            playlist: updated,
            remoteMembershipChanged: previousRemoteIDs != updated.remoteSongIDs
        )
    }

    private static func promoting(
        localEntry: MobilePlaylistPresentationEntryID,
        to remoteEntry: MobilePlaylistPresentationEntryID,
        in storedOrder: [String],
        appendIfMissing: Bool
    ) -> [String] {
        let hasLocalSlot = storedOrder.contains { entryID(for: $0) == localEntry }
        guard hasLocalSlot else {
            guard appendIfMissing,
                  !storedOrder.contains(where: { entryID(for: $0) == remoteEntry }) else {
                return storedOrder
            }
            return storedOrder + [remoteEntry.storageKey]
        }

        var insertedReplacement = false
        return storedOrder.compactMap { key in
            let id = entryID(for: key)
            if id == localEntry {
                guard !insertedReplacement else { return nil }
                insertedReplacement = true
                return remoteEntry.storageKey
            }
            if id == remoteEntry {
                // Prefer the exact legacy local slot over a reconciled remote
                // token elsewhere in the raw order.
                return nil
            }
            return key
        }
    }

    private static func insert(
        _ remoteSongID: String,
        into remoteIDs: inout [String],
        followingOrder storedOrder: [String]
    ) {
        let displayedRemoteIDs = unique(storedOrder.compactMap { key -> String? in
            guard let entry = entryID(for: key),
                  case .remote(let id) = entry else { return nil }
            return id
        })
        let displayedIndex = displayedRemoteIDs.firstIndex(of: remoteSongID) ?? displayedRemoteIDs.endIndex
        let precedingRemoteIDs = displayedRemoteIDs[..<displayedIndex]
        let insertionIndex = precedingRemoteIDs.reduce(into: 0) { count, id in
            if remoteIDs.contains(id) { count += 1 }
        }
        remoteIDs.insert(remoteSongID, at: min(insertionIndex, remoteIDs.count))
    }

    private static func removing(
        _ entry: MobilePlaylistPresentationEntryID,
        from storedOrder: [String]
    ) -> [String] {
        removing([entry], from: storedOrder)
    }

    private static func removing(
        _ entries: Set<MobilePlaylistPresentationEntryID>,
        from storedOrder: [String]
    ) -> [String] {
        storedOrder.filter { key in
            guard let id = entryID(for: key) else { return true }
            return !entries.contains(id)
        }
    }

    private static func entryID(for storageKey: String) -> MobilePlaylistPresentationEntryID? {
        MobilePlaylistPresentationEntryID(storageKey: storageKey)
    }

    private static func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum MobilePlaylistPresentationPolicy {
    static func entries(
        in playlist: MobilePlaylist,
        tracks: [MobileTrack],
        remoteSongs: [MobileRemoteSong]
    ) -> [MobilePlaylistPresentationEntry] {
        let tracksByID = tracks.reduce(into: [UUID: MobileTrack]()) { result, track in
            if result[track.id] == nil { result[track.id] = track }
        }
        let playlistTracks = playlist.trackIDs.compactMap { tracksByID[$0] }
        guard !playlist.isSystem, let remoteSongIDs = playlist.remoteSongIDs else {
            let entries = playlistTracks.map {
                MobilePlaylistPresentationEntry(
                    id: .local($0.id),
                    track: $0,
                    remoteSongID: nil,
                    remoteSong: nil
                )
            }
            return applyingStoredOrder(playlist.entryOrder, to: entries)
        }

        let orderedRemoteIDs = unique(remoteSongIDs)
        let remoteIDSet = Set(orderedRemoteIDs)
        var downloadedByRemoteID: [String: MobileTrack] = [:]
        let previousKeys: [MobilePlaylistPresentationEntryID] = playlistTracks.map { track in
            guard let remoteID = track.remoteID, remoteIDSet.contains(remoteID) else {
                return .local(track.id)
            }
            if downloadedByRemoteID[remoteID] == nil { downloadedByRemoteID[remoteID] = track }
            return .remote(remoteID)
        }
        let orderedKeys = orderedRemoteIDs.map(MobilePlaylistPresentationEntryID.remote)
        let preservedKeys = previousKeys.filter {
            if case .local = $0 { return true }
            return false
        }
        let remoteSongsByID = remoteSongs.reduce(into: [String: MobileRemoteSong]()) { result, song in
            if result[song.id] == nil { result[song.id] = song }
        }

        let entries = MobilePlaylistOrderPolicy.merge(
            previous: previousKeys,
            ordered: orderedKeys,
            preserving: preservedKeys
        ).compactMap { key in
            switch key {
            case .local(let trackID):
                guard let track = tracksByID[trackID] else { return nil }
                return MobilePlaylistPresentationEntry(
                    id: key,
                    track: track,
                    remoteSongID: nil,
                    remoteSong: nil
                )
            case .remote(let remoteID):
                return MobilePlaylistPresentationEntry(
                    id: key,
                    track: downloadedByRemoteID[remoteID],
                    remoteSongID: remoteID,
                    remoteSong: remoteSongsByID[remoteID]
                )
            }
        }
        return applyingStoredOrder(playlist.entryOrder, to: entries)
    }

    private static func applyingStoredOrder(
        _ storedOrder: [String]?,
        to entries: [MobilePlaylistPresentationEntry]
    ) -> [MobilePlaylistPresentationEntry] {
        guard let storedOrder, !storedOrder.isEmpty else { return entries }
        let entriesByID = entries.reduce(into: [MobilePlaylistPresentationEntryID: MobilePlaylistPresentationEntry]()) {
            if $0[$1.id] == nil { $0[$1.id] = $1 }
        }
        var seen = Set<MobilePlaylistPresentationEntryID>()
        var reconciled = storedOrder.compactMap { key -> MobilePlaylistPresentationEntry? in
            guard let id = MobilePlaylistPresentationEntryID(storageKey: key),
                  seen.insert(id).inserted else { return nil }
            return entriesByID[id]
        }
        reconciled.append(contentsOf: entries.filter { seen.insert($0.id).inserted })
        return reconciled
    }

    private static func unique<Element: Hashable>(_ values: [Element]) -> [Element] {
        var seen = Set<Element>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum MobileQueueCompletionPolicy {
    static func nextIndex(count: Int, currentIndex: Int) -> Int? {
        guard count > 0 else { return nil }
        return (max(currentIndex, -1) + 1) % count
    }
}

struct MobilePlaybackRestoreResult: Equatable {
    let queue: [UUID]
    let playlistID: UUID?
    let currentTrackID: UUID?
    let history: [UUID]

    init(
        queue: [UUID],
        playlistID: UUID?,
        currentTrackID: UUID?,
        history: [UUID] = []
    ) {
        self.queue = queue
        self.playlistID = playlistID
        self.currentTrackID = currentTrackID
        self.history = history
    }
}

struct MobilePlaybackQueueReference: Codable, Equatable {
    let trackID: UUID
    let remoteIdentity: MobileRemoteIdentity?
}

struct MobilePlaybackSnapshot: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let queue: [MobilePlaybackQueueReference]
    let playlistID: UUID?
    let currentTrack: MobilePlaybackQueueReference?
    let history: [MobilePlaybackQueueReference]?

    init(
        version: Int,
        queue: [MobilePlaybackQueueReference],
        playlistID: UUID?,
        currentTrack: MobilePlaybackQueueReference?,
        history: [MobilePlaybackQueueReference]? = nil
    ) {
        self.version = version
        self.queue = queue
        self.playlistID = playlistID
        self.currentTrack = currentTrack
        self.history = history
    }
}

enum MobilePlaybackSnapshotPolicy {
    static func restore(
        queue: [UUID],
        playlistID: UUID?,
        currentTrackID: UUID?,
        activeTrackIDs: Set<UUID>,
        playlistIDs: Set<UUID>
    ) -> MobilePlaybackRestoreResult {
        var seen = Set<UUID>()
        var restored = queue.filter { activeTrackIDs.contains($0) && seen.insert($0).inserted }
        if let currentTrackID,
           activeTrackIDs.contains(currentTrackID),
           !restored.contains(currentTrackID) {
            restored.insert(currentTrackID, at: 0)
        }
        let restoredPlaylistID = playlistID.flatMap { playlistIDs.contains($0) ? $0 : nil }
        return MobilePlaybackRestoreResult(
            queue: restored,
            playlistID: restored.isEmpty ? nil : restoredPlaylistID,
            currentTrackID: currentTrackID.flatMap { activeTrackIDs.contains($0) ? $0 : nil }
        )
    }

    static func restore(
        snapshot: MobilePlaybackSnapshot,
        tracks: [MobileTrack],
        activeTrackIDs: Set<UUID>,
        playlistIDs: Set<UUID>
    ) -> MobilePlaybackRestoreResult {
        guard (1...MobilePlaybackSnapshot.currentVersion).contains(snapshot.version) else {
            return MobilePlaybackRestoreResult(queue: [], playlistID: nil, currentTrackID: nil)
        }

        func resolvedID(for reference: MobilePlaybackQueueReference) -> UUID? {
            if activeTrackIDs.contains(reference.trackID),
               let track = tracks.first(where: { $0.id == reference.trackID }),
               reference.remoteIdentity == nil || track.remoteIdentity() == reference.remoteIdentity {
                return reference.trackID
            }
            guard let remoteIdentity = reference.remoteIdentity else { return nil }
            return tracks.first {
                activeTrackIDs.contains($0.id) && $0.remoteIdentity() == remoteIdentity
            }?.id
        }

        var seen = Set<UUID>()
        var queue = snapshot.queue.compactMap(resolvedID).filter { seen.insert($0).inserted }
        let currentTrackID = snapshot.currentTrack.flatMap(resolvedID)
        if let currentTrackID, !queue.contains(currentTrackID) {
            queue.insert(currentTrackID, at: 0)
        }
        let playlistID = snapshot.playlistID.flatMap { playlistIDs.contains($0) ? $0 : nil }
        return MobilePlaybackRestoreResult(
            queue: queue,
            playlistID: queue.isEmpty ? nil : playlistID,
            currentTrackID: currentTrackID,
            history: (snapshot.history ?? []).compactMap(resolvedID)
        )
    }
}

enum MobileStoredLibraryRecoverySource: Equatable {
    case primary
    case backup
    case empty
}

struct MobileStoredLibraryRecoveryResult: Equatable {
    let library: MobileStoredLibrary?
    let source: MobileStoredLibraryRecoverySource
    let primaryWasCorrupt: Bool
}

enum MobileStoredLibraryRecoveryPolicy {
    static func recover(primaryData: Data?, backupData: Data?) -> MobileStoredLibraryRecoveryResult {
        let decoder = JSONDecoder()
        if let primaryData,
           let library = try? decoder.decode(MobileStoredLibrary.self, from: primaryData) {
            return MobileStoredLibraryRecoveryResult(
                library: library,
                source: .primary,
                primaryWasCorrupt: false
            )
        }
        let primaryWasCorrupt = primaryData != nil
        if let backupData,
           let library = try? decoder.decode(MobileStoredLibrary.self, from: backupData) {
            return MobileStoredLibraryRecoveryResult(
                library: library,
                source: .backup,
                primaryWasCorrupt: primaryWasCorrupt
            )
        }
        return MobileStoredLibraryRecoveryResult(
            library: nil,
            source: .empty,
            primaryWasCorrupt: primaryWasCorrupt
        )
    }
}
