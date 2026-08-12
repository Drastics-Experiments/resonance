package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SoundCloudImportTest {
    @Test
    fun `source URL validation accepts only exact HTTPS SoundCloud hosts`() {
        assertNotNull(SoundCloudImportUrls.source("https://soundcloud.com/forss/flickermood"))
        assertNotNull(SoundCloudImportUrls.source("https://on.soundcloud.com/example"))
        assertNull(SoundCloudImportUrls.source("http://soundcloud.com/forss/flickermood"))
        assertNull(SoundCloudImportUrls.source("https://soundcloud.com.example/forss/flickermood"))
        assertNull(SoundCloudImportUrls.source("https://user:secret@soundcloud.com/forss/flickermood"))
    }

    @Test
    fun `hydration parser handles quoted brackets and creates direct track`() {
        val html = """
            <script>
            window.__sc_hydration = [
              {"hydratable":"apiClient","data":{"id":"abcdefghijklmnopqrstuvwxyz123456"}},
              {"hydratable":"sound","data":{
                "kind":"track",
                "id":101,
                "title":"Direct [Mix]",
                "full_duration":125500,
                "permalink_url":"https://www.soundcloud.com/artist/direct-mix?si=share",
                "streamable":true,
                "policy":"ALLOW",
                "track_authorization":"authorized-value",
                "user":{"username":"Artist","avatar_url":"https://i1.sndcdn.com/avatars-test-large.jpg"},
                "publisher_metadata":{"artist":"Artist","album_title":"Album"},
                "media":{"transcodings":[{
                  "url":"https://api-v2.soundcloud.com/media/sound/101/progressive",
                  "format":{"protocol":"progressive","mime_type":"audio/mpeg"}
                }]}
              }}
            ];
            </script>
        """.trimIndent()

        val hydration = SoundCloudImportParser.hydration(html)
        assertEquals("abcdefghijklmnopqrstuvwxyz123456", SoundCloudImportParser.clientID(hydration))
        val track = SoundCloudImportParser.track(hydration["sound"])
        val resolvedTrack = requireNotNull(track)
        assertEquals("Direct [Mix]", resolvedTrack.metadata.title)
        assertEquals("Artist", resolvedTrack.metadata.artist)
        assertEquals("Album", resolvedTrack.metadata.album)
        assertEquals(126, resolvedTrack.metadata.durationSeconds)
        assertEquals("https://soundcloud.com/artist/direct-mix", resolvedTrack.metadata.sourceURL)
        assertTrue(resolvedTrack.directlyImportable)
        assertEquals(LinkImportSourceProvider.SoundCloud, resolvedTrack.directCandidate()?.sourceProvider)
    }

    @Test
    fun `blocked or HLS-only tracks are not marked directly importable`() {
        val html = """
            window.__sc_hydration = [{"hydratable":"sound","data":{
              "kind":"track","id":202,"title":"Blocked",
              "permalink_url":"https://soundcloud.com/artist/blocked",
              "streamable":true,"policy":"BLOCK","track_authorization":"auth",
              "user":{"username":"Artist"},
              "media":{"transcodings":[{"url":"https://api-v2.soundcloud.com/media/202/hls",
                "format":{"protocol":"hls","mime_type":"audio/mpeg"}}]}
            }}];
        """.trimIndent()

        val track = SoundCloudImportParser.track(SoundCloudImportParser.hydration(html)["sound"])
        val resolvedTrack = requireNotNull(track)
        assertFalse(resolvedTrack.directlyImportable)
        assertNull(resolvedTrack.directCandidate())
    }

    @Test
    fun `only playlist import kinds report playlist behavior`() {
        assertTrue(LinkImportKind.SpotifyPlaylist.isPlaylist)
        assertTrue(LinkImportKind.SoundCloudPlaylist.isPlaylist)
        assertFalse(LinkImportKind.Track.isPlaylist)
    }
}
