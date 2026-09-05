package mov.unblocked.resonance.data

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Serializes durable writes and captures the value only after the previous write finishes.
 *
 * The last successfully written value is retained so callers that arrive during a write can
 * avoid writing an identical snapshot again. A regular mutex keeps cancellation and writer
 * failures local to the caller while still coalescing bursts of state-only changes.
 */
internal class LatestValuePersistenceGate<Value> {
    private val mutex = Mutex()
    private var hasWrittenValue = false
    private var lastWrittenValue: Value? = null

    suspend fun persist(
        latestValue: () -> Value,
        write: suspend (Value) -> Unit,
    ): Value = mutex.withLock {
        val value = latestValue()
        if (hasWrittenValue && value == lastWrittenValue) return@withLock value
        write(value)
        lastWrittenValue = value
        hasWrittenValue = true
        value
    }
}
