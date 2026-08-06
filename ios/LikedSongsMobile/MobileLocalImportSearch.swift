import Foundation

enum LocalImportSearchProvider: String, CaseIterable, Hashable, Identifiable, Sendable {
    case spotify
    case soundcloud
    case youtube

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .soundcloud: "SoundCloud"
        case .youtube: "YouTube"
        }
    }
}

struct LocalImportSearchResult: Hashable, Identifiable, Sendable {
    var id: String { "\(provider.rawValue):\(track.trackID)" }
    let provider: LocalImportSearchProvider
    let track: LocalImportSpotifyTrack
    let candidates: [LocalImportAudioSourceMatch]

    var resolution: LocalImportResolution {
        let kind: LocalImportResolution.Kind = switch provider {
        case .spotify: .spotify
        case .soundcloud: .soundCloud
        case .youtube: .youtube
        }
        return LocalImportResolution(kind: kind, track: track, candidates: candidates)
    }
}

struct LocalImportSearchResponse: Hashable, Sendable {
    let query: String
    let results: [LocalImportSearchResult]

    func results(for provider: LocalImportSearchProvider) -> [LocalImportSearchResult] {
        results.filter { $0.provider == provider }
    }
}

enum LocalImportInput {
    static func looksLikeLink(_ value: String) -> Bool {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return false }
        if input.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) != nil {
            return true
        }
        guard input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return input.range(of: #"^www\."#, options: [.regularExpression, .caseInsensitive]) != nil
            || input.range(of: #"^[^/?#]+\.[A-Za-z]{2,}(?:[/?#:]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

enum LocalImportSearchParser {
    static func spotifyTracks(_ data: Data) -> [LocalImportSpotifyTrack] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let values = payload["tracks"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return values.compactMap { value in
            guard let trackID = clean(value["id"] as? String, maximum: 22),
                  trackID.range(of: "^[A-Za-z0-9]{22}$", options: .regularExpression) != nil,
                  !seen.contains(trackID),
                  let title = clean(value["title"] as? String),
                  let artist = clean(value["artist"] as? String) else { return nil }
            seen.insert(trackID)
            let rawDuration = number(value["duration"])
            let seconds = rawDuration.flatMap { value -> Int? in
                guard value > 0 else { return nil }
                return Int((value > 86_400 ? value / 1_000 : value).rounded())
            }
            return LocalImportSpotifyTrack(
                provider: "spotify",
                type: "track",
                trackID: trackID,
                title: title,
                artist: artist,
                album: clean(value["album"] as? String),
                trackNumber: nonnegativeInteger(value["trackNumber"]),
                durationSeconds: seconds,
                artworkURL: LocalImportURL.spotifyArtwork(value["artworkURL"] as? String)?.absoluteString,
                embedURL: "https://open.spotify.com/embed/track/\(trackID)",
                sourceURL: "https://open.spotify.com/track/\(trackID)"
            )
        }
    }

    private static func clean(_ value: String?, maximum: Int = 500) -> String? {
        guard let value else { return nil }
        let cleaned = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximum))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.int64Value
        guard result >= 0, result <= Int64(Int.max), Double(result) == number.doubleValue else { return nil }
        return Int(result)
    }
}

struct LocalImportSearchEngine: Sendable {
    private let sessions: LocalImportSessions
    private let maxDocumentBytes = 8 * 1_024 * 1_024
    private let maximumResultsPerProvider = 6

    init(sessions: LocalImportSessions) {
        self.sessions = sessions
    }

    func search(_ value: String) async throws -> LocalImportSearchResponse {
        let query = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LocalImportError(stage: .searchingCandidates, code: "MISSING_SEARCH_QUERY", message: "Enter a song, artist, or album to search.")
        }
        guard query.count <= 200 else {
            throw LocalImportError(stage: .searchingCandidates, code: "SEARCH_QUERY_TOO_LONG", message: "Keep music searches under 200 characters.")
        }
        guard !LocalImportInput.looksLikeLink(value) else {
            throw LocalImportError(
                stage: .searchingCandidates,
                code: "SEARCH_QUERY_IS_LINK",
                message: "Links are inspected directly instead of being sent to music search providers."
            )
        }

        async let spotifyTask = spotifyTracksIgnoringFailure(query)
        async let soundCloudTask = soundCloudTracksIgnoringFailure(query)
        async let youtubeTask = youtubeCandidatesIgnoringFailure(query)
        let (spotifyTracks, soundCloudTracks, youtubeCandidates) = await (spotifyTask, soundCloudTask, youtubeTask)
        try Task.checkCancellation()

