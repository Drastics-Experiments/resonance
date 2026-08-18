package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class LibraryTrackIndexTest {
    @Test
    fun blankSearchReturnsTheOriginalLibrarySnapshot() {
        val tracks = sampleTracks()
        val index = LibraryTrackIndex(tracks)

        assertSame(tracks, index.search("   "))
        assertEquals(tracks.map(Track::id), index.queueIDs)
    }

    @Test
    fun searchMatchesEveryVisibleMetadataFieldAndPreservesOrder() {
        val tracks = sampleTracks()
        val index = LibraryTrackIndex(tracks)

        assertEquals(listOf("title"), index.search(" MIDNIGHT ").map(Track::id))
        assertEquals(listOf("artist"), index.search("nova rae").map(Track::id))
        assertEquals(listOf("album"), index.search("blue rooms").map(Track::id))
        assertEquals(listOf("path"), index.search("hidden-gem").map(Track::id))
        assertEquals(listOf("title", "artist", "album", "path"), index.search("music").map(Track::id))
    }

    @Test
    fun fieldSeparatorsPreventMatchesAcrossMetadataBoundaries() {
        val tracks = listOf(
            Track(
                id = "boundary",
                title = "Alpha",
                artist = "Artist",
                album = "Album",
                relativePath = "track.m4a",
            ),
        )

        assertEquals(emptyList<Track>(), LibraryTrackIndex(tracks).search("haart"))
    }

    @Test
    fun indexedResultsMatchThePreviousSearchPolicy() {
        val tracks = buildList {
            repeat(2_000) { index ->
                add(
                    Track(
                        id = "track-$index",
                        title = "Song ${index.toString().padStart(4, '0')}",
                        artist = "Artist ${index % 31}",
                        album = "Album ${index % 17}",
                        relativePath = "folder/${index % 13}/track-$index.m4a",
                    ),
                )
            }
        }
        val index = LibraryTrackIndex(tracks)
        for (query in listOf("song 0199", "artist 7", "album 3", "folder/8", "not-present")) {
            assertEquals(
                previousSearch(tracks, query).map(Track::id),
                index.search(query).map(Track::id),
            )
        }
    }

    private fun previousSearch(tracks: List<Track>, rawQuery: String): List<Track> {
        val query = rawQuery.trim()
        if (query.isEmpty()) return tracks
        return tracks.filter { track ->
            track.title.contains(query, ignoreCase = true) ||
                track.artist.contains(query, ignoreCase = true) ||
                track.album.contains(query, ignoreCase = true) ||
                track.relativePath.contains(query, ignoreCase = true)
        }
    }

    private fun sampleTracks(): List<Track> = listOf(
        Track(
            id = "title",
            title = "Midnight Music",
            artist = "Artist",
            album = "Album",
            relativePath = "title.m4a",
        ),
        Track(
            id = "artist",
            title = "Other Music",
            artist = "Nova Rae",
            album = "Album",
            relativePath = "artist.m4a",
        ),
        Track(
            id = "album",
            title = "Third Music",
            artist = "Artist",
            album = "Blue Rooms",
            relativePath = "album.m4a",
        ),
        Track(
            id = "path",
            title = "Fourth Music",
            artist = "Artist",
            album = "Album",
            relativePath = "imports/hidden-gem.m4a",
        ),
    )
}
