package mov.unblocked.resonance.data

import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.roundToInt
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.longOrNull

internal object SoundCloudImportUrls {
    private val sourceHosts = setOf("soundcloud.com", "www.soundcloud.com", "m.soundcloud.com", "on.soundcloud.com")

    fun source(value: String): URL? = runCatching {
        if (value.length > 8_192) return null
        val uri = URI(value.trim())
        val host = uri.host?.lowercase() ?: return null
        if (uri.scheme?.lowercase() != "https" || uri.userInfo != null || host !in sourceHosts) return null
        if (uri.path.split('/').none(String::isNotBlank)) return null
        uri.toURL()
    }.getOrNull()

    fun isPage(url: URL): Boolean = safeHTTPS(url) && url.host.lowercase() in sourceHosts
    fun isAPI(url: URL): Boolean = safeHTTPS(url) && url.host.equals("api-v2.soundcloud.com", true)
    fun isMedia(url: URL): Boolean {
        if (!safeHTTPS(url)) return false
        val host = url.host.lowercase()
        return host == "sndcdn.com" || host.endsWith(".sndcdn.com")
    }
    fun isArtwork(value: String): Boolean = runCatching { isMedia(URL(value)) }.getOrDefault(false)

    fun normalizePermalink(value: String?): String? {
        val source = value?.let(::source) ?: return null
        val host = when (source.host.lowercase()) {
            "www.soundcloud.com", "m.soundcloud.com" -> "soundcloud.com"
            else -> source.host.lowercase()
        }
        val path = source.path.trimEnd('/').ifEmpty { "/" }
        return URI("https", null, host, -1, path, null, null).toString()
    }

    private fun safeHTTPS(url: URL): Boolean =
        url.protocol.equals("https", true) && url.userInfo == null && url.host.isNotBlank()
}

internal data class SoundCloudTrack(
    val id: String,
    val metadata: LinkImportTrack,
    val directlyImportable: Boolean,
) {
    fun directCandidate(position: Int? = null): LinkImportCandidate? {
        if (!directlyImportable) return null
        val track = if (position == null) metadata else metadata.copy(trackNumber = position)
        return LinkImportCandidate(
            videoID = "soundcloud:$id",
            title = track.title,
            artist = track.artist,
            durationSeconds = track.durationSeconds,
            thumbnailURL = track.artworkURL,
            sourceURL = track.sourceURL,
            score = 1.0,
            importTrack = position?.let { track },
            playlistIndex = position,
            sourceProvider = LinkImportSourceProvider.SoundCloud,
        )
    }
}

internal data class SoundCloudPlaylist(
    val id: String,
    val title: String,
    val author: String,
    val artworkURL: String?,
    val sourceURL: String,
    val tracks: List<SoundCloudTrack>,
    val unavailableCount: Int,
)

internal sealed interface SoundCloudSource {
    data class Track(val value: SoundCloudTrack) : SoundCloudSource
    data class Playlist(val value: SoundCloudPlaylist) : SoundCloudSource
}

internal data class SoundCloudAudio(
    val track: LinkImportTrack,
    val url: URL,
    val contentLength: Long,
)

internal object SoundCloudImportParser {
    private const val MAX_PAGE_CHARACTERS = 8 * 1_024 * 1_024

    fun hydration(html: String, json: Json = Json { ignoreUnknownKeys = true }): Map<String, JsonElement> {
        if (html.length > MAX_PAGE_CHARACTERS) invalidResponse()
        val marker = html.indexOf("window.__sc_hydration")
        val start = if (marker >= 0) html.indexOf('[', marker) else -1
        val payload = if (start >= 0) balancedArray(html, start) else null
        val values = payload?.let { runCatching { json.parseToJsonElement(it) as? JsonArray }.getOrNull() }
            ?: invalidResponse()
        return buildMap {
            values.forEach { element ->
                val value = element as? JsonObject ?: return@forEach
                val key = value.string("hydratable") ?: return@forEach
                value["data"]?.let { put(key, it) }
            }
        }
    }

    fun clientID(hydration: Map<String, JsonElement>): String? =
        (hydration["apiClient"] as? JsonObject)?.string("id")
            ?.takeIf { it.matches(Regex("^[A-Za-z0-9_-]{20,80}$")) }

