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

        val legacyKeys = PlaylistOrderPolicy.merge(previousKeys, orderedKeys, preservedKeys)
        val keysByStableID = legacyKeys.associateBy(::stableID)
        val storedOrder = playlist.entryOrder.orEmpty().distinct().mapNotNull(keysByStableID::get)
        val storedIDs = storedOrder.mapTo(mutableSetOf(), ::stableID)
        val presentedKeys = storedOrder + legacyKeys.filter { stableID(it) !in storedIDs }

        return presentedKeys.mapNotNull { key ->
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

    private fun stableID(key: EntryKey): String = when (key) {
        is EntryKey.Local -> "local:${key.trackID}"
        is EntryKey.Remote -> "remote:${key.remoteSongID}"
    }
}

object PlaylistEntryOrderPolicy {
    fun move(
        playlist: Playlist,
        tracks: List<Track>,
        remoteSongs: List<RemoteSong>,
        fromIndex: Int,
        toIndex: Int,
    ): Playlist {
        val entries = PlaylistPresentationPolicy.entries(playlist, tracks, remoteSongs)
        if (fromIndex !in entries.indices || toIndex !in entries.indices || fromIndex == toIndex) {
            return playlist
        }
        val moved = entries.toMutableList().apply { add(toIndex, removeAt(fromIndex)) }
        val movedTrackIDs = moved.mapNotNull { entry ->
            (entry as? PlaylistPresentationEntry.Downloaded)?.track?.id
        }
        val remoteSongIDs = playlist.remoteSongIDs ?: return playlist.copy(trackIDs = movedTrackIDs)
        val remoteIDSet = remoteSongIDs.toSet()
        val movedRemoteIDs = moved.mapNotNull { entry ->
            when (entry) {
                is PlaylistPresentationEntry.Unavailable -> entry.remoteSongID
                is PlaylistPresentationEntry.Downloaded -> entry.track.remoteID?.takeIf(remoteIDSet::contains)
            }
        }.distinct()
        return playlist.copy(
            trackIDs = movedTrackIDs,
            remoteSongIDs = movedRemoteIDs,
            entryOrder = moved.map(PlaylistPresentationEntry::stableID),
        )
    }

    fun normalizedOrder(
        playlist: Playlist,
        tracks: List<Track>,
    ): List<String> = PlaylistPresentationPolicy.entries(playlist, tracks, emptyList())
        .map(PlaylistPresentationEntry::stableID)

    fun mergingRemoteOrder(
        previous: Playlist?,
        remoteSongIDs: List<String>,
        tracks: List<Track>,
    ): List<String> {
        val remoteTokens = remoteSongIDs.distinct().map { "remote:$it" }
        val remoteIDSet = remoteSongIDs.toSet()
        val tracksByID = tracks.associateBy(Track::id)
        val fallbackTokens = previous?.trackIDs.orEmpty().mapNotNull { trackID ->
            tracksByID[trackID]?.let { track ->
                track.remoteID?.takeIf(remoteIDSet::contains)?.let { "remote:$it" }
                    ?: "local:${track.id}"
            }
        }
        val previousTokens = previous?.entryOrder.orEmpty().ifEmpty { fallbackTokens }
        val localTokens = (previousTokens + fallbackTokens).distinct().filter { token ->
            token.startsWith("local:") && token.removePrefix("local:") in tracksByID
        }
        val merged = PlaylistOrderPolicy.merge(previousTokens, remoteTokens, localTokens)
        return merged + localTokens.filterNot(merged::contains)
    }
}

