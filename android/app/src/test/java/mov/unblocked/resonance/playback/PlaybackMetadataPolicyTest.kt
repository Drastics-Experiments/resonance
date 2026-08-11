package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackMetadataPolicyTest {
    @Test fun completeMetadataIsPreservedForSystemPublication() {
        assertEquals(
            PublishedPlaybackMetadata("Song", "Artist", "Album", 123_000L),
            PlaybackMetadataPolicy.published(" Song ", " Artist ", " Album ", 123_000L),
        )
    }

    @Test fun blanksAndUnknownDurationHaveUsefulSystemFallbacks() {
        val metadata = PlaybackMetadataPolicy.published(" ", "", "  ", 0L)

        assertEquals("Unknown Title", metadata.title)
        assertEquals("Unknown Artist", metadata.artist)
        assertNull(metadata.album)
        assertNull(metadata.durationMs)
    }
}
