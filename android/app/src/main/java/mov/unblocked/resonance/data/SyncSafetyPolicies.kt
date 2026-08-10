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

sealed interface PlaylistPresentationEntry {
    val stableID: String

    data class Downloaded(
        val track: Track,
        override val stableID: String,
    ) : PlaylistPresentationEntry

    data class Unavailable(
        val remoteSongID: String,
        val remoteSong: RemoteSong?,
        override val stableID: String = "remote:$remoteSongID",
    ) : PlaylistPresentationEntry
}

object PlaylistPresentationPolicy {
    private sealed interface EntryKey {
        data class Local(val trackID: String) : EntryKey
        data class Remote(val remoteSongID: String) : EntryKey
    }

    fun entries(
        playlist: Playlist,
        tracks: List<Track>,
        remoteSongs: List<RemoteSong>,
    ): List<PlaylistPresentationEntry> {
        val tracksByID = tracks.associateBy(Track::id)
        val playlistTracks = playlist.trackIDs.mapNotNull(tracksByID::get)
        val remoteSongIDs = playlist.remoteSongIDs
        if (playlist.isSystem || remoteSongIDs == null) {
            return playlistTracks.map { track ->
                PlaylistPresentationEntry.Downloaded(track, "local:${track.id}")
            }
        }

        val orderedRemoteIDs = remoteSongIDs.distinct()
        val remoteIDSet = orderedRemoteIDs.toSet()
        val downloadedByRemoteID = mutableMapOf<String, Track>()
        val previousKeys = playlistTracks.map { track ->
            val remoteID = track.remoteID
            if (remoteID != null && remoteID in remoteIDSet) {
                downloadedByRemoteID.putIfAbsent(remoteID, track)
                EntryKey.Remote(remoteID)
            } else {
                EntryKey.Local(track.id)
            }
        }
        val orderedKeys = orderedRemoteIDs.map(EntryKey::Remote)
        val preservedKeys = previousKeys.filterIsInstance<EntryKey.Local>()
        val remoteSongsByID = remoteSongs.associateBy(RemoteSong::id)

        return PlaylistOrderPolicy.merge(previousKeys, orderedKeys, preservedKeys).mapNotNull { key ->
            when (key) {
                is EntryKey.Local -> tracksByID[key.trackID]?.let { track ->
                    PlaylistPresentationEntry.Downloaded(track, "local:${track.id}")
                }
                is EntryKey.Remote -> downloadedByRemoteID[key.remoteSongID]?.let { track ->
                    PlaylistPresentationEntry.Downloaded(track, "remote:${key.remoteSongID}")
                } ?: PlaylistPresentationEntry.Unavailable(
                    remoteSongID = key.remoteSongID,
                    remoteSong = remoteSongsByID[key.remoteSongID],
                )
            }
        }
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
