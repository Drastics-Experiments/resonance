package mov.unblocked.resonance

import android.app.Application
import android.content.ComponentName
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Bundle
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
import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.LinkImportException
import mov.unblocked.resonance.data.LinkImportProgress
import mov.unblocked.resonance.data.LinkImportService
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.LinkImportTrack
import mov.unblocked.resonance.data.LibraryRepository
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.PlaylistPutResult
import mov.unblocked.resonance.data.RemotePlaylist
import mov.unblocked.resonance.data.RemoteClipRange
import mov.unblocked.resonance.data.RemotePlaylistsDocument
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.ServerClient
import mov.unblocked.resonance.data.StoredLibrary
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.playback.PlaybackService
import mov.unblocked.resonance.playback.DownloadPolicy
import mov.unblocked.resonance.ui.ResonanceActions
import mov.unblocked.resonance.ui.ResonanceUiState
import mov.unblocked.resonance.ui.LinkImportUiState

class ResonanceViewModel(application: Application) : AndroidViewModel(application), ResonanceActions {
    private val context = application.applicationContext
    private val repository = LibraryRepository(context)
    private val linkImportService = LinkImportService(context)
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
            volume = preferences.getFloat("volume", .8f).coerceIn(0f, 1f),
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
    private var likesMutationGeneration = 0L
    private var clipRangeMutationGeneration = 0L
    private var linkImportJob: Job? = null

    override fun dismissError() {
        mutableState.value = mutableState.value.copy(errorMessage = null)
    }

    init {
        connectController()
        viewModelScope.launch {
            library = migrateRemoteLikes(repository.load().copy(serverURL = credentials.serverURL))
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
                mediaController.repeatMode = repeatModeFor(mutableState.value.repeatEnabled)
                mediaController.shuffleModeEnabled = mutableState.value.shuffleEnabled
                mediaController.setPlaybackSpeed(mutableState.value.playbackSpeed)
                mediaController.volume = mutableState.value.volume
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

    override fun resolveLinkImport(source: String) {
        val value = source.trim()
        if (value.isEmpty()) {
            mutableState.value = mutableState.value.copy(
                linkImport = LinkImportUiState(
                    stage = LinkImportStage.Failed,
                    errorCode = "MISSING_SOURCE",
                    errorMessage = "Paste a Spotify track or YouTube video URL first.",
                ),
            )
            return
        }
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = LinkImportUiState(stage = LinkImportStage.ResolvingMetadata),
        )
        linkImportJob = viewModelScope.launch {
            runCatching {
                linkImportService.resolve(value, ::applyLinkImportProgress)
            }.onSuccess { resolution ->
                mutableState.value = mutableState.value.copy(
                    linkImport = mutableState.value.linkImport.copy(
                        stage = LinkImportStage.AwaitingSelection,
                        resolution = resolution,
                        selectedVideoId = resolution.candidates.firstOrNull()?.videoID,
                        errorCode = null,
                        errorMessage = null,
                    ),
                )
            }.onFailure(::applyLinkImportFailure)
        }
    }

    override fun selectLinkImportCandidate(videoId: String) {
        val current = mutableState.value.linkImport
        if (current.resolution?.candidates?.any { it.videoID == videoId } != true) return
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(selectedVideoId = videoId),
        )
    }

