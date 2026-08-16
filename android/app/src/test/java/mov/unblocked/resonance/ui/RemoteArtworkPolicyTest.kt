package mov.unblocked.resonance.ui

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL

class RemoteArtworkPolicyTest {
    @Test
    fun artworkURLsAreResolvedThroughTheSharedNetworkPolicy() {
        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/song-1/artwork",
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "/api/v1/songs/song-1/artwork",
                allowCleartextDevelopment = false,
            ),
        )
        assertEquals(
            "https://i.ytimg.com/cover.jpg",
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "https://i.ytimg.com/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )

        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "http://cdn.example/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "https://user:secret@cdn.example/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "https://cdn.example/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "https://127.0.0.1/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                artworkURL = "https://i.ytimg.com:8443/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
    }

    @Test
    fun cleartextArtworkIsOnlyAvailableForExplicitDebugLocalHosts() {
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "http://10.0.2.2:8787",
                artworkURL = "/cover.jpg",
                allowCleartextDevelopment = false,
            ),
        )
        assertEquals(
            "http://10.0.2.2:8787/cover.jpg",
            resolveRemoteArtworkURL(
                serverURL = "http://10.0.2.2:8787",
                artworkURL = "/cover.jpg",
                allowCleartextDevelopment = true,
            ),
        )
        assertNull(
            resolveRemoteArtworkURL(
                serverURL = "http://192.168.1.25:8787",
                artworkURL = "/cover.jpg",
                allowCleartextDevelopment = true,
            ),
        )
    }

    @Test
    fun artworkFetchHandlesRedirectsManuallyWithoutAuthorization() {
        val openedConnections = mutableListOf<FakeHttpConnection>()
        val payload = byteArrayOf(1, 2, 3, 4)
        val responses = ArrayDeque(
            listOf(
                FakeResponse(
                    status = HttpURLConnection.HTTP_MOVED_TEMP,
                    location = "https://i.ytimg.com/final-cover.jpg",
                ),
                FakeResponse(
                    status = HttpURLConnection.HTTP_OK,
                    body = payload,
                ),
            ),
        )

        val result = loadRemoteArtworkBytes(
            serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
            url = "https://resonance-core.blithe-haven-9710.chatgpt.site/cover.jpg",
            allowCleartextDevelopment = false,
            connectionFactory = { url ->
                FakeHttpConnection(url, responses.removeFirst()).also(openedConnections::add)
            },
        )

        assertArrayEquals(payload, result)
        assertEquals(
            listOf(
                "https://resonance-core.blithe-haven-9710.chatgpt.site/cover.jpg",
                "https://i.ytimg.com/final-cover.jpg",
            ),
            openedConnections.map { it.url.toString() },
        )
        openedConnections.forEach { connection ->
            assertFalse(connection.instanceFollowRedirects)
            assertNull(connection.requestHeaders["Authorization"])
            assertEquals("image/*", connection.requestHeaders["Accept"])
            assertTrue(connection.disconnected)
        }
    }

    @Test
    fun artworkFetchRejectsAnInsecureRedirectBeforeOpeningIt() {
        val openedConnections = mutableListOf<FakeHttpConnection>()

        val result = loadRemoteArtworkBytes(
            serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
            url = "https://resonance-core.blithe-haven-9710.chatgpt.site/cover.jpg",
            allowCleartextDevelopment = false,
            connectionFactory = { url ->
                FakeHttpConnection(
                    url,
                    FakeResponse(
                        status = HttpURLConnection.HTTP_MOVED_TEMP,
                        location = "http://cdn.example/cover.jpg",
                    ),
                ).also(openedConnections::add)
            },
        )

        assertNull(result)
        assertEquals(1, openedConnections.size)
        assertTrue(openedConnections.single().disconnected)
    }

    @Test
    fun artworkResponsesAreBoundedWithAndWithoutContentLength() {
        val payload = byteArrayOf(1, 2, 3, 4)
        assertArrayEquals(
            payload,
            readRemoteArtworkBytes(ByteArrayInputStream(payload), maxBytes = payload.size.toLong()),
        )
        assertNull(
            readRemoteArtworkBytes(ByteArrayInputStream(payload), maxBytes = payload.size.toLong() - 1L),
        )

        val oversized = FakeHttpConnection(
            URL("https://resonance-core.blithe-haven-9710.chatgpt.site/cover.jpg"),
            FakeResponse(
                status = HttpURLConnection.HTTP_OK,
                body = payload,
                declaredBytes = MAX_REMOTE_ARTWORK_BYTES + 1L,
            ),
        )
        assertNull(
            loadRemoteArtworkBytes(
                serverURL = "https://resonance-core.blithe-haven-9710.chatgpt.site",
                url = "https://resonance-core.blithe-haven-9710.chatgpt.site/cover.jpg",
                allowCleartextDevelopment = false,
                connectionFactory = { oversized },
            ),
        )
        assertFalse(oversized.inputOpened)
        assertTrue(oversized.disconnected)
    }

    private data class FakeResponse(
        val status: Int,
        val body: ByteArray = ByteArray(0),
        val location: String? = null,
        val declaredBytes: Long = body.size.toLong(),
    )

    private class FakeHttpConnection(
        url: URL,
        private val response: FakeResponse,
    ) : HttpURLConnection(url) {
        val requestHeaders = mutableMapOf<String, String>()
        var disconnected = false
            private set
        var inputOpened = false
            private set

        override fun connect() = Unit

        override fun disconnect() {
            disconnected = true
        }

        override fun usingProxy(): Boolean = false

        override fun getResponseCode(): Int = response.status

        override fun getHeaderField(name: String?): String? =
            if (name.equals("Location", ignoreCase = true)) response.location else null

        override fun getContentLengthLong(): Long = response.declaredBytes

        override fun getInputStream(): InputStream {
            inputOpened = true
            return ByteArrayInputStream(response.body)
        }

        override fun setRequestProperty(key: String, value: String) {
            requestHeaders[key] = value
        }

        override fun getRequestProperty(key: String): String? = requestHeaders[key]
    }
}
