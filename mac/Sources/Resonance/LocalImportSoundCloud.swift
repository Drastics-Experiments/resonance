import CryptoKit
import Foundation

struct LocalImportSoundCloudTrack: Hashable, Sendable {
    let metadata: LocalImportSpotifyTrack
    let directlyImportable: Bool

    var directCandidate: LocalImportAudioSourceMatch? {
        guard directlyImportable else { return nil }
        return LocalImportAudioSourceMatch(
            videoID: "soundcloud:\(metadata.trackID)",
            title: metadata.title,
            artist: metadata.artist,
            album: metadata.album,
            durationSeconds: metadata.durationSeconds,
            thumbnailURL: metadata.artworkURL,
            sourceProvider: .soundcloud,
            officialArtist: true,
            sourceURL: metadata.sourceURL,
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
    }
}

struct LocalImportSoundCloudPlaylist: Hashable, Sendable {
    let playlistID: String
    let title: String
    let author: String
    let artworkURL: String?
    let sourceURL: String
    let tracks: [LocalImportSoundCloudTrack]
    let unavailableCount: Int
}

enum LocalImportSoundCloudSource: Hashable, Sendable {
    case track(LocalImportSoundCloudTrack)
    case playlist(LocalImportSoundCloudPlaylist)
}

struct LocalImportSoundCloudAudioStream: Hashable, Sendable {
    let track: LocalImportSpotifyTrack
    let streamingURL: URL
    let contentLength: Int64
}

extension LocalImportURL {
    private static var soundCloudSourceHosts: Set<String> {
        ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com"]
    }

    static func isSoundCloud(_ value: String) -> Bool {
        (try? soundCloudSource(value)) != nil
    }

    static func soundCloudSource(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 8_192,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              soundCloudSourceHosts.contains(host),
              !components.path.split(separator: "/").isEmpty,
              let url = components.url else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "INVALID_SOUNDCLOUD_URL",
                message: "Source must be a SoundCloud track or playlist URL."
            )
        }
        return url
    }

    static func soundCloudArtwork(_ value: String?) -> URL? {
        guard let value,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              host == "sndcdn.com" || host.hasSuffix(".sndcdn.com") else { return nil }
        return components.url
    }

    static func isSoundCloudPage(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else { return false }
        return soundCloudSourceHosts.contains(host)
    }

    static func isSoundCloudAPI(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil else { return false }
        return components.host?.lowercased() == "api-v2.soundcloud.com"
    }

    static func isSoundCloudMedia(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased() else { return false }
        return host == "sndcdn.com" || host.hasSuffix(".sndcdn.com")
    }

    static func isSoundCloudRequest(_ url: URL) -> Bool {
        isSoundCloudPage(url) || isSoundCloudAPI(url) || isSoundCloudMedia(url)
    }
}

enum LocalImportSoundCloudParser {
    private static let maxPageCharacters = 8 * 1_024 * 1_024

