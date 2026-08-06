package mov.unblocked.resonance.data

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
