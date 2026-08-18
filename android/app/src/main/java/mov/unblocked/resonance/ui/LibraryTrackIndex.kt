package mov.unblocked.resonance.ui

import java.util.Locale
import mov.unblocked.resonance.data.Track

/**
 * Immutable search index for one library snapshot.
 *
 * Building it is linear in the number of tracks. Subsequent searches reuse folded metadata instead
 * of performing four case-insensitive scans for every row on every keystroke.
 */
internal class LibraryTrackIndex(
    private val tracks: List<Track>,
) {
    private data class Entry(
        val track: Track,
        val searchText: String,
    )

    private val entries: List<Entry> = tracks.map { track ->
        Entry(
            track = track,
            searchText = buildString(
                track.title.length + track.artist.length + track.album.length + track.relativePath.length + 3,
            ) {
                append(track.title)
                append(FIELD_SEPARATOR)
                append(track.artist)
                append(FIELD_SEPARATOR)
                append(track.album)
                append(FIELD_SEPARATOR)
                append(track.relativePath)
            }.lowercase(Locale.ROOT),
        )
    }

    val queueIDs: List<String> = tracks.map(Track::id)

    fun search(rawQuery: String): List<Track> {
        val query = rawQuery.trim()
        if (query.isEmpty()) return tracks

        val foldedQuery = query.lowercase(Locale.ROOT)
        val matches = ArrayList<Track>()
        for (entry in entries) {
            if (entry.searchText.contains(foldedQuery)) matches.add(entry.track)
        }
        return matches
    }

    private companion object {
        const val FIELD_SEPARATOR = '\u0000'
    }
}
