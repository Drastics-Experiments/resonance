import Foundation

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
    enum Kind: Hashable, Sendable { case spotify, youtube }

    let kind: Kind
    let track: LocalImportSpotifyTrack
    let candidates: [LocalImportAudioSourceMatch]
}

struct LocalImportedAudio: Hashable, Sendable {
    let fileURL: URL
    let metadata: LocalImportMetadata
    let duration: TimeInterval
    let artworkData: Data?
    let sourceSHA256: String
    let contentSHA256: String
}

enum LocalImportOutcome: Hashable, Sendable {
    case created(LocalImportedAudio)
    case duplicate(UUID)
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
    private static let spotifyHosts = Set(["open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link"])
    private static let youtubeHosts = Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"])
    private static let youtubeEmbedHosts = Set(["youtube-nocookie.com", "www.youtube-nocookie.com"])

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
            throw LocalImportError(stage: .resolvingMetadata, code: "INVALID_SPOTIFY_URL", message: "Source must be a Spotify track URL.")
        }
        return url
    }

    static func spotifyTrack(_ value: String) throws -> (url: URL, trackID: String)? {
        let source = try spotifySource(value)
        guard ["open.spotify.com", "www.open.spotify.com"].contains(source.host?.lowercased() ?? "") else { return nil }
        var segments = source.pathComponents.filter { $0 != "/" }
        if segments.first?.hasPrefix("intl-") == true { segments.removeFirst() }
        guard segments.count == 2, segments[0] == "track", matches(spotifyID, segments[1]) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SPOTIFY_RESOURCE",
                message: "Only individual Spotify track links are supported; albums and playlists are not."
            )
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "open.spotify.com"
        components.path = "/track/\(segments[1])"
        guard let canonical = components.url else {
            throw LocalImportError(stage: .resolvingMetadata, code: "INVALID_SPOTIFY_URL", message: "Source must be a Spotify track URL.")
        }
        return (canonical, segments[1])
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

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
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
        let runs = object["runs"] as? [[String: Any]] ?? []
        return clean(runs.compactMap { clean($0["text"] as? String) }.joined())
    }

    private static func thumbnail(_ value: [String: Any]?) -> String? {
        let values = value?["thumbnails"] as? [[String: Any]] ?? []
        return values.reversed().compactMap { LocalImportURL.youtubeArtwork($0["url"] as? String)?.absoluteString }.first
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
