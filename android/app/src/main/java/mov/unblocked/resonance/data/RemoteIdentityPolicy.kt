package mov.unblocked.resonance.data

import java.net.URI

data class RemoteTrackIdentity(
    val serverOrigin: String,
    val profileID: String,
    val songID: String,
) {
    val key: String get() = "$serverOrigin#profile=${encode(profileID)}#song=${encode(songID)}"

    private fun encode(value: String): String = value
        .replace("%", "%25")
        .replace("#", "%23")
        .replace("|", "%7C")
}

data class RemoteTrackDeduplication(
    val tracks: List<Track>,
    val replacementTrackIDs: Map<String, String>,
)

class RemoteTrackAssociationConflictException(message: String) : IllegalStateException(message)

/** One identity policy shared by persistence, visibility, queues, and sync. */
object RemoteTrackIdentityPolicy {
    fun normalizedOrigin(value: String): String? = runCatching {
        val uri = URI(value.trim())
        val scheme = uri.scheme?.lowercase()
        require(scheme == "https" || scheme == "http")
        require(uri.rawUserInfo == null)
        require(uri.port in -1..65_535)
        var host = uri.host?.lowercase()?.takeIf(String::isNotBlank) ?: error("missing host")
        val port = if (uri.port >= 0) uri.port else if (scheme == "https") 443 else 80
        if (scheme == "https" && port == 443 && host == "music.unblocked.mov") {
            host = "resonance-core.blithe-haven-9710.chatgpt.site"
        }
        val formattedHost = if (':' in host && !host.startsWith("[")) "[$host]" else host
        "$scheme://$formattedHost:$port"
    }.getOrNull()

    fun contextKey(serverURL: String, profileID: String): String? =
        normalizedOrigin(serverURL)?.let { "$it#profile=${encode(profileID)}" }

    fun canonicalContextKey(value: String): String {
        val marker = "#profile="
        val boundary = value.indexOf(marker)
        if (boundary < 0) return normalizedOrigin(value) ?: value
        val origin = normalizedOrigin(value.substring(0, boundary)) ?: return value
        return origin + value.substring(boundary)
    }

    fun identity(track: Track): RemoteTrackIdentity? {
        val songID = track.remoteID?.takeIf(String::isNotBlank) ?: return null
        val origin = track.sourceServer?.let(::normalizedOrigin) ?: return null
        return RemoteTrackIdentity(origin, track.syncProfileID ?: "default", songID)
    }

    fun matches(track: Track, serverURL: String, profileID: String, songID: String? = null): Boolean {
        val identity = identity(track) ?: return false
        val activeOrigin = normalizedOrigin(serverURL) ?: return false
        return identity.serverOrigin == activeOrigin &&
            identity.profileID == profileID &&
            (songID == null || identity.songID == songID)
    }

    fun belongsToContext(track: Track, serverURL: String, profileID: String): Boolean {
        val sourceOrigin = track.sourceServer?.let(::normalizedOrigin) ?: return false
        val activeOrigin = normalizedOrigin(serverURL) ?: return false
        return sourceOrigin == activeOrigin && (track.syncProfileID ?: "default") == profileID
    }

    fun visibleInContext(track: Track, serverURL: String, profileID: String): Boolean =
        (track.remoteID == null && track.sourceServer == null) || belongsToContext(track, serverURL, profileID)

    /**
     * A Track currently has one persisted server/profile association. Until the
     * model can store multiple associations, never replace one context's tuple
     * while adopting an upload in another context.
     */
    fun requireCanAssociate(track: Track, serverURL: String, profileID: String) {
        val hasAssociation = !track.remoteID.isNullOrBlank() || !track.sourceServer.isNullOrBlank()
        if (!hasAssociation || belongsToContext(track, serverURL, profileID)) return

        val existingServer = track.sourceServer?.takeIf(String::isNotBlank) ?: "an unknown server"
        val existingProfile = track.syncProfileID?.takeIf(String::isNotBlank) ?: "default"
        val targetServer = serverURL.trim().takeIf(String::isNotBlank) ?: "the active server"
        val targetProfile = profileID.takeIf(String::isNotBlank) ?: "default"
        throw RemoteTrackAssociationConflictException(
            "This audio is already linked to profile \"$existingProfile\" on $existingServer. " +
                "Resonance kept that link unchanged. Import a separate local copy before uploading it " +
                "to profile \"$targetProfile\" on $targetServer.",
        )
    }

