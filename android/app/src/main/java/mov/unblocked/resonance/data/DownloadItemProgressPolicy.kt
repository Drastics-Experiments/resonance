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
