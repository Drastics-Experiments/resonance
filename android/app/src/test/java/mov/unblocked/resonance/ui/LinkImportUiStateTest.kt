package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.LinkImportCandidate
import mov.unblocked.resonance.data.LinkImportResolution
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.LinkImportTrack
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
}
