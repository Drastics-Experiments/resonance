package mov.unblocked.resonance.data

internal object RemoteArtworkPersistencePolicy {
    fun shouldBackfill(
        artworkScanComplete: Boolean?,
        existingArtworkBytes: Long?,
        artworkURL: String?,
    ): Boolean = !artworkURL.isNullOrBlank() &&
        (artworkScanComplete != true || existingArtworkBytes == null || existingArtworkBytes <= 0L)
}
