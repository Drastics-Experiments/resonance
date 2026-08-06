package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkImportSearchTest {
    @Test
    fun distinguishesSearchTextFromLinks() {
        assertFalse(LinkImportInput.looksLikeLink("Test Song Test Artist"))
        assertTrue(LinkImportInput.looksLikeLink("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8"))
        assertTrue(LinkImportInput.looksLikeLink("www.youtube.com/watch?v=jNQXAC9IVRw"))
        assertTrue(LinkImportInput.looksLikeLink("example.com/song"))
    }

    @Test
    fun parsesPublicSpotifySearchMetadata() {
        val payload = """
            {
              "data": {
                "tracks": [{
                  "id": "4PTG3Z6ehGkBFwjybzWkR8",
                  "title": "Test Song",
                  "artist": "Test Artist",
                  "album": "Test Album",
                  "duration": 214,
                  "artworkURL": "https://i.scdn.co/image/cover"
                }]
              }
            }
        """.trimIndent()
        val track = LinkImportSearchParser.spotifyTracks(payload).single()
        assertEquals("https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8", track.sourceURL)
        assertEquals(214, track.durationSeconds)
    }
}
