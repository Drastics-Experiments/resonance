package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.LinkImportCandidate
import mov.unblocked.resonance.data.LinkImportResolution
import mov.unblocked.resonance.data.LinkImportPlaylist
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.LinkImportTrack
import mov.unblocked.resonance.data.LinkImportMediaMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class LinkImportUiStateTest {
    @Test
    fun editingResolvedSourceFromAToBInvalidatesStaleResolutionAndSelection() {
        val sourceA = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
        val candidate = LinkImportCandidate(
            videoID = "jNQXAC9IVRw",
            title = "A",
            artist = "Artist A",
            durationSeconds = 10,
            thumbnailURL = null,
            sourceURL = sourceA,
            score = 1.0,
        )
        val state = LinkImportUiState(
            mediaMode = LinkImportMediaMode.Video,
            requestedSource = sourceA,
            stage = LinkImportStage.AwaitingSelection,
            resolution = LinkImportResolution(
                track = LinkImportTrack(title = "A", artist = "Artist A", sourceURL = sourceA),
                candidates = listOf(candidate),
            ),
            selectedVideoId = candidate.videoID,
            selectedVideoIds = setOf(candidate.videoID),
            previewingVideoId = candidate.videoID,
        )

        val invalidated = state.invalidatedForSourceEdit(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        )

        assertEquals(LinkImportStage.Idle, invalidated.stage)
        assertNull(invalidated.requestedSource)
        assertNull(invalidated.resolution)
        assertNull(invalidated.selectedVideoId)
        assertTrue(invalidated.selectedVideoIds.isEmpty())
        assertNull(invalidated.previewingVideoId)
        assertEquals(LinkImportMediaMode.Video, invalidated.mediaMode)
    }

    @Test
    fun whitespaceOnlyEditKeepsResolutionBoundToSameSource() {
        val state = LinkImportUiState(
            requestedSource = "https://www.youtube.com/watch?v=jNQXAC9IVRw",
            stage = LinkImportStage.AwaitingSelection,
        )

        assertSame(
            state,
            state.invalidatedForSourceEdit("  https://www.youtube.com/watch?v=jNQXAC9IVRw  "),
        )
    }

    @Test
    fun playlistTruncationNoticeOnlyAppearsForBoundedResolutions() {
        val playlist = LinkImportPlaylist(
            id = "PL1234567890",
            title = "Long playlist",
            author = "Artist",
            artworkURL = null,
            sourceURL = "https://www.youtube.com/playlist?list=PL1234567890",
            skippedItems = emptyList(),
        )

        assertNull(linkImportPlaylistTruncationNotice(playlist))
        assertEquals(
            "Only part of this playlist could be loaded. Resonance shows at most 500 playable videos across 10 continuation pages, and only the visible items can be selected.",
            linkImportPlaylistTruncationNotice(playlist.copy(truncated = true)),
        )
    }
}