    fun track(value: JsonElement?, position: Int? = null): SoundCloudTrack? {
        val record = value as? JsonObject ?: return null
        if (record.string("kind") != "track") return null
        val id = record.nonnegativeLong("id") ?: return null
        val title = clean(record.string("title")) ?: return null
        val user = record.obj("user") ?: return null
        val sourceURL = SoundCloudImportUrls.normalizePermalink(record.string("permalink_url")) ?: return null
        val publisher = record.obj("publisher_metadata")
        val artist = clean(publisher?.string("artist")) ?: clean(user.string("username")) ?: return null
        val durationMs = record.nonnegativeLong("full_duration") ?: record.nonnegativeLong("duration")
        val album = clean(publisher?.string("album_title"))
            ?: clean(publisher?.string("release_title"))
            ?: clean(record.string("label_name"))
        val artwork = record.string("artwork_url")?.takeIf(SoundCloudImportUrls::isArtwork)
            ?: user.string("avatar_url")?.takeIf(SoundCloudImportUrls::isArtwork)
        val metadata = LinkImportTrack(
            title = title,
            artist = artist,
            album = album,
            durationSeconds = durationMs?.let { (it / 1_000.0).roundToInt() },
            artworkURL = artwork,
            sourceURL = sourceURL,
            trackNumber = position,
        )
        val streamable = record["streamable"]?.primitiveBoolean() != false
        val blocked = record.string("policy") == "BLOCK"
        val authorized = clean(record.string("track_authorization"), 2_048) != null
        return SoundCloudTrack(
            id = id.toString(),
            metadata = metadata,
            directlyImportable = streamable && !blocked && authorized && progressiveTranscoding(record) != null,
        )
    }

    fun progressiveTranscoding(record: JsonObject): JsonObject? =
        record.obj("media")?.array("transcodings").orEmpty()
            .mapNotNull { it as? JsonObject }
            .firstOrNull { value ->
                value["snipped"]?.primitiveBoolean() != true &&
                    value.obj("format")?.string("protocol") == "progressive" &&
                    value.obj("format")?.string("mime_type")?.startsWith("audio/mpeg", true) == true &&
                    value.string("url")?.let { runCatching { SoundCloudImportUrls.isAPI(URL(it)) }.getOrDefault(false) } == true
            }

    private fun balancedArray(source: String, start: Int): String? {
        var depth = 0
        var quoted = false
        var escaped = false
        for (index in start until source.length) {
            val character = source[index]
            if (quoted) {
                when {
                    escaped -> escaped = false
                    character == '\\' -> escaped = true
                    character == '"' -> quoted = false
                }
            } else when (character) {
                '"' -> quoted = true
                '[' -> depth += 1
                ']' -> {
                    depth -= 1
                    if (depth == 0) return source.substring(start, index + 1)
                }
            }
        }
        return null
    }

    private fun invalidResponse(): Nothing = throw LinkImportException(
        LinkImportStage.ResolvingMetadata,
        "SOUNDCLOUD_INVALID_RESPONSE",
        "SoundCloud returned invalid page metadata.",
    )
}

internal object SoundCloudImport {
    private const val MAX_PAGE_BYTES = 8 * 1_024 * 1_024
    private const val MAX_API_BYTES = 8 * 1_024 * 1_024
    private const val MAX_AUDIO_BYTES = 256L * 1_024 * 1_024
    private const val MAX_PLAYLIST_ITEMS = 500
    private const val MAX_REDIRECTS = 5
    // SoundCloud's mobile document omits the public hydration payload used to
    // resolve tracks and playlists. Request the normal desktop document while
    // keeping every redirect and media host independently allowlisted.
    private const val WEB_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private val json = Json { ignoreUnknownKeys = true }

    private data class Page(val hydration: Map<String, JsonElement>)
    private data class Response(
        val status: Int,
        val finalURL: URL,
        val contentType: String?,
        val contentLength: Long,
        val retryAfter: String?,
        val body: ByteArray,
    )

