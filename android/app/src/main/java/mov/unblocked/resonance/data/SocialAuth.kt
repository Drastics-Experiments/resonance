package mov.unblocked.resonance.data

import android.net.Uri
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

val ResonanceSocialAuthProviders = listOf("clerk")
const val ResonanceAuthCallback = "resonance://auth/callback"
const val ResonanceLegacyProductionServerURL = "https://music.unblocked.mov"
const val ResonanceProductionServerURL = "https://resonance-core.blithe-haven-9710.chatgpt.site"
const val ResonanceAccountSignInServerURL = "https://resonance-core.blithe-haven-9710.chatgpt.site/"

object AccountEmailPrivacy {
    const val CensoredAddress = "••••••@••••••.•••"

    fun displayedAddress(email: String, isRevealed: Boolean): String =
        if (isRevealed) email else CensoredAddress

    fun safeDisplayName(value: String?, email: String?): String {
        val candidate = value?.trim().orEmpty()
        val looksLikeEmail = candidate.substringAfter('@', "").contains('.') && '@' in candidate
        return candidate.takeIf {
            it.isNotEmpty() && !looksLikeEmail && !it.equals(email, ignoreCase = true)
        } ?: "Clerk account"
    }
}

object AccountScopePolicy {
    fun resolvedProfileID(
        accountID: String?,
        serverProfileID: String?,
        requestedLegacyProfileID: String?,
    ): String? {
        val accountScope = accountID?.trim().orEmpty()
        if (accountScope.isEmpty()) return null
        val serverScope = serverProfileID?.trim().orEmpty()
        if (serverScope.isNotEmpty()) return accountScope.takeIf { serverScope == accountScope }
        return requestedLegacyProfileID?.trim()?.takeIf(String::isNotEmpty) ?: "default"
    }
}

@Serializable
data class AccountSession(
    val accessToken: String,
    val refreshToken: String,
    val expiresAt: Long,
    val email: String,
    val role: String,
    val baseURL: String,
    val accountID: String? = null,
    val profileID: String? = null,
    val displayName: String? = null,
    val imageURL: String? = null,
    @Transient val migratedProfileID: String? = null,
) {
    val usesNativeClerkSession: Boolean
        get() = refreshToken == NativeClerkRefreshMarker
    val profileDisplayName: String
        get() = AccountEmailPrivacy.safeDisplayName(displayName, email)
}

const val NativeClerkRefreshMarker = "clerk-native-session"

data class NativeAuthConfiguration(
    val publishableKey: String,
    val tokenTemplate: String,
)

@Serializable
data class PendingAccountSignIn(
    val baseURL: String,
    val verifier: String,
    val state: String,
    val startedAt: Long,
)

@Serializable
private data class AuthConfigurationPayload(
    val version: Int,
    val issuer: String,
    @SerialName("publishable_key") val publishableKey: String? = null,
    @SerialName("token_template") val tokenTemplate: String? = null,
    @SerialName("authorization_endpoint") val authorizationEndpoint: String,
    @SerialName("token_endpoint") val tokenEndpoint: String,
    @SerialName("user_endpoint") val userEndpoint: String,
    @SerialName("logout_endpoint") val logoutEndpoint: String,
    @SerialName("client_id") val clientID: String,
    val scope: String,
    @SerialName("redirect_uri") val redirectURI: String,
    val providers: List<String>,
)

private data class AuthConfiguration(
    val issuer: String,
    val authorizationEndpoint: URL,
    val tokenEndpoint: URL,
    val logoutEndpoint: URL,
    val clientID: String,
    val scope: String,
    val providers: Set<String>,
    val native: NativeAuthConfiguration?,
)

@Serializable
private data class TokenPayload(
    @SerialName("id_token") val idToken: String = "",
    @SerialName("refresh_token") val refreshToken: String = "",
    @SerialName("expires_in") val expiresIn: Long = 0,
    val error: String? = null,
    @SerialName("error_description") val errorDescription: String? = null,
    val msg: String? = null,
)

@Serializable
private data class AccountPayload(
    val id: String = "",
    val email: String = "",
    val role: String = "",
    @SerialName("profile_id") val profileID: String = "",
    @SerialName("migrated_profile_id") val migratedProfileID: String? = null,
    @SerialName("display_name") val displayName: String = "",
    @SerialName("image_url") val imageURL: String? = null,
    val error: String? = null,
)

private val authJSON = Json { ignoreUnknownKeys = true }