/** Converts deleted downloads to server-only entries without moving their playlist slots. */
object PlaylistLocalDeletionPolicy {
    fun apply(
        playlist: Playlist,
        tracks: List<Track>,
        deletingTrackIDs: Set<String>,
        activeRemoteSongIDs: Set<String>,
        activeServerURL: String,
        activeProfileID: String,
        catalogIsAuthoritative: Boolean,
    ): Playlist {
        if (deletingTrackIDs.isEmpty()) return playlist
        val deletingTracks = tracks.filter { it.id in deletingTrackIDs }
        if (deletingTracks.isEmpty()) return playlist
        val deletingRemoteIDs = deletingTracks.mapNotNull { track ->
            track.remoteID?.takeIf {
                RemoteTrackIdentityPolicy.matches(track, activeServerURL, activeProfileID, it)
            }
        }.toSet()
        val affected = playlist.trackIDs.any(deletingTrackIDs::contains) ||
            playlist.remoteSongIDs.orEmpty().any(deletingRemoteIDs::contains)
        if (!affected) return playlist
        if (playlist.isSystem) {
            return playlist.copy(trackIDs = playlist.trackIDs.filterNot(deletingTrackIDs::contains))
        }

        // remoteSongIDs is the server's canonical sequence. entryOrder is the independent,
        // device-local presentation sequence and may intentionally arrange those IDs differently.
        var remoteSongIDs = playlist.remoteSongIDs.orEmpty()
        val validTokens = playlist.trackIDs.mapTo(linkedSetOf()) { "local:$it" }.apply {
            addAll(remoteSongIDs.map { "remote:$it" })
        }
        val normalizedOrder = PlaylistEntryOrderPolicy.normalizedOrder(playlist, tracks)
        val storedOrder = playlist.entryOrder.orEmpty().distinct().filter(validTokens::contains)
        var order = if (storedOrder.isEmpty()) {
            normalizedOrder
        } else {
            storedOrder + normalizedOrder.filterNot(storedOrder::contains)
        }
        deletingTracks.forEach { track ->
            val localToken = "local:${track.id}"
            val remoteID = track.remoteID
            val remoteToken = remoteID?.let { "remote:$it" }
            val activeRemoteID = remoteID?.takeIf {
                RemoteTrackIdentityPolicy.matches(track, activeServerURL, activeProfileID, it)
            }
            val hasCanonicalRemoteMembership = activeRemoteID?.let(remoteSongIDs::contains) == true
            val hasAuthoritativeBacking = activeRemoteID != null &&
                catalogIsAuthoritative && activeRemoteID in activeRemoteSongIDs
            if (hasAuthoritativeBacking || (!catalogIsAuthoritative && hasCanonicalRemoteMembership)) {
                order = order.map { token ->
                    if (token == localToken) requireNotNull(remoteToken) else token
                }
                if (
                    hasAuthoritativeBacking &&
                    localToken in validTokens &&
                    activeRemoteID != null &&
                    activeRemoteID !in remoteSongIDs
                ) {
                    // Legacy local-only membership has no server position to recover. Append it
                    // without disturbing the canonical order already received from the server.
                    remoteSongIDs = remoteSongIDs + activeRemoteID
                }
            } else if (activeRemoteID != null && catalogIsAuthoritative) {
                order = order.filterNot { it == localToken || it == remoteToken }
                remoteSongIDs = remoteSongIDs.filterNot { it == activeRemoteID }
            } else {
                // Truly local entries and tracks owned by another server/profile only lose their
                // local slot. A same-ID remote membership belongs to the active context and stays.
                order = order.filterNot { it == localToken }
            }
        }
        order = order.filterNot { token ->
            token.startsWith("local:") && token.removePrefix("local:") in deletingTrackIDs
        }.distinct()

        val hadRemoteMembership = playlist.remoteSongIDs != null
        return playlist.copy(
            trackIDs = playlist.trackIDs.filterNot(deletingTrackIDs::contains),
            remoteSongIDs = remoteSongIDs.takeIf { hadRemoteMembership || it.isNotEmpty() },
            entryOrder = order,
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

object CatalogAuthorityPolicy {
    fun isFresh(
        authoritativeSnapshot: CatalogRequestSnapshot?,
        currentContext: ServerProfileContext?,
        currentRequestGeneration: Long,
        currentUploadMutationGeneration: Long,
    ): Boolean = authoritativeSnapshot?.let { snapshot ->
        CatalogResponsePolicy.shouldApply(
            snapshot,
            currentContext,
            currentRequestGeneration,
            currentUploadMutationGeneration,
        )
    } == true
}
