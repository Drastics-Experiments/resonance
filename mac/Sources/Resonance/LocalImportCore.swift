import Foundation

enum LocalImportMediaMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case audio
    case video

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fileExtension: String { self == .video ? "mp4" : "m4a" }
}

struct LocalImportServerConfiguration: Hashable, Sendable {
    let baseURL: URL
    let adminToken: String
    let profileID: String
    let clientContext: MacClientConfigContext
}

struct LocalImportTransferContext: Hashable, Sendable {
    let id: UUID
    let baseURL: URL?
    let adminToken: String?
    let profileID: String
    let profileName: String
    let uploadMode: MacUploadMode
    let rawSourceInput: String?
    let mediaMode: LocalImportMediaMode
    let requiresReviewedMatch: Bool
    let reservesUpload: Bool
}

enum LocalImportTransferContextError: LocalizedError {
    case serverBusy
    case missingUploadConfiguration
    case uploadModeUnavailable
    case unsupportedSourceLink
    case sourceLinkRequiresAudio
    case reviewedMatchRequired
    case contextChanged
    case remoteAssociationConflict

    var errorDescription: String? {
        switch self {
        case .serverBusy:
            "Wait for the current server transfer to finish."
        case .missingUploadConfiguration:
            "Sign in to your Resonance account or configure a legacy admin key before uploading."
        case .uploadModeUnavailable:
            "The selected upload mode is disabled by the verified server configuration. Choose an available mode and try again."
        case .unsupportedSourceLink:
            "Server source-link upload requires the exact original https://www.youtube.com/watch?v=… page typed into Import from Web. Short links, rewritten links, and discovered matches must use Reviewed match."
        case .sourceLinkRequiresAudio:
            "Server source-link import creates audio only. Choose Audio before uploading this source."
        case .reviewedMatchRequired:
            "This discovered source can only be uploaded in Reviewed match mode after you select it explicitly."
        case .contextChanged:
            "The server or profile changed while the import was running."
        case .remoteAssociationConflict:
            "This song is already linked to another server or profile. Switch back to that server and profile, or import a separate local copy before uploading here."
        }
    }
}

struct LocalImportSpotifyTrack: Codable, Hashable, Sendable {
    let provider: String
    let type: String
    let trackID: String
    let title: String
    let artist: String
    let album: String?
    let trackNumber: Int?
    let durationSeconds: Int?
    let artworkURL: String?
    let embedURL: String
    let sourceURL: String
}

struct LocalImportAudioSourceMatch: Codable, Hashable, Identifiable, Sendable {
    enum Provider: String, Codable, Hashable, Sendable {
        case youtubeMusic = "youtube_music"
        case youtube
        case soundcloud
    }

    struct MatchDetails: Codable, Hashable, Sendable {
        let title: Double
        let artist: Double
        let album: Double?
        let duration: Double?
        let durationDeltaSeconds: Int?
    }

    var id: String { videoID }
    let videoID: String
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?
    let thumbnailURL: String?
    let sourceProvider: Provider
    let officialArtist: Bool
    let sourceURL: String
    let score: Double
    let confidence: String
    let match: MatchDetails
}

struct LocalImportDebridRelease: Codable, Hashable, Identifiable, Sendable {
    var id: String { infoHash }
    let title: String
    let infoHash: String
    let magnetLink: String
    let size: Int64?
    let seeders: Int?
    let leechers: Int?
    let indexer: String?
    let uploadDate: String?
    let quality: String?
}

struct LocalImportYouTubePreview: Codable, Hashable, Sendable {
    let videoID: String
    let title: String
    let author: String?
    let durationSeconds: Int?
    let thumbnailURL: String?
    let itag: Int
    let contentLength: Int64
    let contentType: String
    let sourceURL: String
}

struct LocalImportMetadata: Codable, Hashable, Sendable {
    var title: String
    var artist: String
    var album: String?
    var artworkURL: String?
    var sourceURL: String
}

struct LocalImportResolution: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case spotify
        case spotifyPlaylist
        case soundCloud
        case soundCloudPlaylist
        case youtube
        case youtubePlaylist
    }

    let kind: Kind
    let track: LocalImportSpotifyTrack
    let candidates: [LocalImportAudioSourceMatch]
    let reviewCandidateVideoIDs: Set<String>
    let releases: [LocalImportDebridRelease]
    let playlist: LocalImportPlaylist?

    init(
        kind: Kind,
        track: LocalImportSpotifyTrack,
        candidates: [LocalImportAudioSourceMatch],
        reviewCandidateVideoIDs: Set<String> = [],
        releases: [LocalImportDebridRelease],
        playlist: LocalImportPlaylist? = nil
    ) {
        self.kind = kind
        self.track = track
        self.candidates = candidates
        self.reviewCandidateVideoIDs = reviewCandidateVideoIDs
        self.releases = releases
        self.playlist = playlist
    }
}

struct LocalImportPlaylistItem: Hashable, Identifiable, Sendable {
    var id: String { track.trackID }
    let position: Int
    let track: LocalImportSpotifyTrack
    let candidate: LocalImportAudioSourceMatch
    let fallbackCandidates: [LocalImportAudioSourceMatch]

    init(
        position: Int,
        track: LocalImportSpotifyTrack,
        candidate: LocalImportAudioSourceMatch,
        fallbackCandidates: [LocalImportAudioSourceMatch] = []
    ) {
        self.position = position
        self.track = track
        self.candidate = candidate
        self.fallbackCandidates = fallbackCandidates.filter { $0.videoID != candidate.videoID }
    }

    var downloadCandidates: [LocalImportAudioSourceMatch] {
        [candidate] + fallbackCandidates
    }
}

struct LocalImportPlaylistSkippedItem: Hashable, Identifiable, Sendable {
    var id: Int { position }
    let position: Int
    let title: String
    let artist: String?
    let reason: String
}

struct LocalImportPlaylist: Hashable, Sendable {
    let playlistID: String
    let title: String
    let author: String
    let artworkURL: String?
    let sourceURL: String
    let items: [LocalImportPlaylistItem]
    let skippedItems: [LocalImportPlaylistSkippedItem]
    let truncated: Bool

    var unavailableCount: Int { skippedItems.count }
}

enum LocalImportPlaylistLimitPolicy {
    static let maxItems = 500
    static let maxContinuations = 10

    struct PageResult {
        let tracks: [LocalImportSpotifyTrack]
        let overflowed: Bool
    }

    static func takeInitial(_ tracks: [LocalImportSpotifyTrack]) -> PageResult {
        let limited = Array(tracks.prefix(maxItems))
        return PageResult(tracks: limited, overflowed: tracks.count > limited.count)
    }