    fun withAssociation(track: Track, songID: String, serverURL: String, profileID: String): Track {
        require(songID.isNotBlank()) { "The server returned an empty song ID" }
        requireCanAssociate(track, serverURL, profileID)
        return track.copy(
            remoteID = songID,
            sourceServer = serverURL,
            syncProfileID = profileID,
        )
    }

    fun deduplication(tracks: List<Track>): RemoteTrackDeduplication {
        val retainedByIdentity = LinkedHashMap<String, Track>()
        val retained = ArrayList<Track>(tracks.size)
        val replacements = LinkedHashMap<String, String>()
        tracks.forEach { track ->
            val key = identity(track)?.key ?: "local:${track.id}"
            val existing = retainedByIdentity[key]
            if (existing == null) {
                retainedByIdentity[key] = track
                retained += track
            } else if (existing.id != track.id) {
                replacements[track.id] = existing.id
            }
        }
        return RemoteTrackDeduplication(retained, replacements)
    }

    fun deduplicate(tracks: List<Track>): List<Track> = deduplication(tracks).tracks

    /**
     * Applies duplicate-ID replacements to every persisted profile before a
     * redundant same-context remote record is removed.
     */
    fun reconcileLibraryTracks(
        library: StoredLibrary,
        candidateTracks: List<Track> = library.tracks,
    ): StoredLibrary {
        val result = deduplication(candidateTracks)
        if (result.replacementTrackIDs.isEmpty() && result.tracks == library.tracks) return library

        fun mapped(trackID: String): String = result.replacementTrackIDs[trackID] ?: trackID
        fun remapPlaylists(playlists: List<Playlist>): List<Playlist> = playlists.map { playlist ->
            playlist.copy(trackIDs = playlist.trackIDs.map(::mapped).distinct())
        }
        fun remapState(state: ProfileLibraryState): ProfileLibraryState = state.copy(
            playlists = remapPlaylists(state.playlists),
            favorites = state.favorites.mapTo(linkedSetOf(), ::mapped),
        )

        return library.copy(
            tracks = result.tracks,
            playlists = remapPlaylists(library.playlists),
            favorites = library.favorites.mapTo(linkedSetOf(), ::mapped),
            profileStates = library.profileStates.mapValues { (_, state) -> remapState(state) },
        )
    }

    private fun encode(value: String): String = value
        .replace("%", "%25")
        .replace("#", "%23")
        .replace("|", "%7C")
}

/** Persists active state before switching and restores it without discarding dirty mutations. */
object ProfileLibraryStatePolicy {
    fun captureActive(library: StoredLibrary): StoredLibrary {
        val key = RemoteTrackIdentityPolicy.contextKey(library.serverURL, library.syncProfileID)
            ?: return library
        val snapshot = ProfileLibraryState(
            playlists = library.playlists,
            favorites = library.favorites,
            playlistRevision = library.playlistRevision,
            knownRemotePlaylistIDs = library.knownRemotePlaylistIDs.orEmpty(),
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty(),
            deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty(),
            playlistSyncServerURL = library.playlistSyncServerURL,
            remoteLikedSongIDs = library.remoteLikedSongIDs.orEmpty(),
            dirtyRemoteLikeSongIDs = library.dirtyRemoteLikeSongIDs.orEmpty(),
            likesDirty = library.likesDirty,
            clipRanges = library.clipRanges,
            dirtyClipRangeKeys = library.dirtyClipRangeKeys,
            deletedClipRangeKeys = library.deletedClipRangeKeys,
        )
        return library.copy(profileStates = library.profileStates + (key to snapshot))
    }

    fun switchContext(library: StoredLibrary, serverURL: String, profileID: String): StoredLibrary {
        return restoreContext(captureActive(library), serverURL, profileID)
    }

