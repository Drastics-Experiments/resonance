package mov.unblocked.resonance.data

import java.net.URL
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteURLPolicyTest {
    private val youtubeHosts = setOf("www.youtube.com", "music.youtube.com")

    @Test
    fun providerURLPolicyAllowsApprovedHTTPSOnly() {
        assertTrue(isApproved("https://www.youtube.com/youtubei/v1/player"))
        assertTrue(isApproved("https://music.youtube.com/results"))
        assertFalse(isApproved("http://www.youtube.com/results"))
        assertFalse(isApproved("https://www.youtube.com:8443/results"))
        assertFalse(isApproved("https://user:secret@www.youtube.com/results"))
        assertFalse(isApproved("https://127.0.0.1/results"))
        assertFalse(isApproved("https://evil.example/results"))
    }

    @Test
    fun redirectResolutionRevalidatesEveryDestination() {
        val current = URL("https://www.youtube.com/results")

        assertNotNull(
            RemoteURLPolicy.resolveRedirect(
                current,
                "https://music.youtube.com/watch?v=jNQXAC9IVRw",
                approvedHost = { it in youtubeHosts },
            ),
        )
        assertNull(
            RemoteURLPolicy.resolveRedirect(
                current,
                "https://evil.example/collect",
                approvedHost = { it in youtubeHosts },
            ),
        )
        assertNull(
            RemoteURLPolicy.resolveRedirect(
                current,
                "http://127.0.0.1/collect",
                approvedHost = { it in youtubeHosts },
            ),
        )
        assertNull(
            RemoteURLPolicy.resolveRedirect(
                current,
                "https://user:secret@music.youtube.com/collect",
                approvedHost = { it in youtubeHosts },
            ),
        )
    }

    private fun isApproved(value: String): Boolean = RemoteURLPolicy.isSafeURL(
        URL(value),
        approvedHost = { it in youtubeHosts },
    )
}
