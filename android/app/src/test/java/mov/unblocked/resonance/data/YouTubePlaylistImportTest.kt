package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class YouTubePlaylistImportTest {
    @Test
    fun playlistURLRecognizesListParameterWithoutTreatingVideoQueryAsRequired() {
        assertEquals(
            "PL1234567890",
            YouTubePlaylistParser.playlistID("https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PL1234567890"),
        )
        assertEquals(
            "PL1234567890",
            YouTubePlaylistParser.playlistID("https://youtu.be/jNQXAC9IVRw?list=PL1234567890"),
        )
        assertNull(YouTubePlaylistParser.playlistID("https://www.youtube.com/watch?v=jNQXAC9IVRw"))
        assertNull(YouTubePlaylistParser.playlistID("http://www.youtube.com/playlist?list=PL1234567890"))
        assertTrue(LinkImportKind.YouTubePlaylist.isPlaylist)
    }

    @Test
    fun parsesPlayableAndUnavailableRowsAndContinuation() {
        val html = """
            <script>
            var ytInitialData = {
              "playlistMetadataRenderer": {
                "playlistId": "PL1234567890",
                "title": {"simpleText": "Road Mix"}
              },
              "playlistHeaderRenderer": {
                "ownerText": {"runs": [{"text": "DJ Example"}]}
              },
              "playlistSidebarPrimaryInfoRenderer": {
                "thumbnailRenderer": {
                  "playlistVideoThumbnailRenderer": {
                    "thumbnail": {"thumbnails": [
                      {"url":"https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg","width":480,"height":360}
                    ]}
                  }
                }
              },
              "contents": [
                {"playlistVideoRenderer": {
                  "videoId":"jNQXAC9IVRw",
                  "title":{"runs":[{"text":"First Song"}]},
                  "shortBylineText":{"runs":[{"text":"First Artist"}]},
                  "lengthText":{"simpleText":"1:02"},
                  "index":{"simpleText":"1"},
                  "isPlayable":true,
                  "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/jNQXAC9IVRw/default.jpg","width":120,"height":90}]}
                }},
                {"playlistVideoRenderer": {
                  "videoId":"abcde123456",
                  "title":{"simpleText":"Unavailable"},
                  "isPlayable":false
                }},
                {"continuationItemRenderer": {
                  "continuationEndpoint": {"continuationCommand": {"token":"continue-token"}}
                }}
              ]
            };
            """.trimIndent()

        val page = YouTubePlaylistParser.parseHTML(html, "PL1234567890")

        assertEquals("Road Mix", page.title)
        assertEquals("DJ Example", page.author)
        assertEquals("continue-token", page.continuation)
        assertEquals(1, page.unavailableCount)
        assertEquals(1, page.items.size)
        val item = page.items.single()
        assertEquals("jNQXAC9IVRw", item.videoID)
        assertEquals("First Song", item.importTrack?.title)
        assertEquals("First Artist", item.importTrack?.artist)
        assertEquals(62, item.importTrack?.durationSeconds)
        assertEquals(1, item.playlistIndex)
        assertEquals(LinkImportSourceProvider.YouTube, item.sourceProvider)
        assertTrue(item.sourceURL.contains("watch?v=jNQXAC9IVRw"))
        assertTrue(page.artworkURL?.contains("i.ytimg.com") == true)
    }

    @Test
    fun parsesContinuationPayloadAndProviderConfiguration() {
        val payload = """
            {"onResponseReceivedActions":[
              {"continuationItems":[
                {"playlistVideoRenderer": {
                  "videoId":"dQw4w9WgXcQ",
                  "title":{"simpleText":"Second Song"},
                  "longBylineText":{"runs":[{"text":"Second Artist"}]},
                  "lengthText":{"simpleText":"3:05"},
                  "index":{"simpleText":"2"},
                  "thumbnail":{"thumbnails":[]}
                }}
              ]}
            ]}
        """.trimIndent()
        val page = YouTubePlaylistParser.parsePayload(payload, "PL1234567890")
        assertEquals("Second Song", page.items.single().title)
        assertEquals(185, page.items.single().durationSeconds)
        assertFalse(page.items.single().importTrack?.artist.isNullOrBlank())

        val config = YouTubePlaylistParser.configuration(
            """<script>{"INNERTUBE_API_KEY":"api-key","INNERTUBE_CLIENT_VERSION":"2.20260101.01.00","VISITOR_DATA":"visitor"}</script>""",
        )
        assertEquals("api-key", config.apiKey)
        assertEquals("2.20260101.01.00", config.clientVersion)
        assertEquals("visitor", config.visitorData)
    }
}
