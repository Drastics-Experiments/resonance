package mov.unblocked.resonance.playback

import android.net.Uri
import androidx.media3.common.C
import androidx.media3.datasource.BaseDataSource
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.common.util.UnstableApi
import mov.unblocked.resonance.BuildConfig
import mov.unblocked.resonance.data.ClientContextHeaderPolicy
import mov.unblocked.resonance.data.ServerNetworkPolicy
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

internal data class AuthenticatedStreamHandle(
    val id: String,
    val playbackURI: Uri,
)

internal object AuthenticatedStreamRegistry {
    private data class Entry(
        val baseURL: String,
        val streamURL: URL,
        val accessToken: String,
        val profileID: String,
        val cohortKey: String,
        val authorizationExpiry: AtomicReference<Instant>,
        val allowCleartextDevelopment: Boolean,
    )

    private val entries = ConcurrentHashMap<String, Entry>()

    fun register(
        baseURL: String,
        streamURL: String,
        accessToken: String,
        profileID: String,
        cohortKey: String,
        authorizationExpiresAt: Instant,
        allowCleartextDevelopment: Boolean,
    ): AuthenticatedStreamHandle {
        require(accessToken.isNotBlank()) { "Sign in to stream" }
        require(profileID.isNotBlank()) { "The stream profile is missing" }
        require(cohortKey.isNotBlank()) { "The anonymous client cohort key is unavailable" }
        require(Instant.now().isBefore(authorizationExpiresAt)) { "The server stream policy has expired" }
        val authorized = ServerNetworkPolicy.resolveAuthorizedMediaURL(
            baseURL,
            streamURL,
            allowCleartextDevelopment,
        )
        val id = Base64.getUrlEncoder().withoutPadding().encodeToString(
            ByteArray(18).also(SecureRandom()::nextBytes),
        )
        entries[id] = Entry(
            baseURL,
            authorized,
            accessToken,
            profileID,
            cohortKey,
            AtomicReference(authorizationExpiresAt),
            allowCleartextDevelopment,
        )
        return AuthenticatedStreamHandle(id, Uri.parse("resonance-stream://session/$id"))
    }

    fun remove(id: String?) {
        id?.let(entries::remove)?.authorizationExpiry?.set(Instant.EPOCH)
    }

    fun clearAll() {
        entries.values.forEach { it.authorizationExpiry.set(Instant.EPOCH) }
        entries.clear()
    }

    fun authorizationExpiresAt(id: String?): Instant? = id
        ?.let(entries::get)
        ?.authorizationExpiry
        ?.get()
        ?.takeIf { Instant.now().isBefore(it) }

    fun renew(
        id: String?,
        baseURL: String,
        accessToken: String,
        profileID: String,
        cohortKey: String,
        authorizationExpiresAt: Instant,
    ): Boolean {
        val key = id ?: return false
        if (!Instant.now().isBefore(authorizationExpiresAt)) return false
        val entry = entries[key] ?: return false
        if (
            entry.baseURL != baseURL ||
            entry.accessToken != accessToken ||
            entry.profileID != profileID ||
            entry.cohortKey != cohortKey
        ) return false
        while (true) {
            val current = entry.authorizationExpiry.get()
            val authoritative = StreamLeaseExpiryPolicy.authoritativeReplacement(
                current = current,
                signed = authorizationExpiresAt,
                now = Instant.now(),
            ) ?: return false
            if (authoritative == current) return true
            if (entry.authorizationExpiry.compareAndSet(current, authoritative)) return true
        }
    }

    internal fun entry(uri: Uri): StreamRequest? {
        if (uri.scheme != "resonance-stream" || uri.host != "session") return null
        val id = uri.pathSegments.singleOrNull() ?: return null
        val entry = entries[id] ?: return null
        if (!Instant.now().isBefore(entry.authorizationExpiry.get())) {
            entries.remove(id, entry)
            return null
        }
        return entry.let {
            StreamRequest(
                baseURL = it.baseURL,
                streamURL = it.streamURL,
                accessToken = it.accessToken,
                profileID = it.profileID,
                cohortKey = it.cohortKey,
                authorizationExpiry = it.authorizationExpiry,
                allowCleartextDevelopment = it.allowCleartextDevelopment,
            )
        }
    }
}

