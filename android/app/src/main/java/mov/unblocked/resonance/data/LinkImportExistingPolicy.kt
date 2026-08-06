package mov.unblocked.resonance.data

import java.text.Normalizer

data class LinkImportExistingMatch(
    val deviceTrackID: String? = null,
    val serverSongID: String? = null,
) {
    val isOnDevice: Boolean get() = deviceTrackID != null
    val isOnServer: Boolean get() = serverSongID != null
}

object ServerSongIdentityPolicy {
    fun metadataMatches(
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: Double?,
        actualTitle: String,
        actualArtist: String,
        actualDuration: Double?,
    ): Boolean {
        if (normalize(expectedTitle) != normalize(actualTitle)) return false
        val expectedArtists = artistTokens(expectedArtist)
        val actualArtists = artistTokens(actualArtist)
        if (expectedArtists.isEmpty() || expectedArtists != actualArtists) return false
        return expectedDuration == null || expectedDuration <= 0 || actualDuration == null || actualDuration <= 0 ||
            kotlin.math.abs(expectedDuration - actualDuration) <= 5
    }

    private fun artistTokens(value: String): Set<String> = normalize(value)
        .split(' ')
        .filter(String::isNotBlank)
        .filterNot { it in setOf("and", "feat", "featuring", "ft", "with", "unknown", "artist", "local", "file") }
        .toSet()

    private fun normalize(value: String): String = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFKD)
        .replace(Regex("""\p{M}+"""), "")
        .replace(Regex("""[^\p{L}\p{N}]+"""), " ")
        .trim()
}

object LinkImportExistingPolicy {
    fun match(
        expected: LinkImportTrack,
        deviceTracks: List<Track>,
        activeServerSongs: List<RemoteSong>,
    ): LinkImportExistingMatch {
        val device = deviceTracks.firstOrNull { candidate ->
            ServerSongIdentityPolicy.metadataMatches(
                expected.title,
                expected.artist,
                expected.durationSeconds?.toDouble(),
                candidate.title,
                candidate.artist,
                candidate.durationMs.takeIf { it > 0 }?.div(1_000.0),
            )
        }
        val server = device?.remoteID?.let { remoteID ->
            activeServerSongs.firstOrNull { it.id == remoteID }
        } ?: activeServerSongs.firstOrNull { candidate ->
            ServerSongIdentityPolicy.metadataMatches(
                expected.title,
                expected.artist,
                expected.durationSeconds?.toDouble(),
                candidate.title,
                candidate.artist,
                candidate.durationSeconds,
            )
        }
        return LinkImportExistingMatch(device?.id, server?.id)
    }

}
