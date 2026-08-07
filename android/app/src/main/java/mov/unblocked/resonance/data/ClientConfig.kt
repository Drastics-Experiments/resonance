package mov.unblocked.resonance.data

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.time.Duration
import java.time.Instant
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

const val CLIENT_CONFIG_PROTOCOL = 1
const val CLIENT_CONFIG_PLATFORM = "android"

object ClientContextHeaderPolicy {
    fun headers(
        cohortKey: String,
        appVersion: String,
        appBuild: Long,
        platform: String = CLIENT_CONFIG_PLATFORM,
    ): Map<String, String> {
        require(ClientConfigVerifier.isCanonicalCohortKey(cohortKey)) {
            "Client config cohort key must be canonical 128-bit base64url"
        }
        require(appVersion.isNotBlank()) { "Client app version is required" }
        require(appBuild > 0L) { "Client app build must be positive" }
        return mapOf(
            "X-Resonance-Client-Platform" to platform,
            "X-Resonance-App-Version" to appVersion,
            "X-Resonance-App-Build" to appBuild.toString(),
            "X-Resonance-Cohort-Key" to cohortKey,
            "X-Resonance-Config-Protocol" to CLIENT_CONFIG_PROTOCOL.toString(),
        )
    }
}

enum class ServerUploadMode(val wireValue: String, val label: String) {
    LocalFile("local_file", "Local file"),
    ServerSourceLink("server_source_link", "Source link"),
    ReviewedMatch("reviewed_match", "Reviewed match"),
    ;

    companion object {
        fun fromWireValue(value: String?): ServerUploadMode? = entries.firstOrNull {
            it.wireValue == value
        }
    }
}

enum class ServerDownloadMode(val wireValue: String, val label: String) {
    VerifiedFileCache("verified_file_cache", "Verified file"),
    StreamOnly("stream_only", "Stream only"),
    ;

    companion object {
        fun fromWireValue(value: String?): ServerDownloadMode? = entries.firstOrNull {
            it.wireValue == value
        }
    }
}

enum class ServerUploadTransport { RawVerifiedFile, CanonicalSourcePage }

object ServerUploadTransportPolicy {
    fun transportFor(mode: ServerUploadMode): ServerUploadTransport = when (mode) {
        ServerUploadMode.LocalFile, ServerUploadMode.ReviewedMatch ->
            ServerUploadTransport.RawVerifiedFile
        ServerUploadMode.ServerSourceLink -> ServerUploadTransport.CanonicalSourcePage
    }

    fun allowsLinkDerivedServerUpload(mode: ServerUploadMode): Boolean =
        mode == ServerUploadMode.ServerSourceLink || mode == ServerUploadMode.ReviewedMatch
}

@Serializable
enum class ClientDownloadOfflineMode {
    @SerialName("verified_file_cache") VerifiedFileCache,
    @SerialName("stream_only") StreamOnly,
}

@Serializable
enum class ClientDownloadPlaybackMode {
    @SerialName("same_origin_resolver") SameOriginResolver,
}

@Serializable
enum class ClientMatcherMode {
    @SerialName("off") Off,
    @SerialName("shadow") Shadow,
    @SerialName("review") Review,
}

@Serializable
enum class ClientStorageReadMode {
    @SerialName("r2_only") R2Only,
    @SerialName("external_with_r2_fallback") ExternalWithR2Fallback,
}

@Serializable
data class ClientConfigAudience(
    val origin: String,
    @SerialName("profile_id") val profileID: String,
    val platform: String,
    @SerialName("app_version") val appVersion: String,
    @SerialName("app_build") val appBuild: Long,
    @SerialName("cohort_bucket") val cohortBucket: Int,
)

@Serializable
data class ClientConfigValues(
    @SerialName("upload.local_file") val uploadLocalFile: Boolean,
    @SerialName("upload.server_source_link") val uploadServerSourceLink: Boolean,
    @SerialName("upload.reviewed_match") val uploadReviewedMatch: Boolean,
    @SerialName("upload.external_object") val uploadExternalObject: Boolean,
    @SerialName("download.offline_mode") val downloadOfflineMode: ClientDownloadOfflineMode,
    @SerialName("download.playback_mode") val downloadPlaybackMode: ClientDownloadPlaybackMode,
    @SerialName("matcher.mode") val matcherMode: ClientMatcherMode,
    @SerialName("storage.read_mode") val storageReadMode: ClientStorageReadMode,
    @SerialName("storage.r2_reclaim") val storageR2Reclaim: Boolean,
)

