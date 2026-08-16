import AppKit
import AVFoundation
import CryptoKit
import Foundation

typealias LocalImportProgressHandler = @MainActor @Sendable (LocalImportProgress) -> Void

final class LocalImportMetadataEnrichment: @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var metadata: LocalImportMetadata?

        func publish(_ metadata: LocalImportMetadata?) {
            lock.lock()
            self.metadata = metadata
            lock.unlock()
        }

        var availableMetadata: LocalImportMetadata? {
            lock.lock()
            defer { lock.unlock() }
            return metadata
        }
    }

    private let storage: Storage
    private let task: Task<LocalImportMetadata?, Never>

    init(operation: @escaping @Sendable () async -> LocalImportMetadata?) {
        let storage = Storage()
        self.storage = storage
        self.task = Task {
            let metadata = await operation()
            storage.publish(metadata)
            return metadata
        }
    }

    var availableMetadata: LocalImportMetadata? { storage.availableMetadata }

    func value() async -> LocalImportMetadata? { await task.value }

    func cancel() { task.cancel() }
}

enum LocalImportFeature {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["RESONANCE_LOCAL_DEVICE_IMPORT"] != "0"
    }
}

private final class LocalImportRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validator: @Sendable (URL) -> Bool

    init(validator: @escaping @Sendable (URL) -> Bool) {
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(validator) == true ? request : nil)
    }
}

struct LocalImportSessions: @unchecked Sendable {
    let spotify: URLSession
    let soundcloud: URLSession
    let youtube: URLSession
    let debridVault: URLSession
    let server: URLSession
    let googleVideo: URLSession
    let artwork: URLSession

    static func production() -> LocalImportSessions {
        func session(
            acceptsCookies: Bool = false,
            validator: @escaping @Sendable (URL) -> Bool
        ) -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            if !acceptsCookies {
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
            }
            configuration.timeoutIntervalForRequest = 45
            configuration.timeoutIntervalForResource = 180
            return URLSession(configuration: configuration, delegate: LocalImportRedirectDelegate(validator: validator), delegateQueue: nil)
        }
        return LocalImportSessions(
            spotify: session { url in
                (try? LocalImportURL.spotifySource(url.absoluteString)) != nil
            },
            soundcloud: session(acceptsCookies: true) { LocalImportURL.isSoundCloudRequest($0) },
            // YouTube uses short-lived visitor cookies to keep consecutive
            // playlist searches from degrading into empty result documents.
            // The ephemeral store is isolated to this import-service instance.
            youtube: session(acceptsCookies: true) { LocalImportURL.isYouTubeDocument($0) },
            debridVault: session { LocalImportURL.isDebridVaultDocument($0) },
            server: session { _ in false },
            googleVideo: session { LocalImportURL.isGoogleVideo($0) },
            artwork: session { url in
                LocalImportURL.spotifyArtwork(url.absoluteString) != nil
                    || LocalImportURL.soundCloudArtwork(url.absoluteString) != nil
                    || LocalImportURL.youtubeArtwork(url.absoluteString) != nil
            }
        )
    }

    static func testing(_ session: URLSession) -> LocalImportSessions {
        LocalImportSessions(
            spotify: session,
            soundcloud: session,
            youtube: session,
            debridVault: session,
            server: session,
            googleVideo: session,
            artwork: session
        )
    }
}

struct LocalImportSoundCloudOperations: Sendable {
    let resolveSource: @Sendable (String, URLSession) async throws -> LocalImportSoundCloudSource
    let resolveAudio: @Sendable (String, URLSession) async throws -> LocalImportSoundCloudAudioStream

    static let production = LocalImportSoundCloudOperations(
        resolveSource: { source, session in
            try await LocalImportSoundCloud.resolve(source: source, session: session)
        },
        resolveAudio: { source, session in
            try await LocalImportSoundCloud.resolveAudio(source: source, session: session)
        }
    )
}

/// A small in-memory handoff for the expiring SoundCloud rendition prepared by
/// a saved server download. Its key deliberately contains only non-secret
/// server/profile context plus the exact validated source and media mode.
struct LocalImportPreparedSoundCloudStreamCache: Sendable {
    private struct Key: Hashable, Sendable {
        let preparationContext: String
        let normalizedSource: String
        let mediaMode: LocalImportMediaMode
    }

    private struct Entry: Sendable {
        let stream: LocalImportSoundCloudAudioStream
        let expiresAt: Date
    }

    private let maximumCount: Int
    private let lifetime: TimeInterval
    private var entries: [Key: Entry] = [:]

    init(maximumCount: Int = 8, lifetime: TimeInterval = 30) {
        self.maximumCount = min(max(maximumCount, 1), 32)
        self.lifetime = min(max(lifetime, 1), 120)
    }

    static func normalizedSource(_ value: String) throws -> String {
        let source = try LocalImportURL.soundCloudSource(value)
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_SOUNDCLOUD_URL",
                message: "Source must be a SoundCloud track or playlist URL."
            )
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if components.port == 443 { components.port = nil }
        components.fragment = nil
        guard let normalized = components.url else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_SOUNDCLOUD_URL",
                message: "Source must be a SoundCloud track or playlist URL."
            )
        }
        return normalized.absoluteString
    }

    mutating func store(
        _ stream: LocalImportSoundCloudAudioStream,
        source: String,
        mediaMode: LocalImportMediaMode,
        preparationContext: String,
        now: Date = .now
    ) throws {
        let key = try key(
            source: source,
            mediaMode: mediaMode,
            preparationContext: preparationContext
        )
        prune(at: now)
        if entries[key] == nil,
           entries.count >= maximumCount,
           let oldestKey = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            entries.removeValue(forKey: oldestKey)
        }
        entries[key] = Entry(stream: stream, expiresAt: now.addingTimeInterval(lifetime))
    }

    /// Removes the entry before returning it, so cancellation or a failed
    /// transfer can never replay the same short-lived rendition handoff.
    mutating func take(
        source: String,
        mediaMode: LocalImportMediaMode,
        preparationContext: String,
        now: Date = .now
    ) -> LocalImportSoundCloudAudioStream? {
        guard let key = try? key(
            source: source,
            mediaMode: mediaMode,
            preparationContext: preparationContext
        ) else { return nil }
        prune(at: now)
        return entries.removeValue(forKey: key)?.stream
    }

    mutating func discard(
        source: String,
        mediaMode: LocalImportMediaMode,
        preparationContext: String,
        now: Date = .now
    ) {
        prune(at: now)
        guard let key = try? key(
            source: source,
            mediaMode: mediaMode,
            preparationContext: preparationContext
        ) else { return }
        entries.removeValue(forKey: key)
    }

    mutating func cachedCount(now: Date = .now) -> Int {
        prune(at: now)
        return entries.count
    }

    private func key(
        source: String,
        mediaMode: LocalImportMediaMode,
        preparationContext: String
    ) throws -> Key {
        let loweredContext = preparationContext.lowercased()
        let forbiddenCredentialMarkers = [
            "authorization:",
            "bearer ",
            "token=",
            "access_token",
            "admin_key",
        ]
        guard !preparationContext.isEmpty,
              preparationContext.utf8.count <= 4_096,
              preparationContext.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              !forbiddenCredentialMarkers.contains(where: { loweredContext.contains($0) }) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_PREPARATION_CONTEXT",
                message: "The saved download context is invalid. Refresh the server library and try again."
            )
        }
        let normalizedSource = try Self.normalizedSource(source)
        return Key(
            preparationContext: preparationContext,
            normalizedSource: normalizedSource,
            mediaMode: mediaMode
        )
    }

    private mutating func prune(at now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }
}

