package mov.unblocked.resonance.update

import java.net.URL
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Test

class AndroidUpdatePolicyTest {
    @Test
    fun startupCheckBypassesRecentSuccessfulCheck() {
        assertEquals(
            true,
            AndroidUpdateCheckPolicy.shouldCheck(
                lastSuccessfulCheckMillis = 9_999L,
                nowMillis = 10_000L,
                force = true,
            ),
        )
    }

    @Test
    fun resumedChecksRemainThrottledUntilTheIntervalElapses() {
        val interval = AndroidUpdateCheckPolicy.DefaultIntervalMillis

        assertEquals(false, AndroidUpdateCheckPolicy.shouldCheck(1_000L, 1_000L + interval - 1L))
        assertEquals(true, AndroidUpdateCheckPolicy.shouldCheck(1_000L, 1_000L + interval))
        assertEquals(true, AndroidUpdateCheckPolicy.shouldCheck(0L, 1_000L))
    }

    @Test
    fun forcedDeveloperChecksBypassTheNormalResumeThrottle() {
        val interval = AndroidUpdateCheckPolicy.DefaultIntervalMillis

        assertTrue(
            AndroidUpdateCheckPolicy.shouldCheck(
                lastSuccessfulCheckMillis = 1_000L,
                nowMillis = 1_000L + interval - 1L,
                force = true,
            ),
        )
    }

    @Test
    fun clockRollbackDoesNotSuppressUpdateChecks() {
        assertEquals(true, AndroidUpdateCheckPolicy.shouldCheck(10_000L, 9_000L))
    }

    @Test
    fun newerManifestBecomesAvailableUpdate() {
        val update = AndroidUpdatePolicy.availableUpdate(
            rawManifest = manifest(versionCode = 7),
            currentVersionCode = 6,
        )

        assertEquals(7L, update?.versionCode)
        assertEquals("1.0.7", update?.versionName)
        assertEquals(SHA256.lowercase(), update?.sha256)
    }