class SocialAuthClient(private val baseURL: String) {
    private val origin = canonicalHTTPSOrigin(baseURL)

    suspend fun begin(provider: String): Pair<Uri, PendingAccountSignIn> = withContext(Dispatchers.IO) {
        val configuration = configuration()
        require(provider in configuration.providers) { "This sign-in provider is not enabled by the server." }
        val verifierBytes = ByteArray(48).also(SecureRandom()::nextBytes)
        val verifier = verifierBytes.base64URL()
        val state = ByteArray(32).also(SecureRandom()::nextBytes).base64URL()
        val challenge = MessageDigest.getInstance("SHA-256")
            .digest(verifier.toByteArray(Charsets.US_ASCII))
            .base64URL()
        val destination = Uri.parse(configuration.authorizationEndpoint.toString()).buildUpon()
            .appendQueryParameter("client_id", configuration.clientID)
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("redirect_uri", ResonanceAuthCallback)
            .appendQueryParameter("scope", configuration.scope)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", state)
            .build()
        destination to PendingAccountSignIn(origin, verifier, state, System.currentTimeMillis())
    }

    suspend fun nativeConfiguration(): NativeAuthConfiguration = withContext(Dispatchers.IO) {
        configuration().native ?: error("This Resonance server has not enabled native account sign-in.")
    }

    suspend fun accountSession(
        nativeToken: String,
        migrationProfileID: String? = null,
    ): AccountSession = withContext(Dispatchers.IO) {
        val expiration = jwtExpiration(nativeToken)
        val account = account(nativeToken, migrationProfileID)
        require(account.role == "member" || account.role == "admin") {
            account.error ?: "This account could not access this Resonance server."
        }
        val accountID = bounded(account.id, "Clerk account ID")
        val profileID = AccountScopePolicy.resolvedProfileID(
            accountID,
            account.profileID,
            migrationProfileID,
        ) ?: error(
            "The Resonance server returned a legacy profile instead of this Clerk account library."
        )
        val displayName = account.displayName.trim().takeIf(String::isNotEmpty)?.let {
            bounded(it, "Clerk display name")
        }
        AccountSession(
            accessToken = bounded(nativeToken, "Clerk session token"),
            refreshToken = NativeClerkRefreshMarker,
            expiresAt = expiration,
            email = bounded(account.email, "account email").lowercase(),
            role = account.role,
            baseURL = origin,
            accountID = accountID,
            profileID = bounded(profileID, "Clerk profile ID"),
            displayName = displayName,
            imageURL = ProfileImageNetworkPolicy.resolveURL(origin, account.imageURL)?.toString(),
            migratedProfileID = account.migratedProfileID,
        )
    }

    suspend fun exchange(
        code: String,
        state: String?,
        pending: PendingAccountSignIn,
        migrationProfileID: String? = null,
    ): AccountSession = withContext(Dispatchers.IO) {
        require(
            canonicalHTTPSOrigin(pending.baseURL) == origin && state == pending.state &&
                System.currentTimeMillis() - pending.startedAt <= 10 * 60_000
        ) {
            "The sign-in request expired. Please try again."
        }
        val configuration = configuration()
        val token = tokenRequest(
            configuration,
            mapOf(
                "grant_type" to "authorization_code",
                "client_id" to configuration.clientID,
                "redirect_uri" to ResonanceAuthCallback,
                "code" to bounded(code, "authorization code"),
                "code_verifier" to pending.verifier,
            ),
        )
        session(
            token,
            account(token.idToken, migrationProfileID),
            origin,
            requestedLegacyProfileID = migrationProfileID,
        )
    }

    suspend fun refresh(
        current: AccountSession,
        migrationProfileID: String? = null,
    ): AccountSession = withContext(Dispatchers.IO) {
        require(canonicalHTTPSOrigin(current.baseURL) == origin) {
            "The account session belongs to a different server."
        }
        val configuration = configuration()
        val token = tokenRequest(
            configuration,
            mapOf(
                "grant_type" to "refresh_token",
                "client_id" to configuration.clientID,
                "refresh_token" to bounded(current.refreshToken, "refresh token"),
            ),
        )
        session(
            token,
            account(token.idToken, current.profileID ?: migrationProfileID),
            origin,
            current.refreshToken,
            current.profileID ?: migrationProfileID,
        )
    }

