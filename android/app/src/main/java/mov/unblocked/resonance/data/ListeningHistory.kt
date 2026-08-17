package mov.unblocked.resonance.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.time.Instant
import java.util.UUID

@Serializable
data class ListeningHistoryEntry(
    val id: String = UUID.randomUUID().toString(),
    @SerialName("track_id") val trackID: String,
    @SerialName("started_at") val startedAt: String = Instant.now().toString(),
    @SerialName("listened_seconds") val listenedSeconds: Double = 0.0,
    @SerialName("server_origin") val serverOrigin: String? = null,
    @SerialName("profile_id") val syncProfileID: String = "default",
    @SerialName("song_id") val remoteSongID: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    @SerialName("duration_seconds") val durationSeconds: Double? = null,
    @SerialName("artwork_url") val artworkURL: String? = null,
    @SerialName("originated_on_this_device") val originatedOnThisDevice: Boolean = true,
)

@Serializable
data class RemoteListeningHistoryDocument(
    @SerialName("profile_id") val profileID: String = "",
    val entries: List<RemoteListeningHistoryEntry> = emptyList(),
)

@Serializable
data class RemoteListeningHistoryEntry(
    val id: String = "",
    @SerialName("track_id") val trackID: String = "",
    @SerialName("song_id") val songID: String? = null,
    @SerialName("started_at") val startedAt: String = "",
    @SerialName("listened_seconds") val listenedSeconds: Double = 0.0,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    @SerialName("duration_seconds") val durationSeconds: Double? = null,
    @SerialName("artwork_url") val artworkURL: String? = null,
)

@Serializable
internal data class ListeningHistoryUploadDocument(val entries: List<ListeningHistoryUploadEntry>)

@Serializable
internal data class ListeningHistoryUploadEntry(
    val id: String,
    @SerialName("track_id") val trackID: String,
    @SerialName("song_id") val songID: String? = null,
    @SerialName("started_at") val startedAt: String,
    @SerialName("listened_seconds") val listenedSeconds: Double,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    @SerialName("duration_seconds") val durationSeconds: Double? = null,
    val client: String = "android",
)

object ListeningHistoryPlaybackPolicy {
    fun advance(
        entry: ListeningHistoryEntry,
        currentPositionSeconds: Double,
        previousPositionSeconds: Double,
        isPlaying: Boolean,
        playerDurationSeconds: Double? = null,
    ): ListeningHistoryEntry {
        val duration = entry.durationSeconds?.takeIf { it.isFinite() && it > 0.0 }
            ?: playerDurationSeconds?.takeIf { it.isFinite() && it > 0.0 }
                ?.coerceAtMost(ListeningHistoryRetentionPolicy.MAX_DURATION_SECONDS)
        val delta = currentPositionSeconds - previousPositionSeconds
        val listened = if (isPlaying && delta > 0.0 && delta < 5.0) {
            (entry.listenedSeconds + delta).coerceAtMost(ListeningHistoryRetentionPolicy.MAX_LISTENED_SECONDS)
        } else entry.listenedSeconds
        return entry.copy(listenedSeconds = listened, durationSeconds = duration)
    }
}

object ListeningHistoryRetentionPolicy {
    const val MAXIMUM_ENTRIES = 2_000
    const val MAX_UPLOAD_BATCH = 500
    const val MAX_LISTENED_SECONDS = 31.0 * 24.0 * 60.0 * 60.0
    const val MAX_DURATION_SECONDS = 7.0 * 24.0 * 60.0 * 60.0

    fun entry(
        track: Track,
        serverOrigin: String?,
        profileID: String,
        remoteSongID: String? = track.remoteID,
        artworkURL: String? = null,
    ) = ListeningHistoryEntry(
        trackID = track.id,
        serverOrigin = normalizedOrigin(serverOrigin),
        syncProfileID = profileID.ifBlank { "default" },
        remoteSongID = limited(remoteSongID, 128),
        title = limited(track.title, 500),
        artist = limited(track.artist, 500),
        album = limited(track.album, 500),
        durationSeconds = track.durationMs.takeIf { it > 0L }?.div(1_000.0),
        artworkURL = normalizedArtworkURL(artworkURL),
    )

    fun append(entries: List<ListeningHistoryEntry>, entry: ListeningHistoryEntry) = normalize(entries + entry)

    fun qualifies(entry: ListeningHistoryEntry, track: Track? = null): Boolean {
        val duration = track?.durationMs?.takeIf { it > 0L }?.div(1_000.0) ?: entry.durationSeconds
        return entry.listenedSeconds.isFinite() && entry.listenedSeconds > 0.0 &&
            duration != null && duration.isFinite() && duration > 0.0 &&
            entry.listenedSeconds > duration * 0.10
    }

    fun matchesContext(entry: ListeningHistoryEntry, serverURL: String, profileID: String): Boolean =
        normalizedOrigin(entry.serverOrigin) == normalizedOrigin(serverURL) &&
            entry.syncProfileID.ifBlank { "default" } == profileID.ifBlank { "default" }

