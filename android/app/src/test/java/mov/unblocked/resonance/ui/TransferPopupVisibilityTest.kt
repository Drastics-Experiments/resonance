package mov.unblocked.resonance.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TransferPopupVisibilityTest {
    @Test fun zeroByteDownloadPreparationIsVisibleImmediately() {
        assertTrue(shouldShowTransferPopup(
            ResonanceUiState(
                isDownloading = true,
                downloadCurrentItem = 1,
                downloadTotalItems = 12,
                downloadCurrentTitle = "Starting song",
                downloadBytesTransferred = 0L,
                downloadTotalBytes = null,
            ),
        ))
    }

    @Test fun idleStateDoesNotShowTransferPopup() {
        assertFalse(shouldShowTransferPopup(ResonanceUiState()))
    }
}
