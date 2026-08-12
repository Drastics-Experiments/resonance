package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PreparedMediaReusePolicyTest {
    @Test fun preparedStreamsAreScopedByMediaModeAndVideo() {
        assertEquals(
            "audio:abcdefghijk",
            PreparedMediaReusePolicy.key("abcdefghijk", LinkImportMediaMode.Audio),
        )
        assertEquals(
            "video:abcdefghijk",
            PreparedMediaReusePolicy.key("abcdefghijk", LinkImportMediaMode.Video),
        )
    }

    @Test fun preparedStreamsExpireBeforeTheirSignedURLsCanGoStale() {
        val preparedAt = 1_000L
        assertTrue(PreparedMediaReusePolicy.isFresh(preparedAt, preparedAt))
        assertTrue(
            PreparedMediaReusePolicy.isFresh(
                preparedAt,
                preparedAt + PreparedMediaReusePolicy.MaximumAgeNanos,
            ),
        )
        assertFalse(
            PreparedMediaReusePolicy.isFresh(
                preparedAt,
                preparedAt + PreparedMediaReusePolicy.MaximumAgeNanos + 1L,
            ),
        )
        assertFalse(PreparedMediaReusePolicy.isFresh(preparedAt, preparedAt - 1L))
    }
}
