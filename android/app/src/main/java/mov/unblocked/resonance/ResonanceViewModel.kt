package mov.unblocked.resonance

import android.app.Application
import android.content.ComponentName
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import java.io.File
import java.util.UUID
import java.util.concurrent.Future
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import mov.unblocked.resonance.data.CredentialStore
import mov.unblocked.resonance.data.LibraryRepository
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.PlaylistPutResult
import mov.unblocked.resonance.data.RemotePlaylist
import mov.unblocked.resonance.data.RemotePlaylistsDocument
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.ServerClient
import mov.unblocked.resonance.data.StoredLibrary
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.playback.PlaybackService
import mov.unblocked.resonance.playback.DownloadPolicy
import mov.unblocked.resonance.ui.ResonanceActions
import mov.unblocked.resonance.ui.ResonanceUiState

class ResonanceViewModel(application: Application) : AndroidViewModel(application), ResonanceActions {
    private val context = application.applicationContext
    private val repository = LibraryRepository(context)
    private val credentials = CredentialStore(context)
    private val preferences = context.getSharedPreferences("resonance.playback", 0)
    private val mutableState = MutableStateFlow(
        ResonanceUiState(
            serverUrl = credentials.serverURL,
            serverToken = credentials.clientToken,
            serverAdminKey = credentials.adminToken,
            shuffleEnabled = preferences.getBoolean("shuffle", false),
            repeatEnabled = preferences.getBoolean("repeat", false),
            playbackSpeed = preferences.getFloat("speed", 1f),
        ),
    )
    val uiState = mutableState.asStateFlow()

    private val mutableImportRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val importRequests = mutableImportRequests.asSharedFlow()
    private val mutableUploadRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val uploadRequests = mutableUploadRequests.asSharedFlow()

    private var library = StoredLibrary(serverURL = credentials.serverURL)
    private var controllerFuture: Future<MediaController>? = null
    private var controller: MediaController? = null
    private var activeQueue: List<String> = emptyList()
    private var activePlaylistId: String? = null
    private var syncDebounce: Job? = null

    override fun dismissError() {
        mutableState.value = mutableState.value.copy(errorMessage = null)
    }

    init {
        connectController()
        viewModelScope.launch {
            library = repository.load().copy(serverURL = credentials.serverURL)
            refreshLibraryState()
            refreshStorage()
            syncPlaylistsAutomatically()
        }
        viewModelScope.launch {
            while (isActive) {
                delay(250)
                refreshPlaybackState()
            }
        }
        viewModelScope.launch {
            while (isActive) {
                delay(60_000)
                syncPlaylistsAutomatically()
            }
        }
    }

    private fun connectController() {
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        controllerFuture = future
        future.addListener({
            runCatching { future.get() }.onSuccess { mediaController ->
                controller = mediaController
                mediaController.repeatMode = if (mutableState.value.repeatEnabled) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_ALL
                mediaController.shuffleModeEnabled = mutableState.value.shuffleEnabled
                mediaController.setPlaybackSpeed(mutableState.value.playbackSpeed)
                mediaController.addListener(object : Player.Listener {
                    override fun onEvents(player: Player, events: Player.Events) = refreshPlaybackState()
                })
                refreshPlaybackState()
            }
        }, ContextCompat.getMainExecutor(context))
    }

    override fun onCleared() {
        controller?.release()
        controller = null
        controllerFuture?.cancel(true)
        super.onCleared()
    }

    override fun importAudio() { mutableImportRequests.tryEmit(Unit) }

