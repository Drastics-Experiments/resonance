package mov.unblocked.resonance.data

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.util.UUID

@Serializable
data class Track(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val artist: String = "Local file",
    val album: String = "Imported",
    val durationMs: Long = 0L,
    val relativePath: String,
    val remoteID: String? = null,
    val sourceServer: String? = null,
    val artworkFilename: String? = null,
    val artworkScanComplete: Boolean? = false,
    val dateAddedEpochMs: Long = System.currentTimeMillis(),
) {
    val durationText: String
        get() {
            val totalSeconds = durationMs.coerceAtLeast(0L) / 1_000L
            return "${totalSeconds / 60}:${(totalSeconds % 60).toString().padStart(2, '0')}"
        }
}

@Serializable
data class Playlist(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val trackIDs: List<String> = emptyList(),
    val isSystem: Boolean = false,
    val remoteSongIDs: List<String>? = null,
)

@Serializable(with = RemoteSongSerializer::class)
data class RemoteSong(
    val id: String,
    val filename: String,
    val title: String,
    val artist: String,
    val album: String,
    val size: Long,
    val modifiedAt: String,
    val contentType: String,
    val downloadURL: String,
    val streamURL: String,
)

@Serializable
data class RemoteCatalog(
    val songs: List<RemoteSong> = emptyList(),
    val count: Int = songs.size,
)

@Serializable
data class RemotePlaylist(
    val id: String,
    val name: String,
    @SerialName("song_ids") val songIDs: List<String> = emptyList(),
)

@Serializable
data class RemotePlaylistsDocument(
    val revision: Int = 0,
    val playlists: List<RemotePlaylist> = emptyList(),
)

@Serializable
data class StoredLibrary(
    val tracks: List<Track> = emptyList(),
    val playlists: List<Playlist> = listOf(Playlist(name = "Liked Songs", isSystem = true)),
    val favorites: Set<String> = emptySet(),
    val serverURL: String = "https://music.unblocked.mov",
    val playlistRevision: Int? = 0,
    val knownRemotePlaylistIDs: Set<String>? = emptySet(),
    val dirtyPlaylistIDs: Set<String>? = emptySet(),
    val deletedPlaylistIDs: Set<String>? = emptySet(),
    val playlistSyncServerURL: String? = null,
)

data class StorageStats(
    val importedBytes: Long,
    val downloadedBytes: Long,
    val availableBytes: Long,
    val importedCount: Int,
    val downloadedCount: Int,
) {
    val usedBytes: Long get() = importedBytes + downloadedBytes
    val totalBytes: Long get() = usedBytes + availableBytes
}

data class TransferProgress(
    val completed: Int,
    val total: Int,
    val currentFilename: String,
    val bytesTransferred: Long = 0L,
    val totalBytes: Long? = null,
) {
    val fraction: Float
        get() = if (total <= 0) 0f else completed.toFloat() / total.toFloat()
}

sealed interface PlaylistPutResult {
    val document: RemotePlaylistsDocument

    data class Updated(override val document: RemotePlaylistsDocument) : PlaylistPutResult
    data class Conflict(override val document: RemotePlaylistsDocument) : PlaylistPutResult
}

internal object RemoteSongSerializer : KSerializer<RemoteSong> {
    override val descriptor: SerialDescriptor =
        buildClassSerialDescriptor("RemoteSong")

    override fun deserialize(decoder: Decoder): RemoteSong {
        val input = decoder as? JsonDecoder
            ?: error("RemoteSong can only be decoded from JSON")
        val objectValue = input.decodeJsonElement() as? JsonObject
            ?: error("RemoteSong must be a JSON object")

        fun string(key: String): String? =
            objectValue[key]?.jsonPrimitive?.contentOrNull

        val filename = string("filename") ?: string("name")
            ?: error("Remote song is missing filename")
        return RemoteSong(
            id = string("id") ?: error("Remote song is missing id"),
            filename = filename,
            title = string("title") ?: filename.substringBeforeLast('.', filename),
            artist = string("artist") ?: "Unknown Artist",
            album = string("album") ?: "Server Library",
            size = objectValue["size"]?.jsonPrimitive?.longOrNull ?: 0L,
            modifiedAt = string("modified_at")
                ?: objectValue["modified_utc"]?.jsonPrimitive?.longOrNull?.toString()
                ?: "0",
            contentType = string("content_type") ?: "application/octet-stream",
            downloadURL = string("download_url")
                ?: error("Remote song is missing download_url"),
            streamURL = string("stream_url")
                ?: error("Remote song is missing stream_url"),
        )
    }

    override fun serialize(encoder: Encoder, value: RemoteSong) {
        val output = encoder as? JsonEncoder
            ?: error("RemoteSong can only be encoded as JSON")
        output.encodeJsonElement(buildJsonObject {
            put("id", JsonPrimitive(value.id))
            put("filename", JsonPrimitive(value.filename))
            put("title", JsonPrimitive(value.title))
            put("artist", JsonPrimitive(value.artist))
            put("album", JsonPrimitive(value.album))
            put("size", JsonPrimitive(value.size))
            put("modified_at", JsonPrimitive(value.modifiedAt))
            put("content_type", JsonPrimitive(value.contentType))
            put("download_url", JsonPrimitive(value.downloadURL))
            put("stream_url", JsonPrimitive(value.streamURL))
        })
    }
}
