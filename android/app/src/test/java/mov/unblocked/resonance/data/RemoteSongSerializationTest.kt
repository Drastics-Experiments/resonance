package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteSongSerializationTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun decodesMinimalCatalogWithoutServerMetadata() {
        val song = json.decodeFromString<RemoteSong>(
            """
            {
              "id": "saved-song-uuid",
              "source_url": "https://media.example/Local%20Title.m4a?token=preserved",
              "download_url": "/api/v1/songs/saved-song-uuid/file",
              "stream_url": "/api/v1/songs/saved-song-uuid/stream"
            }
            """.trimIndent(),
        )

        assertEquals("saved-song-uuid", song.id)
        assertEquals("Local Title.m4a", song.filename)
        assertEquals("Resolving metadata…", song.title)
        assertEquals("On-device lookup", song.artist)
        assertEquals("Link only", song.album)
        assertEquals(0L, song.size)
        assertEquals("https://media.example/Local%20Title.m4a?token=preserved", song.sourceURL)
        assertEquals("audio", song.mediaKind)
        assertTrue(song.isSourceLinkRecord)
    }

    @Test
    fun decodesIosCatalogArtworkAndDurationFields() {
        val song = json.decodeFromString<RemoteSong>(
            """
            {
              "id": "song-1",
              "filename": "Example.mp3",
              "title": "Example",
              "artist": "Artist",
              "album": "Album",
              "size": 1200,
              "modified_at": "2026-08-03T00:00:00Z",
              "content_type": "audio/mpeg",
              "download_url": "/api/v1/songs/song-1/download",
              "stream_url": "/api/v1/songs/song-1/stream",
              "duration_seconds": 184.46,
              "artwork_url": "https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/song-1/artwork"
            }
            """.trimIndent(),
        )

        assertEquals("3:04", song.durationText)
        assertEquals("https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/song-1/artwork", song.artworkURL)
    }

    @Test
    fun ignoresInvalidOptionalDurationAndArtwork() {
        val song = json.decodeFromString<RemoteSong>(
            """
            {
              "id": "song-2",
              "filename": "Example.mp3",
              "title": "Example",
              "artist": "Artist",
              "album": "Album",
              "size": 1200,
              "modified_at": "0",
              "content_type": "audio/mpeg",
              "download_url": "/download",
              "stream_url": "/stream",
              "duration": 0,
              "artwork": "   "
            }
            """.trimIndent(),
        )

        assertNull(song.durationText)
        assertNull(song.artworkURL)
    }

    @Test
    fun identifiesVideoFromContentTypeOrSupportedContainerExtension() {
        val audio = RemoteSong(
            id = "audio",
            filename = "song.mp3",
            title = "Song",
            artist = "Artist",
            album = "Album",
            size = 1,
            modifiedAt = "",
            contentType = "audio/mpeg",
            downloadURL = "/download",
            streamURL = "/stream",
        )
        assertFalse(audio.isVideoMedia)
        assertTrue(audio.copy(filename = "clip.MP4").isVideoMedia)
        assertTrue(audio.copy(contentType = "video/webm", filename = "clip.bin").isVideoMedia)
        assertTrue(audio.copy(mediaKind = "video").isVideoMedia)
    }
}
