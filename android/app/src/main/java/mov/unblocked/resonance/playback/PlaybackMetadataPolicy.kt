package mov.unblocked.resonance.playback

data class PublishedPlaybackMetadata(
    val title: String,
    val artist: String,
    val album: String?,
    val durationMs: Long?,
)

/** Normalizes the metadata that Media3 publishes to Android's system media surfaces. */
object PlaybackMetadataPolicy {
    fun published(
        title: String,
        artist: String,
        album: String,
        durationMs: Long,
    ): PublishedPlaybackMetadata = PublishedPlaybackMetadata(
        title = title.trim().ifBlank { "Unknown Title" },
        artist = artist.trim().ifBlank { "Unknown Artist" },
        album = album.trim().takeIf(String::isNotEmpty),
        durationMs = durationMs.takeIf { it > 0L },
    )
}
