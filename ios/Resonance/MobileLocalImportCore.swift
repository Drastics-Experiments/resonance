import Foundation

enum LocalImportMediaMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case audio
    case video

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var fileExtension: String { self == .video ? "mp4" : "m4a" }
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
    // YouTube playlist parsing can expose a provider index that must survive
    // source matching and playlist-row reconstruction. Search candidates do
    // not have a playlist position, so this remains nil for those matches.
    let playlistPosition: Int?
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
        case youtubePlaylist
        case youtube
    }

    let kind: Kind
    let track: LocalImportSpotifyTrack
    let candidates: [LocalImportAudioSourceMatch]
    let playlist: LocalImportPlaylist?

    init(kind: Kind, track: LocalImportSpotifyTrack, candidates: [LocalImportAudioSourceMatch], playlist: LocalImportPlaylist? = nil) {
        self.kind = kind
        self.track = track
        self.candidates = candidates
        self.playlist = playlist
    }
}

enum LocalImportSourceIdentityPolicy {
    static func isCurrent(resolvedInput: String?, displayedInput: String) -> Bool {
        guard let resolvedInput else { return false }
        return resolvedInput == displayedInput
    }
}

struct LocalImportPlaylistItem: Hashable, Identifiable, Sendable {
    // Provider playlists may legitimately contain the same track more than
    // once. Position keeps SwiftUI rows stable while trackID remains the
    // source identity used for duplicate download suppression.
    var id: String { "\(position)-\(track.trackID)" }
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

    var unavailableCount: Int { skippedItems.count }
}

enum LocalImportPlaylistSelectionPolicy {
    static func allItemIDs(in items: [LocalImportPlaylistItem]) -> Set<String> {
        Set(items.map(\.id))
    }

    static func selectedItems(
        in playlist: LocalImportPlaylist,
        itemIDs: Set<String>
    ) -> [LocalImportPlaylistItem] {
        playlist.items.filter { itemIDs.contains($0.id) }
    }

    static func toggledItemIDs(
        _ itemIDs: Set<String>,
        item: LocalImportPlaylistItem
    ) -> Set<String> {
        var updated = itemIDs
        if updated.contains(item.id) {
            updated.remove(item.id)
        } else {
            updated.insert(item.id)
        }
        return updated
    }
}

enum LocalImportPlaylistDownloadPolicy {
    // Provider rows remain independently selectable, but repeated rows for
    // the same source track must not perform duplicate network/storage work.
    static func uniqueItems(_ items: [LocalImportPlaylistItem]) -> [LocalImportPlaylistItem] {
        var seenTrackIDs = Set<String>()
        return items.filter { seenTrackIDs.insert($0.track.trackID).inserted }
    }
}

enum LocalImportYouTubePlaylistLimitPolicy {
    static let maxItems = 500

    static func syntheticMoreItemsPosition(
        offset: Int,
        items: [LocalImportAudioSourceMatch],
        skippedItems: [LocalImportPlaylistSkippedItem]
    ) -> Int {
        let maxParsedPosition = max(
            items.compactMap(\.playlistPosition).max() ?? 0,
            skippedItems.map(\.position).max() ?? 0
        )
        return max(max(offset, maxParsedPosition) + 1, 1)
    }

    static func takeRows(
        items: [LocalImportAudioSourceMatch],
        skippedItems: [LocalImportPlaylistSkippedItem],
        maximum: Int,
        startingPosition: Int
    ) -> (
        items: [LocalImportAudioSourceMatch],
        skippedItems: [LocalImportPlaylistSkippedItem],
        truncated: Bool
    ) {
        guard maximum > 0 else {
            return ([], [], !items.isEmpty || !skippedItems.isEmpty)
        }
        let selectedItems = Array(items.prefix(maximum))
        let firstPosition = max(startingPosition, 1)
        let selectedSkippedItems = skippedItems.filter { $0.position >= firstPosition }
        return (
            selectedItems,
            selectedSkippedItems,
            selectedItems.count < items.count
        )
    }
}

