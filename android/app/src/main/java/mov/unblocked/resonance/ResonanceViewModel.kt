package mov.unblocked.resonance

import android.app.Application
import android.content.ComponentName
import android.media.MediaMetadataRetriever
import android.media.MediaPlayer
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
import com.clerk.api.Clerk
import com.clerk.api.ClerkConfigurationOptions
import com.clerk.api.network.serialization.ClerkResult
import com.clerk.api.session.GetTokenOptions
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Future
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import mov.unblocked.resonance.data.CredentialStore
import mov.unblocked.resonance.data.AccountSession
import mov.unblocked.resonance.data.ClipRange
import mov.unblocked.resonance.data.CatalogRequestSnapshot
import mov.unblocked.resonance.data.CatalogResponsePolicy
import mov.unblocked.resonance.data.ClientConfigFetchResult
import mov.unblocked.resonance.data.ClientConfigCacheFallbackPolicy
import mov.unblocked.resonance.data.ClientConfigRevisionPolicy
import mov.unblocked.resonance.data.ClientConfigSource
import mov.unblocked.resonance.data.ClientConfigStore
import mov.unblocked.resonance.data.EffectiveClientConfig
import mov.unblocked.resonance.data.LinkImportException
import mov.unblocked.resonance.data.LinkImportCandidate
import mov.unblocked.resonance.data.LinkImportExistingPolicy
import mov.unblocked.resonance.data.LinkImportProgress
import mov.unblocked.resonance.data.LinkImportService
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.LinkImportTrack
import mov.unblocked.resonance.data.LinkImportKind
import mov.unblocked.resonance.data.LinkImportMediaMode
import mov.unblocked.resonance.data.LinkImportInput
import mov.unblocked.resonance.data.LinkImportResolution
import mov.unblocked.resonance.data.ReviewedMatchResolutionPolicy
import mov.unblocked.resonance.data.LibraryRepository
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.PlaylistPutResult
import mov.unblocked.resonance.data.PlaylistMutationSnapshot
import mov.unblocked.resonance.data.PlaylistOrderPolicy
import mov.unblocked.resonance.data.PlaylistSyncMutationPolicy
import mov.unblocked.resonance.data.ProfileLibraryStatePolicy
import mov.unblocked.resonance.data.ProfileLibraryState
import mov.unblocked.resonance.data.RemotePlaylist
import mov.unblocked.resonance.data.RemoteClipRange
import mov.unblocked.resonance.data.RemotePlaylistsDocument
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.RemoteSongMetadataCacheEntry
import mov.unblocked.resonance.data.RemoteSongMetadataCachePolicy
import mov.unblocked.resonance.data.ResonanceAccountSignInServerURL
import mov.unblocked.resonance.data.ServerClient
import mov.unblocked.resonance.data.ServerProfileContext
import mov.unblocked.resonance.data.RemoteTrackIdentityPolicy
import mov.unblocked.resonance.data.ServerSongIdentityPolicy
import mov.unblocked.resonance.data.ServerDownloadMode
import mov.unblocked.resonance.data.ServerTransferModePolicy
import mov.unblocked.resonance.data.ServerUploadMode
import mov.unblocked.resonance.data.ServerUploadTransportPolicy
import mov.unblocked.resonance.data.SocialAuthClient
import mov.unblocked.resonance.data.NativeAuthConfiguration
import mov.unblocked.resonance.data.StoredLibrary
import mov.unblocked.resonance.data.SyncProfile
import mov.unblocked.resonance.data.ProfilePictureStore
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.associatedWithLocalSource
import mov.unblocked.resonance.playback.PlaybackService
import mov.unblocked.resonance.playback.DownloadPolicy
import mov.unblocked.resonance.playback.PlaybackFailurePolicy
import mov.unblocked.resonance.playback.PlaybackVolumePolicy
import mov.unblocked.resonance.playback.QueuePolicy
import mov.unblocked.resonance.playback.UploadMissingPolicy
import mov.unblocked.resonance.playback.AuthenticatedStreamHandle
import mov.unblocked.resonance.playback.AuthenticatedStreamRegistry
import mov.unblocked.resonance.playback.StreamLeaseUpdatePolicy
import mov.unblocked.resonance.ui.ResonanceActions
import mov.unblocked.resonance.ui.ResonanceUiState
import mov.unblocked.resonance.ui.LinkImportUiState
import mov.unblocked.resonance.ui.PlaybackUiStatus
import mov.unblocked.resonance.ui.invalidatedForSourceEdit
import mov.unblocked.resonance.ui.activeSyncProfileName

private data class ServerDownloadPolicySnapshot(
    val context: ServerProfileContext,
    val config: EffectiveClientConfig,
    val mode: ServerDownloadMode,
)

private data class ServerUploadPolicySnapshot(
    val context: ServerProfileContext,
    val config: EffectiveClientConfig,
    val mode: ServerUploadMode,
)

private data class RemoteSongMetadataRequest(
    val songIDs: List<String>,
    val cacheKey: String,
    val source: String,
    val mediaKind: String,
)

private data class RemoteSourceDownloadResult(
    val remoteID: String? = null,
    val failure: String? = null,
)

private data class RemoteSongMetadataResult(
    val request: RemoteSongMetadataRequest,
    val metadata: LinkImportTrack?,
)

private const val STREAM_ARTWORK_URL_EXTRA = "resonance.stream.artwork_url"

class ResonanceViewModel(application: Application) : AndroidViewModel(application), ResonanceActions {
    private val context = application.applicationContext
    private val repository = LibraryRepository(context)
    private val linkImportService = LinkImportService(context)
    private val remoteSourceResolutions = mutableMapOf<String, LinkImportResolution>()
    private val credentials = CredentialStore(context)
    private var accountSession: AccountSession? = credentials.accountSession
    private val clientConfigStore = ClientConfigStore(context)
    private val profilePictureStore = ProfilePictureStore(context)
    private val preferences = context.getSharedPreferences("resonance.playback", 0)
    private val mutableState = MutableStateFlow(
        ResonanceUiState(
            serverUrl = accountSession?.baseURL ?: credentials.serverURL,
            serverToken = accountSession?.accessToken ?: credentials.clientToken,
            serverAdminKey = accountSession?.accessToken ?: credentials.adminToken,
            accountEmail = accountSession?.email,
            accountRole = accountSession?.role,
            accountDisplayName = accountSession?.profileDisplayName,
            accountImageURL = accountSession?.imageURL,
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
    private val mutableProfilePictureRequests = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val profilePictureRequests = mutableProfilePictureRequests.asSharedFlow()
    private val mutableAccountBrowserRequests = MutableSharedFlow<String>(extraBufferCapacity = 1)
    val accountBrowserRequests = mutableAccountBrowserRequests.asSharedFlow()

    private var library = StoredLibrary(serverURL = credentials.serverURL)
    private var controllerFuture: Future<MediaController>? = null
    private var controller: MediaController? = null
    private var activeQueue: List<String> = emptyList()
    private var activePlaylistId: String? = null
    private var syncDebounce: Job? = null
    private var playlistMutationGeneration = 0L
    private var likesMutationGeneration = 0L
    private var clipRangeMutationGeneration = 0L
    private var connectionGeneration = 0L
    private var catalogRequestGeneration = 0L
    private var remoteSongMetadataHydrationGeneration = 0L
    private var remoteSongMetadataHydrationJob: Job? = null
    private var uploadMutationGeneration = 0L
    private var clientConfigRequestGeneration = 0L
    private var linkImportJob: Job? = null
    private var linkPreviewJob: Job? = null
    private var linkPreviewStopJob: Job? = null
    private var linkPreviewPlayer: MediaPlayer? = null
    private var remoteDownloadJob: Job? = null
    private var remoteDownloadExpiryJob: Job? = null
    private var activeDownloadPolicySnapshot: ServerDownloadPolicySnapshot? = null
    private var activeStreamHandle: AuthenticatedStreamHandle? = null
    private var activeStreamPresentation: Track? = null
    private var activeStreamPolicyContext: ServerProfileContext? = null
    private var streamConfigRenewalJob: Job? = null
    private var streamLeaseExpiryJob: Job? = null
    private var pendingStreamRenewalMinimumExpiry: Instant? = null
    private var libraryLoaded = false
    private var accountRefreshJob: Job? = null
    private var isRefreshingAccountSession = false
    private var nativeAuthServerURL: String? = null

    override fun dismissError() {
        mutableState.value = mutableState.value.copy(errorMessage = null)
    }

    override fun signInWithProvider(provider: String) {
        if (mutableState.value.isSigningIn) return
        mutableState.value = mutableState.value.copy(isSigningIn = true, serverMessage = "Opening account sign-in…")
        viewModelScope.launch {
            runCatching {
                val (destination, pending) = SocialAuthClient(ResonanceAccountSignInServerURL).begin(provider)
                credentials.pendingAccountSignIn = pending
                mutableAccountBrowserRequests.emit(destination.toString())
            }.onFailure { error ->
                mutableState.value = mutableState.value.copy(
                    isSigningIn = false,
                    serverMessage = error.message ?: "Account sign-in could not be started.",
                )
            }
        }
    }

    override fun startNativeAccountSignIn() {
        if (mutableState.value.isSigningIn) return
        mutableState.value = mutableState.value.copy(isSigningIn = true, serverMessage = "Preparing secure sign-in…")
        viewModelScope.launch {
            runCatching {
                val client = SocialAuthClient(ResonanceAccountSignInServerURL)
                val configuration = client.nativeConfiguration()
                configureClerk(configuration)
                nativeAuthServerURL = ResonanceAccountSignInServerURL
            }.onSuccess {
                mutableState.value = mutableState.value.copy(
                    isSigningIn = false,
                    isNativeAccountSignInOpen = true,
                    serverMessage = "Choose a sign-in method",
                )
            }.onFailure { error ->
                mutableState.value = mutableState.value.copy(
                    isSigningIn = false,
                    isNativeAccountSignInOpen = false,
                    serverMessage = error.message ?: "Account sign-in could not be started.",
                )
            }
        }
    }

    override fun dismissNativeAccountSignIn() {
        nativeAuthServerURL = null
        mutableState.value = mutableState.value.copy(
            isNativeAccountSignInOpen = false,
            isSigningIn = false,
        )
    }

    override fun completeNativeAccountSignIn() {
        val serverURL = nativeAuthServerURL ?: return
        if (mutableState.value.isSigningIn) return
        mutableState.value = mutableState.value.copy(isSigningIn = true, serverMessage = "Finishing sign-in…")
        viewModelScope.launch {
            runCatching {
                nativeAccountSession(
                    serverURL,
                    forceRefresh = false,
                    migrationProfileID = library.syncProfileID,
                )
            }
                .onSuccess { session ->
                    nativeAuthServerURL = null
                    acceptAccountSession(session)
                }
                .onFailure { error ->
                    mutableState.value = mutableState.value.copy(
                        isSigningIn = false,
                        serverMessage = error.message ?: "Account sign-in could not be completed.",
                    )
                }
        }
    }

    fun handleAccountCallback(uri: Uri?) {
        if (uri?.scheme != "resonance" || uri.host != "auth" || uri.path != "/callback") return
        val pending = credentials.pendingAccountSignIn
        if (pending == null || uri.getQueryParameter("state") != pending.state) {
            mutableState.value = mutableState.value.copy(
                isSigningIn = false,
                serverMessage = "The account sign-in callback was invalid or expired.",
            )
            return
        }
        credentials.pendingAccountSignIn = null
        val providerError = uri.getQueryParameter("error_description") ?: uri.getQueryParameter("error")
        val code = uri.getQueryParameter("code")
        if (providerError != null || code.isNullOrBlank()) {
            mutableState.value = mutableState.value.copy(
                isSigningIn = false,
                serverMessage = providerError ?: "The account sign-in callback was invalid or expired.",
            )
            return
        }
        viewModelScope.launch {
            runCatching {
                SocialAuthClient(pending.baseURL).exchange(
                    code,
                    pending.state,
                    pending,
                    migrationProfileID = library.syncProfileID,
                )
            }
                .onSuccess { session ->
                    acceptAccountSession(session)
                }
                .onFailure { error ->
                    mutableState.value = mutableState.value.copy(
                        isSigningIn = false,
                        serverMessage = error.message ?: "Account sign-in could not be completed.",
                    )
                }
        }
    }

    override fun signOutAccount() {
        val current = accountSession
        accountSession = null
        accountRefreshJob?.cancel()
        accountRefreshJob = null
        credentials.accountSession = null
        credentials.pendingAccountSignIn = null
        credentials.clearTokens()
        cancelRemoteSongMetadataHydration()
        mutableState.value = mutableState.value.copy(
            serverToken = "",
            serverAdminKey = "",
            accountEmail = null,
            accountRole = null,
            accountDisplayName = null,
            accountImageURL = null,
            isSigningIn = false,
            isNativeAccountSignInOpen = false,
            remoteSongs = emptyList(),
            selectedRemoteSongIds = emptySet(),
            serverMessage = "Signed out",
        )
        if (current != null) viewModelScope.launch {
            if (current.usesNativeClerkSession) {
                runCatching {
                    configureClerk(SocialAuthClient(current.baseURL).nativeConfiguration())
                    Clerk.auth.signOut()
                }
            } else {
                SocialAuthClient(current.baseURL).signOut(current)
            }
        }
    }

    fun refreshAccountSessionIfNeeded() {
        val current = accountSession ?: return
        val refreshLead = if (current.usesNativeClerkSession) 15_000L else 5 * 60_000L
        val needsProfileHydration = current.profileID.isNullOrBlank() ||
            current.profileID != current.accountID ||
            current.displayName.isNullOrBlank()
        if (!needsProfileHydration && current.expiresAt > System.currentTimeMillis() + refreshLead) {
            scheduleAccountRefresh(current)
            return
        }
        if (isRefreshingAccountSession) return
        isRefreshingAccountSession = true
        viewModelScope.launch {
            try {
                val refreshed = if (current.usesNativeClerkSession) {
                    nativeAccountSession(
                        current.baseURL,
                        forceRefresh = true,
                        migrationProfileID = current.profileID ?: library.syncProfileID,
                    )
                } else {
                    SocialAuthClient(current.baseURL).refresh(current, library.syncProfileID)
                }
                if (accountSession != current) return@launch
                migrateConfirmedLegacyProfile(refreshed)
                accountSession = refreshed
                credentials.accountSession = refreshed
                applyAccountSession(refreshed)
                refreshClientConfig()
                scheduleAccountRefresh(refreshed)
            } catch (error: Throwable) {
                if (accountSession != current) return@launch
                if (current.expiresAt <= System.currentTimeMillis()) {
                    signOutAccount()
                    mutableState.value = mutableState.value.copy(
                        serverMessage = error.message ?: "Your account session expired. Please sign in again.",
                    )
                } else {
                    accountRefreshJob?.cancel()
                    accountRefreshJob = viewModelScope.launch {
                        delay(60_000)
                        refreshAccountSessionIfNeeded()
                    }
                }
            } finally {
                isRefreshingAccountSession = false
            }
        }
    }

    private fun applyAccountSession(session: AccountSession) {
        mutableState.value = mutableState.value.copy(
            serverUrl = session.baseURL,
            serverToken = session.accessToken,
            serverAdminKey = session.accessToken,
            accountEmail = session.email,
            accountRole = session.role,
            accountDisplayName = session.profileDisplayName,
            accountImageURL = session.imageURL,
            isSigningIn = false,
            isNativeAccountSignInOpen = false,
            serverMessage = "Signed in with Clerk",
        )
    }

    private fun scheduleAccountRefresh(session: AccountSession) {
        accountRefreshJob?.cancel()
        val refreshLead = if (session.usesNativeClerkSession) 15_000L else 5 * 60_000L
        accountRefreshJob = viewModelScope.launch {
            delay((session.expiresAt - System.currentTimeMillis() - refreshLead).coerceAtLeast(5_000))
            refreshAccountSessionIfNeeded()
        }
    }

    private fun acceptAccountSession(session: AccountSession) {
        migrateConfirmedLegacyProfile(session)
        accountSession = session
        credentials.accountSession = session
        credentials.serverURL = session.baseURL
        credentials.clearTokens()
        applyAccountSession(session)
        scheduleAccountRefresh(session)
        saveServerConnection(
            session.baseURL,
            session.accessToken,
            session.accessToken,
            session.profileDisplayName,
        )
    }

    private fun migrateConfirmedLegacyProfile(session: AccountSession) {
        val migratedProfileID = session.migratedProfileID?.trim().orEmpty()
        val accountProfileID = session.profileID?.trim().orEmpty()
        if (migratedProfileID.isEmpty() || accountProfileID.isEmpty()) return
        val migrated = ProfileLibraryStatePolicy.migrateContext(
            library,
            session.baseURL,
            migratedProfileID,
            accountProfileID,
        )
        if (migrated == library) return
        library = normalizeLiked(migrated.copy(
            syncProfiles = listOf(SyncProfile(accountProfileID, session.profileDisplayName, true)),
        ))
        rebuildPlaybackQueueForActiveContext()
        refreshLibraryState()
        saveSoon()
    }

    private suspend fun configureClerk(configuration: NativeAuthConfiguration) {
        val options = ClerkConfigurationOptions(telemetryEnabled = false)
        if (Clerk.publishableKey != null && Clerk.publishableKey != configuration.publishableKey) {
            Clerk.switchConfiguration(context, configuration.publishableKey, options)
        } else {
            Clerk.initialize(context, configuration.publishableKey, options)
        }
        withTimeout(20_000) { Clerk.isInitialized.first { it } }
    }

    private suspend fun nativeAccountSession(
        serverURL: String,
        forceRefresh: Boolean,
        migrationProfileID: String? = null,
    ): AccountSession {
        val client = SocialAuthClient(serverURL)
        val configuration = client.nativeConfiguration()
        configureClerk(configuration)
        val result = Clerk.auth.getToken(
            GetTokenOptions(
                template = configuration.tokenTemplate,
                skipCache = forceRefresh,
                expirationBuffer = 15,
            ),
        )
        val token = when (result) {
            is ClerkResult.Success -> result.value
            is ClerkResult.Failure -> throw IllegalStateException(
                result.throwable?.message ?: "Clerk could not create a Resonance session token.",
            )
        }
        return client.accountSession(token, migrationProfileID)
    }

    override fun chooseProfilePicture() {
        mutableProfilePictureRequests.tryEmit(Unit)
    }

    fun setProfilePicture(uri: Uri) {
        val serverURL = library.serverURL
        val profileID = library.syncProfileID
        viewModelScope.launch {
            runCatching {
                withContext(Dispatchers.IO) {
                    profilePictureStore.save(uri, serverURL, profileID)
                }
            }.onSuccess { path ->
                if (library.serverURL == serverURL && library.syncProfileID == profileID) {
                    mutableState.value = mutableState.value.copy(profilePicturePath = path)
                }
            }.onFailure { error ->
                mutableState.value = mutableState.value.copy(
                    errorMessage = error.message ?: "Resonance could not use that profile picture.",
                )
            }
        }
    }

    override fun removeProfilePicture() {
        val serverURL = library.serverURL
        val profileID = library.syncProfileID
        viewModelScope.launch {
            withContext(Dispatchers.IO) { profilePictureStore.remove(serverURL, profileID) }
            if (library.serverURL == serverURL && library.syncProfileID == profileID) {
                mutableState.value = mutableState.value.copy(profilePicturePath = null)
            }
        }
    }

    init {
        accountSession?.let {
            credentials.serverURL = it.baseURL
            credentials.clearTokens()
            scheduleAccountRefresh(it)
        }
        connectController()
        viewModelScope.launch {
            library = repository.load()
            library = migrateRemoteTrackContexts(library)
            library = migrateCompoundClipKeys(library)
            library = migrateRemoteLikes(library)
            val configuredContext = RemoteTrackIdentityPolicy.contextKey(
                credentials.serverURL,
                library.syncProfileID,
            )
            val storedContext = RemoteTrackIdentityPolicy.contextKey(
                library.serverURL,
                library.syncProfileID,
            )
            if (configuredContext != null) {
                library = if (configuredContext == storedContext) {
                    library.copy(serverURL = credentials.serverURL)
                } else {
                    normalizeLiked(ProfileLibraryStatePolicy.switchContext(
                        library,
                        credentials.serverURL,
                        library.syncProfileID,
                    ))
                }
            }
            resetClientConfigForCurrentContext()
            libraryLoaded = true
            controller?.let(::restoreActiveStreamPresentation)
            rebuildPlaybackQueueForActiveContext()
            refreshLibraryState()
            refreshStorage()
            refreshAccountSessionIfNeeded()
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
                expireClientConfigIfNeeded()
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
                if (libraryLoaded) restoreActiveStreamPresentation(mediaController)
                mediaController.repeatMode = repeatModeFor(mutableState.value.repeatEnabled)
                mediaController.shuffleModeEnabled = mutableState.value.shuffleEnabled
                mediaController.setPlaybackSpeed(mutableState.value.playbackSpeed)
                mediaController.volume = PlaybackVolumePolicy.gainForSlider(mutableState.value.volume)
                mediaController.addListener(object : Player.Listener {
                    override fun onEvents(player: Player, events: Player.Events) = refreshPlaybackState()
                })
                rebuildPlaybackQueueForActiveContext()
                refreshPlaybackState()
            }
        }, ContextCompat.getMainExecutor(context))
    }