@Serializable
data class ClientConfigKillSwitches(
    @SerialName("all_uploads") val allUploads: Boolean,
    @SerialName("link_imports") val linkImports: Boolean,
    @SerialName("offline_downloads") val offlineDownloads: Boolean,
    @SerialName("external_reads") val externalReads: Boolean,
    @SerialName("r2_reclaim") val r2Reclaim: Boolean,
)

@Serializable
data class ClientConfigDocument(
    @SerialName("schema_version") val schemaVersion: Int,
    val revision: Long,
    @SerialName("issued_at") val issuedAt: String,
    @SerialName("not_before") val notBefore: String,
    @SerialName("expires_at") val expiresAt: String,
    val audience: ClientConfigAudience,
    val values: ClientConfigValues,
    @SerialName("kill_switches") val killSwitches: ClientConfigKillSwitches,
)

data class ClientConfigRequestContext(
    val origin: String,
    val profileID: String,
    val platform: String = CLIENT_CONFIG_PLATFORM,
    val appVersion: String,
    val appBuild: Long,
    val cohortKey: String,
) {
    init {
        require(origin.isNotBlank()) { "Client config origin is required" }
        require(profileID.isNotBlank()) { "Client config profile is required" }
        require(appVersion.isNotBlank()) { "Client config app version is required" }
        require(appBuild > 0L) { "Client config app build must be positive" }
        require(ClientConfigVerifier.isCanonicalCohortKey(cohortKey)) {
            "Client config cohort key must be canonical 128-bit base64url"
        }
    }

    val cohortBucket: Int get() = ClientConfigVerifier.cohortBucket(cohortKey)
}

data class SignedClientConfigEnvelope(
    val body: ByteArray,
    val contentDigest: String,
    val signature: String,
)

class ClientConfigValidationException(
    message: String,
    cause: Throwable? = null,
) : IOException(message, cause)

enum class ClientConfigSource { SafeDefaults, VerifiedCache, VerifiedServer }

data class EffectiveClientConfig(
    val revision: Long,
    val issuedAt: Instant?,
    val notBefore: Instant?,
    val expiresAt: Instant?,
    val values: ClientConfigValues,
    val killSwitches: ClientConfigKillSwitches,
    val source: ClientConfigSource,
) {
    val availableUploadModes: List<ServerUploadMode>
        get() = buildList {
            if (!killSwitches.allUploads && values.uploadLocalFile) add(ServerUploadMode.LocalFile)
            if (
                !killSwitches.allUploads &&
                !killSwitches.linkImports &&
                values.uploadServerSourceLink
            ) add(ServerUploadMode.ServerSourceLink)
            if (
                !killSwitches.allUploads &&
                values.uploadLocalFile &&
                values.uploadReviewedMatch &&
                values.matcherMode == ClientMatcherMode.Review
            ) add(ServerUploadMode.ReviewedMatch)
        }

    val availableDownloadModes: List<ServerDownloadMode>
        get() = when (values.downloadOfflineMode) {
            ClientDownloadOfflineMode.VerifiedFileCache -> {
                if (killSwitches.offlineDownloads) listOf(ServerDownloadMode.StreamOnly)
                else listOf(ServerDownloadMode.VerifiedFileCache)
            }
            ClientDownloadOfflineMode.StreamOnly -> listOf(ServerDownloadMode.StreamOnly)
        }

    fun isActive(at: Instant): Boolean = source == ClientConfigSource.SafeDefaults ||
        notBefore?.let { !at.isBefore(it) } == true && expiresAt?.let(at::isBefore) == true

    fun withSource(source: ClientConfigSource): EffectiveClientConfig = copy(source = source)

    companion object {
        fun safeDefaults(): EffectiveClientConfig = EffectiveClientConfig(
            revision = 0,
            issuedAt = null,
            notBefore = null,
            expiresAt = null,
            values = ClientConfigValues(
                uploadLocalFile = true,
                uploadServerSourceLink = false,
                uploadReviewedMatch = false,
                uploadExternalObject = false,
                downloadOfflineMode = ClientDownloadOfflineMode.VerifiedFileCache,
                downloadPlaybackMode = ClientDownloadPlaybackMode.SameOriginResolver,
                matcherMode = ClientMatcherMode.Off,
                storageReadMode = ClientStorageReadMode.R2Only,
                storageR2Reclaim = false,
            ),
            killSwitches = ClientConfigKillSwitches(
                allUploads = false,
                linkImports = true,
                offlineDownloads = false,
                externalReads = true,
                r2Reclaim = true,
            ),
            source = ClientConfigSource.SafeDefaults,
        )
    }
}

