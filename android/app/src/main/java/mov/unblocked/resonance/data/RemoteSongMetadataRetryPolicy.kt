package mov.unblocked.resonance.data

/** Bounded foreground retry window; a later catalog or foreground pass starts a fresh window. */
object RemoteSongMetadataRetryPolicy {
    const val MaximumAttempts = 4
    private val retryDelaysMs = longArrayOf(1_000L, 3_000L, 10_000L)

    fun shouldRetryAfterFailure(failedAttemptCount: Int): Boolean =
        failedAttemptCount in 1 until MaximumAttempts

    fun delayAfterFailureMs(failedAttemptCount: Int): Long =
        retryDelaysMs[(failedAttemptCount - 1).coerceIn(retryDelaysMs.indices)]
}
