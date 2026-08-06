package mov.unblocked.resonance.ui

/**
 * All side effects requested by the Compose UI. Keeping this contract separate makes every
 * screen previewable and prevents the UI layer from depending directly on a ViewModel.
 */
interface ResonanceActions {
    fun dismissError()
    fun importAudio()
    fun setLibrarySearch(query: String)
    fun playTrack(trackId: String, queueTrackIds: List<String>? = null, playlistId: String? = null)
    fun togglePlayPause()
    fun playNext()
    fun playPrevious()
    fun seekToFraction(fraction: Float)
    fun setShuffleEnabled(enabled: Boolean)
    fun setRepeatEnabled(enabled: Boolean)
    fun setPlaybackSpeed(speed: Float)
    fun setVolume(volume: Float)
    fun toggleFavorite(trackId: String)
    fun deleteTracksFromDevice(trackIds: Set<String>)
    fun saveClipRange(trackId: String, startMs: Long, endMs: Long)
    fun clearClipRange(trackId: String)
    fun resolveLinkImport(source: String)
    fun selectLinkImportSearchResult(resultId: String)
    fun selectLinkImportCandidate(videoId: String)
    fun confirmLinkImport(uploadAfterImport: Boolean): Boolean
    fun toggleLinkImportPreview(videoId: String)
    fun stopLinkImportPreview()
    fun cancelLinkImport()

    fun createPlaylist(name: String)
    fun deletePlaylist(playlistId: String)
    fun playPlaylist(playlistId: String)
    fun addTrackToPlaylist(playlistId: String, trackId: String)
    fun removeTrackFromPlaylist(playlistId: String, trackId: String)
    fun movePlaylistTrack(playlistId: String, fromIndex: Int, toIndex: Int)

    fun onServerScreenOpened()
    fun refreshServer()
    fun saveServerConnection(url: String, accessToken: String, adminKey: String, profileName: String)
    fun uploadAudio()
    fun uploadMissingDownloads()
    fun downloadRemoteSong(songId: String)
    fun downloadSelectedRemoteSongs()
    fun toggleRemoteSelection(songId: String)
    fun clearRemoteSelection()
    fun deleteRemoteSong(songId: String)
}