enum LocalImportYouTubePlaylistPositionPolicy {
    static func positions(
        for candidates: [LocalImportAudioSourceMatch],
        skippedPositions: Set<Int>
    ) -> [Int] {
        var nextPosition = 1
        return candidates.map { candidate in
            while skippedPositions.contains(nextPosition) {
                nextPosition += 1
            }
            let position = max(candidate.playlistPosition ?? nextPosition, nextPosition)
            nextPosition = position + 1
            return position
        }
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
        deviceTracks: [MobileTrack],
        activeServerSongs: [MobileRemoteSong],
        activeServerURL: URL?,
        activeProfileID: String,
        mediaMode: LocalImportMediaMode = .audio
    ) -> LocalImportExistingSongMatch {
        let deviceTrack = deviceTracks.first { candidate in
            trackMediaMode(for: candidate) == mediaMode && metadataMatches(
                expectedTitle: spotifyTrack.title,
                expectedArtist: spotifyTrack.artist,
                expectedDuration: spotifyTrack.durationSeconds.map(Double.init),
                actualTitle: candidate.title,
                actualArtist: candidate.artist,
                actualDuration: candidate.duration
            )
        }
        let trustedDeviceRemoteID = deviceTrack.flatMap { candidate -> String? in
            guard let activeServerURL,
                  let activeContext = MobileServerEndpointPolicy.context(
                    serverURL: activeServerURL,
                    profileID: activeProfileID
                  ),
                  candidate.remoteIdentity()?.context == activeContext else { return nil }
            return candidate.remoteID
        }
        let serverSong = trustedDeviceRemoteID.flatMap { remoteID in
            activeServerSongs.first {
                $0.id == remoteID && LocalImportMediaMode(rawValue: $0.mediaKind) == mediaMode
            }
        }
        return LocalImportExistingSongMatch(
            deviceTrackID: deviceTrack?.id,
            serverSongID: serverSong?.id
        )
    }

    private static func trackMediaMode(for track: MobileTrack) -> LocalImportMediaMode {
        let videoExtensions = Set(["mp4", "mov", "m4v", "webm"])
        return videoExtensions.contains(
            URL(fileURLWithPath: track.relativePath).pathExtension.lowercased()
        ) ? .video : .audio
    }

