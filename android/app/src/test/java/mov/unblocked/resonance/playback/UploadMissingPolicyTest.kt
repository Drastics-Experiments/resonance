package mov.unblocked.resonance.playback

import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track
import org.junit.Assert.assertEquals
import org.junit.Test

class UploadMissingPolicyTest {
    @Test
    fun uploadsOnlyActiveContextDownloadsAndUsesExactHashes() {
        val hash = "a".repeat(64)
        val tracks = listOf(
            track("present", remoteID = "server-present"),
            track("missing", remoteID = "server-gone"),
            track("hash-match", remoteID = "old-id", hash = hash.uppercase()),
            track(
                "metadata-match",
                remoteID = "old-metadata-id",
                title = "All for You - Radio Version",
                artist = "Ace of Base",
                durationMs = 217_100,
            ),
            track("local"),
            track("other-profile", remoteID = "gone", profileID = "other"),
            track("other-server", remoteID = "server-present", sourceServer = "https://old.example"),
            track("unknown-origin", remoteID = "server-present", sourceServer = null),
            track("origin-only", sourceServer = "https://old.example"),
        )
        val catalog = listOf(
            remote("server-present"),
            remote("replacement", hash = hash),
            remote(
                "metadata-replacement",
                title = "All for You Radio Version",
                artist = "Ace of Base",
                durationSeconds = 217.9,
            ),
        )

        val plan = UploadMissingPolicy.plan(tracks, catalog, "default", "https://music.example")

        assertEquals(listOf("missing"), plan.uploadTrackIDs)
        assertEquals(
            mapOf("hash-match" to "replacement"),
            plan.existingRemoteIDsByTrackID,
        )
        assertEquals(listOf("metadata-match"), plan.reviewTrackIDs)
    }

    @Test
    fun missingCatalogAccessDoesNotCrossProfileOrServer() {
        val plan = UploadMissingPolicy.plan(
            tracks = listOf(
                track("download", remoteID = "old-id"),
                track("other-profile", remoteID = "profile-id", profileID = "old-profile"),
                track("other-server", remoteID = "other-id", sourceServer = "https://old.example"),
                track("local"),
            ),
            catalog = emptyList(),
            activeProfileID = "default",
            activeServerURL = "https://music.example",
        )

        assertEquals(listOf("download"), plan.uploadTrackIDs)
        assertEquals(emptyMap<String, String>(), plan.existingRemoteIDsByTrackID)
        assertEquals(emptyList<String>(), plan.reviewTrackIDs)
    }

    @Test
    fun ambiguousHashAndMetadataMatchesRequireReview() {
        val hash = "b".repeat(64)
        val plan = UploadMissingPolicy.plan(
            tracks = listOf(
                track("duplicate-hash", remoteID = "old", hash = hash),
                track("metadata-only", remoteID = "gone", title = "Version", artist = "Named Performer", durationMs = 200_000),
            ),
            catalog = listOf(
                remote("hash-a", hash = hash),
                remote("hash-b", hash = hash),
                remote("possible-version", title = "Version", artist = "Named Performer", durationSeconds = 200.0),
            ),
            activeProfileID = "default",
            activeServerURL = "https://music.example",
        )

        assertEquals(emptyList<String>(), plan.uploadTrackIDs)
        assertEquals(emptyMap<String, String>(), plan.existingRemoteIDsByTrackID)
        assertEquals(listOf("duplicate-hash", "metadata-only"), plan.reviewTrackIDs)
    }

    private fun track(
        id: String,
        remoteID: String? = null,
        hash: String? = null,
        profileID: String = "default",
        sourceServer: String? = remoteID?.let { "https://music.example" },
        title: String = id,
        artist: String = "Artist",
        durationMs: Long = 0,
    ) = Track(
        id = id,
        title = title,
        artist = artist,
        durationMs = durationMs,
        relativePath = "$id.mp3",
        remoteID = remoteID,
        sourceServer = sourceServer,
        syncProfileID = remoteID?.let { profileID },
        contentSHA256 = hash,
    )

    private fun remote(
        id: String,
        hash: String? = null,
        title: String = id,
        artist: String = "Artist",
        durationSeconds: Double? = null,
    ) = RemoteSong(
        id = id,
        filename = "$id.mp3",
        title = title,
        artist = artist,
        album = "Album",
        size = 1,
        modifiedAt = "0",
        contentType = "audio/mpeg",
        downloadURL = "/download/$id",
        streamURL = "/stream/$id",
        durationSeconds = durationSeconds,
        contentSHA256 = hash,
    )
}
