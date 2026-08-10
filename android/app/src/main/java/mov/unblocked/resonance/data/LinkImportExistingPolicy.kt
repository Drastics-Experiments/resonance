package mov.unblocked.resonance.data

import java.net.URI
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
        activeServerURL: String,
        activeProfileID: String,
        mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
    ): LinkImportExistingMatch {
        val device = deviceTracks.firstOrNull { candidate ->
            trackMediaMode(candidate) == mediaMode &&
            RemoteTrackIdentityPolicy.visibleInContext(
                candidate,
                activeServerURL,
                activeProfileID,
            ) && ServerSongIdentityPolicy.metadataMatches(
                expected.title,
                expected.artist,
                expected.durationSeconds?.toDouble(),
                candidate.title,
                candidate.artist,
                candidate.durationMs.takeIf { it > 0 }?.div(1_000.0),
            )
        }
        val activeOrigin = serverOrigin(activeServerURL)
        val trustedDeviceRemoteID = device?.remoteID?.takeIf {
            activeOrigin != null &&
                serverOrigin(device.sourceServer.orEmpty()) == activeOrigin &&
                (device.syncProfileID ?: "default") == activeProfileID
        }
        val server = trustedDeviceRemoteID?.let { remoteID ->
            activeServerSongs.firstOrNull {
                it.id == remoteID && (it.isVideoMedia == (mediaMode == LinkImportMediaMode.Video))
            }
        } ?: activeServerSongs.filter { candidate ->
            (candidate.isVideoMedia == (mediaMode == LinkImportMediaMode.Video)) &&
            ServerSongIdentityPolicy.metadataMatches(
                expected.title,
                expected.artist,
                expected.durationSeconds?.toDouble(),
                candidate.title,
                candidate.artist,
                candidate.durationSeconds,
            )
        }.singleOrNull()
        return LinkImportExistingMatch(device?.id, server?.id)
    }

    private fun trackMediaMode(track: Track): LinkImportMediaMode =
        if (track.relativePath.substringAfterLast('.', "").lowercase() in setOf("mp4", "mov", "m4v", "webm")) {
            LinkImportMediaMode.Video
        } else {
            LinkImportMediaMode.Audio
        }

    private fun serverOrigin(value: String): String? = runCatching {
        val uri = URI(value)
        val port = if (uri.port >= 0) uri.port else if (uri.scheme.equals("https", true)) 443 else 80
        "${uri.scheme.lowercase()}://${uri.host.lowercase()}:$port"
    }.getOrNull()
}
