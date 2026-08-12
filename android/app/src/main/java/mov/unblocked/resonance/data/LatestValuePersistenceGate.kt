package mov.unblocked.resonance.data

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Serializes durable writes and captures the value only after the previous write finishes.
 * A later caller therefore cannot write an older pre-mutation snapshot over newer state.
 */
internal class LatestValuePersistenceGate<Value> {
    private val mutex = Mutex()

    suspend fun persist(
        latestValue: () -> Value,
        write: suspend (Value) -> Unit,
    ): Value = mutex.withLock {
        val value = latestValue()
        write(value)
        value
    }
}
