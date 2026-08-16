package mov.unblocked.resonance.playback

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/** A short-lived, provider-only stream handle. It deliberately stores no bearer token. */
internal data class ListenAlongProviderStreamHandle(
    val id: String,
    val playbackURI: Uri,
)

internal object ListenAlongProviderStreamPolicy {
    private val allowedHeaders = setOf(
        "accept",
        "accept-language",
        "origin",
        "referer",
        "user-agent",
        "x-goog-visitor-id",
    )

    fun register(
        url: String,
        headers: Map<String, String>,
        lifetimeSeconds: Long = 240L,
    ): ListenAlongProviderStreamHandle {
        val validated = validateURL(URL(url))
        val safeHeaders = safeHeaders(headers)
        val id = Base64.getUrlEncoder().withoutPadding().encodeToString(
            ByteArray(18).also(SecureRandom()::nextBytes),
        )
        providerStreams[id] = Entry(
            url = validated,
            headers = safeHeaders,
            expiresAt = AtomicReference(Instant.now().plusSeconds(lifetimeSeconds.coerceIn(30L, 900L))),
        )
        return ListenAlongProviderStreamHandle(id, Uri.parse("resonance-listen://session/$id"))
    }

    internal fun isAllowedSourceURL(value: String): Boolean = runCatching {
        validateURL(URL(value))
    }.isSuccess

    internal fun areSafeHeaders(headers: Map<String, String>): Boolean = runCatching {
        safeHeaders(headers)
    }.isSuccess

    fun remove(id: String?) {
        id?.let(providerStreams::remove)?.expiresAt?.set(Instant.EPOCH)
    }

    fun clearAll() {
        providerStreams.values.forEach { it.expiresAt.set(Instant.EPOCH) }
        providerStreams.clear()
    }

    fun renew(id: String?, url: String, headers: Map<String, String>): Boolean {
        val key = id ?: return false
        val entry = providerStreams[key] ?: return false
        val replacement = runCatching { validateURL(URL(url)) }.getOrNull() ?: return false
        if (!Instant.now().isBefore(entry.expiresAt.get())) return false
        val safeHeaders = safeHeaders(headers)
        providerStreams[key] = entry.copy(
            url = replacement,
            headers = safeHeaders,
            expiresAt = AtomicReference(Instant.now().plusSeconds(240L)),
        )
        return true
    }

    internal fun entry(uri: Uri): Entry? {
        if (uri.scheme != "resonance-listen" || uri.host != "session") return null
        val id = uri.pathSegments.singleOrNull() ?: return null
        val entry = providerStreams[id] ?: return null
        if (!Instant.now().isBefore(entry.expiresAt.get())) {
            providerStreams.remove(id, entry)
            return null
        }
        return entry
    }

    internal fun validateRedirect(current: URL, location: String): URL {
        val resolved = runCatching { URI(current.toString()).resolve(location).toURL() }
            .getOrElse { throw IOException("The provider stream redirect is invalid") }
        return validateURL(resolved)
    }

    private fun validateURL(url: URL): URL {
        val host = url.host.lowercase().trimEnd('.')
        val allowed = host == "googlevideo.com" || host.endsWith(".googlevideo.com") ||
            host == "sndcdn.com" || host.endsWith(".sndcdn.com")
        require(url.protocol.equals("https", true) && url.userInfo == null && allowed) {
            "The provider stream URL is not allowed"
        }
        return url
    }

    internal data class Entry(
        val url: URL,
        val headers: Map<String, String>,
        val expiresAt: AtomicReference<Instant>,
    )

    private fun safeHeaders(headers: Map<String, String>): Map<String, String> {
        require(headers.keys.none { it.equals("authorization", true) || it.equals("cookie", true) }) {
            "Provider playback headers cannot contain credentials"
        }
        return headers
            .filterKeys { it.lowercase() in allowedHeaders }
            .filterValues { it.isNotBlank() && it.length <= 2_048 }
            .toMap()
    }

    private val providerStreams = ConcurrentHashMap<String, Entry>()
}