internal object StreamLeaseExpiryPolicy {
    fun authoritativeReplacement(current: Instant, signed: Instant, now: Instant): Instant? {
        if (!now.isBefore(current) || !now.isBefore(signed)) return null
        // A freshly verified signed policy is authoritative in both directions:
        // it may extend the lease, retain it, or shorten it.
        return signed
    }
}

internal enum class StreamLeaseUpdateKind { Shorten, Retain, Extend }

internal data class StreamLeaseUpdateDecision(
    val kind: StreamLeaseUpdateKind,
    val clearPendingRenewalFloor: Boolean,
)

internal object StreamLeaseUpdatePolicy {
    fun decide(
        current: Instant,
        signed: Instant,
        proactiveRenewal: Boolean,
    ): StreamLeaseUpdateDecision {
        val kind = when {
            signed.isBefore(current) -> StreamLeaseUpdateKind.Shorten
            signed.isAfter(current) -> StreamLeaseUpdateKind.Extend
            else -> StreamLeaseUpdateKind.Retain
        }
        return StreamLeaseUpdateDecision(
            kind = kind,
            // A proactive equal envelope keeps the existing hard deadline and
            // retries closer to it. Earlier/later signed policy is authoritative.
            clearPendingRenewalFloor = !proactiveRenewal || kind != StreamLeaseUpdateKind.Retain,
        )
    }
}

internal data class StreamRequest(
    val baseURL: String,
    val streamURL: URL,
    val accessToken: String,
    val profileID: String,
    val cohortKey: String,
    val authorizationExpiry: AtomicReference<Instant>,
    val allowCleartextDevelopment: Boolean,
)

@UnstableApi
internal class AuthenticatedStreamDataSource : BaseDataSource(true) {
    private var connection: HttpURLConnection? = null
    private var input: InputStream? = null
    private var opened = false
    private var remaining = C.LENGTH_UNSET.toLong()
    private var resolvedURI: Uri? = null
    private var responseHeaders: Map<String, List<String>> = emptyMap()
    private var authorizationExpiry: AtomicReference<Instant>? = null