    static func append(
        existing: [LocalImportSpotifyTrack],
        incoming: [LocalImportSpotifyTrack]
    ) -> PageResult {
        var seenTrackIDs = Set(existing.map(\.trackID))
        let unique = incoming.filter { seenTrackIDs.insert($0.trackID).inserted }
        let remaining = max(maxItems - existing.count, 0)
        return PageResult(
            tracks: Array(unique.prefix(remaining)),
            overflowed: unique.count > remaining
        )
    }

    static func hasRemainingContinuation(_ continuation: String?) -> Bool {
        continuation != nil
    }
}

struct LocalImportExistingSongMatch: Equatable {
    let deviceTrackID: UUID?
    let serverSongID: String?

    var isOnDevice: Bool { deviceTrackID != nil }
    var isOnServer: Bool { serverSongID != nil }
}

enum LocalImportExistingSongPolicy {
    static func match(
        spotifyTrack: LocalImportSpotifyTrack,
        deviceTracks: [Track],
        activeServerSongs: [RemoteSong],
        fileManager: FileManager = .default
    ) -> LocalImportExistingSongMatch {
        let deviceTrack = deviceTracks.first { candidate in
            guard let fileURL = candidate.fileURL,
                  fileManager.fileExists(atPath: fileURL.path) else { return false }
            if let expectedSpotifyID = spotifyTrackID(spotifyTrack.sourceURL),
               spotifyTrackID(candidate.sourceURL) == expectedSpotifyID {
                return true
            }
            return metadataMatches(
                expectedTitle: spotifyTrack.title,
                expectedArtist: spotifyTrack.artist,
                expectedDuration: spotifyTrack.durationSeconds.map(Double.init),
                actualTitle: candidate.title,
                actualArtist: candidate.artist,
                actualDuration: candidate.duration
            )
        }

        let serverSong = deviceTrack?.remoteID.flatMap { remoteID in
            activeServerSongs.first { $0.id == remoteID }
        } ?? activeServerSongs.first { candidate in
            metadataMatches(
                expectedTitle: spotifyTrack.title,
                expectedArtist: spotifyTrack.artist,
                expectedDuration: spotifyTrack.durationSeconds.map(Double.init),
                actualTitle: candidate.title,
                actualArtist: candidate.artist,
                actualDuration: candidate.durationSeconds
            )
        }

        return LocalImportExistingSongMatch(
            deviceTrackID: deviceTrack?.id,
            serverSongID: serverSong?.id
        )
    }

    private static func metadataMatches(
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: Double?,
        actualTitle: String,
        actualArtist: String,
        actualDuration: Double?
    ) -> Bool {
        ServerSongIdentityPolicy.metadataMatches(
            expectedTitle: expectedTitle,
            expectedArtist: expectedArtist,
            expectedDuration: expectedDuration,
            actualTitle: actualTitle,
            actualArtist: actualArtist,
            actualDuration: actualDuration
        )
    }

    private static func spotifyTrackID(_ value: String?) -> String? {
        guard let value else { return nil }
        return try? LocalImportURL.spotifyTrack(value)?.trackID
    }
}

struct LocalImportPreviewStream: Hashable, Sendable {
    let url: URL
    let httpHeaders: [String: String]
    let contentLength: Int64?
    let contentType: String?

    init(
        url: URL,
        httpHeaders: [String: String],
        contentLength: Int64? = nil,
        contentType: String? = nil
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.contentLength = contentLength
        self.contentType = contentType
    }
}

struct LocalImportedAudio: Hashable, Sendable {
    let fileURL: URL
    let metadata: LocalImportMetadata
    let duration: TimeInterval
    let artworkData: Data?
    var downloadSourceURL: URL? = nil
    let sourceSHA256: String
    let contentSHA256: String
    var mediaMode: LocalImportMediaMode = .audio
}

struct LocalImportSourceAssociation: Hashable, Sendable {
    let sourceURL: String
    let downloadSourceURL: URL?
}

enum LocalImportOutcome: Hashable, Sendable {
    case created(LocalImportedAudio)
    case duplicate(UUID, source: LocalImportSourceAssociation)
}

enum LocalImportStage: String, Codable, Hashable, Sendable {
    case idle
    case resolvingMetadata = "resolving_metadata"
    case searchingCandidates = "searching_candidates"
    case awaitingSelection = "awaiting_selection"
    case inspectingSource = "inspecting_source"
    case downloading
    case processing
    case savingLocal = "saving_local"
    case localComplete = "local_complete"
    case syncing
    case complete
    case failed
    case cancelled
}

struct LocalImportProgress: Hashable, Sendable {
    let stage: LocalImportStage
    var completed: Int64 = 0
    var total: Int64 = 0
}

struct LocalImportError: LocalizedError, Hashable, Sendable {
    let stage: LocalImportStage
    let code: String
    let message: String
    var retryAfter: String?

    var errorDescription: String? { message }
}

enum LocalImportURL {
    private static let spotifyID = try! NSRegularExpression(pattern: "^[A-Za-z0-9]{22}$")
    private static let youtubeID = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{11}$")
    // YouTube playlist IDs are opaque, but public playlist URLs currently use
    // the same URL-safe alphabet as video IDs and are at least ten characters
    // long. Keep the upper bound deliberately small so a pasted query cannot
    // turn into an unbounded provider request.
    private static let youtubePlaylistID = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{10,150}$")
    private static let spotifyHosts = Set(["open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link"])
    private static let youtubeHosts = Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"])
    private static let youtubeEmbedHosts = Set(["youtube-nocookie.com", "www.youtube-nocookie.com"])
    private static let debridVaultHost = "debridvault.elfhosted.com"