/** Media3 data source for an already-resolved YouTube/SoundCloud rendition. */
@UnstableApi
internal class ListenAlongProviderDataSource : BaseDataSource(true) {
    private var connection: HttpURLConnection? = null
    private var input: InputStream? = null
    private var opened = false
    private var remaining = C.LENGTH_UNSET.toLong()
    private var resolvedURI: Uri? = null
    private var responseHeaders: Map<String, List<String>> = emptyMap()
    private var expiry: AtomicReference<Instant>? = null

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val entry = ListenAlongProviderStreamPolicy.entry(dataSpec.uri)
            ?: throw IOException("The listen-along provider stream is unavailable")
        expiry = entry.expiresAt
        val result = openConnection(entry, dataSpec)
        val openedConnection = result.connection
        connection = openedConnection
        resolvedURI = openedConnection.url?.toString()?.let(Uri::parse)
        responseHeaders = openedConnection.headerFields
            .filterKeys { it != null }
            .mapKeys { requireNotNull(it.key) }
        var stream = openedConnection.inputStream
        if (dataSpec.position > 0L && openedConnection.responseCode == HttpURLConnection.HTTP_OK) {
            stream = stream.also { skipFully(it, dataSpec.position) }
        }
        input = stream
        val responseLength = openedConnection.contentLengthLong.takeIf { it >= 0L }
        remaining = StreamRangePolicy.remainingLength(
            requestedLength = dataSpec.length.takeIf { it != C.LENGTH_UNSET.toLong() },
            responseLength = responseLength,
            requestedPosition = dataSpec.position,
            partialRange = result.partialRange,
        ) ?: C.LENGTH_UNSET.toLong()
        opened = true
        transferStarted(dataSpec)
        return remaining
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        if (!Instant.now().isBefore(expiry?.get() ?: Instant.EPOCH)) {
            throw IOException("The listen-along provider stream has expired")
        }
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val allowed = if (remaining == C.LENGTH_UNSET.toLong()) {
            length
        } else {
            minOf(length.toLong(), remaining).toInt()
        }
        val read = input?.read(buffer, offset, allowed) ?: C.RESULT_END_OF_INPUT
        if (read < 0) {
            if (remaining != C.LENGTH_UNSET.toLong() && remaining > 0L) {
                throw EOFException("The provider stream ended early")
            }
            return C.RESULT_END_OF_INPUT
        }
        if (remaining != C.LENGTH_UNSET.toLong()) remaining -= read
        bytesTransferred(read)
        return read
    }

    override fun getUri(): Uri? = resolvedURI

    override fun getResponseHeaders(): Map<String, List<String>> = responseHeaders

    override fun close() {
        try {
            input?.close()
        } finally {
            input = null
            connection?.disconnect()
            connection = null
            resolvedURI = null
            responseHeaders = emptyMap()
            expiry = null
            remaining = C.LENGTH_UNSET.toLong()
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }

    private fun openConnection(
        initial: ListenAlongProviderStreamPolicy.Entry,
        dataSpec: DataSpec,
    ): OpenedConnection {
        var currentURL = initial.url
        repeat(MAX_REDIRECTS + 1) { redirectCount ->
            if (!Instant.now().isBefore(initial.expiresAt.get())) {
                throw IOException("The listen-along provider stream has expired")
            }
            val connection = (currentURL.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                useCaches = false
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                initial.headers.forEach { (key, value) -> setRequestProperty(key, value) }
                setRequestProperty("Accept-Encoding", "identity")
                val rangeEnd = dataSpec.length
                    .takeIf { it != C.LENGTH_UNSET.toLong() }
                    ?.let { length -> dataSpec.position + length - 1L }
                if (dataSpec.position > 0L || rangeEnd != null) {
                    setRequestProperty("Range", "bytes=${dataSpec.position}-${rangeEnd?.toString().orEmpty()}")
                }
            }
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_OK || status == HttpURLConnection.HTTP_PARTIAL) {
                val partialRange = if (status == HttpURLConnection.HTTP_PARTIAL) {
                    runCatching {
                        StreamRangePolicy.validatePartialResponse(
                            contentRange = connection.getHeaderField("Content-Range"),
                            requestedStart = dataSpec.position,
                            requestedLength = dataSpec.length.takeIf { it != C.LENGTH_UNSET.toLong() },
                            responseLength = connection.contentLengthLong.takeIf { it >= 0L },
                        )
                    }.getOrElse {
                        connection.disconnect()
                        throw it
                    }
                } else null
                return OpenedConnection(connection, partialRange)
            }
            if (status !in REDIRECT_STATUSES || redirectCount == MAX_REDIRECTS) {
                connection.disconnect()
                throw IOException("The provider stream returned HTTP $status")
            }
            val location = connection.getHeaderField("Location")
            if (location.isNullOrBlank()) {
                connection.disconnect()
                throw IOException("The provider stream redirect is missing a location")
            }
            currentURL = try {
                ListenAlongProviderStreamPolicy.validateRedirect(currentURL, location)
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("The provider stream redirected too many times")
    }

    private fun skipFully(stream: InputStream, bytes: Long) {
        var remainingBytes = bytes
        val buffer = ByteArray(16 * 1_024)
        while (remainingBytes > 0L) {
            val skipped = stream.skip(remainingBytes)
            if (skipped > 0L) {
                remainingBytes -= skipped
                continue
            }
            val read = stream.read(buffer, 0, minOf(buffer.size.toLong(), remainingBytes).toInt())
            if (read < 0) throw EOFException("The provider stream ended before the requested range")
            remainingBytes -= read
        }
    }

    internal class Factory : DataSource.Factory {
        override fun createDataSource(): DataSource = ListenAlongProviderDataSource()
    }

    private data class OpenedConnection(
        val connection: HttpURLConnection,
        val partialRange: ValidatedContentRange?,
    )

    private companion object {
        const val CONNECT_TIMEOUT_MS = 20_000
        const val READ_TIMEOUT_MS = 120_000
        const val MAX_REDIRECTS = 5
        val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
    }
}
