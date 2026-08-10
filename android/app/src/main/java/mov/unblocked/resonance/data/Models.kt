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
import kotlinx.serialization.json.doubleOrNull
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
    val syncProfileID: String? = null,
    val downloadSourceURL: String? = null,
    val artworkFilename: String? = null,
    val artworkScanComplete: Boolean? = false,
    val dateAddedEpochMs: Long = System.currentTimeMillis(),
    val sourceSHA256: String? = null,
    val contentSHA256: String? = null,
    val sourceURL: String? = null,
) {
    val durationText: String
        get() {
            if (durationMs <= 0L) return "Unknown"
            val totalSeconds = durationMs / 1_000L
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
) {
    val automaticArtworkTrackIDs: List<String>
        get() = if (isSystem) emptyList() else trackIDs.take(4)
}

@Serializable
data class ClipRange(
    val startMs: Long,
    val endMs: Long,
) {
    val durationMs: Long get() = (endMs - startMs).coerceAtLeast(0L)
}

@Serializable
data class RemoteClipRange(
    @SerialName("song_id") val songID: String,
    @SerialName("start_seconds") val startSeconds: Double,
    @SerialName("end_seconds") val endSeconds: Double,
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
    val durationSeconds: Double? = null,
    val artworkURL: String? = null,
    val contentSHA256: String? = null,
    val sourceURL: String? = null,
    val mediaKind: String = "audio",
    val isSourceLinkRecord: Boolean = false,
) {
    val durationText: String?
        get() = durationSeconds
            ?.takeIf { it.isFinite() && it > 0.0 }
            ?.toLong()
            ?.let { seconds -> "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}" }

    val isVideoMedia: Boolean
        get() = mediaKind == "video" || contentType.contains("video", ignoreCase = true) ||
            filename.substringAfterLast('.', "").lowercase() in setOf("mp4", "mov", "m4v", "webm")

    val requiresOriginalSourcePage: Boolean
        get() = sourceURL?.let { value ->
            runCatching { java.net.URI(value) }.getOrNull()?.let { url ->
                val host = url.host?.lowercase().orEmpty()
                host == "googlevideo.com" || host.endsWith(".googlevideo.com") ||
                    url.path.substringAfterLast('/').equals("videoplayback", ignoreCase = true)
            }
        } == true
}

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
    @SerialName("profile_id") val profileID: String? = null,
    val revision: Int = 0,
    val playlists: List<RemotePlaylist> = emptyList(),
    @SerialName("liked_song_ids") val likedSongIDs: List<String> = emptyList(),
    @SerialName("clip_ranges") val clipRanges: List<RemoteClipRange> = emptyList(),
)

@Serializable
data class SyncProfile(
    val id: String,
    val name: String,
    @SerialName("is_default") val isDefault: Boolean = false,
    @SerialName("song_count") val songCount: Int = 0,
    @SerialName("playlist_count") val playlistCount: Int = 0,
    @SerialName("liked_count") val likedCount: Int = 0,
)

@Serializable
data class SyncProfilesResponse(
    @SerialName("default_profile_id") val defaultProfileID: String = "default",
    val profiles: List<SyncProfile> = emptyList(),
)

@Serializable
data class StoredLibrary(
    val tracks: List<Track> = emptyList(),
    val playlists: List<Playlist> = listOf(Playlist(name = "Liked Songs", isSystem = true)),
    val favorites: Set<String> = emptySet(),
    val serverURL: String = "https://resonance-core.blithe-haven-9710.chatgpt.site",
    val playlistRevision: Int? = 0,
    val knownRemotePlaylistIDs: Set<String>? = emptySet(),
    val dirtyPlaylistIDs: Set<String>? = emptySet(),
    val deletedPlaylistIDs: Set<String>? = emptySet(),
    val playlistSyncServerURL: String? = null,
    val syncProfileID: String = "default",
    val syncProfiles: List<SyncProfile> = listOf(SyncProfile("default", "Default", true)),
    val remoteLikedSongIDs: Set<String>? = null,
    val dirtyRemoteLikeSongIDs: Set<String>? = null,
    val likesDirty: Boolean = false,
    val clipRanges: Map<String, ClipRange> = emptyMap(),
    val dirtyClipRangeKeys: Set<String> = emptySet(),
    val deletedClipRangeKeys: Set<String> = emptySet(),
    /**
     * Durable profile-scoped snapshots keyed by normalized server origin and profile ID.
     *
     * The duplicated top-level fields remain the active profile's working set for
     * backwards-compatible decoding. They are captured into this map before every
     * save and restored when the server/profile context changes.
     */
    val profileStates: Map<String, ProfileLibraryState> = emptyMap(),
)

