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
        assertEquals(1, page.skippedItems.size)
        assertEquals(2, page.skippedItems.single().position)
        assertEquals("Unavailable", page.skippedItems.single().title)
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

    @Test
    fun preservesRepeatedLegacyPlaylistRowsWithDistinctPositions() {
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[${playlistVideoRow("jNQXAC9IVRw", "First Occurrence", 1)},${playlistVideoRow("jNQXAC9IVRw", "Second Occurrence", 2)}]}""",
            "PL1234567890",
        )

        assertEquals(listOf("jNQXAC9IVRw", "jNQXAC9IVRw"), page.items.map(LinkImportCandidate::videoID))
        assertEquals(listOf(1, 2), page.items.map(LinkImportCandidate::playlistIndex))
        assertEquals(
            listOf("playlist:1:jNQXAC9IVRw", "playlist:2:jNQXAC9IVRw"),
            page.items.map(LinkImportCandidate::playlistItemID),
        )
    }

    @Test
    fun parsesModernLockupRowsWithContentText() {
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[${lockupRow("jNQXAC9IVRw", "Me at the zoo", "Jawed Karim")},${lockupRow("dQw4w9WgXcQ", "Second Song", "Second Artist") }]}""",
            "PL1234567890",
        )

        assertEquals(listOf("jNQXAC9IVRw", "dQw4w9WgXcQ"), page.items.map(LinkImportCandidate::videoID))
        assertEquals("Me at the zoo", page.items.first().title)
        assertEquals("Jawed Karim", page.items.first().artist)
        assertEquals(listOf(1, 2), page.items.map(LinkImportCandidate::playlistIndex))
    }

    @Test
    fun parsesModernLockupArtworkSources() {
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[${lockupRowWithArtwork("jNQXAC9IVRw", "Me at the zoo", "Jawed Karim") }]}""",
            "PL1234567890",
        )

        assertEquals(
            "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
            page.items.single().thumbnailURL,
        )
        assertEquals(
            "https://i.ytimg.com/vi/jNQXAC9IVRw/hqdefault.jpg",
            page.items.single().importTrack?.artworkURL,
        )
    }

    @Test
    fun continuationFallbackIndexesRemainGlobalAcrossPages() {
        val firstPage = YouTubePlaylistParser.parsePayload(
            """{"contents":[${lockupRow("jNQXAC9IVRw", "First Song", "Artist")},${invalidLockupRow()},${lockupRow("jNQXAC9IVRw", "Duplicate Song", "Artist")},${lockupRow("dQw4w9WgXcQ", "Second Song", "Artist") }]}""",
            "PL1234567890",
        )
        val continuationPage = YouTubePlaylistParser.parsePayload(
            """{"contents":[${lockupRow("9bZkp7q19f0", "Third Song", "Artist")},${lockupRow("aqz-KE-bpKQ", "Fourth Song", "Artist") }]}""",
            "PL1234567890",
            fallbackIndexOffset = firstPage.lastPlaylistIndex,
        )

        val ordered = (firstPage.items + continuationPage.items).sortedBy(LinkImportCandidate::playlistIndex)
        assertEquals(
            listOf("jNQXAC9IVRw", "jNQXAC9IVRw", "dQw4w9WgXcQ", "9bZkp7q19f0", "aqz-KE-bpKQ"),
            ordered.map(LinkImportCandidate::videoID),
        )
        assertEquals(4, firstPage.rowCount)
        assertEquals(1, firstPage.unavailableCount)
        assertEquals(listOf(2), firstPage.skippedItems.map(LinkImportSkippedItem::position))
        assertEquals(listOf("Unavailable"), firstPage.skippedItems.map(LinkImportSkippedItem::title))
        assertEquals(listOf(1, 3, 4, 5, 6), ordered.map(LinkImportCandidate::playlistIndex))
        assertEquals(
            listOf(
                "playlist:1:jNQXAC9IVRw",
                "playlist:3:jNQXAC9IVRw",
                "playlist:4:dQw4w9WgXcQ",
                "playlist:5:9bZkp7q19f0",
                "playlist:6:aqz-KE-bpKQ",
            ),
            ordered.map(LinkImportCandidate::playlistItemID),
        )
    }

    @Test
    fun mixedExplicitAndFallbackIndexesPreserveEncounterOrder() {
        val explicit = """
            {"playlistVideoRenderer":{
              "videoId":"jNQXAC9IVRw",
              "title":{"simpleText":"Explicit Song"},
              "shortBylineText":{"simpleText":"Artist"},
              "index":{"simpleText":"10"}
            }}
        """.trimIndent()
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[$explicit,${lockupRow("dQw4w9WgXcQ", "Fallback Song", "Artist")}]}""",
            "PL1234567890",
        )

        assertEquals(listOf("jNQXAC9IVRw", "dQw4w9WgXcQ"), page.items.map(LinkImportCandidate::videoID))
        assertEquals(listOf(10, 11), page.items.map(LinkImportCandidate::playlistIndex))
        assertEquals(11, page.lastPlaylistIndex)
    }

    @Test
    fun explicitMaximumIntIndexDoesNotOverflowFollowingFallbackRow() {
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[${playlistVideoRow("jNQXAC9IVRw", "Huge Position", Int.MAX_VALUE)},${playlistVideoRowWithoutIndex("dQw4w9WgXcQ", "Following Row")}]}""",
            "PL1234567890",
        )

        assertEquals(listOf(1, 2), page.items.map(LinkImportCandidate::playlistIndex))
    }

    @Test
    fun unavailableRendererKeepsItsExplicitProviderPosition() {
        val page = YouTubePlaylistParser.parsePayload(
            """{"contents":[${playlistVideoRow("jNQXAC9IVRw", "First Song", 1)},${unavailablePlaylistVideoRow("Unavailable", 10)},${playlistVideoRow("dQw4w9WgXcQ", "Later Song", 11)}]}""",
            "PL1234567890",
        )

        assertEquals(listOf(1, 11), page.items.map(LinkImportCandidate::playlistIndex))
        assertEquals(listOf(10), page.skippedItems.map(LinkImportSkippedItem::position))
        assertEquals(11, page.lastPlaylistIndex)
    }

    @Test
    fun playlistItemLimitTracksInitialOverflowAndExactBoundary() {
        val items = (0..YouTubePlaylistLimitPolicy.MAX_ITEMS).map { index -> candidate("video-$index") }

        val result = YouTubePlaylistLimitPolicy.takeInitial(items)

        assertEquals(YouTubePlaylistLimitPolicy.MAX_ITEMS, result.items.size)
        assertTrue(result.overflowed)
        assertFalse(
            YouTubePlaylistLimitPolicy.takeInitial(items.take(YouTubePlaylistLimitPolicy.MAX_ITEMS)).overflowed,
        )
    }

    @Test
    fun playlistItemLimitCountsRepeatedRowsAgainstRemainingCapacity() {
        val existing = (0 until YouTubePlaylistLimitPolicy.MAX_ITEMS - 1)
            .map { index -> candidate("existing-$index") }
        val incoming = listOf(
            existing.first(),
            candidate("new-at-limit"),
            candidate("new-beyond-limit"),
        )

        val result = YouTubePlaylistLimitPolicy.append(existing, incoming)

        assertEquals(listOf(existing.first().videoID), result.items.map(LinkImportCandidate::videoID))
        assertTrue(result.overflowed)
    }

    @Test
    fun remainingContinuationMarksPlaylistAsIncomplete() {
        assertTrue(YouTubePlaylistLimitPolicy.hasRemainingContinuation("next"))
        assertFalse(YouTubePlaylistLimitPolicy.hasRemainingContinuation(null))
    }

    private fun candidate(videoID: String): LinkImportCandidate = LinkImportCandidate(
        videoID = videoID,
        title = videoID,
        artist = "Artist",
        durationSeconds = 60,
        thumbnailURL = null,
        sourceURL = "https://www.youtube.com/watch?v=$videoID",
        score = 1.0,
    )

    private fun playlistVideoRow(videoID: String, title: String, index: Int): String = """
        {"playlistVideoRenderer":{
          "videoId":"$videoID",
          "title":{"simpleText":"$title"},
          "shortBylineText":{"simpleText":"Artist"},
          "index":{"simpleText":"$index"},
          "isPlayable":true
        }}
    """.trimIndent()

    private fun playlistVideoRowWithoutIndex(videoID: String, title: String): String = """
        {"playlistVideoRenderer":{
          "videoId":"$videoID",
          "title":{"simpleText":"$title"},
          "shortBylineText":{"simpleText":"Artist"},
          "isPlayable":true
        }}
    """.trimIndent()

    private fun unavailablePlaylistVideoRow(title: String, index: Int): String = """
        {"playlistVideoRenderer":{
          "videoId":"invalid",
          "title":{"simpleText":"$title"},
          "index":{"simpleText":"$index"},
          "isPlayable":false
        }}
    """.trimIndent()

    private fun lockupRow(videoID: String, title: String, artist: String): String = """
        {"lockupViewModel":{
          "contentId":"$videoID",
          "contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
          "metadata":{"lockupMetadataViewModel":{
            "title":{"content":"$title"},
            "metadata":{"contentMetadataViewModel":{
              "metadataRows":[{"metadataParts":[{"text":{"content":"$artist"}}]}]
            }}
          }}
        }}
    """.trimIndent()

    private fun lockupRowWithArtwork(videoID: String, title: String, artist: String): String = """
        {"lockupViewModel":{
          "contentId":"$videoID",
          "contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
          "contentImage":{"thumbnailViewModel":{
            "image":{"sources":[{"url":"https://i.ytimg.com/vi/$videoID/hqdefault.jpg","width":480}]}
          }},
          "metadata":{"lockupMetadataViewModel":{
            "title":{"content":"$title"},
            "metadata":{"contentMetadataViewModel":{
              "metadataRows":[{"metadataParts":[{"text":{"content":"$artist"}}]}]
            }}
          }}
        }}
    """.trimIndent()

    private fun invalidLockupRow(): String = """
        {"lockupViewModel":{
          "contentId":"invalid",
          "contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
          "metadata":{"lockupMetadataViewModel":{"title":{"content":"Unavailable"}}}
        }}
    """.trimIndent()
}