    override fun onCleared() {
        stopLinkImportPreview()
        remoteSongMetadataHydrationJob?.cancel()
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

    override fun updateLinkImportSource(source: String) {
        val current = mutableState.value.linkImport
        val invalidated = current.invalidatedForSourceEdit(source)
        if (invalidated === current) return

        stopLinkImportPreview()
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.value = mutableState.value.copy(linkImport = invalidated)
    }

    override fun setLinkImportMediaMode(mode: LinkImportMediaMode) {
        val current = mutableState.value.linkImport
        if (current.mediaMode == mode || current.isRunning) return
        stopLinkImportPreview()
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.value = mutableState.value.copy(linkImport = LinkImportUiState(mediaMode = mode))
    }

    override fun resolveLinkImport(source: String) {
        stopLinkImportPreview()
        val value = source.trim()
        val requestedMode = mutableState.value.linkImport.mediaMode
        if (value.isEmpty()) {
            mutableState.value = mutableState.value.copy(
                linkImport = LinkImportUiState(
                    mediaMode = requestedMode,
                    stage = LinkImportStage.Failed,
                    errorCode = "MISSING_SOURCE",
                    errorMessage = "Enter a song, artist, album, or supported Spotify, SoundCloud, or YouTube link first.",
                ),
            )
            return
        }
        linkImportJob?.cancel()
        val searchesProviders = !LinkImportInput.looksLikeLink(value)
        mutableState.value = mutableState.value.copy(
            linkImport = LinkImportUiState(
                mediaMode = requestedMode,
                requestedSource = value,
                stage = if (searchesProviders) LinkImportStage.SearchingCandidates else LinkImportStage.ResolvingMetadata,
            ),
        )
        linkImportJob = viewModelScope.launch {
            if (searchesProviders) {
                runCatching { linkImportService.search(value, requestedMode) }
                    .onSuccess { response ->
                        val first = response.results.first()
                        mutableState.value = mutableState.value.copy(
                            linkImport = mutableState.value.linkImport.copy(
                                stage = LinkImportStage.AwaitingSelection,
                                searchResponse = response,
                                selectedSearchResultId = first.id,
                                resolution = first.resolution,
                                selectedVideoId = first.candidates.firstOrNull()?.videoID,
                                selectedVideoIds = first.candidates.firstOrNull()?.videoID?.let(::setOf).orEmpty(),
                                errorCode = null,
                                errorMessage = null,
                            ),
                        )
                    }.onFailure(::applyLinkImportFailure)
            } else {
                runCatching { linkImportService.resolve(value, requestedMode, ::applyLinkImportProgress) }
                    .onSuccess { resolution ->
                        mutableState.value = mutableState.value.copy(
                            linkImport = mutableState.value.linkImport.copy(
                                stage = LinkImportStage.AwaitingSelection,
                                resolution = resolution,
                                selectedVideoId = resolution.candidates.firstOrNull()?.videoID,
                                selectedVideoIds = if (resolution.kind.isPlaylist) {
                                    resolution.candidates.mapTo(mutableSetOf(), mov.unblocked.resonance.data.LinkImportCandidate::videoID)
                                } else {
                                    resolution.candidates.firstOrNull()?.videoID?.let(::setOf).orEmpty()
                                },
                                errorCode = null,
                                errorMessage = null,
                            ),
                        )
                    }.onFailure(::applyLinkImportFailure)
            }
        }
    }

    override fun selectLinkImportSearchResult(resultId: String) {
        val current = mutableState.value.linkImport
        val result = current.searchResponse?.results?.firstOrNull { it.id == resultId } ?: return
        val candidate = result.candidates.firstOrNull()
        if (current.previewingVideoId != null && current.previewingVideoId != candidate?.videoID) {
            stopLinkImportPreview()
        }
        val refreshed = mutableState.value.linkImport
        mutableState.value = mutableState.value.copy(
            linkImport = refreshed.copy(
                selectedSearchResultId = result.id,
                resolution = result.resolution,
                selectedVideoId = candidate?.videoID,
                selectedVideoIds = candidate?.videoID?.let(::setOf).orEmpty(),
                previewError = null,
            ),
        )
    }

    override fun selectLinkImportCandidate(videoId: String) {
        val current = mutableState.value.linkImport
        if (current.resolution?.candidates?.any { it.videoID == videoId } != true) return
        val playlist = current.resolution.kind.isPlaylist
        val selection = if (playlist) {
            current.selectedVideoIds.toMutableSet().apply {
                if (!add(videoId)) remove(videoId)
            }
        } else {
            setOf(videoId)
        }
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(selectedVideoId = if (playlist) current.selectedVideoId else videoId, selectedVideoIds = selection),
        )
    }