    @Test
    fun timestampedPrereleasesUseTheExactTagAndHighestBuild() {
        val olderTag = "v1.0.7-pre.1788150123"
        val newerTag = "v1.0.7-pre.1788154123"
        val older = requireNotNull(AndroidUpdatePolicy.availableUpdate(
            rawManifest = manifest(
                versionCode = 7,
                releaseTag = olderTag,
                apkUrl = "https://github.com/Drastics-Experiments/resonance/releases/download/$olderTag/Resonance-Android-1.0.7.apk",
            ),
            currentVersionCode = 6,
            expectedReleaseTag = olderTag,
        ))
        val newer = requireNotNull(AndroidUpdatePolicy.availableUpdate(
            rawManifest = manifest(
                versionCode = 8,
                releaseTag = newerTag,
                apkUrl = "https://github.com/Drastics-Experiments/resonance/releases/download/$newerTag/Resonance-Android-1.0.7.apk",
            ),
            currentVersionCode = 6,
            expectedReleaseTag = newerTag,
        ))

        assertEquals(newerTag, AndroidUpdatePolicy.newestUpdate(listOf(newer, older))?.releaseTag)
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.availableUpdate(
                rawManifest = manifest(versionCode = 8, releaseTag = olderTag),
                currentVersionCode = 6,
                expectedReleaseTag = newerTag,
            )
        }
    }

    @Test
    fun releaseListParserAcceptsDuplicateTitlesWithUniqueTimestampTags() {
        val releases = AndroidUpdatePolicy.decodeReleaseList(
            """[{"name":"Beta","tag_name":"v1.0.7-pre.1788150123","prerelease":true,"assets":[]},{"name":"Beta","tag_name":"v1.0.7-pre.1788154123","prerelease":true,"assets":[]}]""",
        )
        assertEquals(2, releases.size)
        assertEquals(1788154123L, AndroidUpdatePolicy.parseReleaseTag(releases[1].tagName)?.sourceTimestamp)
    }

    @Test
    fun installedOrOlderManifestDoesNotOfferUpdate() {
        assertNull(AndroidUpdatePolicy.availableUpdate(manifest(versionCode = 6), 6))
        assertNull(AndroidUpdatePolicy.availableUpdate(manifest(versionCode = 5), 6))
    }

    @Test
    fun insecureDownloadUrlIsRejected() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.availableUpdate(
                manifest(versionCode = 7, apkUrl = "http://example.com/resonance.apk"),
                6,
            )
        }

        assertEquals("The update download URL is not secure.", error.message)
    }

    @Test
    fun onlyApprovedReleaseHostsAreAccepted() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.availableUpdate(
                manifest(versionCode = 7, apkUrl = "https://updates.example/resonance.apk"),
                6,
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.availableUpdate(
                manifest(versionCode = 7, apkUrl = "https://github.com:8443/Drastics-Experiments/resonance/releases/download/v1.0.7/app.apk"),
                6,
            )
        }
        assertNotNull(
            AndroidUpdatePolicy.availableUpdate(
                manifest(versionCode = 7, apkUrl = "https://release-assets.githubusercontent.com/resonance.apk"),
                6,
            ),
        )
        assertTrue(
            AndroidUpdateNetworkPolicy.isAllowedURL(
                "https://api.github.com/repos/Drastics-Experiments/resonance/releases?per_page=30",
            ),
        )
    }

    @Test
    fun developerChannelSelectsNewestPublishedPrereleaseManifest() {
        val manifestURL = AndroidUpdatePolicy.prereleaseManifestURL(
            """
            [
              {
                "draft": false,
                "prerelease": true,
                "tag_name": "v2.1.0-pre.1788154123",
                "published_at": "2026-08-31T12:00:00Z",
                "assets": [{
                  "name": "latest-android.json",
                  "browser_download_url": "https://github.com/Drastics-Experiments/resonance/releases/download/v2.1.0-pre.1788154123/latest-android.json"
                }]
              },
              {
                "draft": false,
                "prerelease": true,
                "tag_name": "v2.0.0-pre.1788150123",
                "published_at": "2026-08-30T12:00:00Z",
                "assets": [{
                  "name": "latest-android.json",
                  "browser_download_url": "https://github.com/Drastics-Experiments/resonance/releases/download/v2.0.0-pre.1788150123/latest-android.json"
                }]
              }
            ]
            """.trimIndent(),
        )

        assertEquals(
            "https://github.com/Drastics-Experiments/resonance/releases/download/v2.1.0-pre.1788154123/latest-android.json",
            manifestURL,
        )
    }

    @Test
    fun developerChannelSkipsDraftStableAndManifestlessReleases() {
        val manifestURL = AndroidUpdatePolicy.prereleaseManifestURL(
            """
            [
              {
                "draft": true,
                "prerelease": true,
                "tag_name": "v3.0.0-pre.1788159123",
                "published_at": "2026-09-02T12:00:00Z",
                "assets": [{
                  "name": "latest-android.json",
                  "browser_download_url": "https://github.com/Drastics-Experiments/resonance/releases/download/v3.0.0-pre.1788159123/latest-android.json"
                }]
              },
              {
                "draft": false,
                "prerelease": false,
                "tag_name": "v3.0.0",
                "published_at": "2026-09-01T12:00:00Z",
                "assets": [{
                  "name": "latest-android.json",
                  "browser_download_url": "https://github.com/Drastics-Experiments/resonance/releases/download/v3.0.0/latest-android.json"
                }]
              },
              {
                "draft": false,
                "prerelease": true,
                "tag_name": "v2.1.0-pre.1788154123",
                "published_at": "2026-08-31T12:00:00Z",
                "assets": [{"name": "Resonance-Android.apk"}]
              },
              {
                "draft": false,
                "prerelease": true,
                "tag_name": "v2.0.0-pre.1788150123",
                "published_at": "2026-08-30T12:00:00Z",
                "assets": [{
                  "name": "latest-android.json",
                  "browser_download_url": "https://github.com/Drastics-Experiments/resonance/releases/download/v2.0.0-pre.1788150123/latest-android.json"
                }]
              }
            ]
            """.trimIndent(),
        )

        assertEquals(
            "https://github.com/Drastics-Experiments/resonance/releases/download/v2.0.0-pre.1788150123/latest-android.json",
            manifestURL,
        )
    }

    @Test
    fun developerChannelRejectsUntrustedManifestAssetURL() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.prereleaseManifestURL(
                """
                [{
                  "draft": false,
                  "prerelease": true,
                  "tag_name": "v2.1.0-pre.1788154123",
                  "published_at": "2026-08-31T12:00:00Z",
                  "assets": [{
                    "name": "latest-android.json",
                    "browser_download_url": "https://evil.example/latest-android.json"
                  }]
                }]
                """.trimIndent(),
            )
        }

        assertEquals("No published Android prerelease contains latest-android.json.", error.message)
    }

    @Test
    fun updaterRedirectsAreRevalidatedAgainstTheReleaseAllowlist() {
        val github = URL("https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-android.json")

        assertNotNull(
            AndroidUpdateNetworkPolicy.resolveRedirect(
                github,
                "https://release-assets.githubusercontent.com/resonance.apk",
            ),
        )
        assertNull(
            AndroidUpdateNetworkPolicy.resolveRedirect(github, "https://evil.example/resonance.apk"),
        )
        assertNull(
            AndroidUpdateNetworkPolicy.resolveRedirect(github, "http://127.0.0.1/resonance.apk"),
        )
        assertFalse(AndroidUpdateNetworkPolicy.isAllowedURL("https://github.com:8443/releases/app.apk"))
        assertTrue(
            AndroidUpdateNetworkPolicy.isAllowedURL(
                "http://10.0.2.2:8765/Resonance-Android.apk",
                allowLocalDevelopment = true,
            ),
        )
    }

    @Test
    fun emulatorTestCanExplicitlyAllowHttpDownload() {
        val update = AndroidUpdatePolicy.availableUpdate(
            rawManifest = manifest(
                versionCode = 7,
                apkUrl = "http://10.0.2.2:8765/Resonance-Android-1.0.7.apk",
            ),
            currentVersionCode = 6,
            allowInsecureDownloadUrl = true,
        )

        assertEquals(7L, update?.versionCode)
    }

    @Test
    fun malformedChecksumIsRejected() {
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.availableUpdate(manifest(versionCode = 7, sha256 = "nope"), 6)
        }
    }

    @Test
    fun unknownFutureFieldsAreIgnored() {
        val raw = manifest(versionCode = 7).dropLast(1) + ",\"futureField\":true}"

        assertEquals(7L, AndroidUpdatePolicy.availableUpdate(raw, 6)?.versionCode)
    }

    @Test
    fun downloadedPackageMustMatchManifestAndBeNewer() {
        val update = requireNotNull(AndroidUpdatePolicy.availableUpdate(manifest(versionCode = 7), 6))

        AndroidUpdatePolicy.requireMatchingDownloadedVersion(update, 7, "1.0.7", 6)
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.requireMatchingDownloadedVersion(update, 8, "1.0.8", 6)
        }
        assertThrows(IllegalArgumentException::class.java) {
            AndroidUpdatePolicy.requireMatchingDownloadedVersion(update, 7, "1.0.7", 7)
        }
    }

    private fun manifest(
        versionCode: Long,
        apkUrl: String = "https://github.com/Drastics-Experiments/resonance/releases/download/v1.0.7/Resonance-Android-1.0.7.apk",
        sha256: String = SHA256,
        releaseTag: String? = null,
    ): String = """
        {
          "schemaVersion": 1,
          "versionCode": $versionCode,
          "versionName": "1.0.7",
          ${releaseTag?.let { "\"releaseTag\": \"$it\"," }.orEmpty()}
          "apkUrl": "$apkUrl",
          "sha256": "$sha256",
          "sizeBytes": 1234,
          "releaseNotes": "Updater support"
        }
    """.trimIndent()

    private companion object {
        const val SHA256 = "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
    }
}
