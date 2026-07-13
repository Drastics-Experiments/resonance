package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.RemoteSong
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
}
