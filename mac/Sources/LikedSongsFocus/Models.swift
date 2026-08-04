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

    static func timeText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
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
        var todayListeningSeconds: TimeInterval = 0
        var todayListeningPlays = 0
        var activeTrackIDs = Set<UUID>()
        var seriesByTrackID: [
            UUID: (
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
            activeTrackIDs.insert(entry.trackID)

            guard let track = tracksByID[entry.trackID] else { continue }
            var series = seriesByTrackID[track.id] ?? (
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
            seriesByTrackID[track.id] = series
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
        var total: TimeInterval = 0
        var playCount = 0
        var songsByID: [UUID: (seconds: TimeInterval, plays: Int)] = [:]
        var artistsByName: [String: (seconds: TimeInterval, plays: Int)] = [:]

        for entry in entries {
            let seconds = entry.listenedSeconds.isFinite
                ? max(0, entry.listenedSeconds)
                : 0
            total += seconds
            playCount += 1

            var song = songsByID[entry.trackID] ?? (seconds: 0, plays: 0)
            song.seconds += seconds
            song.plays += 1
            songsByID[entry.trackID] = song

            let rawArtist = tracksByID[entry.trackID]?.artist
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        songRanking = songsByID.compactMap { trackID, stats in
            guard let track = tracksByID[trackID] else { return nil }
            return ListeningHistoryRankedSong(
                track: track,
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

    enum CodingKeys: String, CodingKey {
        case id, filename, name, title, artist, album, size, duration, artwork
        case modifiedAt = "modified_at"
        case modifiedUTC = "modified_utc"
        case contentType = "content_type"
        case durationSeconds = "duration_seconds"
        case artworkURL = "artwork_url"
        case downloadURL = "download_url"
        case streamURL = "stream_url"
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
