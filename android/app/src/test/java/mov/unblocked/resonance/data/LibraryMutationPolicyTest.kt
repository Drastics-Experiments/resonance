package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class LibraryMutationPolicyTest {
    @Test
    fun removesTracksAndAllCollectionReferencesInOneMutation() {
        val keep = Track(id = "keep", title = "Keep", relativePath = "keep.mp3")
        val remove = Track(id = "remove", title = "Remove", relativePath = "remove.mp3")
        val library = StoredLibrary(
            tracks = listOf(keep, remove),
            favorites = setOf(keep.id, remove.id),
            playlists = listOf(
                Playlist(name = "Liked Songs", isSystem = true, trackIDs = listOf(remove.id)),
                Playlist(name = "Mix", trackIDs = listOf(remove.id, keep.id, remove.id)),
            ),
        )

        val updated = LibraryMutationPolicy.removeTracks(library, setOf(remove.id))

        assertEquals(listOf(keep), updated.tracks)
        assertEquals(setOf(keep.id), updated.favorites)
        assertEquals(
            listOf(
                Playlist(name = "Liked Songs", isSystem = true),
                Playlist(name = "Mix", trackIDs = listOf(keep.id)),
            ),
            updated.playlists,
        )
    }

    @Test
    fun ignoresUnknownOrEmptyIDsWithoutAllocatingANewLibrary() {
        val library = StoredLibrary(
            tracks = listOf(Track(id = "keep", title = "Keep", relativePath = "keep.mp3")),
        )

        assertSame(library, LibraryMutationPolicy.removeTracks(library, emptySet()))
        assertSame(library, LibraryMutationPolicy.removeTracks(library, setOf("missing")))
    }
}
