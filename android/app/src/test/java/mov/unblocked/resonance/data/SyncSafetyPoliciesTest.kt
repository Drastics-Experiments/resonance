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
    fun playlistPresentationIncludesUndownloadedRemoteSongsInOrder() {
        val local = Track(title = "Local", relativePath = "local.m4a")
        val remoteA = Track(
            title = "Downloaded A",
            relativePath = "a.m4a",
            remoteID = "remote-a",
        )
        val remoteB = Track(
            title = "Downloaded B",
            relativePath = "b.m4a",
            remoteID = "remote-b",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(remoteA.id, local.id, remoteB.id),
            remoteSongIDs = listOf("remote-b", "remote-missing", "remote-a"),
        )

        val entries = PlaylistPresentationPolicy.entries(
            playlist,
            listOf(local, remoteA, remoteB),
            emptyList(),
        )

        assertEquals(
            listOf("remote:remote-b", "local:${local.id}", "remote:remote-missing", "remote:remote-a"),
            entries.map(PlaylistPresentationEntry::stableID),
        )
        assertEquals(
            listOf(true, true, false, true),
            entries.map { it is PlaylistPresentationEntry.Downloaded },
        )
        assertEquals(
            "remote-missing",
            (entries[2] as PlaylistPresentationEntry.Unavailable).remoteSongID,
        )
    }

    @Test
    fun unavailableRemoteSongsCanMoveAcrossLocalSongsAndRoundTripExactly() {
        val local = Track(title = "Local", relativePath = "local.m4a")
        val downloaded = Track(
            title = "Downloaded B",
            relativePath = "b.m4a",
            remoteID = "remote-b",
        )
        val original = Playlist(
            name = "Shared",
            trackIDs = listOf(local.id, downloaded.id),
            remoteSongIDs = listOf("remote-a", "remote-b"),
        )
        assertEquals(
            listOf("local:${local.id}", "remote:remote-a", "remote:remote-b"),
            PlaylistPresentationPolicy.entries(original, listOf(local, downloaded), emptyList())
                .map(PlaylistPresentationEntry::stableID),
        )

        val moved = PlaylistEntryOrderPolicy.move(
            playlist = original,
            tracks = listOf(local, downloaded),
            remoteSongs = emptyList(),
            fromIndex = 1,
            toIndex = 0,
        )

        assertEquals(listOf(local.id, downloaded.id), moved.trackIDs)
        assertEquals(listOf("remote-a", "remote-b"), moved.remoteSongIDs)
        assertEquals(
            listOf("remote:remote-a", "local:${local.id}", "remote:remote-b"),
            moved.entryOrder,
        )
        assertEquals(
            moved.entryOrder,
            PlaylistPresentationPolicy.entries(moved, listOf(local, downloaded), emptyList())
                .map(PlaylistPresentationEntry::stableID),
        )
    }

    @Test
    fun serializedMixedEntryOrderRoundTripsAndSurvivesRemoteRefresh() {
        val local = Track(title = "Local", relativePath = "local.m4a")
        val downloaded = Track(
            title = "Downloaded B",
            relativePath = "b.m4a",
            remoteID = "remote-b",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(local.id, downloaded.id),
            remoteSongIDs = listOf("remote-a", "remote-b"),
            entryOrder = listOf("remote:remote-a", "local:${local.id}", "remote:remote-b"),
        )

        assertEquals(
            playlist.entryOrder,
            PlaylistPresentationPolicy.entries(playlist, listOf(local, downloaded), emptyList())
                .map(PlaylistPresentationEntry::stableID),
        )
        assertEquals(
            playlist.entryOrder,
            PlaylistEntryOrderPolicy.mergingRemoteOrder(
                previous = playlist,
                remoteSongIDs = listOf("remote-a", "remote-b"),
                tracks = listOf(local, downloaded),
            ),
        )
    }

    @Test
    fun remoteRefreshReconcilesStaleTokensAndRestoresMissingLocalTokens() {
        val local = Track(title = "Local", relativePath = "local.m4a")
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(local.id),
            remoteSongIDs = listOf("remote-old"),
            entryOrder = listOf("remote:remote-old", "local:stale"),
        )

        assertEquals(
            listOf("remote:remote-new", "local:${local.id}"),
            PlaylistEntryOrderPolicy.mergingRemoteOrder(
                previous = playlist,
                remoteSongIDs = listOf("remote-new"),
                tracks = listOf(local),
            ),
        )
    }

    @Test
    fun movingUnavailableSongPersistsRemoteAndDownloadedRelativeOrder() {
        val remoteA = Track(
            title = "Downloaded A",
            relativePath = "a.m4a",
            remoteID = "remote-a",
        )
        val remoteC = Track(
            title = "Downloaded C",
            relativePath = "c.m4a",
            remoteID = "remote-c",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(remoteA.id, remoteC.id),
            remoteSongIDs = listOf("remote-a", "remote-b", "remote-c"),
        )

        val moved = PlaylistEntryOrderPolicy.move(
            playlist,
            listOf(remoteA, remoteC),
            emptyList(),
            fromIndex = 1,
            toIndex = 2,
        )

        assertEquals(listOf(remoteA.id, remoteC.id), moved.trackIDs)
        assertEquals(listOf("remote-a", "remote-c", "remote-b"), moved.remoteSongIDs)
        assertEquals(
            listOf("remote:remote-a", "remote:remote-c", "remote:remote-b"),
            PlaylistPresentationPolicy.entries(moved, listOf(remoteA, remoteC), emptyList())
                .map(PlaylistPresentationEntry::stableID),
        )
    }

    @Test
    fun deletingDownloadedSongKeepsItsExactSlotAsUnavailableWhenServerStillHasIt() {
        val before = Track(title = "Before", relativePath = "before.m4a")
        val downloaded = Track(
            title = "Downloaded",
            relativePath = "downloaded.m4a",
            remoteID = "remote-song",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val after = Track(title = "After", relativePath = "after.m4a")
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(before.id, downloaded.id, after.id),
            remoteSongIDs = emptyList(),
            entryOrder = listOf("local:${before.id}", "local:${downloaded.id}", "local:${after.id}"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(before, downloaded, after),
            deletingTrackIDs = setOf(downloaded.id),
            activeRemoteSongIDs = setOf("remote-song"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertEquals(listOf(before.id, after.id), updated.trackIDs)
        assertEquals(listOf("remote-song"), updated.remoteSongIDs)
        assertEquals(
            listOf("local:${before.id}", "remote:remote-song", "local:${after.id}"),
            updated.entryOrder,
        )
        assertEquals(
            updated.entryOrder,
            PlaylistPresentationPolicy.entries(updated, listOf(before, after), emptyList())
                .map(PlaylistPresentationEntry::stableID),
        )
    }

    @Test
    fun deletingDownloadedRemoteEntryPreservesExistingRemoteMembershipAndOrder() {
        val before = Track(title = "Before", relativePath = "before.m4a")
        val downloaded = Track(
            title = "Downloaded",
            relativePath = "downloaded.m4a",
            remoteID = "remote-song",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val after = Track(title = "After", relativePath = "after.m4a")
        val expectedOrder = listOf(
            "local:${before.id}",
            "remote:remote-song",
            "local:${after.id}",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(before.id, downloaded.id, after.id),
            remoteSongIDs = listOf("remote-song"),
            entryOrder = expectedOrder,
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(before, downloaded, after),
            deletingTrackIDs = setOf(downloaded.id),
            activeRemoteSongIDs = setOf("remote-song"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertEquals(listOf(before.id, after.id), updated.trackIDs)
        assertEquals(listOf("remote-song"), updated.remoteSongIDs)
        assertEquals(expectedOrder, updated.entryOrder)
    }

    @Test
    fun localOnlyDeletionKeepsCanonicalRemoteOrderWhenDeviceOrderIsReversed() {
        val local = Track(title = "Device only", relativePath = "local.m4a")
        val playlist = Playlist(
            name = "Mixed",
            trackIDs = listOf(local.id),
            remoteSongIDs = listOf("remote-a", "remote-b"),
            entryOrder = listOf("remote:remote-b", "local:${local.id}", "remote:remote-a"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(local),
            deletingTrackIDs = setOf(local.id),
            activeRemoteSongIDs = setOf("remote-a", "remote-b"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertTrue(updated.trackIDs.isEmpty())
        assertEquals(listOf("remote-a", "remote-b"), updated.remoteSongIDs)
        assertEquals(listOf("remote:remote-b", "remote:remote-a"), updated.entryOrder)
    }

    @Test
    fun legacyLocalMembershipAppendsBackedIDWithoutReorderingServerMembership() {
        val downloaded = Track(
            title = "Legacy download",
            relativePath = "legacy.m4a",
            remoteID = "remote-x",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val playlist = Playlist(
            name = "Mixed",
            trackIDs = listOf(downloaded.id),
            remoteSongIDs = listOf("remote-a", "remote-b"),
            entryOrder = listOf(
                "remote:remote-b",
                "local:${downloaded.id}",
                "remote:remote-a",
            ),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(downloaded),
            deletingTrackIDs = setOf(downloaded.id),
            activeRemoteSongIDs = setOf("remote-a", "remote-b", "remote-x"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertEquals(listOf("remote-a", "remote-b", "remote-x"), updated.remoteSongIDs)
        assertEquals(
            listOf("remote:remote-b", "remote:remote-x", "remote:remote-a"),
            updated.entryOrder,
        )
    }

    @Test
    fun offlineLegacyLocalMembershipDoesNotInventRemoteMembership() {
        val downloaded = Track(
            title = "Legacy download",
            relativePath = "legacy-offline.m4a",
            remoteID = "remote-x",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val playlist = Playlist(
            name = "Device only",
            trackIDs = listOf(downloaded.id),
            remoteSongIDs = emptyList(),
            entryOrder = listOf("local:${downloaded.id}"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(downloaded),
            deletingTrackIDs = setOf(downloaded.id),
            // A retained/stale catalog ID is not authoritative after a failed refresh.
            activeRemoteSongIDs = setOf("remote-x"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = false,
        )

        assertTrue(updated.trackIDs.isEmpty())
        assertTrue(updated.remoteSongIDs.orEmpty().isEmpty())
        assertTrue(updated.entryOrder.orEmpty().isEmpty())
    }

    @Test
    fun localOnlyDeletionNeverChangesExistingRemoteMembership() {
        val local = Track(title = "Device only", relativePath = "local.m4a")
        val playlist = Playlist(
            name = "Mixed",
            trackIDs = listOf(local.id),
            remoteSongIDs = listOf("remote-a", "remote-b"),
            entryOrder = listOf("local:${local.id}", "remote:remote-a", "remote:remote-b"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(local),
            deletingTrackIDs = setOf(local.id),
            activeRemoteSongIDs = emptySet(),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertEquals(listOf("remote-a", "remote-b"), updated.remoteSongIDs)
        assertEquals(listOf("remote:remote-a", "remote:remote-b"), updated.entryOrder)
    }

    @Test
    fun sameSongIDFromAnotherContextCannotCreateActiveRemoteMembership() {
        val foreignDownload = Track(
            title = "Other profile",
            relativePath = "foreign.m4a",
            remoteID = "same-song-id",
            sourceServer = "https://other.example",
            syncProfileID = "other-profile",
        )
        val playlist = Playlist(
            name = "Mixed",
            trackIDs = listOf(foreignDownload.id),
            remoteSongIDs = emptyList(),
            entryOrder = listOf("local:${foreignDownload.id}"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(foreignDownload),
            deletingTrackIDs = setOf(foreignDownload.id),
            // The active catalog contains the same opaque ID, but for another identity tuple.
            activeRemoteSongIDs = setOf("same-song-id"),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertTrue(updated.trackIDs.isEmpty())
        assertTrue(updated.remoteSongIDs.orEmpty().isEmpty())
        assertTrue(updated.entryOrder.orEmpty().isEmpty())
    }

    @Test
    fun deletingSongWithoutActiveServerBackingRemovesMembershipAndStaleOrderToken() {
        val downloaded = Track(
            title = "Gone",
            relativePath = "gone.m4a",
            remoteID = "remote-gone",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(downloaded.id),
            remoteSongIDs = listOf("remote-a", "remote-gone", "remote-b"),
            entryOrder = listOf("remote:remote-b", "remote:remote-gone", "remote:remote-a"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(downloaded),
            deletingTrackIDs = setOf(downloaded.id),
            activeRemoteSongIDs = emptySet(),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = true,
        )

        assertTrue(updated.trackIDs.isEmpty())
        assertEquals(listOf("remote-a", "remote-b"), updated.remoteSongIDs)
        assertEquals(listOf("remote:remote-b", "remote:remote-a"), updated.entryOrder)
    }

    @Test
    fun unavailableCatalogCannotRemoveRemoteMembership() {
        val downloaded = Track(
            title = "Still unknown",
            relativePath = "unknown.m4a",
            remoteID = "remote-song",
            sourceServer = "https://music.example",
            syncProfileID = "default",
        )
        val playlist = Playlist(
            name = "Shared",
            trackIDs = listOf(downloaded.id),
            remoteSongIDs = listOf("remote-song"),
            entryOrder = listOf("remote:remote-song"),
        )

        val updated = PlaylistLocalDeletionPolicy.apply(
            playlist,
            tracks = listOf(downloaded),
            deletingTrackIDs = setOf(downloaded.id),
            activeRemoteSongIDs = emptySet(),
            activeServerURL = "https://music.example",
            activeProfileID = "default",
            catalogIsAuthoritative = false,
        )

        assertTrue(updated.trackIDs.isEmpty())
        assertEquals(listOf("remote-song"), updated.remoteSongIDs)
        assertEquals(listOf("remote:remote-song"), updated.entryOrder)
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

    @Test
    fun failedOrSupersededRefreshInvalidatesDeletionAuthority() {
        val context = ServerProfileContext("https://music.example", "default", 7)
        val lastSuccess = CatalogRequestSnapshot(
            context,
            requestGeneration = 3,
            uploadMutationGeneration = 9,
        )

        assertTrue(CatalogAuthorityPolicy.isFresh(lastSuccess, context, 3, 9))
        // Beginning request 4 makes request 3 stale even when request 4 fails and the UI keeps
        // the last working catalog/session visible.
        assertFalse(CatalogAuthorityPolicy.isFresh(lastSuccess, context, 4, 9))
        assertFalse(CatalogAuthorityPolicy.isFresh(lastSuccess, context.copy(profileID = "other"), 3, 9))
        assertFalse(CatalogAuthorityPolicy.isFresh(lastSuccess, context, 3, 10))
    }
}
