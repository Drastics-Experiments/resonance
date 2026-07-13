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
        get() = preferences.getString(SERVER_URL, DEFAULT_SERVER_URL) ?: DEFAULT_SERVER_URL
        set(value) {
            preferences.edit().putString(SERVER_URL, value.trim()).apply()
        }

    fun clearTokens() {
        preferences.edit().remove(CLIENT_TOKEN).remove(ADMIN_TOKEN).apply()
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
        const val DEFAULT_SERVER_URL = "https://music.unblocked.mov"
    }
}
