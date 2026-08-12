package mov.unblocked.resonance.data

import android.content.Context
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64

class ClientConfigStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        "resonance.client.config.v1",
        Context.MODE_PRIVATE,
    )

    val cohortKey: String
        get() {
            preferences.getString(COHORT_KEY, null)?.takeIf(::isValidCohortKey)?.let { return it }
            val bytes = ByteArray(16).also(SecureRandom()::nextBytes)
            return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).also { generated ->
                preferences.edit().putString(COHORT_KEY, generated).apply()
            }
        }

    fun readEnvelope(scope: ClientConfigCacheScope): CachedClientConfigEnvelope? {
        val key = cacheKey(scope)
        val encodedBody = preferences.getString("$key.body", null) ?: return null
        val digest = preferences.getString("$key.digest", null) ?: return null
        val signature = preferences.getString("$key.signature", null) ?: return null
        val storedAtEpochMs = preferences.getLong("$key.stored-at", -1L).takeIf { it >= 0L }
            ?: return null
        val body = runCatching { Base64.getDecoder().decode(encodedBody) }.getOrNull() ?: return null
        return CachedClientConfigEnvelope(
            SignedClientConfigEnvelope(body, digest, signature),
            storedAtEpochMs,
        )
    }

    fun writeEnvelope(
        scope: ClientConfigCacheScope,
        envelope: SignedClientConfigEnvelope,
        verifiedRevision: Long,
        storedAtEpochMs: Long = System.currentTimeMillis(),
    ) {
        val key = cacheKey(scope)
        require(ClientConfigRevisionPolicy.accepts(readHighestVerifiedRevision(scope), verifiedRevision)) {
            "A lower client config revision cannot replace the highest verified revision"
        }
        preferences.edit()
            .putString("$key.body", Base64.getEncoder().encodeToString(envelope.body))
            .putString("$key.digest", envelope.contentDigest)
            .putString("$key.signature", envelope.signature)
            .putLong("$key.stored-at", storedAtEpochMs)
            .putLong("$key.highest-revision", verifiedRevision)
            .commit()
    }

    fun readHighestVerifiedRevision(scope: ClientConfigCacheScope): Long? {
        val key = cacheKey(scope)
        return preferences.getLong("$key.highest-revision", -1L).takeIf { it >= 0L }
    }

    fun removeEnvelope(scope: ClientConfigCacheScope) {
        val key = cacheKey(scope)
        preferences.edit()
            .remove("$key.body")
            .remove("$key.digest")
            .remove("$key.signature")
            .remove("$key.stored-at")
            .apply()
    }

    fun readUploadMode(origin: String, profileID: String): ServerUploadMode? {
        val key = transferKey(origin, profileID)
        // Download behavior is server-selected now; discard the obsolete user preference on sight.
        if (preferences.contains("$key.download")) {
            preferences.edit().remove("$key.download").apply()
        }
        return ServerUploadMode.fromWireValue(preferences.getString("$key.upload", null))
    }

    fun writeUploadMode(origin: String, profileID: String, uploadMode: ServerUploadMode) {
        val key = transferKey(origin, profileID)
        preferences.edit()
            .putString("$key.upload", uploadMode.wireValue)
            .remove("$key.download")
            .apply()
    }

    companion object {
        private const val COHORT_KEY = "cohort-key"

        internal fun cacheKey(scope: ClientConfigCacheScope): String = "cache." + digestKey(
            listOf(
                scope.origin,
                scope.profileID,
                scope.platform,
                scope.appVersion,
                scope.appBuild.toString(),
                scope.tokenFingerprint,
            ),
        )

        internal fun transferKey(origin: String, profileID: String): String = "transfer." + digestKey(
            listOf(origin, profileID),
        )

        private fun digestKey(parts: List<String>): String = Base64.getUrlEncoder().withoutPadding()
            .encodeToString(
                MessageDigest.getInstance("SHA-256").digest(
                    parts.joinToString("\n").toByteArray(Charsets.UTF_8),
                ),
            )

        private fun isValidCohortKey(value: String): Boolean =
            ClientConfigVerifier.isCanonicalCohortKey(value)
    }
}

data class ClientConfigCacheScope(
    val origin: String,
    val profileID: String,
    val platform: String,
    val appVersion: String,
    val appBuild: Long,
    val tokenFingerprint: String,
)

data class CachedClientConfigEnvelope(
    val envelope: SignedClientConfigEnvelope,
    val storedAtEpochMs: Long,
) {
    fun isWithinLocalAge(nowEpochMs: Long, maximumAgeMs: Long = 15L * 60L * 1_000L): Boolean {
        if (storedAtEpochMs < 0L || nowEpochMs < storedAtEpochMs) return false
        return nowEpochMs - storedAtEpochMs <= maximumAgeMs
    }
}
