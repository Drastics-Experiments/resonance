import UIKit
import AVFoundation
import CryptoKit
import Foundation

struct LocalImportSoundCloudOperations: Sendable {
    let resolveAudio: @Sendable (String, URLSession) async throws -> LocalImportSoundCloudAudioStream

    static let production = LocalImportSoundCloudOperations(
        resolveAudio: { source, session in
            try await LocalImportSoundCloud.resolveAudio(source: source, session: session)
        }
    )
}

typealias LocalImportProgressHandler = @MainActor @Sendable (LocalImportProgress) -> Void

@MainActor
private final class LocalImportCombinedProgress {
    private var completedByStream: [Int64]
    private let total: Int64
    private let progress: LocalImportProgressHandler

    init(streamCount: Int, total: Int64, progress: @escaping LocalImportProgressHandler) {
        completedByStream = Array(repeating: 0, count: streamCount)
        self.total = total
        self.progress = progress
    }

    func update(streamIndex: Int, completed: Int64) {
        completedByStream[streamIndex] = completed
        progress(.init(
            stage: .downloading,
            completed: completedByStream.reduce(0, +),
            total: total
        ))
    }
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

enum LocalImportBoundedDataError: Error {
    case tooLarge
}

enum LocalImportRangeProgressPolicy {
    static func absoluteCompleted(
        completedBeforeRange: Int64,
        receivedInRange: Int64,
        total: Int64
    ) -> Int64 {
        guard total > 0 else { return 0 }
        let base = max(completedBeforeRange, 0)
        let received = max(receivedInRange, 0)
        let sum = base.addingReportingOverflow(received)
        return min(sum.overflow ? total : sum.partialValue, total)
    }
}

/// Receives URLSession body chunks directly instead of iterating AsyncBytes one
/// byte at a time. Each operation is still strictly bounded before data is
/// accumulated, and it inherits the caller's ephemeral/test configuration.
final class LocalImportBoundedDataOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let maximumSize: Int
    private let redirectValidator: @Sendable (URL) -> Bool
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var data = Data()
    private var lastReportedByteCount: Int64 = 0
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isFinished = false

    init(
        session: URLSession,
        maximumSize: Int,
        redirectValidator: @escaping @Sendable (URL) -> Bool,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) {
        configuration = session.configuration
        self.maximumSize = maximumSize
        self.redirectValidator = redirectValidator
        self.progress = progress
        super.init()
    }

    func run(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .utility
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: queue
                )
                let task = session.dataTask(with: request)

                lock.lock()
                let alreadyFinished = isFinished
                if !alreadyFinished {
                    self.continuation = continuation
                    self.session = session
                    self.task = task
                    data.reserveCapacity(min(maximumSize, 1 * 1_024 * 1_024))
                }
                lock.unlock()

                if alreadyFinished {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                } else if Task.isCancelled {
                    cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url.map(redirectValidator) == true ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            complete(with: .failure(URLError(.badServerResponse)))
            return
        }
        if response.expectedContentLength > Int64(maximumSize) {
            completionHandler(.cancel)
            complete(with: .failure(LocalImportBoundedDataError.tooLarge))
            return
        }
        lock.lock()
        if !isFinished { self.response = response }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive incoming: Data
    ) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        let remaining = maximumSize - data.count
        guard incoming.count <= remaining else {
            lock.unlock()
            dataTask.cancel()
            complete(with: .failure(LocalImportBoundedDataError.tooLarge))
            return
        }
        data.append(incoming)
        let completedByteCount = Int64(data.count)
        let shouldReportProgress = MobileTransferByteProgressPolicy.shouldReport(
            completedBytes: completedByteCount,
            lastReportedBytes: lastReportedByteCount,
            totalBytes: Int64(maximumSize)
        )
        if shouldReportProgress {
            lastReportedByteCount = completedByteCount
        }
        lock.unlock()
        if shouldReportProgress {
            progress(completedByteCount)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            complete(with: .failure(error))
            return
        }
        lock.lock()
        let result = response.map { (data, $0) }
        lock.unlock()
        guard let result else {
            complete(with: .failure(URLError(.badServerResponse)))
            return
        }
        complete(with: .success(result))
    }

    private func cancel() {
        complete(with: .failure(CancellationError()))
    }

    private func complete(with result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        let finalProgress: Int64?
        switch result {
        case .success(let completedResult):
            finalProgress = Int64(completedResult.0.count)
            lastReportedByteCount = Int64(completedResult.0.count)
        case .failure:
            finalProgress = nil
        }
        lock.unlock()

        // Publish the exact final range count before resuming run(), even if
        // the last data callback happened to land on a throttle boundary.
        if let finalProgress {
            progress(finalProgress)
        }
        switch result {
        case .success:
            session?.finishTasksAndInvalidate()
        case .failure:
            session?.invalidateAndCancel()
        }
        continuation?.resume(with: result)
    }
}