    private static func metadataMatches(
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: Double?,
        actualTitle: String,
        actualArtist: String,
        actualDuration: Double?
    ) -> Bool {
        MobileServerSongIdentityPolicy.metadataMatches(
            expectedTitle: expectedTitle,
            expectedArtist: expectedArtist,
            expectedDuration: expectedDuration,
            actualTitle: actualTitle,
            actualArtist: actualArtist,
            actualDuration: actualDuration
        )
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

    init(sourceURL: String, downloadSourceURL: URL?) {
        self.sourceURL = MobileTrackPersistencePolicy.canonicalSourceURL(sourceURL) ?? ""
        self.downloadSourceURL = downloadSourceURL.flatMap {
            MobileTrackPersistencePolicy.persistedDownloadSourceURL($0).flatMap(URL.init(string:))
        }
    }
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
    private static let youtubePlaylistID = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{10,150}$")
    private static let spotifyHosts = Set(["open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link"])
    private static let youtubeHosts = Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"])
    private static let youtubeShortHosts = Set(["youtu.be", "www.youtu.be"])
    private static let youtubeEmbedHosts = Set(["youtube-nocookie.com", "www.youtube-nocookie.com"])
    private static let debridVaultHost = "debridvault.elfhosted.com"

    static func isSpotify(_ value: String) -> Bool {
        guard let trimmed = MobileDurableURLPolicy.trimmed(value),
              let url = URL(string: trimmed),
              let host = url.host?.lowercased() else { return false }
        return spotifyHosts.contains(host)
    }

    static func spotifySource(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= MobileDurableURLPolicy.maximumCharacters,
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
            throw LocalImportError(stage: .resolvingMetadata, code: "UNSUPPORTED_SPOTIFY_RESOURCE", message: "Only Spotify track and playlist links are supported.")
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

    static func isYouTubeVideoID(_ value: String) -> Bool {
        matches(youtubeID, value)
    }

    static func youtubePlaylist(_ value: String) throws -> (url: URL, playlistID: String)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= MobileDurableURLPolicy.maximumCharacters,
              let components = URLComponents(string: trimmed) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_SOURCE",
                message: "Enter a supported Spotify, SoundCloud, or YouTube track or playlist URL."
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
              youtubeHosts.contains(host) || youtubeShortHosts.contains(host) else { return nil }
        guard let rawID = components.queryItems?.first(where: { $0.name == "list" })?.value,
              !rawID.isEmpty else { return nil }
        guard matches(youtubePlaylistID, rawID) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_YOUTUBE_PLAYLIST",
                message: "The YouTube playlist URL is invalid."
            )
        }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "www.youtube.com"
        canonical.path = "/playlist"
        canonical.queryItems = [URLQueryItem(name: "list", value: rawID)]
        guard let url = canonical.url else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_YOUTUBE_PLAYLIST",
                message: "The YouTube playlist URL is invalid."
            )
        }
        return (url, rawID)
    }

    static func youtubeVideoID(_ value: String) throws -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= MobileDurableURLPolicy.maximumCharacters,
              let components = URLComponents(string: trimmed) else {
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
                message: "Only individual YouTube videos are supported here; resolve the playlist link to download its items."
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
        guard let value,
              value.count <= MobileDurableURLPolicy.maximumCharacters,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "scdn.co" || host.hasSuffix(".scdn.co") || host == "spotifycdn.com" || host.hasSuffix(".spotifycdn.com")
        else { return nil }
        guard let url = components.url, MobileDurableURLPolicy.accepts(url) else { return nil }
        return url
    }

    static func youtubeArtwork(_ value: String?) -> URL? {
        guard let value,
              value.count <= MobileDurableURLPolicy.maximumCharacters,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "ytimg.com" || host.hasSuffix(".ytimg.com") || host == "ggpht.com" || host.hasSuffix(".ggpht.com")
        else { return nil }
        guard let url = components.url, MobileDurableURLPolicy.accepts(url) else { return nil }
        return url
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
        guard var components = URLComponents(string: raw), components.scheme == "https", components.host == "open.spotify.com" else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned a mismatched playlist preview.")
        }
        let segments = components.path.split(separator: "/").map(String.init)
        guard let embedIndex = segments.firstIndex(of: "embed"), segments.indices.contains(embedIndex + 2),
              segments[embedIndex + 1] == "playlist", segments[embedIndex + 2] == expectedPlaylistID else {
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

    static func spotifyPlaylistEmbed(_ html: String, expectedPlaylistID: String) throws -> (title: String, author: String, artworkURL: String?, tracks: [LocalImportSpotifyTrack], skippedItems: [LocalImportPlaylistSkippedItem]) {
        guard let script = scriptContents(id: "__NEXT_DATA__", html: html),
              let root = try? JSONSerialization.jsonObject(with: Data(script.utf8)) as? [String: Any],
              let entity = nested(root, ["props", "pageProps", "state", "data", "entity"]) as? [String: Any],
              entity["type"] as? String == "playlist", entity["id"] as? String == expectedPlaylistID,
              let title = clean(entity["title"] as? String) ?? clean(entity["name"] as? String),
              let trackList = entity["trackList"] as? [[String: Any]] else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_MISMATCH", message: "Spotify returned mismatched playlist metadata.")
        }
        let author = clean(entity["subtitle"] as? String) ?? "Spotify"
        let coverSources = nested(entity, ["coverArt", "sources"]) as? [[String: Any]]
        let visualSources = nested(entity, ["visualIdentity", "image"]) as? [[String: Any]]
        let artwork = (coverSources ?? visualSources)?
            .sorted { max(number($0["width"]), number($0["maxWidth"])) > max(number($1["width"]), number($1["maxWidth"])) }
            .compactMap { LocalImportURL.spotifyArtwork($0["url"] as? String)?.absoluteString }.first
        var tracks: [LocalImportSpotifyTrack] = []
        var skippedItems: [LocalImportPlaylistSkippedItem] = []
        for (index, item) in trackList.enumerated() {
            let position = index + 1
            let itemTitle = clean(item["title"] as? String)
            let artist = clean(item["subtitle"] as? String)
            let appendSkipped: (String) -> Void = { reason in
                skippedItems.append(.init(
                    position: position,
                    title: itemTitle ?? "Unavailable item",
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
                provider: "spotify", type: "track", trackID: trackID, title: itemTitle, artist: artist,
                album: nil, trackNumber: index + 1,
                durationSeconds: milliseconds > 0 ? Int((milliseconds / 1_000).rounded()) : nil,
                artworkURL: nil, embedURL: "https://open.spotify.com/embed/track/\(trackID)",
                sourceURL: "https://open.spotify.com/track/\(trackID)"
            ))
        }
        guard !tracks.isEmpty else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_PLAYLIST_EMPTY", message: "This Spotify playlist has no public, playable tracks.")
        }
        return (title, author, artwork, tracks, skippedItems)
    }

    static func youtubePlaylistCandidate(
        _ renderer: [String: Any],
        fallbackPosition: Int
    ) -> LocalImportAudioSourceMatch? {
        guard let videoID = clean(renderer["videoId"] as? String),
              LocalImportURL.isYouTubeVideoID(videoID),
              renderer["isPlayable"] as? Bool != false,
              let title = rendererText(renderer["title"]) else { return nil }
        let position = youtubePlaylistPosition(renderer, fallbackPosition: fallbackPosition)
        let artist = rendererText(renderer["shortBylineText"])
            ?? rendererText(renderer["longBylineText"])
            ?? "Unknown uploader"
        let durationSeconds = rendererText(renderer["lengthText"]).flatMap(parseDuration)
        let thumbnailURL = thumbnail(renderer["thumbnail"] as? [String: Any])
        return youtubePlaylistCandidate(
            videoID: videoID,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            position: position
        )
    }

    static func youtubeLockupPlaylistCandidate(
        _ renderer: [String: Any],
        fallbackPosition: Int
    ) -> LocalImportAudioSourceMatch? {
        guard renderer["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO",
              let videoID = clean(renderer["contentId"] as? String),
              LocalImportURL.isYouTubeVideoID(videoID),
              let metadata = renderer["metadata"] as? [String: Any],
              let lockup = metadata["lockupMetadataViewModel"] as? [String: Any],
              let titleRecord = lockup["title"] as? [String: Any],
              let title = rendererText(titleRecord) else { return nil }

        let rows = nested(lockup, ["metadata", "contentMetadataViewModel", "metadataRows"]) as? [[String: Any]] ?? []
        let artist = rows.first.flatMap { row -> String? in
            guard let parts = row["metadataParts"] as? [[String: Any]] else { return nil }
            return clean(parts.compactMap { part in
                let text = part["text"] as? [String: Any]
                return rendererText(text)
            }.joined(separator: " • "))
        } ?? "Unknown uploader"

        var durationSeconds: Int?
        if let image = renderer["contentImage"] as? [String: Any],
           let thumbnailView = image["thumbnailViewModel"] as? [String: Any],
           let overlays = thumbnailView["overlays"] as? [[String: Any]] {
            for overlay in overlays {
                let badges = nested(overlay, ["thumbnailBottomOverlayViewModel", "badges"]) as? [[String: Any]] ?? []
                for badge in badges {
                    guard let badgeView = badge["thumbnailBadgeViewModel"] as? [String: Any],
                          let text = clean(badgeView["text"] as? String),
                          let parsed = parseDuration(text) else { continue }
                    durationSeconds = parsed
                    break
                }
                if durationSeconds != nil { break }
            }
        }
        let thumbnailURL = nested(renderer, ["contentImage", "thumbnailViewModel", "image"])
            .flatMap { value -> String? in
                guard let image = value as? [String: Any],
                      let sources = image["sources"] as? [[String: Any]] else { return nil }
                return sources
                    .sorted { number($0["width"]) > number($1["width"]) }
                    .compactMap { LocalImportURL.youtubeArtwork($0["url"] as? String)?.absoluteString }
                    .first
            }
        return youtubePlaylistCandidate(
            videoID: videoID,
            title: title,
            artist: artist,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            position: max(fallbackPosition, 1)
        )
    }

    private static func youtubePlaylistPosition(
        _ renderer: [String: Any],
        fallbackPosition: Int
    ) -> Int {
        let fallback = max(fallbackPosition, 1)
        let parsedPosition = rendererText(renderer["index"]).flatMap(Int.init)
        // Match the macOS parser's bounded provider-position policy. A
        // malformed index such as Int.max must not reach the increment below
        // and trap on integer overflow.
        return max(parsedPosition.flatMap { $0 > 0 && $0 <= 10_000 ? $0 : nil } ?? fallback, fallback)
    }

    static func youtubePlaylistData(
        _ value: Any,
        expectedPlaylistID: String,
        positionOffset: Int = 0
    ) throws -> (
        title: String?,
        author: String?,
        artworkURL: String?,
        items: [LocalImportAudioSourceMatch],
        continuation: String?,
        skippedItems: [LocalImportPlaylistSkippedItem],
        unavailableCount: Int,
        nextPosition: Int
    ) {
        var title: String?
        var author: String?
        var artworkURL: String?
        var items: [LocalImportAudioSourceMatch] = []
        var continuation: String?
        var skippedItems: [LocalImportPlaylistSkippedItem] = []
        var unavailableCount = 0
        var nextPosition = max(positionOffset + 1, 1)
        var playlistMismatch = false

        walk(value) { record in
            if let metadata = record["playlistMetadataRenderer"] as? [String: Any] {
                if let metadataID = clean(metadata["playlistId"] as? String), metadataID != expectedPlaylistID {
                    playlistMismatch = true
                }
                title = title ?? clean(metadata["title"] as? String) ?? rendererText(metadata["title"])
            }
            if let header = record["playlistHeaderRenderer"] as? [String: Any] {
                title = title ?? rendererText(header["title"])
                author = author ?? rendererText(header["ownerText"])
            }
            if artworkURL == nil,
               let sidebar = record["playlistSidebarPrimaryInfoRenderer"] as? [String: Any],
               let thumbnails = sidebar["thumbnailRenderer"] as? [String: Any] {
                let source = thumbnails["playlistVideoThumbnailRenderer"] as? [String: Any]
                    ?? thumbnails["playlistCustomThumbnailRenderer"] as? [String: Any]
                artworkURL = thumbnail(source?["thumbnail"] as? [String: Any])
            }
            if let renderer = record["playlistVideoRenderer"] as? [String: Any] {
                let itemPosition = youtubePlaylistPosition(renderer, fallbackPosition: nextPosition)
                if let item = youtubePlaylistCandidate(renderer, fallbackPosition: itemPosition) {
                    items.append(item)
                } else {
                    unavailableCount += 1
                    skippedItems.append(LocalImportPlaylistSkippedItem(
                        position: itemPosition,
                        title: rendererText(renderer["title"]) ?? "Unavailable video",
                        artist: rendererText(renderer["shortBylineText"]) ?? rendererText(renderer["longBylineText"]),
                        reason: renderer["isPlayable"] as? Bool == false
                            ? "Unavailable on YouTube"
                            : "Missing public video metadata"
                    ))
                }
                nextPosition = max(nextPosition, itemPosition + 1)
            }
            if let lockup = record["lockupViewModel"] as? [String: Any],
               lockup["contentType"] as? String == "LOCKUP_CONTENT_TYPE_VIDEO" {
                if let item = youtubeLockupPlaylistCandidate(lockup, fallbackPosition: nextPosition) {
                    items.append(item)
                } else {
                    unavailableCount += 1
                    skippedItems.append(LocalImportPlaylistSkippedItem(
                        position: nextPosition,
                        title: "Unavailable video",
                        artist: nil,
                        reason: "Missing public video metadata"
                    ))
                }
                nextPosition += 1
            }
            if let token = nested(record, ["continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token"]) as? String,
               !token.isEmpty, token.count <= 8_192 {
                continuation = token
            }
        }
        guard !playlistMismatch else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_MISMATCH",
                message: "YouTube returned the wrong playlist."
            )
        }
        return (title, author, artworkURL, items, continuation, skippedItems, unavailableCount, nextPosition)
    }

    private static func youtubePlaylistCandidate(
        videoID: String,
        title: String,
        artist: String,
        durationSeconds: Int?,
        thumbnailURL: String?,
        position: Int
    ) -> LocalImportAudioSourceMatch {
        let sourceURL = "https://www.youtube.com/watch?v=\(videoID)"
        return LocalImportAudioSourceMatch(
            videoID: videoID,
            playlistPosition: position,
            title: title,
            artist: artist,
            album: nil,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            sourceProvider: .youtube,
            officialArtist: false,
            sourceURL: sourceURL,
            score: 1,
            confidence: "high",
            match: .init(
                title: 1,
                artist: 1,
                album: nil,
                duration: durationSeconds == nil ? nil : 1,
                durationDeltaSeconds: durationSeconds == nil ? nil : 0
            )
        )
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
        if let content = clean(object["content"] as? String) { return content }
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

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(500))
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
            playlistPosition: nil,
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
