package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class ClientConfigTest {
    private val bearer = "test-access-token"
    private val context = ClientConfigRequestContext(
        origin = "https://music.example",
        profileID = "default",
        appVersion = "1.1.4",
        appBuild = 15,
        cohortKey = "AAECAwQFBgcICQoLDA0ODw",
    )
    private val now = Instant.parse("2026-08-06T17:05:00Z")

    @Test
    fun verifiesCanonicalFixtureAndIgnoresAdditionalProperties() {
        val verified = ClientConfigVerifier.verify(
            signedEnvelope(body(extra = ",\"future_property\":true")),
            bearer,
            context,
            now,
        )

        assertEquals(7L, verified.revision)
        assertEquals(ClientConfigSource.VerifiedServer, verified.source)
        assertEquals(listOf(ServerUploadMode.LocalFile), verified.availableUploadModes)
        assertEquals(listOf(ServerDownloadMode.VerifiedFileCache), verified.availableDownloadModes)
    }

    @Test
    fun mutationsAndAudienceMismatchesFailClosed() {
        val signed = signedEnvelope(body())
        val mutated = signed.copy(body = signed.body.copyOf().also { bytes ->
            bytes[bytes.lastIndex - 2] = (bytes[bytes.lastIndex - 2].toInt() xor 1).toByte()
        })
        expectFailure("digest does not match") {
            ClientConfigVerifier.verify(mutated, bearer, context, now)
        }
        expectFailure("signature does not match") {
            ClientConfigVerifier.verify(signed, "$bearer-wrong", context, now)
        }
        expectFailure("audience does not match") {
            ClientConfigVerifier.verify(
                signed,
                bearer,
                context.copy(profileID = "another-profile"),
                now,
            )
        }
    }

    @Test
    fun signedMalformedUtf8FailsClosedInsteadOfBeingReplacementDecoded() {
        val bytes = body(extra = ",\"ignored_future_value\":\"x\"")
            .toByteArray(Charsets.UTF_8)
            .also { value ->
                val marker = value.lastIndexOf('x'.code.toByte())
                check(marker >= 0)
                value[marker] = 0x80.toByte()
            }

        expectFailure("document is invalid") {
            ClientConfigVerifier.verify(signedEnvelope(bytes), bearer, context, now)
        }
    }

    @Test
    fun expiryFutureUnknownEnumsAndLongLeasesFailClosed() {
        expectFailure("not currently valid") {
            ClientConfigVerifier.verify(signedEnvelope(body()), bearer, context, Instant.parse("2026-08-06T17:10:00Z"))
        }
        expectFailure("not currently valid") {
            ClientConfigVerifier.verify(signedEnvelope(body(notBefore = "2026-08-06T17:06:00Z")), bearer, context, now)
        }
        expectFailure("document is invalid") {
            ClientConfigVerifier.verify(
                signedEnvelope(body().replace("verified_file_cache", "future_download_mode")),
                bearer,
                context,
                now,
            )
        }
        expectFailure("longer than 15 minutes") {
            ClientConfigVerifier.verify(
                signedEnvelope(body(expiresAt = "2026-08-06T17:16:00Z")),
                bearer,
                context,
                now,
            )
        }
        expectFailure("longer than 15 minutes") {
            ClientConfigVerifier.verify(
                signedEnvelope(
                    body(expiresAt = "2026-08-06T17:15:00.001Z"),
                ),
                bearer,
                context,
                now,
            )
        }
    }

    @Test
    fun externalStorageAndReclaimRemainHardDisabled() {
        expectFailure("hard-disabled") {
            ClientConfigVerifier.verify(
                signedEnvelope(body().replace("\"upload.external_object\":false", "\"upload.external_object\":true")),
                bearer,
                context,
                now,
            )
        }
        expectFailure("hard-disabled") {
            ClientConfigVerifier.verify(
                signedEnvelope(body().replace("\"storage.read_mode\":\"r2_only\"", "\"storage.read_mode\":\"external_with_r2_fallback\"")),
                bearer,
                context,
                now,
            )
        }
    }

    @Test
    fun modePolicyUsesSafeDefaultsAndFallsBackWhenModesDisappear() {
        val safe = EffectiveClientConfig.safeDefaults()
        assertEquals(
            ResolvedServerTransferModes(ServerUploadMode.LocalFile, ServerDownloadMode.VerifiedFileCache),
            ServerTransferModePolicy.resolve(
                safe,
                ServerUploadMode.ServerSourceLink,
                ServerDownloadMode.StreamOnly,
                now,
            ),
        )

        val remote = ClientConfigVerifier.verify(
            signedEnvelope(
                body(
                    uploadSourceLink = true,
                    uploadReviewedMatch = true,
                    matcherMode = "review",
                    downloadMode = "stream_only",
                    linkImportsKilled = false,
                ),
            ),
            bearer,
            context,
            now,
        )
        assertEquals(
            listOf(
                ServerUploadMode.LocalFile,
                ServerUploadMode.ServerSourceLink,
                ServerUploadMode.ReviewedMatch,
            ),
            remote.availableUploadModes,
        )
        assertEquals(listOf(ServerDownloadMode.StreamOnly), remote.availableDownloadModes)
        assertEquals(
            ServerUploadTransport.PreservedSourceLink,
            ServerUploadTransportPolicy.transportFor(ServerUploadMode.ReviewedMatch),
        )
        assertEquals(
            ServerUploadTransport.PreservedSourceLink,
            ServerUploadTransportPolicy.transportFor(ServerUploadMode.ServerSourceLink),
        )
        assertTrue(ServerUploadTransportPolicy.allowsLinkDerivedServerUpload(ServerUploadMode.LocalFile))
        assertTrue(ServerUploadTransportPolicy.allowsLinkDerivedServerUpload(ServerUploadMode.ReviewedMatch))
        val reviewedWithoutRawUpload = ClientConfigVerifier.verify(
            signedEnvelope(
                body(
                    uploadLocalFile = false,
                    uploadReviewedMatch = true,
                    matcherMode = "review",
                    linkImportsKilled = false,
                ),
            ),
            bearer,
            context,
            now,
        )
        assertFalse(ServerUploadMode.ReviewedMatch in reviewedWithoutRawUpload.availableUploadModes)
        val reviewedWithSourceLinksKilled = ClientConfigVerifier.verify(
            signedEnvelope(
                body(
                    uploadReviewedMatch = true,
                    matcherMode = "review",
                    linkImportsKilled = true,
                ),
            ),
            bearer,
            context,
            now,
        )
        assertTrue(ServerUploadMode.ReviewedMatch in reviewedWithSourceLinksKilled.availableUploadModes)
    }

    @Test
    fun cacheScopeIncludesProfileBuildAndTokenFingerprint() {
        val base = ClientConfigCacheScope(
            origin = context.origin,
            profileID = context.profileID,
            platform = context.platform,
            appVersion = context.appVersion,
            appBuild = context.appBuild,
            tokenFingerprint = ClientConfigVerifier.tokenFingerprint(bearer),
        )
        assertNotEquals(ClientConfigStore.cacheKey(base), ClientConfigStore.cacheKey(base.copy(profileID = "other")))
        assertNotEquals(ClientConfigStore.cacheKey(base), ClientConfigStore.cacheKey(base.copy(appBuild = 16)))
        assertNotEquals(
            ClientConfigStore.cacheKey(base),
            ClientConfigStore.cacheKey(base.copy(tokenFingerprint = ClientConfigVerifier.tokenFingerprint("other"))),
        )
        assertTrue(CachedClientConfigEnvelope(signedEnvelope(body()), 1_000L).isWithinLocalAge(901_000L))
        assertFalse(CachedClientConfigEnvelope(signedEnvelope(body()), 1_000L).isWithinLocalAge(901_001L))
        assertFalse(CachedClientConfigEnvelope(signedEnvelope(body()), 2_000L).isWithinLocalAge(1_000L))
    }

    @Test
    fun lowerSignedRevisionIsRejectedPerExactCacheScope() {
        assertTrue(ClientConfigRevisionPolicy.accepts(null, 7))
        assertTrue(ClientConfigRevisionPolicy.accepts(7, 7))
        assertTrue(ClientConfigRevisionPolicy.accepts(7, 8))
        assertFalse(ClientConfigRevisionPolicy.accepts(8, 7))
        assertFalse(ClientConfigRevisionPolicy.accepts(null, -1))
    }

    @Test
    fun cacheFallbackIsLimitedToTransportFailuresAndServerErrors() {
        assertTrue(ClientConfigCacheFallbackPolicy.mayUseFreshCache(IOException("offline")))
        assertTrue(ClientConfigCacheFallbackPolicy.mayUseFreshCache(ServerException(503)))
        assertFalse(ClientConfigCacheFallbackPolicy.mayUseFreshCache(ServerException(401)))
        assertFalse(ClientConfigCacheFallbackPolicy.mayUseFreshCache(ServerException(302)))
        assertFalse(
            ClientConfigCacheFallbackPolicy.mayUseFreshCache(
                ClientConfigValidationException("invalid signature"),
            ),
        )
        assertFalse(ClientConfigCacheFallbackPolicy.mayUseFreshCache(IllegalStateException("missing token")))
        assertFalse(
            ClientConfigCacheFallbackPolicy.mayUseFreshCache(
                ClientConfigResponsePolicy.oversizedBody(IOException("limit exceeded")),
            ),
        )
    }

    @Test
    fun cohortAndWrappedBase64MustUseCanonicalEncoding() {
        assertTrue(ClientConfigVerifier.isCanonicalCohortKey(context.cohortKey))
        assertEquals(154, context.cohortBucket)
        assertFalse(ClientConfigVerifier.isCanonicalCohortKey(context.cohortKey + "="))
        assertFalse(ClientConfigVerifier.isCanonicalCohortKey(context.cohortKey.dropLast(1) + "B"))
        try {
            context.copy(cohortKey = context.cohortKey + "=")
            fail("Expected a non-canonical cohort key to be rejected")
        } catch (_: IllegalArgumentException) {
            // Expected.
        }

        val signed = signedEnvelope(body())
        expectFailure("invalid") {
            ClientConfigVerifier.verify(
                signed.copy(contentDigest = signed.contentDigest.replace("=:", ":")),
                bearer,
                context,
                now,
            )
        }
        expectFailure("invalid") {
            ClientConfigVerifier.verify(
                signed.copy(signature = signed.signature.replace("=:", ":")),
                bearer,
                context,
                now,
            )
        }
    }

    @Test
    fun transferContextHeadersCarryTheExactProtocolAudience() {
        assertEquals(
            mapOf(
                "X-Resonance-Client-Platform" to "android",
                "X-Resonance-App-Version" to "1.1.4",
                "X-Resonance-App-Build" to "15",
                "X-Resonance-Cohort-Key" to context.cohortKey,
                "X-Resonance-Config-Protocol" to "1",
            ),
            ClientContextHeaderPolicy.headers(context.cohortKey, "1.1.4", 15),
        )
    }

    @Test
    fun sourceImportAcceptsCanonicalYoutubePagesOnly() {
        assertEquals(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            SourceImportPolicy.canonicalYouTubePageURL(" https://www.youtube.com/watch?v=dQw4w9WgXcQ "),
        )
        expectIllegalArgument("exact www.youtube.com") {
            SourceImportPolicy.canonicalYouTubePageURL("https://youtu.be/dQw4w9WgXcQ")
        }
        expectIllegalArgument("exact canonical") {
            SourceImportPolicy.canonicalYouTubePageURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123")
        }
        expectIllegalArgument("YouTube") {
            SourceImportPolicy.canonicalYouTubePageURL("https://soundcloud.com/artist/song")
        }
        expectIllegalArgument("HTTPS") {
            SourceImportPolicy.canonicalYouTubePageURL("http://www.youtube.com/watch?v=dQw4w9WgXcQ")
        }
        expectIllegalArgument("credentials") {
            SourceImportPolicy.canonicalYouTubePageURL("https://token@www.youtube.com/watch?v=dQw4w9WgXcQ")
        }
        expectIllegalArgument("valid video ID") {
            SourceImportPolicy.canonicalYouTubePageURL("https://www.youtube.com/watch?v=short")
        }
    }

    @Test
    fun reviewedMatchCandidatesRequireExplicitReviewAndExactSourceIdentity() {
        val candidate = ReviewedMatchCandidate(
            provider = "youtube_music",
            sourceURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            videoID = "dQw4w9WgXcQ",
            title = "Reviewed recording",
            artist = "Artist",
            score = .91,
            actionable = false,
            autoSelectable = false,
            requiresReview = true,
        )
        assertEquals("dQw4w9WgXcQ", candidate.validatedCandidate()?.videoID)
        assertEquals(null, candidate.copy(actionable = true).validatedCandidate())
        assertEquals(null, candidate.copy(autoSelectable = true).validatedCandidate())
        assertEquals(null, candidate.copy(requiresReview = false).validatedCandidate())
        assertEquals(null, candidate.copy(sourceURL = "https://youtu.be/dQw4w9WgXcQ").validatedCandidate())
        assertEquals(null, candidate.copy(videoID = "aaaaaaaaaaa").validatedCandidate())
    }

    @Test
    fun consumesExplicitYoutubeReviewedResponseShapeWithoutImplicitSelection() {
        val decoded = Json { ignoreUnknownKeys = true }.decodeFromString<ReviewedMatchResolveResponse>(
            """
            {
              "provider": "youtube",
              "type": "video",
              "source": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
              "video_id": "dQw4w9WgXcQ",
              "title": "Reviewed recording",
              "duration_seconds": 213,
              "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
              "review_candidates": [{
                "provider": "youtube",
                "source_url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                "video_id": "dQw4w9WgXcQ",
                "title": "Reviewed recording",
                "artist": "Artist",
                "duration_seconds": 213,
                "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
                "score": 1.0,
                "requires_review": true,
                "auto_selectable": false,
                "actionable": false
              }]
            }
            """.trimIndent(),
        )

        val resolution = decoded.validatedResolution()
        assertTrue(resolution.reviewedMatchPolicyBound)
        assertEquals("Unknown uploader", resolution.track.artist)
        assertEquals("dQw4w9WgXcQ", resolution.candidates.single().videoID)
        assertTrue(resolution.candidates.single().fallbackCandidates.isEmpty())
    }

    @Test
    fun configAudienceUsesTheCanonicalServerOrigin() {
        assertEquals(
            "https://music.example",
            ServerClient.canonicalServerOrigin("https://MUSIC.example:443/base/path"),
        )
        assertEquals(
            "https://music.example:8443",
            ServerClient.canonicalServerOrigin("https://music.example:8443/base/path"),
        )
    }

    private fun body(
        notBefore: String = "2026-08-06T17:00:00Z",
        expiresAt: String = "2026-08-06T17:10:00Z",
        uploadLocalFile: Boolean = true,
        uploadSourceLink: Boolean = false,
        uploadReviewedMatch: Boolean = false,
        matcherMode: String = "off",
        downloadMode: String = "verified_file_cache",
        linkImportsKilled: Boolean = true,
        extra: String = "",
    ): String = """{"schema_version":1,"revision":7,"issued_at":"2026-08-06T17:00:00Z","not_before":"$notBefore","expires_at":"$expiresAt","audience":{"origin":"${context.origin}","profile_id":"${context.profileID}","platform":"${context.platform}","app_version":"${context.appVersion}","app_build":${context.appBuild},"cohort_bucket":${context.cohortBucket}},"values":{"upload.local_file":$uploadLocalFile,"upload.server_source_link":$uploadSourceLink,"upload.reviewed_match":$uploadReviewedMatch,"upload.external_object":false,"download.offline_mode":"$downloadMode","download.playback_mode":"same_origin_resolver","matcher.mode":"$matcherMode","storage.read_mode":"r2_only","storage.r2_reclaim":false},"kill_switches":{"all_uploads":false,"link_imports":$linkImportsKilled,"offline_downloads":false,"external_reads":true,"r2_reclaim":true}$extra}"""

    private fun signedEnvelope(value: String): SignedClientConfigEnvelope =
        signedEnvelope(value.toByteArray(Charsets.UTF_8))

    private fun signedEnvelope(bytes: ByteArray): SignedClientConfigEnvelope {
        val contentDigest = "sha-256=:" + Base64.getEncoder().encodeToString(
            MessageDigest.getInstance("SHA-256").digest(bytes),
        ) + ":"
        val input = "resonance-client-config-v1\n${context.origin}\n${context.profileID}\n${context.platform}\n${context.appBuild}\n$contentDigest"
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(bearer.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val signature = "v1=:" + Base64.getEncoder().encodeToString(
            mac.doFinal(input.toByteArray(Charsets.UTF_8)),
        ) + ":"
        return SignedClientConfigEnvelope(bytes, contentDigest, signature)
    }

    private fun expectFailure(message: String, block: () -> Unit) {
        try {
            block()
            fail("Expected IOException containing $message")
        } catch (error: IOException) {
            assertTrue("${error.message} should contain $message", error.message.orEmpty().contains(message))
        }
    }

    private fun expectIllegalArgument(message: String, block: () -> Unit) {
        try {
            block()
            fail("Expected IllegalArgumentException containing $message")
        } catch (error: IllegalArgumentException) {
            assertTrue("${error.message} should contain $message", error.message.orEmpty().contains(message))
        }
    }
}