    override fun confirmLinkImport(uploadAfterImport: Boolean): Boolean {
        val current = mutableState.value.linkImport
        val resolution = current.resolution ?: return false
        if (mutableState.value.isApplyingServerConnection || mutableState.value.isDownloading || mutableState.value.isUploading) {
            mutableState.value = mutableState.value.copy(
                linkImport = current.copy(
                    stage = LinkImportStage.Failed,
                    errorCode = "TRANSFER_IN_PROGRESS",
                    errorMessage = "Wait for the current connection change, download, or upload to finish, then try again.",
                ),
            )
            return false
        }
        if (uploadAfterImport && !hasLinkImportServerConfiguration()) {
            mutableState.value = mutableState.value.copy(
                linkImport = current.copy(
                    stage = LinkImportStage.Failed,
                    errorCode = "SERVER_UPLOAD_NOT_CONFIGURED",
                    errorMessage = "Sign in to your Resonance account, or turn off server upload.",
                ),
            )
            return false
        }
        val uploadMode = if (uploadAfterImport) activeUploadMode() else null
        if (uploadAfterImport && uploadMode == null) {
            applyLinkUploadModeFailure(current, "Server uploads are disabled by the current server policy.")
            return false
        }
        if (
            uploadAfterImport &&
            uploadMode?.let(ServerUploadTransportPolicy::allowsLinkDerivedServerUpload) != true
        ) {
            applyLinkUploadModeFailure(
                current,
                "Link-derived media requires the Reviewed match mode, or Source link mode for an original YouTube page. Turn off server upload to keep it only on this device.",
            )
            return false
        }
        if (resolution.reviewedMatchPolicyBound && (!uploadAfterImport || uploadMode != ServerUploadMode.ReviewedMatch)) {
            applyLinkUploadModeFailure(
                current,
                "These candidates came from the server's Reviewed match gate. Keep Reviewed match selected to register the explicitly reviewed source link, or resolve the link again for a device-only import.",
            )
            return false
        }
        if (uploadAfterImport && uploadMode == ServerUploadMode.ReviewedMatch && !resolution.reviewedMatchPolicyBound) {
            return beginReviewedMatchResolution(current)
        }
        val sourcePageURL: String? = null
        val uploadSnapshot = if (uploadAfterImport) {
            currentUploadPolicySnapshot(requireNotNull(uploadMode)) ?: run {
                applyLinkUploadModeFailure(current, "The server upload policy changed; refresh and review the match again.")
                return false
            }
        } else null
        stopLinkImportPreview()
        if (resolution.kind.isPlaylist) {
            return confirmSpotifyPlaylistImport(current, resolution, uploadAfterImport, uploadSnapshot)
        }
        val candidate = resolution.candidates.firstOrNull { it.videoID == current.selectedVideoId } ?: return false
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.InspectingSource,
                completedBytes = 0,
                totalBytes = 0,
                errorCode = null,
                errorMessage = null,
            ),
            isDownloading = true,
            downloadDetail = "Preparing import…",
            errorMessage = null,
        )
        linkImportJob = viewModelScope.launch {
            runSingleLinkImport(
                resolution,
                candidate,
                current.mediaMode,
                uploadAfterImport,
                sourcePageURL,
                uploadMode,
                uploadSnapshot,
            )
        }
        return true
    }

    private fun beginReviewedMatchResolution(current: LinkImportUiState): Boolean {
        val snapshot = currentUploadPolicySnapshot(ServerUploadMode.ReviewedMatch) ?: run {
            applyLinkUploadModeFailure(current, "Reviewed match is no longer enabled by the server policy.")
            return false
        }
        val requestedSource = current.requestedSource?.trim().orEmpty()
        if (!LinkImportInput.isReviewedTrackLink(requestedSource)) {
            applyLinkUploadModeFailure(
                current,
                "Reviewed match needs one full Spotify track link or individual YouTube video link so the server can return review-only candidates.",
            )
            return false
        }
        ReviewedMatchResolutionPolicy.bindLocalYouTubeCandidate(
            requestedSource = requestedSource,
            resolution = current.resolution ?: return false,
        )?.let { localReviewed ->
            stopLinkImportPreview()
            mutableState.value = mutableState.value.copy(
                linkImport = current.copy(
                    stage = LinkImportStage.AwaitingSelection,
                    resolution = localReviewed,
                    // A reviewed upload always needs a fresh explicit selection,
                    // even when the exact YouTube candidate was resolved locally.
                    selectedVideoId = null,
                    selectedVideoIds = emptySet(),
                    errorCode = null,
                    errorMessage = null,
                ),
            )
            return false
        }
        stopLinkImportPreview()
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.SearchingCandidates,
                selectedVideoId = null,
                selectedVideoIds = emptySet(),
                errorCode = null,
                errorMessage = null,
            ),
        )
        linkImportJob = viewModelScope.launch {
            runCatching {
                requireUploadPolicySnapshot(snapshot)
                serverClient(snapshot.context).resolveReviewedMatch(
                    source = requestedSource,
                    cohortKey = clientConfigStore.cohortKey,
                ).also { requireUploadPolicySnapshot(snapshot) }
            }.onSuccess { reviewed ->
                mutableState.value = mutableState.value.copy(
                    linkImport = mutableState.value.linkImport.copy(
                        stage = LinkImportStage.AwaitingSelection,
                        resolution = reviewed,
                        // Never preselect metadata-only server candidates.
                        selectedVideoId = null,
                        selectedVideoIds = emptySet(),
                        errorCode = null,
                        errorMessage = null,
                    ),
                )
            }.onFailure(::applyLinkImportFailure)
        }
        // Keep the dialog open for an explicit radio-button selection.
        return false
    }

    private fun confirmSpotifyPlaylistImport(
        current: LinkImportUiState,
        resolution: LinkImportResolution,
        uploadAfterImport: Boolean,
        uploadSnapshot: ServerUploadPolicySnapshot?,
    ): Boolean {
        val playlist = resolution.playlist ?: return false
        val selected = resolution.candidates
            .filter { it.videoID in current.selectedVideoIds }
            .sortedBy { it.playlistIndex }
        if (selected.isEmpty()) return false
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.InspectingSource,
                completedBytes = 0,
                totalBytes = 0,
                errorCode = null,
                errorMessage = null,
                completedSummary = null,
            ),
            isDownloading = true,
            downloadDetail = "Preparing playlist import…",
            errorMessage = null,
        )
        linkImportJob = viewModelScope.launch {
            runSpotifyPlaylistImport(resolution, selected, current.mediaMode, uploadAfterImport, uploadSnapshot)
        }
        return true
    }

    override fun toggleLinkImportPreview(videoId: String) {
        val linkState = mutableState.value.linkImport
        if (linkState.previewingVideoId == videoId || linkState.previewLoadingVideoId == videoId) {
            stopLinkImportPreview()
            return
        }
        val candidate = linkState.resolution?.candidates?.firstOrNull { it.videoID == videoId } ?: return
        stopLinkImportPreview()
        mutableState.value = mutableState.value.copy(
            linkImport = mutableState.value.linkImport.copy(
                previewLoadingVideoId = videoId,
                previewError = null,
            ),
        )
        linkPreviewJob = viewModelScope.launch {
            runCatching { linkImportService.preview(candidate) }
                .onSuccess { preview ->
                    val player = MediaPlayer()
                    linkPreviewPlayer = player
                    player.setOnPreparedListener {
                        it.start()
                        mutableState.value = mutableState.value.copy(
                            linkImport = mutableState.value.linkImport.copy(
                                previewLoadingVideoId = null,
                                previewingVideoId = videoId,
                            ),
                        )
                        linkPreviewStopJob?.cancel()
                        linkPreviewStopJob = viewModelScope.launch {
                            delay(30_000)
                            stopLinkImportPreview()
                        }
                    }
                    player.setOnErrorListener { _, _, _ ->
                        stopLinkImportPreview()
                        mutableState.value = mutableState.value.copy(
                            linkImport = mutableState.value.linkImport.copy(previewError = "Preview unavailable."),
                        )
                        true
                    }
                    player.setDataSource(context, Uri.parse(preview.url), preview.headers)
                    player.prepareAsync()
                }
                .onFailure { error ->
                    if (error !is CancellationException) {
                        mutableState.value = mutableState.value.copy(
                            linkImport = mutableState.value.linkImport.copy(
                                previewLoadingVideoId = null,
                                previewError = "Preview unavailable: ${error.message ?: "unknown error"}",
                            ),
                        )
                    }
                }
            linkPreviewJob = null
        }
    }

    override fun stopLinkImportPreview() {
        linkPreviewJob?.cancel()
        linkPreviewStopJob?.cancel()
        linkPreviewJob = null
        linkPreviewStopJob = null
        linkPreviewPlayer?.runCatching { stop() }
        linkPreviewPlayer?.release()
        linkPreviewPlayer = null
        mutableState.value = mutableState.value.copy(
            linkImport = mutableState.value.linkImport.copy(
                previewLoadingVideoId = null,
                previewingVideoId = null,
            ),
        )
    }

    private suspend fun runSingleLinkImport(
        resolution: LinkImportResolution,
        selectedCandidate: LinkImportCandidate,
        mediaMode: LinkImportMediaMode,
        uploadAfterImport: Boolean,
        sourcePageURL: String?,
        uploadMode: ServerUploadMode?,
        uploadSnapshot: ServerUploadPolicySnapshot?,
    ) {
        val client = uploadSnapshot?.let { serverClient(it.context) }
        try {
            uploadSnapshot?.let(::requireUploadPolicySnapshot)
            val strictSourceIdentity = uploadMode in setOf(
                ServerUploadMode.ReviewedMatch,
                ServerUploadMode.ServerSourceLink,
            )
            val metadata = resolution.track.copy(
                artworkURL = resolution.track.artworkURL ?: selectedCandidate.thumbnailURL,
            )
            var match = LinkImportExistingPolicy.match(
                metadata,
                library.tracks,
                mutableState.value.remoteSongs,
                mutableState.value.serverUrl,
                library.syncProfileID,
                mediaMode,
            )
            // A metadata match is not proof that existing bytes are the requested
            // source. Both source-bound modes resolve the exact sole candidate and
            // may reuse only a cryptographic duplicate discovered after those
            // bytes have been downloaded and hashed.
            var track = if (strictSourceIdentity) null else {
                match.deviceTrackID
                    ?.let { id -> library.tracks.firstOrNull { it.id == id } }
                    ?.let { existing -> associateLocalImportSource(existing, metadata.sourceURL) }
            }
            val plannedDownloads = if (track == null) 1 else 0
            if (track == null) {
                beginLinkDownloads(1)
                val candidates = if (strictSourceIdentity) {
                    listOf(selectedCandidate)
                } else {
                    listOf(selectedCandidate) + selectedCandidate.fallbackCandidates +
                        resolution.candidates.filter { it.videoID != selectedCandidate.videoID }
                }
                track = downloadLinkTrack(metadata, candidates.distinctBy(LinkImportCandidate::videoID), mediaMode, 0, 1)
                mutableState.value = mutableState.value.copy(downloadProgress = 1f)
            }
            requireNotNull(track) { "The imported song could not be found on this device." }
            uploadSnapshot?.let(::requireUploadPolicySnapshot)
            match = LinkImportExistingPolicy.match(
                metadata,
                library.tracks,
                mutableState.value.remoteSongs,
                mutableState.value.serverUrl,
                library.syncProfileID,
                mediaMode,
            )
            val existingServerSongID = match.serverSongID.takeUnless { strictSourceIdentity }
            existingServerSongID?.let { adoptUploadedDownload(track.id, it, client?.baseURL ?: mutableState.value.serverUrl) }

            var uploadFailure: Throwable? = null
            if (client != null && existingServerSongID == null) {
                beginLinkUploads(1)
                runCatching {
                    uploadLinkTrackWithRetry(
                        track,
                        client,
                        0,
                        1,
                        sourcePageURL,
                        requireNotNull(uploadSnapshot),
                    )
                }
                    .onFailure { uploadFailure = it }
                mutableState.value = mutableState.value.copy(uploadProgress = 1f)
            }
            persistLibrary()
            finishLinkTransfers()
            if (client != null && uploadFailure == null) refreshCatalogAfterUpload()
            if (uploadFailure != null) {
                val detail = "Saved locally; upload failed after retrying: ${track.title} — ${track.artist} (${uploadFailure.message ?: "upload failed"})"
                mutableState.value = mutableState.value.copy(
                    errorMessage = detail,
                    linkImport = mutableState.value.linkImport.copy(
                        stage = LinkImportStage.Failed,
                        completedTrackTitle = track.title,
                        errorCode = "SERVER_UPLOAD_FAILED",
                        errorMessage = detail,
                    ),
                )
            } else {
                val localDetail = if (plannedDownloads == 0) "Already on this device." else "Downloaded to this device."
                val serverDetail = if (!uploadAfterImport) "" else if (existingServerSongID != null) " Already on the server." else " Uploaded to the server."
                mutableState.value = mutableState.value.copy(
                    linkImport = mutableState.value.linkImport.copy(
                        stage = LinkImportStage.Complete,
                        completedTrackTitle = track.title,
                        completedSummary = localDetail + serverDetail,
                        batchCurrentTitle = null,
                    ),
                )
            }
        } catch (_: CancellationException) {
            finishLinkTransfers()
            mutableState.value = mutableState.value.copy(
                linkImport = mutableState.value.linkImport.copy(stage = LinkImportStage.Cancelled, batchCurrentTitle = null),
            )
        } catch (error: Throwable) {
            finishLinkTransfers()
            val detail = "${resolution.track.title} — ${resolution.track.artist}: ${error.message ?: "download failed"}"
            mutableState.value = mutableState.value.copy(
                errorMessage = detail,
                linkImport = mutableState.value.linkImport.copy(
                    stage = LinkImportStage.Failed,
                    errorCode = (error as? LinkImportException)?.code ?: "LOCAL_IMPORT_FAILED",
                    errorMessage = detail,
                    batchCurrentTitle = null,
                ),
            )
        }
    }

    private suspend fun runSpotifyPlaylistImport(
        resolution: LinkImportResolution,
        selected: List<LinkImportCandidate>,
        mediaMode: LinkImportMediaMode,
        uploadAfterImport: Boolean,
        uploadSnapshot: ServerUploadPolicySnapshot?,
    ) {
        val playlist = requireNotNull(resolution.playlist)
        val imported = mutableListOf<Pair<LinkImportCandidate, Track>>()
        val downloadFailures = mutableListOf<String>()
        val uploadFailures = mutableListOf<String>()
        val client = uploadSnapshot?.let { serverClient(it.context) }
        try {
            val initialMatches = selected.associateWith { candidate ->
                LinkImportExistingPolicy.match(
                    requireNotNull(candidate.importTrack),
                    library.tracks,
                    mutableState.value.remoteSongs,
                    mutableState.value.serverUrl,
                    library.syncProfileID,
                    mediaMode,
                )
            }
            val downloadItems = selected.filter { initialMatches[it]?.deviceTrackID == null }
            if (downloadItems.isNotEmpty()) beginLinkDownloads(downloadItems.size)
            var completedDownloads = 0
            selected.forEach { candidate ->
                val metadata = requireNotNull(candidate.importTrack).copy(
                    artworkURL = candidate.importTrack.artworkURL ?: candidate.thumbnailURL,
                )
                val initial = initialMatches[candidate]
                var track = initial?.deviceTrackID
                    ?.let { id -> library.tracks.firstOrNull { it.id == id } }
                    ?.let { existing -> associateLocalImportSource(existing, metadata.sourceURL) }
                if (track == null) {
                    mutableState.value = mutableState.value.copy(
                        linkImport = mutableState.value.linkImport.copy(
                            batchCurrentTitle = "${completedDownloads + 1} of ${downloadItems.size} • ${metadata.title}",
                        ),
                    )
                    try {
                        track = downloadLinkTrack(
                            metadata,
                            (listOf(candidate) + candidate.fallbackCandidates).distinctBy(LinkImportCandidate::videoID),
                            mediaMode,
                            completedDownloads,
                            downloadItems.size,
                        )
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        downloadFailures += "${metadata.title} — ${metadata.artist} (${error.message ?: "download failed"})"
                    }
                    completedDownloads += 1
                    mutableState.value = mutableState.value.copy(
                        downloadProgress = completedDownloads.toFloat() / downloadItems.size.coerceAtLeast(1),
                    )
                }
                if (track != null) {
                    initial?.serverSongID?.let { remoteID ->
                        adoptUploadedDownload(track.id, remoteID, client?.baseURL ?: mutableState.value.serverUrl)
                    }
                    if (imported.none { it.second.id == track.id }) imported += candidate to track
                }
            }
            upsertImportedPlaylist(playlist.title, imported.map { it.second })
            persistLibrary()

            val uploadQueue = if (client == null) emptyList() else imported.filter { (candidate, _) ->
                LinkImportExistingPolicy.match(
                    requireNotNull(candidate.importTrack),
                    library.tracks,
                    mutableState.value.remoteSongs,
                    mutableState.value.serverUrl,
                    library.syncProfileID,
                    mediaMode,
                ).serverSongID == null
            }
            if (client != null && uploadQueue.isNotEmpty()) {
                beginLinkUploads(uploadQueue.size)
                uploadQueue.forEachIndexed { index, (_, track) ->
                    try {
                        uploadLinkTrackWithRetry(
                            track,
                            client,
                            index,
                            uploadQueue.size,
                            null,
                            requireNotNull(uploadSnapshot),
                        )
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        uploadFailures += "${track.title} — ${track.artist} (${error.message ?: "upload failed"})"
                    }
                    mutableState.value = mutableState.value.copy(
                        uploadProgress = (index + 1).toFloat() / uploadQueue.size,
                    )
                }
            }
            persistLibrary()
            finishLinkTransfers()
            if (client != null) refreshCatalogAfterUpload()
            val summary = "Kept ${imported.size} of ${selected.size} selected songs in ${playlist.title}."
            val deviceSkips = initialMatches.values.count { it.isOnDevice }
            val serverSkips = if (uploadAfterImport) initialMatches.values.count { it.isOnServer } else 0
            when {
                downloadFailures.isNotEmpty() -> {
                    val detail = "Playlist import incomplete. Kept ${imported.size} song${if (imported.size == 1) "" else "s"}. Downloads failed after retrying: ${downloadFailures.joinToString("; ")}"
                    mutableState.value = mutableState.value.copy(
                        errorMessage = detail,
                        linkImport = mutableState.value.linkImport.copy(
                            stage = LinkImportStage.Failed,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = summary,
                            batchCurrentTitle = null,
                            errorCode = "PLAYLIST_DOWNLOAD_PARTIAL_FAILURE",
                            errorMessage = detail,
                        ),
                    )
                }
                uploadFailures.isNotEmpty() -> {
                    val detail = "Saved every downloaded song locally. Server uploads failed after retrying: ${uploadFailures.joinToString("; ")}"
                    mutableState.value = mutableState.value.copy(
                        errorMessage = detail,
                        linkImport = mutableState.value.linkImport.copy(
                            stage = LinkImportStage.Failed,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = summary,
                            batchCurrentTitle = null,
                            errorCode = "PLAYLIST_UPLOAD_PARTIAL_FAILURE",
                            errorMessage = detail,
                        ),
                    )
                }
                else -> {
                    mutableState.value = mutableState.value.copy(
                        linkImport = mutableState.value.linkImport.copy(
                            stage = LinkImportStage.Complete,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = "$summary Skipped $deviceSkips device downloads and $serverSkips server uploads.",
                            batchCurrentTitle = null,
                        ),
                    )
                }
            }
        } catch (_: CancellationException) {
            upsertImportedPlaylist(playlist.title, imported.map { it.second })
            persistLibrary()
            finishLinkTransfers()
            mutableState.value = mutableState.value.copy(
                linkImport = mutableState.value.linkImport.copy(
                    stage = LinkImportStage.Cancelled,
                    batchCurrentTitle = null,
                    completedSummary = "Cancelled after keeping ${imported.size} of ${selected.size} songs.",
                ),
            )
        } catch (error: Throwable) {
            upsertImportedPlaylist(playlist.title, imported.map(Pair<LinkImportCandidate, Track>::second))
            persistLibrary()
            finishLinkTransfers()
            val detail = error.message ?: "The playlist import failed."
            mutableState.value = mutableState.value.copy(
                errorMessage = detail,
                linkImport = mutableState.value.linkImport.copy(
                    stage = LinkImportStage.Failed,
                    batchCurrentTitle = null,
                    errorCode = "LOCAL_IMPORT_FAILED",
                    errorMessage = detail,
                ),
            )
        }
    }

    private suspend fun associateLocalImportSource(
        track: Track,
        sourceURL: String?,
        downloadSourceURL: String? = null,
        persistImmediately: Boolean = true,
    ): Track {
        val associated = track.associatedWithLocalSource(sourceURL, downloadSourceURL)
        if (associated == track) return track
        library = normalizeLiked(library.copy(
            tracks = library.tracks.map { current ->
                if (current.id == track.id) associated else current
            },
        ))
        if (persistImmediately) persistLibrary()
        return associated
    }

    private suspend fun downloadLinkTrack(
        metadata: LinkImportTrack,
        candidates: List<LinkImportCandidate>,
        mediaMode: LinkImportMediaMode,
        completedBefore: Int,
        total: Int,
        deferArtwork: Boolean = false,
        persistImmediately: Boolean = true,
        batchProgress: ((Float) -> Unit)? = null,
    ): Track {
        var lastError: Throwable? = null
        candidates.forEachIndexed { candidateIndex, candidate ->
            try {
                if (candidateIndex > 0) delay(400)
                val download = linkImportService.download(
                    candidate = candidate,
                    metadata = metadata,
                    mediaMode = mediaMode,
                    includeArtwork = !deferArtwork,
                ) { progress ->
                    applyLinkImportProgress(progress)
                    val byteFraction = if (progress.totalBytes > 0) {
                        (progress.completedBytes.toFloat() / progress.totalBytes).coerceIn(0f, 1f)
                    } else 0f
                    if (batchProgress != null) {
                        batchProgress(byteFraction)
                    } else {
                        mutableState.update { state -> state.copy(
                            downloadProgress = (completedBefore + byteFraction) / total.coerceAtLeast(1),
                            downloadDetail = "Downloading ${completedBefore + 1} of $total • ${metadata.title}",
                        ) }
                    }
                }
                val duplicate = library.tracks.firstOrNull {
                    it.sourceSHA256 == download.sourceSHA256 ||
                        it.contentSHA256 == download.sourceSHA256 ||
                        it.contentSHA256 == download.contentSHA256
                }
                val track = if (duplicate != null) {
                    download.file.parentFile?.deleteRecursively()
                    associateLocalImportSource(
                        duplicate,
                        download.metadata.sourceURL,
                        download.downloadSourceURL,
                        persistImmediately,
                    )
                } else {
                    applyLinkImportProgress(LinkImportProgress(LinkImportStage.SavingLocal))
                    repository.registerLocalImport(download).also { imported ->
                        library = normalizeLiked(library.copy(tracks = library.tracks + imported))
                        if (persistImmediately) persistLibrary()
                    }
                }
                return track
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
            }
        }
        throw lastError ?: LinkImportException(
            LinkImportStage.Downloading,
            "ALL_SOURCES_FAILED",
            "Every matched ${mediaMode.name.lowercase()} source failed.",
        )
    }

    private suspend fun uploadLinkTrackWithRetry(
        track: Track,
        client: ServerClient,
        index: Int,
        total: Int,
        sourcePageURL: String?,
        snapshot: ServerUploadPolicySnapshot,
    ): String {
        val requestedMode = snapshot.mode
        requireUploadPolicySnapshot(snapshot)
        // Fail before any server mutation if hash deduplication reused a file
        // that is already owned by another server/profile association.
        RemoteTrackIdentityPolicy.requireCanAssociate(track, client.baseURL, library.syncProfileID)
        if (requestedMode == ServerUploadMode.LocalFile) {
            mutableState.value.remoteSongs.firstOrNull { song ->
                ServerSongIdentityPolicy.metadataMatches(
                    expectedTitle = track.title,
                    expectedArtist = track.artist,
                    expectedDuration = track.durationMs.takeIf { it > 0 }?.div(1_000.0),
                    actualTitle = song.title,
                    actualArtist = song.artist,
                    actualDuration = song.durationSeconds,
                )
            }?.let { existing ->
                adoptUploadedDownload(track.id, existing.id, client.baseURL)
                return existing.id
            }
        }
        var lastError: Throwable? = null
        for (attempt in 0 until 3) {
            if (attempt > 0) delay(if (attempt == 1) 500 else 1_500)
            mutableState.value = mutableState.value.copy(
                linkImport = mutableState.value.linkImport.copy(stage = LinkImportStage.Syncing),
                uploadDetail = "Uploading ${index + 1} of $total • ${track.title}",
            )
            val uploaded = try {
                // Capture and revalidate immediately before every request. A retry
                // is a new request and therefore needs a still-current lease.
                requireUploadPolicySnapshot(snapshot)
                client.upload(track) {
                    requireUploadPolicySnapshot(snapshot)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
                continue
            }

            // The server has committed a 201/409 here. Reconcile only into the
            // exact captured context, without requiring the lease to remain live
            // after the request or turning a reconciliation problem into a retry.
            if (currentServerProfileContext() == snapshot.context) {
                uploadMutationGeneration += 1
                runCatching { adoptUploadedDownload(track.id, uploaded.id, client.baseURL) }
                    .onFailure(::showError)
            }
            return uploaded.id
        }
        throw lastError ?: IllegalStateException("Upload failed")
    }

    private fun beginLinkDownloads(total: Int) {
        mutableState.value = mutableState.value.copy(
            isUploading = false,
            isDownloading = true,
            downloadProgress = 0f,
            downloadDetail = "Preparing 1 of $total",
        )
    }

    private fun beginLinkUploads(total: Int) {
        mutableState.value = mutableState.value.copy(
            isDownloading = false,
            isUploading = true,
            uploadProgress = 0f,
            uploadDetail = "Preparing 1 of $total",
            linkImport = mutableState.value.linkImport.copy(stage = LinkImportStage.Syncing),
        )
    }

    private fun finishLinkTransfers() {
        mutableState.value = mutableState.value.copy(isDownloading = false, isUploading = false)
    }

    private fun hasLinkImportServerConfiguration(): Boolean {
        return mutableState.value.hasServerUploadCredentials
    }

    private fun upsertImportedPlaylist(name: String, tracks: List<Track>) {
        if (tracks.isEmpty()) return
        val index = library.playlists.indexOfFirst { !it.isSystem && it.name.equals(name, ignoreCase = true) }
        val playlists = library.playlists.toMutableList()
        val playlist = if (index >= 0) playlists[index] else Playlist(name = name, remoteSongIDs = emptyList()).also(playlists::add)
        val updated = updateRemoteSongIds(playlist.copy(trackIDs = (playlist.trackIDs + tracks.map(Track::id)).distinct()))
        val updatedIndex = if (index >= 0) index else playlists.lastIndex
        playlists[updatedIndex] = updated
        library = library.copy(
            playlists = playlists,
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() + updated.id,
        )
        playlistMutationGeneration += 1
        saveAndScheduleSync()
    }

    override fun cancelLinkImport() {
        stopLinkImportPreview()
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.value = mutableState.value.copy(
            linkImport = LinkImportUiState(stage = LinkImportStage.Cancelled),
        )
    }

    private fun applyLinkImportProgress(progress: LinkImportProgress) {
        mutableState.update { state -> state.copy(
            linkImport = state.linkImport.copy(
                stage = progress.stage,
                completedBytes = progress.completedBytes,
                totalBytes = progress.totalBytes,
            ),
        ) }
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

    private fun applyLinkUploadModeFailure(current: LinkImportUiState, message: String) {
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.Failed,
                errorCode = "UPLOAD_MODE_UNAVAILABLE",
                errorMessage = message,
            ),
        )
    }

    private fun activeUploadMode(): ServerUploadMode? {
        expireClientConfigIfNeeded()
        val state = mutableState.value
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            state.serverUploadMode,
            state.serverDownloadMode,
        )
        if (resolved.uploadMode != state.serverUploadMode || resolved.downloadMode != state.serverDownloadMode) {
            mutableState.value = state.copy(
                serverUploadMode = resolved.uploadMode,
                serverDownloadMode = resolved.downloadMode,
                clientConfigStatus = if (state.clientConfig.isActive(Instant.now())) {
                    state.clientConfigStatus
                } else {
                    "Safe defaults • server policy expired"
                },
            )
        }
        return resolved.uploadMode
    }

    private fun currentUploadPolicySnapshot(mode: ServerUploadMode): ServerUploadPolicySnapshot? {
        val context = currentServerProfileContext() ?: return null
        val snapshot = ServerUploadPolicySnapshot(context, mutableState.value.clientConfig, mode)
        return runCatching { requireUploadPolicySnapshot(snapshot); snapshot }.getOrNull()
    }

    private fun requireUploadPolicySnapshot(snapshot: ServerUploadPolicySnapshot) {
        val state = mutableState.value
        check(currentServerProfileContext() == snapshot.context) { "The server connection changed during upload" }
        val now = Instant.now()
        val exactLease = state.clientConfig == snapshot.config && snapshot.config.isActive(now)
        check(exactLease) {
            "The server upload policy changed or expired"
        }
        check(state.serverUploadMode == snapshot.mode) { "The selected server upload mode changed" }
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            snapshot.mode,
            state.serverDownloadMode,
        )
        check(resolved.uploadMode == snapshot.mode) { "The selected server upload mode changed" }
    }

    override fun uploadAudio() {
        val state = mutableState.value
        if (!state.isApplyingServerConnection && !state.isDownloading && !state.isUploading) {
            when (activeUploadMode()) {
                ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink, ServerUploadMode.ReviewedMatch -> {
                    mutableState.value = mutableState.value.copy(
                        errorMessage = "Use Import from Link so Resonance can preserve and register the direct source URL.",
                    )
                }
                null -> mutableState.value = mutableState.value.copy(
                    errorMessage = "Server uploads are disabled by the current server policy.",
                )
            }
        }
    }

    override fun uploadMissingDownloads() {
        if (mutableState.value.isApplyingServerConnection || mutableState.value.isDownloading || mutableState.value.isUploading) return
        if (activeUploadMode() != ServerUploadMode.LocalFile) {
            mutableState.value = mutableState.value.copy(
                errorMessage = "Downloaded-song source-link registration requires Preserved source link mode.",
            )
            return
        }
        val uploadSnapshot = currentUploadPolicySnapshot(ServerUploadMode.LocalFile) ?: return
        mutableState.value = mutableState.value.copy(
            isUploading = true,
            uploadProgress = 0f,
            uploadDetail = "Checking downloaded songs…",
            errorMessage = null,
        )
        viewModelScope.launch {
            var syncAfterUpload = false
            try {
                requireUploadPolicySnapshot(uploadSnapshot)
                val client = serverClient(uploadSnapshot.context)
                val plan = UploadMissingPolicy.plan(
                    tracks = library.tracks,
                    catalog = mutableState.value.remoteSongs,
                    activeProfileID = library.syncProfileID,
                    activeServerURL = client.baseURL,
                )
                plan.existingRemoteIDsByTrackID.forEach { (trackID, remoteID) ->
                    adoptUploadedDownload(trackID, remoteID, client.baseURL)
                }
                val tracksToUpload = plan.uploadTrackIDs.mapNotNull { id ->
                    library.tracks.firstOrNull { it.id == id }?.let { track -> track to repository.fileForTrack(track) }
                }
                val reviewCount = plan.reviewTrackIDs.size
                if (tracksToUpload.isEmpty()) {
                    persistLibrary()
                    mutableState.value = mutableState.value.copy(
                        serverMessage = if (reviewCount == 0) {
                            "All downloaded songs are already on the server"
                        } else {
                            "$reviewCount ambiguous song${if (reviewCount == 1) " needs" else "s need"} review"
                        },
                        uploadDetail = if (reviewCount == 0) "Nothing to upload" else "Review ambiguous matches before uploading",
                        uploadProgress = 1f,
                        isUploading = false,
                        errorMessage = if (reviewCount == 0) null else {
                            "Skipped $reviewCount song${if (reviewCount == 1) "" else "s"} because metadata alone cannot prove audio identity."
                        },
                    )
                    syncPlaylistsAutomatically()
                    refreshCatalogAfterUpload()
                    return@launch
                }

                val failures = mutableListOf<String>()
                var uploadedCount = 0
                tracksToUpload.forEachIndexed { index, (track, file) ->
                    mutableState.value = mutableState.value.copy(
                        uploadProgress = index.toFloat() / tracksToUpload.size,
                        uploadDetail = "Uploading ${index + 1} of ${tracksToUpload.size} • ${track.title}",
                    )
                    RemoteTrackIdentityPolicy.requireCanAssociate(track, client.baseURL, library.syncProfileID)
                    var uploadedID: String? = null
                    var lastError: Throwable? = null
                    repeat(3) { attempt ->
                        if (uploadedID == null) {
                            runCatching {
                                requireUploadPolicySnapshot(uploadSnapshot)
                                client.upload(track) {
                                    requireUploadPolicySnapshot(uploadSnapshot)
                                }
                            }
                                .onSuccess { uploadedID = it.id }
                                .onFailure { error ->
                                    if (error is CancellationException) throw error
                                    lastError = error
                                    if (attempt < 2) delay(if (attempt == 0) 400 else 1_200)
                                }
                        }
                    }
                    val resolvedUploadedID = uploadedID
                    if (resolvedUploadedID != null) {
                        uploadedCount += 1
                        // A 201/409 is already committed. Reconcile it without a
                        // post-request lease check, but never into a new context.
                        if (currentServerProfileContext() == uploadSnapshot.context) {
                            uploadMutationGeneration += 1
                            runCatching {
                                adoptUploadedDownload(track.id, resolvedUploadedID, client.baseURL)
                            }.onFailure(::showError)
                        }
                    } else {
                        val artist = track.artist.takeIf { it.isNotBlank() }?.let { " — $it" }.orEmpty()
                        failures += "“${track.title}”$artist (${lastError?.message ?: "upload failed"})"
                    }
                    mutableState.value = mutableState.value.copy(
                        uploadProgress = (index + 1).toFloat() / tracksToUpload.size,
                    )
                }
                persistLibrary()
                val failureNotice = failures.takeIf { it.isNotEmpty() }?.let {
                    "${it.size} song${if (it.size == 1) "" else "s"} failed to upload after retrying: ${it.joinToString("; ")}"
                }
                val reviewNotice = reviewCount.takeIf { it > 0 }?.let {
                    "Skipped $it ambiguous song${if (it == 1) "" else "s"} for review."
                }
                mutableState.value = mutableState.value.copy(
                    serverMessage = if (failureNotice == null) "Uploaded $uploadedCount missing song${if (uploadedCount == 1) "" else "s"}" else "Uploaded $uploadedCount; ${failures.size} failed",
                    uploadDetail = if (failureNotice == null && reviewNotice == null) "Upload complete" else "Upload completed with review items",
                    errorMessage = listOfNotNull(failureNotice, reviewNotice)
                        .joinToString(" ")
                        .takeIf(String::isNotBlank),
                )
                syncAfterUpload = true
            } catch (error: Throwable) {
                showError(error)
                mutableState.value = mutableState.value.copy(uploadDetail = "Upload failed: ${error.message ?: "Unknown error"}")
            } finally {
                mutableState.value = mutableState.value.copy(isUploading = false)
            }
            if (syncAfterUpload) {
                syncPlaylistsAutomatically()
                refreshCatalogAfterUpload()
            }
        }
    }

    fun uploadUris(uris: List<Uri>) {
        if (uris.isEmpty()) return
        mutableState.value = mutableState.value.copy(
            errorMessage = "File uploads are no longer accepted. Download a song from a link first, then upload its preserved source link.",
            uploadDetail = "Choose a link-downloaded song to upload",
        )
    }

    private fun refreshCatalogAfterUpload() {
        val (snapshot, client) = beginCatalogRequest() ?: return
        viewModelScope.launch {
            runCatching { client.fetchCatalog() }
                .onSuccess { catalog ->
                    if (CatalogResponsePolicy.shouldApply(
                            snapshot,
                            currentServerProfileContext(),
                            catalogRequestGeneration,
                            uploadMutationGeneration,
                        )
                    ) {
                        val songs = applyingKnownRemoteSongMetadata(catalog.songs)
                        mutableState.value = mutableState.value.copy(
                            remoteSongs = songs,
                        )
                        beginRemoteSongMetadataHydration(snapshot.context, client)
                    }
                }
        }
    }

    private fun adoptUploadedDownload(trackID: String, remoteID: String, serverURL: String) {
        val oldTrack = library.tracks.firstOrNull { it.id == trackID } ?: return
        val oldRemoteID = oldTrack.remoteID
        val oldClipKey = clipRangeKey(oldTrack)
        val updatedTrack = RemoteTrackIdentityPolicy.withAssociation(
            track = oldTrack,
            songID = remoteID,
            serverURL = serverURL,
            profileID = library.syncProfileID,
        )
        library = library.copy(tracks = library.tracks.map { if (it.id == trackID) updatedTrack else it })
        val changedPlaylists = library.playlists.filter {
            !it.isSystem && (trackID in it.trackIDs || oldRemoteID in it.remoteSongIDs.orEmpty())
        }.mapTo(mutableSetOf(), Playlist::id)
        val playlists = library.playlists.map { playlist ->
            if (playlist.id !in changedPlaylists) playlist else updateRemoteSongIds(playlist.copy(
                remoteSongIDs = playlist.remoteSongIDs.orEmpty().map { if (it == oldRemoteID) remoteID else it }.distinct(),
            ))
        }
        val remoteLikes = library.remoteLikedSongIDs.orEmpty().toMutableSet()
        val dirtyLikes = library.dirtyRemoteLikeSongIDs.orEmpty().toMutableSet()
        if (trackID in library.favorites) {
            oldRemoteID?.let { remoteLikes.remove(it); dirtyLikes.add(it) }
            remoteLikes.add(remoteID)
            dirtyLikes.add(remoteID)
            likesMutationGeneration += 1
        }
        val newClipKey = activeContextPrefix() + "|remote:$remoteID"
        val clipRanges = library.clipRanges.toMutableMap()
        val dirtyClipKeys = library.dirtyClipRangeKeys.toMutableSet()
        val deletedClipKeys = library.deletedClipRangeKeys.toMutableSet()
        if (oldClipKey != newClipKey) {
            clipRanges.remove(oldClipKey)?.let { clipRanges[newClipKey] = it }
            if (newClipKey in clipRanges) {
                dirtyClipKeys.add(newClipKey)
                if (oldRemoteID != null) {
                    dirtyClipKeys.add(oldClipKey)
                    deletedClipKeys.add(oldClipKey)
                }
                clipRangeMutationGeneration += 1
            }
        }
        library = library.copy(
            playlists = playlists,
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() + changedPlaylists,
            remoteLikedSongIDs = remoteLikes,
            dirtyRemoteLikeSongIDs = dirtyLikes,
            likesDirty = dirtyLikes.isNotEmpty(),
            clipRanges = clipRanges,
            dirtyClipRangeKeys = dirtyClipKeys,
            deletedClipRangeKeys = deletedClipKeys,
        )
        if (changedPlaylists.isNotEmpty()) playlistMutationGeneration += 1
    }

    override fun setLibrarySearch(query: String) {
        mutableState.value = mutableState.value.copy(librarySearch = query)
    }

    override fun playTrack(trackId: String, queueTrackIds: List<String>?, playlistId: String?) {
        val player = controller ?: return
        val visibleTracks = library.tracks.filter(::trackBelongsToActiveContext)
        val byID = QueuePolicy.indexByMediaID(visibleTracks, Track::id)
        val requested = queueTrackIds ?: visibleTracks.map(Track::id)
        val entries = QueuePolicy.assembleQueue(requested, byID) { mediaItem(it) }
        val index = entries.indexOfFirst { it.mediaID == trackId }
        if (index < 0) return
        clearActiveStreamPresentation()
        val items = entries.map { it.item }
        activeQueue = entries.map { it.mediaID }
        activePlaylistId = playlistId
        val start = byID.getValue(trackId).let(::playbackRange)?.startMs ?: 0L
        player.setMediaItems(items, index, start)
        player.prepare()
        player.play()
        refreshPlaybackState()
    }

    override fun togglePlayPause() {
        val player = controller ?: return
        if (player.mediaItemCount == 0) {
            library.tracks.firstOrNull(::trackBelongsToActiveContext)?.let { playTrack(it.id) }
        } else if (player.isPlaying) {
            player.pause()
        } else {
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } }
            if (track != null) {
                val range = playbackRange(track)
                if (range != null && player.currentPosition !in range.startMs until range.endMs) player.seekTo(range.startMs)
            }
            if (player.playerError != null || player.playbackState == Player.STATE_IDLE) player.prepare()
            player.play()
        }
    }

    override fun playNext() {
        if (activeStreamPresentation != null) return
        controller?.seekToNextMediaItem()
    }

    override fun playPrevious() {
        if (activeStreamPresentation != null) return
        controller?.let { player ->
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } }
            val start = track?.let(::playbackRange)?.startMs ?: 0L
            if (player.currentPosition > start + 3_000) player.seekTo(start) else player.seekToPreviousMediaItem()
        }
    }

    override fun seekToFraction(fraction: Float) {
        controller?.let { player ->
            val currentID = player.currentMediaItem?.mediaId ?: return
            val track = library.tracks.firstOrNull { it.id == currentID }
            val range = track?.let(::playbackRange)
                ?: activeStreamPresentation
                    ?.takeIf { it.id == currentID }
                    ?.durationMs
                    ?.takeIf { it > 0L }
                    ?.let { ClipRange(0L, it) }
                ?: player.duration
                    .takeIf { it != C.TIME_UNSET && it > 0L }
                    ?.let { ClipRange(0L, it) }
                ?: return
            player.seekTo(range.startMs + (range.durationMs * fraction.coerceIn(0f, 1f)).toLong())
        }
    }

    override fun setShuffleEnabled(enabled: Boolean) {
        if (activeStreamPresentation != null) return
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
        controller?.volume = PlaybackVolumePolicy.gainForSlider(clamped)
        mutableState.value = mutableState.value.copy(volume = clamped)
        preferences.edit().putFloat("volume", clamped).apply()
    }

    override fun toggleFavorite(trackId: String) {
        if (library.tracks.none { it.id == trackId && trackBelongsToActiveContext(it) }) return
        val favorites = if (trackId in library.favorites) library.favorites - trackId else library.favorites + trackId
        val remoteID = library.tracks.firstOrNull { it.id == trackId }
            ?.takeIf(::trackBelongsToActiveContext)
            ?.remoteID
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
            reconcilePlaybackQueueAfterDeletion(trackIds)
            val clipKeys = library.tracks
                .filter { it.id in trackIds }
                .mapTo(linkedSetOf(), ::clipRangeKey)
            library = repository.deleteLocalTracks(library, trackIds)
            library = library.copy(
                clipRanges = library.clipRanges - clipKeys,
                dirtyClipRangeKeys = library.dirtyClipRangeKeys - clipKeys,
                deletedClipRangeKeys = library.deletedClipRangeKeys - clipKeys,
            )
            persistLibrary()
        }
    }

    override fun saveClipRange(trackId: String, startMs: Long, endMs: Long) {
        val track = library.tracks.firstOrNull { it.id == trackId } ?: return
        val duration = track.durationMs.takeIf { it > 0L } ?: return
        val start = startMs.coerceIn(0L, duration)
        val end = endMs.coerceIn(0L, duration)
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
        playlistMutationGeneration += 1
        saveAndScheduleSync()
    }

    override fun deletePlaylist(playlistId: String) {
        val playlist = library.playlists.firstOrNull { it.id == playlistId && !it.isSystem } ?: return
        library = library.copy(
            playlists = library.playlists.filterNot { it.id == playlistId },
            dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() - playlistId,
            deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty() + playlist.id,
        )
        playlistMutationGeneration += 1
        if (activePlaylistId == playlistId) activePlaylistId = null
        saveAndScheduleSync()
    }

    override fun playPlaylist(playlistId: String) {
        val playlist = library.playlists.firstOrNull { it.id == playlistId } ?: return
        val visibleIDs = library.tracks
            .filter(::trackBelongsToActiveContext)
            .mapTo(hashSetOf(), Track::id)
        val ids = QueuePolicy.retainAvailable(playlist.trackIDs, visibleIDs)
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
        playlistMutationGeneration += 1
        if (activePlaylistId == playlistId) activeQueue = changed.trackIDs
        saveAndScheduleSync()
    }

    override fun onServerScreenOpened() {
        if (activeAccessToken().isNotBlank()) refreshServer()
        else if (activeAdminToken().isNotBlank()) refreshClientConfig()
    }

    override fun refreshServer() {
        refreshClientConfig()
        if (mutableState.value.isRefreshingServer) return
        viewModelScope.launch { refreshServerNow() }
    }

    private fun refreshClientConfig() {
        val context = currentServerProfileContext() ?: run {
            resetClientConfigForCurrentContext()
            return
        }
        if (activeAccessToken().isBlank() && activeAdminToken().isBlank()) {
            resetClientConfigForCurrentContext()
            return
        }
        val requestGeneration = ++clientConfigRequestGeneration
        val client = serverClient(context)
        val cohortKey = clientConfigStore.cohortKey
        viewModelScope.launch {
            val fetched = runCatching { client.fetchClientConfig(cohortKey) }
            if (
                requestGeneration != clientConfigRequestGeneration ||
                currentServerProfileContext() != context
            ) return@launch
            fetched.onSuccess { result ->
                when (result) {
                    is ClientConfigFetchResult.Verified -> {
                        val receivedAt = Instant.now()
                        if (!result.config.isActive(receivedAt)) {
                            runCatching { clientConfigStore.removeEnvelope(result.cacheScope) }
                            applyClientConfig(
                                EffectiveClientConfig.safeDefaults(),
                                "Safe defaults • server policy expired in transit",
                            )
                            return@onSuccess
                        }
                        val highestRevision = clientConfigStore.readHighestVerifiedRevision(result.cacheScope)
                        if (!ClientConfigRevisionPolicy.accepts(highestRevision, result.config.revision)) {
                            runCatching { clientConfigStore.removeEnvelope(result.cacheScope) }
                            applyClientConfig(
                                EffectiveClientConfig.safeDefaults(),
                                "Safe defaults • lower server policy revision rejected",
                            )
                            return@onSuccess
                        }
                        clientConfigStore.writeEnvelope(
                            result.cacheScope,
                            result.envelope,
                            result.config.revision,
                            receivedAt.toEpochMilli(),
                        )
                        applyClientConfig(result.config, "Server policy r${result.config.revision}")
                    }
                    ClientConfigFetchResult.Unsupported -> {
                        runCatching { clientConfigStore.removeEnvelope(client.clientConfigCacheScope()) }
                        applyClientConfig(EffectiveClientConfig.safeDefaults(), "Safe defaults • server does not publish policy")
                    }
                }
            }.onFailure { error ->
                val fallbackAt = Instant.now()
                val cacheEligible = ClientConfigCacheFallbackPolicy.mayUseFreshCache(error)
                val rejected = !cacheEligible
                if (rejected) {
                    runCatching { clientConfigStore.removeEnvelope(client.clientConfigCacheScope()) }
                }
                val cached = if (!cacheEligible) null else {
                    val scope = client.clientConfigCacheScope()
                    val entry = clientConfigStore.readEnvelope(scope)
                    when {
                        entry == null -> null
                        !entry.isWithinLocalAge(fallbackAt.toEpochMilli()) -> {
                            runCatching { clientConfigStore.removeEnvelope(scope) }
                            null
                        }
                        else -> runCatching {
                            client.verifyCachedClientConfig(entry.envelope, cohortKey, fallbackAt).also { verified ->
                                check(
                                    ClientConfigRevisionPolicy.accepts(
                                        clientConfigStore.readHighestVerifiedRevision(scope),
                                        verified.revision,
                                    ),
                                ) { "The cached client config revision was rolled back" }
                            }
                        }.onFailure {
                            runCatching { clientConfigStore.removeEnvelope(scope) }
                        }.getOrNull()
                    }
                }
                if (cached != null) {
                    applyClientConfig(cached, "Cached server policy r${cached.revision}")
                } else {
                    applyClientConfig(
                        EffectiveClientConfig.safeDefaults(),
                        if (rejected) {
                            "Safe defaults • server policy rejected"
                        } else {
                            "Safe defaults • server policy unavailable"
                        },
                    )
                }
            }
        }
    }

    private fun resetClientConfigForCurrentContext(status: String = "Safe defaults") {
        clientConfigRequestGeneration += 1
        applyClientConfig(EffectiveClientConfig.safeDefaults(), status)
    }

    private fun applyClientConfig(config: EffectiveClientConfig, status: String) {
        val context = currentServerProfileContext()
        val preferred = context?.let {
            clientConfigStore.readTransferModes(
                ServerClient.canonicalServerOrigin(it.serverURL),
                it.profileID,
            )
        }
        val resolved = ServerTransferModePolicy.resolve(
            config = config,
            preferredUpload = preferred?.uploadMode,
            preferredDownload = preferred?.downloadMode,
        )
        if (activeStreamPresentation != null) {
            val now = Instant.now()
            val expiresAt = config.expiresAt
            val renewalFloor = pendingStreamRenewalMinimumExpiry
            val streamContext = activeStreamPolicyContext
            val currentStreamExpiry =
                AuthenticatedStreamRegistry.authorizationExpiresAt(activeStreamHandle?.id)
            val canApplySignedLease =
                context != null &&
                    context == streamContext &&
                    resolved.downloadMode == ServerDownloadMode.StreamOnly &&
                    config.source != ClientConfigSource.SafeDefaults &&
                    config.isActive(now) &&
                    expiresAt != null &&
                    currentStreamExpiry != null
            val leaseDecision = if (canApplySignedLease) {
                StreamLeaseUpdatePolicy.decide(
                    current = requireNotNull(currentStreamExpiry),
                    signed = requireNotNull(expiresAt),
                    proactiveRenewal = renewalFloor != null,
                )
            } else null
            val renewed = leaseDecision != null && AuthenticatedStreamRegistry.renew(
                id = activeStreamHandle?.id,
                baseURL = serverClient(requireNotNull(context)).baseURL,
                accessToken = activeAccessToken(),
                profileID = context.profileID,
                cohortKey = clientConfigStore.cohortKey,
                authorizationExpiresAt = requireNotNull(expiresAt),
            )
            if (renewed) {
                if (requireNotNull(leaseDecision).clearPendingRenewalFloor) {
                    pendingStreamRenewalMinimumExpiry = null
                }
                // Earlier policy shortens, equal policy retains/retries, and
                // later policy extends the shared hard deadline.
                scheduleActiveStreamRenewal(requireNotNull(expiresAt))
            } else {
                stopActiveStream(
                    if (renewalFloor == null) {
                        "The server stream stopped because its policy or connection changed."
                    } else {
                        "The server stream stopped because its policy could not be renewed."
                    },
                )
            }
        }
        activeDownloadPolicySnapshot?.let { snapshot ->
            val now = Instant.now()
            if (
                context != snapshot.context ||
                config != snapshot.config ||
                resolved.downloadMode != snapshot.mode ||
                !config.isActive(now)
            ) {
                remoteDownloadJob?.cancel()
            }
        }
        mutableState.value = mutableState.value.copy(
            clientConfig = config,
            clientConfigStatus = status,
            serverUploadMode = resolved.uploadMode,
            serverDownloadMode = resolved.downloadMode,
        )
    }

    private fun scheduleActiveStreamRenewal(authorizationExpiresAt: Instant) {
        streamConfigRenewalJob?.cancel()
        streamLeaseExpiryJob?.cancel()
        val remainingMillis = authorizationExpiresAt.toEpochMilli() - Instant.now().toEpochMilli()
        if (remainingMillis <= 0L) {
            stopActiveStream("The server stream stopped because its policy expired.")
            return
        }
        val renewalLeadMillis = minOf(60_000L, maxOf(5_000L, remainingMillis / 3L))
        val refreshDelayMillis = (remainingMillis - renewalLeadMillis)
            .coerceAtLeast(1_000L)
            .coerceAtMost(remainingMillis)
        val scheduledHandleID = activeStreamHandle?.id
        streamLeaseExpiryJob = viewModelScope.launch {
            delay(remainingMillis + 1L)
            if (
                activeStreamHandle?.id == scheduledHandleID &&
                AuthenticatedStreamRegistry.authorizationExpiresAt(scheduledHandleID) == null
            ) {
                stopActiveStream("The server stream stopped because its policy expired.")
            }
        }
        streamConfigRenewalJob = viewModelScope.launch {
            delay(refreshDelayMillis)
            val currentExpiry = AuthenticatedStreamRegistry.authorizationExpiresAt(activeStreamHandle?.id)
            if (activeStreamPresentation != null && currentExpiry != null) {
                pendingStreamRenewalMinimumExpiry = currentExpiry
                refreshClientConfig()
            } else if (activeStreamPresentation != null) {
                stopActiveStream("The server stream stopped because its policy expired.")
            }
        }
    }

    private fun expireClientConfigIfNeeded() {
        val config = mutableState.value.clientConfig
        if (config.source != ClientConfigSource.SafeDefaults && !config.isActive(Instant.now())) {
            resetClientConfigForCurrentContext("Safe defaults • server policy expired")
        }
    }

    override fun setServerUploadMode(mode: ServerUploadMode) {
        val state = mutableState.value
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            mode,
            state.serverDownloadMode,
        )
        if (resolved.uploadMode != mode) return
        if (state.serverUploadMode != mode && state.linkImport.isRunning) linkImportJob?.cancel()
        mutableState.value = state.copy(serverUploadMode = mode)
        persistServerTransferModes()
    }

    override fun setServerDownloadMode(mode: ServerDownloadMode) {
        val state = mutableState.value
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            state.serverUploadMode,
            mode,
        )
        if (resolved.downloadMode != mode) return
        if (mode != ServerDownloadMode.StreamOnly && activeStreamPresentation != null) {
            stopActiveStream("The server stream stopped because the download mode changed.")
        }
        if (activeDownloadPolicySnapshot?.mode != null && activeDownloadPolicySnapshot?.mode != mode) {
            remoteDownloadJob?.cancel()
        }
        mutableState.value = mutableState.value.copy(serverDownloadMode = mode)
        persistServerTransferModes()
    }

    private fun persistServerTransferModes() {
        val context = currentServerProfileContext() ?: return
        val state = mutableState.value
        clientConfigStore.writeTransferModes(
            origin = ServerClient.canonicalServerOrigin(context.serverURL),
            profileID = context.profileID,
            uploadMode = state.serverUploadMode,
            downloadMode = state.serverDownloadMode,
        )
    }

    private suspend fun refreshServerNow() {
        val (catalogSnapshot, client) = beginCatalogRequest() ?: return
        mutableState.value = mutableState.value.copy(isRefreshingServer = true, serverMessage = "Connecting…")
        runCatching {
            coroutineScope {
                val profiles = async { client.fetchProfiles() }
                val catalog = async { client.fetchCatalog() }
                catalog.await() to profiles.await()
            }
        }
            .onSuccess { (catalog, profiles) ->
                if (currentServerProfileContext() != catalogSnapshot.context) return@onSuccess
                val applyCatalog = CatalogResponsePolicy.shouldApply(
                    catalogSnapshot,
                    currentServerProfileContext(),
                    catalogRequestGeneration,
                    uploadMutationGeneration,
                )
                library = library.copy(syncProfiles = profiles.profiles)
                val catalogSongs = applyingKnownRemoteSongMetadata(catalog.songs)
                mutableState.value = mutableState.value.copy(
                    remoteSongs = if (applyCatalog) catalogSongs else mutableState.value.remoteSongs,
                    syncProfiles = profiles.profiles,
                    serverMessage = if (applyCatalog) {
                        "Connected • ${catalog.count} song${if (catalog.count == 1) "" else "s"}"
                    } else {
                        "Connected"
                    },
                )
                if (applyCatalog) {
                    beginRemoteSongMetadataHydration(catalogSnapshot.context, client)
                }
                if (applyCatalog && backfillDownloadedArtwork(client, catalogSongs)) {
                    persistLibrary()
                } else {
                    saveSoon()
                }
                syncPlaylistsNow()
            }
            .onFailure { error ->
                if (currentServerProfileContext() != catalogSnapshot.context) return@onFailure
                mutableState.value = mutableState.value.copy(
                    serverMessage = error.message ?: "Connection failed",
                    errorMessage = error.message.takeUnless { mutableState.value.isApplyingServerConnection },
                )
            }
        mutableState.value = mutableState.value.copy(isRefreshingServer = false)
    }

    private fun applyingKnownRemoteSongMetadata(songs: List<RemoteSong>): List<RemoteSong> {
        val localTracksByRemoteID = library.tracks.asSequence()
            .filter(::trackBelongsToActiveContext)
            .mapNotNull { track -> track.remoteID?.let { it to track } }
            .distinctBy { it.first }
            .toMap()
        return songs.map { song ->
            if (!song.isMetadataLoading) return@map song
            localTracksByRemoteID[song.id]?.let { local ->
                return@map song.copy(
                    title = local.title,
                    artist = local.artist,
                    album = local.album,
                    durationSeconds = local.durationMs.takeIf { it > 0 }?.div(1_000.0),
                    isMetadataLoading = false,
                )
            }
            val key = remoteSongMetadataCacheKey(song)
                ?: return@map applyRemoteSongMetadataFailure(song)
            library.remoteSongMetadataCache[key]?.let { cached ->
                return@map applyRemoteSongMetadata(song, cached)
            }
            remoteSourceResolutions[key]
                ?.takeIf { it.kind == LinkImportKind.Track }
                ?.track
                ?.let { return@map applyRemoteSongMetadata(song, it) }
            song
        }
    }

    private fun beginRemoteSongMetadataHydration(
        context: ServerProfileContext,
        client: ServerClient,
    ) {
        cancelRemoteSongMetadataHydration()
        val requests = remoteSongMetadataRequests(mutableState.value.remoteSongs)

        remoteSongMetadataHydrationGeneration += 1
        val generation = remoteSongMetadataHydrationGeneration
        remoteSongMetadataHydrationJob = viewModelScope.launch {
            var cacheChanged = false
            for (batch in requests.chunked(4)) {
                val results = coroutineScope {
                    batch.map { request ->
                        async {
                            val metadata = runCatching {
                                linkImportService.resolveMetadata(request.source)
                            }.getOrNull()
                            RemoteSongMetadataResult(request, metadata)
                        }
                    }.awaitAll()
                }
                if (!isCurrentRemoteSongMetadataHydration(generation, context)) return@launch

                var songs = mutableState.value.remoteSongs
                results.forEach { result ->
                    val songIDs = result.request.songIDs.toSet()
                    songs = songs.map { song ->
                        if (song.id !in songIDs || !song.isMetadataLoading) return@map song
                        result.metadata?.let { applyRemoteSongMetadata(song, it) }
                            ?: applyRemoteSongMetadataFailure(song)
                    }
                    result.metadata?.let { metadata ->
                        library = library.copy(
                            remoteSongMetadataCache = library.remoteSongMetadataCache + (
                                result.request.cacheKey to RemoteSongMetadataCacheEntry(
                                    sourceURL = result.request.source,
                                    mediaKind = result.request.mediaKind,
                                    title = metadata.title,
                                    artist = metadata.artist,
                                    album = metadata.album,
                                    durationSeconds = metadata.durationSeconds?.toDouble(),
                                    artworkURL = metadata.artworkURL,
                                    cachedAtEpochMs = System.currentTimeMillis(),
                                )
                            ),
                        )
                        cacheChanged = true
                    }
                }
                mutableState.value = mutableState.value.copy(remoteSongs = songs)
            }

            if (!isCurrentRemoteSongMetadataHydration(generation, context)) return@launch
            val artworkChanged = backfillDownloadedArtwork(client, mutableState.value.remoteSongs)
            if (cacheChanged || artworkChanged) {
                library = library.copy(
                    remoteSongMetadataCache = RemoteSongMetadataCachePolicy.normalized(
                        library.remoteSongMetadataCache,
                    ),
                )
                persistLibrary()
            }
            if (remoteSongMetadataHydrationGeneration == generation) {
                remoteSongMetadataHydrationJob = null
            }
        }
    }

    private fun remoteSongMetadataRequests(songs: List<RemoteSong>): List<RemoteSongMetadataRequest> {
        val requests = mutableListOf<RemoteSongMetadataRequest>()
        val requestIndexByKey = mutableMapOf<String, Int>()
        songs.filter(RemoteSong::isMetadataLoading).forEach { song ->
            val source = song.sourceURL?.trim().orEmpty()
            val key = remoteSongMetadataCacheKey(song) ?: return@forEach
            val existingIndex = requestIndexByKey[key]
            if (existingIndex == null) {
                requestIndexByKey[key] = requests.size
                requests += RemoteSongMetadataRequest(listOf(song.id), key, source, song.mediaKind)
            } else {
                val existing = requests[existingIndex]
                requests[existingIndex] = existing.copy(songIDs = existing.songIDs + song.id)
            }
        }
        return requests
    }

    private fun remoteSongMetadataCacheKey(song: RemoteSong): String? =
        song.sourceURL?.let { RemoteSongMetadataCachePolicy.key(it, song.mediaKind) }

    private fun isCurrentRemoteSongMetadataHydration(
        generation: Long,
        context: ServerProfileContext,
    ): Boolean = generation == remoteSongMetadataHydrationGeneration &&
        currentServerProfileContext() == context

    private fun cancelRemoteSongMetadataHydration() {
        remoteSongMetadataHydrationJob?.cancel()
        remoteSongMetadataHydrationJob = null
        remoteSongMetadataHydrationGeneration += 1
    }

    private fun applyRemoteSongMetadata(song: RemoteSong, metadata: LinkImportTrack): RemoteSong = song.copy(
        title = metadata.title,
        artist = metadata.artist,
        album = metadata.album ?: "Imported",
        durationSeconds = metadata.durationSeconds?.toDouble(),
        artworkURL = metadata.artworkURL,
        isMetadataLoading = false,
    )

    private fun applyRemoteSongMetadata(
        song: RemoteSong,
        metadata: RemoteSongMetadataCacheEntry,
    ): RemoteSong = song.copy(
        title = metadata.title,
        artist = metadata.artist,
        album = metadata.album ?: "Imported",
        durationSeconds = metadata.durationSeconds,
        artworkURL = metadata.artworkURL,
        isMetadataLoading = false,
    )

    private fun applyRemoteSongMetadataFailure(song: RemoteSong): RemoteSong = song.copy(
        title = if (song.requiresOriginalSourcePage) "Original source link needed" else "Metadata unavailable",
        artist = if (song.requiresOriginalSourcePage) "Re-import on the original device" else "Refresh to retry",
        album = if (song.requiresOriginalSourcePage) "Legacy expired link" else "Link only",
        isMetadataLoading = false,
    )

    private suspend fun backfillDownloadedArtwork(
        client: ServerClient,
        songs: List<RemoteSong>,
    ): Boolean {
        val songsByID = songs.associateBy(RemoteSong::id)
        val updatedTracks = ArrayList<Track>(library.tracks.size)
        var changed = false

        for (track in library.tracks) {
            val existingArtwork = repository.artworkFile(track)?.takeIf(File::isFile)
            val song = track.takeIf(::trackBelongsToActiveContext)?.remoteID?.let(songsByID::get)
            if (!trackBelongsToActiveContext(track)
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
        val state = mutableState.value
        if (state.isApplyingServerConnection || state.isRefreshingServer || state.isDownloading || state.isUploading || state.isSyncingPlaylists) {
            mutableState.value = state.copy(serverMessage = "Wait for the current connection or transfer to finish.")
            return
        }
        val normalized = runCatching { ServerClient.normalizeServerURL(url) }.getOrElse { showError(it); return }
        val normalizedProfileName = accountSession?.profileDisplayName ?: normalizeProfileName(profileName)
        if (normalizedProfileName.isEmpty()) {
            mutableState.value = mutableState.value.copy(serverMessage = "Enter a profile name.")
            return
        }
        val serverChanged = runCatching {
            ServerClient.normalizeServerURL(credentials.serverURL) != normalized
        }.getOrDefault(true)
        val previousServerURL = credentials.serverURL
        val previousAccessToken = accountSession?.accessToken ?: credentials.clientToken
        val previousAdminKey = accountSession?.accessToken ?: credentials.adminToken
        val previousRemoteSongs = state.remoteSongs
        val previousSelection = state.selectedRemoteSongIds
        connectionGeneration += 1
        resetClientConfigForCurrentContext("Safe defaults • connection changed")
        library = ProfileLibraryStatePolicy.captureActive(library)
        val previousLibrary = library
        if (accessToken.isBlank()) {
            credentials.serverURL = normalized
            credentials.clientToken = accessToken
            credentials.adminToken = adminKey
            library = normalizeLiked(ProfileLibraryStatePolicy.restoreContext(
                library,
                normalized,
                library.syncProfileID,
            ))
            activePlaylistId = null
            rebuildPlaybackQueueForActiveContext()
            mutableState.value = mutableState.value.copy(
                serverUrl = normalized,
                serverToken = "",
                serverAdminKey = adminKey,
                remoteSongs = if (serverChanged) emptyList() else mutableState.value.remoteSongs,
                selectedRemoteSongIds = emptySet(),
                isApplyingServerConnection = false,
                serverMessage = "Server saved • sign in to connect",
                errorMessage = null,
            )
            resetClientConfigForCurrentContext()
            if (adminKey.isNotBlank()) refreshClientConfig()
            saveSoon()
            return
        }
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
                val client = ServerClient(
                    normalized,
                    accessToken,
                    adminKey,
                    library.syncProfileID,
                    clientConfigStore.cohortKey,
                )
                val activeAccount = accountSession
                val response = if (activeAccount == null) client.fetchProfiles() else null
                val profile = if (activeAccount?.profileID != null) {
                    SyncProfile(
                        id = activeAccount.profileID,
                        name = activeAccount.profileDisplayName,
                        isDefault = true,
                    )
                } else {
                    response!!.profiles.firstOrNull {
                        it.id == normalizedProfileName || it.name.equals(normalizedProfileName, ignoreCase = true)
                    } ?: client.createProfile(normalizedProfileName)
                }
                val profiles = if (activeAccount != null) {
                    listOf(profile)
                } else {
                    (response!!.profiles + profile).distinctBy { it.id }
                }
                credentials.serverURL = normalized
                if (accountSession == null) {
                    credentials.clientToken = accessToken
                    credentials.adminToken = adminKey
                } else {
                    credentials.clearTokens()
                }
                library = library.copy(syncProfiles = profiles)
                activateProfile(profile.id, normalized, currentAlreadyCaptured = true)
                resetClientConfigForCurrentContext()
                persistLibrary()
            }
                .onSuccess {
                    refreshClientConfig()
                    refreshServerNow()
                }
                .onFailure { error ->
                    credentials.serverURL = previousServerURL
                    if (accountSession == null) {
                        credentials.clientToken = previousAccessToken
                        credentials.adminToken = previousAdminKey
                    } else {
                        credentials.clearTokens()
                    }
                    library = previousLibrary
                    rebuildPlaybackQueueForActiveContext()
                    refreshLibraryState()
                    mutableState.value = mutableState.value.copy(
                        serverUrl = previousServerURL,
                        serverToken = previousAccessToken,
                        serverAdminKey = previousAdminKey,
                        remoteSongs = previousRemoteSongs,
                        selectedRemoteSongIds = previousSelection,
                        serverMessage = "Could not activate profile: ${error.message ?: "Unknown error"}",
                    )
                    resetClientConfigForCurrentContext()
                }
            mutableState.value = mutableState.value.copy(isApplyingServerConnection = false)
        }
    }

    private fun activateProfile(
        profileId: String,
        serverURL: String = credentials.serverURL,
        currentAlreadyCaptured: Boolean = false,
    ) {
        if (profileId.isBlank()) return
        val sameContext = RemoteTrackIdentityPolicy.normalizedOrigin(library.serverURL) ==
            RemoteTrackIdentityPolicy.normalizedOrigin(serverURL) && profileId == library.syncProfileID
        if (sameContext) return
        connectionGeneration += 1
        val captured = if (currentAlreadyCaptured) library else ProfileLibraryStatePolicy.captureActive(library)
        library = normalizeLiked(ProfileLibraryStatePolicy.restoreContext(captured, serverURL, profileId))
        playlistMutationGeneration += 1
        likesMutationGeneration += 1
        clipRangeMutationGeneration += 1
        activePlaylistId = null
        rebuildPlaybackQueueForActiveContext()
        refreshLibraryState()
        mutableState.value = mutableState.value.copy(
            syncProfileId = profileId,
            remoteSongs = emptyList(),
            selectedRemoteSongIds = emptySet(),
        )
        resetClientConfigForCurrentContext("Safe defaults • profile changed")
    }

    override fun downloadRemoteSong(songId: String) { downloadSongs(setOf(songId)) }
    override fun downloadSelectedRemoteSongs() {
        val state = mutableState.value
        if (activeDownloadMode() == ServerDownloadMode.StreamOnly) {
            val selectedID = state.selectedRemoteSongIds.singleOrNull()
            if (selectedID == null) {
                mutableState.value = mutableState.value.copy(
                    downloadDetail = "Select one server song to stream",
                    errorMessage = "Stream-only mode plays one selected song and never adds a library file.",
                )
                return
            }
            downloadSongs(setOf(selectedID))
            return
        }
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
        if (ids.isEmpty() || mutableState.value.isApplyingServerConnection || mutableState.value.isDownloading || mutableState.value.isUploading) return
        val requestedMode = activeDownloadMode()
        if (requestedMode == ServerDownloadMode.StreamOnly) {
            val songID = ids.singleOrNull()
            if (songID == null) {
                mutableState.value = mutableState.value.copy(
                    errorMessage = "Stream-only mode can play one server song at a time.",
                )
                return
            }
            streamRemoteSong(songID)
            return
        }
        val transferContext = currentServerProfileContext() ?: return
        val snapshot = ServerDownloadPolicySnapshot(
            context = transferContext,
            config = mutableState.value.clientConfig,
            mode = requestedMode,
        )
        runCatching { requireDownloadPolicySnapshot(snapshot) }.onFailure {
            mutableState.value = mutableState.value.copy(
                errorMessage = "The server download policy changed; review the mode and try again.",
            )
            return
        }
        mutableState.value = mutableState.value.copy(isDownloading = true, downloadProgress = 0f)
        activeDownloadPolicySnapshot = snapshot
        cancelRemoteSongMetadataHydration()
        remoteDownloadJob?.cancel()
        remoteDownloadExpiryJob?.cancel()
        val downloadClient = serverClient(transferContext)
        val job = viewModelScope.launch {
            try {
                val requestedSongs = mutableState.value.remoteSongs.filter { it.id in ids }
                val sourceSongs = requestedSongs.filter(RemoteSong::isSourceLinkRecord)
                var sourceDownloads = 0
                var sourceProcessed = 0
                val sourceFailures = mutableListOf<String>()
                val downloadedRemoteIDs = mutableSetOf<String>()
                if (sourceSongs.isNotEmpty()) {
                    try {
                        val sourceGroups = sourceSongs
                            .filterNot(RemoteSong::isVideoMedia)
                            .chunked(2) + sourceSongs.filter(RemoteSong::isVideoMedia).chunked(1)
                        for (group in sourceGroups) {
                            val completedBeforeGroup = sourceProcessed
                            val groupProgress = FloatArray(group.size)
                            val groupProgressLock = Any()
                            val results = coroutineScope {
                                group.mapIndexed { groupIndex, song ->
                                    async {
                                        requireDownloadPolicySnapshot(snapshot)
                                        try {
                                            val source = requireNotNull(song.sourceURL)
                                            val mediaMode = if (song.isVideoMedia) {
                                                LinkImportMediaMode.Video
                                            } else {
                                                LinkImportMediaMode.Audio
                                            }
                                            val key = "${song.mediaKind}:$source"
                                            val resolution = remoteSourceResolutions[key]
                                                ?: linkImportService.resolve(source, mediaMode) { }
                                                    .also { remoteSourceResolutions[key] = it }
                                            check(resolution.kind == LinkImportKind.Track) {
                                                "A saved song link resolved to a playlist instead of one song."
                                            }
                                            val track = downloadLinkTrack(
                                                metadata = resolution.track,
                                                candidates = resolution.candidates,
                                                mediaMode = mediaMode,
                                                completedBefore = completedBeforeGroup + groupIndex,
                                                total = requestedSongs.size,
                                                deferArtwork = true,
                                                persistImmediately = false,
                                                batchProgress = { fraction ->
                                                    synchronized(groupProgressLock) {
                                                        groupProgress[groupIndex] = fraction
                                                        mutableState.update { state -> state.copy(
                                                            downloadProgress = (completedBeforeGroup + groupProgress.sum()) /
                                                                requestedSongs.size.coerceAtLeast(1),
                                                            downloadDetail = "Downloading ${completedBeforeGroup + groupIndex + 1} of ${requestedSongs.size} • ${resolution.track.title}",
                                                        ) }
                                                    }
                                                },
                                            )
                                            requireDownloadPolicySnapshot(snapshot)
                                            adoptUploadedDownload(track.id, song.id, transferContext.serverURL)
                                            RemoteSourceDownloadResult(remoteID = song.id)
                                        } catch (error: CancellationException) {
                                            throw error
                                        } catch (error: Throwable) {
                                            // A changed policy or profile is a batch interruption,
                                            // not an item-level failure that should be skipped.
                                            requireDownloadPolicySnapshot(snapshot)
                                            RemoteSourceDownloadResult(
                                                failure = "${song.title}: ${error.message ?: "download failed"}",
                                            )
                                        }
                                    }
                                }.awaitAll()
                            }
                            results.forEach { result ->
                                result.remoteID?.let {
                                    downloadedRemoteIDs += it
                                    sourceDownloads += 1
                                }
                                result.failure?.let(sourceFailures::add)
                            }
                            sourceProcessed += results.size
                        }
                    } finally {
                        // Source imports, provenance, and remote associations are
                        // checkpointed once for the batch (also on cancellation).
                        persistLibrary()
                    }
                }
                val catalog = mov.unblocked.resonance.data.RemoteCatalog(
                    requestedSongs.filterNot(RemoteSong::isSourceLinkRecord),
                )
                val result = downloadClient.downloadSelected(
                    catalog = catalog,
                    selectedIDs = catalog.songs.mapTo(mutableSetOf(), RemoteSong::id),
                    repository = repository,
                    existingRemoteIDs = library.tracks
                        .filter(::trackBelongsToActiveContext)
                        .mapNotNullTo(mutableSetOf(), Track::remoteID),
                    onProgress = { progress ->
                        mutableState.update { state -> state.copy(
                            downloadProgress = (sourceProcessed + progress.completed).toFloat() /
                                requestedSongs.size.coerceAtLeast(1),
                            downloadDetail = "Downloading ${(sourceProcessed + progress.completed).coerceAtMost(requestedSongs.size)} of ${requestedSongs.size} • ${progress.currentFilename}",
                        ) }
                    },
                    beforeEach = { requireDownloadPolicySnapshot(snapshot) },
                )
                requireDownloadPolicySnapshot(snapshot)
                downloadedRemoteIDs += result.tracks.mapNotNull(Track::remoteID)
                library = hydrateRemoteLikes(hydrateRemotePlaylists(
                    library.copy(tracks = library.tracks + result.tracks),
                ))
                persistLibrary()
                val downloadedCount = sourceDownloads + result.tracks.size
                val failedCount = sourceFailures.size + result.failures.size
                val detail = if (failedCount == 0) {
                    "Downloaded $downloadedCount song${if (downloadedCount == 1) "" else "s"}"
                } else {
                    "Downloaded $downloadedCount of ${requestedSongs.size} • $failedCount failed"
                }
                mutableState.value = mutableState.value.copy(
                    selectedRemoteSongIds = mutableState.value.selectedRemoteSongIds - downloadedRemoteIDs,
                    downloadDetail = detail,
                    errorMessage = if (failedCount == 0) null else {
                        (sourceFailures + result.failures.map { "${it.filename}: ${it.message}" })
                            .take(4)
                            .joinToString("; ")
                    },
                )
                syncPlaylistsNow()
            } catch (_: CancellationException) {
                mutableState.value = mutableState.value.copy(
                    downloadDetail = "Download stopped because the server policy or connection changed",
                )
            } catch (error: Throwable) {
                showError(error)
            } finally {
                if (activeDownloadPolicySnapshot == snapshot) {
                    activeDownloadPolicySnapshot = null
                    remoteDownloadExpiryJob?.cancel()
                    remoteDownloadExpiryJob = null
                    mutableState.value = mutableState.value.copy(isDownloading = false)
                    if (currentServerProfileContext() == transferContext) {
                        beginRemoteSongMetadataHydration(transferContext, downloadClient)
                    }
                }
            }
        }
        remoteDownloadJob = job
        job.invokeOnCompletion {
            if (remoteDownloadJob === job) remoteDownloadJob = null
        }
        snapshot.config.expiresAt?.let { expiry ->
            remoteDownloadExpiryJob = viewModelScope.launch {
                delay((expiry.toEpochMilli() - Instant.now().toEpochMilli()).coerceAtLeast(0L) + 1L)
                if (activeDownloadPolicySnapshot == snapshot) expireClientConfigIfNeeded()
            }
        }
    }

    private fun requireDownloadPolicySnapshot(snapshot: ServerDownloadPolicySnapshot) {
        val state = mutableState.value
        check(currentServerProfileContext() == snapshot.context) { "The server connection changed during download" }
        val now = Instant.now()
        val exactLease = state.clientConfig == snapshot.config && snapshot.config.isActive(now)
        check(exactLease) {
            "The server download policy changed or expired"
        }
        check(state.serverDownloadMode == snapshot.mode) { "The selected server download mode changed" }
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            state.serverUploadMode,
            snapshot.mode,
        )
        check(resolved.downloadMode == snapshot.mode) { "The server download mode changed" }
    }

    private fun activeDownloadMode(): ServerDownloadMode {
        expireClientConfigIfNeeded()
        val state = mutableState.value
        val resolved = ServerTransferModePolicy.resolve(
            state.clientConfig,
            state.serverUploadMode,
            state.serverDownloadMode,
        )
        if (resolved.uploadMode != state.serverUploadMode || resolved.downloadMode != state.serverDownloadMode) {
            mutableState.value = state.copy(
                serverUploadMode = resolved.uploadMode,
                serverDownloadMode = resolved.downloadMode,
                clientConfigStatus = if (state.clientConfig.isActive(Instant.now())) {
                    state.clientConfigStatus
                } else {
                    "Safe defaults • server policy expired"
                },
            )
        }
        return resolved.downloadMode
    }

    private fun streamRemoteSong(songID: String) {
        if (activeDownloadMode() != ServerDownloadMode.StreamOnly) {
            mutableState.value = mutableState.value.copy(
                errorMessage = "Stream-only mode is no longer enabled by the server.",
            )
            return
        }
        val song = mutableState.value.remoteSongs.firstOrNull { it.id == songID } ?: return
        if (song.isVideoMedia) {
            mutableState.value = mutableState.value.copy(
                downloadDetail = "Visible video playback is not available on Android yet",
                errorMessage = "This Android client cannot show server video yet, so Stream-only playback is unavailable for MP4, MOV, M4V, and WebM. Verified file mode can save the file offline, but playback remains audio-only until a video surface is added.",
            )
            return
        }
        val player = controller ?: run {
            mutableState.value = mutableState.value.copy(errorMessage = "The player is still starting.")
            return
        }
        val streamContext = currentServerProfileContext() ?: run {
            mutableState.value = mutableState.value.copy(
                errorMessage = "The server connection is unavailable.",
            )
            return
        }
        val client = serverClient(streamContext)
        val authorizationExpiresAt = mutableState.value.clientConfig.expiresAt
            ?.takeIf { Instant.now().isBefore(it) }
            ?: run {
                mutableState.value = mutableState.value.copy(
                    errorMessage = "The server stream policy has expired; refresh the server first.",
                )
                return
            }
        val handle = runCatching {
            AuthenticatedStreamRegistry.register(
                baseURL = client.baseURL,
                streamURL = song.streamURL,
                accessToken = activeAccessToken(),
                profileID = streamContext.profileID,
                cohortKey = clientConfigStore.cohortKey,
                authorizationExpiresAt = authorizationExpiresAt,
                allowCleartextDevelopment = BuildConfig.DEBUG,
            )
        }.getOrElse {
            showError(it)
            return
        }
        clearActiveStreamPresentation()
        val presentation = Track(
            id = "remote-stream:${song.id}:${handle.id}",
            title = song.title,
            artist = song.artist,
            album = song.album,
            durationMs = song.durationSeconds?.takeIf { it.isFinite() && it > 0.0 }
                ?.times(1_000.0)
                ?.toLong()
                ?: 0L,
            // This render-only object is never inserted into StoredLibrary and carries no URL.
            relativePath = "",
            remoteID = null,
            sourceServer = null,
            syncProfileID = null,
        )
        activeStreamHandle = handle
        activeStreamPresentation = presentation
        activeStreamPolicyContext = streamContext
        val metadataExtras = Bundle().apply {
            song.artworkURL?.takeIf(String::isNotBlank)?.let {
                putString(STREAM_ARTWORK_URL_EXTRA, it)
            }
        }
        val metadata = MediaMetadata.Builder()
            .setTitle(song.title)
            .setArtist(song.artist)
            .setAlbumTitle(song.album)
            .setExtras(metadataExtras)
            .build()
        val item = MediaItem.Builder()
            .setMediaId(presentation.id)
            .setUri(handle.playbackURI)
            .setMediaMetadata(metadata)
            .build()
        activeQueue = listOf(presentation.id)
        activePlaylistId = null
        mutableState.value = mutableState.value.copy(
            tracks = library.tracks.filter(::trackBelongsToActiveContext),
            currentTrackId = presentation.id,
            transientCurrentTrack = presentation,
            transientArtworkURL = song.artworkURL,
            activePlaylistId = null,
            selectedRemoteSongIds = emptySet(),
            downloadDetail = "Streaming ${song.title} • no file saved",
            errorMessage = null,
        )
        player.setMediaItem(item)
        player.shuffleModeEnabled = false
        player.prepare()
        player.play()
        scheduleActiveStreamRenewal(authorizationExpiresAt)
        refreshPlaybackState()
    }

    private fun clearActiveStreamPresentation() {
        streamConfigRenewalJob?.cancel()
        streamConfigRenewalJob = null
        streamLeaseExpiryJob?.cancel()
        streamLeaseExpiryJob = null
        pendingStreamRenewalMinimumExpiry = null
        AuthenticatedStreamRegistry.remove(activeStreamHandle?.id)
        activeStreamHandle = null
        activeStreamPresentation = null
        activeStreamPolicyContext = null
        if (
            mutableState.value.transientCurrentTrack != null ||
            mutableState.value.transientArtworkURL != null
        ) {
            mutableState.value = mutableState.value.copy(
                transientCurrentTrack = null,
                transientArtworkURL = null,
            )
        }
        controller?.shuffleModeEnabled = mutableState.value.shuffleEnabled
    }

    private fun stopActiveStream(message: String) {
        if (activeStreamPresentation == null) return
        controller?.stop()
        controller?.clearMediaItems()
        clearActiveStreamPresentation()
        activeQueue = emptyList()
        activePlaylistId = null
        mutableState.value = mutableState.value.copy(
            tracks = library.tracks.filter(::trackBelongsToActiveContext),
            currentTrackId = null,
            transientCurrentTrack = null,
            transientArtworkURL = null,
            activePlaylistId = null,
            isPlaying = false,
            playbackStatus = PlaybackUiStatus.Idle,
            positionMs = 0L,
            playerDurationMs = null,
            downloadDetail = message,
        )
    }

    private fun restoreActiveStreamPresentation(player: Player) {
        val item = player.currentMediaItem ?: return
        val uri = item.localConfiguration?.uri ?: return
        if (uri.scheme != "resonance-stream" || uri.host != "session") return
        val handleID = uri.pathSegments.singleOrNull() ?: return
        if (activeStreamHandle?.id == handleID && activeStreamPresentation != null) return
        val streamContext = currentServerProfileContext()
        val authorizationExpiresAt = AuthenticatedStreamRegistry.authorizationExpiresAt(handleID)
        val client = streamContext?.let(::serverClient)
        val restorable =
            streamContext != null &&
                client != null &&
                authorizationExpiresAt != null &&
                AuthenticatedStreamRegistry.renew(
                    id = handleID,
                    baseURL = client.baseURL,
                    accessToken = activeAccessToken(),
                    profileID = streamContext.profileID,
                    cohortKey = clientConfigStore.cohortKey,
                    authorizationExpiresAt = authorizationExpiresAt,
                )
        if (!restorable) {
            AuthenticatedStreamRegistry.remove(handleID)
            player.stop()
            player.clearMediaItems()
            return
        }
        val metadata = item.mediaMetadata
        activeStreamHandle = AuthenticatedStreamHandle(handleID, uri)
        activeStreamPolicyContext = streamContext
        activeStreamPresentation = Track(
            id = item.mediaId,
            title = metadata.title?.toString().orEmpty().ifBlank { "Server stream" },
            artist = metadata.artist?.toString().orEmpty().ifBlank { "Server" },
            album = metadata.albumTitle?.toString().orEmpty(),
            durationMs = player.duration.takeIf { it != C.TIME_UNSET && it > 0L } ?: 0L,
            relativePath = "",
        )
        mutableState.value = mutableState.value.copy(
            transientCurrentTrack = activeStreamPresentation,
            transientArtworkURL = metadata.extras?.getString(STREAM_ARTWORK_URL_EXTRA),
        )
        player.shuffleModeEnabled = false
        scheduleActiveStreamRenewal(requireNotNull(authorizationExpiresAt))
        // Rebind restored playback to a currently verified same-context policy.
        // The existing lease remains the hard read deadline while this request runs.
        refreshClientConfig()
    }

    override fun toggleRemoteSelection(songId: String) {
        val current = mutableState.value.selectedRemoteSongIds
        mutableState.value = mutableState.value.copy(selectedRemoteSongIds = if (songId in current) current - songId else current + songId)
    }

    override fun clearRemoteSelection() {
        mutableState.value = mutableState.value.copy(selectedRemoteSongIds = emptySet())
    }

    override fun deleteRemoteSong(songId: String) {
        val remoteContext = currentServerProfileContext() ?: return
        val client = serverClient(remoteContext)
        viewModelScope.launch {
            runCatching {
                client.deleteRemoteSong(songId)
                ensureServerProfileContext(remoteContext)
            }
                .onSuccess {
                    // Reject any catalog response that started before this
                    // server-side mutation committed.
                    uploadMutationGeneration += 1
                    mutableState.value = mutableState.value.copy(
                        remoteSongs = mutableState.value.remoteSongs.filterNot { it.id == songId },
                        selectedRemoteSongIds = mutableState.value.selectedRemoteSongIds - songId,
                    )
                }
                .onFailure { error ->
                    if (error !is StaleServerProfileException) showError(error)
                }
        }
    }

    fun syncPlaylistsAutomatically() {
        if (activeAccessToken().isBlank()) return
        viewModelScope.launch { syncPlaylistsNow() }
    }

    private suspend fun syncPlaylistsNow() {
        if (mutableState.value.isSyncingPlaylists || activeAccessToken().isBlank()) return
        val syncContext = currentServerProfileContext() ?: return
        val syncClient = serverClient(syncContext)
        val serverKey = RemoteTrackIdentityPolicy.contextKey(syncContext.serverURL, syncContext.profileID)
            ?: return
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
            var remote = syncClient.fetchPlaylists()
            ensureServerProfileContext(syncContext)
            repeat(2) { attempt ->
                val merge = mergePlaylists(remote)
                if (!merge.second) { applyRemotePlaylists(remote); return@runCatching remote }
                val submittedPlaylists = PlaylistMutationSnapshot(
                    generation = playlistMutationGeneration,
                    dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty(),
                    deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty(),
                )
                val submittedLikesGeneration = likesMutationGeneration
                val submittedDirtyLikeIDs = library.dirtyRemoteLikeSongIDs.orEmpty()
                val submittedClipGeneration = clipRangeMutationGeneration
                val submittedDirtyClipKeys = library.dirtyClipRangeKeys.filterTo(mutableSetOf(), ::activeClipKey)
                when (val result = syncClient.putPlaylists(merge.first)) {
                    is PlaylistPutResult.Updated -> {
                        ensureServerProfileContext(syncContext)
                        val playlistReconciliation = PlaylistSyncMutationPolicy.reconcile(
                            submitted = submittedPlaylists,
                            currentGeneration = playlistMutationGeneration,
                            currentDirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty(),
                            currentDeletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty(),
                        )
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
                            dirtyPlaylistIDs = playlistReconciliation.dirtyPlaylistIDs,
                            deletedPlaylistIDs = playlistReconciliation.deletedPlaylistIDs,
                            dirtyRemoteLikeSongIDs = remainingDirtyLikeIDs,
                            likesDirty = remainingDirtyLikeIDs.isNotEmpty(),
                            dirtyClipRangeKeys = remainingDirtyClipKeys,
                            deletedClipRangeKeys = if (clipRangeMutationGeneration == submittedClipGeneration) {
                                library.deletedClipRangeKeys - submittedDirtyClipKeys
                            } else {
                                library.deletedClipRangeKeys
                            },
                        )
                        if (!playlistReconciliation.applyRemoteDocument) {
                            library = library.copy(playlistRevision = result.document.revision)
                            persistLibrary()
                            remote = result.document
                            if (attempt == 0) return@repeat
                            return@runCatching result.document
                        }
                        applyRemotePlaylists(result.document)
                        return@runCatching result.document
                    }
                    is PlaylistPutResult.Conflict -> {
                        ensureServerProfileContext(syncContext)
                        remote = result.document
                    }
                }
            }
            error("Playlist sync conflicted; try again")
        }.onSuccess { document ->
            mutableState.value = mutableState.value.copy(playlistSyncDetail = "Synced ${document.playlists.size} playlist${if (document.playlists.size == 1) "" else "s"}")
        }.onFailure {
            if (it !is StaleServerProfileException) {
                mutableState.value = mutableState.value.copy(playlistSyncDetail = "Playlist sync failed: ${it.message}")
            }
        }
        mutableState.value = mutableState.value.copy(isSyncingPlaylists = false)
        if (library.dirtyPlaylistIDs.orEmpty().isNotEmpty() ||
            library.deletedPlaylistIDs.orEmpty().isNotEmpty() ||
            library.likesDirty ||
            library.dirtyClipRangeKeys.any(::activeClipKey)
        ) {
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
        val ordered = playlist.trackIDs.mapNotNull { id ->
            library.tracks.firstOrNull { it.id == id && trackBelongsToActiveContext(it) }?.remoteID
        }.distinct()
        val previous = playlist.remoteSongIDs.orEmpty()
        val unresolved = previous.filter { remoteId ->
            library.tracks.none { trackBelongsToActiveContext(it) && it.remoteID == remoteId }
        }
        return RemotePlaylist(
            playlist.id.lowercase(),
            playlist.name,
            PlaylistOrderPolicy.merge(previous, ordered, unresolved),
        )
    }

    private suspend fun applyRemotePlaylists(document: RemotePlaylistsDocument) {
        val existing = library.playlists.filterNot(Playlist::isSystem).associateBy(Playlist::id)
        val system = library.playlists.filter(Playlist::isSystem)
        val custom = document.playlists.map { remote ->
            val localOnly = existing[remote.id]?.trackIDs.orEmpty().filter { id ->
                library.tracks.firstOrNull { it.id == id }?.let { it.remoteID == null && it.sourceServer == null } == true
            }
            val downloaded = remote.songIDs.mapNotNull { remoteId ->
                library.tracks.firstOrNull { trackBelongsToActiveContext(it) && it.remoteID == remoteId }?.id
            }
            Playlist(
                remote.id,
                remote.name,
                PlaylistOrderPolicy.merge(existing[remote.id]?.trackIDs.orEmpty(), downloaded, localOnly),
                false,
                remote.songIDs,
            )
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
            val key = activeContextPrefix() + "|remote:" + payload.songID
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
            likesDirty = library.dirtyRemoteLikeSongIDs.orEmpty().isNotEmpty(),
            clipRanges = mergedClipRanges,
        )))
        refreshQueuedClipMetadata()
        persistLibrary()
    }

    private fun hydrateRemotePlaylists(value: StoredLibrary): StoredLibrary = value.copy(
        playlists = value.playlists.map { playlist ->
            if (playlist.isSystem || playlist.remoteSongIDs == null) playlist else {
                val localOnly = playlist.trackIDs.filter { id ->
                    value.tracks.firstOrNull { it.id == id }?.let { it.remoteID == null && it.sourceServer == null } == true
                }
                val downloaded = playlist.remoteSongIDs.mapNotNull { remoteId ->
                    value.tracks.firstOrNull {
                        RemoteTrackIdentityPolicy.matches(it, value.serverURL, value.syncProfileID, remoteId)
                    }?.id
                }
                playlist.copy(trackIDs = PlaylistOrderPolicy.merge(playlist.trackIDs, downloaded, localOnly))
            }
        },
    )

    /**
     * Older libraries recorded a remote song ID without always recording the
     * server/profile that issued it. Attach the only context that legacy data
     * could have belonged to before applying compound-identity deduplication.
     */
    private fun migrateRemoteTrackContexts(value: StoredLibrary): StoredLibrary {
        val migrated = value.tracks.map { track ->
            if (track.remoteID == null && track.sourceServer == null) {
                track
            } else {
                track.copy(
                    sourceServer = track.sourceServer?.takeIf(String::isNotBlank) ?: value.serverURL,
                    syncProfileID = track.syncProfileID?.takeIf(String::isNotBlank) ?: value.syncProfileID,
                )
            }
        }
        return RemoteTrackIdentityPolicy.reconcileLibraryTracks(value.copy(tracks = migrated))
    }

    /** Moves legacy `profile|remote:` clip keys under the server-origin scope. */
    private fun migrateCompoundClipKeys(value: StoredLibrary): StoredLibrary {
        fun migratedKey(key: String): String {
            if ("#profile=" in key) return RemoteTrackIdentityPolicy.canonicalContextKey(key)
            val boundary = listOf(key.indexOf("|remote:"), key.indexOf("|local:"))
                .filter { it >= 0 }
                .minOrNull()
                ?: return key
            val profileID = key.substring(0, boundary).takeIf(String::isNotBlank) ?: return key
            val context = RemoteTrackIdentityPolicy.contextKey(value.serverURL, profileID) ?: return key
            return context + key.substring(boundary)
        }

        fun migrateRanges(ranges: Map<String, ClipRange>): Map<String, ClipRange> {
            val migrated = LinkedHashMap<String, ClipRange>()
            ranges.forEach { (key, range) ->
                val target = migratedKey(key)
                if (target == key || target !in migrated) migrated[target] = range
            }
            return migrated
        }

        val syncKey = value.playlistSyncServerURL?.let { existing ->
            if ("#profile=" in existing) RemoteTrackIdentityPolicy.canonicalContextKey(existing)
            else RemoteTrackIdentityPolicy.contextKey(existing, value.syncProfileID) ?: existing
        }
        val profileStates = LinkedHashMap<String, ProfileLibraryState>()
        value.profileStates.forEach { (key, state) ->
            val canonicalKey = RemoteTrackIdentityPolicy.canonicalContextKey(key)
            if (canonicalKey == key) profileStates[canonicalKey] = state
        }
        value.profileStates.forEach { (key, state) ->
            profileStates.putIfAbsent(RemoteTrackIdentityPolicy.canonicalContextKey(key), state)
        }
        return value.copy(
            playlistSyncServerURL = syncKey,
            profileStates = profileStates,
            clipRanges = migrateRanges(value.clipRanges),
            dirtyClipRangeKeys = value.dirtyClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
            deletedClipRangeKeys = value.deletedClipRangeKeys.mapTo(linkedSetOf(), ::migratedKey),
        )
    }

    private fun migrateRemoteLikes(value: StoredLibrary): StoredLibrary {
        val remoteLikedSongIDs = value.remoteLikedSongIDs ?: value.favorites.mapNotNullTo(mutableSetOf()) { trackID ->
            value.tracks.firstOrNull {
                it.id == trackID && RemoteTrackIdentityPolicy.belongsToContext(it, value.serverURL, value.syncProfileID)
            }?.remoteID
        }
        val dirtyRemoteLikeSongIDs = value.dirtyRemoteLikeSongIDs ?: if (value.likesDirty) {
            value.tracks.mapNotNullTo(mutableSetOf()) { track ->
                track.remoteID?.takeIf {
                    RemoteTrackIdentityPolicy.belongsToContext(track, value.serverURL, value.syncProfileID)
                }
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
            value.tracks.firstOrNull { it.id == id }?.let {
                it.remoteID == null && it.sourceServer == null
            } == true
        }
        val remoteFavorites = value.tracks.mapNotNullTo(mutableSetOf()) { track ->
            track.id.takeIf {
                track.remoteID?.let { it in value.remoteLikedSongIDs.orEmpty() } == true &&
                    RemoteTrackIdentityPolicy.belongsToContext(track, value.serverURL, value.syncProfileID)
            }
        }
        return normalizeLiked(value.copy(favorites = localFavorites + remoteFavorites))
    }

    private fun updateRemoteSongIds(playlist: Playlist): Playlist {
        val unresolved = playlist.remoteSongIDs.orEmpty().filter { remoteId ->
            library.tracks.none { trackBelongsToActiveContext(it) && it.remoteID == remoteId }
        }
        val ordered = playlist.trackIDs.mapNotNull { id ->
            library.tracks.firstOrNull { it.id == id && trackBelongsToActiveContext(it) }?.remoteID
        }.distinct()
        return playlist.copy(remoteSongIDs = PlaylistOrderPolicy.merge(
            playlist.remoteSongIDs.orEmpty(),
            ordered,
            unresolved,
        ))
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
        library = ProfileLibraryStatePolicy.captureActive(library)
        library = RemoteTrackIdentityPolicy.reconcileLibraryTracks(library)
        repository.save(library)
        refreshLibraryState()
        refreshStorage()
    }

    private fun refreshLibraryState() {
        val visibleTracks = library.tracks.filter {
            RemoteTrackIdentityPolicy.visibleInContext(it, library.serverURL, library.syncProfileID)
        }
        val trackSizes = visibleTracks.associate { it.id to repository.fileForTrack(it).length() }
        val filePaths = visibleTracks.associate { it.id to repository.fileForTrack(it).absolutePath }
        val artwork = visibleTracks.mapNotNull { track -> repository.artworkFile(track)?.takeIf(File::isFile)?.absolutePath?.let { track.id to it } }.toMap()
        val visibleClipRanges = visibleTracks.mapNotNull { track ->
            library.clipRanges[clipRangeKey(track)]?.let { track.id to it }
        }.toMap()
        mutableState.value = mutableState.value.copy(
            tracks = visibleTracks,
            transientCurrentTrack = activeStreamPresentation,
            playlists = library.playlists,
            favoriteTrackIds = library.favorites,
            trackSizesById = trackSizes,
            trackFilePathsById = filePaths,
            clipRangesByTrackId = visibleClipRanges,
            artworkPathsByTrackId = artwork,
            downloadedRemoteSongIds = visibleTracks.mapNotNullTo(mutableSetOf(), Track::remoteID),
            serverUrl = credentials.serverURL,
            serverToken = accountSession?.accessToken ?: credentials.clientToken,
            serverAdminKey = accountSession?.accessToken ?: credentials.adminToken,
            accountEmail = accountSession?.email,
            accountRole = accountSession?.role,
            accountDisplayName = accountSession?.profileDisplayName,
            accountImageURL = accountSession?.imageURL,
            syncProfileId = library.syncProfileID,
            syncProfiles = library.syncProfiles,
            profilePicturePath = profilePictureStore.existingPath(
                library.serverURL,
                library.syncProfileID,
            ),
        )
    }

    private suspend fun refreshStorage() {
        val stats = repository.storageStats(library)
        mutableState.value = mutableState.value.copy(availableStorageBytes = stats.availableBytes)
    }

    private fun refreshPlaybackState() {
        val player = controller ?: return
        val currentId = player.currentMediaItem?.mediaId?.takeIf(String::isNotBlank)
        val playbackStatus = player.playerError?.let { error ->
            PlaybackFailurePolicy.status(error.errorCode, error.message)
        } ?: when (player.playbackState) {
            Player.STATE_IDLE -> PlaybackUiStatus.Idle
            Player.STATE_BUFFERING -> PlaybackUiStatus.Buffering
            Player.STATE_READY -> PlaybackUiStatus.Ready
            Player.STATE_ENDED -> PlaybackUiStatus.Ended
            else -> PlaybackUiStatus.Idle
        }
        mutableState.value = mutableState.value.copy(
            currentTrackId = currentId,
            activePlaylistId = activePlaylistId,
            isPlaying = player.isPlaying,
            playbackStatus = playbackStatus,
            positionMs = player.currentPosition.coerceAtLeast(0L),
            playerDurationMs = player.duration.takeIf { it != C.TIME_UNSET && it > 0L },
            playbackSpeed = player.playbackParameters.speed,
        )
    }

    private fun mediaItem(id: String): MediaItem? =
        library.tracks.firstOrNull { it.id == id }?.let(::mediaItem)

    private fun mediaItem(track: Track): MediaItem? {
        val audioFile = repository.fileForTrack(track).takeIf(File::isFile) ?: return null
        val artworkUri = repository.artworkFile(track)?.takeIf(File::isFile)?.let(Uri::fromFile)
        val clip = playbackRange(track)
        val extras = Bundle().apply {
            putLong(PlaybackService.CLIP_START_MS, clip?.startMs ?: 0L)
            clip?.let { putLong(PlaybackService.CLIP_END_MS, it.endMs) }
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
            .setUri(Uri.fromFile(audioFile))
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
        val byID = QueuePolicy.indexByMediaID(library.tracks.filter(::trackBelongsToActiveContext), Track::id)
        val entries = QueuePolicy.assembleQueue(ids, byID) { mediaItem(it) }
        val items = entries.map { it.item }
        val index = entries.indexOfFirst { it.mediaID == currentID }
        val track = byID[currentID]
        if (index < 0 || track == null) return
        val range = playbackRange(track)
        val position = range?.let {
            player.currentPosition.coerceIn(it.startMs, (it.endMs - 1).coerceAtLeast(it.startMs))
        } ?: player.currentPosition.coerceAtLeast(0L)
        val wasPlaying = player.playWhenReady
        player.setMediaItems(items, index, position)
        activeQueue = entries.map { it.mediaID }
        player.prepare()
        if (wasPlaying) player.play() else player.pause()
    }

    private fun rebuildPlaybackQueueForActiveContext() {
        if (activeStreamPresentation?.id == controller?.currentMediaItem?.mediaId) return
        val inScopeIDs = library.tracks
            .filter(::trackBelongsToActiveContext)
            .mapTo(linkedSetOf(), Track::id)
        val player = controller
        if (player == null) {
            activeQueue = activeQueue.filter(inScopeIDs::contains)
            return
        }
        applyQueueRebuildPlan(QueuePolicy.reconcileScope(
            queueMediaIDs = playerQueueIDs(player),
            inScopeMediaIDs = inScopeIDs,
            currentMediaID = player.currentMediaItem?.mediaId,
        ))
    }

    private fun reconcilePlaybackQueueAfterDeletion(trackIDs: Set<String>) {
        if (trackIDs.isEmpty()) return
        val player = controller
        if (player == null) {
            activeQueue = activeQueue.filterNot(trackIDs::contains)
            if (mutableState.value.currentTrackId in trackIDs) {
                mutableState.value = mutableState.value.copy(
                    currentTrackId = null,
                    activePlaylistId = null,
                    isPlaying = false,
                    playbackStatus = PlaybackUiStatus.Idle,
                    positionMs = 0L,
                    playerDurationMs = null,
                )
            }
            return
        }
        applyQueueRebuildPlan(QueuePolicy.reconcileDeletion(
            queueMediaIDs = playerQueueIDs(player),
            deletedMediaIDs = trackIDs,
            currentMediaID = player.currentMediaItem?.mediaId,
        ))
    }

    private fun playerQueueIDs(player: Player): List<String> =
        (0 until player.mediaItemCount).map { player.getMediaItemAt(it).mediaId }

    private fun applyQueueRebuildPlan(plan: QueuePolicy.QueueRebuildPlan) {
        val player = controller ?: return
        if (!plan.requiresRebuild) {
            activeQueue = plan.mediaIDs
            return
        }

        val visibleTracks = library.tracks.filter(::trackBelongsToActiveContext)
        val tracksByID = QueuePolicy.indexByMediaID(visibleTracks, Track::id)
        val entries = QueuePolicy.assembleQueue(plan.mediaIDs, tracksByID) { mediaItem(it) }
        val retainedCurrentID = plan.currentMediaID?.takeIf { current ->
            entries.any { it.mediaID == current }
        }
        val targetIndex = retainedCurrentID?.let { current ->
            entries.indexOfFirst { it.mediaID == current }
        } ?: 0
        val targetPosition = if (retainedCurrentID == null) 0L else player.currentPosition.coerceAtLeast(0L)
        val resumePlayback = !plan.shouldStopPlayback && retainedCurrentID != null && player.playWhenReady

        if (plan.shouldStopPlayback || retainedCurrentID == null) {
            player.stop()
            activePlaylistId = null
        }
        player.clearMediaItems()
        if (entries.isNotEmpty()) {
            player.setMediaItems(entries.map { it.item }, targetIndex, targetPosition)
            player.prepare()
            if (resumePlayback) player.play() else player.pause()
        }
        activeQueue = entries.map { it.mediaID }
        refreshPlaybackState()
    }

    private fun trackBelongsToActiveContext(track: Track): Boolean =
        RemoteTrackIdentityPolicy.visibleInContext(track, library.serverURL, library.syncProfileID)

    private fun activeContextPrefix(): String = requireNotNull(
        RemoteTrackIdentityPolicy.contextKey(library.serverURL, library.syncProfileID),
    ) { "The active server URL is invalid" }

    private fun clipRangeKey(track: Track): String = activeContextPrefix() +
        if (track.remoteID != null) "|remote:" + track.remoteID else "|local:" + track.id

    private fun activeClipKey(key: String): Boolean = key.startsWith(activeContextPrefix() + "|")

    private fun playbackRange(track: Track): ClipRange? {
        val duration = track.durationMs.takeIf { it > 0L }
        val stored = library.clipRanges[clipRangeKey(track)]
        if (stored == null) return duration?.let { ClipRange(0L, it) }
        val maximum = duration ?: stored.endMs
        val start = stored.startMs.coerceIn(0L, maximum)
        val end = stored.endMs.coerceIn(start, maximum)
        return if (end - start >= 250L) ClipRange(start, end) else duration?.let { ClipRange(0L, it) }
    }

    private fun activeAccessToken(): String = accountSession?.accessToken ?: credentials.clientToken

    private fun activeAdminToken(): String = accountSession?.accessToken ?: credentials.adminToken

    private fun serverClient() = ServerClient(
        credentials.serverURL,
        activeAccessToken(),
        activeAdminToken(),
        library.syncProfileID,
        clientConfigStore.cohortKey,
    )

    private fun serverClient(context: ServerProfileContext) = ServerClient(
        context.serverURL,
        activeAccessToken(),
        activeAdminToken(),
        context.profileID,
        clientConfigStore.cohortKey,
    )

    private fun currentServerProfileContext(): ServerProfileContext? {
        val normalized = runCatching { ServerClient.normalizeServerURL(credentials.serverURL) }.getOrNull() ?: return null
        return ServerProfileContext(normalized, library.syncProfileID, connectionGeneration)
    }

    private fun beginCatalogRequest(): Pair<CatalogRequestSnapshot, ServerClient>? {
        if (activeAccessToken().isBlank()) return null
        val context = currentServerProfileContext() ?: return null
        cancelRemoteSongMetadataHydration()
        catalogRequestGeneration += 1
        return CatalogRequestSnapshot(
            context = context,
            requestGeneration = catalogRequestGeneration,
            uploadMutationGeneration = uploadMutationGeneration,
        ) to serverClient(context)
    }

    private fun ensureServerProfileContext(expected: ServerProfileContext) {
        if (currentServerProfileContext() != expected) throw StaleServerProfileException()
    }

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

private class StaleServerProfileException : IllegalStateException("Server profile changed during synchronization")

internal fun repeatModeFor(enabled: Boolean): Int =
    if (enabled) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_ALL