    fun importUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val imported = repository.importAudio(uris)
            if (imported.isNotEmpty()) {
                library = normalizeLiked(library.copy(tracks = library.tracks + imported))
                persistLibrary()
            }
        }
    }

    override fun uploadAudio() { mutableUploadRequests.tryEmit(Unit) }

    fun uploadUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(isUploading = true, uploadProgress = 0f, uploadDetail = "Preparing uploads…")
            val temporaryFiles = uris.mapIndexedNotNull { index, uri ->
                runCatching {
                    val requestedName = displayName(uri) ?: "Upload-${index + 1}.mp3"
                    val safeName = File(requestedName).name.takeIf { it.isNotBlank() }
                        ?: "Upload-${index + 1}.mp3"
                    val uploadDirectory = File(context.cacheDir, "resonance-upload-${UUID.randomUUID()}")
                        .apply { mkdirs() }
                    File(uploadDirectory, safeName).also { file ->
                        context.contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use(input::copyTo) }
                    }
                }.getOrNull()
            }
            runCatching {
                serverClient().upload(temporaryFiles) { progress ->
                    mutableState.value = mutableState.value.copy(
                        uploadProgress = progress.fraction,
                        uploadDetail = "Uploading ${progress.completed.coerceAtMost(progress.total)} of ${progress.total} • ${progress.currentFilename}",
                    )
                }
            }.onSuccess {
                mutableState.value = mutableState.value.copy(uploadDetail = "Uploaded ${it.size} song${if (it.size == 1) "" else "s"}")
                refreshServer()
            }.onFailure(::showError)
            temporaryFiles.forEach { file ->
                file.delete()
                file.parentFile?.delete()
            }
            mutableState.value = mutableState.value.copy(isUploading = false)
        }
    }

    override fun setLibrarySearch(query: String) {
        mutableState.value = mutableState.value.copy(librarySearch = query)
    }

    override fun playTrack(trackId: String, queueTrackIds: List<String>?, playlistId: String?) {
        val ids = (queueTrackIds ?: library.tracks.map(Track::id)).filter { id -> library.tracks.any { it.id == id } }
        if (trackId !in ids) return
        val player = controller ?: return
        val items = ids.mapNotNull(::mediaItem)
        val index = items.indexOfFirst { it.mediaId == trackId }
        if (index < 0) return
        activeQueue = ids
        activePlaylistId = playlistId
        player.setMediaItems(items, index, 0L)
        player.prepare()
        player.play()
        refreshPlaybackState()
    }

    override fun togglePlayPause() {
        val player = controller ?: return
        if (player.mediaItemCount == 0) {
            library.tracks.firstOrNull()?.let { playTrack(it.id) }
        } else if (player.isPlaying) player.pause() else player.play()
    }

    override fun playNext() { controller?.seekToNextMediaItem() }

    override fun playPrevious() {
        controller?.let { if (it.currentPosition > 3_000) it.seekTo(0) else it.seekToPreviousMediaItem() }
    }

    override fun seekToFraction(fraction: Float) {
        controller?.let { player ->
            val duration = player.duration.takeIf { it != C.TIME_UNSET && it > 0 } ?: return
            player.seekTo((duration * fraction.coerceIn(0f, 1f)).toLong())
        }
    }

    override fun setShuffleEnabled(enabled: Boolean) {
        controller?.shuffleModeEnabled = enabled
        mutableState.value = mutableState.value.copy(shuffleEnabled = enabled)
        preferences.edit().putBoolean("shuffle", enabled).apply()
    }

    override fun setRepeatEnabled(enabled: Boolean) {
        controller?.repeatMode = if (enabled) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_ALL
        mutableState.value = mutableState.value.copy(repeatEnabled = enabled)
        preferences.edit().putBoolean("repeat", enabled).apply()
    }

    override fun setPlaybackSpeed(speed: Float) {
        controller?.setPlaybackSpeed(speed)
        mutableState.value = mutableState.value.copy(playbackSpeed = speed)
        preferences.edit().putFloat("speed", speed).apply()
    }

    override fun toggleFavorite(trackId: String) {
        val favorites = if (trackId in library.favorites) library.favorites - trackId else library.favorites + trackId
        library = normalizeLiked(library.copy(favorites = favorites))
        saveSoon()
    }

    override fun deleteTracksFromDevice(trackIds: Set<String>) {
        viewModelScope.launch {
            if (mutableState.value.currentTrackId in trackIds) controller?.stop()
            library = repository.deleteLocalTracks(library, trackIds)
            persistLibrary()
        }
    }

    override fun createPlaylist(name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        val playlist = Playlist(name = trimmed, remoteSongIDs = emptyList())
        library = library.copy(
            playlists = library.playlists + playlist,
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() + playlist.id,
        )
        saveAndScheduleSync()
    }

    override fun deletePlaylist(playlistId: String) {
        val playlist = library.playlists.firstOrNull { it.id == playlistId && !it.isSystem } ?: return
        library = library.copy(
            playlists = library.playlists.filterNot { it.id == playlistId },
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() - playlistId,
            deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty() + playlist.id,
        )
        if (activePlaylistId == playlistId) activePlaylistId = null
        saveAndScheduleSync()
    }

    override fun playPlaylist(playlistId: String) {
        val playlist = library.playlists.firstOrNull { it.id == playlistId } ?: return
        val ids = playlist.trackIDs.filter { id -> library.tracks.any { it.id == id } }
        if (ids.isEmpty()) return
        val first = if (mutableState.value.shuffleEnabled) ids.random() else ids.first()
        playTrack(first, ids, playlistId)
    }

    override fun addTrackToPlaylist(playlistId: String, trackId: String) {
        mutatePlaylist(playlistId) { playlist ->
            if (trackId in playlist.trackIDs) playlist else playlist.copy(trackIDs = playlist.trackIDs + trackId)
        }
    }

    override fun removeTrackFromPlaylist(playlistId: String, trackId: String) {
        val playlist = library.playlists.firstOrNull { it.id == playlistId } ?: return
        if (playlist.isSystem) { toggleFavorite(trackId); return }
        mutatePlaylist(playlistId) { it.copy(trackIDs = it.trackIDs - trackId) }
    }

    override fun movePlaylistTrack(playlistId: String, fromIndex: Int, toIndex: Int) {
        mutatePlaylist(playlistId) { playlist ->
            if (fromIndex !in playlist.trackIDs.indices || toIndex !in playlist.trackIDs.indices) playlist
            else playlist.copy(trackIDs = playlist.trackIDs.toMutableList().apply { add(toIndex, removeAt(fromIndex)) })
        }
    }

    private fun mutatePlaylist(playlistId: String, transform: (Playlist) -> Playlist) {
        val index = library.playlists.indexOfFirst { it.id == playlistId && !it.isSystem }
        if (index < 0) return
        val changed = updateRemoteSongIds(transform(library.playlists[index]))
        library = library.copy(
            playlists = library.playlists.toMutableList().apply { this[index] = changed },
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() + playlistId,
            deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty() - playlistId,
        )
        if (activePlaylistId == playlistId) activeQueue = changed.trackIDs
        saveAndScheduleSync()
    }

    override fun onServerScreenOpened() {
        if (credentials.clientToken.isNotBlank()) refreshServer()
    }

    override fun refreshServer() {
        if (mutableState.value.isRefreshingServer) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(isRefreshingServer = true, serverMessage = "Connecting…")
            runCatching { serverClient().fetchCatalog() }
                .onSuccess { catalog ->
                    mutableState.value = mutableState.value.copy(
                        remoteSongs = catalog.songs,
                        serverMessage = "Connected • ${catalog.count} song${if (catalog.count == 1) "" else "s"}",
                    )
                    syncPlaylistsNow()
                }
                .onFailure { error -> mutableState.value = mutableState.value.copy(serverMessage = error.message ?: "Connection failed", errorMessage = error.message) }
            mutableState.value = mutableState.value.copy(isRefreshingServer = false)
        }
    }

    override fun saveServerConnection(url: String, accessToken: String, adminKey: String) {
        val normalized = runCatching { ServerClient.normalizeServerURL(url) }.getOrElse { showError(it); return }
        credentials.serverURL = normalized
        credentials.clientToken = accessToken
        credentials.adminToken = adminKey
        library = library.copy(serverURL = normalized)
        mutableState.value = mutableState.value.copy(serverUrl = normalized, serverToken = accessToken, serverAdminKey = adminKey)
        saveSoon()
        refreshServer()
    }

    override fun downloadRemoteSong(songId: String) { downloadSongs(setOf(songId)) }
    override fun downloadSelectedRemoteSongs() {
        val state = mutableState.value
        val ids = DownloadPolicy.songIdsToDownload(
            remoteSongIds = state.remoteSongs.map(RemoteSong::id),
            downloadedSongIds = state.downloadedRemoteSongIds,
            selectedSongIds = state.selectedRemoteSongIds,
        )
        if (ids.isEmpty()) {
            mutableState.value = state.copy(
                selectedRemoteSongIds = emptySet(),
                downloadDetail = "All server songs are already on this device",
            )
            return
        }
        downloadSongs(ids)
    }

    private fun downloadSongs(ids: Set<String>) {
        if (ids.isEmpty() || mutableState.value.isDownloading) return
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(isDownloading = true, downloadProgress = 0f)
            runCatching {
                val catalog = mov.unblocked.resonance.data.RemoteCatalog(mutableState.value.remoteSongs)
                serverClient().downloadSelected(
                    catalog,
                    ids,
                    repository,
                    library.tracks.mapNotNullTo(mutableSetOf(), Track::remoteID),
                ) { progress ->
                    mutableState.value = mutableState.value.copy(
                        downloadProgress = progress.fraction,
                        downloadDetail = "Downloading ${progress.completed.coerceAtMost(progress.total)} of ${progress.total} • ${progress.currentFilename}",
                    )
                }
            }.onSuccess { tracks ->
                library = hydrateRemotePlaylists(library.copy(tracks = library.tracks + tracks))
                persistLibrary()
                mutableState.value = mutableState.value.copy(
                    selectedRemoteSongIds = emptySet(),
                    downloadDetail = "Downloaded ${tracks.size} song${if (tracks.size == 1) "" else "s"}",
                )
                syncPlaylistsNow()
            }.onFailure(::showError)
            mutableState.value = mutableState.value.copy(isDownloading = false)
        }
    }

    override fun toggleRemoteSelection(songId: String) {
        val current = mutableState.value.selectedRemoteSongIds
        mutableState.value = mutableState.value.copy(selectedRemoteSongIds = if (songId in current) current - songId else current + songId)
    }

    override fun clearRemoteSelection() {
        mutableState.value = mutableState.value.copy(selectedRemoteSongIds = emptySet())
    }

    override fun deleteRemoteSong(songId: String) {
        viewModelScope.launch {
            runCatching { serverClient().deleteRemoteSong(songId) }
                .onSuccess {
                    mutableState.value = mutableState.value.copy(
                        remoteSongs = mutableState.value.remoteSongs.filterNot { it.id == songId },
                        selectedRemoteSongIds = mutableState.value.selectedRemoteSongIds - songId,
                    )
                }
                .onFailure(::showError)
        }
    }

    fun syncPlaylistsAutomatically() {
        if (credentials.clientToken.isBlank()) return
        viewModelScope.launch { syncPlaylistsNow() }
    }

    private suspend fun syncPlaylistsNow() {
        if (mutableState.value.isSyncingPlaylists || credentials.clientToken.isBlank()) return
        val serverKey = runCatching { ServerClient.normalizeServerURL(credentials.serverURL) }.getOrNull() ?: return
        if (library.playlistSyncServerURL != serverKey) {
            library = library.copy(
                playlistSyncServerURL = serverKey,
                playlistRevision = 0,
                knownRemotePlaylistIDs = emptySet(),
                deletedPlaylistIDs = emptySet(),
                dirtyPlaylistIDs = library.playlists.filterNot(Playlist::isSystem).mapTo(mutableSetOf(), Playlist::id),
            )
        }
        mutableState.value = mutableState.value.copy(isSyncingPlaylists = true, playlistSyncDetail = "Syncing playlists…")
        runCatching {
            var remote = serverClient().fetchPlaylists()
            repeat(2) {
                val merge = mergePlaylists(remote)
                if (!merge.second) { applyRemotePlaylists(remote); return@runCatching remote }
                when (val result = serverClient().putPlaylists(merge.first)) {
                    is PlaylistPutResult.Updated -> {
                        library = library.copy(dirtyPlaylistIDs = emptySet(), deletedPlaylistIDs = emptySet())
                        applyRemotePlaylists(result.document)
                        return@runCatching result.document
                    }
                    is PlaylistPutResult.Conflict -> remote = result.document
                }
            }
            error("Playlist sync conflicted; try again")
        }.onSuccess { document ->
            mutableState.value = mutableState.value.copy(playlistSyncDetail = "Synced ${document.playlists.size} playlist${if (document.playlists.size == 1) "" else "s"}")
        }.onFailure { mutableState.value = mutableState.value.copy(playlistSyncDetail = "Playlist sync failed: ${it.message}") }
        mutableState.value = mutableState.value.copy(isSyncingPlaylists = false)
    }

    private fun mergePlaylists(remote: RemotePlaylistsDocument): Pair<RemotePlaylistsDocument, Boolean> {
        val deleted = library.deletedPlaylistIDs.orEmpty()
        val known = library.knownRemotePlaylistIDs.orEmpty()
        val dirty = library.dirtyPlaylistIDs.orEmpty()
        val merged = remote.playlists.filterNot { it.id in deleted }.toMutableList()
        val remoteIds = remote.playlists.mapTo(mutableSetOf(), RemotePlaylist::id)
        var needsUpload = deleted.isNotEmpty()
        library.playlists.filterNot(Playlist::isSystem).forEach { playlist ->
            val unsynced = playlist.id !in remoteIds && playlist.id !in known
            if (playlist.id !in dirty && !unsynced) return@forEach
            val payload = remotePlaylist(playlist)
            val index = merged.indexOfFirst { it.id == playlist.id }
            if (index >= 0) merged[index] = payload else merged += payload
            needsUpload = true
        }
        return RemotePlaylistsDocument(remote.revision, merged) to needsUpload
    }

    private fun remotePlaylist(playlist: Playlist): RemotePlaylist {
        val songIds = playlist.trackIDs.mapNotNull { id -> library.tracks.firstOrNull { it.id == id }?.remoteID }.distinct().toMutableList()
        playlist.remoteSongIDs.orEmpty().filterNot(songIds::contains).forEach(songIds::add)
        return RemotePlaylist(playlist.id.lowercase(), playlist.name, songIds)
    }

    private suspend fun applyRemotePlaylists(document: RemotePlaylistsDocument) {
        val existing = library.playlists.filterNot(Playlist::isSystem).associateBy(Playlist::id)
        val system = library.playlists.filter(Playlist::isSystem)
        val custom = document.playlists.map { remote ->
            val localOnly = existing[remote.id]?.trackIDs.orEmpty().filter { id -> library.tracks.firstOrNull { it.id == id }?.remoteID == null }
            val downloaded = remote.songIDs.mapNotNull { remoteId -> library.tracks.firstOrNull { it.remoteID == remoteId }?.id }
            Playlist(remote.id, remote.name, (downloaded + localOnly).distinct(), false, remote.songIDs)
        }
        library = normalizeLiked(library.copy(
            playlists = system + custom,
            playlistRevision = document.revision,
            knownRemotePlaylistIDs = document.playlists.mapTo(mutableSetOf(), RemotePlaylist::id),
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() - document.playlists.map(RemotePlaylist::id).toSet(),
        ))
        persistLibrary()
    }

    private fun hydrateRemotePlaylists(value: StoredLibrary): StoredLibrary = value.copy(
        playlists = value.playlists.map { playlist ->
            if (playlist.isSystem || playlist.remoteSongIDs == null) playlist else {
                val localOnly = playlist.trackIDs.filter { id -> value.tracks.firstOrNull { it.id == id }?.remoteID == null }
                val downloaded = playlist.remoteSongIDs.mapNotNull { remoteId -> value.tracks.firstOrNull { it.remoteID == remoteId }?.id }
                playlist.copy(trackIDs = (downloaded + localOnly).distinct())
            }
        },
    )

    private fun updateRemoteSongIds(playlist: Playlist): Playlist {
        val unresolved = playlist.remoteSongIDs.orEmpty().filter { remoteId -> library.tracks.none { it.remoteID == remoteId } }
        val ordered = playlist.trackIDs.mapNotNull { id -> library.tracks.firstOrNull { it.id == id }?.remoteID }.distinct()
        return playlist.copy(remoteSongIDs = (ordered + unresolved).distinct())
    }

    private fun normalizeLiked(value: StoredLibrary): StoredLibrary {
        val playlists = value.playlists.toMutableList()
        val index = playlists.indexOfFirst(Playlist::isSystem)
        val liked = Playlist(
            id = playlists.getOrNull(index)?.id ?: UUID.randomUUID().toString(),
            name = "Liked Songs",
            trackIDs = value.tracks.map(Track::id).filter(value.favorites::contains),
            isSystem = true,
        )
        if (index >= 0) playlists[index] = liked else playlists.add(0, liked)
        return value.copy(playlists = playlists)
    }

    private fun saveAndScheduleSync() {
        saveSoon()
        syncDebounce?.cancel()
        syncDebounce = viewModelScope.launch { delay(500); syncPlaylistsNow() }
    }

    private fun saveSoon() { viewModelScope.launch { persistLibrary() } }

    private suspend fun persistLibrary() {
        repository.save(library)
        refreshLibraryState()
        refreshStorage()
    }

    private fun refreshLibraryState() {
        val trackSizes = library.tracks.associate { it.id to repository.fileForTrack(it).length() }
        val artwork = library.tracks.mapNotNull { track -> repository.artworkFile(track)?.takeIf(File::isFile)?.absolutePath?.let { track.id to it } }.toMap()
        mutableState.value = mutableState.value.copy(
            tracks = library.tracks,
            playlists = library.playlists,
            favoriteTrackIds = library.favorites,
            trackSizesById = trackSizes,
            artworkPathsByTrackId = artwork,
            downloadedRemoteSongIds = library.tracks.mapNotNullTo(mutableSetOf(), Track::remoteID),
            serverUrl = credentials.serverURL,
            serverToken = credentials.clientToken,
            serverAdminKey = credentials.adminToken,
        )
    }

    private suspend fun refreshStorage() {
        val stats = repository.storageStats(library)
        mutableState.value = mutableState.value.copy(availableStorageBytes = stats.availableBytes)
    }

    private fun refreshPlaybackState() {
        val player = controller ?: return
        val currentId = player.currentMediaItem?.mediaId?.takeIf(String::isNotBlank)
        mutableState.value = mutableState.value.copy(
            currentTrackId = currentId,
            activePlaylistId = activePlaylistId,
            isPlaying = player.isPlaying,
            positionMs = player.currentPosition.coerceAtLeast(0L),
            playbackSpeed = player.playbackParameters.speed,
        )
    }

    private fun mediaItem(id: String): MediaItem? {
        val track = library.tracks.firstOrNull { it.id == id } ?: return null
        val artworkUri = repository.artworkFile(track)?.takeIf(File::isFile)?.let(Uri::fromFile)
        val metadata = MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setAlbumTitle(track.album)
            .setArtworkUri(artworkUri)
            .build()
        return MediaItem.Builder()
            .setMediaId(track.id)
            .setUri(Uri.fromFile(repository.fileForTrack(track)))
            .setMediaMetadata(metadata)
            .build()
    }

    private fun serverClient() = ServerClient(credentials.serverURL, credentials.clientToken, credentials.adminToken)

    private fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    private fun showError(error: Throwable) {
        mutableState.value = mutableState.value.copy(errorMessage = error.message ?: "Something went wrong")
    }
}
