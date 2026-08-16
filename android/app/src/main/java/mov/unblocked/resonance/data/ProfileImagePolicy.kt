package mov.unblocked.resonance.data

import android.graphics.BitmapFactory
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.URI
import java.net.URL

/** Public destinations that may host a Clerk profile image. */
internal object ProfileImageNetworkPolicy {
    private val clerkImageHosts = setOf("img.clerk.com", "images.clerk.dev")

    fun resolveURL(baseURL: String, value: String?): URL? {
        val base = normalizedBaseURL(baseURL) ?: return null
        val imageURL = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
        val resolved = runCatching {
            base.toURI().resolve(URI(imageURL)).toURL()
        }.getOrNull() ?: return null
        return resolved.takeIf { isAllowed(base, it) }
    }

    fun resolveRedirect(baseURL: String, currentURL: URL, location: String): URL? {
        val base = normalizedBaseURL(baseURL) ?: return null
        if (location.trim().isEmpty()) return null
        return RemoteURLPolicy.resolveRedirect(
            currentURL = currentURL,
            location = location,
            approvedHost = { host -> isApprovedHost(base, host) },
        )?.takeIf { isAllowed(base, it) }
    }

    private fun normalizedBaseURL(value: String): URL? {
        val bounded = ProviderMediaURLPolicy.boundedURL(value) ?: return null
        return runCatching {
            URL(ServerNetworkPolicy.normalizeServerURL(bounded, allowCleartextDevelopment = false))
        }.getOrNull()
    }

    private fun isAllowed(base: URL, candidate: URL): Boolean = RemoteURLPolicy.isSafeURL(
        candidate,
        approvedHost = { host -> isApprovedHost(base, host) },
    )

    private fun isApprovedHost(base: URL, host: String): Boolean {
        val normalized = host.trimEnd('.').lowercase()
        return normalized == base.host.trimEnd('.').lowercase() || normalized in clerkImageHosts
    }
}

/** Bounds encoded profile-image bytes before decoding and bounds the decoded bitmap dimensions. */
internal object ProfileImagePayloadPolicy {
    const val MAX_BYTES = 5L * 1_024L * 1_024L
    const val MAX_DECODED_EDGE = 8_192
    const val MAX_DECODED_PIXELS = 16L * 1_024L * 1_024L

    fun readBoundedBytes(input: InputStream): ByteArray? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(32 * 1_024)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            if (output.size().toLong() + count > MAX_BYTES) return null
            output.write(buffer, 0, count)
        }
        return output.toByteArray().takeIf(ByteArray::isNotEmpty)
    }

    fun hasSafeDecodedBounds(bytes: ByteArray): Boolean {
        if (bytes.isEmpty() || bytes.size.toLong() > MAX_BYTES) return false
        return runCatching {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            val width = bounds.outWidth
            val height = bounds.outHeight
            width > 0 && height > 0 &&
                width <= MAX_DECODED_EDGE && height <= MAX_DECODED_EDGE &&
                width.toLong() * height.toLong() <= MAX_DECODED_PIXELS
        }.getOrDefault(false)
    }
}
