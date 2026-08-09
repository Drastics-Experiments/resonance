package mov.unblocked.resonance

import androidx.media3.common.Player
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.ui.isVideoClipPath
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidParityTest {
    @Test
    fun playlistArtworkUsesOnlyTheFirstFourCustomPlaylistTracks() {
        val trackIDs = listOf("one", "two", "three", "four", "five")

        assertEquals(trackIDs.take(4), Playlist(name = "Mix", trackIDs = trackIDs).automaticArtworkTrackIDs)
        assertTrue(Playlist(name = "Liked Songs", trackIDs = trackIDs, isSystem = true).automaticArtworkTrackIDs.isEmpty())
    }

    @Test
    fun profileNamesMatchIosWhitespaceNormalization() {
        assertEquals("Living Room", normalizeProfileName("  Living\n\tRoom  "))
    }

    @Test
    fun repeatOffWrapsAtTheEndOfTheQueue() {
        assertEquals(Player.REPEAT_MODE_ALL, repeatModeFor(false))
        assertEquals(Player.REPEAT_MODE_ONE, repeatModeFor(true))
    }

    @Test
    fun clipEditorShowsInlinePreviewsOnlyForVideoFiles() {
        assertTrue(isVideoClipPath("downloads/preview.MP4"))
        assertTrue(isVideoClipPath("imports/movie.webm"))
        assertFalse(isVideoClipPath("library/song.m4a"))
    }
}
