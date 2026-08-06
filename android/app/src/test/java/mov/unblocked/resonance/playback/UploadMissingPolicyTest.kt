package mov.unblocked.resonance.playback

import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Test

class UploadMissingPolicyTest {
    @Test
    fun uploadsOnlyDownloadedActiveProfileSongsMissingFromTheCatalog() {
        val tracks = listOf(
            track("present", remoteID = "server-present"),
            track("missing", remoteID = "server-gone"),
            track("hash-match", remoteID = "old-id", hash = "ABC"),
            track("local"),
            track("other-profile", remoteID = "gone", profileID = "other"),
        )
        val catalog = listOf(
            remote("server-present"),
            remote("replacement", hash = "abc"),
        )

        val plan = UploadMissingPolicy.plan(tracks, catalog, "default", "https://music.example")

        assertEquals(listOf("missing"), plan.uploadTrackIDs)
        assertEquals(mapOf("hash-match" to "replacement"), plan.existingRemoteIDsByTrackID)
    }

    private fun track(
        id: String,
        remoteID: String? = null,
        hash: String? = null,
        profileID: String = "default",
    ) = Track(
        id = id,
        title = id,
        relativePath = "$id.mp3",
        remoteID = remoteID,
        sourceServer = remoteID?.let { "https://music.example" },
        syncProfileID = remoteID?.let { profileID },
        contentSHA256 = hash,
    )

    private fun remote(id: String, hash: String? = null) = RemoteSong(
        id = id,
        filename = "$id.mp3",
        title = id,
        artist = "Artist",
        album = "Album",
        size = 1,
        modifiedAt = "0",
        contentType = "audio/mpeg",
        downloadURL = "/download/$id",
        streamURL = "/stream/$id",
        contentSHA256 = hash,
    )
}
