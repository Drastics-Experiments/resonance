package mov.unblocked.resonance.data

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

enum class LinkImportStage {
    Idle, ResolvingMetadata, SearchingCandidates, AwaitingSelection, InspectingSource,
    Downloading, SavingLocal, Complete, Failed, Cancelled,
}

data class LinkImportTrack(
    val title: String,
    val artist: String,
    val album: String? = null,
    val durationSeconds: Int? = null,
    val artworkURL: String? = null,
    val sourceURL: String,
)

data class LinkImportCandidate(
    val videoID: String,
    val title: String,
    val artist: String?,
    val durationSeconds: Int?,
    val thumbnailURL: String?,
    val sourceURL: String,
    val score: Double,
)

data class LinkImportResolution(val track: LinkImportTrack, val candidates: List<LinkImportCandidate>)
data class LinkImportProgress(val stage: LinkImportStage, val completedBytes: Long = 0, val totalBytes: Long = 0)
data class LinkImportDownload(
    val file: File,
    val metadata: LinkImportTrack,
    val artwork: ByteArray?,
    val durationMs: Long,
    val sourceSHA256: String,
    val contentSHA256: String,
)

class LinkImportException(
    val stage: LinkImportStage,
    val code: String,
    override val message: String,
) : Exception(message)

class LinkImportService(context: Context) {
    private data class ResolvedAudio(
        val candidate: LinkImportCandidate,
        val streamURL: URL,
        val contentLength: Long,
    )

    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }
    private val spotifyHosts = setOf("open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link")
    private val youtubeHosts = setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com")
    private val maxAudioBytes = 256L * 1_024 * 1_024
    private val webAgent = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/140 Mobile Safari/537.36"
    private val playerAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L) gzip"

    suspend fun resolve(source: String, progress: (LinkImportProgress) -> Unit): LinkImportResolution =
        withContext(Dispatchers.IO) {
            val spotify = spotifyURL(source.trim())
            if (spotify != null) {
                progress(LinkImportProgress(LinkImportStage.ResolvingMetadata))
                val track = resolveSpotify(spotify)
                progress(LinkImportProgress(LinkImportStage.SearchingCandidates))
                val matches = searchYouTube(track)
                if (matches.isEmpty()) throw LinkImportException(
                    LinkImportStage.SearchingCandidates,
                    "NO_AUDIO_MATCH",
                    "No sufficiently close YouTube audio match was found. Try a YouTube URL instead.",
                )
                return@withContext LinkImportResolution(track, matches)
            }
            val id = youtubeID(source) ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "UNSUPPORTED_SOURCE",
                "Enter a Spotify track or supported YouTube video URL.",
            )
            progress(LinkImportProgress(LinkImportStage.InspectingSource))
            val resolved = resolveYouTube(id)
            val track = LinkImportTrack(
                resolved.candidate.title,
                resolved.candidate.artist ?: "Unknown uploader",
                durationSeconds = resolved.candidate.durationSeconds,
                artworkURL = resolved.candidate.thumbnailURL,
                sourceURL = resolved.candidate.sourceURL,
            )
            LinkImportResolution(track, listOf(resolved.candidate))
        }

    suspend fun download(
        candidate: LinkImportCandidate,
        metadata: LinkImportTrack,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportDownload = withContext(Dispatchers.IO) {
        val resolved = resolveYouTube(candidate.videoID)
        val directory = File(appContext.cacheDir, "resonance-link-import-" + System.nanoTime()).apply { mkdirs() }
        val output = File(directory, "source.m4a")
        try {
            val hash = downloadRanges(resolved, output, progress)
            val artwork = fetchArtwork(metadata.artworkURL ?: resolved.candidate.thumbnailURL)
            LinkImportDownload(
                output,
                metadata.copy(
                    title = metadata.title.ifBlank { resolved.candidate.title },
                    artist = metadata.artist.ifBlank { resolved.candidate.artist ?: "Unknown uploader" },
                ),
                artwork,
                ((metadata.durationSeconds ?: resolved.candidate.durationSeconds) ?: 0).coerceAtLeast(0) * 1_000L,
                hash,
                hash,
            )
        } catch (error: Throwable) {
            directory.deleteRecursively()
            throw error
        }
    }

    private suspend fun resolveSpotify(source: URL): LinkImportTrack {
        val parts = source.path.split('/').filter(String::isNotBlank)
        val trackIndex = parts.indexOf("track")
        val id = trackIndex.takeIf { it >= 0 }?.let { parts.getOrNull(it + 1) }
            ?.takeIf { it.matches(Regex("[A-Za-z0-9]{22}")) }
            ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "UNSUPPORTED_SPOTIFY_RESOURCE",
                "Only individual Spotify track links are supported.",
            )
        val canonical = "https://open.spotify.com/track/" + id
        val embed = json.parseToJsonElement(
            request(
                URL("https://open.spotify.com/oembed?url=" + URLEncoder.encode(canonical, "UTF-8")),
                256 * 1_024,
                "application/json",
            ),
        ) as JsonObject
        if (embed.string("provider_name") != "Spotify" || embed.string("type") != "rich") throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INVALID_PREVIEW",
            "Spotify returned an invalid track preview.",
        )
        val html = request(URL("https://open.spotify.com/embed/track/" + id), 6 * 1_024 * 1_024, "text/html")
        val script = Regex(
            """<script[^>]*\bid=[\"']__NEXT_DATA__[\"'][^>]*>([\s\S]*?)</script>""",
            RegexOption.IGNORE_CASE,
        ).find(html)?.groupValues?.getOrNull(1)
        val root = script?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        val entity = root?.obj("props")?.obj("pageProps")?.obj("state")?.obj("data")?.obj("entity")
            ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "SPOTIFY_MISMATCH",
                "Spotify returned mismatched track metadata.",
            )
        if (entity.string("type") != "track" || entity.string("id") != id) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_MISMATCH",
            "Spotify returned mismatched track metadata.",
        )
        val title = entity.string("title")?.trim()?.takeIf(String::isNotEmpty) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INCOMPLETE_METADATA",
            "Spotify returned incomplete track metadata.",
        )
        val artist = entity.array("artists").mapNotNull { item ->
            (item as? JsonObject)?.string("name")?.trim()?.takeIf(String::isNotEmpty)
        }.joinToString(", ").takeIf(String::isNotEmpty) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INCOMPLETE_METADATA",
            "Spotify returned incomplete track metadata.",
        )
        val artwork = entity.obj("visualIdentity")?.array("image").orEmpty()
            .mapNotNull { it as? JsonObject }
            .sortedByDescending { it.long("maxWidth") }
            .mapNotNull { it.string("url")?.takeIf(::isArtwork) }
            .firstOrNull()
        val durationMs = entity.long("duration")
        return LinkImportTrack(
            title,
            artist,
            durationSeconds = durationMs.takeIf { it > 0 }?.let { (it / 1_000.0).toInt() },
            artworkURL = artwork ?: embed.string("thumbnail_url")?.takeIf(::isArtwork),
            sourceURL = canonical,
        )
    }

    private suspend fun searchYouTube(track: LinkImportTrack): List<LinkImportCandidate> {
        val query = URLEncoder.encode(track.artist + " " + track.title + " official audio", "UTF-8")
        val html = request(URL("https://www.youtube.com/results?search_query=" + query), 6 * 1_024 * 1_024, "text/html")
        val ids = Regex("""\"videoId\"\s*:\s*\"([A-Za-z0-9_-]{11})\"""")
            .findAll(html).map { it.groupValues[1] }.distinct().take(10).toList()
        val candidates = buildList {
            for (id in ids) {
                currentCoroutineContext().ensureActive()
                runCatching { resolveYouTube(id).candidate }.getOrNull()?.let(::add)
            }
        }
        return candidates.map { candidate ->
            val titleScore = overlap(normalize(track.title), normalize(candidate.title))
            val artistScore = maxOf(
                overlap(normalize(track.artist), normalize(candidate.title)),
                overlap(normalize(track.artist), normalize(candidate.artist.orEmpty())),
            )
            val durationScore = if (track.durationSeconds == null || candidate.durationSeconds == null) .5 else {
                (1.0 - kotlin.math.abs(track.durationSeconds - candidate.durationSeconds) / 30.0).coerceIn(0.0, 1.0)
            }
            candidate.copy(score = titleScore * .62 + artistScore * .28 + durationScore * .1)
        }.filter { it.score >= .42 }.sortedByDescending(LinkImportCandidate::score).take(8).toList()
    }

    private suspend fun resolveYouTube(videoID: String): ResolvedAudio {
        val watch = request(
            URL("https://www.youtube.com/watch?v=" + videoID + "&bpctr=9999999999&has_verified=1"),
            6 * 1_024 * 1_024,
            "text/html",
        )
        val visitor = capture(watch, Regex("""\"(?:VISITOR_DATA|visitorData)\"\s*:\s*\"((?:\\.|[^\"\\]){1,1000})\""""))
        val body = buildJsonObject {
            put("videoId", videoID)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            put("context", buildJsonObject {
                put("client", buildJsonObject {
                    put("clientName", "ANDROID_VR")
                    put("clientVersion", "1.65.10")
                    put("deviceMake", "Oculus")
                    put("deviceModel", "Quest 3")
                    put("androidSdkVersion", 32)
                    put("osName", "Android")
                    put("osVersion", "12L")
                    put("hl", "en")
                    put("timeZone", "UTC")
                    put("utcOffsetMinutes", 0)
                    put("userAgent", playerAgent)
                })
            })
        }.toString().toByteArray()
        val headers = mutableMapOf(
            "Content-Type" to "application/json",
            "X-YouTube-Client-Name" to "28",
            "X-YouTube-Client-Version" to "1.65.10",
            "Origin" to "https://www.youtube.com",
            "User-Agent" to playerAgent,
        )
        if (!visitor.isNullOrBlank()) headers["X-Goog-Visitor-Id"] = visitor
        val player = json.parseToJsonElement(
            requestBytes(
                URL("https://www.youtube.com/youtubei/v1/player?prettyPrint=false"),
                4 * 1_024 * 1_024,
                "application/json",
                "POST",
                body,
                headers,
            ).decodeToString(),
        ) as JsonObject
        if (player.obj("playabilityStatus")?.string("status") != "OK") {
            throw LinkImportException(LinkImportStage.InspectingSource, "YOUTUBE_UNAVAILABLE", "YouTube could not provide anonymous playback for this video.")
        }
        val details = player.obj("videoDetails") ?: JsonObject(emptyMap())
        if (details.bool("isLive") || details.bool("isLiveContent") || details.bool("isUpcoming")) {
            throw LinkImportException(LinkImportStage.InspectingSource, "YOUTUBE_LIVE_UNSUPPORTED", "Live and upcoming YouTube videos are not supported.")
        }
        val streaming = player.obj("streamingData") ?: JsonObject(emptyMap())
        val formats = (streaming.array("adaptiveFormats") + streaming.array("formats"))
            .mapNotNull { it as? JsonObject }
            .filter {
                it.string("mimeType")?.startsWith("audio/mp4", true) == true
                    && it.string("url") != null && it.long("contentLength") > 0
                    && it["qualityLabel"] == null
            }
            .sortedByDescending { it.long("averageBitrate").takeIf { value -> value > 0 } ?: it.long("bitrate") }
        val format = formats.firstOrNull() ?: throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_NO_VERIFIED_M4A",
            "YouTube did not provide a direct, verifiable M4A audio stream for this video.",
        )
        val stream = URL(requireNotNull(format.string("url")))
        if (!isGoogleVideo(stream)) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_UNSAFE_STREAM",
            "YouTube returned an untrusted audio stream.",
        )
        val length = format.long("contentLength")
        if (length !in 1..maxAudioBytes) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_AUDIO_TOO_LARGE",
            "The selected audio is too large to import on this device.",
        )
        val thumbs = details.obj("thumbnail")?.array("thumbnails").orEmpty().mapNotNull { it as? JsonObject }
        val thumbnail = thumbs.maxByOrNull { it.long("width") }?.string("url")?.takeIf(::isArtwork)
        val candidate = LinkImportCandidate(
            videoID,
            details.string("title") ?: videoID,
            details.string("author"),
            details.string("lengthSeconds")?.toIntOrNull() ?: details["lengthSeconds"]?.jsonPrimitive?.intOrNull,
            thumbnail,
            "https://www.youtube.com/watch?v=" + videoID,
            1.0,
        )
        return ResolvedAudio(candidate, stream, length)
    }

    private suspend fun downloadRanges(
        resolved: ResolvedAudio,
        destination: File,
        progress: (LinkImportProgress) -> Unit,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        var completed = 0L
        FileOutputStream(destination).use { output ->
            while (completed < resolved.contentLength) {
                currentCoroutineContext().ensureActive()
                val end = minOf(resolved.contentLength - 1, completed + 10L * 1_024 * 1_024 - 1)
                val connection = open(
                    resolved.streamURL,
                    "GET",
                    mapOf(
                        "Range" to "bytes=" + completed + "-" + end,
                        "Accept-Encoding" to "identity",
                        "User-Agent" to playerAgent,
                        "Origin" to "https://www.youtube.com",
                    ),
                )
                try {
                    val status = connection.responseCode
                    if (!isGoogleVideo(connection.url) || status !in listOf(200, 206)) {
                        throw LinkImportException(LinkImportStage.Downloading, "YOUTUBE_DOWNLOAD_FAILED", "The YouTube audio stream could not be read.")
                    }
                    val contentType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
                    if (contentType != "audio/mp4") throw LinkImportException(
                        LinkImportStage.Downloading,
                        "YOUTUBE_CONTENT_TYPE_MISMATCH",
                        "YouTube returned an unexpected audio format.",
                    )
                    val expectedBytes = if (status == 206) {
                        expectedRangeLength(
                            connection.getHeaderField("Content-Range"),
                            completed,
                            end,
                            resolved.contentLength,
                        )
                    } else {
                        if (completed != 0L || end != resolved.contentLength - 1) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_RANGE_MISMATCH",
                            "YouTube ignored a required audio range.",
                        )
                        resolved.contentLength
                    }
                    connection.inputStream.use { input ->
                        val buffer = ByteArray(64 * 1_024)
                        var received = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (received + count > expectedBytes) throw LinkImportException(
                                LinkImportStage.Downloading,
                                "YOUTUBE_RANGE_OVERFLOW",
                                "YouTube returned more audio data than requested.",
                            )
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            received += count
                            progress(LinkImportProgress(LinkImportStage.Downloading, completed + received, resolved.contentLength))
                        }
                        if (received != expectedBytes || completed + received > resolved.contentLength) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_SIZE_MISMATCH",
                            "YouTube returned an unverifiable audio size.",
                        )
                        completed += received
                    }
                } finally {
                    connection.disconnect()
                }
            }
        }
        if (completed != resolved.contentLength) throw LinkImportException(
            LinkImportStage.Downloading,
            "YOUTUBE_SIZE_MISMATCH",
            "The downloaded audio size could not be verified.",
        )
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun fetchArtwork(value: String?): ByteArray? {
        val url = value?.takeIf(::isArtwork)?.let(::URL) ?: return null
        return runCatching { requestBytes(url, 10 * 1_024 * 1_024, "image/*") }.getOrNull()
    }

    private suspend fun spotifyURL(value: String): URL? {
        val source = runCatching { URL(value) }.getOrNull() ?: return null
        if (source.protocol != "https" || source.host.lowercase() !in spotifyHosts || source.userInfo != null) return null
        if (!source.host.lowercase().contains("spotify.link")) return source
        val connection = open(source, "HEAD")
        return try {
            connection.responseCode
            spotifyURL(connection.url.toString())
        } finally {
            connection.disconnect()
        }
    }

    private fun youtubeID(value: String): String? {
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.userInfo != null) return null
        if (uri.rawQuery.orEmpty().split('&').any { it.substringBefore('=') == "list" }) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "UNSUPPORTED_YOUTUBE_COLLECTION",
            "Only individual YouTube videos are supported.",
        )
        val host = uri.host?.lowercase() ?: return null
        val segments = uri.path.split('/').filter(String::isNotBlank)
        val id = when {
            host == "youtu.be" || host == "www.youtu.be" -> segments.firstOrNull()
            host in youtubeHosts && uri.path == "/watch" -> uri.rawQuery.orEmpty().split('&')
                .firstOrNull { it.substringBefore('=') == "v" }?.substringAfter('=')
            host in youtubeHosts && segments.firstOrNull() in setOf("shorts", "live", "embed") -> segments.getOrNull(1)
            else -> null
        }
        return id?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{11}")) }
    }

    private suspend fun request(url: URL, limit: Int, accept: String): String =
        requestBytes(url, limit, accept).decodeToString()

    private suspend fun requestBytes(
        url: URL,
        limit: Int,
        accept: String,
        method: String = "GET",
        body: ByteArray? = null,
        headers: Map<String, String> = emptyMap(),
    ): ByteArray {
        val connection = open(
            url,
            method,
            mapOf("Accept" to accept, "Accept-Language" to "en-US,en;q=0.8", "User-Agent" to webAgent) + headers,
        )
        try {
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
            if (status !in 200..299) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "PROVIDER_HTTP_" + status,
                "The media provider returned HTTP " + status + ".",
            )
            if (connection.contentLengthLong > limit) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "PROVIDER_RESPONSE_TOO_LARGE",
                "A media provider returned an oversized response.",
            )
            return connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1_024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw LinkImportException(
                        LinkImportStage.InspectingSource,
                        "PROVIDER_RESPONSE_TOO_LARGE",
                        "A media provider returned an oversized response.",
                    )
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun open(url: URL, method: String, headers: Map<String, String> = emptyMap()): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = true
            connectTimeout = 45_000
            readTimeout = 180_000
            headers.forEach(::setRequestProperty)
        }

    private fun isGoogleVideo(url: URL): Boolean =
        url.protocol == "https" && (url.host == "googlevideo.com" || url.host.endsWith(".googlevideo.com"))

    private fun expectedRangeLength(value: String?, start: Long, end: Long, total: Long): Long {
        val match = Regex("""^bytes\s+(\d+)-(\d+)/(\d+)$""", RegexOption.IGNORE_CASE)
            .matchEntire(value?.trim().orEmpty())
        val actualStart = match?.groupValues?.getOrNull(1)?.toLongOrNull()
        val actualEnd = match?.groupValues?.getOrNull(2)?.toLongOrNull()
        val actualTotal = match?.groupValues?.getOrNull(3)?.toLongOrNull()
        if (actualStart != start || actualEnd != end || actualTotal != total) throw LinkImportException(
            LinkImportStage.Downloading,
            "YOUTUBE_RANGE_MISMATCH",
            "YouTube returned an unverifiable audio range.",
        )
        return end - start + 1
    }

    private fun isArtwork(value: String): Boolean = runCatching {
        val url = URL(value)
        val host = url.host.lowercase()
        url.protocol == "https" && (
            host == "ytimg.com" || host.endsWith(".ytimg.com")
                || host == "ggpht.com" || host.endsWith(".ggpht.com")
                || host == "scdn.co" || host.endsWith(".scdn.co")
                || host == "spotifycdn.com" || host.endsWith(".spotifycdn.com")
        )
    }.getOrDefault(false)

    private fun capture(value: String, pattern: Regex): String? =
        pattern.find(value)?.groupValues?.getOrNull(1)?.let { encoded ->
            runCatching { json.decodeFromString<String>("\"" + encoded + "\"") }.getOrDefault(encoded)
        }

    private fun normalize(value: String): String =
        value.lowercase().replace(Regex("""[^\p{L}\p{N}]+"""), " ").trim()

    private fun overlap(expected: String, actual: String): Double {
        val tokens = expected.split(' ').filter { it.length > 1 }.toSet()
        if (tokens.isEmpty()) return 0.0
        val actualTokens = actual.split(' ').toSet()
        return tokens.count(actualTokens::contains).toDouble() / tokens.size
    }

    private fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.long(key: String): Long =
        this[key]?.jsonPrimitive?.longOrNull ?: this[key]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
    private fun JsonObject.bool(key: String): Boolean =
        (this[key] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull() ?: false
    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.array(key: String): List<JsonElement> = (this[key] as? JsonArray)?.toList().orEmpty()
}