    suspend fun signOut(current: AccountSession) = withContext(Dispatchers.IO) {
        runCatching {
            val configuration = configuration()
            request(
                configuration.logoutEndpoint,
                "POST",
                mapOf(
                    "Accept" to "application/json",
                    "Content-Type" to "application/json",
                    "Authorization" to "Bearer ${bounded(current.accessToken, "access token")}",
                ),
                authJSON.encodeToString(mapOf("refresh_token" to current.refreshToken)),
            )
        }
        Unit
    }

    private fun configuration(): AuthConfiguration {
        val response = request(URL(origin + "/api/v1/auth/config"), "GET", mapOf("Accept" to "application/json"))
        require(response.code in 200..299) { "Account sign-in is unavailable (HTTP ${response.code})." }
        val payload = authJSON.decodeFromString<AuthConfigurationPayload>(response.body)
        require(
            payload.version in setOf(2, 3) && payload.redirectURI == ResonanceAuthCallback &&
                payload.scope == "openid profile email"
        ) {
            "The server returned an unsupported account sign-in configuration."
        }
        val issuer = canonicalHTTPSOrigin(payload.issuer)
        val authorization = URL(payload.authorizationEndpoint)
        val token = URL(payload.tokenEndpoint)
        val user = URL(payload.userEndpoint)
        val logout = URL(payload.logoutEndpoint)
        require(listOf(authorization, token, user).all { canonicalHTTPSOrigin(it.toString()) == issuer }) {
            "The account sign-in endpoints are invalid."
        }
        require(canonicalHTTPSOrigin(logout.toString()) == origin && logout.path == "/api/v1/auth/logout") {
            "The account sign-out endpoint is invalid."
        }
        val providers = payload.providers.filter(ResonanceSocialAuthProviders::contains).toSet()
        require(providers.isNotEmpty() && payload.clientID.isNotBlank()) {
            "Clerk sign-in is not enabled by the server."
        }
        val native = if (payload.version == 3) {
            val publishableKey = bounded(payload.publishableKey.orEmpty(), "Clerk publishable key")
            val tokenTemplate = payload.tokenTemplate.orEmpty()
            require(validPublishableKey(publishableKey, issuer) && tokenTemplate == "resonance") {
                "The server returned an invalid native sign-in configuration."
            }
            NativeAuthConfiguration(publishableKey, tokenTemplate)
        } else {
            null
        }
        return AuthConfiguration(
            issuer,
            authorization,
            token,
            logout,
            bounded(payload.clientID, "Clerk client ID"),
            payload.scope,
            providers,
            native,
        )
    }

    private fun tokenRequest(configuration: AuthConfiguration, fields: Map<String, String>): TokenPayload {
        val response = request(
            configuration.tokenEndpoint,
            "POST",
            mapOf(
                "Accept" to "application/json",
                "Content-Type" to "application/x-www-form-urlencoded",
            ),
            fields.entries.joinToString("&") { (key, value) ->
                "${URLEncoder.encode(key, Charsets.UTF_8.name())}=${URLEncoder.encode(value, Charsets.UTF_8.name())}"
            },
        )
        val payload = authJSON.decodeFromString<TokenPayload>(response.body)
        require(response.code in 200..299) {
            payload.msg ?: payload.errorDescription ?: payload.error ?: "Sign-in could not be completed."
        }
        return payload
    }

    private fun account(accessToken: String, migrationProfileID: String? = null): AccountPayload {
        val headers = mutableMapOf(
            "Accept" to "application/json",
            "Authorization" to "Bearer ${bounded(accessToken, "access token")}",
        )
        migrationProfileID?.trim()?.takeIf(String::isNotEmpty)?.let {
            headers["X-Resonance-Profile"] = it
        }
        val response = request(
            URL(origin + "/api/v1/auth/me"),
            "GET",
            headers,
        )
        val payload = authJSON.decodeFromString<AccountPayload>(response.body)
        require(response.code in 200..299) { payload.error ?: "This account could not access this Resonance server." }
        return payload
    }

