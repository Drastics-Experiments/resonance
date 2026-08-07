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

        val match = LinkImportExistingPolicy.match(
            expected,
            listOf(local),
            listOf(remote),
            "https://music.example",
            "default",
        )

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

        val match = LinkImportExistingPolicy.match(
            expected,
            listOf(local),
            emptyList(),
            "https://music.example",
            "default",
        )

        assertFalse(match.isOnDevice)
        assertFalse(match.isOnServer)
    }

    @Test
    fun remoteIdFastPathRequiresActiveServerAndProfile() {
        val collidingRemote = remoteSong(
            id = "collision",
            title = "Different Song",
            artist = "Different Artist",
            duration = 100.0,
        )
        fun device(sourceServer: String?, profileID: String?) = Track(
            id = "device",
            title = expected.title,
            artist = expected.artist,
            durationMs = 223_000,
            relativePath = "Feels.m4a",
            remoteID = "collision",
            sourceServer = sourceServer,
            syncProfileID = profileID,
        )

        val otherServer = LinkImportExistingPolicy.match(
            expected, listOf(device("https://old.example", "default")), listOf(collidingRemote),
            "https://music.example", "default",
        )
        val unknownServer = LinkImportExistingPolicy.match(
            expected, listOf(device(null, "default")), listOf(collidingRemote),
            "https://music.example", "default",
        )
        val otherProfile = LinkImportExistingPolicy.match(
            expected, listOf(device("https://music.example", "other")), listOf(collidingRemote),
            "https://music.example", "default",
        )
        val active = LinkImportExistingPolicy.match(
            expected, listOf(device("https://music.example", "default")), listOf(collidingRemote),
            "https://music.example", "default",
        )

        assertFalse(otherServer.isOnServer)
        assertFalse(otherServer.isOnDevice)
        assertFalse(unknownServer.isOnServer)
        assertFalse(unknownServer.isOnDevice)
        assertFalse(otherProfile.isOnServer)
        assertFalse(otherProfile.isOnDevice)
        assertTrue(active.isOnDevice)
        assertEquals("collision", active.serverSongID)
    }

    @Test
    fun hiddenContextMatchCannotShadowAVisibleLocalMatch() {
        fun matchingTrack(id: String, sourceServer: String?, profileID: String?) = Track(
            id = id,
            title = expected.title,
            artist = expected.artist,
            durationMs = 223_000,
            relativePath = "$id.m4a",
            remoteID = sourceServer?.let { "remote-$id" },
            sourceServer = sourceServer,
            syncProfileID = profileID,
        )
        val hidden = matchingTrack("hidden", "https://old.example", "default")
        val local = matchingTrack("local", null, null)

        val match = LinkImportExistingPolicy.match(
            expected,
            listOf(hidden, local),
            emptyList(),
            "https://music.example",
            "default",
        )

        assertEquals(local.id, match.deviceTrackID)
    }

    @Test
    fun ambiguousServerMetadataNeverChoosesAnArbitraryRemoteId() {
        val first = remoteSong("first", expected.title, expected.artist, 223.0)
        val second = remoteSong("second", expected.title, expected.artist, 224.0)

        val match = LinkImportExistingPolicy.match(
            expected,
            emptyList(),
            listOf(first, second),
            "https://music.example",
            "default",
        )

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