    fun normalize(entries: List<ListeningHistoryEntry>): List<ListeningHistoryEntry> {
        val byIdentity = linkedMapOf<String, ListeningHistoryEntry>()
        entries.mapNotNull(::normalized).forEach { entry ->
            val key = "${entry.serverOrigin ?: "unowned"}#${entry.syncProfileID}#${entry.id}"
            val existing = byIdentity[key]
            byIdentity[key] = if (existing == null) entry else existing.copy(
                listenedSeconds = maxOf(existing.listenedSeconds, entry.listenedSeconds),
                remoteSongID = entry.remoteSongID ?: existing.remoteSongID,
                title = entry.title ?: existing.title,
                artist = entry.artist ?: existing.artist,
                album = entry.album ?: existing.album,
                durationSeconds = entry.durationSeconds ?: existing.durationSeconds,
                artworkURL = entry.artworkURL ?: existing.artworkURL,
                originatedOnThisDevice = existing.originatedOnThisDevice || entry.originatedOnThisDevice,
            )
        }
        return byIdentity.values
            .groupBy { "${it.serverOrigin ?: "unowned"}#${it.syncProfileID}" }
            .values.flatMap { it.sortedBy(ListeningHistoryEntry::startedAt).takeLast(MAXIMUM_ENTRIES) }
            .sortedBy(ListeningHistoryEntry::startedAt)
    }

    fun mergeRemote(
        existing: List<ListeningHistoryEntry>,
        document: RemoteListeningHistoryDocument,
        serverURL: String,
        profileID: String,
        tracks: List<Track>,
        catalog: List<RemoteSong> = emptyList(),
    ): List<ListeningHistoryEntry> {
        val origin = normalizedOrigin(serverURL) ?: return existing
        if (document.profileID != profileID) return existing
        val active = existing.filter { matchesContext(it, serverURL, profileID) }.associateBy { it.id }.toMutableMap()
        val others = existing.filterNot { matchesContext(it, serverURL, profileID) }
        val tracksByID = tracks.associateBy(Track::id)
        val tracksByRemoteID = tracks.filter { RemoteTrackIdentityPolicy.matches(it, serverURL, profileID) }
            .mapNotNull { track -> track.remoteID?.let { it to track } }.toMap()
        val catalogByID = catalog.associateBy(RemoteSong::id)
        document.entries.forEach { remote ->
            val id = limited(remote.id, 128) ?: return@forEach
            val trackID = limited(remote.trackID, 128) ?: return@forEach
            runCatching { Instant.parse(remote.startedAt) }.getOrNull() ?: return@forEach
            val old = active[id]
            val songID = limited(remote.songID, 128) ?: old?.remoteSongID
            val localTrack = songID?.let(tracksByRemoteID::get) ?: tracksByID[trackID]
            val catalogSong = songID?.let(catalogByID::get)
            active[id] = ListeningHistoryEntry(
                id = id,
                trackID = localTrack?.id ?: old?.trackID ?: trackID,
                startedAt = old?.startedAt ?: remote.startedAt,
                listenedSeconds = maxOf(old?.listenedSeconds ?: 0.0, remote.listenedSeconds),
                serverOrigin = origin,
                syncProfileID = profileID,
                remoteSongID = songID ?: localTrack?.remoteID,
                title = catalogSong?.title ?: remote.title ?: old?.title ?: localTrack?.title,
                artist = catalogSong?.artist ?: remote.artist ?: old?.artist ?: localTrack?.artist,
                album = catalogSong?.album ?: remote.album ?: old?.album ?: localTrack?.album,
                durationSeconds = catalogSong?.durationSeconds ?: remote.durationSeconds ?: old?.durationSeconds
                    ?: localTrack?.durationMs?.takeIf { it > 0L }?.div(1_000.0),
                artworkURL = normalizedArtworkURL(
                    remote.artworkURL ?: catalogSong?.artworkURL ?: old?.artworkURL,
                ),
                originatedOnThisDevice = old?.originatedOnThisDevice ?: false,
            )
        }
        return normalize(others + active.values)
    }

    private fun normalized(entry: ListeningHistoryEntry): ListeningHistoryEntry? {
        val id = limited(entry.id, 128) ?: return null
        val trackID = limited(entry.trackID, 128) ?: return null
        runCatching { Instant.parse(entry.startedAt) }.getOrNull() ?: return null
        if (!entry.listenedSeconds.isFinite() || entry.listenedSeconds < 0.0) return null
        return entry.copy(
            id = id,
            trackID = trackID,
            listenedSeconds = entry.listenedSeconds.coerceAtMost(MAX_LISTENED_SECONDS),
            serverOrigin = normalizedOrigin(entry.serverOrigin),
            syncProfileID = entry.syncProfileID.trim().ifEmpty { "default" },
            remoteSongID = limited(entry.remoteSongID, 128),
            title = limited(entry.title, 500),
            artist = limited(entry.artist, 500),
            album = limited(entry.album, 500),
            durationSeconds = entry.durationSeconds?.takeIf { it.isFinite() && it >= 0.0 }
                ?.coerceAtMost(MAX_DURATION_SECONDS),
            artworkURL = normalizedArtworkURL(entry.artworkURL),
        )
    }

    private fun limited(value: String?, maximum: Int): String? = value?.trim()?.takeIf(String::isNotEmpty)?.take(maximum)
    private fun normalizedArtworkURL(value: String?): String? = limited(value, 2_048)
        ?.takeIf { runCatching { java.net.URI(it) }.getOrNull()?.let { uri ->
            uri.scheme.equals("https", ignoreCase = true) && !uri.host.isNullOrBlank() && uri.userInfo == null
        } == true }
    private fun normalizedOrigin(value: String?): String? = value?.trim()?.takeIf(String::isNotEmpty)
        ?.let(RemoteTrackIdentityPolicy::normalizedOrigin)
}
