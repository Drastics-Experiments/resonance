package mov.unblocked.resonance.playback

import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.RemoteTrackIdentityPolicy
import mov.unblocked.resonance.data.ServerSongIdentityPolicy
import mov.unblocked.resonance.data.Track

data class MissingDownloadedUploadPlan(
    val uploadTrackIDs: List<String>,
    val existingRemoteIDsByTrackID: Map<String, String>,
    val reviewTrackIDs: List<String> = emptyList(),
)

object UploadMissingPolicy {
    fun plan(
        tracks: List<Track>,
        catalog: List<RemoteSong>,
        activeProfileID: String,
        activeServerURL: String,
    ): MissingDownloadedUploadPlan {
        val remoteIDs = catalog.mapTo(hashSetOf(), RemoteSong::id)
        val remoteByHash = catalog.mapNotNull { song ->
            song.contentSHA256?.normalizedSHA256()?.let { it to song.id }
        }.groupBy({ it.first }, { it.second })
        val uploadTrackIDs = ArrayList<String>()
        val existingRemoteIDs = linkedMapOf<String, String>()
        val reviewTrackIDs = ArrayList<String>()

        tracks.forEach { track ->
            if (track.remoteID == null && track.sourceServer == null) return@forEach
            if (!RemoteTrackIdentityPolicy.belongsToContext(track, activeServerURL, activeProfileID)) return@forEach
            if (track.remoteID in remoteIDs) return@forEach

            val hashMatches = track.contentSHA256?.normalizedSHA256()?.let(remoteByHash::get).orEmpty()
            when {
                hashMatches.size == 1 -> existingRemoteIDs[track.id] = hashMatches.single()
                hashMatches.size > 1 -> reviewTrackIDs += track.id
                hasPlausibleMetadataMatch(track, catalog) -> reviewTrackIDs += track.id
                else -> uploadTrackIDs += track.id
            }
        }
        return MissingDownloadedUploadPlan(uploadTrackIDs, existingRemoteIDs, reviewTrackIDs)
    }

    private fun hasPlausibleMetadataMatch(track: Track, catalog: List<RemoteSong>): Boolean =
        catalog.any { song ->
            ServerSongIdentityPolicy.metadataMatches(
                expectedTitle = track.title,
                expectedArtist = track.artist,
                expectedDuration = track.durationMs.takeIf { it > 0 }?.div(1_000.0),
                actualTitle = song.title,
                actualArtist = song.artist,
                actualDuration = song.durationSeconds,
            )
        }

    private fun String.normalizedSHA256(): String? = trim().lowercase()
        .takeIf { it.matches(Regex("[0-9a-f]{64}")) }
}
