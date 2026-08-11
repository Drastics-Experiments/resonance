package mov.unblocked.resonance.playback

import org.junit.Assert.assertEquals
import org.junit.Test

class CrossfadePolicyTest {
    @Test
    fun normalizesTheUserFacingRange() {
        assertEquals(1f, CrossfadePolicy.normalizedSeconds(-4f), 0f)
        assertEquals(12f, CrossfadePolicy.normalizedSeconds(20f), 0f)
        assertEquals(5f, CrossfadePolicy.normalizedSeconds(Float.NaN), 0f)
    }

    @Test
    fun shortSongsCannotBeConsumedByTheFade() {
        assertEquals(2_000L, CrossfadePolicy.effectiveDurationMs(12f, 4_000L, 10_000L))
        assertEquals(0L, CrossfadePolicy.effectiveDurationMs(5f, 0L, 10_000L))
    }

    @Test
    fun progressIsClamped() {
        assertEquals(0f, CrossfadePolicy.progress(5_000L, 5_000L), 0f)
        assertEquals(.5f, CrossfadePolicy.progress(2_500L, 5_000L), 0f)
        assertEquals(1f, CrossfadePolicy.progress(-1L, 5_000L), 0f)
    }
}
