package mov.unblocked.resonance.playback

object DownloadPolicy {
    fun songIdsToDownload(
        remoteSongIds: List<String>,
        downloadedSongIds: Set<String>,
        selectedSongIds: Set<String>,
    ): Set<String> {
        val candidates = if (selectedSongIds.isEmpty()) remoteSongIds.toSet() else selectedSongIds
        return candidates - downloadedSongIds
    }
}
