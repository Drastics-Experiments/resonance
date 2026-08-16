package mov.unblocked.resonance.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteArtworkPersistencePolicyTest {
    @Test
    fun authoritativeCatalogArtworkReplacesTemporaryEmbeddedArtwork() {
        assertTrue(
            RemoteArtworkPersistencePolicy.shouldBackfill(
                artworkScanComplete = false,
                existingArtworkBytes = 4_096L,
                artworkURL = "https://images.example/song-a.jpg",
            ),
        )
    }

    @Test
    fun completedNonEmptyCatalogArtworkIsNotFetchedAgain() {
        assertFalse(
            RemoteArtworkPersistencePolicy.shouldBackfill(
                artworkScanComplete = true,
                existingArtworkBytes = 4_096L,
                artworkURL = "https://images.example/song-a.jpg",
            ),
        )
    }

    @Test
    fun missingFilesAreRepairedAndMissingUrlsAreSkipped() {
        assertTrue(
            RemoteArtworkPersistencePolicy.shouldBackfill(
                artworkScanComplete = true,
                existingArtworkBytes = null,
                artworkURL = "https://images.example/song-a.jpg",
            ),
        )
        assertFalse(
            RemoteArtworkPersistencePolicy.shouldBackfill(
                artworkScanComplete = false,
                existingArtworkBytes = null,
                artworkURL = null,
            ),
        )
    }
}
