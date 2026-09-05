package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class TrackIndexPolicyTest {
    @Test
    fun indexesUseTheFirstRecordForDuplicateIDs() {
        val first = Track(id = "same", title = "First", relativePath = "first.mp3")
        val second = Track(id = "same", title = "Second", relativePath = "second.mp3")

        val indexed = TrackIndexPolicy.byID(listOf(first, second))

        assertEquals(listOf("same"), indexed.keys.toList())
        assertSame(first, indexed["same"])
    }

    @Test
    fun remoteIndexExcludesOtherServerProfilesAndLocalTracks() {
        val matching = Track(
            id = "matching",
            title = "Matching",
            relativePath = "matching.mp3",
            remoteID = "song-1",
            sourceServer = "https://music.example",
            syncProfileID = "profile-a",
        )
        val otherProfile = matching.copy(id = "other-profile", syncProfileID = "profile-b")
        val otherServer = matching.copy(id = "other-server", sourceServer = "https://other.example")
        val local = Track(id = "local", title = "Local", relativePath = "local.mp3")

        val indexed = TrackIndexPolicy.byRemoteID(
            listOf(matching, otherProfile, otherServer, local),
            serverURL = "https://music.example",
            profileID = "profile-a",
        )

        assertEquals(mapOf("song-1" to matching), indexed)
    }
}
