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
    val detail: String? = null,
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

/** Zero-byte source preparation is indeterminate; received bytes become determinate progress. */
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


/** Keeps a single-song popup stable while multiple downloads run underneath it. */
internal class BatchDownloadPresentationCoordinator(itemCount: Int) {
    private val active = BooleanArray(itemCount.coerceAtLeast(0)) { true }
    private val latest = arrayOfNulls<TransferProgress>(active.size)
    private var presentedIndex = -1

    private fun hasBytes(progress: TransferProgress?): Boolean =
        (progress?.bytesTransferred ?: 0L) > 0L

    private fun bestIndex(): Int {
        val started = active.indices.filter { active[it] && latest[it] != null }
        return started.firstOrNull { hasBytes(latest[it]) }
            ?: started.firstOrNull()
            ?: active.indexOfFirst { it }
    }

    fun update(index: Int, progress: TransferProgress): TransferProgress? {
        if (index !in active.indices || !active[index]) return null
        latest[index] = progress
        if (presentedIndex !in active.indices || !active[presentedIndex]) {
            presentedIndex = bestIndex()
        } else if (index != presentedIndex) {
            val currentHasBytes = hasBytes(latest[presentedIndex])
            val candidateHasBytes = hasBytes(progress)
            if ((!currentHasBytes && candidateHasBytes) ||
                (!currentHasBytes && !candidateHasBytes && index < presentedIndex)
            ) {
                presentedIndex = index
            }
        }
        return progress.takeIf { index == presentedIndex }
    }

    fun complete(index: Int): TransferProgress? {
        if (index !in active.indices || !active[index]) return null
        active[index] = false
        latest[index] = null
        if (index != presentedIndex) return null
        presentedIndex = bestIndex()
        return presentedIndex.takeIf { it >= 0 }?.let(latest::get)
    }

    fun currentIndex(): Int? = presentedIndex.takeIf { it >= 0 }
}

/** Coordinates source-provider and direct-file progress using original batch order. */
internal class DownloadItemPresentationCoordinator(itemCount: Int) {
    private val active = BooleanArray(itemCount.coerceAtLeast(0)) { true }
    private val latest = arrayOfNulls<DownloadItemProgressPresentation>(active.size)
    private var presentedIndex = -1

    private fun hasBytes(progress: DownloadItemProgressPresentation?): Boolean =
        (progress?.bytesTransferred ?: 0L) > 0L

    private fun bestIndex(): Int {
        val started = active.indices.filter { active[it] && latest[it] != null }
        return started.firstOrNull { hasBytes(latest[it]) }
            ?: started.firstOrNull()
            ?: active.indexOfFirst { it }
    }

    fun update(index: Int, progress: DownloadItemProgressPresentation): DownloadItemProgressPresentation? {
        if (index !in active.indices || !active[index]) return null
        latest[index] = progress
        if (presentedIndex !in active.indices || !active[presentedIndex]) {
            presentedIndex = bestIndex()
        } else if (index != presentedIndex) {
            val currentHasBytes = hasBytes(latest[presentedIndex])
            val candidateHasBytes = hasBytes(progress)
            if ((!currentHasBytes && candidateHasBytes) ||
                (!currentHasBytes && !candidateHasBytes && index < presentedIndex)
            ) {
                presentedIndex = index
            }
        }
        return progress.takeIf { index == presentedIndex }
    }

    fun complete(index: Int): DownloadItemProgressPresentation? {
        if (index !in active.indices || !active[index]) return null
        active[index] = false
        latest[index] = null
        if (index != presentedIndex) return null
        presentedIndex = bestIndex()
        return presentedIndex.takeIf { it >= 0 }?.let(latest::get)
    }

    fun currentIndex(): Int? = presentedIndex.takeIf { it >= 0 }
}

data class MixedProviderConcurrencyBudget(
    val sourceConcurrency: Int,
    val directConcurrency: Int,
)

/** Shares the mobile worker budget instead of running every provider before server files. */
internal object MixedProviderDownloadPolicy {
    fun budget(
        sourceCount: Int,
        directCount: Int,
        maximumConcurrency: Int = BatchDownloadPolicy.MobileConcurrency,
    ): MixedProviderConcurrencyBudget {
        val source = sourceCount.coerceAtLeast(0)
        val direct = directCount.coerceAtLeast(0)
        val maximum = maximumConcurrency.coerceAtLeast(1)
        if (source == 0) return MixedProviderConcurrencyBudget(0, minOf(maximum, direct))
        if (direct == 0) return MixedProviderConcurrencyBudget(minOf(maximum, source), 0)
        val sourceWorkers = minOf(source, maxOf(1, maximum - 1))
        return MixedProviderConcurrencyBudget(
            sourceConcurrency = sourceWorkers,
            directConcurrency = minOf(direct, maxOf(1, maximum - sourceWorkers)),
        )
    }
}

internal object ProviderDownloadPreparationPolicy {
    fun provider(sourceURL: String?): String {
        val value = sourceURL.orEmpty().lowercase()
        return when {
            "soundcloud.com" in value -> "SoundCloud"
            "spotify.com" in value || "spotify.link" in value -> "Spotify"
            "youtube.com" in value || "youtu.be" in value -> "YouTube"
            else -> "provider"
        }
    }

    fun detail(sourceURL: String?, stage: LinkImportStage): String {
        val provider = provider(sourceURL)
        return when (stage) {
            LinkImportStage.ResolvingMetadata -> "Resolving $provider"
            LinkImportStage.SearchingCandidates ->
                if (provider == "Spotify") "Finding a YouTube match" else "Finding $provider media"
            LinkImportStage.AwaitingSelection -> "Choosing a playable source"
            LinkImportStage.InspectingSource -> "Inspecting $provider"
            LinkImportStage.Downloading -> "Downloading $provider"
            LinkImportStage.SavingLocal -> "Finishing download"
            LinkImportStage.Syncing -> "Saving server association"
            LinkImportStage.Complete -> "Download complete"
            LinkImportStage.Failed -> "Download failed"
            LinkImportStage.Cancelled -> "Download cancelled"
            LinkImportStage.Idle -> "Preparing $provider"
        }
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
        detail: String? = null,
    ): DownloadItemProgressPresentation = DownloadItemProgressPresentation(
        currentItem = currentItem.coerceIn(1, totalItems.coerceAtLeast(1)),
        totalItems = totalItems.coerceAtLeast(1),
        title = title.trim().ifBlank { "Song ${currentItem.coerceAtLeast(1)}" },
        bytesTransferred = bytesTransferred.coerceAtLeast(0L),
        totalBytes = totalBytes?.takeIf { it > 0L },
        isComplete = isComplete,
        detail = detail,
    )
}

object PendingDownloadBatchPolicy {
    fun songs(
        requestedSongs: List<RemoteSong>,
        existingRemoteSongIDs: Set<String>,
    ): List<RemoteSong> = requestedSongs.filterNot { it.id in existingRemoteSongIDs }
}
