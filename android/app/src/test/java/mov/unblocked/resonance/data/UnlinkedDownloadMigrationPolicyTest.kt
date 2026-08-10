package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnlinkedDownloadMigrationPolicyTest {
    private fun track(
        sourceURL: String? = null,
        downloadSourceURL: String? = null,
        preservesUnlinkedImport: Boolean? = null,
    ) = Track(
        title = "Song",
        relativePath = "song.m4a",
        remoteID = "remote-song",
        sourceServer = "https://music.example",
        sourceURL = sourceURL,
        downloadSourceURL = downloadSourceURL,
        preservesUnlinkedImport = preservesUnlinkedImport,
    )

    @Test
    fun unlinkedManagedDownloadIsSelectedForCleanup() {
        val decision = UnlinkedDownloadMigrationPolicy.decision(
            track(),
            legacyDownloadOwned = true,
        )

        assertTrue(decision.shouldDelete)
        assertEquals(false, decision.track.preservesUnlinkedImport)
    }

    @Test
    fun eitherPreservedSourceLinkKeepsDownload() {
        assertFalse(UnlinkedDownloadMigrationPolicy.decision(
            track(sourceURL = "https://source.example/song"),
            legacyDownloadOwned = true,
        ).shouldDelete)
        assertFalse(UnlinkedDownloadMigrationPolicy.decision(
            track(downloadSourceURL = "https://media.example/song.m4a"),
            legacyDownloadOwned = true,
        ).shouldDelete)
    }

    @Test
    fun explicitImportFlagWinsAfterRemoteAssociation() {
        val decision = UnlinkedDownloadMigrationPolicy.decision(
            track(preservesUnlinkedImport = true),
            legacyDownloadOwned = true,
        )

        assertFalse(decision.shouldDelete)
        assertEquals(true, decision.track.preservesUnlinkedImport)
    }

    @Test
    fun legacyNonDownloadFileBecomesProtectedImport() {
        val decision = UnlinkedDownloadMigrationPolicy.decision(
            track(),
            legacyDownloadOwned = false,
        )

        assertFalse(decision.shouldDelete)
        assertEquals(true, decision.track.preservesUnlinkedImport)
    }
}
