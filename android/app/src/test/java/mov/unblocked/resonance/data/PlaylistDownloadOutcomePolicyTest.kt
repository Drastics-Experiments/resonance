package mov.unblocked.resonance.data

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaylistDownloadOutcomePolicyTest {
    private data class Row(val videoID: String, val playlistIndex: Int)

    @Test
    fun reportsCompletedOutcomeBeforeLaterCancellation() = runTest {
        val selected = listOf(Row("video-a", 1), Row("video-b", 2))
        val loaderCalls = mutableListOf<String>()
        val completed = mutableListOf<PlaylistDownloadOutcome<String, String>>()

        val attempted = runCatching {
            PlaylistDownloadOutcomePolicy.loadDistinct(
                selected = selected,
                key = Row::videoID,
                onOutcome = completed::add,
            ) { row ->
                loaderCalls += row.videoID
                if (row.videoID == "video-a") {
                    Result.success("track-a")
                } else {
                    throw kotlinx.coroutines.CancellationException("cancel after first download")
                }
            }
        }

        assertTrue(attempted.isFailure)
        assertEquals(listOf("video-a", "video-b"), loaderCalls)
        assertEquals(listOf("video-a"), completed.map(PlaylistDownloadOutcome<String, String>::key))
        assertEquals("track-a", completed.single().result.getOrNull())
    }

    @Test
    fun cachesFailedVideoOutcomeAndKeepsRepeatedRowsMappedToTheSameVideo() = runTest {
        val selected = listOf(
            Row(videoID = "video-a", playlistIndex = 1),
            Row(videoID = "video-a", playlistIndex = 3),
            Row(videoID = "video-b", playlistIndex = 4),
        )
        val calls = mutableListOf<String>()

        val outcomes = PlaylistDownloadOutcomePolicy.loadDistinct(
            selected = selected,
            key = Row::videoID,
        ) { row ->
            calls += row.videoID
            if (row.videoID == "video-a") {
                Result.failure(IllegalStateException("forced failure"))
            } else {
                Result.success("track-b")
            }
        }

        assertEquals(listOf("video-a", "video-b"), calls)
        assertEquals(listOf("video-a", "video-b"), outcomes.map(PlaylistDownloadOutcome<String, String>::key))
        assertTrue(outcomes.first().result.isFailure)

        val outcomesByVideoID = outcomes.associateBy(PlaylistDownloadOutcome<String, String>::key)
        assertEquals(
            listOf("video-a", "video-a", "video-b"),
            selected.map { outcomesByVideoID.getValue(it.videoID).key },
        )
    }

    @Test
    fun doesNotCollapseDistinctNonYouTubeMetadataRowsSharingYouTubeCandidate() = runTest {
        val selected = listOf(
            candidate(
                videoID = "shared-youtube-id",
                sourceURL = "https://open.spotify.com/track/spotify-row",
            ),
            candidate(
                videoID = "shared-youtube-id",
                sourceURL = "https://soundcloud.com/artist/soundcloud-row",
            ),
        )
        val calls = mutableListOf<String>()

        val outcomes = PlaylistDownloadOutcomePolicy.loadDistinct(
            selected = selected,
            key = LinkImportCandidate::playlistDownloadKey,
        ) { row ->
            calls += requireNotNull(row.importTrack).sourceURL
            Result.success(row.sourceURL)
        }

        assertEquals(
            listOf(
                "https://open.spotify.com/track/spotify-row",
                "https://soundcloud.com/artist/soundcloud-row",
            ),
            calls,
        )
        assertEquals(2, outcomes.size)
    }

    @Test
    fun deduplicatesRepeatedYouTubeRowsButKeepsProviderFallbackChainsIndependent() = runTest {
        val repeatedYouTube = listOf(
            candidate(
                videoID = "youtube-row",
                sourceURL = "https://www.youtube.com/watch?v=youtube-row",
            ),
            candidate(
                videoID = "youtube-row",
                sourceURL = "https://www.youtube.com/watch?v=youtube-row",
            ),
        )
        val spotify = candidate(
            videoID = "shared-youtube-id",
            sourceURL = "https://open.spotify.com/track/spotify-row",
            fallbackCandidates = listOf(candidate("spotify-fallback", "https://www.youtube.com/watch?v=spotify-fallback")),
        )
        val soundCloud = candidate(
            videoID = "shared-youtube-id",
            sourceURL = "https://soundcloud.com/artist/soundcloud-row",
            fallbackCandidates = listOf(candidate("soundcloud-fallback", "https://www.youtube.com/watch?v=soundcloud-fallback")),
        )
        val selected = repeatedYouTube + listOf(spotify, soundCloud)
        val calls = mutableListOf<String>()

        val outcomes = PlaylistDownloadOutcomePolicy.loadDistinct(
            selected = selected,
            key = LinkImportCandidate::playlistDownloadKey,
        ) { row ->
            calls += requireNotNull(row.importTrack).sourceURL
            val playableIDs = setOf("youtube-row", "soundcloud-fallback")
            (listOf(row) + row.fallbackCandidates)
                .firstOrNull { it.videoID in playableIDs }
                ?.let { Result.success(it.videoID) }
                ?: Result.failure(IllegalStateException("no playable candidate"))
        }

        assertEquals(
            listOf(
                "https://www.youtube.com/watch?v=youtube-row",
                "https://open.spotify.com/track/spotify-row",
                "https://soundcloud.com/artist/soundcloud-row",
            ),
            calls,
        )
        assertEquals(3, outcomes.size)
        assertEquals("youtube-row", outcomes[0].result.getOrNull())
        assertTrue(outcomes[1].result.isFailure)
        assertEquals("soundcloud-fallback", outcomes[2].result.getOrNull())
    }

    private fun candidate(
        videoID: String,
        sourceURL: String,
        fallbackCandidates: List<LinkImportCandidate> = emptyList(),
    ): LinkImportCandidate {
        val metadata = LinkImportTrack(
            title = sourceURL,
            artist = "Artist",
            sourceURL = sourceURL,
        )
        return LinkImportCandidate(
            videoID = videoID,
            title = metadata.title,
            artist = metadata.artist,
            durationSeconds = null,
            thumbnailURL = null,
            sourceURL = "https://www.youtube.com/watch?v=$videoID",
            score = 1.0,
            importTrack = metadata,
            playlistIndex = 1,
            fallbackCandidates = fallbackCandidates,
        )
    }
}
