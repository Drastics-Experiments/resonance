package mov.unblocked.resonance.playback

import androidx.media3.common.PlaybackException
import mov.unblocked.resonance.ui.PlaybackUiStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackFailurePolicyTest {
    @Test
    fun networkFailureKeepsItsDetailAndCanBeRetried() {
        val status = PlaybackFailurePolicy.status(
            PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
            "The audio server timed out",
        )

        assertEquals("The audio server timed out", status.message)
        assertTrue(status.retryable)
    }

    @Test
    fun unsupportedAudioIsTerminal() {
        val status = PlaybackFailurePolicy.status(
            PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED,
            "Unsupported codec",
        )

        assertFalse(status.retryable)
    }

    @Test
    fun blankPlatformMessageGetsAReadableFallback() {
        assertEquals(
            PlaybackUiStatus.Failed("This audio could not be played.", retryable = false),
            PlaybackFailurePolicy.status(PlaybackException.ERROR_CODE_IO_FILE_NOT_FOUND, "  "),
        )
    }
}