object ClientConfigVerifier {
    const val MAX_BODY_BYTES = 256 * 1_024
    const val MAX_TTL_SECONDS = 15L * 60L
    private const val SIGNATURE_PREFIX = "resonance-client-config-v1"
    private const val COHORT_PREFIX = "resonance-client-config-cohort-v1"
    private val digestPattern = Regex("^sha-256=:[A-Za-z0-9+/]+={0,2}:$")
    private val signaturePattern = Regex("^v1=:[A-Za-z0-9+/]+={0,2}:$")
    private val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
    }

    fun verify(
        envelope: SignedClientConfigEnvelope,
        bearer: String,
        expected: ClientConfigRequestContext,
        now: Instant = Instant.now(),
        source: ClientConfigSource = ClientConfigSource.VerifiedServer,
    ): EffectiveClientConfig {
        if (envelope.body.isEmpty() || envelope.body.size > MAX_BODY_BYTES) {
            throw ClientConfigValidationException("The client config response size is invalid")
        }
        if (bearer.isEmpty()) throw ClientConfigValidationException("The client config verification token is missing")
        if (!digestPattern.matches(envelope.contentDigest)) {
            throw ClientConfigValidationException("The client config Content-Digest header is invalid")
        }
        val actualDigest = MessageDigest.getInstance("SHA-256").digest(envelope.body)
        val expectedDigest = decodeWrappedHeader(envelope.contentDigest, "sha-256=:")
        if (!MessageDigest.isEqual(actualDigest, expectedDigest)) {
            throw ClientConfigValidationException("The client config body digest does not match")
        }

        val document = runCatching {
            val text = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(envelope.body))
                .toString()
            json.decodeFromString<ClientConfigDocument>(text)
        }.getOrElse { throw ClientConfigValidationException("The client config document is invalid", it) }
        requireAudience(document, expected)

        if (!signaturePattern.matches(envelope.signature)) {
            throw ClientConfigValidationException("The client config signature header is invalid")
        }
        val signatureInput = buildString {
            append(SIGNATURE_PREFIX)
            append('\n').append(document.audience.origin)
            append('\n').append(document.audience.profileID)
            append('\n').append(document.audience.platform)
            append('\n').append(document.audience.appBuild)
            append('\n').append(envelope.contentDigest)
        }.toByteArray(Charsets.UTF_8)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(bearer.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val expectedSignature = decodeWrappedHeader(envelope.signature, "v1=:")
        if (!MessageDigest.isEqual(mac.doFinal(signatureInput), expectedSignature)) {
            throw ClientConfigValidationException("The client config signature does not match")
        }

        val issuedAt = parseInstant("issued_at", document.issuedAt)
        val notBefore = parseInstant("not_before", document.notBefore)
        val expiresAt = parseInstant("expires_at", document.expiresAt)
        if (document.schemaVersion != CLIENT_CONFIG_PROTOCOL || document.revision < 0L) {
            throw ClientConfigValidationException("The client config version or revision is invalid")
        }
        if (notBefore.isBefore(issuedAt) || expiresAt.isBefore(notBefore) || expiresAt == notBefore) {
            throw ClientConfigValidationException("The client config validity window is invalid")
        }
        if (Duration.between(issuedAt, expiresAt) > Duration.ofSeconds(MAX_TTL_SECONDS)) {
            throw ClientConfigValidationException("The client config lease is longer than 15 minutes")
        }
        if (now.isBefore(notBefore) || !now.isBefore(expiresAt)) {
            throw ClientConfigValidationException("The client config is not currently valid")
        }
        // External-primary storage and destructive R2 reclamation stay compile-time disabled
        // until Android has a renewable provider adapter and a reviewed reclaim manifest path.
        if (
            document.values.uploadExternalObject ||
            document.values.storageR2Reclaim ||
            document.values.storageReadMode != ClientStorageReadMode.R2Only
        ) {
            throw ClientConfigValidationException("The client config requested a hard-disabled storage capability")
        }

        return EffectiveClientConfig(
            revision = document.revision,
            issuedAt = issuedAt,
            notBefore = notBefore,
            expiresAt = expiresAt,
            values = document.values,
            killSwitches = document.killSwitches,
            source = source,
        )
    }

    fun cohortBucket(cohortKey: String): Int {
        require(isCanonicalCohortKey(cohortKey)) {
            "Client config cohort key must be canonical 128-bit base64url"
        }
        val digest = MessageDigest.getInstance("SHA-256").digest(
            "$COHORT_PREFIX\n$cohortKey".toByteArray(Charsets.UTF_8),
        )
        val unsigned = ByteBuffer.wrap(digest, 0, Int.SIZE_BYTES).int.toLong() and 0xffff_ffffL
        return (unsigned % 10_000L).toInt()
    }

    fun tokenFingerprint(bearer: String): String = Base64.getUrlEncoder().withoutPadding().encodeToString(
        MessageDigest.getInstance("SHA-256").digest(bearer.toByteArray(Charsets.UTF_8)),
    )

    fun isCanonicalCohortKey(value: String): Boolean {
        if (value.length != 22 || !value.matches(Regex("^[A-Za-z0-9_-]{22}$"))) return false
        val decoded = runCatching { Base64.getUrlDecoder().decode(value) }.getOrNull() ?: return false
        return decoded.size == 16 && Base64.getUrlEncoder().withoutPadding().encodeToString(decoded) == value
    }

    private fun requireAudience(document: ClientConfigDocument, expected: ClientConfigRequestContext) {
        val audience = document.audience
        if (
            audience.origin != expected.origin ||
            audience.profileID != expected.profileID ||
            audience.platform != expected.platform ||
            audience.appVersion != expected.appVersion ||
            audience.appBuild != expected.appBuild ||
            audience.cohortBucket != expected.cohortBucket
        ) {
            throw ClientConfigValidationException("The client config audience does not match this server context")
        }
    }

    private fun decodeWrappedHeader(value: String, prefix: String): ByteArray {
        val encoded = value.removePrefix(prefix).removeSuffix(":")
        val decoded = runCatching { Base64.getDecoder().decode(encoded) }
            .getOrElse {
                throw ClientConfigValidationException("The client config signature encoding is invalid", it)
            }
        if (decoded.size != 32 || Base64.getEncoder().encodeToString(decoded) != encoded) {
            throw ClientConfigValidationException("The client config signature encoding is invalid")
        }
        return decoded
    }

    private fun parseInstant(field: String, value: String): Instant = runCatching {
        Instant.parse(value)
    }.getOrElse { throw ClientConfigValidationException("The client config $field timestamp is invalid", it) }
}

