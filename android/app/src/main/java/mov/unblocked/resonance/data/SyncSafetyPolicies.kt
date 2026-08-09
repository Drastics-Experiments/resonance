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

object PlaylistOrderPolicy {
    fun <T> merge(
        previous: List<T>,
        ordered: List<T>,
        preserving: List<T>,
    ): List<T> {
        val previous = previous.distinct()
        val ordered = ordered.distinct()
        val orderedSet = ordered.toSet()
        val preservedSet = preserving.distinct().filterTo(mutableSetOf()) {
            it in previous && it !in orderedSet
        }
        val merged = mutableListOf<T>()
        var orderedIndex = 0

        previous.forEach { previousItem ->
            if (previousItem in preservedSet) {
                merged += previousItem
            } else if (orderedIndex < ordered.size) {
                merged += ordered[orderedIndex]
                orderedIndex += 1
            }
        }
        merged += ordered.drop(orderedIndex)
        return merged.distinct()
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
