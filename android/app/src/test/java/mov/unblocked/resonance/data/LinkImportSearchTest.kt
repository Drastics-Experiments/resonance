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
    fun requestsDesktopProviderDocumentsForSearch() {
        val userAgent = LinkImportSearchRequestPolicy.USER_AGENT
        assertTrue(userAgent.contains("Macintosh"))
        assertTrue(userAgent.contains("Chrome/"))
        assertFalse(userAgent.contains("Android"))
        assertFalse(userAgent.contains(" Mobile "))
    }

    @Test
    fun reviewedUploadAcceptsOnlySpotifyTracksAndIndividualYouTubeVideos() {
        assertTrue(
            LinkImportInput.isReviewedTrackLink(
                "https://open.spotify.com/track/4PTG3Z6ehGkBFwjybzWkR8?si=test",
            ),
        )
        assertTrue(
            LinkImportInput.isReviewedTrackLink(
                "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            ),
        )
        assertTrue(LinkImportInput.isReviewedTrackLink("https://youtu.be/jNQXAC9IVRw"))

        assertFalse(LinkImportInput.isReviewedTrackLink("Test Song Test Artist"))
        assertFalse(LinkImportInput.isReviewedTrackLink("https://soundcloud.com/artist/song"))
        assertFalse(
            LinkImportInput.isReviewedTrackLink(
                "https://open.spotify.com/playlist/4PTG3Z6ehGkBFwjybzWkR8",
            ),
        )
        assertFalse(
            LinkImportInput.isReviewedTrackLink(
                "https://www.youtube.com/watch?v=jNQXAC9IVRw&list=PL123",
            ),
        )
        assertFalse(LinkImportInput.isReviewedTrackLink("http://youtu.be/jNQXAC9IVRw"))
    }

    @Test
    fun bindsExactLocalYoutubeCandidateForFreshExplicitReviewedSelection() {
        val candidate = LinkImportCandidate(
            videoID = "jNQXAC9IVRw",
            title = "Me at the zoo",
            artist = "jawed",
            durationSeconds = 19,
            thumbnailURL = null,
            sourceURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            score = 1.0,
            fallbackCandidates = listOf(
                LinkImportCandidate(
                    videoID = "dQw4w9WgXcQ",
                    title = "Fallback",
                    artist = null,
                    durationSeconds = null,
                    thumbnailURL = null,
                    sourceURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    score = .5,
                ),
            ),
        )
        val resolution = LinkImportResolution(
            track = LinkImportTrack(
                title = candidate.title,
                artist = candidate.artist.orEmpty(),
                sourceURL = candidate.sourceURL,
            ),
            candidates = listOf(candidate),
        )

        val bound = ReviewedMatchResolutionPolicy.bindLocalYouTubeCandidate(
            "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            resolution,
        )
        assertTrue(bound?.reviewedMatchPolicyBound == true)
        assertEquals("jNQXAC9IVRw", bound?.candidates?.single()?.videoID)
        assertTrue(bound?.candidates?.single()?.fallbackCandidates?.isEmpty() == true)
        assertEquals(
            null,
            ReviewedMatchResolutionPolicy.bindLocalYouTubeCandidate(
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                resolution,
            ),
        )
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
