package mov.unblocked.resonance.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferSessionOwnershipTest {
    @Test fun cancelThenRestartRejectsEveryStaleCallbackAndFinalizer() {
        val ownership = TransferSessionOwnership()
        val cancelled = ownership.begin()

        assertTrue(ownership.owns(cancelled))
        assertTrue(ownership.cancel() == cancelled)
        assertFalse(ownership.owns(cancelled))

        val restarted = ownership.begin()
        assertTrue(ownership.owns(restarted))
        assertFalse(ownership.owns(cancelled))
        assertFalse(ownership.release(cancelled))
        assertTrue(ownership.owns(restarted))
        assertTrue(ownership.release(restarted))
        assertFalse(ownership.owns(restarted))
    }
}