    static func hydration(_ html: String) throws -> [String: Any] {
        guard html.count <= maxPageCharacters,
              let marker = html.range(of: "window.__sc_hydration"),
              let start = html[marker.upperBound...].firstIndex(of: "["),
              let json = balancedJSONArray(in: html, from: start),
              let values = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "SOUNDCLOUD_INVALID_RESPONSE",
                message: "SoundCloud returned invalid page metadata."
            )
        }
        var result: [String: Any] = [:]
        for value in values {
            guard let key = value["hydratable"] as? String,
                  let data = value["data"] else { continue }
            result[key] = data
        }
        return result
    }

    static func clientID(_ hydration: [String: Any]) -> String? {
        guard let value = (hydration["apiClient"] as? [String: Any])?["id"] as? String,
              value.range(of: "^[A-Za-z0-9_-]{20,80}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func track(_ value: Any?, position: Int? = nil) -> LocalImportSoundCloudTrack? {
        guard let record = value as? [String: Any],
              record["kind"] as? String == "track",
              let id = nonnegativeInteger(record["id"]),
              let title = clean(record["title"] as? String),
              let user = record["user"] as? [String: Any],
              let sourceURL = normalizedPermalink(record["permalink_url"] as? String) else { return nil }
        let publisher = record["publisher_metadata"] as? [String: Any]
        guard let artist = clean(publisher?["artist"] as? String) ?? clean(user["username"] as? String) else { return nil }
        let durationMilliseconds = nonnegativeInteger(record["full_duration"])
            ?? nonnegativeInteger(record["duration"])
        let album = clean(publisher?["album_title"] as? String)
            ?? clean(publisher?["release_title"] as? String)
            ?? clean(record["label_name"] as? String)
        let artwork = LocalImportURL.soundCloudArtwork(record["artwork_url"] as? String)?.absoluteString
            ?? LocalImportURL.soundCloudArtwork(user["avatar_url"] as? String)?.absoluteString
        let metadata = LocalImportSpotifyTrack(
            provider: "soundcloud",
            type: "track",
            trackID: String(id),
            title: title,
            artist: artist,
            album: album,
            trackNumber: position,
            durationSeconds: durationMilliseconds.map { Int((Double($0) / 1_000).rounded()) },
            artworkURL: artwork,
            embedURL: "",
            sourceURL: sourceURL
        )
        let streamable = (record["streamable"] as? Bool) != false
        let blocked = record["policy"] as? String == "BLOCK"
        let authorized = clean(record["track_authorization"] as? String, maximum: 2_048) != nil
        return LocalImportSoundCloudTrack(
            metadata: metadata,
            directlyImportable: streamable && !blocked && authorized && progressiveTranscoding(record) != nil
        )
    }

    static func progressiveTranscoding(_ value: Any?) -> [String: Any]? {
        guard let record = value as? [String: Any],
              let media = record["media"] as? [String: Any],
              let values = media["transcodings"] as? [[String: Any]] else { return nil }
        return values.first { value in
            guard value["snipped"] as? Bool != true,
                  let format = value["format"] as? [String: Any],
                  format["protocol"] as? String == "progressive",
                  let mimeType = format["mime_type"] as? String,
                  mimeType.lowercased().hasPrefix("audio/mpeg"),
                  let rawURL = value["url"] as? String,
                  let url = URL(string: rawURL) else { return false }
            return LocalImportURL.isSoundCloudAPI(url)
        }
    }

    private static func normalizedPermalink(_ value: String?) -> String? {
        guard let value,
              let url = try? LocalImportURL.soundCloudSource(value),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        if host == "www.soundcloud.com" || host == "m.soundcloud.com" { components.host = "soundcloud.com" }
        components.query = nil
        components.fragment = nil
        if components.path.count > 1 {
            components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        }
        return components.url?.absoluteString
    }

    private static func balancedJSONArray(in source: String, from start: String.Index) -> String? {
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
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return String(source[start...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        guard integer >= 0, integer <= Int64(Int.max), Double(integer) == number.doubleValue else { return nil }
        return Int(integer)
    }

    private static func clean(_ value: String?, maximum: Int = 500) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximum))
    }
}

