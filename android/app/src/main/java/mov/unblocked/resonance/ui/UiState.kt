package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track

enum class ResonanceTab(val label: String) {
    Library("Library"),
    Playlists("Playlists"),
    Storage("Storage"),
    Server("Server"),
}

enum class StorageScope(val label: String) {
    Songs("Songs"),
    Downloads("Downloads"),
    Files("Files"),
}

enum class StorageSort(val label: String) {
    Title("Title"),
    Artist("Artist"),
    RecentlyAdded("Recently Added"),
    FileSize("File Size"),
}

enum class ServerScope(val label: String) {
    All("All"),
    OnDevice("On Device"),
    NotDownloaded("Not Downloaded"),
}

enum class ServerSort(val label: String) {
    Title("Title"),
    Artist("Artist"),
    FileSize("File Size"),
    RecentlyUpdated("Recently Updated"),
}

/** A complete, render-only snapshot of Resonance. The ViewModel owns this state. */
data class ResonanceUiState(
    val tracks: List<Track> = emptyList(),
    val artworkPathsByTrackId: Map<String, String> = emptyMap(),
    val trackSizesById: Map<String, Long> = emptyMap(),
    val playlists: List<Playlist> = emptyList(),
    val favoriteTrackIds: Set<String> = emptySet(),
    val currentTrackId: String? = null,
    val activePlaylistId: String? = null,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0,
    val shuffleEnabled: Boolean = false,
    val repeatEnabled: Boolean = false,
    val playbackSpeed: Float = 1f,
    val librarySearch: String = "",
    val serverUrl: String = "https://music.unblocked.mov",
    val serverToken: String = "",
    val serverAdminKey: String = "",
    val serverMessage: String = "Not connected",
    val remoteSongs: List<RemoteSong> = emptyList(),
    val downloadedRemoteSongIds: Set<String> = emptySet(),
    val selectedRemoteSongIds: Set<String> = emptySet(),
    val isRefreshingServer: Boolean = false,
    val isDownloading: Boolean = false,
    val isUploading: Boolean = false,
    val isSyncingPlaylists: Boolean = false,
    val downloadProgress: Float = 0f,
    val uploadProgress: Float = 0f,
    val downloadDetail: String = "Idle",
    val uploadDetail: String = "Idle",
    val playlistSyncDetail: String = "Idle",
    val availableStorageBytes: Long = 0,
    val errorMessage: String? = null,
) {
    val currentTrack: Track?
        get() = currentTrackId?.let { id -> tracks.firstOrNull { it.id == id } }

    val isConnected: Boolean
        get() = remoteSongs.isNotEmpty() || serverMessage.startsWith("Connected", ignoreCase = true)
}
