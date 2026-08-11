package mov.unblocked.resonance.data

import java.util.concurrent.atomic.AtomicLong

/**
 * Issues monotonic operation generations and gives UI callbacks a lock-free ownership check.
 * Releasing or cancelling an older generation can never clear a newer operation.
 */
class TransferSessionOwnership {
    private val sequence = AtomicLong(0L)
    private val activeGeneration = AtomicLong(0L)

    fun begin(): Long = sequence.incrementAndGet().also(activeGeneration::set)

    fun owns(generation: Long): Boolean =
        generation > 0L && activeGeneration.get() == generation

    fun hasActiveSession(): Boolean = activeGeneration.get() > 0L

    fun release(generation: Long): Boolean =
        generation > 0L && activeGeneration.compareAndSet(generation, 0L)

    fun cancel(): Long? = activeGeneration.getAndSet(0L).takeIf { it > 0L }
}
