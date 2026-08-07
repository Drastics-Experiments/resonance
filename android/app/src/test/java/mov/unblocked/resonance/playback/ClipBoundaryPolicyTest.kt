package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipBoundaryPolicyTest {
    @Test
    fun unknownOneMillisecondDurationDoesNotBecomeAClipBoundary() {
        assertNull(ClipBoundaryPolicy.exactEndMs(startMs = 0L, endMs = 1L))
    }

    @Test
    fun validClipUsesItsExactSourceTimeEnd() {
        assertEquals(75_000L, ClipBoundaryPolicy.exactEndMs(startMs = 15_000L, endMs = 75_000L))
    }

    @Test
    fun invalidAndEditorRejectedRangesAreNotClipped() {
        assertNull(ClipBoundaryPolicy.exactEndMs(startMs = 8_000L, endMs = 7_000L))
        assertNull(ClipBoundaryPolicy.exactEndMs(startMs = 8_000L, endMs = 8_249L))
    }
}
