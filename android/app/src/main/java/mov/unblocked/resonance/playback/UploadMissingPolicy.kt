package mov.unblocked.resonance.playback

import java.net.URI
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track

data class MissingDownloadedUploadPlan(
    val uploadTrackIDs: List<String>,
    val existingRemoteIDsByTrackID: Map<String, String>,
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
            song.contentSHA256?.trim()?.lowercase()?.takeIf(String::isNotEmpty)?.let { it to song.id }
        }.toMap()
        val activeOrigin = origin(activeServerURL)
        val uploadTrackIDs = ArrayList<String>()
        val existingRemoteIDs = linkedMapOf<String, String>()

        tracks.forEach { track ->
            if (track.remoteID == null && track.sourceServer == null) return@forEach
            if ((track.syncProfileID ?: "default") != activeProfileID) return@forEach
            if (track.sourceServer != null && activeOrigin != null && origin(track.sourceServer) != activeOrigin) return@forEach
            if (track.remoteID in remoteIDs) return@forEach
            val hashMatch = track.contentSHA256?.trim()?.lowercase()?.let(remoteByHash::get)
            if (hashMatch != null) existingRemoteIDs[track.id] = hashMatch
            else uploadTrackIDs += track.id
        }
        return MissingDownloadedUploadPlan(uploadTrackIDs, existingRemoteIDs)
    }

    private fun origin(value: String): String? = runCatching {
        val uri = URI(value)
        val port = if (uri.port >= 0) uri.port else if (uri.scheme.equals("https", true)) 443 else 80
        "${uri.scheme.lowercase()}://${uri.host.lowercase()}:$port"
    }.getOrNull()
}