    suspend fun resolve(source: String): SoundCloudSource {
        val page = loadPage(source)
        val sound = page.hydration["sound"]
        SoundCloudImportParser.track(sound)?.let { track ->
            return SoundCloudSource.Track(importabilityChecked(track, page.hydration))
        }
        val record = page.hydration["playlist"] as? JsonObject
        if (record?.string("kind") != "playlist") unsupportedResource()
        val id = record.nonnegativeLong("id") ?: unsupportedResource()
        val title = clean(record.string("title")) ?: unsupportedResource()
        val sourceURL = SoundCloudImportUrls.normalizePermalink(record.string("permalink_url")) ?: unsupportedResource()
        val rawTracks = record.array("tracks").mapNotNull { it as? JsonObject }
        val limitedTracks = rawTracks.take(MAX_PLAYLIST_ITEMS)
        val records = limitedTracks.mapNotNull { item -> item.nonnegativeLong("id")?.let { it to item } }.toMap().toMutableMap()
        val missingIDs = limitedTracks.mapNotNull { item ->
            if (SoundCloudImportParser.track(item) == null) item.nonnegativeLong("id") else null
        }
        SoundCloudImportParser.clientID(page.hydration)?.let { clientID ->
            missingIDs.chunked(50).forEach { ids ->
                currentCoroutineContext().ensureActive()
                fetchTracks(ids, clientID).forEach { item -> item.nonnegativeLong("id")?.let { records[it] = item } }
            }
        }
        val tracks = limitedTracks.mapIndexedNotNull { index, item ->
            val trackID = item.nonnegativeLong("id") ?: return@mapIndexedNotNull null
            SoundCloudImportParser.track(records[trackID], index + 1)
                ?.let { importabilityChecked(it, page.hydration) }
        }
        if (tracks.isEmpty()) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SOUNDCLOUD_PLAYLIST_EMPTY",
            "This SoundCloud playlist has no public tracks that can be imported.",
        )
        val user = record.obj("user")
        val artwork = record.string("artwork_url")?.takeIf(SoundCloudImportUrls::isArtwork)
            ?: user?.string("avatar_url")?.takeIf(SoundCloudImportUrls::isArtwork)
        val trackCount = record.nonnegativeLong("track_count")?.toInt() ?: rawTracks.size
        return SoundCloudSource.Playlist(SoundCloudPlaylist(
            id = id.toString(),
            title = title,
            author = clean(user?.string("username")) ?: "SoundCloud",
            artworkURL = artwork,
            sourceURL = sourceURL,
            tracks = tracks,
            unavailableCount = max(trackCount - tracks.size, 0),
        ))
    }

    suspend fun resolveAudio(source: String): SoundCloudAudio {
        val page = loadPage(source)
        val record = page.hydration["sound"] as? JsonObject
        val track = SoundCloudImportParser.track(record)
        val clientID = SoundCloudImportParser.clientID(page.hydration)
        val transcoding = record?.let(SoundCloudImportParser::progressiveTranscoding)
        val authorization = clean(record?.string("track_authorization"), 2_048)
        val rawEndpoint = transcoding?.string("url")
        if (track == null || clientID == null || authorization == null || rawEndpoint == null) streamUnavailable()
        val endpoint = URL(rawEndpoint + (if (rawEndpoint.contains('?')) "&" else "?") +
            "client_id=" + URLEncoder.encode(clientID, "UTF-8") +
            "&track_authorization=" + URLEncoder.encode(authorization, "UTF-8"))
        if (!SoundCloudImportUrls.isAPI(endpoint)) unsafeStream()
        val payload = responseBytes(
            endpoint, "GET", 64 * 1_024, "application/json", SoundCloudImportUrls::isAPI,
            LinkImportStage.InspectingSource,
        )
        if (payload.status !in 200..299) providerFailure(payload, "audio stream", LinkImportStage.InspectingSource)
        val mediaValue = runCatching { (json.parseToJsonElement(payload.body.decodeToString()) as? JsonObject)?.string("url") }.getOrNull()
        val mediaURL = mediaValue?.let { runCatching { URL(it) }.getOrNull() }
        if (mediaURL == null || !SoundCloudImportUrls.isMedia(mediaURL)) unsafeStream()
        val head = responseBytes(
            mediaURL, "HEAD", 1_024, "audio/mpeg,*/*;q=0.5", SoundCloudImportUrls::isMedia,
            LinkImportStage.InspectingSource,
        )
        if (head.status !in 200..299 || !SoundCloudImportUrls.isMedia(head.finalURL)) {
            providerFailure(head, "audio stream", LinkImportStage.InspectingSource)
        }
        if (head.contentLength !in 1..MAX_AUDIO_BYTES) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "SOUNDCLOUD_AUDIO_TOO_LARGE",
            "The selected SoundCloud audio is too large to import on this device.",
        )
        val type = head.contentType?.substringBefore(';')?.trim()?.lowercase()
        if (type != null && type !in setOf("audio/mpeg", "application/octet-stream")) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "SOUNDCLOUD_INVALID_STREAM",
            "SoundCloud returned an invalid audio stream.",
        )
        return SoundCloudAudio(track.metadata, head.finalURL, head.contentLength)
    }

    suspend fun download(
        stream: SoundCloudAudio,
        destination: File,
        progress: (LinkImportProgress) -> Unit,
    ): String {
        val connection = openMediaFollowingRedirects(stream.url, "GET", mapOf(
            "Accept" to "audio/mpeg,*/*;q=0.5",
            "Accept-Encoding" to "identity",
            "User-Agent" to WEB_AGENT,
        ))
        try {
            val status = connection.responseCode
            if (status !in 200..299 || !SoundCloudImportUrls.isMedia(connection.url) || connection.contentLengthLong != stream.contentLength) {
                throw LinkImportException(LinkImportStage.Downloading, "SOUNDCLOUD_SIZE_MISMATCH", "SoundCloud returned an unverifiable audio stream.")
            }
            val type = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
            if (type != null && type !in setOf("audio/mpeg", "application/octet-stream")) throw LinkImportException(
                LinkImportStage.Downloading, "SOUNDCLOUD_INVALID_STREAM", "SoundCloud returned an invalid audio stream.",
            )
            val digest = MessageDigest.getInstance("SHA-256")
            var completed = 0L
            FileOutputStream(destination).use { output ->
                connection.inputStream.use { input ->
                    val buffer = ByteArray(64 * 1_024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        completed += count
                        if (completed > stream.contentLength || completed > MAX_AUDIO_BYTES) throw LinkImportException(
                            LinkImportStage.Downloading, "SOUNDCLOUD_SIZE_MISMATCH", "SoundCloud returned more audio than expected.",
                        )
                        output.write(buffer, 0, count)
                        digest.update(buffer, 0, count)
                        progress(LinkImportProgress(LinkImportStage.Downloading, completed, stream.contentLength))
                    }
                }
            }
            if (completed != stream.contentLength) throw LinkImportException(
                LinkImportStage.Downloading, "SOUNDCLOUD_SIZE_MISMATCH", "SoundCloud ended the audio download before it was complete.",
            )
            return digest.digest().joinToString("") { "%02x".format(it) }
        } catch (error: Throwable) {
            destination.delete()
            throw error
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun loadPage(source: String): Page {
        val sourceURL = SoundCloudImportUrls.source(source) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata, "INVALID_SOUNDCLOUD_URL", "Source must be a SoundCloud track or playlist URL.",
        )
        val response = responseBytes(
            sourceURL, "GET", MAX_PAGE_BYTES, "text/html", SoundCloudImportUrls::isPage,
            LinkImportStage.ResolvingMetadata,
        )
        if (response.status !in 200..299) providerFailure(response, "source", LinkImportStage.ResolvingMetadata)
        return Page(SoundCloudImportParser.hydration(response.body.decodeToString(), json))
    }

    private suspend fun fetchTracks(ids: List<Long>, clientID: String): List<JsonObject> {
        if (ids.isEmpty()) return emptyList()
        val url = URL("https://api-v2.soundcloud.com/tracks?ids=" + ids.joinToString(",") +
            "&client_id=" + URLEncoder.encode(clientID, "UTF-8"))
        return try {
            val response = responseBytes(
                url, "GET", MAX_API_BYTES, "application/json", SoundCloudImportUrls::isAPI,
                LinkImportStage.ResolvingMetadata,
            )
            if (response.status !in 200..299) return emptyList()
            (json.parseToJsonElement(response.body.decodeToString()) as? JsonArray)
                ?.mapNotNull { it as? JsonObject }.orEmpty()
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (_: Exception) {
            emptyList()
        }
    }

    private suspend fun responseBytes(
        initialURL: URL,
        initialMethod: String,
        limit: Int,
        accept: String,
        validator: (URL) -> Boolean,
        stage: LinkImportStage,
    ): Response {
        var url = initialURL
        var method = initialMethod
        var redirects = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!validator(url)) unsafeRedirect(stage)
            val connection = open(url, method, mapOf(
                "Accept" to accept,
                "Accept-Encoding" to "identity",
                "Accept-Language" to "en-US,en;q=0.8",
                "User-Agent" to WEB_AGENT,
            ))
            try {
                val status = connection.responseCode
                if (status in setOf(301, 302, 303, 307, 308)) {
                    val location = connection.getHeaderField("Location") ?: unsafeRedirect(stage)
                    val next = runCatching { url.toURI().resolve(location).toURL() }.getOrNull() ?: unsafeRedirect(stage)
                    if (++redirects > MAX_REDIRECTS || !validator(next)) unsafeRedirect(stage)
                    url = next
                    if (status == 303) method = "GET"
                    continue
                }
                val declared = connection.contentLengthLong
                if (method != "HEAD" && declared > limit) throw LinkImportException(
                    stage, "SOUNDCLOUD_RESPONSE_TOO_LARGE", "SoundCloud returned an oversized response.",
                )
                val bytes = if (method == "HEAD") ByteArray(0) else {
                    val input = if (status in 200..299) connection.inputStream else connection.errorStream
                    input?.use {
                        val output = java.io.ByteArrayOutputStream()
                        val buffer = ByteArray(32 * 1_024)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = it.read(buffer)
                            if (count < 0) break
                            if (output.size() + count > limit) throw LinkImportException(
                                stage, "SOUNDCLOUD_RESPONSE_TOO_LARGE", "SoundCloud returned an oversized response.",
                            )
                            output.write(buffer, 0, count)
                        }
                        output.toByteArray()
                    } ?: ByteArray(0)
                }
                return Response(
                    status = status,
                    finalURL = connection.url,
                    contentType = connection.contentType,
                    contentLength = connection.contentLengthLong,
                    retryAfter = connection.getHeaderField("Retry-After"),
                    body = bytes,
                )
            } finally {
                connection.disconnect()
            }
        }
    }

    private fun open(url: URL, method: String, headers: Map<String, String>): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            connectTimeout = 45_000
            readTimeout = 180_000
            headers.forEach(::setRequestProperty)
        }

    private fun openMediaFollowingRedirects(
        initialURL: URL,
        method: String,
        headers: Map<String, String>,
    ): HttpURLConnection {
        var url = initialURL
        repeat(MAX_REDIRECTS + 1) { redirectCount ->
            if (!SoundCloudImportUrls.isMedia(url)) unsafeStream()
            val connection = open(url, method, headers)
            val status = connection.responseCode
            if (status !in setOf(301, 302, 303, 307, 308)) return connection
            val location = connection.getHeaderField("Location")
            val next = location?.let { runCatching { url.toURI().resolve(it).toURL() }.getOrNull() }
            connection.disconnect()
            if (redirectCount == MAX_REDIRECTS || next == null || !SoundCloudImportUrls.isMedia(next)) unsafeStream()
            url = next
        }
        unsafeStream()
    }

    private fun importabilityChecked(track: SoundCloudTrack, hydration: Map<String, JsonElement>): SoundCloudTrack =
        if (SoundCloudImportParser.clientID(hydration) == null) track.copy(directlyImportable = false) else track

    private fun providerFailure(response: Response, resource: String, stage: LinkImportStage): Nothing {
        when (response.status) {
            404 -> throw LinkImportException(stage, "SOUNDCLOUD_NOT_FOUND", "SoundCloud could not find that $resource.")
            429 -> throw LinkImportException(stage, "SOUNDCLOUD_RATE_LIMITED", "SoundCloud rate-limited this request. Try again shortly.")
            else -> throw LinkImportException(stage, "SOUNDCLOUD_PROVIDER_FAILED", "SoundCloud could not load that $resource.")
        }
    }

    private fun unsupportedResource(): Nothing = throw LinkImportException(
        LinkImportStage.ResolvingMetadata,
        "UNSUPPORTED_SOUNDCLOUD_RESOURCE",
        "Only individual SoundCloud tracks and public SoundCloud playlists are supported.",
    )
    private fun streamUnavailable(): Nothing = throw LinkImportException(
        LinkImportStage.InspectingSource,
        "SOUNDCLOUD_STREAM_UNAVAILABLE",
        "This SoundCloud track does not provide a direct public audio rendition. Try another offered source.",
    )
    private fun unsafeStream(): Nothing = throw LinkImportException(
        LinkImportStage.InspectingSource, "SOUNDCLOUD_UNSAFE_STREAM", "SoundCloud returned an unsafe audio stream.",
    )
    private fun unsafeRedirect(stage: LinkImportStage): Nothing = throw LinkImportException(
        stage, "SOUNDCLOUD_UNSAFE_REDIRECT", "SoundCloud returned an unsafe redirect.",
    )
}

private fun clean(value: String?, maximum: Int = 500): String? = value
    ?.replace(Regex("[\\p{Cc}\\p{Cf}]+"), " ")
    ?.trim()
    ?.replace(Regex("\\s+"), " ")
    ?.takeIf(String::isNotEmpty)
    ?.take(maximum)

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
private fun JsonObject.array(key: String): List<JsonElement> = (this[key] as? JsonArray)?.toList().orEmpty()
private fun JsonObject.nonnegativeLong(key: String): Long? =
    (this[key] as? JsonPrimitive)?.longOrNull?.takeIf { it >= 0 }
private fun JsonElement.primitiveBoolean(): Boolean? = (this as? JsonPrimitive)?.booleanOrNull
