package mov.unblocked.resonance.ui

import java.net.HttpURLConnection
import java.net.URL
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileImageFetchTest {
    private val serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"

    @Test
    fun profileImageRedirectsAreManualAndRevalidated() {
        val opened = mutableListOf<FakeConnection>()
        val result = loadProfileImageBytes(
            serverURL = serverURL,
            imageURL = "$serverURL/profile.jpg",
            connectionFactory = { url ->
                FakeConnection(
                    url,
                    HttpURLConnection.HTTP_MOVED_TEMP,
                    "https://evil.example/profile.jpg",
                ).also(opened::add)
            },
        )

        assertNull(result)
        assertEquals(1, opened.size)
        assertFalse(opened.single().instanceFollowRedirects)
        assertTrue(opened.single().disconnected)
    }

    @Test
    fun profileImageDoesNotOpenUnapprovedInitialHost() {
        var opened = 0
        val result = loadProfileImageBytes(
            serverURL = serverURL,
            imageURL = "https://evil.example/profile.jpg",
            connectionFactory = { url ->
                opened += 1
                FakeConnection(url, HttpURLConnection.HTTP_OK, null)
            },
        )

        assertNull(result)
        assertEquals(0, opened)
    }

    private class FakeConnection(
        url: URL,
        private val status: Int,
        private val location: String?,
    ) : HttpURLConnection(url) {
        var disconnected = false
            private set

        override fun connect() = Unit
        override fun disconnect() { disconnected = true }
        override fun usingProxy(): Boolean = false
        override fun getResponseCode(): Int = status
        override fun getHeaderField(name: String?): String? =
            if (name.equals("Location", ignoreCase = true)) location else null
    }
}
