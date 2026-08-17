package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class LibraryScreenPolicyTest {
    @Test
    fun blankSearchReturnsTheOriginalListWithoutAllocating() {
        val tracks = listOf(track("one", title = "First"))

        assertSame(tracks, filteredLibraryTracks(tracks, "   "))
    }

    @Test
    fun searchIsTrimmedCaseInsensitiveAndChecksUsefulMetadata() {
        val tracks = listOf(
            track("title", title = "Midnight Drive"),
            track("artist", title = "Other", artist = "Nova Rae"),
            track("album", title = "Third", album = "Blue Rooms"),
            track("path", title = "Fourth", relativePath = "imports/hidden-gem.m4a"),
        )

        assertEquals(listOf("title"), filteredLibraryTracks(tracks, "  midnight ").map(Track::id))
        assertEquals(listOf("artist"), filteredLibraryTracks(tracks, "NOVA").map(Track::id))
        assertEquals(listOf("album"), filteredLibraryTracks(tracks, "rooms").map(Track::id))
        assertEquals(listOf("path"), filteredLibraryTracks(tracks, "HIDDEN-GEM").map(Track::id))
    }

    @Test
    fun recentlyAddedTracksAreNewestFirstAndRespectTheLimit() {
        val tracks = listOf(
            track("old", dateAdded = 10),
            track("new", dateAdded = 30),
            track("middle", dateAdded = 20),
        )

        assertEquals(listOf("new", "middle"), recentlyAddedTracks(tracks, limit = 2).map(Track::id))
        assertEquals(emptyList<Track>(), recentlyAddedTracks(tracks, limit = 0))
    }

    private fun track(
        id: String,
        title: String = id,
        artist: String = "Artist",
        album: String = "Album",
        relativePath: String = "$id.m4a",
        dateAdded: Long = 0,
    ) = Track(
        id = id,
        title = title,
        artist = artist,
        album = album,
        relativePath = relativePath,
        dateAddedEpochMs = dateAdded,
    )
}
