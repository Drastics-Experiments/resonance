import UIKit
import AVFoundation
import CryptoKit
import Foundation

typealias LocalImportProgressHandler = @MainActor @Sendable (LocalImportProgress) -> Void

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
    private struct ResolvedYouTubeAudio: Sendable {
        let preview: LocalImportYouTubePreview
        let streamingURL: URL
        let streamingHeaders: [String: String]
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
    private var preparedDirectories = false

    private let maxDocumentBytes = 6 * 1_024 * 1_024
    private let maxPlayerBytes = 4 * 1_024 * 1_024
    private let maxArtworkBytes = 10 * 1_024 * 1_024
    private let maxAudioBytes: Int64 = 256 * 1_024 * 1_024
    private let audioChunkSize: Int64 = 10 * 1_024 * 1_024

    init(
        sessions: LocalImportSessions = .production(),
        localRoot: URL? = nil,
        temporaryRoot: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.sessions = sessions
        self.temporaryRoot = temporaryRoot
        self.fileManager = fileManager
        if let localRoot {
            self.localRoot = localRoot
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.localRoot = support
                .appendingPathComponent(MobileLegacyAppMigration.applicationSupportName, isDirectory: true)
                .appendingPathComponent("LocalImports", isDirectory: true)
        }
    }

    func search(query: String) async throws -> LocalImportSearchResponse {
        try Task.checkCancellation()
        return try await LocalImportSearchEngine(sessions: sessions).search(query)
    }

    func resolve(source: String, progress: LocalImportProgressHandler) async throws -> LocalImportResolution {
        try Task.checkCancellation()
        try await prepareDirectories()
        if LocalImportURL.isSoundCloud(source) {
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

        guard let videoID = try LocalImportURL.youtubeVideoID(source) else {
            throw LocalImportError(stage: .resolvingMetadata, code: "UNSUPPORTED_SOURCE", message: "Enter a Spotify, SoundCloud, or supported YouTube track or playlist URL.")
        }
        await progress(.init(stage: .inspectingSource))
        let resolved = try await resolveYouTubeAudio(videoID: videoID)
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

    func importCandidate(
        _ candidate: LocalImportAudioSourceMatch,
        metadata inputMetadata: LocalImportMetadata,
        existingTracks: [MobileTrack],
        progress: LocalImportProgressHandler
    ) async throws -> LocalImportOutcome {
        try Task.checkCancellation()
        try await prepareDirectories()
        if candidate.sourceProvider == .soundcloud {
            return try await importSoundCloudCandidate(
                candidate,
                metadata: inputMetadata,
                existingTracks: existingTracks,
                progress: progress
            )
        }
        let temporary = temporaryRoot.appendingPathComponent("resonance-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }

        let source = temporary.appendingPathComponent("source.m4a")
        let processed = temporary.appendingPathComponent("processed.m4a")
        await progress(.init(stage: .inspectingSource))
        let videoID = try LocalImportURL.youtubeVideoID(candidate.sourceURL)
        guard let videoID else {
            throw LocalImportError(stage: .inspectingSource, code: "INVALID_YOUTUBE_VIDEO", message: "The selected source is not a supported YouTube video.")
        }
        let resolved = try await resolveYouTubeAudio(videoID: videoID)
        let sourceAssociation = LocalImportSourceAssociation(
            sourceURL: inputMetadata.sourceURL,
            downloadSourceURL: resolved.streamingURL
        )
        let sourceHash = try await download(resolved, to: source, progress: progress)
        if let duplicate = existingTracks.first(where: {
            $0.sourceSHA256 == sourceHash || $0.contentSHA256 == sourceHash
        }) {
            return .duplicate(duplicate.id, source: sourceAssociation)
        }

        try Task.checkCancellation()
        await progress(.init(stage: .processing))
        let metadata = LocalImportMetadata(
            title: cleanMetadata(inputMetadata.title, fallback: resolved.preview.title),
            artist: cleanMetadata(inputMetadata.artist, fallback: resolved.preview.author ?? "Unknown uploader"),
            album: cleanMetadata(inputMetadata.album, fallback: "Imported"),
            artworkURL: inputMetadata.artworkURL ?? resolved.preview.thumbnailURL,
            sourceURL: inputMetadata.sourceURL
        )
        let artwork = await fetchArtwork(metadata.artworkURL)
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
                throw LocalImportError(stage: .savingLocal, code: "INVALID_LOCAL_MEDIA", message: "The completed local audio file is not playable.")
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

    private func importSoundCloudCandidate(
        _ candidate: LocalImportAudioSourceMatch,
        metadata inputMetadata: LocalImportMetadata,
        existingTracks: [MobileTrack],
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
            title: cleanMetadata(inputMetadata.title, fallback: stream.track.title),
            artist: cleanMetadata(inputMetadata.artist, fallback: stream.track.artist),
            album: cleanMetadata(inputMetadata.album, fallback: stream.track.album ?? "SoundCloud"),
            artworkURL: inputMetadata.artworkURL ?? stream.track.artworkURL,
            sourceURL: inputMetadata.sourceURL
        )
        let artwork = await fetchArtwork(metadata.artworkURL)
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

    func previewStream(for candidate: LocalImportAudioSourceMatch) async throws -> LocalImportPreviewStream {
        try Task.checkCancellation()
        if candidate.sourceProvider == .soundcloud {
            let stream = try await LocalImportSoundCloud.resolveAudio(
                source: candidate.sourceURL,
                session: sessions.soundcloud
            )
            return LocalImportPreviewStream(url: stream.streamingURL, httpHeaders: [:])
        }
        guard let videoID = try LocalImportURL.youtubeVideoID(candidate.sourceURL) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "INVALID_YOUTUBE_VIDEO",
                message: "The selected source is not a supported YouTube video."
            )
        }
        let resolved = try await resolveYouTubeAudio(videoID: videoID)
        return LocalImportPreviewStream(url: resolved.streamingURL, httpHeaders: resolved.streamingHeaders)
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

    private func searchCandidates(for track: LocalImportSpotifyTrack) async throws -> [LocalImportAudioSourceMatch] {
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

    private func resolveYouTubeAudio(videoID: String) async throws -> ResolvedYouTubeAudio {
        let session = try await fetchYouTubeVisitorSession(videoID: videoID)
        let clients = [
            YouTubePlayerClient(
                client: [
                    "clientName": "ANDROID_VR", "clientVersion": "1.65.10", "deviceMake": "Oculus",
                    "deviceModel": "Quest 3", "androidSdkVersion": "32", "userAgent": Self.androidVRUserAgent,
                    "osName": "Android", "osVersion": "12L", "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": "0",
                ],
                clientNumber: "28", userAgent: Self.androidVRUserAgent, origin: "https://www.youtube.com"
            ),
            YouTubePlayerClient(
                client: [
                    "clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
                    "deviceModel": "RealityDevice17,1", "userAgent": Self.visionOSUserAgent,
                    "osName": "visionOS", "osVersion": "26.5.23O471", "hl": "en", "timeZone": "UTC", "utcOffsetMinutes": "0",
                ],
                clientNumber: "101", userAgent: Self.visionOSUserAgent, origin: "https://www.youtube.com"
            ),
        ]
        var verificationError: LocalImportError?
        var lastError: LocalImportError?
        for client in clients {
            do {
                let player = try await fetchYouTubePlayer(videoID: videoID, visitor: session, client: client)
                return try resolvedYouTubeAudio(videoID: videoID, player: player, client: client)
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

    private func resolvedYouTubeAudio(
        videoID: String,
        player: [String: Any],
        client: YouTubePlayerClient
    ) throws -> ResolvedYouTubeAudio {
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
        let candidates = (adaptive + formats).filter { format in
            let mime = format["mimeType"] as? String ?? ""
            return mime.lowercased().hasPrefix("audio/mp4")
                && format["url"] is String
                && Self.integer(format["itag"]) > 0
                && Self.integer64(format["contentLength"]) > 0
                && format["qualityLabel"] == nil
                && format["drmFamilies"] == nil
                && (format["type"] as? String) != "FORMAT_STREAM_TYPE_OTF"
        }.sorted { lhs, rhs in
            let preference = Self.originalAudioPreference(rhs) - Self.originalAudioPreference(lhs)
            if preference != 0 { return preference < 0 }
            return Self.integer64(rhs["averageBitrate"] ?? rhs["bitrate"]) < Self.integer64(lhs["averageBitrate"] ?? lhs["bitrate"])
        }
        guard let format = candidates.first,
              let streamValue = format["url"] as? String,
              let streamURL = URL(string: streamValue), LocalImportURL.isGoogleVideo(streamURL) else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_NO_VERIFIED_M4A", message: "YouTube did not provide a direct, verifiable M4A audio stream for this video.")
        }
        let contentLength = Self.integer64(format["contentLength"])
        guard contentLength > 0, contentLength <= maxAudioBytes else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_AUDIO_TOO_LARGE", message: "The selected audio is too large to import on this device.")
        }
        let duration = Self.integer(details["lengthSeconds"])
        guard duration <= 24 * 60 * 60 else {
            throw LocalImportError(stage: .inspectingSource, code: "YOUTUBE_DURATION_TOO_LONG", message: "The selected audio is too long to import.")
        }
        let thumbnails = ((details["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]] ?? [])
            .sorted { Self.integer($0["width"]) > Self.integer($1["width"]) }
        let thumbnail = thumbnails.compactMap { LocalImportURL.youtubeArtwork($0["url"] as? String)?.absoluteString }.first
        let preview = LocalImportYouTubePreview(
            videoID: videoID,
            title: cleanMetadata(details["title"] as? String, fallback: videoID),
            author: cleanMetadata(details["author"] as? String, fallback: "Unknown uploader"),
            durationSeconds: duration > 0 ? duration : nil,
            thumbnailURL: thumbnail,
            itag: Self.integer(format["itag"]),
            contentLength: contentLength,
            contentType: "audio/mp4",
            sourceURL: "https://www.youtube.com/watch?v=\(videoID)"
        )
        return ResolvedYouTubeAudio(
            preview: preview,
            streamingURL: streamURL,
            streamingHeaders: ["User-Agent": client.userAgent, "Origin": client.origin]
        )
    }

    private func download(
        _ resolved: ResolvedYouTubeAudio,
        to destination: URL,
        progress: LocalImportProgressHandler
    ) async throws -> String {
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else {
            throw LocalImportError(stage: .downloading, code: "LOCAL_WRITE_FAILED", message: "The temporary audio file could not be created.")
        }
        var hasher = SHA256()
        var completed: Int64 = 0
        do {
            defer { try? file.close() }
            var start: Int64 = 0
            while start < resolved.preview.contentLength {
                try Task.checkCancellation()
                let end = min(resolved.preview.contentLength - 1, start + audioChunkSize - 1)
                var request = URLRequest(url: resolved.streamingURL)
                resolved.streamingHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                let (bytes, rawResponse) = try await sessions.googleVideo.bytes(for: request)
                guard let response = rawResponse as? HTTPURLResponse,
                      response.url.map(LocalImportURL.isGoogleVideo) == true else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_UNSAFE_REDIRECT", message: "YouTube returned an unsafe audio redirect.")
                }
                if response.statusCode == 429 {
                    throw LocalImportError(
                        stage: .downloading,
                        code: "YOUTUBE_RATE_LIMITED",
                        message: "YouTube rate-limited the audio import.",
                        retryAfter: response.value(forHTTPHeaderField: "Retry-After")
                    )
                }
                let expected: Int64
                if response.statusCode == 206 {
                    expected = try LocalImportRangeVerifier.expectedLength(
                        response.value(forHTTPHeaderField: "Content-Range"),
                        start: start,
                        end: end,
                        total: resolved.preview.contentLength
                    )
                } else if response.statusCode == 200, start == 0, end == resolved.preview.contentLength - 1 {
                    expected = resolved.preview.contentLength
                } else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_DOWNLOAD_FAILED", message: "The YouTube audio stream could not be read.")
                }
                if let length = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length != expected {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_SIZE_MISMATCH", message: "YouTube returned an unverifiable audio size.")
                }
                var received: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(64 * 1_024)
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    received += 1
                    if received > expected {
                        throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_OVERFLOW", message: "YouTube returned more audio data than requested.")
                    }
                    if buffer.count >= 64 * 1_024 {
                        try file.write(contentsOf: buffer)
                        hasher.update(data: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                    if received % (256 * 1_024) == 0 {
                        await progress(.init(stage: .downloading, completed: completed + received, total: resolved.preview.contentLength))
                    }
                }
                if !buffer.isEmpty {
                    try file.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                }
                guard received == expected else {
                    throw LocalImportError(stage: .downloading, code: "YOUTUBE_RANGE_TRUNCATED", message: "YouTube ended an audio range before it was complete.")
                }
                completed += received
                await progress(.init(stage: .downloading, completed: completed, total: resolved.preview.contentLength))
                start = end + 1
            }
            guard completed == resolved.preview.contentLength else {
                throw LocalImportError(stage: .downloading, code: "YOUTUBE_SIZE_MISMATCH", message: "The downloaded audio size could not be verified.")
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
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
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
        let asset = AVURLAsset(url: input)
        let preset = input.pathExtension.lowercased() == "mp3"
            ? AVAssetExportPresetAppleM4A
            : AVAssetExportPresetPassthrough
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset),
              exporter.supportedFileTypes.contains(.m4a) else {
            throw LocalImportError(stage: .processing, code: "MEDIA_PROCESSOR_UNAVAILABLE", message: "The local media processor cannot remux this M4A file.")
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
                box.value.outputFileType = .m4a
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
                            message: box.value.error?.localizedDescription ?? "The local M4A metadata remux failed."
                        ))
                    }
                }
            }
        } onCancel: {
            box.value.cancelExport()
        }
    }

    private static func metadataItem(_ identifier: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        return item.copy() as! AVMetadataItem
    }
}
