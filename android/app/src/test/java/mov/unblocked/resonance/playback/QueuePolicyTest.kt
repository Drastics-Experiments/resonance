package mov.unblocked.resonance.playback

import kotlin.random.Random
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class QueuePolicyTest {
    @Test fun sequentialNextAndPreviousWrap() {
        assertEquals(0, QueuePolicy.nextIndex(3, 2, false))
        assertEquals(2, QueuePolicy.previousIndex(3, 0))
    }

    @Test fun shuffleDoesNotReturnCurrentTrackWhenAlternativesExist() {
        repeat(20) {
            assertNotEquals(1, QueuePolicy.nextIndex(4, 1, true, Random(it)))
        }
    }

    @Test fun emptyAndSingleQueuesAreSafe() {
        assertEquals(-1, QueuePolicy.nextIndex(0, 0, false))
        assertEquals(0, QueuePolicy.nextIndex(1, 0, true))
    }
}
