package mov.unblocked.resonance.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class ArtworkDecodePolicyTest {
    @Test
    fun imagesAtOrBelowTheDecodeLimitAreNotDownsampled() {
        assertEquals(1, artworkSampleSize(1_024, 768))
    }

    @Test
    fun largeArtworkUsesPowerOfTwoSampling() {
        assertEquals(4, artworkSampleSize(4_096, 2_048))
        assertEquals(8, artworkSampleSize(8_192, 1_024))
    }
}