    static func isSpotify(_ value: String) -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return false }
        return spotifyHosts.contains(host)
    }

    static func spotifySource(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8_192,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              spotifyHosts.contains(host),
              let url = components.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "INVALID_SPOTIFY_URL", message: "Source must be a Spotify track or playlist URL.")
        }
        return url
    }

    static func spotifyTrack(_ value: String) throws -> (url: URL, trackID: String)? {
        let source = try spotifySource(value)
        guard ["open.spotify.com", "www.open.spotify.com"].contains(source.host?.lowercased() ?? "") else { return nil }
        var segments = source.pathComponents.filter { $0 != "/" }
        if segments.first?.hasPrefix("intl-") == true { segments.removeFirst() }
        if segments.first == "playlist" { return nil }
        guard segments.count == 2, segments[0] == "track", matches(spotifyID, segments[1]) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SPOTIFY_RESOURCE",
                message: "Only Spotify track and playlist links are supported."
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "open.spotify.com"
        components.path = "/track/\(segments[1])"
        guard let canonical = components.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "INVALID_SPOTIFY_URL", message: "Source must be a Spotify track or playlist URL.")
        }
        return (canonical, segments[1])
    }

    static func spotifyPlaylist(_ value: String) throws -> (url: URL, playlistID: String)? {
        let source = try spotifySource(value)
        guard ["open.spotify.com", "www.open.spotify.com"].contains(source.host?.lowercased() ?? "") else { return nil }
        var segments = source.pathComponents.filter { $0 != "/" }
        if segments.first?.hasPrefix("intl-") == true { segments.removeFirst() }
        if segments.first == "track" { return nil }
        guard segments.count == 2, segments[0] == "playlist", matches(spotifyID, segments[1]) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SPOTIFY_RESOURCE",
                message: "Only Spotify track and playlist links are supported."
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "open.spotify.com"
        components.path = "/playlist/\(segments[1])"
        guard let canonical = components.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "INVALID_SPOTIFY_URL", message: "Source must be a Spotify track or playlist URL.")
        }
        return (canonical, segments[1])
    }

    static func spotifyTrackID(fromURI value: String) -> String? {
        let prefix = "spotify:track:"
        guard value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        return matches(spotifyID, id) ? id : nil
    }

    /// Returns the playlist ID for a supported YouTube collection URL.
    ///
    /// A watch URL with both `v` and `list` is treated as a playlist import;
    /// this matches YouTube's own share links and avoids silently downloading
    /// only the currently selected video.
    static func youtubePlaylistID(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8_192,
              let components = URLComponents(string: trimmed) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_SOURCE",
                message: "Enter a Spotify, SoundCloud, or supported YouTube link."
            )
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard components.user == nil, components.password == nil else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "SOURCE_HAS_CREDENTIALS",
                message: "Source URLs cannot contain credentials."
            )
        }
        guard let host = components.host?.lowercased(),
              youtubeHosts.contains(host) || host == "youtu.be" || host == "www.youtu.be" else {
            return nil
        }
        guard let playlistID = components.queryItems?.first(where: { $0.name == "list" })?.value else {
            return nil
        }
        guard matches(youtubePlaylistID, playlistID) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_YOUTUBE_PLAYLIST",
                message: "The YouTube playlist URL is invalid."
            )
        }
        return playlistID
    }

    static func youtubeVideoID(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8_192, let components = URLComponents(string: trimmed) else {
            throw LocalImportError(stage: .inspectingSource, code: "INVALID_SOURCE", message: "Enter a Spotify track or YouTube video URL.")
        }
        guard components.scheme?.lowercased() == "https" else { return nil }
        guard components.user == nil, components.password == nil else {
            throw LocalImportError(stage: .inspectingSource, code: "SOURCE_HAS_CREDENTIALS", message: "Source URLs cannot contain credentials.")
        }
        if components.queryItems?.contains(where: { $0.name == "list" }) == true {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "UNSUPPORTED_YOUTUBE_COLLECTION",
                message: "Only individual YouTube videos are supported; playlists and channels are not."
            )
        }
        guard let host = components.host?.lowercased() else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        let candidate: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            candidate = segments.first
        } else if youtubeHosts.contains(host) {
            if components.path == "/watch" {
                candidate = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if ["embed", "live", "shorts"].contains(segments.first ?? "") {
                candidate = segments.count > 1 ? segments[1] : nil
            } else {
                candidate = nil
            }
        } else if youtubeEmbedHosts.contains(host), segments.first == "embed" {
            candidate = segments.count > 1 ? segments[1] : nil
        } else {
            return nil
        }
        guard let candidate, matches(youtubeID, candidate) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_YOUTUBE_VIDEO",
                message: "Source must identify one YouTube video; playlists and channel URLs are not supported."
            )
        }
        return candidate
    }

    static func spotifyArtwork(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "scdn.co" || host.hasSuffix(".scdn.co") || host == "spotifycdn.com" || host.hasSuffix(".spotifycdn.com")
        else { return nil }
        return components.url
    }

    static func youtubeArtwork(_ value: String?) -> URL? {
        guard let value, let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "ytimg.com" || host.hasSuffix(".ytimg.com") || host == "ggpht.com" || host.hasSuffix(".ggpht.com")
        else { return nil }
        return components.url
    }

    static func isYouTubeDocument(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else { return false }
        return youtubeHosts.contains(host) || youtubeEmbedHosts.contains(host)
    }

    static func isGoogleVideo(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    static func isDebridVaultDocument(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.host?.lowercased() == debridVaultHost else { return false }
        return true
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}

enum LocalImportArtworkPolicy {
    static func highestQualityYouTubeThumbnail(_ values: [[String: Any]]) -> String? {
        values.enumerated()
            .sorted { left, right in
                let leftSize = dimensions(left.element)
                let rightSize = dimensions(right.element)
                let leftArea = leftSize.width * leftSize.height
                let rightArea = rightSize.width * rightSize.height
                if leftArea != rightArea { return leftArea > rightArea }
                let leftEdge = max(leftSize.width, leftSize.height)
                let rightEdge = max(rightSize.width, rightSize.height)
                if leftEdge != rightEdge { return leftEdge > rightEdge }
                // YouTube normally sends thumbnails from smallest to largest. Keep
                // that useful ordering as the tie-breaker when dimensions are absent.
                return left.offset > right.offset
            }
            .compactMap { LocalImportURL.youtubeArtwork($0.element["url"] as? String)?.absoluteString }
            .first
    }

    static func preferredArtwork(metadataURL: String?, resolvedYouTubeURL: String?) -> String? {
        if LocalImportURL.youtubeArtwork(metadataURL) != nil {
            return LocalImportURL.youtubeArtwork(resolvedYouTubeURL)?.absoluteString ?? metadataURL
        }
        return metadataURL ?? LocalImportURL.youtubeArtwork(resolvedYouTubeURL)?.absoluteString
    }

    private static func dimensions(_ value: [String: Any]) -> (width: Int64, height: Int64) {
        (dimension(value["width"]), dimension(value["height"]))
    }

    private static func dimension(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return min(max(number.int64Value, 0), 1_000_000) }
        if let string = value as? String, let number = Int64(string) { return min(max(number, 0), 1_000_000) }
        return 0
    }
}

enum LocalImportParser {
    static func debridVaultReleases(_ data: Data) throws -> [LocalImportDebridRelease] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let values = root["data"] as? [[String: Any]] else {
            throw LocalImportError(
                stage: .searchingCandidates,
                code: "DEBRID_VAULT_INVALID_SEARCH",
                message: "Debrid Vault returned an invalid release search."
            )
        }