struct LocalImportSessions: @unchecked Sendable {
    let spotify: URLSession
    let soundcloud: URLSession
    let youtube: URLSession
    let debridVault: URLSession
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
            // Provider search uses short-lived anonymous cookies to keep
            // consecutive YouTube documents from degrading into empty results.
            youtube: session(acceptsCookies: true) { LocalImportURL.isYouTubeDocument($0) },
            debridVault: session { LocalImportURL.isDebridVaultDocument($0) },
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
            googleVideo: session,
            artwork: session
        )
    }
}

enum LocalImportRangeVerifier {
    static func expectedLength(_ value: String?, start: Int64, end: Int64, total: Int64) throws -> Int64 {
        guard let value else {
            throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_MISMATCH", message: "YouTube returned an unverifiable audio range.")
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
            throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_MISMATCH", message: "YouTube returned an unverifiable audio range.")
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
                .appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
                .appendingPathComponent("LocalImports", isDirectory: true)
        }
    }

    func search(
        query: String,
        mediaMode: LocalImportMediaMode = .audio
    ) async throws -> LocalImportSearchResponse {
        try Task.checkCancellation()
        return try await LocalImportSearchEngine(sessions: sessions).search(
            query,
            mediaMode: mediaMode
        )
    }

    func resolveMetadata(source: String) async throws -> LocalImportSpotifyTrack {
        try Task.checkCancellation()

        if LocalImportURL.isSoundCloud(source) {
            switch try await LocalImportSoundCloud.resolve(source: source, session: sessions.soundcloud) {
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

        if (try LocalImportURL.youtubePlaylist(source)) != nil {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "PLAYLIST_METADATA_UNSUPPORTED",
                message: "A saved server song must identify one video, not a playlist."
            )
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

    /// Prepares a downloadable source from metadata that already came from
    /// the server catalog. Saved-link downloads still need a fresh media URL,
    /// but they must not repeat the provider metadata request first.
    func resolveUsingCatalogMetadata(
        source: String,
        metadata: LocalImportSpotifyTrack,
        mediaMode: LocalImportMediaMode = .audio,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportResolution {
        try Task.checkCancellation()

        if LocalImportURL.isSoundCloud(source) {
            guard mediaMode == .audio else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_AUDIO_ONLY",
                    message: "SoundCloud links can only be imported as audio."
                )
            }
            await progress(.init(stage: .inspectingSource))
            do {
                _ = try await soundCloudOperations.resolveAudio(source, sessions.soundcloud)
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
                    candidates: candidates
                )
            }
            let candidate = LocalImportAudioSourceMatch(
                videoID: metadata.trackID,
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                durationSeconds: metadata.durationSeconds,
                thumbnailURL: metadata.artworkURL,
                sourceProvider: .soundcloud,
                officialArtist: false,
                sourceURL: source,
                score: 1,
                confidence: "catalog",
                match: .init(
                    title: 1,
                    artist: 1,
                    album: metadata.album == nil ? nil : 1,
                    duration: metadata.durationSeconds == nil ? nil : 1,
                    durationDeltaSeconds: metadata.durationSeconds == nil ? nil : 0
                )
            )
            return LocalImportResolution(
                kind: .soundCloud,
                track: metadata,
                candidates: [candidate]
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
            let canonicalSource = try await canonicalSpotifySource(source)
            guard let spotifyTrack = try LocalImportURL.spotifyTrack(canonicalSource.absoluteString) else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "PLAYLIST_METADATA_UNSUPPORTED",
                    message: "A saved server song must identify one track, not a playlist."
                )
            }
            let catalogTrack = LocalImportSpotifyTrack(
                provider: "spotify",
                type: "track",
                trackID: spotifyTrack.trackID,
                title: metadata.title,
                artist: metadata.artist,
                album: metadata.album,
                trackNumber: metadata.trackNumber,
                durationSeconds: metadata.durationSeconds,
                artworkURL: metadata.artworkURL,
                embedURL: metadata.embedURL,
                sourceURL: spotifyTrack.url.absoluteString
            )
            await progress(.init(stage: .searchingCandidates))
            let candidates = try await searchCandidates(for: catalogTrack)
            guard !candidates.isEmpty else {
                throw LocalImportError(
                    stage: .searchingCandidates,
                    code: "NO_AUDIO_MATCH",
                    message: "No sufficiently close YouTube audio match was found. Try a YouTube URL instead."
                )
            }
            return LocalImportResolution(
                kind: .spotify,
                track: catalogTrack,
                candidates: candidates
            )
        }

        if (try LocalImportURL.youtubePlaylist(source)) != nil {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "PLAYLIST_METADATA_UNSUPPORTED",
                message: "A saved server song must identify one video, not a playlist."
            )
        }
        guard let videoID = try LocalImportURL.youtubeVideoID(source) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SOURCE",
                message: "Enter a Spotify, SoundCloud, or supported YouTube track URL."
            )
        }
        await progress(.init(stage: .inspectingSource))
        let catalogTrack = LocalImportSpotifyTrack(
            provider: "youtube",
            type: "track",
            trackID: videoID,
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            trackNumber: metadata.trackNumber,
            durationSeconds: metadata.durationSeconds,
            artworkURL: metadata.artworkURL,
            embedURL: metadata.embedURL,
            sourceURL: source
        )
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
            confidence: "catalog",
            match: .init(
                title: 1,
                artist: 1,
                album: metadata.album == nil ? nil : 1,
                duration: metadata.durationSeconds == nil ? nil : 1,
                durationDeltaSeconds: metadata.durationSeconds == nil ? nil : 0
            )
        )
        return LocalImportResolution(
            kind: .youtube,
            track: catalogTrack,
            candidates: [candidate]
        )
    }

    func resolve(
        source: String,
        mediaMode: LocalImportMediaMode = .audio,
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
            let soundCloudSource = try await LocalImportSoundCloud.resolve(source: source, session: sessions.soundcloud)
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
                return LocalImportResolution(kind: .soundCloud, track: track, candidates: candidates)

            case .playlist(let soundCloudPlaylist):
                await progress(.init(stage: .searchingCandidates))
                let matches = try await matchSoundCloudPlaylistTracks(soundCloudPlaylist.tracks)
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
                    provider: "soundcloud", type: "playlist", trackID: soundCloudPlaylist.playlistID,
                    title: soundCloudPlaylist.title, artist: soundCloudPlaylist.author, album: nil,
                    trackNumber: nil, durationSeconds: duration > 0 ? duration : nil,
                    artworkURL: soundCloudPlaylist.artworkURL, embedURL: "", sourceURL: soundCloudPlaylist.sourceURL
                )
                return LocalImportResolution(
                    kind: .soundCloudPlaylist,
                    track: summary,
                    candidates: matches.items.map(\.candidate),
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
                let matches = try await matchSpotifyPlaylistTracks(playlistMetadata.tracks)
                guard !matches.items.isEmpty else {
                    throw LocalImportError(
                        stage: .searchingCandidates,
                        code: "NO_AUDIO_MATCH",
                        message: "No close YouTube audio match was found for the public tracks in this Spotify playlist."
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
                    provider: "spotify", type: "playlist", trackID: canonicalPlaylist.playlistID,
                    title: playlistMetadata.title, artist: playlistMetadata.author, album: nil,
                    trackNumber: nil, durationSeconds: duration > 0 ? duration : nil,
                    artworkURL: playlistMetadata.artworkURL,
                    embedURL: "https://open.spotify.com/embed/playlist/\(canonicalPlaylist.playlistID)",
                    sourceURL: canonicalPlaylist.url.absoluteString
                )
                return LocalImportResolution(
                    kind: .spotifyPlaylist,
                    track: summary,
                    candidates: matches.items.map(\.candidate),
                    playlist: playlist
                )
            }
            let track = try await resolveSpotify(source)
            await progress(.init(stage: .searchingCandidates))
            let candidates = try await searchCandidates(for: track)
            guard !candidates.isEmpty else {
                throw LocalImportError(
                    stage: .searchingCandidates,
                    code: "NO_AUDIO_MATCH",
                    message: "No sufficiently close YouTube audio match was found. Try a YouTube URL instead."
                )
            }
            return LocalImportResolution(kind: .spotify, track: track, candidates: candidates)
        }

        if let canonicalPlaylist = try LocalImportURL.youtubePlaylist(source) {
            await progress(.init(stage: .resolvingMetadata))
            let playlistMetadata = try await resolveYouTubePlaylist(canonicalPlaylist)
            guard !playlistMetadata.items.isEmpty else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "YOUTUBE_PLAYLIST_EMPTY",
                    message: "This YouTube playlist has no public, downloadable videos."
                )
            }
            // Keep the provider's original numbering when unavailable entries
            // were filtered out during metadata resolution. This keeps the
            // visible order aligned with the skipped-item diagnostics.
            let skippedPositions = Set(playlistMetadata.skippedItems.map(\LocalImportPlaylistSkippedItem.position))
            var nextPlaylistPosition = 1
            let playlistItems = playlistMetadata.items.map { candidate in
                while skippedPositions.contains(nextPlaylistPosition) {
                    nextPlaylistPosition += 1
                }
                let position = nextPlaylistPosition
                nextPlaylistPosition += 1
                let track = LocalImportSpotifyTrack(
                    provider: "youtube",
                    type: "track",
                    trackID: candidate.videoID,
                    title: candidate.title,
                    artist: candidate.artist ?? "Unknown uploader",
                    album: candidate.album,
                    trackNumber: position,
                    durationSeconds: candidate.durationSeconds,
                    artworkURL: candidate.thumbnailURL,
                    embedURL: "",
                    sourceURL: candidate.sourceURL
                )
                return LocalImportPlaylistItem(
                    position: position,
                    track: track,
                    candidate: candidate
                )
            }
            let playlist = LocalImportPlaylist(
                playlistID: canonicalPlaylist.playlistID,
                title: playlistMetadata.title ?? "YouTube Playlist",
                author: playlistMetadata.author ?? "YouTube",
                artworkURL: playlistMetadata.artworkURL ?? playlistItems.first?.track.artworkURL,
                sourceURL: canonicalPlaylist.url.absoluteString,
                items: playlistItems,
                skippedItems: playlistMetadata.skippedItems
            )
            let duration = playlistItems.compactMap(\.track.durationSeconds).reduce(0, +)
            let summary = LocalImportSpotifyTrack(
                provider: "youtube",
                type: "playlist",
                trackID: canonicalPlaylist.playlistID,
                title: playlist.title,
                artist: playlist.author,
                album: nil,
                trackNumber: nil,
                durationSeconds: duration > 0 ? duration : nil,
                artworkURL: playlist.artworkURL,
                embedURL: "",
                sourceURL: canonicalPlaylist.url.absoluteString
            )
            return LocalImportResolution(
                kind: .youtubePlaylist,
                track: summary,
                candidates: playlistItems.map(\.candidate),
                playlist: playlist
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
        return LocalImportResolution(kind: .youtube, track: track, candidates: [candidate])
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
            throw youtubeMetadataFailure(response)
        }
        let metadata = try JSONDecoder().decode(YouTubeOEmbedResponse.self, from: data)
        let title = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = metadata.authorName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadata.type == "video",
              metadata.providerName == "YouTube",
              !title.isEmpty,
              !artist.isEmpty else {
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
            title: title,
            artist: artist,
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
        existingTracks: [MobileTrack],
        mediaMode: LocalImportMediaMode = .audio,
        includeArtwork: Bool = true,
        preferResolvedMetadata: Bool = false,
        progress: @escaping LocalImportProgressHandler
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
                existingTracks: existingTracks,
                includeArtwork: includeArtwork,
                preferResolvedMetadata: preferResolvedMetadata,
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
        let progressTracker = await MainActor.run {
            LocalImportCombinedProgress(
                streamCount: resolved.companionAudioStream == nil ? 1 : 2,
                total: totalDownloadBytes,
                progress: progress
            )
        }
        let primaryProgress: LocalImportProgressHandler = { update in
            progressTracker.update(streamIndex: 0, completed: update.completed)
        }
        var sourceHashes: [String]
        var companionAudioInput: URL?
        if let audioStream = resolved.companionAudioStream {
            let audioProgress: LocalImportProgressHandler = { update in
                progressTracker.update(streamIndex: 1, completed: update.completed)
            }
            async let primaryHash = download(
                resolved.primaryStream,
                to: source,
                completedOffset: 0,
                total: resolved.primaryStream.contentLength,
                progress: primaryProgress
            )
            async let audioHash = download(
                audioStream,
                to: companionAudio,
                completedOffset: 0,
                total: audioStream.contentLength,
                progress: audioProgress
            )
            sourceHashes = try await [primaryHash, audioHash]
            companionAudioInput = companionAudio
        } else {
            sourceHashes = [try await download(
                resolved.primaryStream,
                to: source,
                completedOffset: 0,
                total: totalDownloadBytes,
                progress: primaryProgress
            )]
        }
        let sourceHash = Self.combinedSourceHash(sourceHashes)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        await progress(.init(stage: .processing))
        let metadata = LocalImportMetadata(
            title: preferResolvedMetadata
                ? resolved.preview.title
                : cleanMetadata(inputMetadata.title, fallback: resolved.preview.title),
            artist: preferResolvedMetadata
                ? (resolved.preview.author ?? "Unknown uploader")
                : cleanMetadata(inputMetadata.artist, fallback: resolved.preview.author ?? "Unknown uploader"),
            album: preferResolvedMetadata
                ? "Imported"
                : cleanMetadata(inputMetadata.album, fallback: "Imported"),
            artworkURL: preferResolvedMetadata
                ? (resolved.preview.thumbnailURL ?? inputMetadata.artworkURL)
                : LocalImportArtworkPolicy.preferredArtwork(
                    metadataURL: inputMetadata.artworkURL,
                    resolvedYouTubeURL: resolved.preview.thumbnailURL
                ),
            sourceURL: inputMetadata.sourceURL
        )
        let artwork = includeArtwork ? await fetchArtwork(metadata.artworkURL) : nil
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
        existingTracks: [MobileTrack],
        includeArtwork: Bool,
        preferResolvedMetadata: Bool,
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportOutcome {
        let temporary = temporaryRoot.appendingPathComponent("resonance-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source.mp3")
        let processed = temporary.appendingPathComponent("processed.m4a")
        await progress(.init(stage: .inspectingSource))
        let stream = try await LocalImportSoundCloud.resolveAudio(
            source: candidate.sourceURL,
            session: sessions.soundcloud
        )
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
        let metadata = LocalImportMetadata(
            title: preferResolvedMetadata
                ? stream.track.title
                : cleanMetadata(inputMetadata.title, fallback: stream.track.title),
            artist: preferResolvedMetadata
                ? stream.track.artist
                : cleanMetadata(inputMetadata.artist, fallback: stream.track.artist),
            album: preferResolvedMetadata
                ? (stream.track.album ?? "SoundCloud")
                : cleanMetadata(inputMetadata.album, fallback: stream.track.album ?? "SoundCloud"),
            artworkURL: preferResolvedMetadata
                ? (stream.track.artworkURL ?? inputMetadata.artworkURL)
                : (inputMetadata.artworkURL ?? stream.track.artworkURL),
            sourceURL: inputMetadata.sourceURL
        )
        let artwork = includeArtwork ? await fetchArtwork(metadata.artworkURL) : nil
        try Task.checkCancellation()
        do {
            try await LocalImportMediaProcessor.remuxM4A(input: source, output: processed, metadata: metadata, artwork: artwork)
        } catch is CancellationError {
            throw CancellationError()
        } catch where artwork != nil {
            try? fileManager.removeItem(at: processed)
            try await LocalImportMediaProcessor.remuxM4A(input: source, output: processed, metadata: metadata, artwork: nil)
        }
        let contentHash = try hashFile(processed)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash || $0.contentSHA256 == contentHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

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
                contentSHA256: contentHash
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
                    code: "SOUNDCLOUD_VIDEO_UNSUPPORTED",
                    message: "SoundCloud Listen Along playback is audio-only."
                )
            }
            let stream = try await LocalImportSoundCloud.resolveAudio(
                source: candidate.sourceURL,
                session: sessions.soundcloud
            )
            return LocalImportPreviewStream(url: stream.streamingURL, httpHeaders: LocalImportSoundCloud.streamHeaders)
        }
        guard let videoID = try LocalImportURL.youtubeVideoID(candidate.sourceURL) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_YOUTUBE_VIDEO",
                message: "The selected source is not a supported YouTube video."
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
        if ["open.spotify.com", "www.open.spotify.com"].contains(sourceURL.host?.lowercased() ?? "") { return sourceURL }
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
        var components = URLComponents()
        components.scheme = "https"
        components.host = "open.spotify.com"
        components.path = "/oembed"
        components.queryItems = [URLQueryItem(name: "url", value: canonical.url.absoluteString)]
        guard let oEmbedURL = components.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        var request = URLRequest(url: oEmbedURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (oEmbedData, oEmbedResponse) = try await responseData(session: sessions.spotify, request: request, limit: 256 * 1_024)
        guard (200..<300).contains(oEmbedResponse.statusCode) else { throw spotifyFailure(oEmbedResponse) }
        let oEmbed = try LocalImportParser.spotifyPlaylistOEmbed(oEmbedData, expectedPlaylistID: canonical.playlistID)
        guard let embedURL = URL(string: oEmbed.embedURL) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "SPOTIFY_INVALID_PREVIEW", message: "Spotify returned an invalid playlist preview.")
        }
        request = URLRequest(url: embedURL)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Resonance/1.0", forHTTPHeaderField: "User-Agent")
        let (embedData, embedResponse) = try await responseData(session: sessions.spotify, request: request, limit: maxDocumentBytes)
        guard (200..<300).contains(embedResponse.statusCode), let html = String(data: embedData, encoding: .utf8) else {
            throw spotifyFailure(embedResponse)
        }
        let embedded = try LocalImportParser.spotifyPlaylistEmbed(html, expectedPlaylistID: canonical.playlistID)
        let artworkURL = embedded.artworkURL ?? oEmbed.artworkURL
        let tracks = try await hydrateSpotifyPlaylistTrackArtwork(embedded.tracks)
        return (embedded.title, embedded.author, artworkURL, tracks, embedded.skippedItems)
    }

    private func resolveYouTubePlaylist(
        _ canonical: (url: URL, playlistID: String)
    ) async throws -> (
        title: String?,
        author: String?,
        artworkURL: String?,
        items: [LocalImportAudioSourceMatch],
        skippedItems: [LocalImportPlaylistSkippedItem],
        truncated: Bool
    ) {
        let (html, _) = try await searchDocumentResponse(canonical.url)
        guard let initialData = LocalImportParser.youtubeInitialData(html) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_INVALID",
                message: "YouTube returned invalid playlist metadata."
            )
        }
        let firstPage = try LocalImportParser.youtubePlaylistData(
            initialData,
            expectedPlaylistID: canonical.playlistID
        )
        let maxItems = LocalImportYouTubePlaylistLimitPolicy.maxItems
        let initialRows = LocalImportYouTubePlaylistLimitPolicy.takeRows(
            items: firstPage.items,
            skippedItems: firstPage.skippedItems,
            maximum: maxItems,
            startingPosition: 1
        )
        var items = initialRows.items
        var skippedItems = initialRows.skippedItems
        var title = firstPage.title
        var author = firstPage.author
        var artworkURL = firstPage.artworkURL
        var continuation = firstPage.continuation
        let configuration = (
            apiKey: youtubeConfigurationValue(html, key: "INNERTUBE_API_KEY", maximum: 256),
            clientVersion: youtubeConfigurationValue(html, key: "INNERTUBE_CLIENT_VERSION", maximum: 128),
            visitorData: youtubeConfigurationValue(html, key: "VISITOR_DATA", maximum: 2_048)
        )
        let maxContinuations = 10
        var truncated = initialRows.truncated
        var continuationCount = 0
        var seenTokens = Set<String>()
        while let token = continuation,
              !token.isEmpty,
              items.count < maxItems,
              continuationCount < maxContinuations,
              !seenTokens.contains(token),
              let apiKey = configuration.apiKey,
              let clientVersion = configuration.clientVersion {
            try Task.checkCancellation()
            seenTokens.insert(token)
            guard let response = try await youtubePlaylistContinuation(
                token: token,
                apiKey: apiKey,
                clientVersion: clientVersion,
                visitorData: configuration.visitorData
            ) else { break }
            let offset = items.count + skippedItems.count
            let page = try LocalImportParser.youtubePlaylistData(
                response,
                expectedPlaylistID: canonical.playlistID,
                positionOffset: offset
            )
            if title == nil { title = page.title }
            if author == nil { author = page.author }
            if artworkURL == nil { artworkURL = page.artworkURL }
            let remaining = maxItems - items.count
            let pageRows = LocalImportYouTubePlaylistLimitPolicy.takeRows(
                items: page.items,
                skippedItems: page.skippedItems,
                maximum: remaining,
                startingPosition: offset + 1
            )
            items.append(contentsOf: pageRows.items)
            skippedItems.append(contentsOf: pageRows.skippedItems)
            truncated = truncated || pageRows.truncated
            continuation = page.continuation
            continuationCount += 1
        }
        guard !items.isEmpty else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_EMPTY",
                message: "This YouTube playlist has no public, downloadable videos."
            )
        }
        truncated = truncated || continuation != nil
        if truncated {
            skippedItems.append(LocalImportPlaylistSkippedItem(
                position: (items.count + skippedItems.count) + 1,
                title: "More playlist items",
                artist: nil,
                reason: items.count >= maxItems
                    ? "The playlist is limited to the first 500 playable videos."
                    : "YouTube did not return the rest of this playlist; the available items can still be downloaded."
            ))
        }
        return (
            title,
            author,
            artworkURL ?? items.first?.thumbnailURL,
            items,
            skippedItems.sorted { $0.position < $1.position },
            truncated
        )
    }

    private func searchDocumentResponse(_ url: URL) async throws -> (html: String, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await responseData(
                session: sessions.youtube,
                request: request,
                limit: maxDocumentBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalImportError {
            throw error
        } catch {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_UNREACHABLE",
                message: "YouTube could not load that playlist."
            )
        }
        guard (200..<300).contains(response.statusCode),
              response.url.map(LocalImportURL.isYouTubeDocument) == true,
              let html = String(data: data, encoding: .utf8) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "YOUTUBE_PLAYLIST_UNREACHABLE",
                message: "YouTube could not load that playlist."
            )
        }
        return (html, response)
    }

    private func youtubePlaylistContinuation(
        token: String,
        apiKey: String,
        clientVersion: String,
        visitorData: String?
    ) async throws -> Any? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/youtubei/v1/browse"
        components.queryItems = [
            URLQueryItem(name: "prettyPrint", value: "false"),
            URLQueryItem(name: "key", value: apiKey),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        var client: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": clientVersion,
            "hl": "en",
            "gl": "US",
        ]
        if let visitorData { client["visitorData"] = visitorData }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": ["client": client],
            "continuation": token,
        ])
        do {
            let (data, response) = try await responseData(
                session: sessions.youtube,
                request: request,
                limit: maxDocumentBytes
            )
            guard (200..<300).contains(response.statusCode),
                  response.url.map(LocalImportURL.isYouTubeDocument) == true else { return nil }
            return try JSONSerialization.jsonObject(with: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func youtubeConfigurationValue(
        _ html: String,
        key: String,
        maximum: Int
    ) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        guard let expression = try? NSRegularExpression(
            pattern: "\\\"\(escapedKey)\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"\\\\])*)\\\""
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for match in expression.matches(in: html, range: range) {
            guard let capture = Range(match.range(at: 1), in: html) else { continue }
            let encoded = "\"\(html[capture])\""
            guard let data = encoded.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String,
                  !value.isEmpty, value.count <= maximum else { continue }
            return value
        }
        return nil
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
        _ tracks: [LocalImportSpotifyTrack]
    ) async throws -> (items: [LocalImportPlaylistItem], skippedItems: [LocalImportPlaylistSkippedItem]) {
        var output: [LocalImportPlaylistItem] = []
        var unresolved: [SpotifyPlaylistTrackMatch] = []
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            if index > 0 { try await Task.sleep(for: .milliseconds(250)) }
            let match = try await matchSpotifyPlaylistTrack(track)
            if let item = match.item { output.append(item) }
            else { unresolved.append(match) }
        }
        if !unresolved.isEmpty {
            var remaining: [SpotifyPlaylistTrackMatch] = []
            for match in unresolved.sorted(by: { ($0.track.trackNumber ?? 0) < ($1.track.trackNumber ?? 0) }) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(500))
                let retried = try await matchSpotifyPlaylistTrack(match.track)
                if let item = retried.item { output.append(item) }
                else { remaining.append(retried) }
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
        _ tracks: [LocalImportSoundCloudTrack]
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
            let alternatives: [LocalImportAudioSourceMatch]
            do {
                alternatives = try await searchCandidates(for: track)
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
        _ track: LocalImportSpotifyTrack
    ) async throws -> SpotifyPlaylistTrackMatch {
        do {
            let candidates = try await searchCandidates(for: track)
            guard let candidate = candidates.first else {
                return .init(track: track, item: nil, failureReason: "No close YouTube audio match")
            }
            return .init(
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
            return .init(track: track, item: nil, failureReason: "Audio source search failed")
        }
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

    private func youtubeMetadataFailure(_ response: HTTPURLResponse) -> LocalImportError {
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
        progress: @escaping LocalImportProgressHandler
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
                let (rangeProgressStream, rangeProgressContinuation) = AsyncStream<Int64>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                let completedBeforeRange = LocalImportRangeProgressPolicy.absoluteCompleted(
                    completedBeforeRange: completedOffset,
                    receivedInRange: completed,
                    total: total
                )
                let rangeProgressTask = Task { @MainActor in
                    for await receivedInRange in rangeProgressStream {
                        guard !Task.isCancelled else { break }
                        progress(.init(
                            stage: .downloading,
                            completed: LocalImportRangeProgressPolicy.absoluteCompleted(
                                completedBeforeRange: completedBeforeRange,
                                receivedInRange: receivedInRange,
                                total: total
                            ),
                            total: total
                        ))
                    }
                }
                let operation = LocalImportBoundedDataOperation(
                    session: sessions.googleVideo,
                    maximumSize: Int(end - start + 1),
                    redirectValidator: { url in LocalImportURL.isGoogleVideo(url) },
                    progress: { completedInRange in
                        _ = rangeProgressContinuation.yield(completedInRange)
                    }
                )
                let body: Data
                let response: HTTPURLResponse
                do {
                    (body, response) = try await operation.run(request: request)
                    rangeProgressContinuation.finish()
                    await rangeProgressTask.value
                } catch {
                    rangeProgressContinuation.finish()
                    rangeProgressTask.cancel()
                    await rangeProgressTask.value
                    guard !(error is LocalImportBoundedDataError) else {
                        throw LocalImportError(
                            stage: .downloading,
                            code: "YOUTUBE_RANGE_OVERFLOW",
                            message: "YouTube returned more \(mediaLabel) data than requested."
                        )
                    }
                    throw error
                }
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard response.url.map(LocalImportURL.isGoogleVideo) == true else {
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
                try Task.checkCancellation()
                let received = Int64(body.count)
                guard received == expected else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_TRUNCATED", message: "YouTube ended a \(mediaLabel) range before it was complete.")
                }
                try file.write(contentsOf: body)
                hasher.update(data: body)
                completed += received
                await progress(.init(
                    stage: .downloading,
                    completed: LocalImportRangeProgressPolicy.absoluteCompleted(
                        completedBeforeRange: completedOffset,
                        receivedInRange: completed,
                        total: total
                    ),
                    total: total
                ))
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

    func artworkData(for value: String?) async -> Data? {
        await fetchArtwork(value)
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
              let jpeg = MobileArtworkImagePolicy.jpegData(from: data) else { return nil }
        return jpeg
    }

    private func responseData(
        session: URLSession,
        request: URLRequest,
        limit: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
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
        return result.isEmpty ? "MobileTrack-\(UUID().uuidString)" : result
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
