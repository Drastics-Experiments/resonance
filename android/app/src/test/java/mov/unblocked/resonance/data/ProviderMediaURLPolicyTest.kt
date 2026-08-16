package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProviderMediaURLPolicyTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun expiringProviderMediaURLsAreNotPersistable() {
        assertTrue(ProviderMediaURLPolicy.isShortLivedMediaURL(
            "https://rr1---sn.googlevideo.com/videoplayback?expire=1&sig=secret",
        ))
        assertTrue(ProviderMediaURLPolicy.isShortLivedMediaURL(
            "https://cf-media.sndcdn.com/track.mp3?Policy=short-lived",
        ))
        assertNull(ProviderMediaURLPolicy.persistableDownloadURL(
            "https://rr1---sn.googlevideo.com/videoplayback?expire=1&sig=secret",
        ))
        assertEquals(
            "https://music.example/api/v1/songs/song-1/file",
            ProviderMediaURLPolicy.persistableDownloadURL(
                "https://music.example/api/v1/songs/song-1/file",
            ),
        )
        assertEquals(
            "https://music.example/videoplayback/song-1",
            ProviderMediaURLPolicy.persistableDownloadURL(
                "https://music.example/videoplayback/song-1",
            ),
        )
    }

    @Test
    fun canonicalSourceURLRemainsWhileProviderMediaURLIsDropped() {
        val track = Track(
            title = "Song",
            relativePath = "song.m4a",
            sourceURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            downloadSourceURL = "https://rr1---sn.googlevideo.com/videoplayback?expire=1",
        )

        val sanitized = ProviderMediaURLPolicy.sanitizeTrack(track)
        assertEquals(track.sourceURL, sanitized.sourceURL)
        assertNull(sanitized.downloadSourceURL)
        val decoded = json.decodeFromString<Track>(json.encodeToString(sanitized))
        assertEquals(track.sourceURL, decoded.sourceURL)
        assertNull(decoded.downloadSourceURL)
    }

    @Test
    fun shortLivedSourceURLsAreDroppedButCanonicalSourcePagesRemain() {
        val canonical = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        val shortLived = "https://rr1---sn.googlevideo.com/videoplayback?expire=1"
        val sanitizedCanonical = ProviderMediaURLPolicy.sanitizeTrack(
            Track(title = "Song", relativePath = "song.m4a", sourceURL = canonical),
        )
        val sanitizedMedia = ProviderMediaURLPolicy.sanitizeTrack(
            Track(title = "Song", relativePath = "song.m4a", sourceURL = shortLived),
        )

        assertEquals(canonical, sanitizedCanonical.sourceURL)
        assertNull(sanitizedMedia.sourceURL)
        assertNull(
            ProviderMediaURLPolicy.sanitizeTrack(
                Track(
                    title = "Song",
                    relativePath = "song.m4a",
                    sourceServer = "https://music.example/" + "s".repeat(ProviderMediaURLPolicy.MAX_URL_LENGTH),
                    sourceURL = "x".repeat(ProviderMediaURLPolicy.MAX_URL_LENGTH + 1),
                ),
            ).sourceServer,
        )
    }

    @Test
    fun persistedURLFieldsAreBounded() {
        val overlong = "https://www.youtube.com/watch?v=" +
            "x".repeat(ProviderMediaURLPolicy.MAX_URL_LENGTH)

        assertNull(ProviderMediaURLPolicy.boundedURL(overlong))
        assertNull(ProviderMediaURLPolicy.persistableDownloadURL(overlong))
        assertNull(RemoteSongMetadataCachePolicy.key(overlong, "audio"))
    }

    @Test
    fun durableURLsRejectUnsafeAuthoritiesWhileKeepingCanonicalPages() {
        val canonical = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        assertEquals(canonical, ProviderMediaURLPolicy.persistableSourceURL(canonical))
        assertEquals(
            "https://music.example/api/v1/songs/song-1/file",
            ProviderMediaURLPolicy.persistableSourceURL("https://music.example/api/v1/songs/song-1/file"),
        )
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("http://music.example/song"))
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("https://user:secret@music.example/song"))
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("https://music.example:8443/song"))
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("https://music.example/song#fragment"))
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("https://127.0.0.1/song"))
        assertNull(ProviderMediaURLPolicy.persistableSourceURL("https://localhost/song"))
    }

    @Test
    fun metadataCacheDropsOnlyShortLivedArtworkMediaURLs() {
        val source = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        val key = RemoteSongMetadataCachePolicy.key(source, "audio")!!
        val entry = RemoteSongMetadataCacheEntry(
            sourceURL = source,
            mediaKind = "audio",
            title = "Song",
            artist = "Artist",
            artworkURL = "https://rr1---sn.googlevideo.com/videoplayback?expire=1",
            cachedAtEpochMs = 1_800_000_000_000L,
        )

        val normalized = RemoteSongMetadataCachePolicy.normalized(
            mapOf(key to entry),
            nowEpochMs = 1_800_000_000_000L,
        )
        assertNull(normalized.getValue(key).artworkURL)
        assertEquals(
            "https://i1.sndcdn.com/artworks-000123.jpg",
            ProviderMediaURLPolicy.sanitizeMetadataArtworkURL(
                "https://i1.sndcdn.com/artworks-000123.jpg",
            ),
        )
        assertNull(
            ProviderMediaURLPolicy.sanitizeMetadataArtworkURL(
                "https://cf-media.sndcdn.com/track.mp3?Policy=short-lived",
            ),
        )
    }

    @Test
    fun metadataCacheDropsShortLivedSourceURLsToo() {
        val source = "https://rr1---sn.googlevideo.com/videoplayback?expire=1"
        val key = "audio:$source"
        val entry = RemoteSongMetadataCacheEntry(
            sourceURL = source,
            mediaKind = "audio",
            title = "Song",
            artist = "Artist",
            cachedAtEpochMs = 1_800_000_000_000L,
        )

        assertTrue(
            RemoteSongMetadataCachePolicy.normalized(
                mapOf(key to entry),
                nowEpochMs = 1_800_000_000_000L,
            ).isEmpty(),
        )
    }
}