        var seen = Set<String>()
        return values.compactMap { value in
            guard let title = cleanProviderText(value["title"] as? String, maxLength: 1_000),
                  let rawHash = clean(value["infoHash"] as? String, maxLength: 40) else { return nil }
            let infoHash = rawHash.lowercased()
            guard infoHash.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
                  let magnetLink = clean(value["magnetLink"] as? String, maxLength: 8_192),
                  magnetLink.lowercased().hasPrefix("magnet:?xt=urn:btih:\(infoHash)"),
                  seen.insert(infoHash).inserted else { return nil }
            return LocalImportDebridRelease(
                title: title,
                infoHash: infoHash,
                magnetLink: magnetLink,
                size: nonnegativeInt64(value["size"]),
                seeders: nonnegativeInt(value["seeders"]),
                leechers: nonnegativeInt(value["leechers"]),
                indexer: cleanProviderText(value["indexer"] as? String),
                uploadDate: clean(value["uploadDate"] as? String, maxLength: 128),
                quality: cleanProviderText(value["quality"] as? String, maxLength: 128)
            )
        }
        .prefix(40)
        .map { $0 }
    }

    static func spotifyOEmbed(_ data: Data, expectedTrackID: String) throws -> (title: String, artworkURL: String?, embedURL: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider_name"] as? String == "Spotify",
              object["type"] as? String == "rich",
              let title = clean(object["title"] as? String),
              let html = object["html"] as? String,
              html.count <= 8_192,
              let srcRange = html.range(of: #"src="([^"]+)""#, options: .regularExpression) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid track preview.")
        }
        let sourceFragment = String(html[srcRange])
        guard let firstQuote = sourceFragment.firstIndex(of: "\""),
              let lastQuote = sourceFragment.lastIndex(of: "\""), firstQuote < lastQuote else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid track preview.")
        }
        let raw = String(sourceFragment[sourceFragment.index(after: firstQuote)..<lastQuote]).replacingOccurrences(of: "&amp;", with: "&")
        guard var components = URLComponents(string: raw),
              components.scheme == "https",
              components.host == "open.spotify.com" else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned a mismatched track preview.")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let embedIndex = segments.firstIndex(of: "embed"),
              segments.indices.contains(embedIndex + 2),
              segments[embedIndex + 1] == "track",
              segments[embedIndex + 2] == expectedTrackID else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned a mismatched track preview.")
        }
        components.query = nil
        components.fragment = nil
        guard let embedURL = components.url?.absoluteString else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid track preview.")
        }
        return (title, LocalImportURL.spotifyArtwork(object["thumbnail_url"] as? String)?.absoluteString, embedURL)
    }

    static func spotifyPlaylistOEmbed(_ data: Data, expectedPlaylistID: String) throws -> (title: String, artworkURL: String?, embedURL: String) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["provider_name"] as? String == "Spotify",
              object["type"] as? String == "rich",
              let title = clean(object["title"] as? String),
              let html = object["html"] as? String,
              html.count <= 8_192,
              let srcRange = html.range(of: #"src="([^"]+)""#, options: .regularExpression) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        let sourceFragment = String(html[srcRange])
        guard let firstQuote = sourceFragment.firstIndex(of: "\""),
              let lastQuote = sourceFragment.lastIndex(of: "\""), firstQuote < lastQuote else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        let raw = String(sourceFragment[sourceFragment.index(after: firstQuote)..<lastQuote]).replacingOccurrences(of: "&amp;", with: "&")
        guard var components = URLComponents(string: raw),
              components.scheme == "https",
              components.host == "open.spotify.com" else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned a mismatched playlist preview.")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let embedIndex = segments.firstIndex(of: "embed"),
              segments.indices.contains(embedIndex + 2),
              segments[embedIndex + 1] == "playlist",
              segments[embedIndex + 2] == expectedPlaylistID else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned a mismatched playlist preview.")
        }
        components.query = nil
        components.fragment = nil
        guard let embedURL = components.url?.absoluteString else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        return (title, LocalImportURL.spotifyArtwork(object["thumbnail_url"] as? String)?.absoluteString, embedURL)
    }

    static func spotifyEmbed(_ html: String, expectedTrackID: String) throws -> (title: String, artist: String, durationSeconds: Int?, artworkURL: String?) {
        guard let script = scriptContents(id: "__NEXT_DATA__", html: html),
              let root = try? JSONSerialization.jsonObject(with: Data(script.utf8)) as? [String: Any],
              let entity = nested(root, ["props", "pageProps", "state", "data", "entity"]) as? [String: Any],
              entity["type"] as? String == "track",
              entity["id"] as? String == expectedTrackID,
              let title = clean(entity["title"] as? String),
              let artistObjects = entity["artists"] as? [[String: Any]] else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned mismatched track metadata.")
        }
        let artists = artistObjects.compactMap { clean($0["name"] as? String) }
        guard !artists.isEmpty else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INCOMPLETE_METADATA", message: "Spotify returned incomplete track metadata.")
        }
        let images = nested(entity, ["visualIdentity", "image"]) as? [[String: Any]]
        let artwork = images?
            .sorted { number($0["maxWidth"]) > number($1["maxWidth"]) }
            .compactMap { LocalImportURL.spotifyArtwork($0["url"] as? String)?.absoluteString }
            .first
        let milliseconds = number(entity["duration"])
        return (title, artists.joined(separator: ", "), milliseconds > 0 ? Int((milliseconds / 1_000).rounded()) : nil, artwork)
    }

    static func spotifyPlaylistEmbed(
        _ html: String,
        expectedPlaylistID: String
    ) throws -> (title: String, author: String, artworkURL: String?, tracks: [LocalImportSpotifyTrack], skippedItems: [LocalImportPlaylistSkippedItem]) {
        guard let script = scriptContents(id: "__NEXT_DATA__", html: html),
              let root = try? JSONSerialization.jsonObject(with: Data(script.utf8)) as? [String: Any],
              let entity = nested(root, ["props", "pageProps", "state", "data", "entity"]) as? [String: Any],
              entity["type"] as? String == "playlist",
              entity["id"] as? String == expectedPlaylistID,
              let title = clean(entity["title"] as? String) ?? clean(entity["name"] as? String),
              let trackList = entity["trackList"] as? [[String: Any]] else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned mismatched playlist metadata.")
        }
        let author = clean(entity["subtitle"] as? String) ?? "Spotify"
        let coverSources = nested(entity, ["coverArt", "sources"]) as? [[String: Any]]
        let visualSources = nested(entity, ["visualIdentity", "image"]) as? [[String: Any]]
        let artwork = (coverSources ?? visualSources)?
            .sorted { max(number($0["width"]), number($0["maxWidth"])) > max(number($1["width"]), number($1["maxWidth"])) }
            .compactMap { LocalImportURL.spotifyArtwork($0["url"] as? String)?.absoluteString }
            .first
        var tracks: [LocalImportSpotifyTrack] = []
        var skippedItems: [LocalImportPlaylistSkippedItem] = []
        for (index, item) in trackList.enumerated() {
            let position = index + 1
            let itemTitle = clean(item["title"] as? String)
            let artist = clean(item["subtitle"] as? String)
            let skippedTitle = itemTitle ?? "Unavailable item"
            let appendSkipped: (String) -> Void = { reason in
                skippedItems.append(.init(
                    position: position,
                    title: skippedTitle,
                    artist: artist,
                    reason: reason
                ))
            }
            guard item["entityType"] as? String == "track" else {
                appendSkipped("Not a Spotify song")
                continue
            }
            guard item["isPlayable"] as? Bool != false else {
                appendSkipped("Unavailable on Spotify")
                continue
            }
            guard let trackID = (item["uri"] as? String).flatMap({ LocalImportURL.spotifyTrackID(fromURI: $0) }) else {
                appendSkipped("Missing a public Spotify track link")
                continue
            }
            guard let itemTitle else {
                appendSkipped("Missing title metadata")
                continue
            }
            guard let artist else {
                appendSkipped("Missing artist metadata")
                continue
            }
            let milliseconds = number(item["duration"])
            tracks.append(LocalImportSpotifyTrack(
                provider: "spotify",
                type: "track",
                trackID: trackID,
                title: itemTitle,
                artist: artist,
                album: nil,
                trackNumber: index + 1,
                durationSeconds: milliseconds > 0 ? Int((milliseconds / 1_000).rounded()) : nil,
                // Spotify's playlist embed does not include per-track artwork.
                // Keep the playlist cover on the playlist and hydrate each song
                // from its own track oEmbed response in the service layer.
                artworkURL: nil,
                embedURL: "https://open.spotify.com/embed/track/\(trackID)",
                sourceURL: "https://open.spotify.com/track/\(trackID)"
            ))
        }
        guard !tracks.isEmpty else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_PLAYLIST_EMPTY", message: "This Spotify playlist has no public, playable tracks.")
        }
        return (title, author, artwork, tracks, skippedItems)
    }

    static func youtubeMusicSearch(_ html: String) -> [LocalImportSearchCandidate] {
        guard let root = youtubeInitialData(html) else { return [] }
        var output: [LocalImportSearchCandidate] = []
        walk(root) { object in
            guard let renderer = object["musicResponsiveListItemRenderer"] as? [String: Any],
                  let candidate = musicCandidate(renderer) else { return }
            output.append(candidate)
        }
        return output
    }

    static func youtubeWebSearch(_ html: String) -> [LocalImportSearchCandidate] {
        guard let root = youtubeInitialData(html) else { return [] }
        var output: [LocalImportSearchCandidate] = []
        walk(root) { object in
            guard let renderer = object["videoRenderer"] as? [String: Any],
                  let candidate = webCandidate(renderer) else { return }
            output.append(candidate)
        }
        return output
    }

    /// Parses one page of YouTube playlist browse data. YouTube has shipped
    /// several playlist renderer shapes over time, so this intentionally walks
    /// the complete response instead of depending on one tab/section path.
    /// Continuation responses use the same renderer shape as the initial page.
    static func youtubePlaylistData(
        _ value: Any,
        expectedPlaylistID: String,
        positionOffset: Int = 0
    ) throws -> (
        title: String?,
        author: String?,
        artworkURL: String?,
        tracks: [LocalImportSpotifyTrack],
        skippedItems: [LocalImportPlaylistSkippedItem],
        continuation: String?,
        lastPlaylistPosition: Int
    ) {
        var title: String?
        var author: String?
        var artworkURL: String?
        var tracks: [LocalImportSpotifyTrack] = []
        var skippedItems: [LocalImportPlaylistSkippedItem] = []
        var continuation: String?
        var mismatchedPlaylist = false
        var seenTrackIDs = Set<String>()
        // The cursor is based on source rows, not successful/unique tracks.
        // Continuation pages can contain unavailable rows and duplicates, and
        // those rows still occupy positions in the provider playlist.
        var lastPlaylistPosition = max(positionOffset, 0)

        walk(value) { object in
            if let metadata = object["playlistMetadataRenderer"] as? [String: Any] {
                if let playlistID = clean(metadata["playlistId"] as? String),
                   playlistID != expectedPlaylistID {
                    mismatchedPlaylist = true
                }
                title = title ?? rendererText(metadata["title"])
                    ?? clean(metadata["title"] as? String)
            }

            if let header = object["playlistHeaderRenderer"] as? [String: Any] {
                if let playlistID = clean(header["playlistId"] as? String),
                   playlistID != expectedPlaylistID {
                    mismatchedPlaylist = true
                }
                title = title ?? rendererText(header["title"])
                author = author
                    ?? rendererText(header["ownerText"])
                    ?? rendererText(header["bylineText"])
                    ?? rendererText(header["subtitle"])
            }

            if let sidebar = object["playlistSidebarPrimaryInfoRenderer"] as? [String: Any] {
                title = title ?? rendererText(sidebar["title"])
                artworkURL = artworkURL ?? youtubePlaylistThumbnail(sidebar)
            }

            if let renderer = object["playlistVideoRenderer"] as? [String: Any] {
                let fallbackPosition = nextPlaylistPosition(after: lastPlaylistPosition)
                let parsedPosition = playlistPosition(renderer["index"])
                // Explicit indices are provider-global, but malformed pages
                // can repeat or move them backwards. Never let one move the
                // cursor behind the source-row order.
                let position = max(fallbackPosition, parsedPosition ?? fallbackPosition)
                lastPlaylistPosition = position
                let itemTitle = rendererText(renderer["title"])
                let artist = rendererText(renderer["shortBylineText"])
                    ?? rendererText(renderer["longBylineText"])
                    ?? "Unknown uploader"
                let videoID = clean(renderer["videoId"] as? String, maxLength: 11)
                let isPlayable = renderer["isPlayable"] as? Bool != false
                let isDuplicate = videoID.map { seenTrackIDs.contains($0) } ?? false
                guard let videoID,
                      isYouTubeVideoID(videoID),
                      let itemTitle,
                      isPlayable,
                      seenTrackIDs.insert(videoID).inserted else {
                    skippedItems.append(LocalImportPlaylistSkippedItem(
                        position: position,
                        title: itemTitle ?? "Unavailable item",
                        artist: artist,
                        reason: isDuplicate
                            ? "Duplicate YouTube playlist item"
                            : (isPlayable ? "YouTube did not return a public video for this item" : "Video is unavailable on YouTube")
                    ))
                    return
                }
                let duration = rendererText(renderer["lengthText"]).flatMap(parseDuration)
                tracks.append(LocalImportSpotifyTrack(
                    provider: "youtube",
                    type: "track",
                    trackID: videoID,
                    title: itemTitle,
                    artist: artist,
                    album: nil,
                    trackNumber: position,
                    durationSeconds: duration,
                    artworkURL: thumbnail(renderer["thumbnail"] as? [String: Any]),
                    embedURL: "",
                    sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
                ))
            }

            if let lockup = object["lockupViewModel"] as? [String: Any],
               lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO" {
                let position = nextPlaylistPosition(after: lastPlaylistPosition)
                lastPlaylistPosition = position
                let item = lockupPlaylistTrack(lockup, fallbackPosition: position)
                let isDuplicate = item.map { seenTrackIDs.contains($0.trackID) } ?? false
                if let item, seenTrackIDs.insert(item.trackID).inserted {
                    tracks.append(item)
                } else {
                    skippedItems.append(LocalImportPlaylistSkippedItem(
                        position: position,
                        title: item?.title ?? "Unavailable item",
                        artist: item?.artist,
                        reason: isDuplicate
                            ? "Duplicate YouTube playlist item"
                            : "YouTube did not return a public video for this item"
                    ))
                }
            }

            if let token = nested(object, [
                "continuationItemRenderer",
                "continuationEndpoint",
                "continuationCommand",
                "token",
            ]) as? String,
               !token.isEmpty,
               token.count <= 8_192 {
                continuation = token
            }
        }

        if mismatchedPlaylist {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_MISMATCH",
                message: "YouTube returned the wrong playlist."
            )
        }
        return (
            title: title,
            author: author,
            artworkURL: artworkURL,
            tracks: tracks,
            skippedItems: skippedItems,
            continuation: continuation,
            lastPlaylistPosition: lastPlaylistPosition
        )
    }

    private static func nextPlaylistPosition(after position: Int) -> Int {
        position == Int.max ? Int.max : position + 1
    }

    static func youtubePlaylist(
        _ html: String,
        expectedPlaylistID: String
    ) throws -> (
        title: String,
        author: String,
        artworkURL: String?,
        tracks: [LocalImportSpotifyTrack],
        skippedItems: [LocalImportPlaylistSkippedItem],
        continuation: String?,
        lastPlaylistPosition: Int
    ) {
        guard let root = youtubeInitialData(html) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_INVALID",
                message: "YouTube returned invalid playlist metadata."
            )
        }
        let parsed = try youtubePlaylistData(root, expectedPlaylistID: expectedPlaylistID)
        guard let title = parsed.title, !parsed.tracks.isEmpty else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_EMPTY",
                message: "This playlist has no public, downloadable videos."
            )
        }
        return (
            title: title,
            author: parsed.author ?? "YouTube",
            artworkURL: parsed.artworkURL ?? parsed.tracks.first?.artworkURL,
            tracks: parsed.tracks,
            skippedItems: parsed.skippedItems,
            continuation: parsed.continuation,
            lastPlaylistPosition: parsed.lastPlaylistPosition
        )
    }

    /// Reads the public, non-secret YouTube browse configuration embedded in a
    /// playlist HTML document. It is used only to request continuation pages.
    static func youtubeConfigurationValue(
        _ html: String,
        key: String,
        maxLength: Int = 2_048
    ) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "\"\(escapedKey)\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\""
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html) else { continue }
            let encoded = "\"\(html[capture])\""
            guard let data = encoded.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
                  !value.isEmpty,
                  value.count <= maxLength else { continue }
            return value
        }
        return nil
    }

    static func youtubeInitialData(_ html: String) -> Any? {
        for marker in ["var ytInitialData =", "window[\"ytInitialData\"] =", "ytInitialData ="] {
            guard let markerRange = html.range(of: marker),
                  let start = html[markerRange.upperBound...].firstIndex(of: "{") else { continue }
            guard let json = balancedJSONObject(in: html, from: start),
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { continue }
            return object
        }
        return nil
    }

    static func youtubeWatchDescription(_ html: String) -> String? {
        guard let range = html.range(of: #""shortDescription":"((?:\\.|[^"\\])*)""#, options: .regularExpression) else { return nil }
        let fragment = String(html[range])
        guard let colon = fragment.firstIndex(of: ":") else { return nil }
        let encoded = String(fragment[fragment.index(after: colon)...])
        guard let data = "{\"value\":\(encoded)}".data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["value"] as? String
    }

    private static func playlistPosition(_ value: Any?) -> Int? {
        guard let rendered = rendererText(value),
              let position = Int(rendered.trimmingCharacters(in: .whitespacesAndNewlines)),
              position > 0,
              position <= 10_000 else { return nil }
        return position
    }

    private static func isYouTubeVideoID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil
    }

    private static func youtubePlaylistThumbnail(_ record: [String: Any]) -> String? {
        guard let renderer = record["thumbnailRenderer"] as? [String: Any] else { return nil }
        let playlist = renderer["playlistVideoThumbnailRenderer"] as? [String: Any]
            ?? renderer["playlistCustomThumbnailRenderer"] as? [String: Any]
        return thumbnail(playlist?["thumbnail"] as? [String: Any])
    }

    private static func lockupPlaylistTrack(
        _ renderer: [String: Any],
        fallbackPosition: Int
    ) -> LocalImportSpotifyTrack? {
        guard renderer["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let videoID = clean(renderer["contentId"] as? String, maxLength: 11),
              isYouTubeVideoID(videoID),
              let metadata = renderer["metadata"] as? [String: Any],
              let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any],
              let titleObject = lockupMetadata["title"] as? [String: Any],
              let title = clean(titleObject["content"] as? String) else { return nil }

        var artist: String?
        if let metadataObject = lockupMetadata["metadata"] as? [String: Any],
           let contentMetadata = metadataObject["contentMetadataViewModel"] as? [String: Any],
           let rows = contentMetadata["metadataRows"] as? [[String: Any]],
           let parts = rows.first?["metadataParts"] as? [[String: Any]] {
            artist = clean(parts.compactMap { part in
                (part["text"] as? [String: Any]).flatMap { $0["content"] as? String }
            }.joined(separator: " • "))
        }

        var duration: Int?
        if let image = renderer["contentImage"] as? [String: Any],
           let thumbnailView = image["thumbnailViewModel"] as? [String: Any],
           let overlays = thumbnailView["overlays"] as? [[String: Any]] {
            for overlay in overlays {
                guard let bottom = overlay["thumbnailBottomOverlayViewModel"] as? [String: Any],
                      let badges = bottom["badges"] as? [[String: Any]] else { continue }
                for badge in badges {
                    guard let badgeView = badge["thumbnailBadgeViewModel"] as? [String: Any],
                          let text = badgeView["text"] as? String,
                          let parsed = parseDuration(text) else { continue }
                    duration = parsed
                    break
                }
                if duration != nil { break }
            }
        }

        let thumbnailURL: String?
        if let image = renderer["contentImage"] as? [String: Any],
           let thumbnailView = image["thumbnailViewModel"] as? [String: Any] {
            thumbnailURL = imageSource(thumbnailView["image"])
        } else {
            thumbnailURL = nil
        }
        return LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: videoID,
            title: title,
            artist: artist ?? "Unknown uploader",
            album: nil,
            trackNumber: fallbackPosition,
            durationSeconds: duration,
            artworkURL: thumbnailURL,
            embedURL: "",
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
        )
    }

    private static func imageSource(_ value: Any?) -> String? {
        guard let image = value as? [String: Any],
              let sources = image["sources"] as? [[String: Any]] else { return nil }
        return sources
            .sorted { number($0["width"]) > number($1["width"]) }
            .compactMap { LocalImportURL.youtubeArtwork($0["url"] as? String)?.absoluteString }
            .first
    }

    private static func musicCandidate(_ renderer: [String: Any]) -> LocalImportSearchCandidate? {
        guard let playlist = renderer["playlistItemData"] as? [String: Any],
              let videoID = clean(playlist["videoId"] as? String), videoID.count == 11,
              let columns = renderer["flexColumns"] as? [[String: Any]],
              let primary = columns.first.flatMap(musicColumn),
              let title = primary.text else { return nil }
        let secondary: (text: String?, runs: [[String: Any]]) = columns.count > 1
            ? (musicColumn(columns[1]) ?? (nil, []))
            : (nil, [])
        var artist: String?
        var album: String?
        var duration: Int?
        var unclassified: [String] = []
        for run in secondary.runs {
            guard let value = clean(run["text"] as? String), value != "•" else { continue }
            if let parsed = parseDuration(value) { duration = parsed; continue }
            let browse = nested(run, ["navigationEndpoint", "browseEndpoint"]) as? [String: Any]
            let browseID = browse?["browseId"] as? String
            let musicConfig = browse.flatMap {
                nested($0, ["browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig"])
            } as? [String: Any]
            let pageType = musicConfig?["pageType"] as? String
            if browseID?.hasPrefix("MPRE") == true || pageType?.contains("ALBUM") == true { album = album ?? value }
            else if browseID?.hasPrefix("UC") == true || pageType?.contains("ARTIST") == true { artist = artist ?? value }
            else { unclassified.append(value) }
        }
        artist = artist ?? unclassified.first
        if album == nil, unclassified.count > 1 { album = unclassified[1] }
        let thumbnailContainer = (renderer["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbnailURL = thumbnail((thumbnailContainer?["thumbnail"] as? [String: Any]))
        let badges = renderer["badges"] as? [[String: Any]] ?? []
        let official = badges.contains { badge in
            let inline = badge["musicInlineBadgeRenderer"] as? [String: Any]
            let icon = inline?["icon"] as? [String: Any]
            return (icon?["iconType"] as? String)?.contains("VERIFIED") == true
        }
        return LocalImportSearchCandidate(
            videoID: videoID, title: title, artist: artist, album: album,
            durationSeconds: duration, thumbnailURL: thumbnailURL,
            sourceProvider: .youtubeMusic, officialArtist: official
        )
    }

    private static func webCandidate(_ renderer: [String: Any]) -> LocalImportSearchCandidate? {
        guard let videoID = clean(renderer["videoId"] as? String), videoID.count == 11,
              let title = rendererText(renderer["title"]) else { return nil }
        let artist = rendererText(renderer["ownerText"])
            ?? rendererText(renderer["longBylineText"])
            ?? rendererText(renderer["shortBylineText"])
        let badges = (renderer["ownerBadges"] as? [[String: Any]] ?? []) + (renderer["badges"] as? [[String: Any]] ?? [])
        let official = artist?.localizedCaseInsensitiveContains("topic") == true || badges.contains { badge in
            let metadata = badge["metadataBadgeRenderer"] as? [String: Any]
            return (metadata?["style"] as? String)?.contains("VERIFIED") == true
        }
        return LocalImportSearchCandidate(
            videoID: videoID,
            title: title,
            artist: artist,
            album: nil,
            durationSeconds: rendererText(renderer["lengthText"]).flatMap(parseDuration),
            thumbnailURL: thumbnail(renderer["thumbnail"] as? [String: Any]),
            sourceProvider: .youtube,
            officialArtist: official
        )
    }

    private static func musicColumn(_ value: [String: Any]) -> (text: String?, runs: [[String: Any]])? {
        guard let renderer = value["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
              let text = renderer["text"] as? [String: Any] else { return nil }
        return (rendererText(text), text["runs"] as? [[String: Any]] ?? [])
    }

    private static func rendererText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = clean(object["simpleText"] as? String) { return simple }
        let runs = object["runs"] as? [[String: Any]] ?? []
        return clean(runs.compactMap { clean($0["text"] as? String) }.joined())
    }

    private static func thumbnail(_ value: [String: Any]?) -> String? {
        let values = value?["thumbnails"] as? [[String: Any]] ?? []
        return LocalImportArtworkPolicy.highestQualityYouTubeThumbnail(values)
    }

    private static func parseDuration(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 >= 0 }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private static func scriptContents(id: String, html: String) -> String? {
        guard let idRange = html.range(of: "id=\"\(id)\"", options: .caseInsensitive),
              let opening = html[..<idRange.lowerBound].lastIndex(of: "<"),
              let openEnd = html[idRange.upperBound...].firstIndex(of: ">"),
              let close = html.range(of: "</script>", options: .caseInsensitive, range: openEnd..<html.endIndex)?.lowerBound,
              opening < openEnd, openEnd < close else { return nil }
        return String(html[html.index(after: openEnd)..<close])
    }

    private static func balancedJSONObject(in source: String, from start: String.Index) -> String? {
        var depth = 0
        var quoted = false
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[start...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func nested(_ value: Any, _ keys: [String]) -> Any? {
        var current: Any? = value
        for key in keys { current = (current as? [String: Any])?[key] }
        return current
    }

    private static func walk(_ value: Any, visit: ([String: Any]) -> Void) {
        if let array = value as? [Any] {
            array.forEach { walk($0, visit: visit) }
        } else if let object = value as? [String: Any] {
            visit(object)
            object.values.forEach { walk($0, visit: visit) }
        }
    }

    private static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) ?? 0 }
        return 0
    }

    private static func clean(_ value: String?, maxLength: Int = 500) -> String? {
        guard let value else { return nil }
        let cleaned = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maxLength))
    }

    private static func cleanProviderText(_ value: String?, maxLength: Int = 500) -> String? {
        guard var text = clean(value, maxLength: maxLength) else { return nil }
        for (entity, replacement) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        let expression = try! NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let entityRange = Range(match.range(at: 0), in: text),
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }
            let encoded = String(text[valueRange])
            let radix = encoded.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(encoded.dropFirst()) : encoded
            guard let scalarValue = UInt32(digits, radix: radix),
                  let scalar = UnicodeScalar(scalarValue),
                  !CharacterSet.controlCharacters.contains(scalar) else { continue }
            text.replaceSubrange(entityRange, with: String(scalar))
        }
        return String(text.prefix(maxLength))
    }

    private static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.int64Value
        guard result >= 0, result <= Int64(Int.max), Double(result) == number.doubleValue else { return nil }
        return Int(result)
    }

    private static func nonnegativeInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.int64Value
        guard result >= 0, Double(result) == number.doubleValue else { return nil }
        return result
    }
}

