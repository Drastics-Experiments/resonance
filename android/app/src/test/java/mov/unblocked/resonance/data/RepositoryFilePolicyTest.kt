package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RepositoryFilePolicyTest {
    private val firstID = "11111111-1111-4111-8111-111111111111"
    private val secondID = "22222222-2222-4222-8222-222222222222"

    @Test
    fun randomDownloadNamesRetainOnlyASafeExtension() {
        val filename = RepositoryFilePolicy.newDownloadFilename(
            preferredFilename = "../Artist - Song.MP3",
            randomID = firstID,
        )

        assertEquals("resonance-download-$firstID.mp3", filename)
        assertEquals(firstID, RepositoryFilePolicy.downloadID(filename))
        assertEquals(
            ".resonance-staging-$firstID.download",
            RepositoryFilePolicy.newStagingFilename(firstID),
        )
    }

    @Test
    fun cleanupSelectsOnlyUnreferencedAppOwnedMusic() {
        val referencedDownload = RepositoryFilePolicy.newDownloadFilename("keep.m4a", firstID)
        val orphanedDownload = RepositoryFilePolicy.newDownloadFilename("orphan.mp3", secondID)
        val staging = RepositoryFilePolicy.newStagingFilename(firstID)
        val candidates = listOf(
            referencedDownload,
            orphanedDownload,
            staging,
            "Song.mp3",
            "resonance-download-not-a-uuid.mp3",
            ".resonance-staging-not-a-uuid.download",
        )

        assertEquals(
            setOf(orphanedDownload, staging),
            RepositoryFilePolicy.orphanedMusicFilenames(
                candidateFilenames = candidates,
                referencedFilenames = setOf(referencedDownload),
                stateIsTrustworthy = true,
            ),
        )
        assertTrue(
            RepositoryFilePolicy.orphanedMusicFilenames(
                candidateFilenames = candidates,
                referencedFilenames = emptySet(),
                stateIsTrustworthy = false,
            ).isEmpty(),
        )
    }

    @Test
    fun cleanupLeavesArtworkAloneWhenStateIsCorrupt() {
        val referencedArtwork = "$firstID.artwork"
        val orphanedArtwork = "$secondID.artwork"
        val candidates = listOf(referencedArtwork, orphanedArtwork, "cover.artwork", "cover.jpg")

        assertEquals(
            setOf(orphanedArtwork),
            RepositoryFilePolicy.orphanedArtworkFilenames(
                candidateFilenames = candidates,
                referencedFilenames = setOf(referencedArtwork),
                stateIsTrustworthy = true,
            ),
        )
        assertTrue(
            RepositoryFilePolicy.orphanedArtworkFilenames(
                candidateFilenames = candidates,
                referencedFilenames = emptySet(),
                stateIsTrustworthy = false,
            ).isEmpty(),
        )
    }
}
