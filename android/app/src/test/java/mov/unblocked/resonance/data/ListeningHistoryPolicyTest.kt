package mov.unblocked.resonance.data

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ListeningHistoryPolicyTest {
    private val origin = "https://music.example"
    private val profile = "account-profile"

    @Test
    fun `local-only sessions retain metadata and qualify after ten percent`() {
        val track = Track(
            id = "local-track",
            title = "Local title",
            artist = "Local artist",
            album = "Local album",
            durationMs = 120_000,
            relativePath = "local.m4a",
        )
        val entry = ListeningHistoryRetentionPolicy.entry(track, origin, profile)
            .copy(listenedSeconds = 12.01)

        assertNull(entry.remoteSongID)
        assertEquals("Local title", entry.title)
        assertTrue(ListeningHistoryRetentionPolicy.qualifies(entry, track))
        assertFalse(ListeningHistoryRetentionPolicy.qualifies(entry.copy(listenedSeconds = 12.0), track))
    }

    @Test
    fun `remote-only account history keeps snapshot metadata`() {
        val remote = RemoteListeningHistoryDocument(
            profileID = profile,
            entries = listOf(RemoteListeningHistoryEntry(
                id = "event-1",
                trackID = "track-on-other-device",
                songID = "server-song",
                startedAt = "2026-08-16T12:00:00Z",
                listenedSeconds = 45.0,
                title = "Shared title",
                artist = "Shared artist",
                album = "Shared album",
                durationSeconds = 180.0,
                artworkURL = "https://music.example/api/v1/songs/server-song/artwork?token=signed",
            )),
        )

        val merged = ListeningHistoryRetentionPolicy.mergeRemote(
            existing = emptyList(),
            document = remote,
            serverURL = origin,
            profileID = profile,
            tracks = emptyList(),
        ).single()

        assertEquals("Shared title", merged.title)
        assertEquals("Shared artist", merged.artist)
        assertEquals("https://music.example/api/v1/songs/server-song/artwork?token=signed", merged.artworkURL)
        assertEquals("server-song", merged.remoteSongID)
        assertFalse(merged.originatedOnThisDevice)
    }

    @Test
    fun `remote-only history hydrates missing metadata from the server catalog`() {
        val remote = RemoteListeningHistoryDocument(
            profileID = profile,
            entries = listOf(RemoteListeningHistoryEntry(
                id = "event-catalog",
                trackID = "track-on-other-device",
                songID = "server-song",
                startedAt = "2026-08-16T12:00:00Z",
                listenedSeconds = 45.0,
            )),
        )
        val catalog = RemoteSong(
            id = "server-song",
            filename = "server-song.m4a",
            title = "Catalog title",
            artist = "Catalog artist",
            album = "Catalog album",
            size = 0,
            modifiedAt = "now",
            contentType = "audio/mp4",
            downloadURL = "/api/v1/songs/server-song/file",
            streamURL = "/api/v1/songs/server-song/stream",
            durationSeconds = 300.0,
            artworkURL = "https://music.example/api/v1/songs/server-song/artwork?token=signed",
        )

        val merged = ListeningHistoryRetentionPolicy.mergeRemote(
            existing = emptyList(),
            document = remote,
            serverURL = origin,
            profileID = profile,
            tracks = emptyList(),
            catalog = listOf(catalog),
        ).single()

        assertEquals("Catalog title", merged.title)
        assertEquals("Catalog artist", merged.artist)
        assertEquals("Catalog album", merged.album)
        assertEquals(300.0, merged.durationSeconds)
        assertEquals(catalog.artworkURL, merged.artworkURL)
    }

    @Test
    fun `history retention is bounded per account profile`() {
        val start = Instant.parse("2026-08-16T12:00:00Z")
        val entries = (0..ListeningHistoryRetentionPolicy.MAXIMUM_ENTRIES).map { index ->
            ListeningHistoryEntry(
                id = "event-$index",
                trackID = "track-$index",
                startedAt = start.plusSeconds(index.toLong()).toString(),
                listenedSeconds = 1.0,
                serverOrigin = origin,
                syncProfileID = profile,
                durationSeconds = 1.0,
            )
        }
        assertEquals(ListeningHistoryRetentionPolicy.MAXIMUM_ENTRIES, ListeningHistoryRetentionPolicy.normalize(entries).size)
    }
}
