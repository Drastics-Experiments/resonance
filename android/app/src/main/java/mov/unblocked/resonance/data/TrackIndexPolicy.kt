package mov.unblocked.resonance.data

/**
 * Builds stable first-wins indexes for the in-memory library.
 *
 * Track identity is repaired at persistence boundaries, but an index still needs deterministic
 * behavior while a mutation is in flight. A first-wins map matches the presentation order and
 * avoids the accidental last-record replacement that associateBy would introduce.
 */
internal object TrackIndexPolicy {
    fun byID(tracks: Iterable<Track>): Map<String, Track> = index(tracks) { it.id }

    fun byRemoteID(
        tracks: Iterable<Track>,
        serverURL: String,
        profileID: String,
    ): Map<String, Track> = index(
        tracks.asSequence().filter {
            RemoteTrackIdentityPolicy.belongsToContext(it, serverURL, profileID)
        }.asIterable(),
    ) { it.remoteID.orEmpty() }

    private fun index(
        tracks: Iterable<Track>,
        key: (Track) -> String,
    ): Map<String, Track> = LinkedHashMap<String, Track>().also { indexed ->
        tracks.forEach { track ->
            key(track).takeIf(String::isNotBlank)?.let { indexed.putIfAbsent(it, track) }
        }
    }
}
