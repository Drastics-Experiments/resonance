package mov.unblocked.resonance.playback

import kotlin.math.min

object CrossfadePolicy {
    const val DefaultSeconds = 5f
    const val MinimumSeconds = 1f
    const val MaximumSeconds = 12f

    fun normalizedSeconds(value: Float): Float =
        if (value.isFinite()) value.coerceIn(MinimumSeconds, MaximumSeconds) else DefaultSeconds

    fun effectiveDurationMs(
        requestedSeconds: Float,
        currentDurationMs: Long,
        nextDurationMs: Long,
    ): Long {
        if (currentDurationMs <= 0L || nextDurationMs <= 0L) return 0L
        val requestedMs = (normalizedSeconds(requestedSeconds) * 1_000L).toLong()
        return min(requestedMs, min(currentDurationMs / 2L, nextDurationMs / 2L))
            .coerceAtLeast(0L)
    }

    fun progress(remainingMs: Long, durationMs: Long): Float {
        if (durationMs <= 0L) return 0f
        return (1f - remainingMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
    }
}
