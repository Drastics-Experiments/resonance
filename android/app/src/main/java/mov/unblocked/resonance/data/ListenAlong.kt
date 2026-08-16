package mov.unblocked.resonance.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import java.io.IOException
import java.net.URI

/** The small, server-authoritative state that is shared with every listener. */
@Serializable
data class ListenAlongSnapshot(
    @SerialName("source_url") val sourceURL: String? = null,
    @SerialName("media_kind") val mediaKind: String = "audio",
    @SerialName("position_seconds") val positionSeconds: Double = 0.0,
    @SerialName("is_playing") val isPlaying: Boolean = false,
) {
    val normalizedMediaKind: String
        get() = if (mediaKind == "video") "video" else "audio"

    val safePositionSeconds: Double
        get() = positionSeconds.takeIf { it.isFinite() && it >= 0.0 } ?: 0.0

    fun normalized(): ListenAlongSnapshot = copy(
        sourceURL = sourceURL?.trim()?.takeIf(String::isNotEmpty),
        mediaKind = normalizedMediaKind,
        positionSeconds = safePositionSeconds,
    )
}

@Serializable
data class ListenAlongEnvelope(
    @SerialName("schema_version") val schemaVersion: Int = 1,
    /** The API historically calls this field formatted_code; accept code too. */
    @SerialName("formatted_code") val formattedCode: String? = null,
    val code: String? = null,
    @SerialName("session_code") val sessionCode: String? = null,
    val revision: Long = 0L,
    val snapshot: ListenAlongSnapshot? = null,
    // Development servers briefly returned the snapshot fields at the response root.
    // Keep these optional so a guest can still follow that shape without weakening the
    // normal nested contract.
    @SerialName("source_url") val flatSourceURL: String? = null,
    @SerialName("media_kind") val flatMediaKind: String? = null,
    @SerialName("position_seconds") val flatPositionSeconds: Double? = null,
    @SerialName("is_playing") val flatIsPlaying: Boolean? = null,
    @SerialName("updated_at") val updatedAt: String? = null,
    @SerialName("expires_at") val expiresAt: String? = null,
    @SerialName("server_time") val serverTime: String? = null,
    val role: String? = null,
    @SerialName("host_token") val hostToken: String? = null,
) {
    val inviteCode: String?
        get() = formattedCode ?: code ?: sessionCode

    val normalizedSnapshot: ListenAlongSnapshot
        get() = (snapshot ?: ListenAlongSnapshot(
            sourceURL = flatSourceURL,
            mediaKind = flatMediaKind ?: "audio",
            positionSeconds = flatPositionSeconds ?: 0.0,
            isPlaying = flatIsPlaying == true,
        )).normalized()

    val normalizedRole: ListenAlongRole
        get() = if (role.equals("host", ignoreCase = true)) {
            ListenAlongRole.Host
        } else {
            ListenAlongRole.Guest
        }
}

enum class ListenAlongRole { Host, Guest }

/** Flat host update contract used by PUT /api/v1/listen-along/{code}. */
@Serializable
internal data class ListenAlongUpdatePayload(
    val revision: Long,
    @SerialName("source_url") val sourceURL: String? = null,
    @SerialName("media_kind") val mediaKind: String = "audio",
    @SerialName("position_seconds") val positionSeconds: Double = 0.0,
    @SerialName("is_playing") val isPlaying: Boolean = false,
)

internal class ListenAlongRevisionConflictException(
    val current: ListenAlongEnvelope?,
    val serverMessage: String? = null,
) : IOException(serverMessage ?: "The Listen Along room revision is stale")

/** Timing policy for the short-poll fallback used by Listen Along guests. */
internal object ListenAlongPollPolicy {
    const val HealthyIntervalMillis = 250L
    const val MaxBackoffMillis = 15_000L

    fun nextFailureDelay(currentMillis: Long): Long =
        (currentMillis.coerceAtLeast(HealthyIntervalMillis) * 2L)
            .coerceAtMost(MaxBackoffMillis)
}

/** Selects the first non-blank artwork URL available to a transient guest track. */
internal object ListenAlongArtworkPolicy {
    fun preferredURL(vararg values: String?): String? = values
        .asSequence()
        .mapNotNull { it?.trim()?.takeIf(String::isNotEmpty) }
        .firstOrNull()
}

/** Keeps same-source pause/seek/play updates on the already prepared player item. */
internal object ListenAlongPlaybackPolicy {
    fun shouldReuse(
        currentSourceURL: String?,
        nextSourceURL: String?,
        currentMediaKind: String,
        nextMediaKind: String,
        mediaItemCount: Int,
    ): Boolean = mediaItemCount > 0 &&
        currentSourceURL == nextSourceURL &&
        currentMediaKind == nextMediaKind
}

internal object ListenAlongSnapshotPolicy {
    const val MAX_SOURCE_URL_LENGTH = 8_192
    const val MAX_POSITION_SECONDS = 7 * 24 * 60 * 60

    fun normalized(value: ListenAlongSnapshot): ListenAlongSnapshot {
        val source = value.sourceURL?.trim()?.takeIf(String::isNotEmpty)
        require(source == null || source.length <= MAX_SOURCE_URL_LENGTH) {
            "The listen-along source link is too long"
        }
        source?.let { candidate ->
            val uri = runCatching { URI(candidate) }.getOrNull()
            require(
                uri != null &&
                    uri.scheme.equals("https", ignoreCase = true) &&
                    uri.host?.isNotBlank() == true &&
                    uri.userInfo == null &&
                    uri.fragment == null,
            ) { "The listen-along source link must be a public HTTPS URL" }
        }
        require(value.positionSeconds.isFinite() && value.positionSeconds in 0.0..MAX_POSITION_SECONDS.toDouble()) {
            "The listen-along position is invalid"
        }
        return value.copy(
            sourceURL = source,
            mediaKind = if (value.mediaKind == "video") "video" else "audio",
            positionSeconds = value.positionSeconds,
        )
    }

    fun projectedPositionSeconds(
        snapshot: ListenAlongSnapshot,
        updatedAtMillis: Long?,
        serverTimeMillis: Long?,
        nowMillis: Long,
    ): Double {
        val normalized = normalized(snapshot)
        if (!normalized.isPlaying) return normalized.positionSeconds
        val observedServerTime = serverTimeMillis ?: nowMillis
        val updateTime = updatedAtMillis ?: observedServerTime
        val elapsed = (observedServerTime - updateTime).coerceAtLeast(0L) / 1_000.0
        return normalized.positionSeconds + elapsed
    }
}
