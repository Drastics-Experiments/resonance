package mov.unblocked.resonance.data

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaylistDownloadOutcomePolicyTest {
    private data class Row(val videoID: String, val playlistIndex: Int)

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
}
