package mov.unblocked.resonance.data

import java.net.URI
import java.net.URL
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * The playlist page is public metadata, but it is not a stable API. Keep all
 * parsing here so a changed renderer can make one playlist item unavailable
 * without discarding the other items that were returned successfully.
 */
internal object YouTubePlaylistParser {
    private val json = Json { ignoreUnknownKeys = true }
    private val playlistIDPattern = Regex("^[A-Za-z0-9_-]{10,150}$")
    private val videoIDPattern = Regex("^[A-Za-z0-9_-]{11}$")
    private val sourceHosts = setOf(
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "www.youtu.be",
    )
    private const val MAX_HTML_CHARACTERS = 8 * 1_024 * 1_024
    private const val MAX_TOKEN_LENGTH = 8_192

    data class Page(
        val title: String? = null,
        val author: String? = null,
        val artworkURL: String? = null,
        val items: List<LinkImportCandidate> = emptyList(),
        val continuation: String? = null,
        val unavailableCount: Int = 0,
        val rowCount: Int = 0,
        val lastPlaylistIndex: Int = 0,
    )

    data class Configuration(
        val apiKey: String?,
        val clientVersion: String?,
        val visitorData: String?,
    )

    /** Returns the playlist ID, or null when the URL is a regular YouTube URL. */
    fun playlistID(value: String): String? {
        val uri = runCatching { URI(value.trim()) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.userInfo != null) return null
        val host = uri.host?.lowercase() ?: return null
        if (host !in sourceHosts) return null
        val listValue = uri.rawQuery.orEmpty().split('&')
            .firstOrNull { it.substringBefore('=') == "list" }
            ?.substringAfter('=', "")
        if (listValue == null) return null
        if (!playlistIDPattern.matches(listValue)) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "INVALID_YOUTUBE_PLAYLIST",
            "The YouTube playlist URL is invalid.",
        )
        return listValue
    }

    fun parseHTML(
        html: String,
        expectedPlaylistID: String,
        fallbackIndexOffset: Int = 0,
    ): Page {
        if (html.length > MAX_HTML_CHARACTERS) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "YOUTUBE_PLAYLIST_RESPONSE_TOO_LARGE",
            "YouTube returned an oversized playlist response.",
        )
        val initialData = extractObject(html, "ytInitialData")?.let {
            runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull()
        } ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "YOUTUBE_PLAYLIST_INVALID",
            "YouTube returned invalid playlist metadata.",
        )
        return parse(initialData, expectedPlaylistID, fallbackIndexOffset)
    }

    fun parsePayload(
        payload: String,
        expectedPlaylistID: String,
        fallbackIndexOffset: Int = 0,
    ): Page {
        if (payload.length > MAX_HTML_CHARACTERS) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "YOUTUBE_PLAYLIST_RESPONSE_TOO_LARGE",
            "YouTube returned an oversized playlist response.",
        )
        val element = runCatching { json.parseToJsonElement(payload) }.getOrNull()
            ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "YOUTUBE_PLAYLIST_INVALID",
                "YouTube returned invalid playlist metadata.",
            )
        return parse(element, expectedPlaylistID, fallbackIndexOffset)
    }

    fun configuration(html: String): Configuration = Configuration(
        apiKey = configurationValue(html, "INNERTUBE_API_KEY", 256),
        clientVersion = configurationValue(html, "INNERTUBE_CLIENT_VERSION", 128),
        visitorData = configurationValue(html, "VISITOR_DATA", 2_048),
    )

    private fun parse(
        element: JsonElement,
        expectedPlaylistID: String,
        fallbackIndexOffset: Int,
    ): Page {
        var title: String? = null
        var author: String? = null
        var artwork: String? = null
        var continuation: String? = null
        var unavailable = 0
        var rowCount = 0
        var lastPlaylistIndex = fallbackIndexOffset
        val items = mutableListOf<LinkImportCandidate>()
        val seenVideoIDs = mutableSetOf<String>()

        walk(element) { record ->
            val metadata = record["playlistMetadataRenderer"] as? JsonObject
            val metadataID = metadata?.string("playlistId")
            if (metadataID != null && metadataID != expectedPlaylistID) throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "YOUTUBE_PLAYLIST_MISMATCH",
                "YouTube returned the wrong playlist.",
            )
            title = title ?: metadata?.get("title")?.let(::text)?.takeIf(String::isNotBlank)

            val header = record["playlistHeaderRenderer"] as? JsonObject
            title = title ?: header?.get("title")?.let(::text)?.takeIf(String::isNotBlank)
            author = author ?: header?.get("ownerText")?.let(::text)?.takeIf(String::isNotBlank)

            artwork = artwork ?: playlistArtwork(record)

            (record["playlistVideoRenderer"] as? JsonObject)?.let { renderer ->
                rowCount += 1
                val fallbackIndex = lastPlaylistIndex + 1
                val parsedCandidate = playlistCandidate(
                    renderer,
                    fallbackIndex,
                )
                lastPlaylistIndex = maxOf(
                    fallbackIndex,
                    parsedCandidate?.playlistIndex ?: fallbackIndex,
                )
                val candidate = parsedCandidate?.withPlaylistIndex(lastPlaylistIndex)
                if (candidate == null) {
                    unavailable += 1
                } else if (seenVideoIDs.add(candidate.videoID)) {
                    items += candidate
                }
            }

            // Newer YouTube surfaces can represent playlist rows as a lockup.
            // Parse the same stable fields when present, while keeping the
            // legacy playlistVideoRenderer path above for older responses.
            (record["lockupViewModel"] as? JsonObject)?.let { lockup ->
                if (lockup.string("contentType") == "LOCKUP_CONTENT_TYPE_VIDEO") {
                    rowCount += 1
                    val fallbackIndex = lastPlaylistIndex + 1
                    val candidate = lockupCandidate(lockup, fallbackIndex)
                        ?.withPlaylistIndex(fallbackIndex)
                    lastPlaylistIndex = fallbackIndex
                    if (candidate == null) {
                        unavailable += 1
                    } else if (seenVideoIDs.add(candidate.videoID)) {
                        items += candidate
                    }
                }
            }

            val token = (((record["continuationItemRenderer"] as? JsonObject)
                ?.get("continuationEndpoint") as? JsonObject)
                ?.get("continuationCommand") as? JsonObject)
                ?.string("token")
                ?.takeIf { it.length in 1..MAX_TOKEN_LENGTH }
            if (token != null) continuation = token
        }
        return Page(
            title,
            author,
            artwork,
            items,
            continuation,
            unavailable,
            rowCount,
            lastPlaylistIndex,
        )
    }

    private fun LinkImportCandidate.withPlaylistIndex(index: Int): LinkImportCandidate = copy(
        playlistIndex = index,
        importTrack = importTrack?.copy(trackNumber = index),
    )

    private fun playlistCandidate(renderer: JsonObject, fallbackIndex: Int): LinkImportCandidate? {
        val videoID = renderer.string("videoId")?.takeIf(videoIDPattern::matches) ?: return null
        if (renderer["isPlayable"]?.jsonPrimitive?.booleanOrNull == false) return null
        val title = renderer["title"]?.let(::text)?.takeIf(String::isNotBlank) ?: return null
        val artist = renderer["shortBylineText"]?.let(::text)?.takeIf(String::isNotBlank)
            ?: renderer["longBylineText"]?.let(::text)?.takeIf(String::isNotBlank)
            ?: "Unknown uploader"
        val index = renderer["index"]?.let(::text)?.toIntOrNull()
            ?.takeIf { it > 0 } ?: fallbackIndex
        val thumbnail = thumbnail(renderer["thumbnail"])
        val sourceURL = "https://www.youtube.com/watch?v=$videoID"
        val metadata = LinkImportTrack(
            title = title,
            artist = artist,
            durationSeconds = renderer["lengthText"]?.let(::text)?.let(::durationSeconds),
            artworkURL = thumbnail,
            sourceURL = sourceURL,
            trackNumber = index,
        )
        return LinkImportCandidate(
            videoID = videoID,
            title = title,
            artist = artist,
            durationSeconds = metadata.durationSeconds,
            thumbnailURL = thumbnail,
            sourceURL = sourceURL,
            score = 1.0,
            importTrack = metadata,
            playlistIndex = index,
            sourceProvider = LinkImportSourceProvider.YouTube,
        )
    }

    private fun lockupCandidate(lockup: JsonObject, fallbackIndex: Int): LinkImportCandidate? {
        if (lockup.string("contentType") != "LOCKUP_CONTENT_TYPE_VIDEO") return null
        val videoID = lockup.string("contentId")?.takeIf(videoIDPattern::matches) ?: return null
        val metadata = lockup["metadata"] as? JsonObject
        val view = metadata?.get("lockupMetadataViewModel") as? JsonObject
        val title = view?.get("title")?.let(::text)?.takeIf(String::isNotBlank) ?: return null
        val rows = ((view["metadata"] as? JsonObject)
            ?.get("contentMetadataViewModel") as? JsonObject)
            ?.get("metadataRows") as? JsonArray
        val artist = rows?.firstOrNull()?.let { row ->
            ((row as? JsonObject)?.get("metadataParts") as? JsonArray)
                ?.mapNotNull { (it as? JsonObject)?.get("text")?.let(::text) }
                ?.joinToString(" • ")
                ?.takeIf(String::isNotBlank)
        } ?: "Unknown uploader"
        val thumbnail = thumbnail(
            ((lockup["contentImage"] as? JsonObject)
                ?.get("thumbnailViewModel") as? JsonObject)
                ?.get("image"),
        )
        val sourceURL = "https://www.youtube.com/watch?v=$videoID"
        val track = LinkImportTrack(
            title = title,
            artist = artist,
            durationSeconds = lockupDuration(lockup),
            artworkURL = thumbnail,
            sourceURL = sourceURL,
            trackNumber = fallbackIndex,
        )
        return LinkImportCandidate(
            videoID = videoID,
            title = title,
            artist = artist,
            durationSeconds = track.durationSeconds,
            thumbnailURL = thumbnail,
            sourceURL = sourceURL,
            score = 1.0,
            importTrack = track,
            playlistIndex = fallbackIndex,
            sourceProvider = LinkImportSourceProvider.YouTube,
        )
    }

    private fun lockupDuration(lockup: JsonObject): Int? {
        val overlays = ((lockup["contentImage"] as? JsonObject)
            ?.get("thumbnailViewModel") as? JsonObject)
            ?.get("overlays") as? JsonArray ?: return null
        return overlays.asSequence().mapNotNull { overlay ->
            val badges = (((overlay as? JsonObject)?.get("thumbnailBottomOverlayViewModel") as? JsonObject)
                ?.get("badges") as? JsonArray).orEmpty()
            badges.mapNotNull { badge ->
                (((badge as? JsonObject)?.get("thumbnailBadgeViewModel") as? JsonObject)
                    ?.string("text"))?.let(::durationSeconds)
            }.firstOrNull()
        }.firstOrNull()
    }

    private fun playlistArtwork(record: JsonObject): String? {
        val primary = record["playlistSidebarPrimaryInfoRenderer"] as? JsonObject ?: return null
        val thumbnailRenderer = primary["thumbnailRenderer"] as? JsonObject ?: return null
        val renderer = thumbnailRenderer["playlistVideoThumbnailRenderer"] as? JsonObject
            ?: thumbnailRenderer["playlistCustomThumbnailRenderer"] as? JsonObject
            ?: return null
        return thumbnail(renderer["thumbnail"])
    }

    private fun thumbnail(value: JsonElement?): String? {
        val values = (value as? JsonObject)?.get("thumbnails") as? JsonArray ?: return null
        return values.mapNotNull { item ->
            val source = item as? JsonObject ?: return@mapNotNull null
            val url = source.string("url") ?: return@mapNotNull null
            val width = source.long("width")
            val height = source.long("height")
            Triple(url, width, height)
        }.sortedWith(compareByDescending<Triple<String, Long, Long>> { it.second * it.third }.thenByDescending { it.second })
            .map { it.first }
            .firstOrNull(::isArtwork)
    }

    private fun isArtwork(value: String): Boolean = runCatching {
        val url = URL(value)
        RemoteURLPolicy.isSafeURL(url, approvedHost = { host ->
            host == "ytimg.com" || host.endsWith(".ytimg.com") ||
                host == "ggpht.com" || host.endsWith(".ggpht.com")
        })
    }.getOrDefault(false)

    private fun durationSeconds(value: String): Int? {
        val parts = value.trim().split(':')
        if (parts.isEmpty() || parts.size > 3 || parts.any { !it.matches(Regex("\\d+")) }) return null
        val numbers = parts.map(String::toLong)
        val seconds = when (numbers.size) {
            1 -> numbers[0]
            2 -> numbers[0] * 60 + numbers[1]
            else -> numbers[0] * 3_600 + numbers[1] * 60 + numbers[2]
        }
        return seconds.takeIf { it in 1..(24 * 3_600) }?.toInt()
    }

    private fun configurationValue(html: String, key: String, maximum: Int): String? {
        val match = Regex("\\\"$key\\\"\\s*:\\s*\\\"((?:\\\\.|[^\\\"\\\\])*)\\\"").find(html)
            ?: return null
        val encoded = match.groupValues.getOrNull(1) ?: return null
        return runCatching { json.parseToJsonElement("\"$encoded\"").jsonPrimitive.content }
            .getOrNull()
            ?.takeIf { it.length <= maximum }
    }

    private fun extractObject(source: String, marker: String): String? {
        val markerIndex = source.indexOf(marker)
        if (markerIndex < 0) return null
        val start = source.indexOf('{', markerIndex)
        if (start < 0) return null
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
                continue
            }
            when (character) {
                '"' -> quoted = true
                '{' -> depth += 1
                '}' -> {
                    depth -= 1
                    if (depth == 0) return source.substring(start, index + 1)
                }
            }
        }
        return null
    }

    private fun walk(element: JsonElement, visit: (JsonObject) -> Unit) {
        when (element) {
            is JsonObject -> {
                visit(element)
                element.values.forEach { walk(it, visit) }
            }
            is JsonArray -> element.forEach { walk(it, visit) }
            else -> Unit
        }
    }

    private fun text(element: JsonElement): String = when (element) {
        is JsonPrimitive -> element.contentOrNull.orEmpty()
        is JsonObject -> {
            element["content"]?.let(::text)?.takeIf(String::isNotBlank)
                ?: element["simpleText"]?.let(::text)?.takeIf(String::isNotBlank)
                ?: (element["runs"] as? JsonArray)?.mapNotNull { run ->
                    (run as? JsonObject)?.get("text")?.let(::text)
                }?.joinToString("").orEmpty()
        }
        is JsonArray -> element.map(::text).joinToString("")
    }

    private fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.long(key: String): Long =
        this[key]?.jsonPrimitive?.longOrNull ?: this[key]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
}

internal object YouTubePlaylistLimitPolicy {
    const val MAX_ITEMS = 500
    const val MAX_CONTINUATIONS = 10

    data class PageResult(
        val items: List<LinkImportCandidate>,
        val overflowed: Boolean,
    )

    fun takeInitial(items: List<LinkImportCandidate>): PageResult {
        val limited = items.take(MAX_ITEMS)
        return PageResult(limited, items.size > limited.size)
    }

    fun append(
        existing: List<LinkImportCandidate>,
        incoming: List<LinkImportCandidate>,
    ): PageResult {
        val seen = existing.mapTo(mutableSetOf(), LinkImportCandidate::videoID)
        val unique = incoming.filter { seen.add(it.videoID) }
        val remaining = (MAX_ITEMS - existing.size).coerceAtLeast(0)
        return PageResult(unique.take(remaining), unique.size > remaining)
    }

    fun hasRemainingContinuation(continuation: String?): Boolean = continuation != null
}
