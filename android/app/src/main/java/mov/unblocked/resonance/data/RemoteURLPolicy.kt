package mov.unblocked.resonance.data

import java.net.URI
import java.net.URL

/** Shared checks for URLs that are opened without the configured server's auth boundary. */
internal object RemoteURLPolicy {
    const val MAX_URL_LENGTH = 8_192
    private val cleartextDevelopmentHosts = setOf("127.0.0.1", "10.0.2.2")

    fun isSafeURL(
        url: URL,
        approvedHost: (String) -> Boolean,
        allowCleartextDevelopment: Boolean = false,
    ): Boolean {
        if (url.toString().length > MAX_URL_LENGTH) return false
        val host = url.host.trimEnd('.').lowercase()
        if (host.isBlank() || url.userInfo != null || url.ref != null) return false
        val localDevelopment = allowCleartextDevelopment &&
            url.protocol.equals("http", ignoreCase = true) &&
            host in cleartextDevelopmentHosts &&
            (url.port == -1 || url.port in 1..65_535)
        if (localDevelopment) return true
        return url.protocol.equals("https", ignoreCase = true) &&
            (url.port == -1 || url.port == 443) &&
            approvedHost(host) &&
            !ServerNetworkPolicy.isPrivateOrLocalHost(host)
    }

    fun resolveRedirect(
        currentURL: URL,
        location: String,
        approvedHost: (String) -> Boolean,
        allowCleartextDevelopment: Boolean = false,
    ): URL? {
        val next = runCatching {
            currentURL.toURI().resolve(URI(location.trim())).toURL()
        }.getOrNull() ?: return null
        return next.takeIf { isSafeURL(it, approvedHost, allowCleartextDevelopment) }
    }
}
