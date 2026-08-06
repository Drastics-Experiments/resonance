import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case library = "Library"
    case playlists = "Playlists"
    case storage = "Song Storage"
    case server = "Music Server"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .library: "house"
        case .playlists: "square.stack"
        case .storage: "externaldrive"
        case .server: "network"
        }
    }
}

enum SongFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All songs"
    case recentlyAdded = "Recently added"
    case audio = "Audio"
    case video = "Video"

    var id: String { rawValue }
}

enum MediaKindClassifier {
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]

    static func kind(contentType: String, filename: String) -> SongFilter {
        let normalizedType = contentType.lowercased()
        let fileExtension = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return normalizedType.contains("video") || videoExtensions.contains(fileExtension) ? .video : .audio
    }
}

enum ServerUploadNaming {
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

enum ServerSongIdentityPolicy {
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

enum StorageSelectionPolicy {
    static func visibleSelection(
        from selectedTrackIDs: Set<UUID>,
        visibleTrackIDs: Set<UUID>
    ) -> Set<UUID> {
        selectedTrackIDs.intersection(visibleTrackIDs)
    }
}

enum QueueTab: String, CaseIterable, Identifiable {
    case upNext = "Up next"
    case history = "History"

    var id: String { rawValue }
}

enum ArtworkStyle: Int, CaseIterable, Hashable, Codable {
    case liked
    case midnight
    case electric
    case echoes
    case golden
    case weightless
    case falling
    case lateNight
    case softFocus
    case onRepeat
}

struct Track: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var kind: SongFilter
    var artwork: ArtworkStyle
    var artworkData: Data?
    var fileURL: URL?
    var remoteID: String?
    var sourceServer: String?
    var syncProfileID: String?
    var sourceURL: String?
    var sourceSHA256: String?
    var contentSHA256: String?
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        kind: SongFilter = .audio,
        artwork: ArtworkStyle,
        artworkData: Data? = nil,
        fileURL: URL? = nil,
        remoteID: String? = nil,
        sourceServer: String? = nil,
        syncProfileID: String? = nil,
        sourceURL: String? = nil,
        sourceSHA256: String? = nil,
        contentSHA256: String? = nil,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.kind = kind
        self.artwork = artwork
        self.artworkData = artworkData
        self.fileURL = fileURL
        self.remoteID = remoteID
        self.sourceServer = sourceServer
        self.syncProfileID = syncProfileID
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
        self.contentSHA256 = contentSHA256
        self.dateAdded = dateAdded
    }

    var durationText: String { Self.timeText(duration) }

