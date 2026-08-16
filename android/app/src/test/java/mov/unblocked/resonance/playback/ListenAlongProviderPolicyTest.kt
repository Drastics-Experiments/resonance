package mov.unblocked.resonance.playback

import org.junit.Assert.assertTrue
import org.junit.Test

class ListenAlongProviderPolicyTest {
    @Test
    fun providerPolicyRejectsNonProviderAndCredentialBearingSources() {
        assertTrue(runCatching {
            ListenAlongProviderStreamPolicy.register("http://cdn.googlevideo.com/audio", emptyMap())
        }.isFailure)
        assertTrue(runCatching {
            ListenAlongProviderStreamPolicy.register("https://user:pass@cdn.googlevideo.com/audio", emptyMap())
        }.isFailure)
        assertTrue(
            !ListenAlongProviderStreamPolicy.areSafeHeaders(
                mapOf("Authorization" to "Bearer should-not-be-forwarded"),
            ),
        )
        assertTrue(runCatching {
            ListenAlongProviderStreamPolicy.register("https://media.example.com/audio", emptyMap())
        }.isFailure)
    }

    @Test
    fun providerPolicyAllowsOnlyApprovedProviderOrigins() {
        assertTrue(
            ListenAlongProviderStreamPolicy.isAllowedSourceURL(
                "https://r1---sn.googlevideo.com/audio",
            ),
        )
        assertTrue(
            !ListenAlongProviderStreamPolicy.isAllowedSourceURL(
                "https://media.example.com/audio",
            ),
        )
    }
}