    override fun confirmLinkImport() {
        val current = mutableState.value.linkImport
        val resolution = current.resolution ?: return
        val candidate = resolution.candidates.firstOrNull { it.videoID == current.selectedVideoId } ?: return
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.InspectingSource,
                completedBytes = 0,
                totalBytes = 0,
                errorCode = null,
                errorMessage = null,
            ),
        )
        linkImportJob = viewModelScope.launch {
            runCatching {
                val metadata = LinkImportTrack(
                    title = resolution.track.title,
                    artist = resolution.track.artist,
                    album = resolution.track.album,
                    durationSeconds = resolution.track.durationSeconds,
                    artworkURL = resolution.track.artworkURL ?: candidate.thumbnailURL,
                    sourceURL = resolution.track.sourceURL,
                )
                val download = linkImportService.download(candidate, metadata, ::applyLinkImportProgress)
                val duplicate = library.tracks.firstOrNull {
                    it.sourceSHA256 == download.sourceSHA256
                        || it.contentSHA256 == download.sourceSHA256
                        || it.contentSHA256 == download.contentSHA256
                }
                if (duplicate != null) {
                    download.file.parentFile?.deleteRecursively()
                    duplicate
                } else {
                    applyLinkImportProgress(LinkImportProgress(LinkImportStage.SavingLocal))
                    repository.registerLocalImport(download)
                }
            }.onSuccess { track ->
                if (library.tracks.none { it.id == track.id }) {
                    library = normalizeLiked(library.copy(tracks = library.tracks + track))
                    persistLibrary()
                }
                mutableState.value = mutableState.value.copy(
                    linkImport = mutableState.value.linkImport.copy(
                        stage = LinkImportStage.Complete,
                        completedTrackTitle = track.title,
                    ),
                )
            }.onFailure(::applyLinkImportFailure)
        }
    }

    override fun cancelLinkImport() {
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.value = mutableState.value.copy(
            linkImport = LinkImportUiState(stage = LinkImportStage.Cancelled),
        )
    }

    private fun applyLinkImportProgress(progress: LinkImportProgress) {
        mutableState.value = mutableState.value.copy(
            linkImport = mutableState.value.linkImport.copy(
                stage = progress.stage,
                completedBytes = progress.completedBytes,
                totalBytes = progress.totalBytes,
            ),
        )
    }

    private fun applyLinkImportFailure(error: Throwable) {
        if (error is kotlinx.coroutines.CancellationException) return
        val failure = error as? LinkImportException
        mutableState.value = mutableState.value.copy(
            linkImport = mutableState.value.linkImport.copy(
                stage = LinkImportStage.Failed,
                errorCode = failure?.code ?: "LOCAL_IMPORT_FAILED",
                errorMessage = error.message ?: "The link import failed.",
            ),
        )
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
        val start = playbackRange(library.tracks.first { it.id == trackId }).startMs
        player.setMediaItems(items, index, start)
        player.prepare()
        player.play()
        refreshPlaybackState()
    }

    override fun togglePlayPause() {
        val player = controller ?: return
        if (player.mediaItemCount == 0) {
            library.tracks.firstOrNull()?.let { playTrack(it.id) }
        } else if (player.isPlaying) {
            player.pause()
        } else {
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } }
            if (track != null) {
                val range = playbackRange(track)
                if (player.currentPosition !in range.startMs until range.endMs) player.seekTo(range.startMs)
            }
            player.play()
        }
    }

    override fun playNext() { controller?.seekToNextMediaItem() }

    override fun playPrevious() {
        controller?.let { player ->
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } }
            val start = track?.let(::playbackRange)?.startMs ?: 0L
            if (player.currentPosition > start + 3_000) player.seekTo(start) else player.seekToPreviousMediaItem()
        }
    }

    override fun seekToFraction(fraction: Float) {
        controller?.let { player ->
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } } ?: return
            val range = playbackRange(track)
            player.seekTo(range.startMs + (range.durationMs * fraction.coerceIn(0f, 1f)).toLong())
        }
    }

    override fun setShuffleEnabled(enabled: Boolean) {
        controller?.shuffleModeEnabled = enabled
        mutableState.value = mutableState.value.copy(shuffleEnabled = enabled)
        preferences.edit().putBoolean("shuffle", enabled).apply()
    }

    override fun setRepeatEnabled(enabled: Boolean) {
        controller?.repeatMode = repeatModeFor(enabled)
        mutableState.value = mutableState.value.copy(repeatEnabled = enabled)
        preferences.edit().putBoolean("repeat", enabled).apply()
    }

    override fun setPlaybackSpeed(speed: Float) {
        controller?.setPlaybackSpeed(speed)
        mutableState.value = mutableState.value.copy(playbackSpeed = speed)
        preferences.edit().putFloat("speed", speed).apply()
    }

    override fun setVolume(volume: Float) {
        val clamped = volume.coerceIn(0f, 1f)
        controller?.volume = clamped
        mutableState.value = mutableState.value.copy(volume = clamped)
        preferences.edit().putFloat("volume", clamped).apply()
    }

    override fun toggleFavorite(trackId: String) {
        val favorites = if (trackId in library.favorites) library.favorites - trackId else library.favorites + trackId
        val remoteID = library.tracks.firstOrNull { it.id == trackId }?.remoteID
        val remoteLikedSongIDs = library.remoteLikedSongIDs.orEmpty().toMutableSet()
        val dirtyRemoteLikeSongIDs = library.dirtyRemoteLikeSongIDs.orEmpty().toMutableSet()
        if (remoteID != null) {
            likesMutationGeneration += 1
            if (trackId in favorites) remoteLikedSongIDs += remoteID else remoteLikedSongIDs -= remoteID
            dirtyRemoteLikeSongIDs += remoteID
        }
        library = normalizeLiked(library.copy(
            favorites = favorites,
            remoteLikedSongIDs = remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs = dirtyRemoteLikeSongIDs,
            likesDirty = dirtyRemoteLikeSongIDs.isNotEmpty(),
        ))
        saveAndScheduleSync()
    }

    override fun deleteTracksFromDevice(trackIds: Set<String>) {
        viewModelScope.launch {
            if (mutableState.value.currentTrackId in trackIds) controller?.stop()
            val suffixes = library.tracks.filter { it.id in trackIds }.flatMap { track ->
                listOf("|local:" + track.id) + listOfNotNull(track.remoteID?.let { "|remote:" + it })
            }
            library = repository.deleteLocalTracks(library, trackIds)
            library = library.copy(
                clipRanges = library.clipRanges.filterKeys { key -> suffixes.none(key::endsWith) },
                dirtyClipRangeKeys = library.dirtyClipRangeKeys.filterTo(mutableSetOf()) { key -> suffixes.none(key::endsWith) },
                deletedClipRangeKeys = library.deletedClipRangeKeys.filterTo(mutableSetOf()) { key -> suffixes.none(key::endsWith) },
            )
            persistLibrary()
        }
    }

    override fun saveClipRange(trackId: String, startMs: Long, endMs: Long) {
        val track = library.tracks.firstOrNull { it.id == trackId } ?: return
        val start = startMs.coerceIn(0L, track.durationMs)
        val end = endMs.coerceIn(0L, track.durationMs)
        if (end - start < 250L) return
        val key = clipRangeKey(track)
        val ranges = library.clipRanges + (key to ClipRange(start, end))
        val dirty = library.dirtyClipRangeKeys.toMutableSet()
        val deleted = library.deletedClipRangeKeys.toMutableSet()
        if (track.remoteID != null) {
            dirty += key
            deleted -= key
        }
        clipRangeMutationGeneration += 1
        library = library.copy(clipRanges = ranges, dirtyClipRangeKeys = dirty, deletedClipRangeKeys = deleted)
        refreshQueuedClipMetadata()
        saveAndScheduleSync()
    }

    override fun clearClipRange(trackId: String) {
        val track = library.tracks.firstOrNull { it.id == trackId } ?: return
        val key = clipRangeKey(track)
        if (key !in library.clipRanges) return
        val dirty = library.dirtyClipRangeKeys.toMutableSet()
        val deleted = library.deletedClipRangeKeys.toMutableSet()
        if (track.remoteID != null) {
            dirty += key
            deleted += key
        }
        clipRangeMutationGeneration += 1
        library = library.copy(
            clipRanges = library.clipRanges - key,
            dirtyClipRangeKeys = dirty,
            deletedClipRangeKeys = deleted,
        )
        refreshQueuedClipMetadata()
        saveAndScheduleSync()
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
        viewModelScope.launch { refreshServerNow() }
    }

    private suspend fun refreshServerNow() {
        mutableState.value = mutableState.value.copy(isRefreshingServer = true, serverMessage = "Connecting…")
        runCatching {
            val client = serverClient()
            val profiles = client.fetchProfiles()
            val catalog = client.fetchCatalog()
            Triple(client, catalog, profiles)
        }
            .onSuccess { (client, catalog, profiles) ->
                library = library.copy(syncProfiles = profiles.profiles)
                mutableState.value = mutableState.value.copy(
                    remoteSongs = catalog.songs,
                    syncProfiles = profiles.profiles,
                    serverMessage = "Connected • ${catalog.count} song${if (catalog.count == 1) "" else "s"}",
                )
                if (backfillDownloadedArtwork(client, catalog.songs)) {
                    persistLibrary()
                } else {
                    saveSoon()
                }
                syncPlaylistsNow()
            }
            .onFailure { error ->
                mutableState.value = mutableState.value.copy(
                    serverMessage = error.message ?: "Connection failed",
                    errorMessage = error.message.takeUnless { mutableState.value.isApplyingServerConnection },
                )
            }
        mutableState.value = mutableState.value.copy(isRefreshingServer = false)
    }

    private suspend fun backfillDownloadedArtwork(
        client: ServerClient,
        songs: List<RemoteSong>,
    ): Boolean {
        val songsByID = songs.associateBy(RemoteSong::id)
        val updatedTracks = ArrayList<Track>(library.tracks.size)
        var changed = false

        for (track in library.tracks) {
            val existingArtwork = repository.artworkFile(track)?.takeIf(File::isFile)
            val song = track.remoteID?.let(songsByID::get)
            if ((track.syncProfileID ?: "default") != library.syncProfileID
                || existingArtwork?.length()?.let { it > 0L } == true
                || song?.artworkURL.isNullOrBlank()
            ) {
                updatedTracks += track
                continue
            }

            val repaired = runCatching {
                client.fetchArtwork(song)?.let { repository.persistArtwork(track, it) }
            }.getOrNull() ?: track
            updatedTracks += repaired
            changed = changed || repaired != track
        }

        if (changed) library = library.copy(tracks = updatedTracks)
        return changed
    }

    override fun saveServerConnection(url: String, accessToken: String, adminKey: String, profileName: String) {
        val normalized = runCatching { ServerClient.normalizeServerURL(url) }.getOrElse { showError(it); return }
        val normalizedProfileName = normalizeProfileName(profileName)
        if (normalizedProfileName.isEmpty()) {
            mutableState.value = mutableState.value.copy(serverMessage = "Enter a profile name.")
            return
        }
        if (accessToken.isBlank()) {
            mutableState.value = mutableState.value.copy(serverMessage = "Enter the access token.")
            return
        }
        credentials.serverURL = normalized
        credentials.clientToken = accessToken
        credentials.adminToken = adminKey
        library = library.copy(serverURL = normalized)
        mutableState.value = mutableState.value.copy(
            serverUrl = normalized,
            serverToken = accessToken,
            serverAdminKey = adminKey,
            remoteSongs = emptyList(),
            selectedRemoteSongIds = emptySet(),
            isApplyingServerConnection = true,
            serverMessage = "Connecting…",
            errorMessage = null,
        )
        viewModelScope.launch {
            runCatching {
                val client = ServerClient(normalized, accessToken, adminKey, library.syncProfileID)
                val response = client.fetchProfiles()
                val profile = response.profiles.firstOrNull {
                    it.id == normalizedProfileName || it.name.equals(normalizedProfileName, ignoreCase = true)
                } ?: client.createProfile(normalizedProfileName)
                val profiles = (response.profiles + profile).distinctBy { it.id }
                library = library.copy(syncProfiles = profiles)
                activateProfile(profile.id)
                persistLibrary()
            }
                .onSuccess {
                    refreshServerNow()
                }
                .onFailure { error ->
                    mutableState.value = mutableState.value.copy(
                        serverMessage = "Could not activate profile: ${error.message ?: "Unknown error"}",
                    )
                }
            mutableState.value = mutableState.value.copy(isApplyingServerConnection = false)
        }
    }

    private fun activateProfile(profileId: String) {
        if (profileId.isBlank() || profileId == library.syncProfileID) return
        val currentTrack = mutableState.value.currentTrackId?.let { id ->
            library.tracks.firstOrNull { it.id == id }
        }
        if (currentTrack?.remoteID != null && (currentTrack.syncProfileID ?: "default") != profileId) {
            controller?.stop()
            controller?.clearMediaItems()
            activeQueue = emptyList()
            activePlaylistId = null
        }
        val system = library.playlists.filter(Playlist::isSystem)
        val localFavorites = library.favorites.filterTo(mutableSetOf()) { id ->
            library.tracks.firstOrNull { it.id == id }?.remoteID == null
        }
        library = normalizeLiked(library.copy(
            playlists = system,
            favorites = localFavorites,
            playlistRevision = 0,
            knownRemotePlaylistIDs = emptySet(),
            dirtyPlaylistIDs = emptySet(),
            deletedPlaylistIDs = emptySet(),
            playlistSyncServerURL = null,
            syncProfileID = profileId,
            remoteLikedSongIDs = emptySet(),
            dirtyRemoteLikeSongIDs = emptySet(),
            likesDirty = false,
        ))
        likesMutationGeneration += 1
        mutableState.value = mutableState.value.copy(
            syncProfileId = profileId,
            remoteSongs = emptyList(),
            selectedRemoteSongIds = emptySet(),
        )
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
                    library.tracks
                        .filter { it.remoteID == null || (it.syncProfileID ?: "default") == library.syncProfileID }
                        .mapNotNullTo(mutableSetOf(), Track::remoteID),
                ) { progress ->
                    mutableState.value = mutableState.value.copy(
                        downloadProgress = progress.fraction,
                        downloadDetail = "Downloading ${progress.completed.coerceAtMost(progress.total)} of ${progress.total} • ${progress.currentFilename}",
                    )
                }
            }.onSuccess { tracks ->
                library = hydrateRemoteLikes(hydrateRemotePlaylists(library.copy(tracks = library.tracks + tracks)))
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
        val normalizedServer = runCatching { ServerClient.normalizeServerURL(credentials.serverURL) }.getOrNull() ?: return
        val serverKey = "$normalizedServer#profile=${library.syncProfileID}"
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
                val submittedLikesGeneration = likesMutationGeneration
                val submittedDirtyLikeIDs = library.dirtyRemoteLikeSongIDs.orEmpty()
                val submittedClipGeneration = clipRangeMutationGeneration
                val submittedDirtyClipKeys = library.dirtyClipRangeKeys.filterTo(mutableSetOf(), ::activeClipKey)
                when (val result = serverClient().putPlaylists(merge.first)) {
                    is PlaylistPutResult.Updated -> {
                        val remainingDirtyLikeIDs = if (likesMutationGeneration == submittedLikesGeneration) {
                            library.dirtyRemoteLikeSongIDs.orEmpty() - submittedDirtyLikeIDs
                        } else {
                            library.dirtyRemoteLikeSongIDs.orEmpty()
                        }
                        val remainingDirtyClipKeys = if (clipRangeMutationGeneration == submittedClipGeneration) {
                            library.dirtyClipRangeKeys - submittedDirtyClipKeys
                        } else {
                            library.dirtyClipRangeKeys
                        }
                        library = library.copy(
                            dirtyPlaylistIDs = emptySet(),
                            deletedPlaylistIDs = emptySet(),
                            dirtyRemoteLikeSongIDs = remainingDirtyLikeIDs,
                            likesDirty = remainingDirtyLikeIDs.isNotEmpty(),
                            dirtyClipRangeKeys = remainingDirtyClipKeys,
                            deletedClipRangeKeys = if (clipRangeMutationGeneration == submittedClipGeneration) {
                                library.deletedClipRangeKeys - submittedDirtyClipKeys
                            } else {
                                library.deletedClipRangeKeys
                            },
                        )
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
        if (library.likesDirty || library.dirtyClipRangeKeys.any(::activeClipKey)) {
            syncDebounce?.cancel()
            syncDebounce = viewModelScope.launch { delay(100); syncPlaylistsNow() }
        }
    }

    private fun mergePlaylists(remote: RemotePlaylistsDocument): Pair<RemotePlaylistsDocument, Boolean> {
        val deleted = library.deletedPlaylistIDs.orEmpty()
        val known = library.knownRemotePlaylistIDs.orEmpty()
        val dirty = library.dirtyPlaylistIDs.orEmpty()
        val merged = remote.playlists.filterNot { it.id in deleted }.toMutableList()
        val remoteIds = remote.playlists.mapTo(mutableSetOf(), RemotePlaylist::id)
        var needsUpload = deleted.isNotEmpty() || library.likesDirty
        library.playlists.filterNot(Playlist::isSystem).forEach { playlist ->
            val unsynced = playlist.id !in remoteIds && playlist.id !in known
            if (playlist.id !in dirty && !unsynced) return@forEach
            val payload = remotePlaylist(playlist)
            val index = merged.indexOfFirst { it.id == playlist.id }
            if (index >= 0) merged[index] = payload else merged += payload
            needsUpload = true
        }
        val likedSongIds = remote.likedSongIDs.toMutableSet()
        val intendedLikedSongIDs = library.remoteLikedSongIDs.orEmpty()
        library.dirtyRemoteLikeSongIDs.orEmpty().forEach { remoteID ->
            if (remoteID in intendedLikedSongIDs) likedSongIds += remoteID else likedSongIds -= remoteID
        }
        val rangesBySongId = remote.clipRanges.associateBy(RemoteClipRange::songID).toMutableMap()
        val activeDirtyClipKeys = library.dirtyClipRangeKeys.filter(::activeClipKey)
        activeDirtyClipKeys.forEach { key ->
            val songID = key.substringAfter("|remote:", "")
            if (songID.isEmpty()) return@forEach
            if (key in library.deletedClipRangeKeys) {
                rangesBySongId -= songID
            } else {
                library.clipRanges[key]?.let { range ->
                    rangesBySongId[songID] = RemoteClipRange(
                        songID,
                        range.startMs / 1_000.0,
                        range.endMs / 1_000.0,
                    )
                }
            }
        }
        return RemotePlaylistsDocument(
            profileID = library.syncProfileID,
            revision = remote.revision,
            playlists = merged,
            likedSongIDs = likedSongIds.toList(),
            clipRanges = rangesBySongId.values.toList(),
        ) to (needsUpload || activeDirtyClipKeys.isNotEmpty())
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
        val mergedLikedSongIDs = document.likedSongIDs.toMutableSet()
        val intendedLikedSongIDs = library.remoteLikedSongIDs.orEmpty()
        library.dirtyRemoteLikeSongIDs.orEmpty().forEach { remoteID ->
            if (remoteID in intendedLikedSongIDs) mergedLikedSongIDs += remoteID else mergedLikedSongIDs -= remoteID
        }
        val activeDirtyClipKeys = library.dirtyClipRangeKeys.filter(::activeClipKey)
        val mergedClipRanges = library.clipRanges.filterKeys { key ->
            !activeClipKey(key) || "|local:" in key || key in activeDirtyClipKeys
        }.toMutableMap()
        document.clipRanges.forEach { payload ->
            val key = library.syncProfileID + "|remote:" + payload.songID
            if (key in activeDirtyClipKeys || key in library.deletedClipRangeKeys) return@forEach
            val start = (payload.startSeconds * 1_000).toLong()
            val end = (payload.endSeconds * 1_000).toLong()
            if (end - start >= 250L) mergedClipRanges[key] = ClipRange(start, end)
        }
        library = hydrateRemoteLikes(normalizeLiked(library.copy(
            playlists = system + custom,
            remoteLikedSongIDs = mergedLikedSongIDs,
            playlistRevision = document.revision,
            knownRemotePlaylistIDs = document.playlists.mapTo(mutableSetOf(), RemotePlaylist::id),
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() - document.playlists.map(RemotePlaylist::id).toSet(),
            likesDirty = library.dirtyRemoteLikeSongIDs.orEmpty().isNotEmpty(),
            clipRanges = mergedClipRanges,
        )))
        refreshQueuedClipMetadata()
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

    private fun migrateRemoteLikes(value: StoredLibrary): StoredLibrary {
        val remoteLikedSongIDs = value.remoteLikedSongIDs ?: value.favorites.mapNotNullTo(mutableSetOf()) { trackID ->
            value.tracks.firstOrNull {
                it.id == trackID && (it.syncProfileID ?: "default") == value.syncProfileID
            }?.remoteID
        }
        val dirtyRemoteLikeSongIDs = value.dirtyRemoteLikeSongIDs ?: if (value.likesDirty) {
            value.tracks.mapNotNullTo(mutableSetOf()) { track ->
                track.remoteID?.takeIf { (track.syncProfileID ?: "default") == value.syncProfileID }
            }
        } else {
            emptySet()
        }
        return hydrateRemoteLikes(value.copy(
            remoteLikedSongIDs = remoteLikedSongIDs,
            dirtyRemoteLikeSongIDs = dirtyRemoteLikeSongIDs,
            likesDirty = dirtyRemoteLikeSongIDs.isNotEmpty(),
        ))
    }

    private fun hydrateRemoteLikes(value: StoredLibrary): StoredLibrary {
        val localFavorites = value.favorites.filterTo(mutableSetOf()) { id ->
            value.tracks.firstOrNull { it.id == id }?.remoteID == null
        }
        val remoteFavorites = value.tracks.mapNotNullTo(mutableSetOf()) { track ->
            track.id.takeIf {
                track.remoteID?.let { it in value.remoteLikedSongIDs.orEmpty() } == true
                    && (track.syncProfileID ?: "default") == value.syncProfileID
            }
        }
        return normalizeLiked(value.copy(favorites = localFavorites + remoteFavorites))
    }

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
        val visibleTracks = library.tracks.filter { track ->
            track.remoteID == null || (track.syncProfileID ?: "default") == library.syncProfileID
        }
        val trackSizes = visibleTracks.associate { it.id to repository.fileForTrack(it).length() }
        val filePaths = visibleTracks.associate { it.id to repository.fileForTrack(it).absolutePath }
        val artwork = visibleTracks.mapNotNull { track -> repository.artworkFile(track)?.takeIf(File::isFile)?.absolutePath?.let { track.id to it } }.toMap()
        val visibleClipRanges = visibleTracks.mapNotNull { track ->
            library.clipRanges[clipRangeKey(track)]?.let { track.id to it }
        }.toMap()
        mutableState.value = mutableState.value.copy(
            tracks = visibleTracks,
            playlists = library.playlists,
            favoriteTrackIds = library.favorites,
            trackSizesById = trackSizes,
            trackFilePathsById = filePaths,
            clipRangesByTrackId = visibleClipRanges,
            artworkPathsByTrackId = artwork,
            downloadedRemoteSongIds = visibleTracks.mapNotNullTo(mutableSetOf(), Track::remoteID),
            serverUrl = credentials.serverURL,
            serverToken = credentials.clientToken,
            serverAdminKey = credentials.adminToken,
            syncProfileId = library.syncProfileID,
            syncProfiles = library.syncProfiles,
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
            volume = player.volume.coerceIn(0f, 1f),
        )
    }

    private fun mediaItem(id: String): MediaItem? {
        val track = library.tracks.firstOrNull { it.id == id } ?: return null
        val artworkUri = repository.artworkFile(track)?.takeIf(File::isFile)?.let(Uri::fromFile)
        val clip = playbackRange(track)
        val extras = Bundle().apply {
            putLong(PlaybackService.CLIP_START_MS, clip.startMs)
            putLong(PlaybackService.CLIP_END_MS, clip.endMs)
        }
        val metadata = MediaMetadata.Builder()
            .setTitle(track.title)
            .setArtist(track.artist)
            .setAlbumTitle(track.album)
            .setArtworkUri(artworkUri)
            .setExtras(extras)
            .build()
        return MediaItem.Builder()
            .setMediaId(track.id)
            .setUri(Uri.fromFile(repository.fileForTrack(track)))
            .setMediaMetadata(metadata)
            .build()
    }

    private fun refreshQueuedClipMetadata() {
        val player = controller ?: return
        if (player.mediaItemCount == 0) return
        val ids = activeQueue.ifEmpty {
            (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }
        }
        val currentID = player.currentMediaItem?.mediaId ?: return
        val items = ids.mapNotNull(::mediaItem)
        val index = items.indexOfFirst { it.mediaId == currentID }
        val track = library.tracks.firstOrNull { it.id == currentID }
        if (index < 0 || track == null) return
        val range = playbackRange(track)
        val position = player.currentPosition.coerceIn(range.startMs, (range.endMs - 1).coerceAtLeast(range.startMs))
        val wasPlaying = player.playWhenReady
        player.setMediaItems(items, index, position)
        player.prepare()
        if (wasPlaying) player.play() else player.pause()
    }

    private fun clipRangeKey(track: Track): String =
        library.syncProfileID + if (track.remoteID != null) "|remote:" + track.remoteID else "|local:" + track.id

    private fun activeClipKey(key: String): Boolean = key.startsWith(library.syncProfileID + "|")

    private fun playbackRange(track: Track): ClipRange {
        val stored = library.clipRanges[clipRangeKey(track)]
        if (stored == null) return ClipRange(0, track.durationMs.coerceAtLeast(1L))
        val start = stored.startMs.coerceIn(0, track.durationMs)
        val end = stored.endMs.coerceIn(start, track.durationMs)
        return if (end - start >= 250) ClipRange(start, end) else ClipRange(0, track.durationMs.coerceAtLeast(1L))
    }

    private fun serverClient() = ServerClient(
        credentials.serverURL,
        credentials.clientToken,
        credentials.adminToken,
        library.syncProfileID,
    )

    private fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    private fun showError(error: Throwable) {
        mutableState.value = mutableState.value.copy(errorMessage = error.message ?: "Something went wrong")
    }
}

internal fun normalizeProfileName(value: String): String =
    value.trim().split(Regex("\\s+")).filter(String::isNotEmpty).joinToString(" ")

internal fun repeatModeFor(enabled: Boolean): Int =
    if (enabled) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