    override fun open(dataSpec: DataSpec): Long {
        transferInitializing(dataSpec)
        val request = AuthenticatedStreamRegistry.entry(dataSpec.uri)
            ?: throw IOException("The authenticated stream session is unavailable")
        authorizationExpiry = request.authorizationExpiry
        val result = openConnection(request, dataSpec)
        if (!Instant.now().isBefore(request.authorizationExpiry.get())) {
            result.connection.disconnect()
            throw IOException("The authenticated stream policy has expired")
        }
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
        if (!Instant.now().isBefore(authorizationExpiry?.get() ?: Instant.EPOCH)) {
            throw IOException("The authenticated stream policy has expired")
        }
        if (length == 0) return 0
        if (remaining == 0L) return C.RESULT_END_OF_INPUT
        val allowed = if (remaining == C.LENGTH_UNSET.toLong()) length else minOf(length.toLong(), remaining).toInt()
        val read = input?.read(buffer, offset, allowed) ?: C.RESULT_END_OF_INPUT
        if (!Instant.now().isBefore(authorizationExpiry?.get() ?: Instant.EPOCH)) {
            throw IOException("The authenticated stream policy has expired")
        }
        if (read < 0) {
            if (remaining != C.LENGTH_UNSET.toLong() && remaining > 0L) {
                throw EOFException("The authenticated stream ended early")
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
            authorizationExpiry = null
            remaining = C.LENGTH_UNSET.toLong()
            if (opened) {
                opened = false
                transferEnded()
            }
        }
    }

    private fun openConnection(request: StreamRequest, dataSpec: DataSpec): OpenedConnection {
        var currentURL = request.streamURL
        repeat(MAX_REDIRECTS + 1) { redirectCount ->
            if (!Instant.now().isBefore(request.authorizationExpiry.get())) {
                throw IOException("The authenticated stream policy has expired")
            }
            val candidate = ServerNetworkPolicy.requireAuthorizedURL(
                request.baseURL,
                currentURL,
                request.allowCleartextDevelopment,
            )
            val candidateConnection = (candidate.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                useCaches = false
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = READ_TIMEOUT_MS
                setRequestProperty("Authorization", "Bearer ${request.accessToken}")
                setRequestProperty("X-Resonance-Profile", request.profileID)
                ClientContextHeaderPolicy.headers(
                    cohortKey = request.cohortKey,
                    appVersion = BuildConfig.VERSION_NAME,
                    appBuild = BuildConfig.VERSION_CODE.toLong(),
                ).forEach(::setRequestProperty)
                setRequestProperty("Accept-Encoding", "identity")
                val rangeEnd = dataSpec.length
                    .takeIf { it != C.LENGTH_UNSET.toLong() }
                    ?.let { length -> dataSpec.position + length - 1L }
                if (dataSpec.position > 0L || rangeEnd != null) {
                    setRequestProperty(
                        "Range",
                        "bytes=${dataSpec.position}-${rangeEnd?.toString().orEmpty()}",
                    )
                }
            }
            val status = candidateConnection.responseCode
            if (!Instant.now().isBefore(request.authorizationExpiry.get())) {
                candidateConnection.errorStream?.close()
                candidateConnection.disconnect()
                throw IOException("The authenticated stream policy has expired")
            }
            if (status == HttpURLConnection.HTTP_OK || status == HttpURLConnection.HTTP_PARTIAL) {
                val partialRange = if (status == HttpURLConnection.HTTP_PARTIAL) {
                    try {
                        StreamRangePolicy.validatePartialResponse(
                            contentRange = candidateConnection.getHeaderField("Content-Range"),
                            requestedStart = dataSpec.position,
                            requestedLength = dataSpec.length.takeIf { it != C.LENGTH_UNSET.toLong() },
                            responseLength = candidateConnection.contentLengthLong.takeIf { it >= 0L },
                        )
                    } catch (error: Throwable) {
                        candidateConnection.errorStream?.close()
                        candidateConnection.disconnect()
                        throw error
                    }
                } else null
                return OpenedConnection(candidateConnection, partialRange)
            }
            if (status !in REDIRECT_STATUSES) {
                candidateConnection.errorStream?.close()
                candidateConnection.disconnect()
                throw IOException("The server stream returned HTTP $status")
            }
            if (redirectCount == MAX_REDIRECTS) {
                candidateConnection.disconnect()
                throw IOException("The server stream redirected too many times")
            }
            val location = candidateConnection.getHeaderField("Location")
            if (location.isNullOrBlank()) {
                candidateConnection.disconnect()
                throw IOException("The server stream redirect is missing a location")
            }
            currentURL = try {
                ServerNetworkPolicy.resolveAuthorizedRedirect(
                    request.baseURL,
                    candidate,
                    location,
                    request.allowCleartextDevelopment,
                )
            } finally {
                candidateConnection.disconnect()
            }
        }
        throw IOException("The server stream redirected too many times")
    }

    private fun skipFully(stream: InputStream, bytes: Long) {
        var remaining = bytes
        val buffer = ByteArray(16 * 1_024)
        while (remaining > 0L) {
            val skipped = stream.skip(remaining)
            if (skipped > 0L) {
                remaining -= skipped
                continue
            }
            val read = stream.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
            if (read < 0) throw EOFException("The server stream ended before the requested range")
            remaining -= read
        }
    }

    class Factory : DataSource.Factory {
        override fun createDataSource(): DataSource = AuthenticatedStreamDataSource()
    }

    private data class OpenedConnection(
        val connection: HttpURLConnection,
        val partialRange: mov.unblocked.resonance.playback.ValidatedContentRange?,
    )

    private companion object {
        const val CONNECT_TIMEOUT_MS = 20_000
        const val READ_TIMEOUT_MS = 120_000
        const val MAX_REDIRECTS = 5
        val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
    }
}