    private fun session(
        token: TokenPayload,
        account: AccountPayload,
        serverOrigin: String,
        fallbackRefreshToken: String = "",
        requestedLegacyProfileID: String? = null,
    ): AccountSession {
        require(token.expiresIn in 1..604_800) { "The authentication server returned an invalid session lifetime." }
        require(account.role == "member" || account.role == "admin") { "The Resonance server returned an invalid account role." }
        val accountID = bounded(account.id, "Clerk account ID")
        val profileID = AccountScopePolicy.resolvedProfileID(
            accountID,
            account.profileID,
            requestedLegacyProfileID,
        ) ?: error(
            "The Resonance server returned a legacy profile instead of this Clerk account library."
        )
        val displayName = account.displayName.trim().takeIf(String::isNotEmpty)?.let {
            bounded(it, "Clerk display name")
        }
        return AccountSession(
            accessToken = bounded(token.idToken, "Clerk ID token"),
            refreshToken = bounded(token.refreshToken.ifBlank { fallbackRefreshToken }, "refresh token"),
            expiresAt = System.currentTimeMillis() + token.expiresIn * 1000,
            email = bounded(account.email, "account email").lowercase(),
            role = account.role,
            baseURL = serverOrigin,
            accountID = accountID,
            profileID = bounded(profileID, "Clerk profile ID"),
            displayName = displayName,
            imageURL = ProfileImageNetworkPolicy.resolveURL(serverOrigin, account.imageURL)?.toString(),
            migratedProfileID = account.migratedProfileID,
        )
    }

    private fun jwtExpiration(token: String): Long {
        val parts = bounded(token, "Clerk session token").split('.')
        require(parts.size == 3) { "Clerk returned an invalid session token." }
        val decoded = runCatching {
            Base64.decode(parts[1], Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        }.getOrElse { throw IllegalArgumentException("Clerk returned an invalid session token.") }
        val expirationSeconds = runCatching {
            authJSON.parseToJsonElement(decoded.toString(Charsets.UTF_8)).jsonObject
                .getValue("exp").jsonPrimitive.long
        }.getOrElse { throw IllegalArgumentException("Clerk returned an invalid session token.") }
        val expiration = expirationSeconds * 1000
        require(expiration in (System.currentTimeMillis() + 1)..(System.currentTimeMillis() + 604_800_000)) {
            "Clerk returned an invalid session lifetime."
        }
        return expiration
    }

    private data class Response(val code: Int, val body: String)

    private fun request(url: URL, method: String, headers: Map<String, String>, body: String? = null): Response {
        val connection = (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 15_000
            readTimeout = 30_000
            instanceFollowRedirects = false
            headers.forEach(::setRequestProperty)
            if (body != null) {
                doOutput = true
                outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            }
        }
        return try {
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val bodyText = stream?.use { readBoundedText(it, MAX_AUTH_RESPONSE_BYTES) }.orEmpty()
            Response(status, bodyText)
        } finally {
            connection.disconnect()
        }
    }

    private fun readBoundedText(input: java.io.InputStream, maximumBytes: Int): String {
        if (input.available() > maximumBytes) throw IOException("The authentication response is too large")
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(32 * 1_024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size() > maximumBytes - count) {
                throw IOException("The authentication response is too large")
            }
            output.write(buffer, 0, count)
        }
        return output.toString(Charsets.UTF_8.name())
    }

    private companion object {
        const val MAX_AUTH_RESPONSE_BYTES = 512 * 1_024
    }
}

private fun validPublishableKey(key: String, issuer: String): Boolean {
    val encoded = when {
        key.startsWith("pk_test_") -> key.removePrefix("pk_test_")
        key.startsWith("pk_live_") -> key.removePrefix("pk_live_")
        else -> return false
    }
    val frontendHost = runCatching {
        Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            .toString(Charsets.UTF_8)
            .removeSuffix("$")
            .lowercase()
    }.getOrNull() ?: return false
    return frontendHost == URL(issuer).host.lowercase()
}

fun canonicalHTTPSOrigin(value: String): String {
    val url = URL(value.trim())
    require(url.protocol == "https" && url.userInfo == null && url.host.isNotBlank()) { "Server URL must use HTTPS." }
    val port = if (url.port == -1 || url.port == 443) "" else ":${url.port}"
    val host = if (port.isEmpty() && url.host.equals("music.unblocked.mov", ignoreCase = true)) {
        "resonance-core.blithe-haven-9710.chatgpt.site"
    } else {
        url.host.lowercase()
    }
    return "https://$host$port"
}

private fun bounded(value: String, label: String): String {
    val text = value.trim()
    require(text.isNotEmpty() && text.length <= 16 * 1024 && text.none { it.code < 0x20 || it.code == 0x7f }) {
        "The $label is invalid."
    }
    return text
}

private fun ByteArray.base64URL(): String = Base64.encodeToString(
    this,
    Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
)