    var installedVideoURL: URL? {
        guard kind == .video,
              let fileURL,
              fileURL.isFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    static func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

}

struct MissingServerUploadPlan: Equatable {
    let uploadTrackIDs: [UUID]
    let existingRemoteIDsByTrackID: [UUID: String]
}

enum MissingServerUploadPolicy {
    static func plan(
        tracks: [Track],
        catalog: [RemoteSong],
        activeProfileID: String,
        activeServerURL: URL
    ) -> MissingServerUploadPlan {
        let liveRemoteIDs = Set(catalog.map(\.id))
        let remoteIDByHash = Dictionary(
            catalog.compactMap { song -> (String, String)? in
                guard let hash = normalizedHash(song.contentSHA256) else { return nil }
                return (hash, song.id)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let serverOrigin = origin(of: activeServerURL)
        var uploadTrackIDs: [UUID] = []
        var existingRemoteIDsByTrackID: [UUID: String] = [:]

        for track in tracks {
            guard track.fileURL != nil,
                  track.remoteID != nil || track.sourceServer != nil,
                  (track.syncProfileID ?? "default") == activeProfileID else { continue }
            if let sourceServer = track.sourceServer {
                guard let sourceURL = URL(string: sourceServer),
                      origin(of: sourceURL) == serverOrigin else { continue }
            }
            if let remoteID = track.remoteID, liveRemoteIDs.contains(remoteID) {
                continue
            }
            if let hash = normalizedHash(track.contentSHA256),
               let existingRemoteID = remoteIDByHash[hash] {
                existingRemoteIDsByTrackID[track.id] = existingRemoteID
            } else if let existing = catalog.first(where: { song in
                ServerSongIdentityPolicy.metadataMatches(
                    expectedTitle: track.title,
                    expectedArtist: track.artist,
                    expectedDuration: track.duration,
                    actualTitle: song.title,
                    actualArtist: song.artist,
                    actualDuration: song.durationSeconds
                )
            }) {
                existingRemoteIDsByTrackID[track.id] = existing.id
            } else {
                uploadTrackIDs.append(track.id)
            }
        }

        return MissingServerUploadPlan(
            uploadTrackIDs: uploadTrackIDs,
            existingRemoteIDsByTrackID: existingRemoteIDsByTrackID
        )
    }

    private static func normalizedHash(_ value: String?) -> String? {
        guard let hash = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !hash.isEmpty else { return nil }
        return hash
    }

    private static func origin(of url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

struct ListeningHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let trackID: UUID
    let startedAt: Date
    var listenedSeconds: TimeInterval
    var syncProfileID: String?
    var remoteSongID: String?
    var title: String?
    var artist: String?
    var album: String?
    var duration: TimeInterval?
    var originatedOnThisDevice: Bool?

    init(
        id: UUID = UUID(),
        trackID: UUID,
        startedAt: Date = .now,
        listenedSeconds: TimeInterval = 0,
        syncProfileID: String? = nil,
        remoteSongID: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval? = nil,
        originatedOnThisDevice: Bool? = true
    ) {
        self.id = id
        self.trackID = trackID
        self.startedAt = startedAt
        self.listenedSeconds = listenedSeconds
        self.syncProfileID = syncProfileID
        self.remoteSongID = remoteSongID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.originatedOnThisDevice = originatedOnThisDevice
    }
}

enum ListeningHistoryTrackResolver {
    static func identity(for entry: ListeningHistoryEntry) -> String {
        let profileID = entry.syncProfileID ?? "default"
        if let remoteSongID = nonempty(entry.remoteSongID) {
            return "\(profileID)#remote:\(remoteSongID)"
        }
        return "\(profileID)#track:\(entry.trackID.uuidString.lowercased())"
    }

    static func remoteIdentity(profileID: String?, remoteSongID: String) -> String {
        "\(profileID ?? "default")#remote:\(remoteSongID)"
    }

    static func track(
        for entry: ListeningHistoryEntry,
        tracksByID: [UUID: Track],
        tracksByRemoteIdentity: [String: Track]
    ) -> Track {
        if let remoteSongID = nonempty(entry.remoteSongID),
           let track = tracksByRemoteIdentity[remoteIdentity(
               profileID: entry.syncProfileID,
               remoteSongID: remoteSongID
           )] {
            return track
        }
        if let track = tracksByID[entry.trackID] { return track }

        let duration = entry.duration.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        } ?? 0
        return Track(
            id: entry.trackID,
            title: nonempty(entry.title) ?? "Unknown song",
            artist: nonempty(entry.artist) ?? "Unknown artist",
            album: nonempty(entry.album) ?? "Unknown Album",
            duration: duration,
            artwork: .weightless,
            remoteID: nonempty(entry.remoteSongID),
            syncProfileID: entry.syncProfileID ?? "default",
            dateAdded: entry.startedAt
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

struct RemoteListeningHistoryDocument: Decodable {
    let profileID: String
    let entries: [RemoteListeningHistoryEntry]

    enum CodingKeys: String, CodingKey {
        case entries
        case profileID = "profile_id"
    }
}

struct RemoteListeningHistoryEntry: Decodable {
    let id: String
    let trackID: String
    let songID: String?
    let startedAt: String
    let listenedSeconds: TimeInterval
    let title: String?
    let artist: String?
    let album: String?
    let durationSeconds: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album
        case trackID = "track_id"
        case songID = "song_id"
        case startedAt = "started_at"
        case listenedSeconds = "listened_seconds"
        case durationSeconds = "duration_seconds"
    }
}

struct ListeningHistoryDay: Identifiable, Hashable {
    let date: Date
    var seconds: TimeInterval
    var plays: Int

    var id: Date { date }
    var minutes: Double { seconds / 60 }
}

enum ListeningHistoryGranularity: Hashable {
    case hour
    case day
}

struct ListeningHistorySongSeries: Identifiable, Hashable {
    let track: Track
    let seconds: TimeInterval
    let plays: Int
    let days: [ListeningHistoryDay]

    var id: UUID { track.id }
    var minutes: Double { seconds / 60 }
}

struct ListeningHistoryCalendarSummary: Hashable {
    let granularity: ListeningHistoryGranularity
    let days: [ListeningHistoryDay]
    let totalSeconds: TimeInterval
    let plays: Int
    let todaySeconds: TimeInterval
    let todayPlays: Int
    let songs: Int
    let songSeries: [ListeningHistorySongSeries]

    init(
        entries: [ListeningHistoryEntry],
        tracks: [Track],
        dayCount: Int,
        windowOffset: Int = 0,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let requestedCount = min(max(dayCount, 1), 365)
        let offset = max(0, windowOffset)
        let hourly = requestedCount == 1
        granularity = hourly ? .hour : .day
        let count = hourly ? 24 : requestedCount
        let today = calendar.startOfDay(for: now)
        let windowEnd = calendar.date(
            byAdding: .day,
            value: -(offset * requestedCount),
            to: today
        ) ?? today
        var dailyHistory = (0..<count).map { index in
            let date: Date
            if hourly {
                date = calendar.date(
                    byAdding: .hour,
                    value: index,
                    to: windowEnd
                ) ?? windowEnd
            } else {
                date = calendar.date(
                    byAdding: .day,
                    value: -(count - index - 1),
                    to: windowEnd
                ) ?? windowEnd
            }
            return ListeningHistoryDay(
                date: date,
                seconds: 0,
                plays: 0
            )
        }
        let dayIndexByDate = Dictionary(
            uniqueKeysWithValues: dailyHistory.enumerated().map {
                ($0.element.date, $0.offset)
            }
        )
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var tracksByRemoteIdentity: [String: Track] = [:]
        for track in tracks {
            guard let remoteID = track.remoteID else { continue }
            tracksByRemoteIdentity[ListeningHistoryTrackResolver.remoteIdentity(
                profileID: track.syncProfileID,
                remoteSongID: remoteID
            )] = track
        }
        var todayListeningSeconds: TimeInterval = 0
        var todayListeningPlays = 0
        var activeTrackIDs = Set<String>()
        var seriesByTrackID: [
            String: (
                track: Track,
                seconds: TimeInterval,
                plays: Int,
                days: [ListeningHistoryDay]
            )
        ] = [:]

        for entry in entries {
            let seconds = entry.listenedSeconds.isFinite
                ? max(0, entry.listenedSeconds)
                : 0
            if calendar.isDate(entry.startedAt, inSameDayAs: now) {
                todayListeningSeconds += seconds
                todayListeningPlays += 1
            }

            let entryDate: Date
            if hourly {
                entryDate = calendar.dateInterval(
                    of: .hour,
                    for: entry.startedAt
                )?.start ?? entry.startedAt
            } else {
                entryDate = calendar.startOfDay(for: entry.startedAt)
            }
            guard let dayIndex = dayIndexByDate[entryDate] else { continue }
            dailyHistory[dayIndex].seconds += seconds
            dailyHistory[dayIndex].plays += 1
            let identity = ListeningHistoryTrackResolver.identity(for: entry)
            let track = ListeningHistoryTrackResolver.track(
                for: entry,
                tracksByID: tracksByID,
                tracksByRemoteIdentity: tracksByRemoteIdentity
            )
            activeTrackIDs.insert(identity)

            var series = seriesByTrackID[identity] ?? (
                track: track,
                seconds: 0,
                plays: 0,
                days: dailyHistory.map {
                    ListeningHistoryDay(date: $0.date, seconds: 0, plays: 0)
                }
            )
            series.seconds += seconds
            series.plays += 1
            series.days[dayIndex].seconds += seconds
            series.days[dayIndex].plays += 1
            seriesByTrackID[identity] = series
        }

        days = dailyHistory
        totalSeconds = dailyHistory.reduce(0) { $0 + $1.seconds }
        plays = dailyHistory.reduce(0) { $0 + $1.plays }
        todaySeconds = todayListeningSeconds
        todayPlays = todayListeningPlays
        songs = activeTrackIDs.count
        songSeries = seriesByTrackID.values
            .map {
                ListeningHistorySongSeries(
                    track: $0.track,
                    seconds: $0.seconds,
                    plays: $0.plays,
                    days: $0.days
                )
            }
            .sorted { lhs, rhs in
                if lhs.seconds != rhs.seconds {
                    return lhs.seconds > rhs.seconds
                }
                if lhs.plays != rhs.plays {
                    return lhs.plays > rhs.plays
                }
                return lhs.track.title.localizedStandardCompare(rhs.track.title)
                    == .orderedAscending
            }
    }

    var mostActiveDay: ListeningHistoryDay? {
        days.max { lhs, rhs in
            if lhs.seconds == rhs.seconds {
                return lhs.date < rhs.date
            }
            return lhs.seconds < rhs.seconds
        }
    }
}

struct ListeningHistoryRankedSong: Identifiable, Hashable {
    let track: Track
    let seconds: TimeInterval
    let plays: Int

    var id: UUID { track.id }
}

struct ListeningHistoryStatsSummary: Hashable {
    let totalSeconds: TimeInterval
    let plays: Int
    let songs: Int
    let topArtist: String
    let songRanking: [ListeningHistoryRankedSong]

    init(entries: [ListeningHistoryEntry], tracks: [Track]) {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var tracksByRemoteIdentity: [String: Track] = [:]
        for track in tracks {
            guard let remoteID = track.remoteID else { continue }
            tracksByRemoteIdentity[ListeningHistoryTrackResolver.remoteIdentity(
                profileID: track.syncProfileID,
                remoteSongID: remoteID
            )] = track
        }
        var total: TimeInterval = 0
        var playCount = 0
        var songsByID: [String: (track: Track, seconds: TimeInterval, plays: Int)] = [:]
        var artistsByName: [String: (seconds: TimeInterval, plays: Int)] = [:]

        for entry in entries {
            let seconds = entry.listenedSeconds.isFinite
                ? max(0, entry.listenedSeconds)
                : 0
            total += seconds
            playCount += 1

            let identity = ListeningHistoryTrackResolver.identity(for: entry)
            let track = ListeningHistoryTrackResolver.track(
                for: entry,
                tracksByID: tracksByID,
                tracksByRemoteIdentity: tracksByRemoteIdentity
            )
            var song = songsByID[identity] ?? (track: track, seconds: 0, plays: 0)
            song.seconds += seconds
            song.plays += 1
            songsByID[identity] = song

            let rawArtist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            let artistName = rawArtist.isEmpty ? "Unknown artist" : rawArtist
            var artist = artistsByName[artistName] ?? (seconds: 0, plays: 0)
            artist.seconds += seconds
            artist.plays += 1
            artistsByName[artistName] = artist
        }

        totalSeconds = total
        plays = playCount
        songs = songsByID.count
        topArtist = artistsByName
            .sorted { lhs, rhs in
                if lhs.value.seconds != rhs.value.seconds {
                    return lhs.value.seconds > rhs.value.seconds
                }
                if lhs.value.plays != rhs.value.plays {
                    return lhs.value.plays > rhs.value.plays
                }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .first?.key ?? "—"
        songRanking = songsByID.map { _, stats in
            return ListeningHistoryRankedSong(
                track: stats.track,
                seconds: stats.seconds,
                plays: stats.plays
            )
        }
        .sorted { lhs, rhs in
            if lhs.seconds != rhs.seconds {
                return lhs.seconds > rhs.seconds
            }
            if lhs.plays != rhs.plays {
                return lhs.plays > rhs.plays
            }
            return lhs.track.title.localizedStandardCompare(rhs.track.title)
                == .orderedAscending
        }
    }
}

struct Playlist: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var artwork: ArtworkStyle
    var trackIDs: [UUID]
    var isSystem: Bool
    var remoteSongIDs: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        artwork: ArtworkStyle,
        trackIDs: [UUID],
        isSystem: Bool = false,
        remoteSongIDs: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.trackIDs = trackIDs
        self.isSystem = isSystem
        self.remoteSongIDs = remoteSongIDs
    }

    var count: Int { trackIDs.count }

    static func library(trackIDs: [UUID] = []) -> Playlist {
        Playlist(
            name: "Liked Songs",
            artwork: .liked,
            trackIDs: trackIDs,
            isSystem: true
        )
    }
}

struct RemotePlaylist: Codable, Hashable, Identifiable {
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

struct RemotePlaylistsDocument: Codable, Hashable {
    var profileID: String?
    var revision: Int
    var playlists: [RemotePlaylist]
    var likedSongIDs: [String]

    enum CodingKeys: String, CodingKey {
        case revision, playlists
        case profileID = "profile_id"
        case likedSongIDs = "liked_song_ids"
    }

    init(
        profileID: String? = nil,
        revision: Int,
        playlists: [RemotePlaylist],
        likedSongIDs: [String] = []
    ) {
        self.profileID = profileID
        self.revision = revision
        self.playlists = playlists
        self.likedSongIDs = likedSongIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        revision = try values.decode(Int.self, forKey: .revision)
        playlists = try values.decode([RemotePlaylist].self, forKey: .playlists)
        likedSongIDs = try values.decodeIfPresent([String].self, forKey: .likedSongIDs) ?? []
    }
}

struct SyncProfile: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
    }
}

struct SyncProfilesResponse: Codable {
    let defaultProfileID: String
    let profiles: [SyncProfile]

    enum CodingKeys: String, CodingKey {
        case profiles
        case defaultProfileID = "default_profile_id"
    }
}

struct RemoteSong: Identifiable, Hashable, Decodable {
    let id: String
    let filename: String
    let title: String
    let artist: String
    let album: String
    let size: Int64
    let modifiedAt: String
    let contentType: String
    let durationSeconds: TimeInterval?
    let artworkURL: String?
    let downloadURL: String
    let streamURL: String
    let contentSHA256: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, name, title, artist, album, size, duration, artwork
        case modifiedAt = "modified_at"
        case modifiedUTC = "modified_utc"
        case contentType = "content_type"
        case durationSeconds = "duration_seconds"
        case artworkURL = "artwork_url"
        case downloadURL = "download_url"
        case streamURL = "stream_url"
        case contentSHA256 = "content_sha256"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        filename = try values.decodeIfPresent(String.self, forKey: .filename)
            ?? values.decode(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title)
            ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        artist = try values.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        album = try values.decodeIfPresent(String.self, forKey: .album) ?? "Server Library"
        size = try values.decode(Int64.self, forKey: .size)
        if let timestamp = try values.decodeIfPresent(String.self, forKey: .modifiedAt) {
            modifiedAt = timestamp
        } else if let timestamp = try values.decodeIfPresent(Int64.self, forKey: .modifiedUTC) {
            modifiedAt = String(timestamp)
        } else {
            modifiedAt = ""
        }
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        durationSeconds = try values.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
            ?? values.decodeIfPresent(TimeInterval.self, forKey: .duration)
        artworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
            ?? values.decodeIfPresent(String.self, forKey: .artwork)
        downloadURL = try values.decode(String.self, forKey: .downloadURL)
        streamURL = try values.decode(String.self, forKey: .streamURL)
        contentSHA256 = try values.decodeIfPresent(String.self, forKey: .contentSHA256)
    }

    var kind: SongFilter {
        MediaKindClassifier.kind(contentType: contentType, filename: filename)
    }

    var durationText: String? {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return Track.timeText(durationSeconds)
    }
}

struct RemoteCatalog: Decodable {
    let songs: [RemoteSong]
    let count: Int
}

struct RemoteMetadataBackfill: Decodable {
    let processed: Int
    let remaining: Int
}
