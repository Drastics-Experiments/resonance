package mov.unblocked.resonance.playback

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamLeaseExpiryPolicyTest {
    private val now = Instant.parse("2026-08-06T18:00:00Z")

    @Test
    fun newlySignedEarlierExpiryShortensTheExistingLease() {
        val current = now.plusSeconds(600)
        val signed = now.plusSeconds(120)

        assertEquals(
            signed,
            StreamLeaseExpiryPolicy.authoritativeReplacement(current, signed, now),
        )
    }

    @Test
    fun newlySignedLaterOrEqualExpiryIsAlsoAuthoritative() {
        val current = now.plusSeconds(120)

        assertEquals(
            current,
            StreamLeaseExpiryPolicy.authoritativeReplacement(current, current, now),
        )
        assertEquals(
            now.plusSeconds(600),
            StreamLeaseExpiryPolicy.authoritativeReplacement(current, now.plusSeconds(600), now),
        )
    }

    @Test
    fun expiredCurrentOrSignedLeaseCannotBeRenewed() {
        assertNull(
            StreamLeaseExpiryPolicy.authoritativeReplacement(now, now.plusSeconds(60), now),
        )
        assertNull(
            StreamLeaseExpiryPolicy.authoritativeReplacement(now.plusSeconds(60), now, now),
        )
    }

    @Test
    fun proactiveRenewalShortensRetainsOrExtendsAuthoritativeDeadline() {
        val current = now.plusSeconds(300)
        val shorter = StreamLeaseUpdatePolicy.decide(
            current,
            now.plusSeconds(120),
            proactiveRenewal = true,
        )
        val equal = StreamLeaseUpdatePolicy.decide(
            current,
            current,
            proactiveRenewal = true,
        )
        val later = StreamLeaseUpdatePolicy.decide(
            current,
            now.plusSeconds(600),
            proactiveRenewal = true,
        )

        assertEquals(StreamLeaseUpdateKind.Shorten, shorter.kind)
        assertTrue(shorter.clearPendingRenewalFloor)
        assertEquals(StreamLeaseUpdateKind.Retain, equal.kind)
        assertFalse(equal.clearPendingRenewalFloor)
        assertEquals(StreamLeaseUpdateKind.Extend, later.kind)
        assertTrue(later.clearPendingRenewalFloor)
    }
}
