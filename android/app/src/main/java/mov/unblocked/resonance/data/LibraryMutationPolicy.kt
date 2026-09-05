package mov.unblocked.resonance.data

/**
 * Pure library transformations shared by repository mutations.
 *
 * Keeping the collection update separate from file I/O makes batch operations linear in the
 * number of tracks and prevents each deleted item from rebuilding every playlist independently.
 */
internal object LibraryMutationPolicy {
    fun removeTracks(library: StoredLibrary, deletingTrackIDs: Set<String>): StoredLibrary {
        if (deletingTrackIDs.isEmpty()) return library
        if (library.tracks.none { it.id in deletingTrackIDs }) return library

        return library.copy(
            tracks = library.tracks.filterNot { it.id in deletingTrackIDs },
            favorites = library.favorites - deletingTrackIDs,
            playlists = library.playlists.map { playlist ->
                playlist.copy(trackIDs = playlist.trackIDs.filterNot(deletingTrackIDs::contains))
            },
        )
    }
}
