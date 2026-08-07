package mov.unblocked.resonance.data

import java.net.URI
import kotlin.math.roundToInt
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

enum class LinkImportSearchProvider(val displayName: String) {
    Spotify("Spotify"),
    SoundCloud("SoundCloud"),
    YouTube("YouTube"),
}

data class LinkImportSearchResult(
    val provider: LinkImportSearchProvider,
    val track: LinkImportTrack,
    val candidates: List<LinkImportCandidate>,
) {
    val id: String get() = provider.name.lowercase() + ":" + track.sourceURL
    val resolution: LinkImportResolution get() = LinkImportResolution(track, candidates)
}

data class LinkImportSearchResponse(
    val query: String,
    val results: List<LinkImportSearchResult>,
) {
    fun resultsFor(provider: LinkImportSearchProvider): List<LinkImportSearchResult> =
        results.filter { it.provider == provider }
}

internal object LinkImportInput {
    private val scheme = Regex("^[A-Za-z][A-Za-z0-9+.-]*://")
    private val domain = Regex("^[^/?#]+\\.[A-Za-z]{2,}(?:[/?#:]|$)", RegexOption.IGNORE_CASE)

    fun looksLikeLink(value: String): Boolean {
        val input = value.trim()
        if (input.isEmpty()) return false
        if (scheme.containsMatchIn(input)) return true
        if (input.any(Char::isWhitespace)) return false
        return input.startsWith("www.", ignoreCase = true) || domain.containsMatchIn(input)
    }

    fun isReviewedTrackLink(value: String): Boolean {
        val uri = runCatching { URI(value.trim()) }.getOrNull() ?: return false
        if (!uri.scheme.equals("https", ignoreCase = true) || uri.userInfo != null || uri.port != -1) {
            return false
        }
        val host = uri.host?.lowercase() ?: return false
        val segments = uri.path.split('/').filter(String::isNotBlank)
        if (host == "open.spotify.com") {
            return segments.size == 2 &&
                segments[0] == "track" &&
                segments[1].matches(Regex("^[A-Za-z0-9]{22}$")) &&
                uri.rawFragment == null
        }
        return reviewedYouTubeVideoID(value) != null
    }

    fun reviewedYouTubeVideoID(value: String): String? {
        val uri = runCatching { URI(value.trim()) }.getOrNull() ?: return null
        if (!uri.scheme.equals("https", ignoreCase = true) || uri.userInfo != null || uri.port != -1) {
            return null
        }
        val host = uri.host?.lowercase() ?: return null
        val segments = uri.path.split('/').filter(String::isNotBlank)
        if (uri.rawQuery.orEmpty().split('&').any { it.substringBefore('=') == "list" }) return null
        val videoID = when {
            host in setOf("youtu.be", "www.youtu.be") && segments.size == 1 -> segments.single()
            host in setOf("youtube.com", "www.youtube.com", "m.youtube.com") && uri.path == "/watch" ->
                uri.rawQuery.orEmpty().split('&')
                    .firstOrNull { it.substringBefore('=') == "v" }
                    ?.substringAfter('=')
            host in setOf("youtube.com", "www.youtube.com", "m.youtube.com") &&
                segments.size == 2 && segments.firstOrNull() in setOf("shorts", "live", "embed") ->
                segments.getOrNull(1)
            else -> null
        }
        return videoID?.takeIf { it.matches(Regex("^[A-Za-z0-9_-]{11}$")) }
    }
}

internal object ReviewedMatchResolutionPolicy {
    fun bindLocalYouTubeCandidate(
        requestedSource: String,
        resolution: LinkImportResolution,
    ): LinkImportResolution? {
        if (resolution.kind != LinkImportKind.Track) return null
        val videoID = LinkImportInput.reviewedYouTubeVideoID(requestedSource) ?: return null
        val candidate = resolution.candidates.singleOrNull {
            it.videoID == videoID && it.sourceProvider == LinkImportSourceProvider.YouTube
        } ?: return null
        return resolution.copy(
            candidates = listOf(candidate.copy(fallbackCandidates = emptyList())),
            reviewedMatchPolicyBound = true,
        )
    }
}

internal object LinkImportSearchParser {
    fun spotifyTracks(payload: String, json: Json = Json { ignoreUnknownKeys = true }): List<LinkImportTrack> {
        val root = runCatching { json.parseToJsonElement(payload) as? JsonObject }.getOrNull() ?: return emptyList()
        val values = (root["data"] as? JsonObject)?.get("tracks") as? JsonArray ?: return emptyList()
        val seen = mutableSetOf<String>()
        return values.mapNotNull { value ->
            val record = value as? JsonObject ?: return@mapNotNull null
            val id = record.clean("id", 22)?.takeIf { it.matches(Regex("^[A-Za-z0-9]{22}$")) }
                ?: return@mapNotNull null
            if (!seen.add(id)) return@mapNotNull null
            val title = record.clean("title") ?: return@mapNotNull null
            val artist = record.clean("artist") ?: return@mapNotNull null
            val durationValue = record["duration"]?.jsonPrimitive?.doubleOrNull
                ?: record["duration"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()
            val duration = durationValue?.takeIf { it > 0 }?.let {
                (if (it > 86_400) it / 1_000 else it).roundToInt()
            }
            LinkImportTrack(
                title = title,
                artist = artist,
                album = record.clean("album"),
                durationSeconds = duration,
                artworkURL = record.clean("artworkURL")?.takeIf(::isSpotifyArtwork),
                sourceURL = "https://open.spotify.com/track/$id",
                trackNumber = record["trackNumber"]?.jsonPrimitive?.intOrNull?.takeIf { it >= 0 },
            )
        }
    }

    private fun JsonObject.clean(key: String, maximum: Int = 500): String? =
        (this[key] as? JsonPrimitive)?.contentOrNull
            ?.replace(Regex("[\\u0000-\\u001f]+"), " ")
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?.take(maximum)

    private fun isSpotifyArtwork(value: String): Boolean = runCatching {
        val url = java.net.URL(value)
        val host = url.host.lowercase()
        url.protocol == "https" && url.userInfo == null && (
            host == "scdn.co" || host.endsWith(".scdn.co")
                || host == "spotifycdn.com" || host.endsWith(".spotifycdn.com")
        )
    }.getOrDefault(false)
}
