package mov.unblocked.resonance.ui

import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.SyncProfile
import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.LinkImportResolution
import mov.unblocked.resonance.data.LinkImportSearchResponse
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.EffectiveClientConfig
import mov.unblocked.resonance.data.ServerDownloadMode
import mov.unblocked.resonance.data.ServerUploadMode

data class LinkImportUiState(
    val requestedSource: String? = null,
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

sealed interface PlaybackUiStatus {
    data object Idle : PlaybackUiStatus
    data object Ready : PlaybackUiStatus
    data object Buffering : PlaybackUiStatus
    data object Ended : PlaybackUiStatus
    data class Failed(val message: String, val retryable: Boolean) : PlaybackUiStatus
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
    /** Render-only metadata for an authenticated stream; never part of the stored library. */
    val transientCurrentTrack: Track? = null,
    /** Same-origin catalog artwork for the transient stream; never persisted as a library path. */
    val transientArtworkURL: String? = null,
    val activePlaylistId: String? = null,
    val isPlaying: Boolean = false,
    val playbackStatus: PlaybackUiStatus = PlaybackUiStatus.Idle,
    val positionMs: Long = 0,
    val playerDurationMs: Long? = null,
    val shuffleEnabled: Boolean = false,
    val repeatEnabled: Boolean = false,
    val playbackSpeed: Float = 1f,
    val volume: Float = .8f,
    val librarySearch: String = "",
    val serverUrl: String = "https://resonance-core.blithe-haven-9710.chatgpt.site",
    val serverToken: String = "",
    val serverAdminKey: String = "",
    val accountEmail: String? = null,
    val accountRole: String? = null,
    val accountDisplayName: String? = null,
    val accountImageURL: String? = null,
    val isSigningIn: Boolean = false,
    val isNativeAccountSignInOpen: Boolean = false,
    val serverMessage: String = "Not connected",
    val clientConfig: EffectiveClientConfig = EffectiveClientConfig.safeDefaults(),
    val clientConfigStatus: String = "Safe defaults",
    val serverUploadMode: ServerUploadMode? = ServerUploadMode.LocalFile,
    val serverDownloadMode: ServerDownloadMode = ServerDownloadMode.VerifiedFileCache,
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
    val profilePicturePath: String? = null,
    val availableStorageBytes: Long = 0,
    val errorMessage: String? = null,
    val linkImport: LinkImportUiState = LinkImportUiState(),
) {
    val currentTrack: Track?
        get() = currentTrackId?.let { id ->
            tracks.firstOrNull { it.id == id } ?: transientCurrentTrack?.takeIf { it.id == id }
        }

    val isTransientPlayback: Boolean
        get() = currentTrackId != null && transientCurrentTrack?.id == currentTrackId

    val isConnected: Boolean
        get() = remoteSongs.isNotEmpty() || serverMessage.startsWith("Connected", ignoreCase = true)

    val hasServerUploadCredentials: Boolean
        get() = serverUrl.isNotBlank() && serverAdminKey.isNotBlank()

    val availableServerUploadModes: List<ServerUploadMode>
        get() = clientConfig.availableUploadModes

    val availableServerDownloadModes: List<ServerDownloadMode>
        get() = clientConfig.availableDownloadModes

    val currentClipRange: ClipRange?
        get() = currentTrackId?.let(clipRangesByTrackId::get)

    val playbackStartMs: Long
        get() = currentClipRange?.startMs ?: 0L

    val playbackEndMs: Long?
        get() = currentClipRange?.let { range ->
            range.endMs.takeIf { it > range.startMs }
        } ?: playerDurationMs?.takeIf { it > 0L }
            ?: currentTrack?.durationMs?.takeIf { it > 0L }

    val playbackDurationMs: Long?
        get() = playbackEndMs?.let { end -> (end - playbackStartMs).takeIf { it > 0L } }

    val canSeekPlayback: Boolean
        get() = playbackDurationMs != null

    val playbackElapsedMs: Long
        get() {
            val elapsed = (positionMs - playbackStartMs).coerceAtLeast(0L)
            return playbackDurationMs?.let { elapsed.coerceAtMost(it) } ?: elapsed
        }

    val playbackProgressFraction: Float?
        get() = playbackDurationMs?.let { duration ->
            (playbackElapsedMs.toFloat() / duration).coerceIn(0f, 1f)
    }
}

internal fun LinkImportUiState.invalidatedForSourceEdit(source: String): LinkImportUiState {
    val resolvedSource = requestedSource ?: return this
    if (source.trim() == resolvedSource.trim()) return this
    return LinkImportUiState()
}
