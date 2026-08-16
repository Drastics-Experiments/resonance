package mov.unblocked.resonance.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ListenAlongTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Test
    fun envelopeAcceptsFormattedCodeAndNestedSnapshot() {
        val envelope = json.decodeFromString<ListenAlongEnvelope>(
            """{"schema_version":1,"formatted_code":"ABCD-EFGH","revision":4,"snapshot":{"source_url":"https://soundcloud.com/example/track","media_kind":"audio","position_seconds":12.5,"is_playing":true},"server_time":"10000","role":"host","host_token":"opaque-host-token","participant_count":3}""",
        )

        assertEquals("ABCD-EFGH", envelope.inviteCode)
        assertEquals(4L, envelope.revision)
        assertEquals("https://soundcloud.com/example/track", envelope.normalizedSnapshot.sourceURL)
        assertEquals(ListenAlongRole.Host, envelope.normalizedRole)
        assertEquals("opaque-host-token", envelope.hostToken)
        assertEquals(3, envelope.normalizedParticipantCount)
    }

    @Test
    fun snapshotPolicyRejectsInvalidPositionAndProjectsPlayingState() {
        val snapshot = ListenAlongSnapshot(
            sourceURL = " https://example.com/track ",
            mediaKind = "unknown",
            positionSeconds = -4.0,
            isPlaying = true,
        )

        assertTrue(runCatching { ListenAlongSnapshotPolicy.normalized(snapshot) }.isFailure)
        val normalized = ListenAlongSnapshotPolicy.normalized(snapshot.copy(positionSeconds = 0.0))
        assertEquals("https://example.com/track", normalized.sourceURL)
        assertEquals("audio", normalized.mediaKind)
        assertEquals(0.0, normalized.positionSeconds, 0.0)
        assertEquals(
            2.5,
            ListenAlongSnapshotPolicy.projectedPositionSeconds(
                normalized,
                updatedAtMillis = 10_000L,
                serverTimeMillis = 12_500L,
                nowMillis = 90_000L,
            ),
            0.0,
        )
    }

    @Test
    fun hostUpdatePayloadUsesTheFlatPutContract() {
        val payload = json.encodeToString(
            ListenAlongUpdatePayload(
                revision = 7L,
                sourceURL = "https://soundcloud.com/example/track",
                mediaKind = "audio",
                positionSeconds = 12.5,
                isPlaying = true,
            ),
        )
        val objectPayload = json.parseToJsonElement(payload).jsonObject

        assertEquals(7L, objectPayload["revision"]?.jsonPrimitive?.long)
        assertEquals("https://soundcloud.com/example/track", objectPayload["source_url"]?.jsonPrimitive?.contentOrNull)
        assertEquals("audio", objectPayload["media_kind"]?.jsonPrimitive?.contentOrNull)
        assertEquals(12.5, objectPayload["position_seconds"]?.jsonPrimitive?.doubleOrNull ?: -1.0, 0.0)
        assertEquals(true, objectPayload["is_playing"]?.jsonPrimitive?.boolean)
        assertTrue("snapshot" !in objectPayload)
    }

    @Test
    fun sourceLinksAreBoundedBeforeTheyReachTheServer() {
        val tooLong = "https://example.com/" + "x".repeat(ListenAlongSnapshotPolicy.MAX_SOURCE_URL_LENGTH)
        assertTrue(runCatching {
            ListenAlongSnapshotPolicy.normalized(ListenAlongSnapshot(sourceURL = tooLong))
        }.isFailure)
    }

    @Test
    fun guestPollingIsFastWhenHealthyButBacksOffAfterFailures() {
        assertEquals(250L, ListenAlongPollPolicy.HealthyIntervalMillis)
        assertEquals(
            500L,
            ListenAlongPollPolicy.nextFailureDelay(ListenAlongPollPolicy.HealthyIntervalMillis),
        )
        assertEquals(
            ListenAlongPollPolicy.MaxBackoffMillis,
            ListenAlongPollPolicy.nextFailureDelay(ListenAlongPollPolicy.MaxBackoffMillis),
        )
    }

    @Test
    fun guestArtworkUsesResolverCandidateWhenTrackMetadataIsBlank() {
        assertEquals(
            "https://i.ytimg.com/vi/example/hqdefault.jpg",
            ListenAlongArtworkPolicy.preferredURL(
                "  ",
                "https://i.ytimg.com/vi/example/hqdefault.jpg",
                "https://cdn.example/fallback.jpg",
            ),
        )
        assertEquals(
            "https://cdn.example/fallback.jpg",
            ListenAlongArtworkPolicy.preferredURL(null, " ", "https://cdn.example/fallback.jpg"),
        )
    }

    @Test
    fun sameSourceTransportUpdatesReuseTheActiveMediaItem() {
        assertTrue(
            ListenAlongPlaybackPolicy.shouldReuse(
                currentSourceURL = "https://www.youtube.com/watch?v=track",
                nextSourceURL = "https://www.youtube.com/watch?v=track",
                currentMediaKind = "audio",
                nextMediaKind = "audio",
                mediaItemCount = 1,
            ),
        )
        assertTrue(
            !ListenAlongPlaybackPolicy.shouldReuse(
                currentSourceURL = "https://www.youtube.com/watch?v=track",
                nextSourceURL = "https://www.youtube.com/watch?v=next",
                currentMediaKind = "audio",
                nextMediaKind = "audio",
                mediaItemCount = 1,
            ),
        )
    }
}
