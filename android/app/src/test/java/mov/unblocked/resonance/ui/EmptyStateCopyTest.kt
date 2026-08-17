package mov.unblocked.resonance.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class EmptyStateCopyTest {
    @Test
    fun songCountsUseNaturalSingularAndPluralCopy() {
        assertEquals("0 songs", songCountLabel(0))
        assertEquals("1 song", songCountLabel(1))
        assertEquals("2 songs", songCountLabel(2))
    }

    @Test
    fun librarySearchHasAResultSpecificEmptyState() {
        assertEquals(
            EmptyStateCopy("No results", "Try another search term."),
            libraryEmptyStateCopy(hasSongs = true),
        )
        assertEquals(
            EmptyStateCopy("No songs yet", "Import audio or video, or sync your music server."),
            libraryEmptyStateCopy(hasSongs = false),
        )
    }

    @Test
    fun storageScopesExplainTheActionThatPopulatesThem() {
        assertEquals(
            EmptyStateCopy("No stored songs", "Import audio or video, or download songs from your music server."),
            storageEmptyStateCopy(StorageScope.Songs, hasQuery = false),
        )
        assertEquals(
            EmptyStateCopy("No downloads", "Download songs from your music server to keep them on this device."),
            storageEmptyStateCopy(StorageScope.Downloads, hasQuery = false),
        )
        assertEquals(
            EmptyStateCopy("No imported files", "Import audio or video files from this device."),
            storageEmptyStateCopy(StorageScope.Files, hasQuery = false),
        )
    }

    @Test
    fun storageSearchAlwaysExplainsThatTheFilterIsEmpty() {
        for (scope in StorageScope.entries) {
            assertEquals(
                EmptyStateCopy("No results", "Try another search term."),
                storageEmptyStateCopy(scope, hasQuery = true),
            )
        }
    }
}
