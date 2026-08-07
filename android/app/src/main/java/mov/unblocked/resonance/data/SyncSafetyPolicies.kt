package mov.unblocked.resonance.data

data class PlaylistMutationSnapshot(
    val generation: Long,
    val dirtyPlaylistIDs: Set<String>,
    val deletedPlaylistIDs: Set<String>,
)

data class PlaylistMutationReconciliation(
    val dirtyPlaylistIDs: Set<String>,
    val deletedPlaylistIDs: Set<String>,
    val applyRemoteDocument: Boolean,
    val needsRerun: Boolean,
)

object PlaylistSyncMutationPolicy {
    fun reconcile(
        submitted: PlaylistMutationSnapshot,
        currentGeneration: Long,
        currentDirtyPlaylistIDs: Set<String>,
        currentDeletedPlaylistIDs: Set<String>,
    ): PlaylistMutationReconciliation {
        if (currentGeneration != submitted.generation) {
            return PlaylistMutationReconciliation(
                dirtyPlaylistIDs = currentDirtyPlaylistIDs,
                deletedPlaylistIDs = currentDeletedPlaylistIDs,
                applyRemoteDocument = false,
                needsRerun = true,
            )
        }
        return PlaylistMutationReconciliation(
            dirtyPlaylistIDs = currentDirtyPlaylistIDs - submitted.dirtyPlaylistIDs,
            deletedPlaylistIDs = currentDeletedPlaylistIDs - submitted.deletedPlaylistIDs,
            applyRemoteDocument = true,
            needsRerun = false,
        )
    }
}

data class ServerProfileContext(
    val serverURL: String,
    val profileID: String,
    val connectionGeneration: Long,
)

data class CatalogRequestSnapshot(
    val context: ServerProfileContext,
    val requestGeneration: Long,
    val uploadMutationGeneration: Long,
)

object CatalogResponsePolicy {
    fun shouldApply(
        submitted: CatalogRequestSnapshot,
        currentContext: ServerProfileContext?,
        currentRequestGeneration: Long,
        currentUploadMutationGeneration: Long,
    ): Boolean =
        submitted.context == currentContext &&
            submitted.requestGeneration == currentRequestGeneration &&
            submitted.uploadMutationGeneration == currentUploadMutationGeneration
}
