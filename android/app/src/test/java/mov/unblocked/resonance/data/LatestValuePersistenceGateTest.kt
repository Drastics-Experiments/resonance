package mov.unblocked.resonance.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class LatestValuePersistenceGateTest {
    @Test fun queuedWriteCapturesLatestStateAfterOlderWriteFinishes() = runTest {
        val gate = LatestValuePersistenceGate<String>()
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val writes = mutableListOf<String>()
        var latest = "catalog metadata"

        val first = async {
            gate.persist(
                latestValue = { latest },
                write = { value ->
                    firstWriteStarted.complete(Unit)
                    releaseFirstWrite.await()
                    writes += value
                },
            )
        }
        firstWriteStarted.await()
        latest = "catalog metadata + downloaded track"
        val second = async {
            gate.persist(
                latestValue = { latest },
                write = { value -> writes += value },
            )
        }

        yield()
        assertFalse(second.isCompleted)
        releaseFirstWrite.complete(Unit)
        first.await()
        second.await()

        assertEquals(
            listOf("catalog metadata", "catalog metadata + downloaded track"),
            writes,
        )
        assertEquals("catalog metadata + downloaded track", writes.last())
    }
}