enum LocalImportSoundCloud {
    private static let maxPageBytes = 8 * 1_024 * 1_024
    private static let maxAPIBytes = 8 * 1_024 * 1_024
    private static let maxAudioBytes: Int64 = 256 * 1_024 * 1_024
    private static let maxPlaylistItems = 500
    private static let webUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    static func resolve(source: String, session: URLSession) async throws -> LocalImportSoundCloudSource {
        let page = try await loadPage(source: source, session: session)
        if let sound = page.hydration["sound"],
           let track = LocalImportSoundCloudParser.track(sound) {
            return .track(importabilityChecked(track, hydration: page.hydration))
        }
        guard let record = page.hydration["playlist"] as? [String: Any],
              record["kind"] as? String == "playlist",
              let id = nonnegativeInteger(record["id"]),
              let title = clean(record["title"] as? String),
              let sourceURL = normalizedPermalink(record["permalink_url"] as? String),
              let rawTracks = record["tracks"] as? [[String: Any]] else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "UNSUPPORTED_SOUNDCLOUD_RESOURCE",
                message: "Only individual SoundCloud tracks and public SoundCloud playlists are supported."
            )
        }
        let author = clean((record["user"] as? [String: Any])?["username"] as? String) ?? "SoundCloud"
        let limitedTracks = Array(rawTracks.prefix(maxPlaylistItems))
        var records = Dictionary(uniqueKeysWithValues: limitedTracks.compactMap { item -> (Int, [String: Any])? in
            guard let id = nonnegativeInteger(item["id"]) else { return nil }
            return (id, item)
        })
        let missingIDs = limitedTracks.compactMap { item -> Int? in
            LocalImportSoundCloudParser.track(item) == nil ? nonnegativeInteger(item["id"]) : nil
        }
        if let clientID = LocalImportSoundCloudParser.clientID(page.hydration) {
            for start in stride(from: 0, to: missingIDs.count, by: 50) {
                try Task.checkCancellation()
                let end = min(start + 50, missingIDs.count)
                let values = try await fetchTracks(
                    ids: Array(missingIDs[start..<end]),
                    clientID: clientID,
                    session: session
                )
                for value in values {
                    if let id = nonnegativeInteger(value["id"]) { records[id] = value }
                }
            }
        }
        let tracks = limitedTracks.enumerated().compactMap { index, value -> LocalImportSoundCloudTrack? in
            guard let id = nonnegativeInteger(value["id"]) else { return nil }
            return LocalImportSoundCloudParser.track(records[id], position: index + 1)
                .map { importabilityChecked($0, hydration: page.hydration) }
        }
        guard !tracks.isEmpty else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "SOUNDCLOUD_PLAYLIST_EMPTY",
                message: "This SoundCloud playlist has no public tracks that can be imported."
            )
        }
        let trackCount = nonnegativeInteger(record["track_count"]) ?? rawTracks.count
        let artworkURL = LocalImportURL.soundCloudArtwork(record["artwork_url"] as? String)?.absoluteString
            ?? LocalImportURL.soundCloudArtwork((record["user"] as? [String: Any])?["avatar_url"] as? String)?.absoluteString
        return .playlist(LocalImportSoundCloudPlaylist(
            playlistID: String(id),
            title: title,
            author: author,
            artworkURL: artworkURL,
            sourceURL: sourceURL,
            tracks: tracks,
            unavailableCount: max(trackCount - tracks.count, 0)
        ))
    }

    static func resolveAudio(source: String, session: URLSession) async throws -> LocalImportSoundCloudAudioStream {
        let page = try await loadPage(source: source, session: session)
        guard let record = page.hydration["sound"] as? [String: Any],
              let track = LocalImportSoundCloudParser.track(record),
              let clientID = LocalImportSoundCloudParser.clientID(page.hydration),
              let transcoding = LocalImportSoundCloudParser.progressiveTranscoding(record),
              let rawEndpoint = transcoding["url"] as? String,
              var endpoint = URLComponents(string: rawEndpoint),
              let authorization = clean(record["track_authorization"] as? String, maximum: 2_048) else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "SOUNDCLOUD_STREAM_UNAVAILABLE",
                message: "This SoundCloud track does not provide a direct public audio rendition. Try another offered source."
            )
        }
        endpoint.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "track_authorization", value: authorization),
        ]
        guard let endpointURL = endpoint.url, LocalImportURL.isSoundCloudAPI(endpointURL) else {
            throw unsafeStreamError()
        }
        var request = URLRequest(url: endpointURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (payloadData, payloadResponse) = try await boundedResponse(session: session, request: request, limit: 64 * 1_024)
        guard (200..<300).contains(payloadResponse.statusCode) else {
            throw providerFailure(payloadResponse, resource: "audio stream", stage: .inspectingSource)
        }
        guard let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let rawMediaURL = payload["url"] as? String,
              let mediaURL = URL(string: rawMediaURL),
              LocalImportURL.isSoundCloudMedia(mediaURL) else { throw unsafeStreamError() }

        var head = URLRequest(url: mediaURL)
        head.httpMethod = "HEAD"
        head.setValue("audio/mpeg,*/*;q=0.5", forHTTPHeaderField: "Accept")
        head.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (_, headResponse) = try await boundedResponse(session: session, request: head, limit: 1_024)
        guard (200..<300).contains(headResponse.statusCode),
              headResponse.url.map(LocalImportURL.isSoundCloudMedia) == true else {
            throw providerFailure(headResponse, resource: "audio stream", stage: .inspectingSource)
        }
        guard let contentLength = headResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
              contentLength > 0, contentLength <= maxAudioBytes else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "SOUNDCLOUD_AUDIO_TOO_LARGE",
                message: "The selected SoundCloud audio is too large to import on this Mac."
            )
        }
        let contentType = headResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
        guard contentType == nil || contentType == "audio/mpeg" || contentType == "application/octet-stream" else {
            throw LocalImportError(
                stage: .inspectingSource,
                code: "SOUNDCLOUD_INVALID_STREAM",
                message: "SoundCloud returned an invalid audio stream."
            )
        }
        return LocalImportSoundCloudAudioStream(
            track: track.metadata,
            streamingURL: headResponse.url ?? mediaURL,
            contentLength: contentLength
        )
    }

    static func download(
        _ stream: LocalImportSoundCloudAudioStream,
        to destination: URL,
        session: URLSession,
        fileManager: FileManager = .default,
        progress: LocalImportProgressHandler
    ) async throws -> String {
        var request = URLRequest(url: stream.streamingURL)
        request.setValue("audio/mpeg,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, rawResponse) = try await session.bytes(for: request)
        guard let response = rawResponse as? HTTPURLResponse,
              response.url.map(LocalImportURL.isSoundCloudMedia) == true,
              (200..<300).contains(response.statusCode),
              response.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) == stream.contentLength else {
            throw LocalImportError(
                stage: .downloading,
                code: "SOUNDCLOUD_SIZE_MISMATCH",
                message: "SoundCloud returned an unverifiable audio stream."
            )
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else {
            throw LocalImportError(
                stage: .downloading,
                code: "LOCAL_WRITE_FAILED",
                message: "The temporary SoundCloud audio file could not be created."
            )
        }
        var hasher = SHA256()
        var completed: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        do {
            defer { try? file.close() }
            for try await byte in bytes {
                try Task.checkCancellation()
                completed += 1
                guard completed <= stream.contentLength, completed <= maxAudioBytes else {
                    throw LocalImportError(
                        stage: .downloading,
                        code: "SOUNDCLOUD_SIZE_MISMATCH",
                        message: "SoundCloud returned more audio than expected."
                    )
                }
                buffer.append(byte)
                if buffer.count >= 64 * 1_024 {
                    try file.write(contentsOf: buffer)
                    hasher.update(data: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if completed % (256 * 1_024) == 0 {
                    await progress(.init(stage: .downloading, completed: completed, total: stream.contentLength))
                }
            }
            if !buffer.isEmpty {
                try file.write(contentsOf: buffer)
                hasher.update(data: buffer)
            }
            guard completed == stream.contentLength else {
                throw LocalImportError(
                    stage: .downloading,
                    code: "SOUNDCLOUD_SIZE_MISMATCH",
                    message: "SoundCloud ended the audio download before it was complete."
                )
            }
            try file.synchronize()
            await progress(.init(stage: .downloading, completed: completed, total: stream.contentLength))
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            try? file.close()
            try? fileManager.removeItem(at: destination)
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private static func loadPage(source: String, session: URLSession) async throws -> (hydration: [String: Any], response: HTTPURLResponse) {
        let url = try LocalImportURL.soundCloudSource(source)
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await boundedResponse(session: session, request: request, limit: maxPageBytes)
        guard response.url.map(LocalImportURL.isSoundCloudPage) == true else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "SOUNDCLOUD_UNSAFE_REDIRECT",
                message: "SoundCloud returned an unsafe redirect."
            )
        }
        guard (200..<300).contains(response.statusCode) else { throw providerFailure(response, resource: "source") }
        guard let html = String(data: data, encoding: .utf8) else {
            throw LocalImportError(
                stage: .resolvingMetadata,
                code: "SOUNDCLOUD_INVALID_RESPONSE",
                message: "SoundCloud returned invalid page metadata."
            )
        }
        return (try LocalImportSoundCloudParser.hydration(html), response)
    }

    private static func fetchTracks(
        ids: [Int],
        clientID: String,
        session: URLSession
    ) async throws -> [[String: Any]] {
        guard !ids.isEmpty else { return [] }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api-v2.soundcloud.com"
        components.path = "/tracks"
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ",")),
            URLQueryItem(name: "client_id", value: clientID),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(webUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await boundedResponse(session: session, request: request, limit: maxAPIBytes)
            guard (200..<300).contains(response.statusCode),
                  response.url.map(LocalImportURL.isSoundCloudAPI) == true else { return [] }
            return (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private static func boundedResponse(
        session: URLSession,
        request: URLRequest,
        limit: Int
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, rawResponse) = try await session.bytes(for: request)
            guard let response = rawResponse as? HTTPURLResponse else {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_INVALID_RESPONSE",
                    message: "SoundCloud returned an invalid response."
                )
            }
            if request.httpMethod != "HEAD",
               let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared > limit {
                throw LocalImportError(
                    stage: .resolvingMetadata,
                    code: "SOUNDCLOUD_RESPONSE_TOO_LARGE",
                    message: "SoundCloud returned an oversized response."
                )
            }
            var data = Data()
            data.reserveCapacity(min(limit, 256 * 1_024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else {
                    throw LocalImportError(
                        stage: .resolvingMetadata,
                        code: "SOUNDCLOUD_RESPONSE_TOO_LARGE",
                        message: "SoundCloud returned an oversized response."
                    )
                }
                data.append(byte)
            }
            return (data, response)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private static func providerFailure(
        _ response: HTTPURLResponse,
        resource: String,
        stage: LocalImportStage = .resolvingMetadata
    ) -> LocalImportError {
        if response.statusCode == 404 {
            return LocalImportError(stage: stage, code: "SOUNDCLOUD_NOT_FOUND", message: "SoundCloud could not find that \(resource).")
        }
        if response.statusCode == 429 {
            return LocalImportError(
                stage: stage,
                code: "SOUNDCLOUD_RATE_LIMITED",
                message: "SoundCloud rate-limited this request. Try again shortly.",
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")
            )
        }
        return LocalImportError(stage: stage, code: "SOUNDCLOUD_PROVIDER_FAILED", message: "SoundCloud could not load that \(resource).")
    }

    private static func unsafeStreamError() -> LocalImportError {
        LocalImportError(
            stage: .inspectingSource,
            code: "SOUNDCLOUD_UNSAFE_STREAM",
            message: "SoundCloud returned an unsafe audio stream."
        )
    }

    private static func normalizedPermalink(_ value: String?) -> String? {
        guard let value,
              let url = try? LocalImportURL.soundCloudSource(value),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        if host == "www.soundcloud.com" || host == "m.soundcloud.com" { components.host = "soundcloud.com" }
        components.query = nil
        components.fragment = nil
        if components.path.count > 1 {
            components.path = components.path.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        }
        return components.url?.absoluteString
    }

    private static func importabilityChecked(
        _ track: LocalImportSoundCloudTrack,
        hydration: [String: Any]
    ) -> LocalImportSoundCloudTrack {
        guard LocalImportSoundCloudParser.clientID(hydration) != nil else {
            return LocalImportSoundCloudTrack(metadata: track.metadata, directlyImportable: false)
        }
        return track
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.int64Value
        guard integer >= 0, integer <= Int64(Int.max), Double(integer) == number.doubleValue else { return nil }
        return Int(integer)
    }

    private static func clean(_ value: String?, maximum: Int = 500) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(maximum))
    }
}
