package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadPolicyTest {
    @Test
    fun emptySelectionDownloadsEveryUnsyncedSong() {
        assertEquals(
            setOf("song-2", "song-3"),
            DownloadPolicy.songIdsToDownload(
                remoteSongIds = listOf("song-1", "song-2", "song-3"),
                downloadedSongIds = setOf("song-1"),
                selectedSongIds = emptySet(),
            ),
        )
    }

    @Test
    fun selectionDownloadsOnlyUnsyncedSelectedSongs() {
        assertEquals(
            setOf("song-3"),
            DownloadPolicy.songIdsToDownload(
                remoteSongIds = listOf("song-1", "song-2", "song-3"),
                downloadedSongIds = setOf("song-1"),
                selectedSongIds = setOf("song-1", "song-3"),
            ),
        )
    }
}
