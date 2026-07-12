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

    init(id: UUID = UUID(), name: String, trackIDs: [UUID] = [], isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.isSystem = isSystem
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
}
