package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncSafetyPoliciesTest {
    @Test
    fun playlistOrderMergeKeepsDeviceOnlyAndUnresolvedItemsInStableSlots() {
        assertEquals(
            listOf("remote-b", "local", "remote-c", "remote-a"),
            PlaylistOrderPolicy.merge(
                previous = listOf("remote-a", "local", "remote-b"),
                ordered = listOf("remote-b", "remote-c", "remote-a"),
                preserving = listOf("local"),
            ),
        )
        assertEquals(
            listOf("remote-b", "unresolved", "remote-a"),
            PlaylistOrderPolicy.merge(
                previous = listOf("remote-a", "unresolved", "remote-b"),
                ordered = listOf("remote-b", "remote-a"),
                preserving = listOf("unresolved"),
            ),
        )
    }

    @Test
    fun stablePlaylistSubmissionClearsOnlyItsOwnDirtySnapshot() {
        val result = PlaylistSyncMutationPolicy.reconcile(
            submitted = PlaylistMutationSnapshot(4, setOf("submitted"), setOf("deleted")),
            currentGeneration = 4,
            currentDirtyPlaylistIDs = setOf("submitted", "newer-untracked"),
            currentDeletedPlaylistIDs = setOf("deleted", "newer-deletion"),
        )

        assertEquals(setOf("newer-untracked"), result.dirtyPlaylistIDs)
        assertEquals(setOf("newer-deletion"), result.deletedPlaylistIDs)
        assertTrue(result.applyRemoteDocument)
        assertFalse(result.needsRerun)
    }

    @Test
    fun playlistMutationDuringPutPreservesAllNewerStateAndRejectsStaleDocument() {
        val result = PlaylistSyncMutationPolicy.reconcile(
            submitted = PlaylistMutationSnapshot(4, setOf("playlist"), emptySet()),
            currentGeneration = 5,
            currentDirtyPlaylistIDs = setOf("playlist"),
            currentDeletedPlaylistIDs = setOf("new-deletion"),
        )

        assertEquals(setOf("playlist"), result.dirtyPlaylistIDs)
        assertEquals(setOf("new-deletion"), result.deletedPlaylistIDs)
        assertFalse(result.applyRemoteDocument)
        assertTrue(result.needsRerun)
    }

    @Test
    fun staleCatalogResponsesCannotCrossUploadsConnectionsProfilesOrNewerRequests() {
        val context = ServerProfileContext("https://music.example", "default", 7)
        val submitted = CatalogRequestSnapshot(context, requestGeneration = 3, uploadMutationGeneration = 9)

        assertTrue(CatalogResponsePolicy.shouldApply(submitted, context, 3, 9))
        assertFalse(CatalogResponsePolicy.shouldApply(submitted, context.copy(profileID = "other"), 3, 9))
        assertFalse(CatalogResponsePolicy.shouldApply(submitted, context.copy(connectionGeneration = 8), 3, 9))
        assertFalse(CatalogResponsePolicy.shouldApply(submitted, context, 4, 9))
        assertFalse(CatalogResponsePolicy.shouldApply(submitted, context, 3, 10))
    }
}