@Serializable
data class ProfileLibraryState(
    val playlists: List<Playlist> = listOf(Playlist(name = "Liked Songs", isSystem = true)),
    val favorites: Set<String> = emptySet(),
    val playlistRevision: Int? = 0,
    val knownRemotePlaylistIDs: Set<String> = emptySet(),
    val dirtyPlaylistIDs: Set<String> = emptySet(),
    val deletedPlaylistIDs: Set<String> = emptySet(),
    val playlistSyncServerURL: String? = null,
    val remoteLikedSongIDs: Set<String> = emptySet(),
    val dirtyRemoteLikeSongIDs: Set<String> = emptySet(),
    val likesDirty: Boolean = false,
    val clipRanges: Map<String, ClipRange> = emptyMap(),
    val dirtyClipRangeKeys: Set<String> = emptySet(),
    val deletedClipRangeKeys: Set<String> = emptySet(),
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

        fun double(key: String): Double? =
            objectValue[key]?.jsonPrimitive?.doubleOrNull

        val id = string("id") ?: error("Remote song is missing id")
        val sourceURL = string("source_url")?.trim()?.takeIf(String::isNotEmpty)
        val declaredMediaKind = string("media_kind")?.takeIf { it == "audio" || it == "video" }
        val decodedSize = objectValue["size"]?.jsonPrimitive?.longOrNull ?: 0L
        val sourceFilename = sourceURL
            ?.let { runCatching { java.net.URI(it).path.substringAfterLast('/') }.getOrNull() }
            ?.takeIf(String::isNotEmpty)
        val usefulSourceFilename = sourceFilename?.takeUnless {
            it.equals("watch", ignoreCase = true) || it.equals("videoplayback", ignoreCase = true)
        }
        val filename = string("filename") ?: string("name") ?: usefulSourceFilename ?: "Saved-${id.take(8)}"
        return RemoteSong(
            id = id,
            filename = filename,
            title = string("title") ?: if (sourceURL != null) "Resolving metadata…" else filename.substringBeforeLast('.', filename),
            artist = string("artist") ?: if (sourceURL != null) "On-device lookup" else "Unknown Artist",
            album = string("album") ?: if (sourceURL != null) "Link only" else "Server Library",
            size = decodedSize,
            modifiedAt = string("modified_at")
                ?: objectValue["modified_utc"]?.jsonPrimitive?.longOrNull?.toString()
                ?: "0",
            contentType = string("content_type") ?: "application/octet-stream",
            downloadURL = string("download_url")
                ?: error("Remote song is missing download_url"),
            streamURL = string("stream_url")
                ?: error("Remote song is missing stream_url"),
            durationSeconds = (double("duration_seconds") ?: double("duration"))
                ?.takeIf { it.isFinite() && it > 0.0 },
            artworkURL = (string("artwork_url") ?: string("artwork"))
                ?.trim()
                ?.takeIf(String::isNotEmpty),
            contentSHA256 = string("content_sha256")?.trim()?.lowercase()?.takeIf(String::isNotEmpty),
            sourceURL = sourceURL,
            mediaKind = declaredMediaKind ?: if (
                (string("content_type") ?: "").startsWith("video/", ignoreCase = true) ||
                filename.substringAfterLast('.', "").lowercase() in setOf("mp4", "mov", "m4v", "webm")
            ) "video" else "audio",
            isSourceLinkRecord = sourceURL != null && (declaredMediaKind != null || decodedSize == 0L),
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
            value.durationSeconds?.let { put("duration_seconds", JsonPrimitive(it)) }
            value.artworkURL?.let { put("artwork_url", JsonPrimitive(it)) }
            value.contentSHA256?.let { put("content_sha256", JsonPrimitive(it)) }
            value.sourceURL?.let { put("source_url", JsonPrimitive(it)) }
            put("media_kind", JsonPrimitive(value.mediaKind))
        })
    }
}

internal fun Track.associatedWithLocalSource(
    sourceURL: String?,
    downloadSourceURL: String? = null,
): Track {
    fun normalized(value: String?): String? = value
        ?.trim()
        ?.takeIf { it.isNotEmpty() && it.length <= 8_192 }
    return copy(
        sourceURL = normalized(sourceURL) ?: this.sourceURL,
        downloadSourceURL = normalized(downloadSourceURL) ?: this.downloadSourceURL,
    )
}
