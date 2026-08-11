package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadItemProgressPolicyTest {
    @Test fun cachedSongsAreExcludedFromTheVisibleBatchCounter() {
        val cached = RemoteSong(
            id = "cached-a",
            filename = "cached.m4a",
            title = "Cached A",
            artist = "Artist",
            album = "Album",
            size = 1L,
            modifiedAt = "2026-01-01T00:00:00Z",
            contentType = "audio/mp4",
            downloadURL = "/download/cached-a",
            streamURL = "/stream/cached-a",
            durationSeconds = 1.0,
        )
        val pending = cached.copy(id = "pending-b", filename = "pending.m4a", title = "Pending B")

        val batch = PendingDownloadBatchPolicy.songs(
            requestedSongs = listOf(cached, pending),
            existingRemoteSongIDs = setOf(cached.id),
        )
        val presentation = DownloadItemProgressPolicy.fromCatalogTransfer(
            progress = TransferProgress(
                completed = 0,
                total = batch.size,
                currentFilename = pending.filename,
                currentItem = 1,
                currentSongID = pending.id,
                currentTitle = pending.title,
            ),
            completedBefore = 0,
            batchTotal = batch.size,
            catalogTitlesByID = batch.associate { it.id to it.title },
        )

        assertEquals(listOf("pending-b"), batch.map(RemoteSong::id))
        assertEquals(1, presentation.currentItem)
        assertEquals(1, presentation.totalItems)
    }

    @Test fun catalogTitleAndCurrentSongBytesDriveThePresentation() {
        val presentation = DownloadItemProgressPolicy.fromCatalogTransfer(
            progress = TransferProgress(
                completed = 1,
                total = 4,
                currentFilename = "3f1dd0f6-download.part",
                currentItem = 2,
                currentSongID = "song-b",
                currentTitle = "Stale resolver title",
                bytesTransferred = 25L,
                totalBytes = 100L,
            ),
            completedBefore = 1,
            batchTotal = 10,
            catalogTitlesByID = mapOf("song-b" to "Catalog Song Title"),
        )

        assertEquals(3, presentation.currentItem)
        assertEquals(10, presentation.totalItems)
        assertEquals("Catalog Song Title", presentation.title)
        assertEquals(25L, presentation.bytesTransferred)
        assertEquals(100L, presentation.totalBytes)
        assertEquals(.25f, presentation.fraction, 0f)
    }

    @Test fun retryStartsTheSameSongAtZeroInsteadOfKeepingAggregateProgress() {
        val retry = DownloadItemProgressPolicy.fromBytes(
            currentItem = 3,
            totalItems = 10,
            title = "Catalog Song Title",
            bytesTransferred = 0L,
            totalBytes = 200L,
        )

        assertEquals(3, retry.currentItem)
        assertEquals("Catalog Song Title", retry.title)
        assertEquals(0f, retry.fraction, 0f)
    }

    @Test fun completedUnknownLengthTransferCanStillFinishItsBar() {
        assertEquals(
            1f,
            DownloadItemProgressPolicy.fromBytes(
                currentItem = 1,
                totalItems = 1,
                title = "Song",
                bytesTransferred = 50L,
                totalBytes = null,
                isComplete = true,
            ).fraction,
            0f,
        )
    }
}
