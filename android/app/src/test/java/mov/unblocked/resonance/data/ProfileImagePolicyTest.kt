package mov.unblocked.resonance.data

import java.net.URL
import java.io.ByteArrayInputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileImagePolicyTest {
    private val serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"

    @Test
    fun profileImagesAllowOnlyServerOrClerkHTTPSHosts() {
        assertEqualsURL(
            "https://resonance-core.blithe-haven-9710.chatgpt.site/profile.jpg",
            ProfileImageNetworkPolicy.resolveURL(serverURL, "/profile.jpg"),
        )
        assertEqualsURL(
            "https://images.clerk.dev/user/profile.jpg",
            ProfileImageNetworkPolicy.resolveURL(serverURL, "https://images.clerk.dev/user/profile.jpg"),
        )
        assertEqualsURL(
            "https://img.clerk.com/user/profile.jpg",
            ProfileImageNetworkPolicy.resolveURL(serverURL, "https://img.clerk.com/user/profile.jpg"),
        )
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "http://images.clerk.dev/user/profile.jpg"))
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "https://images.clerk.dev:8443/user/profile.jpg"))
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "https://user:secret@images.clerk.dev/user/profile.jpg"))
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "https://images.clerk.dev/user/profile.jpg#fragment"))
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "https://127.0.0.1/profile.jpg"))
        assertNull(ProfileImageNetworkPolicy.resolveURL(serverURL, "https://evil.example/profile.jpg"))
    }

    @Test
    fun profileImageRedirectsAreRevalidated() {
        val current = URL("$serverURL/profile.jpg")
        assertNotNull(
            ProfileImageNetworkPolicy.resolveRedirect(
                serverURL,
                current,
                "https://images.clerk.dev/user/profile.jpg",
            ),
        )
        assertNull(
            ProfileImageNetworkPolicy.resolveRedirect(serverURL, current, "https://evil.example/profile.jpg"),
        )
        assertNull(
            ProfileImageNetworkPolicy.resolveRedirect(serverURL, current, "http://127.0.0.1/profile.jpg"),
        )
    }

    @Test
    fun encodedProfileImageBytesAreBoundedBeforeDecode() {
        val small = byteArrayOf(1, 2, 3)
        assertArrayEquals(small, ProfileImagePayloadPolicy.readBoundedBytes(ByteArrayInputStream(small)))
        val oversized = ByteArray((ProfileImagePayloadPolicy.MAX_BYTES + 1L).toInt())
        assertNull(ProfileImagePayloadPolicy.readBoundedBytes(ByteArrayInputStream(oversized)))
        assertFalse(ProfileImagePayloadPolicy.hasSafeDecodedBounds(small))
        assertTrue(ProfileImagePayloadPolicy.MAX_DECODED_PIXELS > 0L)
    }

    private fun assertEqualsURL(expected: String, actual: URL?) {
        assertEquals(expected, actual?.toString())
    }
}
