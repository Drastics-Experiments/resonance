package mov.unblocked.resonance.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.net.URL
import java.nio.file.Files

class ServerNetworkIntegrityPolicyTest {
    @Test
    fun productionServerURLsRequireHTTPS() {
        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site",
            ServerClient.normalizeServerURL(" https://resonance-core.blithe-haven-9710.chatgpt.site/ "),
        )
        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site",
            ServerClient.normalizeServerURL("https://music.unblocked.mov"),
        )

        expectFailure<IllegalArgumentException>("must use HTTPS") {
            ServerClient.normalizeServerURL("http://music.unblocked.mov")
        }
        expectFailure<IllegalArgumentException>("must use HTTPS") {
            ServerClient.normalizeServerURL("http://192.168.1.20:8787")
        }
    }

    @Test
    fun cleartextIsLimitedToExplicitDevelopmentHosts() {
        val developmentURLs = listOf(
            "http://localhost:8787",
            "http://127.0.0.1:8787",
            "http://10.0.2.2:8787",
        )

        developmentURLs.forEach { value ->
            assertEquals(
                value,
                ServerClient.normalizeServerURL(value, allowCleartextDevelopment = true),
            )
        }
        expectFailure<IllegalArgumentException>("must use HTTPS") {
            ServerClient.normalizeServerURL(
                "http://127.0.0.2:8787",
                allowCleartextDevelopment = true,
            )
        }
        expectFailure<IllegalArgumentException>("must use HTTPS") {
            ServerClient.normalizeServerURL(
                "http://127.0.0.1:8787",
                allowCleartextDevelopment = false,
            )
        }
        expectFailure<IllegalArgumentException>("must use HTTPS") {
            ServerClient(
                serverURL = "http://127.0.0.1:8787",
                accessToken = "test-token",
                allowCleartextDevelopment = false,
            )
        }
    }

    @Test
    fun authorizedMediaURLsMustStayOnTheConfiguredOrigin() {
        val baseURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"

        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/song-1/download",
            ServerNetworkPolicy.resolveAuthorizedMediaURL(
                baseURL,
                "/api/v1/songs/song-1/download",
            ).toString(),
        )
        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site:443/file/song-1",
            ServerNetworkPolicy.resolveAuthorizedMediaURL(
                baseURL,
                "https://resonance-core.blithe-haven-9710.chatgpt.site:443/file/song-1",
            ).toString(),
        )

        expectFailure<IllegalArgumentException>("configured server origin") {
            ServerNetworkPolicy.resolveAuthorizedMediaURL(
                baseURL,
                "https://attacker.example/collect-token",
            )
        }
        expectFailure<IllegalArgumentException>("configured server origin") {
            ServerNetworkPolicy.resolveAuthorizedMediaURL(
                baseURL,
                "http://music.unblocked.mov/file/song-1",
            )
        }
    }

    @Test
    fun redirectsCannotLeaveTheOriginOrDowngradeHTTPS() {
        val baseURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"
        val current = URL("https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/songs/song-1/download")

        assertEquals(
            "https://resonance-core.blithe-haven-9710.chatgpt.site/api/v1/file/song-1",
            ServerNetworkPolicy.resolveAuthorizedRedirect(
                baseURL,
                current,
                "../../file/song-1",
            ).toString(),
        )
        expectFailure<IOException>("left the configured server origin") {
            ServerNetworkPolicy.resolveAuthorizedRedirect(
                baseURL,
                current,
                "https://cdn.example/song-1.mp3",
            )
        }
        expectFailure<IOException>("left the configured server origin") {
            ServerNetworkPolicy.resolveAuthorizedRedirect(
                baseURL,
                current,
                "http://music.unblocked.mov/file/song-1",
            )
        }
    }

    @Test
    fun integrityPolicyRequiresAndVerifiesCatalogSHA256() {
        val sha256 = "a".repeat(64)
        val requirements = DownloadIntegrityPolicy.requirements(
            catalogBytes = 1_024L,
            contentSHA256 = sha256.uppercase(),
        )
        val expectations = DownloadIntegrityPolicy.withResponseLength(
            requirements,
            responseBytes = 1_024L,
        )

        assertEquals(sha256, requirements.expectedSHA256)
        assertEquals(1_024L, expectations.expectedBytes ?: -1L)
        assertEquals(
            sha256,
            DownloadIntegrityPolicy.verify(
                expectations,
                actualBytes = 1_024L,
                actualSHA256 = sha256,
                filename = "Song.mp3",
            ),
        )

        expectFailure<IOException>("valid SHA-256") {
            DownloadIntegrityPolicy.requirements(1_024L, null)
        }
        expectFailure<IOException>("does not match") {
            DownloadIntegrityPolicy.verify(
                expectations,
                actualBytes = 1_024L,
                actualSHA256 = "b".repeat(64),
                filename = "Song.mp3",
            )
        }
    }

    @Test
    fun integrityPolicyRejectsOversizeAndLengthMismatches() {
        val requirements = DownloadIntegrityPolicy.requirements(
            catalogBytes = 1_024L,
            contentSHA256 = "a".repeat(64),
        )
        assertEquals(
            DownloadIntegrityPolicy.MAX_MEDIA_BYTES,
            DownloadIntegrityPolicy.requirements(
                catalogBytes = DownloadIntegrityPolicy.MAX_MEDIA_BYTES,
                contentSHA256 = "a".repeat(64),
            ).catalogBytes,
        )

        expectFailure<IOException>("catalog download is too large") {
            DownloadIntegrityPolicy.requirements(
                catalogBytes = DownloadIntegrityPolicy.MAX_MEDIA_BYTES + 1L,
                contentSHA256 = "a".repeat(64),
            )
        }
        expectFailure<IOException>("does not match") {
            DownloadIntegrityPolicy.withResponseLength(requirements, responseBytes = 2_048L)
        }
        expectFailure<IOException>("ended before") {
            DownloadIntegrityPolicy.verify(
                DownloadIntegrityPolicy.withResponseLength(requirements, responseBytes = 1_024L),
                actualBytes = 1_023L,
                actualSHA256 = "a".repeat(64),
                filename = "Song.mp3",
            )
        }
    }

    @Test
    fun knownLengthIsEnforcedBeforeAnOversizedChunkIsAccepted() {
        val expectations = DownloadExpectations(
            expectedSHA256 = "a".repeat(64),
            expectedBytes = 1_024L,
        )

        assertEquals(
            1_024L,
            DownloadIntegrityPolicy.checkedTotalBytes(
                expectations = expectations,
                currentBytes = 1_000L,
                incomingBytes = 24,
                filename = "Song.mp3",
            ),
        )
        expectFailure<IOException>("exceeded the expected") {
            DownloadIntegrityPolicy.checkedTotalBytes(
                expectations = expectations,
                currentBytes = 1_000L,
                incomingBytes = 25,
                filename = "Song.mp3",
            )
        }
        expectFailure<IOException>("maximum download size") {
            DownloadIntegrityPolicy.checkedTotalBytes(
                expectations = expectations.copy(expectedBytes = null),
                currentBytes = DownloadIntegrityPolicy.MAX_MEDIA_BYTES,
                incomingBytes = 1,
                filename = "Song.mp3",
            )
        }
    }

    @Test
    fun leaseExpiringAfterValidationRejectsAdoptionAndDeletesStaging() {
        val directory = Files.createTempDirectory("resonance-adoption-test")
        val staging = directory.resolve("verified.staging").toFile()
        val destination = directory.resolve("song.mp3").toFile()
        try {
            staging.writeBytes("verified audio bytes".toByteArray())
            val expiresAt = 100L
            var now = expiresAt - 1L
            assertTrue("lease is active while integrity validation finishes", now < expiresAt)

            // Deterministically expire the captured lease between validation
            // and the final adoption authorization.
            now = expiresAt
            expectFailure<IOException>("expired") {
                DownloadAdoptionPolicy.authorizeAndMove(staging, destination) {
                    if (now >= expiresAt) throw IOException("download lease expired")
                }
            }

            assertFalse("expired staging bytes must be deleted", staging.exists())
            assertFalse("expired bytes must not enter the library", destination.exists())
        } finally {
            staging.delete()
            destination.delete()
            directory.toFile().delete()
        }
    }

    private inline fun <reified T : Throwable> expectFailure(
        messageFragment: String,
        block: () -> Unit,
    ): T {
        val thrown = try {
            block()
            fail("Expected ${T::class.java.simpleName}")
            throw AssertionError("unreachable")
        } catch (error: Throwable) {
            error
        }
        assertTrue(
            "Expected ${T::class.java.simpleName}, got ${thrown::class.java.simpleName}",
            thrown is T,
        )
        assertTrue(
            "Expected message containing '$messageFragment', got '${thrown.message}'",
            thrown.message.orEmpty().contains(messageFragment),
        )
        @Suppress("UNCHECKED_CAST")
        return thrown as T
    }
}
