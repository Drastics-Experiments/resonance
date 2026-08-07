package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.SyncProfile
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.ServerUploadMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ResonanceUiStateTest {
    @Test
    fun notConnectedMessageIsNotMistakenForAConnection() {
        assertFalse(ResonanceUiState(serverMessage = "Not connected").isConnected)
        assertFalse(ResonanceUiState(serverMessage = "Connection failed").isConnected)
    }

    @Test
    fun successfulCatalogRefreshMarksTheServerConnected() {
        assertTrue(ResonanceUiState(serverMessage = "Connected • 0 songs").isConnected)
        assertTrue(
            ResonanceUiState(
                remoteSongs = listOf(
                    RemoteSong(
                        id = "song-1",
                        filename = "Example.mp3",
                        title = "Example",
                        artist = "Artist",
                        album = "Album",
                        size = 1L,
                        modifiedAt = "",
                        contentType = "audio/mpeg",
                        downloadURL = "/api/v1/songs/song-1/download",
                        streamURL = "/api/v1/songs/song-1/stream",
                    ),
                ),
            ).isConnected,
        )
    }

    @Test
    fun recentlyAddedTracksAreNewestFirstAndCapped() {
        val tracks = (1..8).map { index ->
            Track(
                id = "track-$index",
                title = "Track $index",
                relativePath = "track-$index.mp3",
                dateAddedEpochMs = index.toLong(),
            )
        }

        assertEquals(
            listOf("track-8", "track-7", "track-6", "track-5", "track-4", "track-3"),
            recentlyAddedTracks(tracks).map(Track::id),
        )
    }

    @Test
    fun profilePresentationUsesTheActiveSyncProfile() {
        val state = ResonanceUiState(
            syncProfileId = "lily",
            syncProfiles = listOf(
                SyncProfile(id = "default", name = "Default", isDefault = true),
                SyncProfile(id = "lily", name = "Lily"),
            ),
        )

        assertEquals("Lily", activeSyncProfileName(state))
        assertEquals("L", syncProfileInitial(activeSyncProfileName(state)))
    }

    @Test
    fun resolvesRelativeServerArtworkLikeTheIosCatalog() {
        assertEquals(
            "https://music.unblocked.mov/api/v1/songs/song-1/artwork",
            resolveRemoteArtworkURL(
                "https://music.unblocked.mov",
                "/api/v1/songs/song-1/artwork",
            ),
        )
    }

    @Test
    fun transferPopupOnlyAppearsForDownloadsAndUploads() {
        assertFalse(shouldShowTransferPopup(ResonanceUiState(isRefreshingServer = true, isSyncingPlaylists = true)))
        assertTrue(shouldShowTransferPopup(ResonanceUiState(isDownloading = true)))
        assertTrue(shouldShowTransferPopup(ResonanceUiState(isUploading = true)))
    }

    @Test
    fun catalogAndPlaylistSyncDoNotBlockConfiguredUploads() {
        val configured = ResonanceUiState(
            serverUrl = "https://music.example",
            serverAdminKey = "admin-key",
            isRefreshingServer = true,
            isSyncingPlaylists = true,
        )

        assertTrue(canStartServerUpload(configured))
    }

    @Test
    fun activeTransfersConnectionChangesAndMissingCredentialsBlockUploads() {
        val configured = ResonanceUiState(
            serverUrl = "https://music.example",
            serverToken = "access-token",
            serverAdminKey = "admin-key",
        )

        assertFalse(canStartServerUpload(configured.copy(isDownloading = true)))
        assertFalse(canStartServerUpload(configured.copy(isUploading = true)))
        assertFalse(canStartServerUpload(configured.copy(isApplyingServerConnection = true)))
        assertFalse(canStartServerUpload(configured.copy(serverUrl = "")))
        assertTrue(configured.copy(serverToken = "").hasServerUploadCredentials)
        assertTrue(canStartServerUpload(configured.copy(serverToken = "")))
        assertFalse(canStartServerUpload(configured.copy(serverAdminKey = "")))
        assertFalse(canStartServerUpload(configured.copy(serverUploadMode = null)))
        assertFalse(canStartServerUpload(configured.copy(serverUploadMode = ServerUploadMode.ServerSourceLink)))
    }

    @Test
    fun clipProgressIsRelativeToTheSavedPlaybackRange() {
        val track = Track(
            id = "track-1",
            title = "Track",
            relativePath = "track.m4a",
            durationMs = 120_000,
        )
        val state = ResonanceUiState(
            tracks = listOf(track),
            currentTrackId = track.id,
            positionMs = 45_000,
            clipRangesByTrackId = mapOf(track.id to ClipRange(15_000, 75_000)),
        )

        assertEquals(15_000L, state.playbackStartMs)
        assertEquals(60_000L, state.playbackDurationMs)
        assertEquals(30_000L, state.playbackElapsedMs)
    }

    @Test
    fun transientStreamIdentityDoesNotDependOnTheStoredLibrary() {
        val stream = Track(
            id = "remote-stream:song-1:session",
            title = "Stream",
            relativePath = "",
        )
        val state = ResonanceUiState(
            currentTrackId = stream.id,
            transientCurrentTrack = stream,
            transientArtworkURL = "/api/v1/songs/song-1/artwork",
        )

        assertTrue(state.isTransientPlayback)
        assertEquals(stream, state.currentTrack)
        assertEquals("/api/v1/songs/song-1/artwork", state.transientArtworkURL)
        assertFalse(state.copy(currentTrackId = null).isTransientPlayback)
    }
}
