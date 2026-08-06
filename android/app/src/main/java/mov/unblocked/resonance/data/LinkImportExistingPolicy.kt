package mov.unblocked.resonance.data

data class LinkImportExistingMatch(
    val deviceTrackID: String? = null,
    val serverSongID: String? = null,
) {
    val isOnDevice: Boolean get() = deviceTrackID != null
    val isOnServer: Boolean get() = serverSongID != null
}

object LinkImportExistingPolicy {
    fun match(
        expected: LinkImportTrack,
        deviceTracks: List<Track>,
        activeServerSongs: List<RemoteSong>,
    ): LinkImportExistingMatch {
        val device = deviceTracks.firstOrNull { candidate ->
            metadataMatches(
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
            metadataMatches(
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

    private fun metadataMatches(
        expectedTitle: String,
        expectedArtist: String,
        expectedDuration: Double?,
        actualTitle: String,
        actualArtist: String,
        actualDuration: Double?,
    ): Boolean {
        if (normalize(expectedTitle) != normalize(actualTitle)) return false
        if (artistTokens(expectedArtist) != artistTokens(actualArtist)) return false
        return expectedDuration == null || expectedDuration <= 0 || actualDuration == null || actualDuration <= 0 ||
            kotlin.math.abs(expectedDuration - actualDuration) <= 5
    }

    private fun artistTokens(value: String): Set<String> = normalize(value)
        .split(' ')
        .filter(String::isNotBlank)
        .filterNot { it in setOf("and", "feat", "featuring", "with") }
        .toSet()

    private fun normalize(value: String): String = value.lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .trim()
}
