package mov.unblocked.resonance.data

data class DownloadItemProgressPresentation(
    val currentItem: Int,
    val totalItems: Int,
    val title: String,
    val bytesTransferred: Long,
    val totalBytes: Long?,
    val isComplete: Boolean = false,
) {
    val fraction: Float
        get() = totalBytes
            ?.takeIf { it > 0L }
            ?.let { (bytesTransferred.toFloat() / it.toFloat()).coerceIn(0f, 1f) }
            ?: if (isComplete) 1f else 0f
}

enum class DownloadProgressDisplayMode {
    Preparing,
    IndeterminateTransfer,
    DeterminateTransfer,
}

/** Keeps connection/source preparation from looking like a stalled zero-byte transfer. */
object DownloadProgressDisplayPolicy {
    fun mode(bytesTransferred: Long, totalBytes: Long?): DownloadProgressDisplayMode = when {
        bytesTransferred <= 0L -> DownloadProgressDisplayMode.Preparing
        totalBytes == null || totalBytes <= 0L -> DownloadProgressDisplayMode.IndeterminateTransfer
        else -> DownloadProgressDisplayMode.DeterminateTransfer
    }

    fun percentageLabel(fraction: Float): String = when {
        fraction > 0f && fraction < .01f -> "<1%"
        else -> "${(fraction.coerceIn(0f, 1f) * 100).toInt()}%"
    }
}

/** Reuses the title/artist already supplied or hydrated for a server catalog row. */
object RemoteSongDownloadMetadataPolicy {
    fun knownTrack(song: RemoteSong): LinkImportTrack? {
        if (song.isMetadataLoading) return null
        val sourceURL = song.sourceURL?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val title = song.title.trim()
            .takeIf { it.isNotEmpty() && it != "Resolving metadata…" }
            ?: return null
        val artist = song.artist.trim()
            .takeIf { it.isNotEmpty() && it != "On-device lookup" }
            ?: return null
        return LinkImportTrack(
            title = title,
            artist = artist,
            album = song.album.trim().takeIf { it.isNotEmpty() && it != "Link only" },
            durationSeconds = song.durationSeconds
                ?.takeIf { it.isFinite() && it > 0.0 }
                ?.toInt(),
            artworkURL = song.artworkURL,
            sourceURL = sourceURL,
        )
    }
}

data class RemoteSourceResolutionCacheKey(
    val serverOrigin: String,
    val profileID: String,
    val connectionGeneration: Long,
    val accountScope: String?,
    val mediaMode: LinkImportMediaMode,
    val sourceURL: String,
)

/** Prevents a prepared source choice or catalog title from leaking across server contexts. */
object RemoteSourceResolutionCachePolicy {
    fun key(
        context: ServerProfileContext,
        mediaMode: LinkImportMediaMode,
        sourceURL: String?,
        accountScope: String?,
    ): RemoteSourceResolutionCacheKey? {
        val origin = RemoteTrackIdentityPolicy.normalizedOrigin(context.serverURL) ?: return null
        val source = sourceURL?.trim()?.takeIf(String::isNotEmpty) ?: return null
        RemoteSongMetadataCachePolicy.key(source, mediaMode.name.lowercase()) ?: return null
        return RemoteSourceResolutionCacheKey(
            serverOrigin = origin,
            profileID = context.profileID,
            connectionGeneration = context.connectionGeneration,
            accountScope = accountScope?.trim()?.takeIf(String::isNotEmpty),
            mediaMode = mediaMode,
            sourceURL = source,
        )
    }

    fun canReuse(
        resolution: LinkImportResolution,
        cachedKey: RemoteSourceResolutionCacheKey,
        expectedKey: RemoteSourceResolutionCacheKey,
        knownCatalogMetadata: LinkImportTrack?,
    ): Boolean {
        if (cachedKey != expectedKey || resolution.kind != LinkImportKind.Track ||
            resolution.playlist != null || resolution.candidates.isEmpty()
        ) return false
        if (knownCatalogMetadata == null) return true
        if (knownCatalogMetadata.sourceURL.trim() != expectedKey.sourceURL) return false
        return resolution.track.title.trim() == knownCatalogMetadata.title.trim() &&
            resolution.track.artist.trim() == knownCatalogMetadata.artist.trim()
    }
}

/** Builds a single-song presentation; internal destination filenames are never presentation data. */
object DownloadItemProgressPolicy {
    fun fromCatalogTransfer(
        progress: TransferProgress,
        completedBefore: Int,
        batchTotal: Int,
        catalogTitlesByID: Map<String, String>,
    ): DownloadItemProgressPresentation {
        val current = (completedBefore + progress.currentItem)
            .coerceIn(1, batchTotal.coerceAtLeast(1))
        val catalogTitle = progress.currentSongID
            ?.let(catalogTitlesByID::get)
            ?.trim()
            ?.takeIf(String::isNotEmpty)
        val title = catalogTitle
            ?: progress.currentTitle.trim().takeIf(String::isNotEmpty)
            ?: "Song $current"
        return DownloadItemProgressPresentation(
            currentItem = current,
            totalItems = batchTotal.coerceAtLeast(1),
            title = title,
            bytesTransferred = progress.bytesTransferred.coerceAtLeast(0L),
            totalBytes = progress.totalBytes?.takeIf { it > 0L },
            isComplete = progress.currentItemComplete,
        )
    }

    fun fromBytes(
        currentItem: Int,
        totalItems: Int,
        title: String,
        bytesTransferred: Long,
        totalBytes: Long?,
        isComplete: Boolean = false,
    ): DownloadItemProgressPresentation = DownloadItemProgressPresentation(
        currentItem = currentItem.coerceIn(1, totalItems.coerceAtLeast(1)),
        totalItems = totalItems.coerceAtLeast(1),
        title = title.trim().ifBlank { "Song ${currentItem.coerceAtLeast(1)}" },
        bytesTransferred = bytesTransferred.coerceAtLeast(0L),
        totalBytes = totalBytes?.takeIf { it > 0L },
        isComplete = isComplete,
    )
}

object PendingDownloadBatchPolicy {
    fun songs(
        requestedSongs: List<RemoteSong>,
        existingRemoteSongIDs: Set<String>,
    ): List<RemoteSong> = requestedSongs.filterNot { it.id in existingRemoteSongIDs }
}