    fun migrateContext(
        library: StoredLibrary,
        serverURL: String,
        migratedProfileID: String,
        accountProfileID: String,
    ): StoredLibrary {
        val oldProfileID = migratedProfileID.trim()
        val nextProfileID = accountProfileID.trim()
        val oldKey = RemoteTrackIdentityPolicy.contextKey(serverURL, oldProfileID) ?: return library
        val nextKey = RemoteTrackIdentityPolicy.contextKey(serverURL, nextProfileID) ?: return library
        if (oldProfileID.isEmpty() || nextProfileID.isEmpty() || oldProfileID == nextProfileID) return library
        if (library.syncProfileID != oldProfileID ||
            RemoteTrackIdentityPolicy.normalizedOrigin(library.serverURL) !=
            RemoteTrackIdentityPolicy.normalizedOrigin(serverURL)
        ) return library

        val captured = captureActive(library)
        fun migratedKey(key: String): String =
            if (key.startsWith("$oldKey|")) nextKey + key.removePrefix(oldKey) else key
        fun migratedRanges(ranges: Map<String, ClipRange>): Map<String, ClipRange> =
            ranges.entries.associate { (key, range) -> migratedKey(key) to range }
        fun migratedState(state: ProfileLibraryState): ProfileLibraryState = state.copy(
            playlistSyncServerURL = if (state.playlistSyncServerURL == oldKey) nextKey else state.playlistSyncServerURL,
            clipRanges = migratedRanges(state.clipRanges),
            dirtyClipRangeKeys = state.dirtyClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
            deletedClipRangeKeys = state.deletedClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
        )

        val states = captured.profileStates.toMutableMap()
        states.remove(oldKey)?.let { states[nextKey] = migratedState(it) }
        return captured.copy(
            tracks = captured.tracks.map { track ->
                if (RemoteTrackIdentityPolicy.belongsToContext(track, serverURL, oldProfileID)) {
                    track.copy(syncProfileID = nextProfileID)
                } else {
                    track
                }
            },
            syncProfileID = nextProfileID,
            playlistSyncServerURL = if (captured.playlistSyncServerURL == oldKey) nextKey else captured.playlistSyncServerURL,
            clipRanges = migratedRanges(captured.clipRanges),
            dirtyClipRangeKeys = captured.dirtyClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
            deletedClipRangeKeys = captured.deletedClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
            profileStates = states,
        )
    }

    fun restoreContext(captured: StoredLibrary, serverURL: String, profileID: String): StoredLibrary {
        val targetKey = RemoteTrackIdentityPolicy.contextKey(serverURL, profileID)
            ?: throw IllegalArgumentException("Enter a valid server URL")
        val target = captured.profileStates[targetKey] ?: emptyState(captured)
        val trulyLocalTrackIDs = captured.tracks.filterTo(linkedSetOf()) {
            it.remoteID == null && it.sourceServer == null
        }.mapTo(linkedSetOf(), Track::id)
        val localFavorites = captured.favorites.intersect(trulyLocalTrackIDs)
        val targetRemoteFavorites = target.favorites - trulyLocalTrackIDs
        return captured.copy(
            serverURL = serverURL,
            syncProfileID = profileID,
            playlists = target.playlists,
            favorites = targetRemoteFavorites + localFavorites,
            playlistRevision = target.playlistRevision,
            knownRemotePlaylistIDs = target.knownRemotePlaylistIDs,
            dirtyPlaylistIDs = target.dirtyPlaylistIDs,
            deletedPlaylistIDs = target.deletedPlaylistIDs,
            playlistSyncServerURL = target.playlistSyncServerURL,
            remoteLikedSongIDs = target.remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs = target.dirtyRemoteLikeSongIDs,
            likesDirty = target.likesDirty,
            clipRanges = target.clipRanges,
            dirtyClipRangeKeys = target.dirtyClipRangeKeys,
            deletedClipRangeKeys = target.deletedClipRangeKeys,
        )
    }

    private fun emptyState(library: StoredLibrary): ProfileLibraryState {
        // Favorites for truly local files are device-local product state and remain
        // available in every server profile. Remote favorites stay isolated.
        val localFavorites = library.favorites.filterTo(linkedSetOf()) { id ->
            library.tracks.firstOrNull { it.id == id }?.let {
                it.remoteID == null && it.sourceServer == null
            } == true
        }
        val system = library.playlists.firstOrNull(Playlist::isSystem)
            ?.copy(trackIDs = localFavorites.toList())
            ?: Playlist(name = "Liked Songs", trackIDs = localFavorites.toList(), isSystem = true)
        return ProfileLibraryState(playlists = listOf(system), favorites = localFavorites)
    }
}