enum LocalImportRangeVerifier {
    static func expectedLength(_ value: String?, start: Int64, end: Int64, total: Int64) throws -> Int64 {
        guard let value else {
            throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_MISMATCH", message: "YouTube returned an unverifiable media range.")
        }
        let expression = try! NSRegularExpression(pattern: #"^bytes\s+(\d+)-(\d+)/(\d+)$"#, options: .caseInsensitive)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range),
              let startRange = Range(match.range(at: 1), in: value),
              let endRange = Range(match.range(at: 2), in: value),
              let totalRange = Range(match.range(at: 3), in: value),
              Int64(value[startRange]) == start,
              Int64(value[endRange]) == end,
              Int64(value[totalRange]) == total else {
            throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_MISMATCH", message: "YouTube returned an unverifiable media range.")
        }
        return end - start + 1
    }
}

actor LocalDeviceImportService {
    typealias CandidateSearch = @Sendable (LocalImportSpotifyTrack) async throws -> [LocalImportAudioSourceMatch]

    private struct YouTubeOEmbedResponse: Decodable, Sendable {
        let type: String
        let providerName: String
        let title: String
        let authorName: String
        let thumbnailURL: String?

        enum CodingKeys: String, CodingKey {
            case type, title
            case providerName = "provider_name"
            case authorName = "author_name"
            case thumbnailURL = "thumbnail_url"
        }
    }

    private struct ServerAudioSourceMatch: Decodable, Sendable {
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
        let sourceURL: String
        let videoID: String?
        let title: String
        let artist: String?
        let album: String?
        let durationSeconds: Int?
        let thumbnailURL: String?
        let score: Double?
        let confidence: String?
        let match: Match?
        let actionable: Bool
        let autoSelectable: Bool
        let requiresReview: Bool

        enum CodingKeys: String, CodingKey {
            case provider, title, artist, album, score, confidence, match, actionable
            case sourceURL = "source_url"
            case videoID = "video_id"
            case durationSeconds = "duration_seconds"
            case thumbnailURL = "thumbnail_url"
            case autoSelectable = "auto_selectable"
            case requiresReview = "requires_review"
        }

    }

    private struct ServerResolveResponse: Decodable, Sendable {
        let reviewCandidates: [ServerAudioSourceMatch]?

        enum CodingKeys: String, CodingKey {
            case reviewCandidates = "review_candidates"
        }
    }

    private struct ResolvedYouTubeStream: Sendable {
        let mediaMode: LocalImportMediaMode
        let streamingURL: URL
        let streamingHeaders: [String: String]
        let contentLength: Int64
        let contentType: String
        let itag: Int
    }

    private struct ResolvedYouTubeMedia: Sendable {
        let mediaMode: LocalImportMediaMode
        let preview: LocalImportYouTubePreview
        let primaryStream: ResolvedYouTubeStream
        let companionAudioStream: ResolvedYouTubeStream?
    }

    private struct YouTubeVisitorSession: Sendable {
        let visitorData: String
        let cookieHeader: String?
    }

    private struct YouTubePlayerClient: Sendable {
        let client: [String: String]
        let clientNumber: String
        let userAgent: String
        let origin: String
    }

    private let sessions: LocalImportSessions
    private let localRoot: URL
    private let temporaryRoot: URL
    private let fileManager: FileManager
    private let soundCloudOperations: LocalImportSoundCloudOperations
    private let candidateSearchOverride: CandidateSearch?
    private var preparedSoundCloudStreams = LocalImportPreparedSoundCloudStreamCache()
    private var preparedDirectories = false

    private let maxDocumentBytes = 6 * 1_024 * 1_024
    private let maxPlayerBytes = 4 * 1_024 * 1_024
    private let maxArtworkBytes = 10 * 1_024 * 1_024
    private let maxAudioBytes: Int64 = 256 * 1_024 * 1_024
    private let maxVideoBytes: Int64 = 1_024 * 1_024 * 1_024
    private let mediaChunkSize: Int64 = 10 * 1_024 * 1_024

    init(
        sessions: LocalImportSessions = .production(),
        localRoot: URL? = nil,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default,
        soundCloudOperations: LocalImportSoundCloudOperations = .production,
        candidateSearch: CandidateSearch? = nil
    ) {
        self.sessions = sessions
        self.temporaryRoot = temporaryRoot
        self.fileManager = fileManager
        self.soundCloudOperations = soundCloudOperations
        self.candidateSearchOverride = candidateSearch
        if let localRoot {
            self.localRoot = localRoot
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.localRoot = support
                .appendingPathComponent("Resonance", isDirectory: true)
                .appendingPathComponent("LocalImports", isDirectory: true)
        }
    }

    func search(
        query: String,
        mediaMode: LocalImportMediaMode = .audio
    ) async throws -> LocalImportSearchResponse {
        try Task.checkCancellation()
        try await prepareDirectories()
        return try await LocalImportSearchEngine(sessions: sessions).search(
            query,
            mediaMode: mediaMode
        )
    }

    func resolveMetadata(
        source: String,
        mediaMode: LocalImportMediaMode = .audio
    ) async throws -> LocalImportSpotifyTrack {
        try Task.checkCancellation()

        if LocalImportURL.isSoundCloud(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be imported as audio."
                )
            }
            switch try await soundCloudOperations.resolveSource(source, sessions.soundcloud) {
            case .track(let track):
                return track.metadata
            case .playlist:
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "PLAYLIST_METADATA_UNSUPPORTED",
                    message: "A saved server song must identify one track, not a playlist."
                )
            }
        }

        if LocalImportURL.isSpotify(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SPOTIFY_VIDEO_UNSUPPORTED",
                    message: "Video downloads require a direct YouTube video URL."
                )
            }
            let canonicalSource = try await canonicalSpotifySource(source)
            guard try LocalImportURL.spotifyPlaylist(canonicalSource.absoluteString) == nil else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "PLAYLIST_METADATA_UNSUPPORTED",
                    message: "A saved server song must identify one track, not a playlist."
                )
            }
            return try await resolveSpotify(canonicalSource.absoluteString)
        }

        guard let videoID = try LocalImportURL.youtubeVideoID(source) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SOURCE",
                message: "Enter a Spotify, SoundCloud, or supported YouTube track URL."
            )
        }
        return try await resolveYouTubeMetadata(videoID: videoID)
    }

    /// Builds the downloadable candidate for a server song while reusing the
    /// metadata that the catalog screen already hydrated. SoundCloud's
    /// short-lived rendition is prepared once here and handed directly to the
    /// immediately following import.
    func resolveSavedDownload(
        source: String,
        metadata: LocalImportSpotifyTrack,
        mediaMode: LocalImportMediaMode = .audio,
        preparationContext: String,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportResolution {
        try Task.checkCancellation()
        try await prepareDirectories()

        if LocalImportURL.isSoundCloud(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be imported as audio."
                )
            }
            guard metadata.type == "track" else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "PLAYLIST_METADATA_UNSUPPORTED",
                    message: "A saved server song must identify one track, not a playlist."
                )
            }
            let normalizedSource = try LocalImportPreparedSoundCloudStreamCache.normalizedSource(source)
            let normalizedMetadataSource = try LocalImportPreparedSoundCloudStreamCache.normalizedSource(metadata.sourceURL)
            guard normalizedMetadataSource == normalizedSource else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SAVED_METADATA_SOURCE_MISMATCH",
                    message: "The saved metadata no longer matches this SoundCloud source. Refresh the server library and try again."
                )
            }

            preparedSoundCloudStreams.discard(
                source: normalizedSource,
                mediaMode: mediaMode,
                preparationContext: preparationContext
            )
            await progress(.init(stage: .inspectingSource))
            let stream: LocalImportSoundCloudAudioStream
            do {
                stream = try await soundCloudOperations.resolveAudio(normalizedSource, sessions.soundcloud)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await progress(.init(stage: .searchingCandidates))
                let candidates = try await searchCandidates(for: metadata)
                guard !candidates.isEmpty else {
                    throw LocalImportError(
                        stage: .searchingCandidates,
                        code: "SOUNDCLOUD_STREAM_UNAVAILABLE",
                        message: "This SoundCloud track has no direct public audio rendition and no matching alternate source was found."
                    )
                }
                return LocalImportResolution(
                    kind: .soundCloud,
                    track: metadata,
                    candidates: candidates,
                    releases: []
                )
            }
            try Task.checkCancellation()
            try preparedSoundCloudStreams.store(
                stream,
                source: normalizedSource,
                mediaMode: mediaMode,
                preparationContext: preparationContext
            )
            do {
                try Task.checkCancellation()
            } catch {
                preparedSoundCloudStreams.discard(
                    source: normalizedSource,
                    mediaMode: mediaMode,
                    preparationContext: preparationContext
                )
                throw error
            }
            let candidate = LocalImportAudioSourceMatch(
                videoID: "soundcloud:\(metadata.trackID)",
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                durationSeconds: metadata.durationSeconds,
                thumbnailURL: metadata.artworkURL,
                sourceProvider: .soundcloud,
                officialArtist: true,
                sourceURL: normalizedSource,
                score: 1,
                confidence: "direct",
                match: .init(
                    title: 1,
                    artist: 1,
                    album: metadata.album == nil ? nil : 1,
                    duration: metadata.durationSeconds == nil ? nil : 1,
                    durationDeltaSeconds: 0
                )
            )
            return LocalImportResolution(
                kind: .soundCloud,
                track: metadata,
                candidates: [candidate],
                releases: []
            )
        }

        if LocalImportURL.isSpotify(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SPOTIFY_VIDEO_UNSUPPORTED",
                    message: "Video downloads require a direct YouTube video URL."
                )
            }
            guard try LocalImportURL.spotifyPlaylist(source) == nil,
                  metadata.type == "track" else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "PLAYLIST_METADATA_UNSUPPORTED",
                    message: "A saved server song must identify one track, not a playlist."
                )
            }
            await progress(.init(stage: .searchingCandidates))
            let candidates = try await searchCandidates(for: metadata)
            guard !candidates.isEmpty else {
                throw LocalImportError(
                    stage: .searchingCandidates,
                    code: "NO_AUDIO_MATCH",
                    message: "No file-backed audio source matched this Spotify track. Try a direct YouTube URL instead."
                )
            }
            return LocalImportResolution(
                kind: .spotify,
                track: metadata,
                candidates: candidates,
                releases: []
            )
        }

        guard let videoID = try LocalImportURL.youtubeVideoID(source) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SOURCE",
                message: "A saved server song must identify one supported YouTube track."
            )
        }
        await progress(.init(stage: .inspectingSource))
        let candidate = LocalImportAudioSourceMatch(
            videoID: videoID,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            durationSeconds: metadata.durationSeconds,
            thumbnailURL: metadata.artworkURL,
            sourceProvider: .youtube,
            officialArtist: false,
            sourceURL: source,
            score: 1,
            confidence: "high",
            match: .init(
                title: 1,
                artist: 1,
                album: nil,
                duration: 1,
                durationDeltaSeconds: 0
            )
        )
        return LocalImportResolution(
            kind: .youtube,
            track: metadata,
            candidates: [candidate],
            releases: []
        )
    }

    func resolve(
        source: String,
        mediaMode: LocalImportMediaMode = .audio,
        serverConfiguration: LocalImportServerConfiguration? = nil,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportResolution {
        try Task.checkCancellation()
        try await prepareDirectories()
        if LocalImportURL.isSoundCloud(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be imported as audio."
                )
            }
            await progress(.init(stage: .resolvingMetadata))
            let soundCloudSource = try await soundCloudOperations.resolveSource(source, sessions.soundcloud)
            switch soundCloudSource {
            case .track(let soundCloudTrack):
                let track = soundCloudTrack.metadata
                await progress(.init(stage: .searchingCandidates))
                var candidates = [soundCloudTrack.directCandidate].compactMap { $0 }
                if candidates.isEmpty {
                    do {
                        candidates = try await searchCandidates(for: track)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        candidates = []
                    }
                }
                guard !candidates.isEmpty else {
                    throw LocalImportError(
                        stage: .searchingCandidates,
                        code: "SOUNDCLOUD_STREAM_UNAVAILABLE",
                        message: "This SoundCloud track has no direct public audio rendition and no matching alternate source was found."
                    )
                }
                return LocalImportResolution(kind: .soundCloud, track: track, candidates: candidates, releases: [])

            case .playlist(let soundCloudPlaylist):
                await progress(.init(stage: .searchingCandidates))
                let matches = try await matchSoundCloudPlaylistTracks(
                    soundCloudPlaylist.tracks,
                    serverConfiguration: serverConfiguration
                )
                guard !matches.items.isEmpty else {
                    throw LocalImportError(
                        stage: .searchingCandidates,
                        code: "NO_AUDIO_MATCH",
                        message: "No public audio source could be imported from this SoundCloud playlist."
                    )
                }
                let playlist = LocalImportPlaylist(
                    playlistID: soundCloudPlaylist.playlistID,
                    title: soundCloudPlaylist.title,
                    author: soundCloudPlaylist.author,
                    artworkURL: soundCloudPlaylist.artworkURL,
                    sourceURL: soundCloudPlaylist.sourceURL,
                    items: matches.items,
                    skippedItems: (matches.skippedItems + soundCloudUnavailableItems(soundCloudPlaylist))
                        .sorted { $0.position < $1.position }
                )
                let duration = soundCloudPlaylist.tracks.compactMap(\.metadata.durationSeconds).reduce(0, +)
                let summary = LocalImportSpotifyTrack(
                    provider: "soundcloud",
                    type: "playlist",
                    trackID: soundCloudPlaylist.playlistID,
                    title: soundCloudPlaylist.title,
                    artist: soundCloudPlaylist.author,
                    album: nil,
                    trackNumber: nil,
                    durationSeconds: duration > 0 ? duration : nil,
                    artworkURL: soundCloudPlaylist.artworkURL,
                    embedURL: "",
                    sourceURL: soundCloudPlaylist.sourceURL
                )
                return LocalImportResolution(
                    kind: .soundCloudPlaylist,
                    track: summary,
                    candidates: matches.items.map(\.candidate),
                    releases: [],
                    playlist: playlist
                )
            }
        }
        if LocalImportURL.isSpotify(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SPOTIFY_VIDEO_UNSUPPORTED",
                    message: "Video downloads require a direct YouTube video URL."
                )
            }
            await progress(.init(stage: .resolvingMetadata))
            let canonicalSource = try await canonicalSpotifySource(source)
            if let canonicalPlaylist = try LocalImportURL.spotifyPlaylist(canonicalSource.absoluteString) {
                let playlistMetadata = try await resolveSpotifyPlaylist(canonicalPlaylist)
                await progress(.init(stage: .searchingCandidates))
                let matches = try await matchSpotifyPlaylistTracks(
                    playlistMetadata.tracks,
                    serverConfiguration: serverConfiguration
                )
                guard !matches.items.isEmpty else {
                    throw LocalImportError(
                        stage: .searchingCandidates,
                        code: "NO_AUDIO_MATCH",
                        message: "No close YouTube audio match was found for the public tracks in this Spotify playlist on this Mac or its configured Resonance server."
                    )
                }
                let playlist = LocalImportPlaylist(
                    playlistID: canonicalPlaylist.playlistID,
                    title: playlistMetadata.title,
                    author: playlistMetadata.author,
                    artworkURL: playlistMetadata.artworkURL,
                    sourceURL: canonicalPlaylist.url.absoluteString,
                    items: matches.items,
                    skippedItems: (playlistMetadata.skippedItems + matches.skippedItems)
                        .sorted { $0.position < $1.position }
                )
                let duration = playlistMetadata.tracks.compactMap(\.durationSeconds).reduce(0, +)
                let summary = LocalImportSpotifyTrack(
                    provider: "spotify",
                    type: "playlist",
                    trackID: canonicalPlaylist.playlistID,
                    title: playlistMetadata.title,
                    artist: playlistMetadata.author,
                    album: nil,
                    trackNumber: nil,
                    durationSeconds: duration > 0 ? duration : nil,
                    artworkURL: playlistMetadata.artworkURL,
                    embedURL: "https://open.spotify.com/embed/playlist/\(canonicalPlaylist.playlistID)",
                    sourceURL: canonicalPlaylist.url.absoluteString
                )
                return LocalImportResolution(
                    kind: .spotifyPlaylist,
                    track: summary,
                    candidates: matches.items.map(\.candidate),
                    releases: [],
                    playlist: playlist
                )
            }
            let track = try await resolveSpotify(source)
            await progress(.init(stage: .searchingCandidates))
            async let candidateSearch = searchCandidates(for: track)
            async let serverReviewSearch = serverReviewCandidates(
                for: track,
                configuration: serverConfiguration
            )
            async let releaseSearch = searchDebridVaultReleases(for: track)
            let (localCandidates, serverCandidates, releases) = try await (
                candidateSearch,
                serverReviewSearch,
                releaseSearch
            )
            var seenVideoIDs = Set<String>()
            let candidates = (localCandidates + serverCandidates).filter {
                seenVideoIDs.insert($0.videoID).inserted
            }
            guard !candidates.isEmpty || !releases.isEmpty else {
                throw LocalImportError(
                    stage: .searchingCandidates,
                    code: "NO_IMPORT_SOURCE",
                    message: "No close YouTube audio match or Debrid Vault release was found. Try a YouTube URL instead."
                )
            }
            return LocalImportResolution(
                kind: .spotify,
                track: track,
                candidates: candidates,
                reviewCandidateVideoIDs: Set(serverCandidates.map(\.videoID)),
                releases: releases
            )
        }

        guard let videoID = try LocalImportURL.youtubeVideoID(source) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "UNSUPPORTED_SOURCE", message: "Enter a Spotify, SoundCloud, or supported YouTube track or playlist URL.")
        }
        await progress(.init(stage: .inspectingSource))
        let resolved = try await resolveYouTubeMedia(videoID: videoID, mediaMode: mediaMode)
        let preview = resolved.preview
        let track = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: preview.videoID,
            title: preview.title,
            artist: preview.author ?? "Unknown uploader",
            album: nil,
            trackNumber: nil,
            durationSeconds: preview.durationSeconds,
            artworkURL: preview.thumbnailURL,
            embedURL: "",
            sourceURL: preview.sourceURL
        )
        let candidate = LocalImportAudioSourceMatch(
            videoID: preview.videoID,
            title: preview.title,
            artist: preview.author,
            album: nil,
            durationSeconds: preview.durationSeconds,
            thumbnailURL: preview.thumbnailURL,
            sourceProvider: .youtube,
            officialArtist: false,
            sourceURL: preview.sourceURL,
            score: 1,
            confidence: "high",
            match: .init(title: 1, artist: 1, album: nil, duration: 1, durationDeltaSeconds: 0)
        )
        return LocalImportResolution(kind: .youtube, track: track, candidates: [candidate], releases: [])
    }

    private func resolveYouTubeMetadata(videoID: String) async throws -> LocalImportSpotifyTrack {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/oembed"
        components.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_INVALID_METADATA_URL",
                message: "YouTube metadata could not be requested safely."
            )
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await responseData(
            session: sessions.youtube,
            request: request,
            limit: 256 * 1_024
        )
        guard (200..<300).contains(response.statusCode),
              response.url?.host?.lowercased() == "www.youtube.com",
              response.url?.path == "/oembed" else {
            throw youtubeFailure(response)
        }
        let metadata = try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
        guard metadata.type == "video",
              metadata.providerName == "YouTube",
              !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_INVALID_METADATA",
                message: "YouTube returned invalid video metadata."
            )
        }
        return LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: videoID,
            title: metadata.title,
            artist: metadata.authorName,
            album: nil,
            trackNumber: nil,
            durationSeconds: nil,
            artworkURL: LocalImportURL.youtubeArtwork(metadata.thumbnailURL)?.absoluteString,
            embedURL: "",
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
        )
    }

    func importCandidate(
        _ candidate: LocalImportAudioSourceMatch,
        metadata inputMetadata: LocalImportMetadata,
        metadataEnrichment: LocalImportMetadataEnrichment? = nil,
        finalizeAuthorization: (@Sendable () async throws -> Void)? = nil,
        existingTracks: [Track],
        mediaMode: LocalImportMediaMode = .audio,
        preparationContext: String? = nil,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        try await prepareDirectories()
        if candidate.sourceProvider == .soundcloud {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .inspectingSource,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be imported as audio."
                )
            }
            return try await importSoundCloudCandidate(
                candidate,
                metadata: inputMetadata,
                metadataEnrichment: metadataEnrichment,
                finalizeAuthorization: finalizeAuthorization,
                existingTracks: existingTracks,
                preparationContext: preparationContext,
                progress: progress
            )
        }
        let temporary = temporaryRoot.appendingPathComponent("resonance-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source.\(mediaMode.fileExtension)")
        let companionAudio = temporary.appendingPathComponent("source-audio.m4a")
        let processed = temporary.appendingPathComponent("processed.\(mediaMode.fileExtension)")
        await progress(.init(stage: .inspectingSource))
        let videoID = try LocalImportURL.youtubeVideoID(candidate.sourceURL)
        guard let videoID else {
            throw LocalImportError(stage: .inspectingSource, code: "INVALID_YOUTUBE_VIDEO", message: "The selected source is not a supported YouTube video.")
        }
        let resolved = try await resolveYouTubeMedia(videoID: videoID, mediaMode: mediaMode)
        let sourceAssociation = LocalImportSourceAssociation(
            sourceURL: inputMetadata.sourceURL,
            downloadSourceURL: resolved.companionAudioStream == nil
                ? resolved.primaryStream.streamingURL
                : nil
        )
        let totalDownloadBytes = resolved.preview.contentLength
        let primaryHash = try await download(
            resolved.primaryStream,
            to: source,
            completedOffset: 0,
            total: totalDownloadBytes,
            progress: progress
        )
        var sourceHashes = [primaryHash]
        var companionAudioInput: URL?
        if let audioStream = resolved.companionAudioStream {
            let audioHash = try await download(
                audioStream,
                to: companionAudio,
                completedOffset: resolved.primaryStream.contentLength,
                total: totalDownloadBytes,
                progress: progress
            )
            sourceHashes.append(audioHash)
            companionAudioInput = companionAudio
        }
        let sourceHash = Self.combinedSourceHash(sourceHashes)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        await progress(.init(stage: .processing))
        let enrichedInputMetadata = metadataEnrichment?.availableMetadata ?? inputMetadata
        try Task.checkCancellation()
        let metadata = LocalImportMetadata(
            title: cleanMetadata(enrichedInputMetadata.title, fallback: resolved.preview.title),
            artist: cleanMetadata(enrichedInputMetadata.artist, fallback: resolved.preview.author ?? "Unknown uploader"),
            album: cleanMetadata(enrichedInputMetadata.album, fallback: "Imported"),
            artworkURL: LocalImportArtworkPolicy.preferredArtwork(
                metadataURL: enrichedInputMetadata.artworkURL,
                resolvedYouTubeURL: resolved.preview.thumbnailURL
            ),
            sourceURL: enrichedInputMetadata.sourceURL
        )
        let artwork = await fetchArtwork(metadata.artworkURL)
        try Task.checkCancellation()
        do {
            try await LocalImportMediaProcessor.remux(
                input: source,
                companionAudioInput: companionAudioInput,
                output: processed,
                mediaMode: mediaMode,
                metadata: metadata,
                artwork: artwork
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch where artwork != nil {
            try? fileManager.removeItem(at: processed)
            try await LocalImportMediaProcessor.remux(
                input: source,
                companionAudioInput: companionAudioInput,
                output: processed,
                mediaMode: mediaMode,
                metadata: metadata,
                artwork: nil
            )
        }
        let contentHash = try hashFile(processed)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash || $0.contentSHA256 == contentHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        try await finalizeAuthorization?()
        try Task.checkCancellation()
        await progress(.init(stage: .savingLocal))
        let filename = safeFilename("\(metadata.artist) - \(metadata.title)") + ".\(mediaMode.fileExtension)"
        let destination = try uniqueDestination(preferredFilename: filename)
        do {
            try fileManager.moveItem(at: processed, to: destination)
            let duration: TimeInterval
            if mediaMode == .video {
                let asset = AVURLAsset(url: destination)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let assetDuration = try await asset.load(.duration).seconds
                guard !videoTracks.isEmpty, assetDuration.isFinite, assetDuration > 0 else {
                    try? fileManager.removeItem(at: destination)
                    throw LocalImportError(stage: .savingLocal, code: "INVALID_LOCAL_MEDIA", message: "The completed local video file is not playable.")
                }
                if let player = try? AVAudioPlayer(contentsOf: destination),
                   player.duration.isFinite,
                   player.duration > 0 {
                    duration = player.duration
                } else {
                    duration = assetDuration
                }
            } else {
                guard let player = try? AVAudioPlayer(contentsOf: destination), player.duration > 0 else {
                    try? fileManager.removeItem(at: destination)
                    throw LocalImportError(stage: .savingLocal, code: "INVALID_LOCAL_MEDIA", message: "The completed local audio file is not playable.")
                }
                duration = player.duration
            }
            return .created(LocalImportedAudio(
                fileURL: destination,
                metadata: metadata,
                duration: duration,
                artworkData: artwork,
                downloadSourceURL: sourceAssociation.downloadSourceURL,
                sourceSHA256: sourceHash,
                contentSHA256: contentHash,
                mediaMode: mediaMode
            ))
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func importSoundCloudCandidate(
        _ candidate: LocalImportAudioSourceMatch,
        metadata inputMetadata: LocalImportMetadata,
        metadataEnrichment: LocalImportMetadataEnrichment?,
        finalizeAuthorization: (@Sendable () async throws -> Void)?,
        existingTracks: [Track],
        preparationContext: String?,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportOutcome {
        let temporary = temporaryRoot.appendingPathComponent("resonance-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source.mp3")
        let processed = temporary.appendingPathComponent("processed.m4a")
        await progress(.init(stage: .inspectingSource))
        try Task.checkCancellation()
        let preparedStream: LocalImportSoundCloudAudioStream?
        if let preparationContext {
            preparedStream = preparedSoundCloudStreams.take(
                source: candidate.sourceURL,
                mediaMode: .audio,
                preparationContext: preparationContext
            )
        } else {
            preparedStream = nil
        }
        let stream: LocalImportSoundCloudAudioStream
        if let preparedStream {
            stream = preparedStream
        } else {
            stream = try await soundCloudOperations.resolveAudio(candidate.sourceURL, sessions.soundcloud)
        }
        try Task.checkCancellation()
        let sourceAssociation = LocalImportSourceAssociation(
            sourceURL: inputMetadata.sourceURL,
            downloadSourceURL: stream.streamingURL
        )
        let sourceHash = try await LocalImportSoundCloud.download(
            stream,
            to: source,
            session: sessions.soundcloud,
            fileManager: fileManager,
            progress: progress
        )
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        await progress(.init(stage: .processing))
        let enrichedInputMetadata = metadataEnrichment?.availableMetadata ?? inputMetadata
        try Task.checkCancellation()
        let metadata = LocalImportMetadata(
            title: cleanMetadata(enrichedInputMetadata.title, fallback: stream.track.title),
            artist: cleanMetadata(enrichedInputMetadata.artist, fallback: stream.track.artist),
            album: cleanMetadata(enrichedInputMetadata.album, fallback: stream.track.album ?? "SoundCloud"),
            artworkURL: enrichedInputMetadata.artworkURL ?? stream.track.artworkURL,
            sourceURL: enrichedInputMetadata.sourceURL
        )
        let artwork = await fetchArtwork(metadata.artworkURL)
        try Task.checkCancellation()
        do {
            try await LocalImportMediaProcessor.remuxM4A(
                input: source,
                output: processed,
                metadata: metadata,
                artwork: artwork
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch where artwork != nil {
            try? fileManager.removeItem(at: processed)
            try await LocalImportMediaProcessor.remuxM4A(
                input: source,
                output: processed,
                metadata: metadata,
                artwork: nil
            )
        }
        let contentHash = try hashFile(processed)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash || $0.contentSHA256 == contentHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        try await finalizeAuthorization?()
        try Task.checkCancellation()
        await progress(.init(stage: .savingLocal))
        let filename = safeFilename("\(metadata.artist) - \(metadata.title)") + ".m4a"
        let destination = try uniqueDestination(preferredFilename: filename)
        do {
            try fileManager.moveItem(at: processed, to: destination)
            guard let player = try? AVAudioPlayer(contentsOf: destination), player.duration > 0 else {
                try? fileManager.removeItem(at: destination)
                throw LocalImportError(
                    stage: .savingLocal,
                    code: "INVALID_LOCAL_MEDIA",
                    message: "The completed local SoundCloud audio file is not playable."
                )
            }
            return .created(LocalImportedAudio(
                fileURL: destination,
                metadata: metadata,
                duration: player.duration,
                artworkData: artwork,
                downloadSourceURL: sourceAssociation.downloadSourceURL,
                sourceSHA256: sourceHash,
                contentSHA256: contentHash,
                mediaMode: .audio
            ))
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func previewStream(
        for candidate: LocalImportAudioSourceMatch,
        mediaMode: LocalImportMediaMode = .audio
    ) async throws -> LocalImportPreviewStream {
        try Task.checkCancellation()
        if candidate.sourceProvider == .soundcloud {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .inspectingSource,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be previewed as audio."
                )
            }
            let stream = try await soundCloudOperations.resolveAudio(candidate.sourceURL, sessions.soundcloud)
            return LocalImportPreviewStream(url: stream.streamingURL, httpHeaders: LocalImportSoundCloud.streamHeaders)
        }
        guard let videoID = try LocalImportURL.youtubeVideoID(candidate.sourceURL) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_YOUTUBE_VIDEO",
                message: "This option is not a supported YouTube audio source."
            )
        }
        let resolved = try await resolveYouTubeMedia(videoID: videoID, mediaMode: mediaMode)
        return LocalImportPreviewStream(
            url: resolved.primaryStream.streamingURL,
            httpHeaders: resolved.primaryStream.streamingHeaders,
            contentLength: resolved.primaryStream.contentLength,
            contentType: resolved.primaryStream.contentType
        )
    }

    func artworkData(for value: String?) async -> Data? {
        await fetchArtwork(value)
    }

    private func resolveSpotify(_ source: String) async throws -> LocalImportSpotifyTrack {
        let canonical: (url: URL, trackID: String)
        if let direct = try LocalImportURL.spotifyTrack(source) {
            canonical = direct
        } else {
            let shortURL = try LocalImportURL.spotifySource(source)
            var request = URLRequest(url: shortURL)
            request.httpMethod = "HEAD"
            let (_, response) = try await responseData(session: sessions.spotify, request: request, limit: 1)
            guard (200..<300).contains(response.statusCode),
                  let final = response.url,
                  let resolved = try LocalImportURL.spotifyTrack(final.absoluteString) else {
                throw spotifyFailure(response)
            }
            canonical = resolved
        }

        var oEmbedComponents = URLComponents()
        oEmbedComponents.scheme = "https"
        oEmbedComponents.host = "open.spotify.com"
        oEmbedComponents.path = "/oembed"
        oEmbedComponents.queryItems = [URLQueryItem(name: "url", value: canonical.url.absoluteString)]
        guard let oEmbedURL = oEmbedComponents.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid track preview.")
        }
        var oEmbedRequest = URLRequest(url: oEmbedURL)
        oEmbedRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (oEmbedData, oEmbedResponse) = try await responseData(session: sessions.spotify, request: oEmbedRequest, limit: 256 * 1_024)
        guard (200..<300).contains(oEmbedResponse.statusCode) else { throw spotifyFailure(oEmbedResponse) }
        let oEmbed = try LocalImportParser.spotifyOEmbed(oEmbedData, expectedTrackID: canonical.trackID)

        guard let embedURL = URL(string: oEmbed.embedURL) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid track preview.")
        }
        var embedRequest = URLRequest(url: embedURL)
        embedRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        embedRequest.setValue("Resonance/1.0", forHTTPHeaderField: "User-Agent")
        let (embedData, embedResponse) = try await responseData(session: sessions.spotify, request: embedRequest, limit: maxDocumentBytes)
        guard (200..<300).contains(embedResponse.statusCode), let html = String(data: embedData, encoding: .utf8) else {
            throw spotifyFailure(embedResponse)
        }
        let embedded = try LocalImportParser.spotifyEmbed(html, expectedTrackID: canonical.trackID)
        return LocalImportSpotifyTrack(
            provider: "spotify",
            type: "track",
            trackID: canonical.trackID,
            title: embedded.title,
            artist: embedded.artist,
            album: nil,
            trackNumber: nil,
            durationSeconds: embedded.durationSeconds,
            artworkURL: embedded.artworkURL ?? oEmbed.artworkURL,
            embedURL: oEmbed.embedURL,
            sourceURL: canonical.url.absoluteString
        )
    }

    private func canonicalSpotifySource(_ source: String) async throws -> URL {
        let sourceURL = try LocalImportURL.spotifySource(source)
        if ["open.spotify.com", "www.open.spotify.com"].contains(sourceURL.host?.lowercased() ?? "") {
            return sourceURL
        }
        var request = URLRequest(url: sourceURL)
        request.httpMethod = "HEAD"
        let (_, response) = try await responseData(session: sessions.spotify, request: request, limit: 1)
        guard (200..<300).contains(response.statusCode), let final = response.url,
              ["open.spotify.com", "www.open.spotify.com"].contains(final.host?.lowercased() ?? "") else {
            throw spotifyFailure(response)
        }
        return final
    }

    private func resolveSpotifyPlaylist(
        _ canonical: (url: URL, playlistID: String)
    ) async throws -> (title: String, author: String, artworkURL: String?, tracks: [LocalImportSpotifyTrack], skippedItems: [LocalImportPlaylistSkippedItem]) {
        var oEmbedComponents = URLComponents()
        oEmbedComponents.scheme = "https"
        oEmbedComponents.host = "open.spotify.com"
        oEmbedComponents.path = "/oembed"
        oEmbedComponents.queryItems = [URLQueryItem(name: "url", value: canonical.url.absoluteString)]
        guard let oEmbedURL = oEmbedComponents.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        var oEmbedRequest = URLRequest(url: oEmbedURL)
        oEmbedRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (oEmbedData, oEmbedResponse) = try await responseData(session: sessions.spotify, request: oEmbedRequest, limit: 256 * 1_024)
        guard (200..<300).contains(oEmbedResponse.statusCode) else { throw spotifyFailure(oEmbedResponse) }
        let oEmbed = try LocalImportParser.spotifyPlaylistOEmbed(oEmbedData, expectedPlaylistID: canonical.playlistID)
        guard let embedURL = URL(string: oEmbed.embedURL) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        var embedRequest = URLRequest(url: embedURL)
        embedRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        embedRequest.setValue("Resonance/1.0", forHTTPHeaderField: "User-Agent")
        let (embedData, embedResponse) = try await responseData(session: sessions.spotify, request: embedRequest, limit: maxDocumentBytes)
        guard (200..<300).contains(embedResponse.statusCode), let html = String(data: embedData, encoding: .utf8) else {
            throw spotifyFailure(embedResponse)
        }
        let embedded = try LocalImportParser.spotifyPlaylistEmbed(html, expectedPlaylistID: canonical.playlistID)
        let artworkURL = embedded.artworkURL ?? oEmbed.artworkURL
        let tracks = try await hydrateSpotifyPlaylistTrackArtwork(embedded.tracks)
        return (embedded.title, embedded.author, artworkURL, tracks, embedded.skippedItems)
    }

    private func hydrateSpotifyPlaylistTrackArtwork(
        _ tracks: [LocalImportSpotifyTrack]
    ) async throws -> [LocalImportSpotifyTrack] {
        var hydrated: [LocalImportSpotifyTrack] = []
        hydrated.reserveCapacity(tracks.count)
        for track in tracks {
            try Task.checkCancellation()
            let artworkURL: String?
            do {
                var components = URLComponents()
                components.scheme = "https"
                components.host = "open.spotify.com"
                components.path = "/oembed"
                components.queryItems = [URLQueryItem(name: "url", value: track.sourceURL)]
                guard let url = components.url else { throw URLError(.badURL) }
                var request = URLRequest(url: url)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await responseData(
                    session: sessions.spotify,
                    request: request,
                    limit: 256 * 1_024
                )
                guard (200..<300).contains(response.statusCode) else { throw spotifyFailure(response) }
                artworkURL = try LocalImportParser.spotifyOEmbed(
                    data,
                    expectedTrackID: track.trackID
                ).artworkURL
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                artworkURL = nil
            }
            hydrated.append(LocalImportSpotifyTrack(
                provider: track.provider,
                type: track.type,
                trackID: track.trackID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                trackNumber: track.trackNumber,
                durationSeconds: track.durationSeconds,
                artworkURL: artworkURL,
                embedURL: track.embedURL,
                sourceURL: track.sourceURL
            ))
        }
        return hydrated
    }

    private struct SpotifyPlaylistTrackMatch: Sendable {
        let track: LocalImportSpotifyTrack
        let item: LocalImportPlaylistItem?
        let failureReason: String?
    }

    private func matchSpotifyPlaylistTracks(
        _ tracks: [LocalImportSpotifyTrack],
        serverConfiguration: LocalImportServerConfiguration?
    ) async throws -> (items: [LocalImportPlaylistItem], skippedItems: [LocalImportPlaylistSkippedItem]) {
        var output: [LocalImportPlaylistItem] = []
        var unresolved: [SpotifyPlaylistTrackMatch] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if index > 0 {
                try await Task.sleep(for: .milliseconds(250))
            }
            let match = try await matchSpotifyPlaylistTrack(
                track,
                serverConfiguration: serverConfiguration
            )
            if let item = match.item {
                output.append(item)
            } else {
                unresolved.append(match)
            }
        }

        // YouTube can return transiently empty search documents when playlist
        // requests arrive too quickly. Keep the initial pass ordered and paced,
        // then give only genuine misses one slower retry before reporting them.
        if !unresolved.isEmpty {
            var remaining: [SpotifyPlaylistTrackMatch] = []
            for match in unresolved.sorted(by: { ($0.track.trackNumber ?? 0) < ($1.track.trackNumber ?? 0) }) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(500))
                let retried = try await matchSpotifyPlaylistTrack(
                    match.track,
                    serverConfiguration: serverConfiguration
                )
                if let item = retried.item {
                    output.append(item)
                } else {
                    remaining.append(retried)
                }
            }
            unresolved = remaining
        }

        let skippedItems = unresolved.map { match in
            LocalImportPlaylistSkippedItem(
                position: match.track.trackNumber ?? 0,
                title: match.track.title,
                artist: match.track.artist,
                reason: "\(match.failureReason ?? "Audio source search failed") after a paced retry"
            )
        }
        return (
            output.sorted { $0.position < $1.position },
            skippedItems.sorted { $0.position < $1.position }
        )
    }

    private func matchSoundCloudPlaylistTracks(
        _ tracks: [LocalImportSoundCloudTrack],
        serverConfiguration: LocalImportServerConfiguration?
    ) async throws -> (items: [LocalImportPlaylistItem], skippedItems: [LocalImportPlaylistSkippedItem]) {
        var items: [LocalImportPlaylistItem] = []
        var skippedItems: [LocalImportPlaylistSkippedItem] = []
        var searchedTrackCount = 0
        for (index, soundCloudTrack) in tracks.enumerated() {
            try Task.checkCancellation()
            let track = soundCloudTrack.metadata
            if let direct = soundCloudTrack.directCandidate {
                items.append(LocalImportPlaylistItem(
                    position: track.trackNumber ?? index + 1,
                    track: track,
                    candidate: direct
                ))
                continue
            }
            if searchedTrackCount > 0 { try await Task.sleep(for: .milliseconds(250)) }
            searchedTrackCount += 1
            var alternatives: [LocalImportAudioSourceMatch] = []
            do {
                alternatives = try await searchPlaylistCandidates(
                    for: track,
                    serverConfiguration: serverConfiguration
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                alternatives = []
            }
            if let candidate = alternatives.first {
                items.append(LocalImportPlaylistItem(
                    position: track.trackNumber ?? index + 1,
                    track: track,
                    candidate: candidate,
                    fallbackCandidates: Array(alternatives.dropFirst())
                ))
            } else {
                skippedItems.append(LocalImportPlaylistSkippedItem(
                    position: track.trackNumber ?? index + 1,
                    title: track.title,
                    artist: track.artist,
                    reason: "No public SoundCloud rendition or close alternate audio match"
                ))
            }
        }
        return (
            items.sorted { $0.position < $1.position },
            skippedItems.sorted { $0.position < $1.position }
        )
    }

    private func soundCloudUnavailableItems(
        _ playlist: LocalImportSoundCloudPlaylist
    ) -> [LocalImportPlaylistSkippedItem] {
        guard playlist.unavailableCount > 0 else { return [] }
        let firstPosition = (playlist.tracks.compactMap(\.metadata.trackNumber).max() ?? playlist.tracks.count) + 1
        return (0..<playlist.unavailableCount).map { offset in
            LocalImportPlaylistSkippedItem(
                position: firstPosition + offset,
                title: "Unavailable SoundCloud track",
                artist: nil,
                reason: "SoundCloud did not return public metadata for this playlist item"
            )
        }
    }

    private func matchSpotifyPlaylistTrack(
        _ track: LocalImportSpotifyTrack,
        serverConfiguration: LocalImportServerConfiguration?
    ) async throws -> SpotifyPlaylistTrackMatch {
        do {
            let candidates = try await searchPlaylistCandidates(
                for: track,
                serverConfiguration: serverConfiguration
            )
            guard let candidate = candidates.first else {
                return SpotifyPlaylistTrackMatch(
                    track: track,
                    item: nil,
                    failureReason: serverConfiguration == nil
                        ? "No close YouTube audio match"
                        : "No close YouTube audio match on this Mac or the Resonance server"
                )
            }
            return SpotifyPlaylistTrackMatch(
                track: track,
                item: LocalImportPlaylistItem(
                    position: track.trackNumber ?? 0,
                    track: track,
                    candidate: candidate,
                    fallbackCandidates: Array(candidates.dropFirst())
                ),
                failureReason: nil
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SpotifyPlaylistTrackMatch(
                track: track,
                item: nil,
                failureReason: "Audio source search failed"
            )
        }
    }

    private func searchPlaylistCandidates(
        for track: LocalImportSpotifyTrack,
        serverConfiguration: LocalImportServerConfiguration?
    ) async throws -> [LocalImportAudioSourceMatch] {
        // Server `review_candidates` are metadata-only matches. Playlist import
        // does not yet provide per-item source review, so never auto-select them.
        _ = serverConfiguration
        return try await localPlaylistCandidates(for: track)
    }

    private func localPlaylistCandidates(
        for track: LocalImportSpotifyTrack
    ) async throws -> [LocalImportAudioSourceMatch] {
        do {
            return try await searchRankedPlaylistCandidates(for: track)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return []
        }
    }

    private func serverReviewCandidates(
        for track: LocalImportSpotifyTrack,
        configuration: LocalImportServerConfiguration?
    ) async throws -> [LocalImportAudioSourceMatch] {
        guard let configuration else { return [] }
        do {
            return try await searchServerReviewCandidates(for: track, configuration: configuration)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return []
        }
    }

    private func searchServerReviewCandidates(
        for track: LocalImportSpotifyTrack,
        configuration: LocalImportServerConfiguration
    ) async throws -> [LocalImportAudioSourceMatch] {
        guard configuration.clientContext.profileID == configuration.profileID,
              configuration.clientContext.origin == ServerSongIdentity.normalizedOrigin(configuration.baseURL) else {
            return []
        }
        let endpoint = configuration.baseURL
            .appendingPathComponent("api", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("admin", isDirectory: true)
            .appendingPathComponent("debrid", isDirectory: true)
            .appendingPathComponent("resolve", isDirectory: false)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(configuration.adminToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.profileID, forHTTPHeaderField: "X-Resonance-Profile")
        request.setValue(MacClientConfigContext.platform, forHTTPHeaderField: "X-Resonance-Client-Platform")
        request.setValue(configuration.clientContext.appVersion, forHTTPHeaderField: "X-Resonance-App-Version")
        request.setValue(String(configuration.clientContext.appBuild), forHTTPHeaderField: "X-Resonance-App-Build")
        request.setValue(configuration.clientContext.cohortKey, forHTTPHeaderField: "X-Resonance-Cohort-Key")
        request.setValue(MacClientConfigContext.protocolVersion, forHTTPHeaderField: "X-Resonance-Config-Protocol")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["source": track.sourceURL])

        let (data, response) = try await responseData(
            session: sessions.server,
            request: request,
            limit: 1_024 * 1_024,
            rejectRedirects: true
        )
        guard (200..<300).contains(response.statusCode),
              response.url.map({ Self.sameOrigin($0, configuration.baseURL) }) == true,
              response.value(forHTTPHeaderField: "Content-Type")?
                .lowercased()
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) == "application/json" else {
            return []
        }
        let payload = try JSONDecoder().decode(ServerResolveResponse.self, from: data)
        var candidates: [LocalImportAudioSourceMatch] = []
        var seenVideoIDs = Set<String>()
        for source in payload.reviewCandidates ?? [] {
            guard source.actionable == false,
                  source.autoSelectable == false,
                  source.requiresReview == true,
                  let resolvedVideoID = try LocalImportURL.youtubeVideoID(source.sourceURL),
                  source.videoID == nil || source.videoID == resolvedVideoID,
                  let score = source.score,
                  let details = source.match,
                  let titleScore = details.title,
                  let artistScore = details.artist,
                  titleScore >= 0.48,
                  artistScore >= 0.28,
                  details.durationDeltaSeconds.map({ $0 <= 24 }) ?? true,
                  score >= 0.56,
                  seenVideoIDs.insert(resolvedVideoID).inserted,
                  !source.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let provider: LocalImportAudioSourceMatch.Provider
            switch source.provider {
            case "youtube_music": provider = .youtubeMusic
            case "youtube": provider = .youtube
            default: continue
            }
            candidates.append(LocalImportAudioSourceMatch(
                videoID: resolvedVideoID,
                title: String(source.title.prefix(500)),
                artist: source.artist.map { String($0.prefix(500)) },
                album: source.album.map { String($0.prefix(500)) },
                durationSeconds: source.durationSeconds,
                thumbnailURL: LocalImportURL.youtubeArtwork(source.thumbnailURL)?.absoluteString,
                sourceProvider: provider,
                officialArtist: false,
                sourceURL: "https://www.youtube.com/watch?v=\(resolvedVideoID)",
                score: min(max(score, 0), 1),
                confidence: String((source.confidence ?? "possible").prefix(32)),
                match: .init(
                    title: min(max(titleScore, 0), 1),
                    artist: min(max(artistScore, 0), 1),
                    album: details.album.map { min(max($0, 0), 1) },
                    duration: details.duration.map { min(max($0, 0), 1) },
                    durationDeltaSeconds: details.durationDeltaSeconds
                )
            ))
        }
        return candidates
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? {
            if let port = url.port { return port }
            return url.scheme?.lowercased() == "https" ? 443 : 80
        }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && port(lhs) == port(rhs)
            && lhs.user == nil
            && lhs.password == nil
    }

    private func searchBestCandidate(for track: LocalImportSpotifyTrack) async throws -> LocalImportAudioSourceMatch? {
        try await searchRankedPlaylistCandidates(for: track).first
    }

    private func searchRankedPlaylistCandidates(
        for track: LocalImportSpotifyTrack,
        limit: Int = 3
    ) async throws -> [LocalImportAudioSourceMatch] {
        let query = [track.artist, track.title, track.album].compactMap { $0 }.joined(separator: " ")
        var musicComponents = URLComponents(string: "https://music.youtube.com/search")!
        musicComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        var webComponents = URLComponents(string: "https://www.youtube.com/results")!
        webComponents.queryItems = [
            URLQueryItem(name: "search_query", value: "\(track.artist) \(track.title) official audio"),
            URLQueryItem(name: "sp", value: "EgIQAQ%3D%3D"),
        ]
        let musicURL = musicComponents.url!
        let webURL = webComponents.url!
        async let musicHTML = searchDocument(musicURL)
        async let webHTML = searchDocument(webURL)
        let documents = try await (musicHTML, webHTML)
        var unique: [String: LocalImportSearchCandidate] = [:]
        for candidate in (documents.0.map(LocalImportParser.youtubeMusicSearch) ?? []) + (documents.1.map(LocalImportParser.youtubeWebSearch) ?? []) {
            if unique[candidate.videoID] == nil || candidate.sourceProvider == .youtubeMusic {
                unique[candidate.videoID] = candidate
            }
        }
        return unique.values.compactMap { LocalImportMatcher.score(track: track, candidate: $0) }
            .sorted { $0.score > $1.score }
            .prefix(max(limit, 1))
            .map { $0 }
    }

    private func spotifyFailure(_ response: HTTPURLResponse) -> LocalImportError {
        if response.statusCode == 404 {
            return LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_NOT_FOUND", message: "Spotify could not find that track.")
        }
        if response.statusCode == 429 {
            return LocalImportError(
                stage: .resolvingMetadata,
                code: "SPOTIFY_RATE_LIMITED",
                message: "Spotify rate-limited the track request.",
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        if (300..<400).contains(response.statusCode) {
            return LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_REDIRECT", message: "Spotify returned an unsafe track redirect.")
        }
        return LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_PROVIDER_FAILED", message: "Spotify could not load that track.")
    }

    private func youtubeFailure(_ response: HTTPURLResponse) -> LocalImportError {
        if response.statusCode == 404 {
            return LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_UNAVAILABLE",
                message: "YouTube could not find that video."
            )
        }
        if response.statusCode == 429 {
            return LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_RATE_LIMITED",
                message: "YouTube rate-limited this metadata request.",
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return LocalImportError(
            stage: .resolvingMetadata,
            code: "YOUTUBE_PROVIDER_FAILED",
            message: "YouTube could not load that video's metadata."
        )
    }

    private func searchCandidates(for track: LocalImportSpotifyTrack) async throws -> [LocalImportAudioSourceMatch] {
        if let candidateSearchOverride {
            return try await candidateSearchOverride(track)
        }
        let query = [track.artist, track.title, track.album].compactMap { $0 }.joined(separator: " ")
        var musicComponents = URLComponents(string: "https://music.youtube.com/search")!
        musicComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        var webComponents = URLComponents(string: "https://www.youtube.com/results")!
        webComponents.queryItems = [
            URLQueryItem(name: "search_query", value: "\(track.artist) \(track.title) official audio"),
            URLQueryItem(name: "sp", value: "EgIQAQ%3D%3D"),
        ]
        let musicURL = musicComponents.url!
        let webURL = webComponents.url!
        async let musicHTML = searchDocument(musicURL)
        async let webHTML = searchDocument(webURL)
        let documents = try await (musicHTML, webHTML)
        var unique: [String: LocalImportSearchCandidate] = [:]
        for candidate in (documents.0.map(LocalImportParser.youtubeMusicSearch) ?? []) + (documents.1.map(LocalImportParser.youtubeWebSearch) ?? []) {
            if unique[candidate.videoID] == nil || candidate.sourceProvider == .youtubeMusic {
                unique[candidate.videoID] = candidate
            }
        }
        let preliminary = unique.values.compactMap { LocalImportMatcher.score(track: track, candidate: $0) }
            .sorted { $0.score > $1.score }
            .prefix(8)
        var enriched: [LocalImportAudioSourceMatch] = []
        for match in preliminary {
            try Task.checkCancellation()
            let candidate = await enrich(match, for: track)
            if let rescored = LocalImportMatcher.score(track: track, candidate: candidate) { enriched.append(rescored) }
        }
        return enriched.sorted { $0.score > $1.score }.prefix(8).map { $0 }
    }

    private func searchDebridVaultReleases(for track: LocalImportSpotifyTrack) async throws -> [LocalImportDebridRelease] {
        var components = URLComponents(string: "https://debridvault.elfhosted.com/api/torrents/search")!
        components.queryItems = [
            URLQueryItem(name: "artist", value: track.artist),
            URLQueryItem(name: "album", value: track.album ?? ""),
            URLQueryItem(name: "track", value: track.title),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await responseData(
                session: sessions.debridVault,
                request: request,
                limit: 2 * 1_024 * 1_024
            )
            guard (200..<300).contains(response.statusCode),
                  response.url.map(LocalImportURL.isDebridVaultDocument) == true else { return [] }
            return try LocalImportParser.debridVaultReleases(data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return []
        }
    }

    private func searchDocument(_ url: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await responseData(session: sessions.youtube, request: request, limit: maxDocumentBytes)
            guard (200..<300).contains(response.statusCode),
                  response.url.map(LocalImportURL.isYouTubeDocument) == true else { return nil }
            return String(data: data, encoding: .utf8)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    private func enrich(_ match: LocalImportAudioSourceMatch, for track: LocalImportSpotifyTrack) async -> LocalImportSearchCandidate {
        var artist = match.artist
        var album = match.album
        if let url = URL(string: match.sourceURL),
           let html = try? await searchDocument(url),
           let description = LocalImportParser.youtubeWatchDescription(html) {
            let normalized = LocalImportMatcher.normalize(description)
            if let targetAlbum = track.album, normalized.contains(LocalImportMatcher.normalize(targetAlbum)) { album = targetAlbum }
            if normalized.contains(LocalImportMatcher.normalize(track.artist)) { artist = track.artist }
        }
        return LocalImportSearchCandidate(
            videoID: match.videoID,
            title: match.title,
            artist: artist,
            album: album,
            durationSeconds: match.durationSeconds,
            thumbnailURL: match.thumbnailURL,
            sourceProvider: match.sourceProvider,
            officialArtist: match.officialArtist
        )
    }

    private func resolveYouTubeMedia(
        videoID: String,
        mediaMode: LocalImportMediaMode
    ) async throws -> ResolvedYouTubeMedia {
        let session = try await fetchYouTubeVisitorSession(videoID: videoID)
        let clients = [
            YouTubePlayerClient(
                client: [
                    "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
                    "deviceModel": "RealityDevice17,1", "userAgent": Self.visionOSUserAgent,
                    "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": "0",
                ],
                clientNumber: "101", userAgent: Self.visionOSUserAgent, origin: "https://www.youtube.com"
            ),
            YouTubePlayerClient(
                client: [
                    "clientName": "ANDROID_VR", "clientVersion": "1.65.10", "deviceMake": "Oculus",
                    "deviceModel": "Quest 3", "androidSdkVersion": "32", "userAgent": Self.androidVRUserAgent,
                    "osName": "Android", "osVersion": "12L", "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": "0",
                ],
                clientNumber: "28", userAgent: Self.androidVRUserAgent, origin: "https://www.youtube.com"
            ),
        ]
        var verificationError: LocalImportError?
        var lastError: LocalImportError?
        for client in clients {
            do {
                let player = try await fetchYouTubePlayer(videoID: videoID, visitor: session, client: client)
                let resolved = try resolvedYouTubeMedia(
                    videoID: videoID,
                    player: player,
                    client: client,
                    mediaMode: mediaMode
                )
                try await verifyYouTubeMedia(resolved)
                return resolved
            } catch let error as LocalImportError {
                if error.code == "YOUTUBE_PLAYBACK_VERIFICATION_REQUIRED" { verificationError = error }
                else { lastError = error }
            }
        }
        throw verificationError ?? lastError ?? LocalImportError(stage: .inspectingSource, code: "YOUTUBE_RESOLVE_FAILED", message: "YouTube could not resolve this video.")
    }

    private func fetchYouTubeVisitorSession(videoID: String) async throws -> YouTubeVisitorSession {
        let origins = ["https://www.youtube.com", "https://m.youtube.com", "https://music.youtube.com"]
        var pages = origins.compactMap { origin -> URL? in
            var components = URLComponents(string: origin + "/watch")
            components?.queryItems = [
                URLQueryItem(name: "v", value: videoID),
                URLQueryItem(name: "bpctr", value: "9999999999"),
                URLQueryItem(name: "has_verified", value: "1"),
            ]
            return components?.url
        }
        pages.append(URL(string: "https://www.youtube.com/embed/\(videoID)")!)
        pages.append(URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)")!)
        var reached = false
        var retryAfter: String?
        for page in pages {
            var request = URLRequest(url: page)
            request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("en-us,en;q=0.5", forHTTPHeaderField: "Accept-Language")
            do {
                let (data, response) = try await responseData(session: sessions.youtube, request: request, limit: maxDocumentBytes)
                reached = true
                if response.statusCode == 429 {
                    retryAfter = retryAfter ?? response.value(forHTTPHeaderField: "Retry-After")
                    continue
                }
                guard (200..<300).contains(response.statusCode), let html = String(data: data, encoding: .utf8),
                      let visitor = Self.youtubeVisitorData(html) else { continue }
                return YouTubeVisitorSession(visitorData: visitor, cookieHeader: Self.youtubeCookieHeader(response))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
        }
        if retryAfter != nil {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_RATE_LIMITED", message: "YouTube rate-limited this request.", retryAfter: retryAfter)
        }
        throw LocalImportError(
            stage: .inspectingSource,
            code: reached ? "YOUTUBE_SESSION_FAILED" : "YOUTUBE_UNREACHABLE",
            message: reached ? "YouTube did not provide an anonymous playback session." : "YouTube could not be reached."
        )
    }

    private func fetchYouTubePlayer(
        videoID: String,
        visitor: YouTubeVisitorSession,
        client: YouTubePlayerClient
    ) async throws -> [String: Any] {
        var lastError: LocalImportError?
        var retryAfter: String?
        for origin in ["https://www.youtube.com", "https://youtubei.googleapis.com"] {
            let url = URL(string: origin + "/youtubei/v1/player?prettyPrint=false")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(client.clientNumber, forHTTPHeaderField: "X-YouTube-Client-Name")
            request.setValue(client.client["clientVersion"], forHTTPHeaderField: "X-YouTube-Client-Version")
            request.setValue(visitor.visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            request.setValue(client.origin, forHTTPHeaderField: "Origin")
            request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
            if let cookie = visitor.cookieHeader { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            var clientObject: [String: Any] = client.client
            for key in ["androidSdkVersion", "utcOffsetMinutes"] {
                if let string = clientObject[key] as? String, let number = Int(string) { clientObject[key] = number }
            }
            clientObject["visitorData"] = visitor.visitorData
            let payload: [String: Any] = [
                "context": ["client": clientObject],
                "videoId": videoID,
                "playbackContext": ["contentPlaybackContext": ["html5Preference": "HTML5_PREF_WANTS"]],
                "contentCheckOk": true,
                "racyCheckOk": true,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            do {
                let (data, response) = try await responseData(session: sessions.youtube, request: request, limit: maxPlayerBytes)
                if response.statusCode == 429 {
                    retryAfter = retryAfter ?? response.value(forHTTPHeaderField: "Retry-After")
                    continue
                }
                guard (200..<300).contains(response.statusCode),
                      let player = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    lastError = LocalImportError(stage: .inspectingSource, code: "YOUTUBE_INVALID_PLAYER", message: "YouTube returned an invalid player response.")
                    continue
                }
                let status = (player["playabilityStatus"] as? [String: Any])?["status"] as? String
                if status == "OK" { return player }
                lastError = Self.youtubePlaybackFailure(Self.collectStrings(player["playabilityStatus"] as Any))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LocalImportError {
                lastError = error
            } catch {
                lastError = LocalImportError(stage: .inspectingSource, code: "YOUTUBE_RESOLVE_FAILED", message: "YouTube could not resolve this video.")
            }
        }
        if retryAfter != nil {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_RATE_LIMITED", message: "YouTube rate-limited this request.", retryAfter: retryAfter)
        }
        throw lastError ?? LocalImportError(stage: .inspectingSource, code: "YOUTUBE_RESOLVE_FAILED", message: "YouTube could not resolve this video.")
    }

    private func resolvedYouTubeMedia(
        videoID: String,
        player: [String: Any],
        client: YouTubePlayerClient,
        mediaMode: LocalImportMediaMode
    ) throws -> ResolvedYouTubeMedia {
        let details = player["videoDetails"] as? [String: Any] ?? [:]
        if let returnedID = details["videoId"] as? String, returnedID != videoID {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_MISMATCH", message: "YouTube returned the wrong video.")
        }
        if Self.bool(details["isLive"]) || Self.bool(details["isLiveContent"]) || Self.bool(details["isUpcoming"]) {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_LIVE_UNSUPPORTED", message: "Live and upcoming YouTube videos are not supported.")
        }
        let streaming = player["streamingData"] as? [String: Any] ?? [:]
        let adaptive = streaming["adaptiveFormats"] as? [[String: Any]] ?? []
        let formats = streaming["formats"] as? [[String: Any]] ?? []
        let streamHeaders = ["User-Agent": client.userAgent, "Origin": client.origin]

        func directStream(
            for format: [String: Any],
            mediaMode: LocalImportMediaMode
        ) -> ResolvedYouTubeStream? {
            let contentLength = Self.integer64(format["contentLength"])
            let maximumSize = mediaMode == .video ? maxVideoBytes : maxAudioBytes
            guard let streamValue = format["url"] as? String,
                  let streamURL = URL(string: streamValue),
                  LocalImportURL.isGoogleVideo(streamURL),
                  Self.integer(format["itag"]) > 0,
                  contentLength > 0,
                  contentLength <= maximumSize,
                  format["drmFamilies"] == nil,
                  (format["type"] as? String) != "FORMAT_STREAM_TYPE_OTF" else { return nil }
            let fallbackType = mediaMode == .video ? "video/mp4" : "audio/mp4"
            return ResolvedYouTubeStream(
                mediaMode: mediaMode,
                streamingURL: streamURL,
                streamingHeaders: streamHeaders,
                contentLength: contentLength,
                contentType: (format["mimeType"] as? String)?.split(separator: ";").first.map(String.init) ?? fallbackType,
                itag: Self.integer(format["itag"])
            )
        }

        func prefersVideo(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            let lhsMIME = (lhs["mimeType"] as? String ?? "").lowercased()
            let rhsMIME = (rhs["mimeType"] as? String ?? "").lowercased()
            let lhsH264 = lhsMIME.contains("avc1") ? 1 : 0
            let rhsH264 = rhsMIME.contains("avc1") ? 1 : 0
            if lhsH264 != rhsH264 { return lhsH264 > rhsH264 }
            let lhsHeight = Self.integer(lhs["height"])
            let rhsHeight = Self.integer(rhs["height"])
            if lhsHeight != rhsHeight { return lhsHeight > rhsHeight }
            return Self.integer64(lhs["averageBitrate"] ?? lhs["bitrate"])
                > Self.integer64(rhs["averageBitrate"] ?? rhs["bitrate"])
        }

        func prefersAudio(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
            let lhsPreference = Self.originalAudioPreference(lhs)
            let rhsPreference = Self.originalAudioPreference(rhs)
            if lhsPreference != rhsPreference { return lhsPreference > rhsPreference }
            return Self.integer64(lhs["averageBitrate"] ?? lhs["bitrate"])
                > Self.integer64(rhs["averageBitrate"] ?? rhs["bitrate"])
        }

        let primaryStream: ResolvedYouTubeStream
        let companionAudioStream: ResolvedYouTubeStream?
        if mediaMode == .video {
            let progressiveCandidates = formats.filter { format in
                let mime = (format["mimeType"] as? String ?? "").lowercased()
                return mime.hasPrefix("video/mp4")
                    && format["qualityLabel"] is String
                    && (format["audioQuality"] is String || Self.integer(format["audioChannels"]) > 0)
                    && directStream(for: format, mediaMode: .video) != nil
            }.sorted(by: prefersVideo)
            let audioCandidates = adaptive.filter { format in
                let mime = (format["mimeType"] as? String ?? "").lowercased()
                return mime.hasPrefix("audio/mp4")
                    && format["qualityLabel"] == nil
                    && directStream(for: format, mediaMode: .audio) != nil
            }.sorted(by: prefersAudio)

            let selectedAudioFormat = audioCandidates.first
            let selectedAudioStream = selectedAudioFormat.flatMap { directStream(for: $0, mediaMode: .audio) }
            let adaptiveVideoCandidates = adaptive.filter { format in
                let mime = (format["mimeType"] as? String ?? "").lowercased()
                guard mime.hasPrefix("video/mp4"),
                      format["qualityLabel"] is String,
                      let videoStream = directStream(for: format, mediaMode: .video),
                      let audioStream = selectedAudioStream else { return false }
                return videoStream.contentLength + audioStream.contentLength <= maxVideoBytes
            }.sorted(by: prefersVideo)

            let progressiveFormat = progressiveCandidates.first
            let adaptiveVideoFormat = adaptiveVideoCandidates.first
            let shouldUseAdaptivePair: Bool
            if let adaptiveVideoFormat {
                shouldUseAdaptivePair = progressiveFormat == nil
                    || Self.integer(adaptiveVideoFormat["height"]) > Self.integer(progressiveFormat?["height"])
            } else {
                shouldUseAdaptivePair = false
            }

            if shouldUseAdaptivePair,
               let adaptiveVideoFormat,
               let videoStream = directStream(for: adaptiveVideoFormat, mediaMode: .video),
               let audioStream = selectedAudioStream {
                primaryStream = videoStream
                companionAudioStream = audioStream
            } else if let progressiveFormat,
                      let videoStream = directStream(for: progressiveFormat, mediaMode: .video) {
                primaryStream = videoStream
                companionAudioStream = nil
            } else {
                throw LocalImportError(
                    stage: .inspectingSource,
                    code: "YOUTUBE_NO_VERIFIED_MP4",
                    message: "YouTube did not provide compatible direct MP4 video and M4A audio streams for this video."
                )
            }
        } else {
            let audioCandidates = (adaptive + formats).filter { format in
                let mime = (format["mimeType"] as? String ?? "").lowercased()
                return mime.hasPrefix("audio/mp4")
                    && format["qualityLabel"] == nil
                    && directStream(for: format, mediaMode: .audio) != nil
            }.sorted(by: prefersAudio)
            guard let audioFormat = audioCandidates.first,
                  let audioStream = directStream(for: audioFormat, mediaMode: .audio) else {
                throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_NO_VERIFIED_M4A", message: "YouTube did not provide a direct, verifiable M4A audio stream for this video.")
            }
            primaryStream = audioStream
            companionAudioStream = nil
        }

        let duration = Self.integer(details["lengthSeconds"])
        guard duration <= 24 * 60 * 60 else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_DURATION_TOO_LONG", message: "The selected \(mediaMode.rawValue) is too long to import.")
        }
        let thumbnails = (details["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? []
        let thumbnail = LocalImportArtworkPolicy.highestQualityYouTubeThumbnail(thumbnails)
        let preview = LocalImportYouTubePreview(
            videoID: videoID,
            title: cleanMetadata(details["title"] as? String, fallback: videoID),
            author: cleanMetadata(details["author"] as? String, fallback: "Unknown uploader"),
            durationSeconds: duration > 0 ? duration : nil,
            thumbnailURL: thumbnail,
            itag: primaryStream.itag,
            contentLength: primaryStream.contentLength + (companionAudioStream?.contentLength ?? 0),
            contentType: primaryStream.contentType,
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
        )
        return ResolvedYouTubeMedia(
            mediaMode: mediaMode,
            preview: preview,
            primaryStream: primaryStream,
            companionAudioStream: companionAudioStream
        )
    }

    private func verifyYouTubeMedia(_ media: ResolvedYouTubeMedia) async throws {
        try await verifyYouTubeStream(media.primaryStream)
        if let companion = media.companionAudioStream {
            try await verifyYouTubeStream(companion)
        }
    }

    private func verifyYouTubeStream(_ stream: ResolvedYouTubeStream) async throws {
        let mediaLabel = stream.mediaMode.rawValue
        var request = URLRequest(url: stream.streamingURL)
        stream.streamingHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (bytes, rawResponse) = try await sessions.googleVideo.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              response.url.map(LocalImportURL.isGoogleVideo) == true else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_UNSAFE_REDIRECT", message: "YouTube returned an unsafe \(mediaLabel) redirect.")
        }
        if response.statusCode == 403 {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "YOUTUBE_PLAYBACK_VERIFICATION_REQUIRED",
                message: "YouTube requires playback verification for this stream. Trying another playback client."
            )
        }
        if response.statusCode == 429 {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "YOUTUBE_RATE_LIMITED",
                message: "YouTube rate-limited the \(mediaLabel) stream probe.",
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        let expected = try LocalImportRangeVerifier.expectedLength(
            response.value(forHTTPHeaderField: "Content-Range"),
            start: 0,
            end: 0,
            total: stream.contentLength
        )
        let responseType = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
        guard response.statusCode == 206,
              expected == 1,
              response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) == 1,
              responseType == stream.contentType.lowercased() else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_STREAM_UNAVAILABLE", message: "YouTube returned an unverifiable \(mediaLabel) stream.")
        }
        var received = 0
        for try await _ in bytes {
            received += 1
            guard received <= 1 else {
                throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_STREAM_UNAVAILABLE", message: "YouTube returned an unverifiable \(mediaLabel) stream body.")
            }
        }
        guard received == 1 else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_STREAM_UNAVAILABLE", message: "YouTube returned no \(mediaLabel) stream data.")
        }
    }

    private func download(
        _ stream: ResolvedYouTubeStream,
        to destination: URL,
        completedOffset: Int64,
        total: Int64,
        progress: LocalImportProgressHandler
    ) async throws -> String {
        let mediaLabel = stream.mediaMode.rawValue
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else {
            throw LocalImportError(stage: .downloading, code: "LOCAL_WRITE_FAILED", message: "The temporary \(mediaLabel) file could not be created.")
        }
        var hasher = SHA256()
        var completed: Int64 = 0
        do {
            defer { try? file.close() }
            var start: Int64 = 0
            while start < stream.contentLength {
                try Task.checkCancellation()
                let end = min(stream.contentLength - 1, start + mediaChunkSize - 1)
                var request = URLRequest(url: stream.streamingURL)
                stream.streamingHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (bytes, rawResponse) = try await sessions.googleVideo.bytes(for: request)
                guard let response = rawResponse as? HTTPURLResponse,
                      response.url.map(LocalImportURL.isGoogleVideo) == true else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_UNSAFE_REDIRECT", message: "YouTube returned an unsafe \(mediaLabel) redirect.")
                }
                if response.statusCode == 429 {
                    throw LocalImportError(
                        stage: .downloading,
                        code: "YOUTUBE_RATE_LIMITED",
                        message: "YouTube rate-limited the \(mediaLabel) import.",
                        retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                    )
                }
                let expected: Int64
                if response.statusCode == 206 {
                    expected = try LocalImportRangeVerifier.expectedLength(
                        response.value(forHTTPHeaderField: "Content-Range"),
                        start: start,
                        end: end,
                        total: stream.contentLength
                    )
                } else if response.statusCode == 200, start == 0, end == stream.contentLength - 1 {
                    expected = stream.contentLength
                } else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_DOWNLOAD_FAILED", message: "The YouTube \(mediaLabel) stream could not be read.")
                }
                if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length != expected {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_SIZE_MISMATCH", message: "YouTube returned an unverifiable \(mediaLabel) size.")
                }
                var received: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1_024)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    received += 1
                    if received > expected {
                        throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_OVERFLOW", message: "YouTube returned more \(mediaLabel) data than requested.")
                    }
                    if buffer.count >= 64 * 1_024 {
                        try file.write(contentsOf: buffer)
                        hasher.update(data: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    if received % (256 * 1_024) == 0 {
                        await progress(.init(stage: .downloading, completed: completedOffset + completed + received, total: total))
                    }
                }
                if !buffer.isEmpty {
                    try file.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                }
                guard received == expected else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_TRUNCATED", message: "YouTube ended a \(mediaLabel) range before it was complete.")
                }
                completed += received
                await progress(.init(stage: .downloading, completed: completedOffset + completed, total: total))
                start = end + 1
            }
            guard completed == stream.contentLength else {
                throw LocalImportError(stage: .downloading, code: "YOUTUBE_SIZE_MISMATCH", message: "The downloaded \(mediaLabel) size could not be verified.")
            }
            try file.synchronize()
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? file.close()
            try? fileManager.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func fetchArtwork(_ value: String?) async -> Data? {
        let url = LocalImportURL.spotifyArtwork(value)
            ?? LocalImportURL.soundCloudArtwork(value)
            ?? LocalImportURL.youtubeArtwork(value)
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("image/avif,image/webp,image/png,image/jpeg", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await responseData(session: sessions.artwork, request: request, limit: maxArtworkBytes),
              (200..<300).contains(response.statusCode),
              let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              type.hasPrefix("image/"),
              let image = NSImage(data: data) else { return nil }
        // Keep JPEG and PNG bytes exactly as supplied. Convert newer provider
        // formats losslessly so AVFoundation can embed a broadly supported cover.
        if type.hasPrefix("image/jpeg") || type.hasPrefix("image/png") { return data }
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]),
              png.count <= maxArtworkBytes else { return nil }
        return png
    }

    private func responseData(
        session: URLSession,
        request: URLRequest,
        limit: Int,
        rejectRedirects: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let bytes: URLSession.AsyncBytes
            let rawResponse: URLResponse
            if rejectRedirects {
                (bytes, rawResponse) = try await session.bytes(
                    for: request,
                    delegate: MacRejectRedirectDelegate()
                )
            } else {
                (bytes, rawResponse) = try await session.bytes(for: request)
            }
            guard let response = rawResponse as? HTTPURLResponse else {
                throw LocalImportError(stage: .inspectingSource, code: "INVALID_PROVIDER_RESPONSE", message: "A provider returned an invalid response.")
            }
            if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), declared > limit {
                throw LocalImportError(stage: .inspectingSource, code: "PROVIDER_RESPONSE_TOO_LARGE", message: "A provider returned an oversized response.")
            }
            var data = Data()
            data.reserveCapacity(min(limit, 256 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else {
                    throw LocalImportError(stage: .inspectingSource, code: "PROVIDER_RESPONSE_TOO_LARGE", message: "A provider returned an oversized response.")
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private func prepareDirectories() async throws {
        guard !preparedDirectories else { return }
        try fileManager.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let entries = (try? fileManager.contentsOfDirectory(at: temporaryRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix("resonance-import-") {
            try? fileManager.removeItem(at: entry)
        }
        preparedDirectories = true
    }

    private func uniqueDestination(preferredFilename: String) throws -> URL {
        let ext = URL(fileURLWithPath: preferredFilename).pathExtension
        let base = URL(fileURLWithPath: preferredFilename).deletingPathExtension().lastPathComponent
        var candidate = localRoot.appendingPathComponent(preferredFilename)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = localRoot.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private static func combinedSourceHash(_ hashes: [String]) -> String {
        guard hashes.count > 1 else { return hashes.first ?? "" }
        return SHA256.hash(data: Data(hashes.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func hashFile(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func safeFilename(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let cleaned = value.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let result = String(cleaned.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Track-\(UUID().uuidString)" : result
    }

    private func cleanMetadata(_ value: String?, fallback: String) -> String {
        let cleaned = (value ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(500))
    }

    static func youtubeVisitorData(_ html: String) -> String? {
        let expression = try! NSRegularExpression(pattern: #""(?:VISITOR_DATA|visitorData)"\s*:\s*"((?:\\.|[^"\\])+)""#)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html) else { continue }
            let encoded = "\"\(html[capture])\""
            if let data = encoded.data(using: .utf8),
               let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
               !value.isEmpty, value.count <= 1_000 { return value }
        }
        return nil
    }

    private static func youtubeCookieHeader(_ response: HTTPURLResponse) -> String? {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        let allowed = Set(["GPS", "VISITOR_INFO1_LIVE", "VISITOR_PRIVACY_METADATA", "YSC", "__Secure-ROLLOUT_TOKEN", "__Secure-YEC", "__Secure-YNID"])
        let expression = try! NSRegularExpression(pattern: #"(?:^|,\s*)([!#$%&'*+\-.^_`|~0-9A-Za-z]+)=([^;,\r\n]*)"#)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let values = expression.matches(in: raw, range: range).compactMap { match -> String? in
            guard let nameRange = Range(match.range(at: 1), in: raw),
                  let valueRange = Range(match.range(at: 2), in: raw) else { return nil }
            let name = String(raw[nameRange])
            let value = String(raw[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(name), !value.isEmpty, value.count <= 2_048 else { return nil }
            return "\(name)=\(value)"
        }
        return values.isEmpty ? nil : values.joined(separator: "; ")
    }

    private static func youtubePlaybackFailure(_ reasons: [String]) -> LocalImportError {
        let message = reasons.joined(separator: " ")
        func contains(_ pattern: String) -> Bool {
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        if contains(#"rate.?limit|too many requests|\b429\b"#) {
            return .init(stage: .inspectingSource, code: "YOUTUBE_RATE_LIMITED", message: "YouTube rate-limited this request.")
        }
        if contains("private") { return .init(stage: .inspectingSource, code: "YOUTUBE_PRIVATE", message: "This YouTube video is private and cannot be imported.") }
        if contains("members?[- ]only|membership") { return .init(stage: .inspectingSource, code: "YOUTUBE_MEMBERS_ONLY", message: "This members-only YouTube video cannot be imported anonymously.") }
        if contains("proof of origin|po.?token|confirm.*not a bot|automated traffic") {
            return .init(stage: .inspectingSource, code: "YOUTUBE_PLAYBACK_VERIFICATION_REQUIRED", message: "YouTube requires playback verification for this video. Try another candidate.")
        }
        if contains("age|sign[ -]?in|login|required.*account") { return .init(stage: .inspectingSource, code: "YOUTUBE_SIGN_IN_REQUIRED", message: "YouTube requires sign-in or age verification for this video.") }
        if contains("not available in your country|country.*unavailable|geo.?restrict") { return .init(stage: .inspectingSource, code: "YOUTUBE_REGION_BLOCKED", message: "This YouTube video is not available from this device's region.") }
        if contains("unavailable|not available|does not exist|removed") { return .init(stage: .inspectingSource, code: "YOUTUBE_UNAVAILABLE", message: "YouTube says this video is unavailable. Check the URL or try another candidate.") }
        return .init(stage: .inspectingSource, code: "YOUTUBE_RESOLVE_FAILED", message: "YouTube could not resolve this video.")
    }

    private static func collectStrings(_ value: Any, output: [String] = []) -> [String] {
        if output.count >= 100 { return output }
        var result = output
        if let string = value as? String {
            let cleaned = string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !cleaned.isEmpty { result.append(cleaned) }
        } else if let array = value as? [Any] {
            for item in array where result.count < 100 { result = collectStrings(item, output: result) }
        } else if let object = value as? [String: Any] {
            for item in object.values where result.count < 100 { result = collectStrings(item, output: result) }
        }
        return result
    }

    private static func originalAudioPreference(_ format: [String: Any]) -> Int {
        let audioTrack = format["audioTrack"] as? [String: Any]
        if (audioTrack?["displayName"] as? String)?.localizedCaseInsensitiveContains("original") == true { return 10 }
        if bool(audioTrack?["audioIsDefault"]) { return 5 }
        return 0
    }

    private static func integer(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func integer64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? String { return Int64(value) ?? 0 }
        return 0
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private static let visionOSUserAgent = webUserAgent
    private static let androidVRUserAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
}

enum LocalImportMediaProcessor {
    private final class ExportSessionBox: @unchecked Sendable {
        let value: AVAssetExportSession

        init(_ value: AVAssetExportSession) {
            self.value = value
        }
    }

    static func remuxM4A(
        input: URL,
        output: URL,
        metadata: LocalImportMetadata,
        artwork: Data?
    ) async throws {
        try await remux(
            input: input,
            companionAudioInput: nil,
            output: output,
            mediaMode: .audio,
            metadata: metadata,
            artwork: artwork
        )
    }

    static func remux(
        input: URL,
        companionAudioInput: URL? = nil,
        output: URL,
        mediaMode: LocalImportMediaMode,
        metadata: LocalImportMetadata,
        artwork: Data?
    ) async throws {
        let asset: AVAsset
        if let companionAudioInput {
            guard mediaMode == .video else {
                throw LocalImportError(
                    stage: .processing,
                    code: "MEDIA_PROCESSING_FAILED",
                    message: "A separate audio stream can only be combined with video."
                )
            }
            asset = try await composition(videoInput: input, audioInput: companionAudioInput)
        } else {
            asset = AVURLAsset(url: input)
        }
        let fileType: AVFileType = mediaMode == .video ? .mp4 : .m4a
        let preset = mediaMode == .audio && input.pathExtension.lowercased() == "mp3"
            ? AVAssetExportPresetAppleM4A
            : AVAssetExportPresetPassthrough
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(fileType) else {
            throw LocalImportError(
                stage: .processing,
                code: "MEDIA_PROCESSOR_UNAVAILABLE",
                message: "The local media processor cannot prepare this \(mediaMode.rawValue) file."
            )
        }
        var items = [
            metadataItem(.commonIdentifierTitle, value: metadata.title as NSString),
            metadataItem(.commonIdentifierArtist, value: metadata.artist as NSString),
        ]
        if let album = metadata.album, !album.isEmpty {
            items.append(metadataItem(.commonIdentifierAlbumName, value: album as NSString))
        }
        if let artwork {
            items.append(metadataItem(.commonIdentifierArtwork, value: artwork as NSData))
        }
        exporter.metadata = items
        exporter.shouldOptimizeForNetworkUse = true
        let box = ExportSessionBox(exporter)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.value.outputURL = output
                box.value.outputFileType = fileType
                box.value.exportAsynchronously {
                    switch box.value.status {
                    case .completed:
                        continuation.resume()
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    default:
                        continuation.resume(throwing: LocalImportError(
                            stage: .processing,
                            code: "MEDIA_PROCESSING_FAILED",
                            message: box.value.error?.localizedDescription ?? "The local \(mediaMode.rawValue) metadata remux failed."
                        ))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
    }

    private static func composition(videoInput: URL, audioInput: URL) async throws -> AVMutableComposition {
        let videoAsset = AVURLAsset(url: videoInput)
        let audioAsset = AVURLAsset(url: audioInput)
        guard let sourceVideoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw LocalImportError(
                stage: .processing,
                code: "MEDIA_PROCESSING_FAILED",
                message: "The separate YouTube video and audio streams could not be combined."
            )
        }

        let videoTimeRange = try await sourceVideoTrack.load(.timeRange)
        let audioTimeRange = try await sourceAudioTrack.load(.timeRange)
        guard videoTimeRange.duration.isNumeric,
              videoTimeRange.duration.seconds > 0,
              audioTimeRange.duration.isNumeric,
              audioTimeRange.duration.seconds > 0 else {
            throw LocalImportError(
                stage: .processing,
                code: "MEDIA_PROCESSING_FAILED",
                message: "The separate YouTube streams had invalid durations."
            )
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw LocalImportError(
                stage: .processing,
                code: "MEDIA_PROCESSOR_UNAVAILABLE",
                message: "The local media processor cannot combine this video."
            )
        }

        let sharedDuration = CMTimeMinimum(videoTimeRange.duration, audioTimeRange.duration)
        let trimmedVideoRange = CMTimeRange(start: videoTimeRange.start, duration: sharedDuration)
        let trimmedAudioRange = CMTimeRange(start: audioTimeRange.start, duration: sharedDuration)
        try compositionVideoTrack.insertTimeRange(trimmedVideoRange, of: sourceVideoTrack, at: .zero)
        try compositionAudioTrack.insertTimeRange(trimmedAudioRange, of: sourceAudioTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
        return composition
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item.copy() as! AVMetadataItem
    }
}