        let spotify = spotifyTracks.compactMap { track -> LocalImportSearchResult? in
            let candidates = matchedCandidates(for: track, from: youtubeCandidates)
            guard !candidates.isEmpty else { return nil }
            return LocalImportSearchResult(provider: .spotify, track: track, candidates: candidates)
        }
        let soundCloud = soundCloudTracks.compactMap { soundCloudTrack -> LocalImportSearchResult? in
            let alternatives = matchedCandidates(for: soundCloudTrack.metadata, from: youtubeCandidates)
            let candidates = [soundCloudTrack.directCandidate].compactMap { $0 } + alternatives
            guard !candidates.isEmpty else { return nil }
            return LocalImportSearchResult(provider: .soundcloud, track: soundCloudTrack.metadata, candidates: uniqueCandidates(candidates))
        }
        let youtube = youtubeCandidates.prefix(maximumResultsPerProvider).map { candidate in
            let sourceURL = "https://www.youtube.com/watch?v=\(candidate.videoID)"
            let track = LocalImportSpotifyTrack(
                provider: candidate.sourceProvider.rawValue,
                type: "track",
                trackID: candidate.videoID,
                title: candidate.title,
                artist: candidate.artist ?? "Unknown uploader",
                album: candidate.album,
                trackNumber: nil,
                durationSeconds: candidate.durationSeconds,
                artworkURL: candidate.thumbnailURL,
                embedURL: "",
                sourceURL: sourceURL
            )
            return LocalImportSearchResult(provider: .youtube, track: track, candidates: [directCandidate(candidate)])
        }
        let results = spotify + soundCloud + youtube
        guard !results.isEmpty else {
            throw LocalImportError(
                stage: .searchingCandidates,
                code: "NO_SEARCH_RESULTS",
                message: "Spotify, SoundCloud, and YouTube returned no previewable results for that search."
            )
        }
        return LocalImportSearchResponse(query: query, results: results)
    }

    private func spotifyTracksIgnoringFailure(_ query: String) async -> [LocalImportSpotifyTrack] {
        do { return try await spotifyTracks(query) }
        catch { return [] }
    }

    private func soundCloudTracksIgnoringFailure(_ query: String) async -> [LocalImportSoundCloudTrack] {
        do { return try await soundCloudTracks(query) }
        catch { return [] }
    }

    private func youtubeCandidatesIgnoringFailure(_ query: String) async -> [LocalImportSearchCandidate] {
        do { return try await youtubeCandidates(query) }
        catch { return [] }
    }

    private func spotifyTracks(_ query: String) async throws -> [LocalImportSpotifyTrack] {
        var components = URLComponents(string: "https://debridvault.elfhosted.com/api/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "provider", value: "spotify"),
        ]
        guard let url = components.url else { return [] }
        let data = try await boundedData(
            session: sessions.debridVault,
            request: providerRequest(url, accept: "application/json"),
            limit: 2 * 1_024 * 1_024,
            validator: LocalImportURL.isDebridVaultDocument
        )
        return LocalImportSearchParser.spotifyTracks(data)
            .sorted { relevance(query, $0) > relevance(query, $1) }
            .prefix(maximumResultsPerProvider).map { $0 }
    }

    private func soundCloudTracks(_ query: String) async throws -> [LocalImportSoundCloudTrack] {
        var pageComponents = URLComponents(string: "https://soundcloud.com/search/sounds")!
        pageComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let pageURL = pageComponents.url else { return [] }
        let pageData = try await boundedData(
            session: sessions.soundcloud,
            request: providerRequest(pageURL, accept: "text/html,application/xhtml+xml"),
            limit: maxDocumentBytes,
            validator: LocalImportURL.isSoundCloudPage
        )
        guard let html = String(data: pageData, encoding: .utf8) else { return [] }
        let hydration = try LocalImportSoundCloudParser.hydration(html)
        guard let clientID = LocalImportSoundCloudParser.clientID(hydration) else { return [] }
        var apiComponents = URLComponents(string: "https://api-v2.soundcloud.com/search/tracks")!
        apiComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "linked_partitioning", value: "1"),
        ]
        guard let apiURL = apiComponents.url else { return [] }
        let apiData = try await boundedData(
            session: sessions.soundcloud,
            request: providerRequest(apiURL, accept: "application/json"),
            limit: maxDocumentBytes,
            validator: LocalImportURL.isSoundCloudAPI
        )
        guard let root = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any],
              let values = root["collection"] as? [Any] else { return [] }
        return values.compactMap { LocalImportSoundCloudParser.track($0) }
            .sorted { relevance(query, $0.metadata) > relevance(query, $1.metadata) }
            .prefix(maximumResultsPerProvider).map { $0 }
    }

    private func youtubeCandidates(_ query: String) async throws -> [LocalImportSearchCandidate] {
        var musicComponents = URLComponents(string: "https://music.youtube.com/search")!
        musicComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        var webComponents = URLComponents(string: "https://www.youtube.com/results")!
        webComponents.queryItems = [
            URLQueryItem(name: "search_query", value: query),
            URLQueryItem(name: "sp", value: "EgIQAQ%3D%3D"),
        ]
        guard let musicURL = musicComponents.url, let webURL = webComponents.url else { return [] }
        async let music = optionalYouTubeDocument(musicURL)
        async let web = optionalYouTubeDocument(webURL)
        let documents = await (music, web)
        try Task.checkCancellation()
        var unique: [String: LocalImportSearchCandidate] = [:]
        for candidate in (documents.0.map(LocalImportParser.youtubeMusicSearch) ?? [])
            + (documents.1.map(LocalImportParser.youtubeWebSearch) ?? []) {
            if unique[candidate.videoID] == nil || candidate.sourceProvider == .youtubeMusic {
                unique[candidate.videoID] = candidate
            }
        }
        return unique.values.sorted { relevance(query, $0) > relevance(query, $1) }.prefix(12).map { $0 }
    }

    private func optionalYouTubeDocument(_ url: URL) async -> String? {
        do {
            let data = try await boundedData(
                session: sessions.youtube,
                request: providerRequest(url, accept: "text/html,application/xhtml+xml"),
                limit: maxDocumentBytes,
                validator: LocalImportURL.isYouTubeDocument
            )
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func matchedCandidates(
        for track: LocalImportSpotifyTrack,
        from candidates: [LocalImportSearchCandidate]
    ) -> [LocalImportAudioSourceMatch] {
        candidates.compactMap { LocalImportMatcher.score(track: track, candidate: $0) }
            .sorted { $0.score > $1.score }.prefix(3).map { $0 }
    }

    private func directCandidate(_ candidate: LocalImportSearchCandidate) -> LocalImportAudioSourceMatch {
        LocalImportAudioSourceMatch(
            videoID: candidate.videoID,
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            durationSeconds: candidate.durationSeconds,
            thumbnailURL: candidate.thumbnailURL,
            sourceProvider: candidate.sourceProvider,
            officialArtist: candidate.officialArtist,
            sourceURL: "https://www.youtube.com/watch?v=\(candidate.videoID)",
            score: 1,
            confidence: "search",
            match: .init(
                title: 1,
                artist: 1,
                album: candidate.album == nil ? nil : 1,
                duration: candidate.durationSeconds == nil ? nil : 1,
                durationDeltaSeconds: 0
            )
        )
    }

    private func uniqueCandidates(_ values: [LocalImportAudioSourceMatch]) -> [LocalImportAudioSourceMatch] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.videoID).inserted }
    }

    private func relevance(_ query: String, _ track: LocalImportSpotifyTrack) -> Double {
        relevance(query, title: track.title, artist: track.artist)
    }

    private func relevance(_ query: String, _ candidate: LocalImportSearchCandidate) -> Double {
        relevance(query, title: candidate.title, artist: candidate.artist ?? "")
    }

    private func relevance(_ query: String, title: String, artist: String) -> Double {
        let expected = LocalImportMatcher.normalize(query)
        let actual = LocalImportMatcher.normalize("\(title) \(artist)")
        guard !expected.isEmpty, !actual.isEmpty else { return 0 }
        if expected == actual { return 3 }
        let expectedTokens = Set(expected.split(separator: " "))
        let actualTokens = Set(actual.split(separator: " "))
        let matched = expectedTokens.intersection(actualTokens).count
        return Double(matched) / Double(max(expectedTokens.count, 1)) + (actual.contains(expected) ? 1 : 0)
    }

    private func providerRequest(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func boundedData(
        session: URLSession,
        request: URLRequest,
        limit: Int,
        validator: (URL) -> Bool
    ) async throws -> Data {
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url.map(validator) == true else {
            throw LocalImportError(stage: .searchingCandidates, code: "SEARCH_PROVIDER_FAILED", message: "A music search provider returned an invalid response.")
        }
        if let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), declared > limit {
            throw LocalImportError(stage: .searchingCandidates, code: "SEARCH_RESPONSE_TOO_LARGE", message: "A provider search response was too large.")
        }
        var data = Data()
        data.reserveCapacity(min(limit, 256 * 1_024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else {
                throw LocalImportError(stage: .searchingCandidates, code: "SEARCH_RESPONSE_TOO_LARGE", message: "A provider search response was too large.")
            }
            data.append(byte)
        }
        return data
    }

    private static let webUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
}
