package mov.unblocked.resonance

import androidx.media3.common.Player
import org.junit.Assert.assertEquals
import org.junit.Test

class AndroidParityTest {
    @Test
    fun profileNamesMatchIosWhitespaceNormalization() {
        assertEquals("Living Room", normalizeProfileName("  Living\n\tRoom  "))
    }

    @Test
    fun repeatOffStopsAtTheEndOfTheQueue() {
        assertEquals(Player.REPEAT_MODE_OFF, repeatModeFor(false))
        assertEquals(Player.REPEAT_MODE_ONE, repeatModeFor(true))
    }
}
