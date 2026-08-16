package mov.unblocked.resonance.data

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class CredentialStore(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(
        "resonance.secure.credentials",
        Context.MODE_PRIVATE,
    )

    var clientToken: String
        get() = readSecret(CLIENT_TOKEN).orEmpty()
        set(value) = writeSecret(CLIENT_TOKEN, value)

    var adminToken: String
        get() = readSecret(ADMIN_TOKEN).orEmpty()
        set(value) = writeSecret(ADMIN_TOKEN, value)

    var serverURL: String
        get() {
            val stored = preferences.getString(SERVER_URL, DEFAULT_SERVER_URL) ?: DEFAULT_SERVER_URL
            val bounded = stored.trim().takeIf { it.length <= ProviderMediaURLPolicy.MAX_URL_LENGTH }
                ?: DEFAULT_SERVER_URL
            return if (bounded.trimEnd('/') == ResonanceLegacyProductionServerURL) {
                DEFAULT_SERVER_URL
            } else {
                bounded
            }
        }
        set(value) {
            val normalized = value.trim()
            require(normalized.length <= ProviderMediaURLPolicy.MAX_URL_LENGTH) {
                "Server URL is too long"
            }
            preferences.edit().putString(SERVER_URL, normalized).apply()
        }

    fun clearTokens() {
        preferences.edit().remove(CLIENT_TOKEN).remove(ADMIN_TOKEN).apply()
    }

    var accountSession: AccountSession?
        get() = readSecret(ACCOUNT_SESSION)?.let {
            runCatching {
                val decoded = JSON.decodeFromString<AccountSession>(it)
                val boundedBaseURL = ProviderMediaURLPolicy.boundedURL(decoded.baseURL)
                    ?: error("Account server URL is missing")
                val canonicalBaseURL = canonicalHTTPSOrigin(boundedBaseURL)
                val imageURL = ProfileImageNetworkPolicy.resolveURL(canonicalBaseURL, decoded.imageURL)?.toString()
                if (canonicalBaseURL == decoded.baseURL && imageURL == decoded.imageURL) {
                    decoded
                } else {
                    decoded.copy(baseURL = canonicalBaseURL, imageURL = imageURL)
                }
            }.getOrNull()
        }
        set(value) {
            if (value == null) preferences.edit().remove(ACCOUNT_SESSION).apply()
            else {
                val baseURL = ProviderMediaURLPolicy.boundedURL(value.baseURL)
                require(baseURL != null) { "Account server URL is missing" }
                val canonicalBaseURL = canonicalHTTPSOrigin(baseURL)
                writeSecret(
                    ACCOUNT_SESSION,
                    JSON.encodeToString(value.copy(
                        baseURL = canonicalBaseURL,
                        imageURL = ProfileImageNetworkPolicy.resolveURL(canonicalBaseURL, value.imageURL)?.toString(),
                    )),
                )
            }
        }

    var pendingAccountSignIn: PendingAccountSignIn?
        get() = readSecret(PENDING_ACCOUNT_SIGN_IN)?.let {
            runCatching {
                JSON.decodeFromString<PendingAccountSignIn>(it).let { pending ->
                    pending.copy(
                        baseURL = ProviderMediaURLPolicy.boundedURL(pending.baseURL)
                            ?: error("Pending account server URL is missing"),
                    )
                }
            }.getOrNull()
        }
        set(value) {
            if (value == null) preferences.edit().remove(PENDING_ACCOUNT_SIGN_IN).apply()
            else {
                val baseURL = ProviderMediaURLPolicy.boundedURL(value.baseURL)
                require(baseURL != null) { "Pending account server URL is missing" }
                writeSecret(
                    PENDING_ACCOUNT_SIGN_IN,
                    JSON.encodeToString(value.copy(baseURL = baseURL)),
                )
            }
        }

    private fun writeSecret(account: String, value: String) {
        if (value.isEmpty()) {
            preferences.edit().remove(account).apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        cipher.updateAAD(account.toByteArray(Charsets.UTF_8))
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val payload = ByteBuffer.allocate(Int.SIZE_BYTES + cipher.iv.size + encrypted.size)
            .putInt(cipher.iv.size)
            .put(cipher.iv)
            .put(encrypted)
            .array()
        preferences.edit().putString(account, Base64.encodeToString(payload, Base64.NO_WRAP)).apply()
    }

    private fun readSecret(account: String): String? = runCatching {
        val encoded = preferences.getString(account, null) ?: return null
        val payload = ByteBuffer.wrap(Base64.decode(encoded, Base64.NO_WRAP))
        val ivLength = payload.int
        require(ivLength in 12..32 && payload.remaining() > ivLength) { "Invalid credential payload" }
        val iv = ByteArray(ivLength).also { payload.get(it) }
        val encrypted = ByteArray(payload.remaining()).also { payload.get(it) }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, iv))
        cipher.updateAAD(account.toByteArray(Charsets.UTF_8))
        cipher.doFinal(encrypted).toString(Charsets.UTF_8)
    }.getOrNull()

    @Synchronized
    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "mov.unblocked.resonance.server-credentials.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val CLIENT_TOKEN = "client-token"
        const val ADMIN_TOKEN = "admin-token"
        const val SERVER_URL = "server-url"
        const val ACCOUNT_SESSION = "account-session-v1"
        const val PENDING_ACCOUNT_SIGN_IN = "pending-account-sign-in-v1"
        const val DEFAULT_SERVER_URL = ResonanceProductionServerURL
        val JSON = Json { ignoreUnknownKeys = true }
    }
}
