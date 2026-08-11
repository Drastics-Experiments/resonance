package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSongMetadataRetryPolicyTest {
    @Test
    fun retriesUseABoundedBackoffWindow() {
        assertTrue(RemoteSongMetadataRetryPolicy.shouldRetryAfterFailure(1))
        assertTrue(RemoteSongMetadataRetryPolicy.shouldRetryAfterFailure(3))
        assertFalse(RemoteSongMetadataRetryPolicy.shouldRetryAfterFailure(4))
        assertEquals(1_000L, RemoteSongMetadataRetryPolicy.delayAfterFailureMs(1))
        assertEquals(3_000L, RemoteSongMetadataRetryPolicy.delayAfterFailureMs(2))
        assertEquals(10_000L, RemoteSongMetadataRetryPolicy.delayAfterFailureMs(3))
    }
}
