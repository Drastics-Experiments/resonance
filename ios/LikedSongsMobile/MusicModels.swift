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
    var artworkFilename: String?
    var artworkScanComplete: Bool?
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        title: String,
        artist: String = "Local file",
        album: String = "Imported",
        duration: TimeInterval,
        relativePath: String,
        remoteID: String? = nil,
        sourceServer: String? = nil,
        artworkFilename: String? = nil,
        artworkScanComplete: Bool? = false,
        dateAdded: Date = .now
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.relativePath = relativePath
        self.remoteID = remoteID
        self.sourceServer = sourceServer
        self.artworkFilename = artworkFilename
        self.artworkScanComplete = artworkScanComplete
        self.dateAdded = dateAdded
    }

    var durationText: String {
        guard duration.isFinite, duration >= 0 else { return "0:00" }
        let seconds = Int(duration)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
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
    var revision: Int
    var playlists: [MobileRemotePlaylist]
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
}
