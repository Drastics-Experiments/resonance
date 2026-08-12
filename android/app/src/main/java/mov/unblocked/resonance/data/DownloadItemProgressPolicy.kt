package mov.unblocked.resonance.data

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Deferred

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
    IndeterminateTransfer,
    DeterminateTransfer,
}

/** Zero-byte preparation and item boundaries keep the batch popup in indeterminate mode. */
object DownloadProgressDisplayPolicy {
    fun mode(bytesTransferred: Long, totalBytes: Long?): DownloadProgressDisplayMode = when {
        bytesTransferred <= 0L -> DownloadProgressDisplayMode.IndeterminateTransfer
        totalBytes == null || totalBytes <= 0L -> DownloadProgressDisplayMode.IndeterminateTransfer
        else -> DownloadProgressDisplayMode.DeterminateTransfer
    }

    fun percentageLabel(fraction: Float): String = when {
        fraction > 0f && fraction < .01f -> "<1%"
        else -> "${(fraction.coerceIn(0f, 1f) * 100).toInt()}%"
    }
}

/**
 * Starts provider/media acquisition without awaiting the independent catalog metadata task.
 * Completed metadata may be consumed before final tagging, but unfinished work is left for the
 * catalog hydrator and never delays advancing the download batch.
 */
internal object RemoteSourceDownloadCoordinator {
    data class Acquisition<Media, Metadata>(
        val media: Media,
        val metadata: Deferred<Metadata?>?,
    )

    suspend fun <Media, Metadata> acquireMedia(
        metadata: Deferred<Metadata?>?,
        acquire: suspend () -> Media,
    ): Acquisition<Media, Metadata> = Acquisition(
        media = acquire(),
        metadata = metadata,
    )

    /** Reads completed enrichment without ever suspending the finished media path. */
    @OptIn(ExperimentalCoroutinesApi::class)
    fun <Metadata> completedMetadataOrNull(metadata: Deferred<Metadata?>?): Metadata? {
        if (metadata == null || !metadata.isCompleted || metadata.isCancelled) return null
        return runCatching { metadata.getCompleted() }.getOrNull()
    }
}

/** Makes the required ordering around an account, token, server, or profile mutation explicit. */
internal object RemoteDownloadContextChangePolicy {
    fun <Value> mutateAfterInvalidation(
        invalidateDownload: () -> Unit,
        mutation: () -> Value,
    ): Value {
        invalidateDownload()
        return mutation()
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
    fun hiddenBoundary(
        currentItem: Int,
        totalItems: Int,
        title: String,
    ): DownloadItemProgressPresentation = fromBytes(
        currentItem = currentItem,
        totalItems = totalItems,
        title = title,
        bytesTransferred = 0L,
        totalBytes = null,
    )

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

/**
 * Merges files into the library snapshot at the same boundary where their download completes.
 * Keeping this operation item-scoped means a later song cannot delay or discard an earlier
 * successful download.
 */
object CompletedDownloadLibraryPolicy {
    fun merge(
        library: StoredLibrary,
        completedTracks: List<Track>,
        authorize: () -> Unit = {},
    ): StoredLibrary {
        authorize()
        if (completedTracks.isEmpty()) return library
        return RemoteTrackIdentityPolicy.reconcileLibraryTracks(
            library.copy(tracks = library.tracks + completedTracks),
        )
    }

    fun filesToDiscard(
        library: StoredLibrary,
        completedTracks: List<Track>,
    ): List<Track> {
        // Physical paths are the deletion boundary. Even if identity reconciliation retained a
        // different Track record, never delete media that any current library record references.
        val referencedPaths = library.tracks.mapTo(hashSetOf(), Track::relativePath)
        return completedTracks.filterNot { it.relativePath in referencedPaths }
    }
}
