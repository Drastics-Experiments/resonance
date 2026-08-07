package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackPresentationTest {
    @Test
    fun unknownTrackDurationStaysUnknownAndCannotBeProportionallySought() {
        val track = Track(
            id = "stream",
            title = "Unknown stream",
            relativePath = "stream.mp3",
            durationMs = 0L,
        )
        val state = ResonanceUiState(
            tracks = listOf(track),
            currentTrackId = track.id,
            positionMs = 12_000L,
        )

        assertNull(state.playbackEndMs)
        assertNull(state.playbackDurationMs)
        assertNull(state.playbackProgressFraction)
        assertFalse(state.canSeekPlayback)
        assertEquals(12_000L, state.playbackElapsedMs)
        assertEquals("Unknown", track.durationText)
    }

    @Test
    fun knownClipProducesRelativeProgressAndEnablesSeeking() {
        val track = Track(
            id = "track",
            title = "Track",
            relativePath = "track.m4a",
            durationMs = 120_000L,
        )
        val state = ResonanceUiState(
            tracks = listOf(track),
            currentTrackId = track.id,
            positionMs = 45_000L,
            clipRangesByTrackId = mapOf(track.id to ClipRange(15_000L, 75_000L)),
        )

        assertTrue(state.canSeekPlayback)
        assertEquals(60_000L, state.playbackDurationMs)
        assertEquals(30_000L, state.playbackElapsedMs)
        assertEquals(.5f, requireNotNull(state.playbackProgressFraction), 0f)
    }

    @Test
    fun media3DurationMakesAnInitiallyUnknownStreamSeekable() {
        val track = Track(
            id = "stream",
            title = "Stream",
            relativePath = "stream.mp3",
            durationMs = 0L,
        )
        val state = ResonanceUiState(
            tracks = listOf(track),
            currentTrackId = track.id,
            positionMs = 30_000L,
            playerDurationMs = 120_000L,
        )

        assertEquals(120_000L, state.playbackDurationMs)
        assertEquals(.25f, requireNotNull(state.playbackProgressFraction), 0f)
        assertTrue(state.canSeekPlayback)
    }
}
