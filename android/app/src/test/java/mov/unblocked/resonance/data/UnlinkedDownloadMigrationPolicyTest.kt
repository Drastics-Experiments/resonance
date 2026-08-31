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
    fun unlinkedManagedDownloadIsRetainedWithoutADeletionDecision() {
        val decision = UnlinkedDownloadMigrationPolicy.decision(
            track(),
            legacyDownloadOwned = true,
        )

        assertFalse(decision.shouldDelete)
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

    @Test
    fun legacyLibraryRetainsTracksAndEveryCollectionReference() {
        val managedID = "managed-track"
        val importedID = "imported-track"
        val managed = Track(
            id = managedID,
            title = "Downloaded from the server",
            relativePath = RepositoryFilePolicy.newDownloadFilename(
                preferredFilename = "downloaded.m4a",
                randomID = "11111111-1111-4111-8111-111111111111",
            ),
            remoteID = "remote-song",
            sourceServer = "https://music.example",
        )
        val imported = Track(
            id = importedID,
            title = "Local import",
            relativePath = "Local import.m4a",
        )
        val playlist = Playlist(
            id = "playlist",
            name = "Keep this mix",
            trackIDs = listOf(managedID, importedID),
        )
        val profilePlaylist = Playlist(
            id = "profile-playlist",
            name = "Profile mix",
            trackIDs = listOf(managedID),
        )
        val profileState = ProfileLibraryState(
            playlists = listOf(profilePlaylist),
            favorites = setOf(managedID),
        )
        val legacy = StoredLibrary(
            tracks = listOf(managed, imported),
            playlists = listOf(playlist),
            favorites = setOf(managedID, importedID),
            listeningHistory = listOf(
                ListeningHistoryEntry(
                    id = "history-entry",
                    trackID = managedID,
                    listenedSeconds = 42.0,
                    durationSeconds = 180.0,
                    remoteSongID = "remote-song",
                ),
            ),
            profileStates = mapOf("https://music.example:443#profile=default" to profileState),
        )

        val migrated = UnlinkedDownloadMigrationPolicy.migrate(legacy) { track ->
            RepositoryFilePolicy.downloadID(track.relativePath) != null
        }

        assertEquals(legacy.tracks.map(Track::id), migrated.tracks.map(Track::id))
        assertEquals(legacy.playlists, migrated.playlists)
        assertEquals(legacy.favorites, migrated.favorites)
        assertEquals(legacy.listeningHistory, migrated.listeningHistory)
        assertEquals(legacy.profileStates, migrated.profileStates)
        assertEquals(false, migrated.tracks.first().preservesUnlinkedImport)
        assertEquals(true, migrated.tracks.last().preservesUnlinkedImport)
        assertTrue(UnlinkedDownloadMigrationPolicy.Identifier in migrated.completedMigrations)
    }

    @Test
    fun partialLegacyMigrationWithExplicitServerFlagIsStillPreserved() {
        val managed = track(preservesUnlinkedImport = false)
        val legacy = StoredLibrary(tracks = listOf(managed))

        val migrated = UnlinkedDownloadMigrationPolicy.migrate(legacy) { true }

        assertEquals(listOf(managed), migrated.tracks)
        assertTrue(UnlinkedDownloadMigrationPolicy.Identifier in migrated.completedMigrations)
    }

    @Test
    fun historicalCompletionMarkerMakesMigrationANoopForRollbackSafety() {
        val legacy = StoredLibrary(
            tracks = listOf(track()),
            completedMigrations = setOf(UnlinkedDownloadMigrationPolicy.Identifier),
        )

        val migrated = UnlinkedDownloadMigrationPolicy.migrate(legacy) {
            error("completed migration must not inspect or mutate tracks")
        }

        assertEquals(legacy, migrated)
    }
}