struct LocalImportSearchCandidate: Hashable, Sendable {
    let videoID: String
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?
    let thumbnailURL: String?
    let sourceProvider: LocalImportAudioSourceMatch.Provider
    let officialArtist: Bool
}

enum LocalImportMatcher {
    private static let versionWords = try! NSRegularExpression(
        pattern: #"\b(cover|instrumental|karaoke|live|nightcore|remaster(?:ed)?|remix|reverb|slowed|sped up|tribute)\b"#,
        options: .caseInsensitive
    )
    private static let qualifier = try! NSRegularExpression(pattern: #"(?:\(([^)]{1,120})\)|\[([^\]]{1,120})\])"#)
    private static let removable = try! NSRegularExpression(
        pattern: #"\b(official|audio|video|visualizer|lyrics?|hd|hq|topic|provided to youtube by)\b"#,
        options: .caseInsensitive
    )
    private static let punctuation = try! NSRegularExpression(pattern: #"[^\p{L}\p{N}]+"#)

    static func normalize(_ value: String?) -> String {
        var text = (value ?? "").folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased()
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = replacing(removable, in: text, with: " ")
        text = replacing(punctuation, in: text, with: " ")
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func score(track: LocalImportSpotifyTrack, candidate: LocalImportSearchCandidate) -> LocalImportAudioSourceMatch? {
        let title = tokenScore(track.title, candidate.title)
        let artist = max(tokenScore(track.artist, candidate.artist), tokenScore(track.artist, candidate.title) * 0.75)
        let album = track.album.flatMap { expected in candidate.album.map { tokenScore(expected, $0) } }
        let duration = durationScore(track.durationSeconds, candidate.durationSeconds)
        let values: [(Double, Double?)] = [(0.46, title), (0.25, artist), (0.11, album), (0.18, duration.score)]
        var total = 0.0
        var weight = 0.0
        for (candidateWeight, value) in values {
            guard let value else { continue }
            total += candidateWeight * value
            weight += candidateWeight
        }
        var score = weight > 0 ? total / weight : 0
        if contains(versionWords, candidate.title), !contains(versionWords, track.title) { score -= 0.18 }
        if hasUnmatchedQualifier(expected: track.title, candidate: candidate.title) { score -= 0.18 }
        if candidate.officialArtist { score += 0.07 }
        let targetNonLatin = track.title.unicodeScalars.filter { !$0.isASCII }.count
        let candidateNonLatin = candidate.title.unicodeScalars.filter { !$0.isASCII }.count
        if targetNonLatin == 0, candidateNonLatin >= 3 { score -= 0.14 }
        if candidate.artist?.range(of: #"\b(topic|official artist channel)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            score += 0.035
        }
        score = min(max(score, 0), 1)
        guard title >= 0.48,
              artist >= 0.28,
              duration.delta.map({ $0 <= 24 }) ?? true,
              score >= 0.56 else { return nil }
        let roundedScore = rounded(score)
        return LocalImportAudioSourceMatch(
            videoID: candidate.videoID,
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationSeconds: candidate.durationSeconds,
            thumbnailURL: candidate.thumbnailURL,
            sourceProvider: candidate.sourceProvider,
            officialArtist: candidate.officialArtist,
            sourceURL: "https://www.youtube.com/watch?v=\(candidate.videoID)",
            score: roundedScore,
            confidence: roundedScore >= 0.86 ? "high" : roundedScore >= 0.72 ? "good" : "possible",
            match: .init(
                title: rounded(title),
                artist: rounded(artist),
                album: album.map(rounded),
                duration: duration.score.map(rounded),
                durationDeltaSeconds: duration.delta
            )
        )
    }

    private static func tokenScore(_ expected: String?, _ actual: String?) -> Double {
        let left = normalize(expected)
        let right = normalize(actual)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        if right.contains(left) || left.contains(right) { return 0.92 }
        let leftTokens = Set(left.split(separator: " "))
        let rightTokens = Set(right.split(separator: " "))
        let shared = leftTokens.intersection(rightTokens).count
        return Double(2 * shared) / Double(leftTokens.count + rightTokens.count)
    }

    private static func durationScore(_ expected: Int?, _ actual: Int?) -> (score: Double?, delta: Int?) {
        guard let expected, expected > 0, let actual, actual > 0 else { return (nil, nil) }
        let delta = abs(expected - actual)
        if delta <= 2 { return (1, delta) }
        if delta <= 5 { return (0.88, delta) }
        if delta <= 10 { return (0.62, delta) }
        if delta <= 20 { return (0.24, delta) }
        return (0, delta)
    }

    private static func hasUnmatchedQualifier(expected: String, candidate: String) -> Bool {
        let expected = normalize(expected)
        let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        return qualifier.matches(in: candidate, range: range).contains { match in
            let captures = [match.range(at: 1), match.range(at: 2)]
            let value = captures.compactMap { Range($0, in: candidate).map { String(candidate[$0]) } }.first
            let normalized = normalize(value)
            return !normalized.isEmpty && !expected.contains(normalized)
        }
    }

    private static func contains(_ expression: NSRegularExpression, _ value: String) -> Bool {
        expression.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)) != nil
    }

    private static func replacing(_ expression: NSRegularExpression, in value: String, with replacement: String) -> String {
        expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value), withTemplate: replacement)
    }

    private static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
}
