package mov.unblocked.resonance.data

/**
 * Loads one outcome for each distinct playlist key while retaining the order of
 * the first occurrence. A failed Result is still an outcome, so a repeated row
 * cannot start the same transfer again.
 */
internal data class PlaylistDownloadOutcome<K, V>(
    val key: K,
    val result: Result<V>,
)

internal object PlaylistDownloadOutcomePolicy {
    suspend fun <T, K, V> loadDistinct(
        selected: List<T>,
        key: (T) -> K,
        onOutcome: (PlaylistDownloadOutcome<K, V>) -> Unit = {},
        loader: suspend (T) -> Result<V>,
    ): List<PlaylistDownloadOutcome<K, V>> {
        val outcomes = LinkedHashMap<K, Result<V>>()
        selected.forEach { candidate ->
            val candidateKey = key(candidate)
            if (!outcomes.containsKey(candidateKey)) {
                val outcome = PlaylistDownloadOutcome(candidateKey, loader(candidate))
                outcomes[candidateKey] = outcome.result
                onOutcome(outcome)
            }
        }
        return outcomes.map { (candidateKey, result) ->
            PlaylistDownloadOutcome(candidateKey, result)
        }
    }
}
