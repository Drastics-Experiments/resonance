package mov.unblocked.resonance.data

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
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

    @Test fun burstOfQueuedWritesSkipsDuplicateSnapshotsAfterTheNewestWrite() = runTest {
        val gate = LatestValuePersistenceGate<String>()
        val firstWriteStarted = CompletableDeferred<Unit>()
        val releaseFirstWrite = CompletableDeferred<Unit>()
        val writes = mutableListOf<String>()
        var latest = "initial"

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
        latest = "newest"
        val second = async {
            gate.persist(latestValue = { latest }, write = { writes += it })
        }
        latest = "newest + artwork"
        val third = async {
            gate.persist(latestValue = { latest }, write = { writes += it })
        }

        releaseFirstWrite.complete(Unit)
        first.await()
        second.await()
        third.await()

        assertEquals(listOf("initial", "newest + artwork"), writes)
    }

    @Test fun canceledWriteReleasesTheGateForTheNextSnapshot() = runTest {
        val gate = LatestValuePersistenceGate<String>()
        val writeStarted = CompletableDeferred<Unit>()
        val releaseWrite = CompletableDeferred<Unit>()
        val writes = mutableListOf<String>()

        val first = launch {
            gate.persist(
                latestValue = { "canceled" },
                write = {
                    writeStarted.complete(Unit)
                    releaseWrite.await()
                },
            )
        }
        writeStarted.await()
        first.cancelAndJoin()

        gate.persist(
            latestValue = { "recovered" },
            write = { writes += it },
        )

        assertEquals(listOf("recovered"), writes)
    }

    @Test fun failedWriteIsNotMarkedAsPersisted() = runTest {
        val gate = LatestValuePersistenceGate<String>()
        var attempts = 0
        var failureObserved = false

        try {
            gate.persist(
                latestValue = { "first" },
                write = {
                    attempts += 1
                    error("disk full")
                },
            )
        } catch (_: IllegalStateException) {
            failureObserved = true
        }

        val writes = mutableListOf<String>()
        gate.persist(latestValue = { "second" }, write = { writes += it })

        assertEquals(true, failureObserved)
        assertEquals(1, attempts)
        assertEquals(listOf("second"), writes)
    }
}
