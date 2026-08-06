package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.SyncProfile
import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.LinkImportResolution
import mov.unblocked.resonance.data.LinkImportSearchResponse
import mov.unblocked.resonance.data.LinkImportStage

data class LinkImportUiState(
    val stage: LinkImportStage = LinkImportStage.Idle,
    val resolution: LinkImportResolution? = null,
    val searchResponse: LinkImportSearchResponse? = null,
    val selectedSearchResultId: String? = null,
    val selectedVideoId: String? = null,
    val selectedVideoIds: Set<String> = emptySet(),
    val completedBytes: Long = 0L,
    val totalBytes: Long = 0L,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val completedTrackTitle: String? = null,
    val batchCurrentTitle: String? = null,
    val completedSummary: String? = null,
    val previewingVideoId: String? = null,
    val previewLoadingVideoId: String? = null,
    val previewError: String? = null,
) {
    val isRunning: Boolean
        get() = stage in setOf(
            LinkImportStage.ResolvingMetadata,
            LinkImportStage.SearchingCandidates,
            LinkImportStage.InspectingSource,
            LinkImportStage.Downloading,
            LinkImportStage.SavingLocal,
            LinkImportStage.Syncing,
        )
}

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
    val trackFilePathsById: Map<String, String> = emptyMap(),
    val trackSizesById: Map<String, Long> = emptyMap(),
    val clipRangesByTrackId: Map<String, ClipRange> = emptyMap(),
    val playlists: List<Playlist> = emptyList(),
    val favoriteTrackIds: Set<String> = emptySet(),
    val currentTrackId: String? = null,
    val activePlaylistId: String? = null,
    val isPlaying: Boolean = false,
    val positionMs: Long = 0,
    val shuffleEnabled: Boolean = false,
    val repeatEnabled: Boolean = false,
    val playbackSpeed: Float = 1f,
    val volume: Float = .8f,
    val librarySearch: String = "",
    val serverUrl: String = "https://music.unblocked.mov",
    val serverToken: String = "",
    val serverAdminKey: String = "",
    val serverMessage: String = "Not connected",
    val remoteSongs: List<RemoteSong> = emptyList(),
    val downloadedRemoteSongIds: Set<String> = emptySet(),
    val selectedRemoteSongIds: Set<String> = emptySet(),
    val isRefreshingServer: Boolean = false,
    val isApplyingServerConnection: Boolean = false,
    val isDownloading: Boolean = false,
    val isUploading: Boolean = false,
    val isSyncingPlaylists: Boolean = false,
    val downloadProgress: Float = 0f,
    val uploadProgress: Float = 0f,
    val downloadDetail: String = "Idle",
    val uploadDetail: String = "Idle",
    val playlistSyncDetail: String = "Idle",
    val syncProfileId: String = "default",
    val syncProfiles: List<SyncProfile> = listOf(SyncProfile("default", "Default", true)),
    val availableStorageBytes: Long = 0,
    val errorMessage: String? = null,
    val linkImport: LinkImportUiState = LinkImportUiState(),
) {
    val currentTrack: Track?
        get() = currentTrackId?.let { id -> tracks.firstOrNull { it.id == id } }

    val isConnected: Boolean
        get() = remoteSongs.isNotEmpty() || serverMessage.startsWith("Connected", ignoreCase = true)

    val currentClipRange: ClipRange?
        get() = currentTrackId?.let(clipRangesByTrackId::get)

    val playbackStartMs: Long
        get() = currentClipRange?.startMs ?: 0L

    val playbackEndMs: Long
        get() = currentClipRange?.endMs ?: currentTrack?.durationMs ?: 0L

    val playbackDurationMs: Long
        get() = (playbackEndMs - playbackStartMs).coerceAtLeast(1L)

    val playbackElapsedMs: Long
        get() = (positionMs - playbackStartMs).coerceIn(0L, playbackDurationMs)
}