data class ResolvedServerTransferModes(
    val uploadMode: ServerUploadMode?,
    val downloadMode: ServerDownloadMode,
)

object ServerTransferModePolicy {
    fun resolve(
        config: EffectiveClientConfig,
        preferredUpload: ServerUploadMode?,
        preferredDownload: ServerDownloadMode?,
        now: Instant = Instant.now(),
    ): ResolvedServerTransferModes {
        val active = if (config.isActive(now)) config else EffectiveClientConfig.safeDefaults()
        val uploads = active.availableUploadModes
        val downloads = active.availableDownloadModes
        return ResolvedServerTransferModes(
            uploadMode = preferredUpload?.takeIf(uploads::contains) ?: uploads.firstOrNull(),
            downloadMode = preferredDownload?.takeIf(downloads::contains)
                ?: downloads.firstOrNull()
                ?: ServerDownloadMode.StreamOnly,
        )
    }
}

object ClientConfigCacheFallbackPolicy {
    fun mayUseFreshCache(error: Throwable): Boolean {
        if (error !is IOException || error is ClientConfigValidationException) return false
        val status = (error as? ServerException)?.status ?: return true
        return status in 500..599
    }
}

internal object ClientConfigResponsePolicy {
    fun oversizedBody(cause: IOException): ClientConfigValidationException =
        ClientConfigValidationException("The client config response is too large", cause)
}

internal object ClientConfigRevisionPolicy {
    fun accepts(highestVerifiedRevision: Long?, candidateRevision: Long): Boolean =
        candidateRevision >= 0L &&
            (highestVerifiedRevision == null || candidateRevision >= highestVerifiedRevision)
}
