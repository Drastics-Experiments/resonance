package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BatchDownloadPolicyTest {
    private fun song(
        title: String = "Catalog title",
        artist: String = "Catalog artist",
        durationSeconds: Double? = 211.5,
        isMetadataLoading: Boolean = false,
    ) = RemoteSong(
        id = "song-a",
        filename = "song-a.m4a",
        title = title,
        artist = artist,
        album = "Catalog album",
        size = 1_024L,
        modifiedAt = "2026-01-01T00:00:00Z",
        contentType = "audio/mp4",
        downloadURL = "/api/v1/songs/song-a/download",
        streamURL = "/api/v1/songs/song-a/stream",
        durationSeconds = durationSeconds,
        contentSHA256 = "a".repeat(64),
    ).copy(isMetadataLoading = isMetadataLoading)

    @Test fun mobilePoolUsesThreeWorkers() {
        assertEquals(3, BatchDownloadPolicy.MobileConcurrency)
    }

    @Test fun completeCatalogRowsSkipEmbeddedTagScanning() {
        assertTrue(BatchDownloadPolicy.canUseCatalogMetadata(song()))
        assertFalse(BatchDownloadPolicy.canUseCatalogMetadata(song(durationSeconds = null)))
        assertFalse(BatchDownloadPolicy.canUseCatalogMetadata(song(isMetadataLoading = true)))
        assertFalse(BatchDownloadPolicy.canUseCatalogMetadata(song(title = "Resolving metadata…")))
        assertFalse(BatchDownloadPolicy.canUseCatalogMetadata(song(artist = "Unknown Artist")))
    }
}
