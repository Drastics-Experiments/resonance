package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkImportExistingPolicyTest {
    private val expected = LinkImportTrack(
        title = "Feels (feat. Pharrell Williams)",
        artist = "Calvin Harris, Pharrell Williams, Katy Perry & Big Sean",
        durationSeconds = 223,
        sourceURL = "https://open.spotify.com/track/example",
    )

    @Test
    fun matchesExistingDeviceAndServerSongsByNormalizedMetadata() {
        val local = Track(
            id = "local-id",
            title = "Feels feat Pharrell Williams",
            artist = "Calvin Harris Pharrell Williams Katy Perry Big Sean",
            durationMs = 224_000,
            relativePath = "Feels.m4a",
        )
        val remote = remoteSong(
            id = "remote-id",
            title = "Feels feat. Pharrell Williams",
            artist = "Calvin Harris, Pharrell Williams, Katy Perry & Big Sean",
            duration = 222.0,
        )

        val match = LinkImportExistingPolicy.match(expected, listOf(local), listOf(remote))

        assertTrue(match.isOnDevice)
        assertTrue(match.isOnServer)
        assertEquals("local-id", match.deviceTrackID)
        assertEquals("remote-id", match.serverSongID)
    }

    @Test
    fun rejectsADeviceSongWithMateriallyDifferentDuration() {
        val local = Track(
            id = "wrong-version",
            title = "Feels feat Pharrell Williams",
            artist = "Calvin Harris Pharrell Williams Katy Perry Big Sean",
            durationMs = 260_000,
            relativePath = "Feels-live.m4a",
        )

        val match = LinkImportExistingPolicy.match(expected, listOf(local), emptyList())

        assertFalse(match.isOnDevice)
        assertFalse(match.isOnServer)
    }

    private fun remoteSong(id: String, title: String, artist: String, duration: Double) = RemoteSong(
        id = id,
        filename = "$title.m4a",
        title = title,
        artist = artist,
        album = "Album",
        size = 1,
        modifiedAt = "0",
        contentType = "audio/mp4",
        downloadURL = "/download/$id",
        streamURL = "/stream/$id",
        durationSeconds = duration,
    )
}
