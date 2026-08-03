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
    var name: String
    let isDefault: Bool
    let songCount: Int
    let playlistCount: Int
    let likedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case isDefault = "is_default"
        case songCount = "song_count"
        case playlistCount = "playlist_count"
        case likedCount = "liked_count"
    }

    init(
        id: String,
        name: String,
        isDefault: Bool = false,
        songCount: Int = 0,
        playlistCount: Int = 0,
        likedCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.songCount = songCount
        self.playlistCount = playlistCount
        self.likedCount = likedCount
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
    let downloadURL: String
    let streamURL: String

    enum CodingKeys: String, CodingKey {
        case id, filename, name, title, artist, album, size
        case modifiedAt = "modified_at"
        case modifiedUTC = "modified_utc"
        case contentType = "content_type"
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
        downloadURL = try values.decode(String.self, forKey: .downloadURL)
        streamURL = try values.decode(String.self, forKey: .streamURL)
    }
}

struct RemoteCatalog: Decodable {
    let songs: [RemoteSong]
    let count: Int
}
