import Foundation

struct MobileTrack: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var relativePath: String
    var remoteID: String?
    var sourceServer: String?
    var syncProfileID: String?
    var artworkFilename: String?
    var artworkScanComplete: Bool?
    var dateAdded: Date
    var sourceSHA256: String?
    var contentSHA256: String?

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Local file",
        album: String = "Imported",
        duration: TimeInterval,
        relativePath: String,
        remoteID: String? = nil,
        sourceServer: String? = nil,
        syncProfileID: String? = nil,
        artworkFilename: String? = nil,
        artworkScanComplete: Bool? = false,
        dateAdded: Date = .now,
        sourceSHA256: String? = nil,
        contentSHA256: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.relativePath = relativePath
        self.remoteID = remoteID
        self.sourceServer = sourceServer
        self.syncProfileID = syncProfileID
        self.artworkFilename = artworkFilename
        self.artworkScanComplete = artworkScanComplete
        self.dateAdded = dateAdded
        self.sourceSHA256 = sourceSHA256
        self.contentSHA256 = contentSHA256
    }

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "0:00" }
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct MobileClipRange: Codable, Hashable {
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    var duration: TimeInterval { max(0, endSeconds - startSeconds) }
}

struct MobileRemoteClipRange: Codable, Hashable {
    var songID: String
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval

    enum CodingKeys: String, CodingKey {
        case songID = "song_id"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

struct MobilePlaylist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    var isSystem: Bool
    var remoteSongIDs: [String]?

    init(
        id: UUID = UUID(),
        name: String,
        trackIDs: [UUID] = [],
        isSystem: Bool = false,
        remoteSongIDs: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.isSystem = isSystem
        self.remoteSongIDs = remoteSongIDs
    }
}

struct MobileRemotePlaylist: Codable, Hashable, Identifiable {
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

struct MobileRemotePlaylistsDocument: Codable, Hashable {
    var profileID: String?
    var revision: Int
    var playlists: [MobileRemotePlaylist]
    var likedSongIDs: [String]
    var clipRanges: [MobileRemoteClipRange]

    enum CodingKeys: String, CodingKey {
        case revision, playlists
        case profileID = "profile_id"
        case likedSongIDs = "liked_song_ids"
        case clipRanges = "clip_ranges"
    }

    init(
        profileID: String? = nil,
        revision: Int,
        playlists: [MobileRemotePlaylist],
        likedSongIDs: [String] = [],
        clipRanges: [MobileRemoteClipRange] = []
    ) {
        self.profileID = profileID
        self.revision = revision
        self.playlists = playlists
        self.likedSongIDs = likedSongIDs
        self.clipRanges = clipRanges
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decodeIfPresent(String.self, forKey: .profileID)
        revision = try values.decode(Int.self, forKey: .revision)
        playlists = try values.decode([MobileRemotePlaylist].self, forKey: .playlists)
        likedSongIDs = try values.decodeIfPresent([String].self, forKey: .likedSongIDs) ?? []
        clipRanges = try values.decodeIfPresent([MobileRemoteClipRange].self, forKey: .clipRanges) ?? []
    }
}

struct MobileSyncProfile: Codable, Hashable, Identifiable {
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

struct MobileSyncProfilesResponse: Codable {
    let defaultProfileID: String
    let profiles: [MobileSyncProfile]

    enum CodingKeys: String, CodingKey {
        case profiles
        case defaultProfileID = "default_profile_id"
    }
}

struct MobileRemoteSong: Identifiable, Decodable, Hashable {
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
    let duration: TimeInterval?
    let artworkURL: URL?

    enum CodingKeys: String, CodingKey {
        case id, filename, name, title, artist, album, size
        case modifiedAt = "modified_at"
        case modifiedUTC = "modified_utc"
        case contentType = "content_type"
        case downloadURL = "download_url"
        case streamURL = "stream_url"
        case durationSeconds = "duration_seconds"
        case duration
        case artworkURL = "artwork_url"
        case artwork
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        filename = try values.decodeIfPresent(String.self, forKey: .filename) ?? values.decode(String.self, forKey: .name)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? (filename as NSString).deletingPathExtension
        artist = try values.decodeIfPresent(String.self, forKey: .artist) ?? "Unknown Artist"
        album = try values.decodeIfPresent(String.self, forKey: .album) ?? "Server Library"
        size = try values.decode(Int64.self, forKey: .size)
        modifiedAt = try values.decodeIfPresent(String.self, forKey: .modifiedAt)
            ?? String(try values.decodeIfPresent(Int64.self, forKey: .modifiedUTC) ?? 0)
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType) ?? "application/octet-stream"
        downloadURL = try values.decode(String.self, forKey: .downloadURL)
        streamURL = try values.decode(String.self, forKey: .streamURL)
        let decodedDuration = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
            ?? values.decodeIfPresent(Double.self, forKey: .duration)
        duration = decodedDuration.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        let decodedArtworkURL = try values.decodeIfPresent(String.self, forKey: .artworkURL)
            ?? values.decodeIfPresent(String.self, forKey: .artwork)
        artworkURL = decodedArtworkURL.flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : URL(string: trimmed)
        }
    }

    var durationText: String? {
        guard let duration else { return nil }
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

struct MobileRemoteCatalog: Decodable {
    let songs: [MobileRemoteSong]
    let count: Int
}

struct MobileStoredLibrary: Codable {
    var tracks: [MobileTrack]
    var playlists: [MobilePlaylist]
    var favorites: Set<UUID>
    var serverURL: String
    var playlistRevision: Int?
    var knownRemotePlaylistIDs: Set<UUID>?
    var dirtyPlaylistIDs: Set<UUID>?
    var deletedPlaylistIDs: Set<UUID>?
    var playlistSyncServerURL: String?
    var syncProfileID: String?
    var syncProfileName: String?
    var remoteLikedSongIDs: Set<String>?
    var dirtyRemoteLikeSongIDs: Set<String>?
    var likesDirty: Bool?
    var clipRanges: [String: MobileClipRange]?
    var dirtyClipRangeKeys: Set<String>?
    var deletedClipRangeKeys: Set<String>?
}
