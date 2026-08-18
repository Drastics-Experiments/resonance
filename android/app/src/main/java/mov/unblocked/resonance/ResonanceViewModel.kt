package mov.unblocked.resonance

import android.app.Application
import android.content.ComponentName
import android.graphics.BitmapFactory
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
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.clerk.api.Clerk
import com.clerk.api.ClerkConfigurationOptions
import com.clerk.api.network.serialization.ClerkResult
import com.clerk.api.session.GetTokenOptions
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URI
import java.time.Instant
import java.util.UUID
import java.util.concurrent.Future
import kotlin.math.abs
import kotlinx.coroutines.Deferred
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
import mov.unblocked.resonance.data.CatalogAuthorityPolicy
import mov.unblocked.resonance.data.CatalogResponsePolicy
import mov.unblocked.resonance.data.ClientConfigFetchResult
import mov.unblocked.resonance.data.ClientConfigCacheFallbackPolicy
import mov.unblocked.resonance.data.ClientConfigRevisionPolicy
import mov.unblocked.resonance.data.ClientConfigSource
import mov.unblocked.resonance.data.ClientConfigStore
import mov.unblocked.resonance.data.EffectiveClientConfig
import mov.unblocked.resonance.data.DownloadItemProgressPolicy
import mov.unblocked.resonance.data.DownloadItemProgressPresentation
import mov.unblocked.resonance.data.DownloadedSongMetadataRefreshPolicy
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
import mov.unblocked.resonance.data.ListenAlongEnvelope
import mov.unblocked.resonance.data.ListenAlongRole
import mov.unblocked.resonance.data.ListenAlongSnapshot
import mov.unblocked.resonance.data.ListenAlongSnapshotPolicy
import mov.unblocked.resonance.data.ListenAlongPollPolicy
import mov.unblocked.resonance.data.ListenAlongArtworkPolicy
import mov.unblocked.resonance.data.ListenAlongPlaybackPolicy
import mov.unblocked.resonance.data.ListenAlongRevisionConflictException
import mov.unblocked.resonance.data.ListeningHistoryPlaybackPolicy
import mov.unblocked.resonance.data.ListeningHistoryRetentionPolicy
import mov.unblocked.resonance.data.LatestValuePersistenceGate
import mov.unblocked.resonance.data.ReviewedMatchResolutionPolicy
import mov.unblocked.resonance.data.LibraryRepository
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.PlaylistDownloadOutcomePolicy
import mov.unblocked.resonance.data.PlaylistPutResult
import mov.unblocked.resonance.data.PlaylistMutationSnapshot
import mov.unblocked.resonance.data.PlaylistEntryOrderPolicy
import mov.unblocked.resonance.data.PlaylistLocalDeletionPolicy
import mov.unblocked.resonance.data.PlaylistOrderPolicy
import mov.unblocked.resonance.data.PlaylistSyncMutationPolicy
import mov.unblocked.resonance.data.PendingDownloadBatchPolicy
import mov.unblocked.resonance.data.RemoteSongDownloadMetadataPolicy
import mov.unblocked.resonance.data.RemoteDownloadContextChangePolicy
import mov.unblocked.resonance.data.RemoteSourceDownloadCoordinator
import mov.unblocked.resonance.data.RemoteSourceResolutionCacheKey
import mov.unblocked.resonance.data.RemoteSourceResolutionCachePolicy
import mov.unblocked.resonance.data.ProfileLibraryStatePolicy
import mov.unblocked.resonance.data.ProfileLibraryState
import mov.unblocked.resonance.data.RemotePlaylist
import mov.unblocked.resonance.data.RemoteClipRange
import mov.unblocked.resonance.data.RemotePlaylistsDocument
import mov.unblocked.resonance.data.RemoteArtworkPersistencePolicy
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.RemoteSongMetadataCacheEntry
import mov.unblocked.resonance.data.RemoteSongMetadataCachePolicy
import mov.unblocked.resonance.data.RemoteSongMetadataRetryPolicy
import mov.unblocked.resonance.data.ResonanceAccountSignInServerURL
import mov.unblocked.resonance.data.ServerClient
import mov.unblocked.resonance.data.ServerException
import mov.unblocked.resonance.data.ServerProfileContext
import mov.unblocked.resonance.data.ServerRefreshPresentationPolicy
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
import mov.unblocked.resonance.data.TransferSessionOwnership
import mov.unblocked.resonance.data.associatedWithLocalSource
import mov.unblocked.resonance.playback.PlaybackService
import mov.unblocked.resonance.playback.DownloadPolicy
import mov.unblocked.resonance.playback.PlaybackFailurePolicy
import mov.unblocked.resonance.playback.PlaybackMetadataPolicy
import mov.unblocked.resonance.playback.PlaybackVolumePolicy
import mov.unblocked.resonance.playback.CrossfadePolicy
import mov.unblocked.resonance.playback.QueuePolicy
import mov.unblocked.resonance.playback.UploadMissingPolicy
import mov.unblocked.resonance.playback.AuthenticatedStreamHandle
import mov.unblocked.resonance.playback.AuthenticatedStreamRegistry
import mov.unblocked.resonance.playback.ListenAlongProviderStreamHandle
import mov.unblocked.resonance.playback.ListenAlongProviderStreamPolicy
import mov.unblocked.resonance.playback.StreamLeaseUpdatePolicy
import mov.unblocked.resonance.ui.ResonanceActions
import mov.unblocked.resonance.ui.ResonanceUiState
import mov.unblocked.resonance.ui.ResonanceThemeChoice
import mov.unblocked.resonance.ui.LinkImportUiState
import mov.unblocked.resonance.ui.PlaybackUiStatus
import mov.unblocked.resonance.ui.ListenAlongConnectionStatus
import mov.unblocked.resonance.ui.ListenAlongUiState
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

private data class ListeningPlaybackSnapshot(
    val track: Track,
    val serverURL: String?,
    val profileID: String,
    val remoteSongID: String?,
    val artworkURL: String?,
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

private data class RemoteSongMetadataTaskKey(
    val generation: Long,
    val context: ServerProfileContext,
    val cacheKey: String,
)

private const val STREAM_ARTWORK_URL_EXTRA = "resonance.stream.artwork_url"
private const val MAX_PUBLISHED_ARTWORK_EDGE = 512
private const val MAX_PUBLISHED_ARTWORK_BYTES = 256 * 1_024
// Keep healthy guests close to real time while retaining exponential backoff for
// unavailable servers. A 250 ms cadence keeps host actions below a second in
// normal conditions without introducing a second realtime transport.
private const val LISTEN_ALONG_INITIAL_POLL_MS = ListenAlongPollPolicy.HealthyIntervalMillis
private const val LISTEN_ALONG_MAX_POLL_MS = ListenAlongPollPolicy.MaxBackoffMillis
private const val LISTEN_ALONG_SEEK_TOLERANCE_MS = 750L
private const val LISTEN_ALONG_PROVIDER_REFRESH_MS = 3 * 60_000L
private const val LISTEN_ALONG_PUBLISH_DEBOUNCE_MS = 25L

@androidx.annotation.OptIn(UnstableApi::class)
class ResonanceViewModel(application: Application) : AndroidViewModel(application), ResonanceActions {
    private val context = application.applicationContext
    private val repository = LibraryRepository(context)
    private val linkImportService = LinkImportService(context)
    private val remoteSourceResolutions = mutableMapOf<RemoteSourceResolutionCacheKey, LinkImportResolution>()
    private val credentials = CredentialStore(context)
    private var accountSession: AccountSession? = credentials.accountSession
    private val clientConfigStore = ClientConfigStore(context)
    private val profilePictureStore = ProfilePictureStore(context)
    private val preferences = context.getSharedPreferences("resonance.playback", 0)
    private val appearancePreferences = context.getSharedPreferences("resonance.appearance", 0)
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
            crossfadeEnabled = preferences.getBoolean("crossfadeEnabled", false),
            crossfadeSeconds = CrossfadePolicy.normalizedSeconds(
                preferences.getFloat("crossfadeSeconds", CrossfadePolicy.DefaultSeconds),
            ),
            themeChoice = ResonanceThemeChoice.fromStorageID(
                appearancePreferences.getString("theme", null),
            ),
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
    private val libraryPersistenceGate = LatestValuePersistenceGate<StoredLibrary>()
    private var controllerFuture: Future<MediaController>? = null
    private var controller: MediaController? = null
    private var activeQueue: List<String> = emptyList()
    private var activePlaylistId: String? = null
    private var syncDebounce: Job? = null
    private var listeningHistorySyncJob: Job? = null
    private var listeningHistorySyncPending = false
    private var listeningHistoryRetryAt = 0L
    private var listeningHistorySyncInFlight = false
    private val listeningHistorySyncedSeconds = mutableMapOf<String, Double>()
    private var activeListeningEntryID: String? = null
    private var lastListeningPositionSeconds = 0.0
    private var lastPersistedListeningSeconds = 0.0
    private var playlistMutationGeneration = 0L
    private var likesMutationGeneration = 0L
    private var clipRangeMutationGeneration = 0L
    private var connectionGeneration = 0L
    private var catalogRequestGeneration = 0L
    private var authoritativeCatalogSnapshot: CatalogRequestSnapshot? = null
    private var remoteSongMetadataHydrationGeneration = 0L
    private var remoteSongMetadataHydrationJob: Job? = null
    private val remoteSongMetadataTaskLock = Any()
    private val remoteSongMetadataTasks = mutableMapOf<RemoteSongMetadataTaskKey, Deferred<LinkImportTrack?>>()
    private var uploadMutationGeneration = 0L
    private var clientConfigRequestGeneration = 0L
    private var linkImportJob: Job? = null
    private val linkImportTransferOwnership = TransferSessionOwnership()
    private var linkPreviewJob: Job? = null
    private var linkPreviewStopJob: Job? = null
    private var linkPreviewPlayer: MediaPlayer? = null
    private var remoteDownloadJob: Job? = null
    private var remoteDownloadExpiryJob: Job? = null
    private var activeDownloadPolicySnapshot: ServerDownloadPolicySnapshot? = null
    private var activeStreamHandle: AuthenticatedStreamHandle? = null
    private var activeStreamPresentation: Track? = null
    private var activeStreamPolicyContext: ServerProfileContext? = null
    private var activeStreamSourceURL: String? = null
    private var streamArtworkJob: Job? = null
    private var streamConfigRenewalJob: Job? = null
    private var streamLeaseExpiryJob: Job? = null
    private var pendingStreamRenewalMinimumExpiry: Instant? = null
    private var listenAlongContext: ServerProfileContext? = null
    private var listenAlongCode: String? = null
    private var listenAlongRole: ListenAlongRole? = null
    private var listenAlongHostToken: String? = null
    private var listenAlongRevision: Long = 0L
    private var listenAlongSnapshot: ListenAlongSnapshot = ListenAlongSnapshot()
    private var listenAlongPendingSnapshot: ListenAlongSnapshot? = null
    private var listenAlongPollJob: Job? = null
    private var listenAlongPublishJob: Job? = null
    private var listenAlongArtworkJob: Job? = null
    private var listenAlongPlaybackJob: Job? = null
    private var listenAlongProviderRefreshJob: Job? = null
    private var listenAlongProviderHandle: ListenAlongProviderStreamHandle? = null
    private var listenAlongPlaybackSourceURL: String? = null
    private var listenAlongPlaybackMediaKind: String = "audio"
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
        finishListeningSession(flush = true)
        connectionGeneration += 1
        listeningHistorySyncJob?.cancel()
        listeningHistorySyncJob = null
        listeningHistorySyncPending = false
        clearListenAlongSession(stopPlayback = true)
        RemoteDownloadContextChangePolicy.mutateAfterInvalidation(
            invalidateDownload = {
                invalidateActiveRemoteDownload("Download stopped because the account signed out")
            },
            mutation = {
                accountSession = null
                remoteSourceResolutions.clear()
                credentials.accountSession = null
                credentials.pendingAccountSignIn = null
                credentials.clearTokens()
            },
        )
        accountRefreshJob?.cancel()
        accountRefreshJob = null
        authoritativeCatalogSnapshot = null
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
            hasConnectedServerSession = false,
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
                RemoteDownloadContextChangePolicy.mutateAfterInvalidation(
                    invalidateDownload = {
                        invalidateActiveRemoteDownload("Download stopped because the account session changed")
                    },
                    mutation = {
                        migrateConfirmedLegacyProfile(refreshed)
                        accountSession = refreshed
                        credentials.accountSession = refreshed
                    },
                )
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
        RemoteDownloadContextChangePolicy.mutateAfterInvalidation(
            invalidateDownload = {
                invalidateActiveRemoteDownload("Download stopped because the account changed")
            },
            mutation = {
                migrateConfirmedLegacyProfile(session)
                accountSession = session
                credentials.accountSession = session
                credentials.serverURL = session.baseURL
                credentials.clearTokens()
            },
        )
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
            listeningHistory = migrated.listeningHistory.map { entry ->
                if (ListeningHistoryRetentionPolicy.matchesContext(entry, session.baseURL, migratedProfileID)) {
                    entry.copy(syncProfileID = accountProfileID)
                } else entry
            },
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
            syncListeningHistoryAutomatically()
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
                retryRemoteSongMetadataIfNeeded()
                syncPlaylistsAutomatically()
                syncListeningHistoryAutomatically()
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
                    override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                        finishListeningSession(flush = true)
                        refreshPlaybackState()
                    }

                    override fun onEvents(player: Player, events: Player.Events) {
                        refreshPlaybackState()
                        if (events.contains(Player.EVENT_MEDIA_ITEM_TRANSITION)) {
                            publishListenAlongSnapshot()
                        }
                    }

                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        if (!isPlaying) updateListeningSession(flush = true)
                        publishListenAlongSnapshot()
                    }

                    override fun onPlaybackStateChanged(playbackState: Int) {
                        if (playbackState == Player.STATE_ENDED) finishListeningSession(flush = true)
                    }

                    override fun onPositionDiscontinuity(
                        oldPosition: Player.PositionInfo,
                        newPosition: Player.PositionInfo,
                        reason: Int,
                    ) {
                        if (reason == Player.DISCONTINUITY_REASON_SEEK ||
                            reason == Player.DISCONTINUITY_REASON_AUTO_TRANSITION
                        ) {
                            publishListenAlongSnapshot()
                        }
                    }
                })
                rebuildPlaybackQueueForActiveContext()
                refreshPlaybackState()
            }
        }, ContextCompat.getMainExecutor(context))
    }

    override fun onCleared() {
        stopLinkImportPreview()
        remoteSongMetadataHydrationJob?.cancel()
        clearListenAlongSession(stopPlayback = false)
        finishListeningSession(flush = true)
        listeningHistorySyncJob?.cancel()
        controller?.release()
        controller = null
        controllerFuture?.cancel(true)
        super.onCleared()
    }

    override fun importAudio() { mutableImportRequests.tryEmit(Unit) }

    override fun playbackPlayer(): Player? = controller

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
        cancelOwnedLinkImportTransfer()
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.value = mutableState.value.copy(linkImport = invalidated)
    }

    override fun setLinkImportMediaMode(mode: LinkImportMediaMode) {
        val current = mutableState.value.linkImport
        if (current.mediaMode == mode || current.isRunning) return
        stopLinkImportPreview()
        cancelOwnedLinkImportTransfer()
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
        cancelOwnedLinkImportTransfer()
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
                                selectedPlaylistItemIds = emptySet(),
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
                                selectedPlaylistItemIds = if (resolution.kind.isPlaylist) {
                                    resolution.candidates.mapTo(
                                        mutableSetOf(),
                                        mov.unblocked.resonance.data.LinkImportCandidate::playlistItemID,
                                    )
                                } else {
                                    emptySet()
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
                selectedPlaylistItemIds = emptySet(),
                previewError = null,
            ),
        )
    }

    override fun selectLinkImportCandidate(identity: String) {
        val current = mutableState.value.linkImport
        val resolution = current.resolution ?: return
        val playlist = resolution.kind.isPlaylist
        val candidate = resolution.candidates.firstOrNull { candidate ->
            if (playlist) candidate.playlistItemID == identity else candidate.videoID == identity
        } ?: return
        val selection = if (playlist) {
            current.selectedPlaylistItemIds.toMutableSet().apply {
                if (!add(candidate.playlistItemID)) remove(candidate.playlistItemID)
            }
        } else {
            emptySet()
        }
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                selectedVideoId = if (playlist) current.selectedVideoId else candidate.videoID,
                selectedPlaylistItemIds = selection,
            ),
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
            return confirmPlaylistImport(current, resolution, uploadAfterImport, uploadSnapshot)
        }
        val candidate = resolution.candidates.firstOrNull { it.videoID == current.selectedVideoId } ?: return false
        val transferGeneration = beginLinkImportTransfer()
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
            downloadProgress = 0f,
            downloadCurrentItem = 1,
            downloadTotalItems = 1,
            downloadCurrentTitle = resolution.track.title,
            downloadBytesTransferred = 0L,
            downloadTotalBytes = null,
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
                transferGeneration,
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
                    selectedPlaylistItemIds = emptySet(),
                    errorCode = null,
                    errorMessage = null,
                ),
            )
            return false
        }
        stopLinkImportPreview()
        cancelOwnedLinkImportTransfer()
        linkImportJob?.cancel()
        mutableState.value = mutableState.value.copy(
            linkImport = current.copy(
                stage = LinkImportStage.SearchingCandidates,
                selectedVideoId = null,
                selectedPlaylistItemIds = emptySet(),
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
                        selectedPlaylistItemIds = emptySet(),
                        errorCode = null,
                        errorMessage = null,
                    ),
                )
            }.onFailure(::applyLinkImportFailure)
        }
        // Keep the dialog open for an explicit radio-button selection.
        return false
    }

    private fun confirmPlaylistImport(
        current: LinkImportUiState,
        resolution: LinkImportResolution,
        uploadAfterImport: Boolean,
        uploadSnapshot: ServerUploadPolicySnapshot?,
    ): Boolean {
        val playlist = resolution.playlist ?: return false
        val selected = resolution.candidates
            .filter { it.playlistItemID in current.selectedPlaylistItemIds }
            .sortedBy { it.playlistIndex }
        if (selected.isEmpty()) return false
        val transferGeneration = beginLinkImportTransfer()
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
            downloadProgress = 0f,
            downloadCurrentItem = 1,
            downloadTotalItems = selected.size,
            downloadCurrentTitle = selected.firstOrNull()?.importTrack?.title,
            downloadBytesTransferred = 0L,
            downloadTotalBytes = null,
            errorMessage = null,
        )
        linkImportJob = viewModelScope.launch {
            runPlaylistImport(
                resolution,
                selected,
                current.mediaMode,
                uploadAfterImport,
                uploadSnapshot,
                transferGeneration,
            )
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
        transferGeneration: Long,
    ) {
        val client = uploadSnapshot?.let { serverClient(it.context) }
        try {
            requireLinkImportTransfer(transferGeneration)
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
                beginLinkDownloads(transferGeneration, 1, metadata.title)
                val candidates = if (strictSourceIdentity) {
                    listOf(selectedCandidate)
                } else {
                    listOf(selectedCandidate) + selectedCandidate.fallbackCandidates +
                        resolution.candidates.filter { it.videoID != selectedCandidate.videoID }
                }
                track = downloadLinkTrack(
                    metadata,
                    candidates.distinctBy(LinkImportCandidate::videoID),
                    mediaMode,
                    0,
                    1,
                    linkTransferGeneration = transferGeneration,
                )
                updateOwnedLinkImportTransfer(transferGeneration) { state ->
                    state.copy(downloadProgress = 1f)
                }
            }
            requireLinkImportTransfer(transferGeneration)
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
                beginLinkUploads(transferGeneration, 1)
                runCatching {
                    uploadLinkTrackWithRetry(
                        track,
                        client,
                        0,
                        1,
                        sourcePageURL,
                        requireNotNull(uploadSnapshot),
                        transferGeneration,
                    )
                }
                    .onFailure { uploadFailure = it }
                updateOwnedLinkImportTransfer(transferGeneration) { state ->
                    state.copy(uploadProgress = 1f)
                }
            }
            persistLibrary()
            hideOwnedLinkTransfers(transferGeneration)
            if (client != null && uploadFailure == null) refreshCatalogAfterUpload()
            if (uploadFailure != null) {
                val detail = "Saved locally; upload failed after retrying: ${track.title} — ${track.artist} (${uploadFailure.message ?: "upload failed"})"
                updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                    errorMessage = detail,
                    linkImport = state.linkImport.copy(
                        stage = LinkImportStage.Failed,
                        completedTrackTitle = track.title,
                        errorCode = "SERVER_UPLOAD_FAILED",
                        errorMessage = detail,
                    ),
                ) }
            } else {
                val localDetail = if (plannedDownloads == 0) "Already on this device." else "Downloaded to this device."
                val serverDetail = if (!uploadAfterImport) "" else if (existingServerSongID != null) " Already on the server." else " Uploaded to the server."
                updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                    linkImport = state.linkImport.copy(
                        stage = LinkImportStage.Complete,
                        completedTrackTitle = track.title,
                        completedSummary = localDetail + serverDetail,
                        batchCurrentTitle = null,
                    ),
                ) }
            }
        } catch (_: CancellationException) {
            hideOwnedLinkTransfers(transferGeneration)
            updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                linkImport = state.linkImport.copy(stage = LinkImportStage.Cancelled, batchCurrentTitle = null),
            ) }
        } catch (error: Throwable) {
            hideOwnedLinkTransfers(transferGeneration)
            val detail = "${resolution.track.title} — ${resolution.track.artist}: ${error.message ?: "download failed"}"
            updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                errorMessage = detail,
                linkImport = state.linkImport.copy(
                    stage = LinkImportStage.Failed,
                    errorCode = (error as? LinkImportException)?.code ?: "LOCAL_IMPORT_FAILED",
                    errorMessage = detail,
                    batchCurrentTitle = null,
                ),
            ) }
        } finally {
            finishOwnedLinkTransfer(transferGeneration)
        }
    }

    private suspend fun runPlaylistImport(
        resolution: LinkImportResolution,
        selected: List<LinkImportCandidate>,
        mediaMode: LinkImportMediaMode,
        uploadAfterImport: Boolean,
        uploadSnapshot: ServerUploadPolicySnapshot?,
        transferGeneration: Long,
    ) {
        val playlist = requireNotNull(resolution.playlist)
        val imported = mutableListOf<Pair<LinkImportCandidate, Track>>()
        val downloadFailures = mutableListOf<String>()
        val uploadFailures = mutableListOf<String>()
        val client = uploadSnapshot?.let { serverClient(it.context) }
        try {
            requireLinkImportTransfer(transferGeneration)
            // A provider video can occur at multiple playlist positions. Keep
            // those rows selected independently, but resolve/download each
            // source video once and reuse the resulting local track.
            val downloadCandidates = selected.distinctBy(LinkImportCandidate::videoID)
            val candidatesByVideoID = downloadCandidates.associateBy(LinkImportCandidate::videoID)
            val initialMatches = downloadCandidates.associateWith { candidate ->
                LinkImportExistingPolicy.match(
                    requireNotNull(candidate.importTrack),
                    library.tracks,
                    mutableState.value.remoteSongs,
                    mutableState.value.serverUrl,
                    library.syncProfileID,
                    mediaMode,
                )
            }
            val downloadItems = downloadCandidates.filter { initialMatches[it]?.deviceTrackID == null }
            if (downloadItems.isNotEmpty()) {
                beginLinkDownloads(
                    transferGeneration,
                    downloadItems.size,
                    downloadItems.firstOrNull()?.importTrack?.title,
                )
            }
            var completedDownloads = 0
            val downloadOutcomes = PlaylistDownloadOutcomePolicy.loadDistinct(
                selected = downloadCandidates,
                key = LinkImportCandidate::videoID,
            ) { downloadCandidate ->
                val metadata = requireNotNull(downloadCandidate.importTrack).copy(
                    artworkURL = downloadCandidate.importTrack.artworkURL ?: downloadCandidate.thumbnailURL,
                )
                val initial = initialMatches.getValue(downloadCandidate)
                val existingTrack = initial.deviceTrackID
                    ?.let { id -> library.tracks.firstOrNull { it.id == id } }
                    ?.let { existing -> associateLocalImportSource(existing, metadata.sourceURL) }
                if (existingTrack != null) {
                    Result.success(existingTrack)
                } else {
                    updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                        linkImport = state.linkImport.copy(
                            batchCurrentTitle = "${completedDownloads + 1} of ${downloadItems.size} • ${metadata.title}",
                        ),
                    ) }
                    val result = try {
                        Result.success(
                            downloadLinkTrack(
                                metadata,
                                (listOf(downloadCandidate) + downloadCandidate.fallbackCandidates)
                                    .distinctBy(LinkImportCandidate::videoID),
                                mediaMode,
                                completedDownloads,
                                downloadItems.size,
                                linkTransferGeneration = transferGeneration,
                            ),
                        )
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        downloadFailures += "${metadata.title} — ${metadata.artist} (${error.message ?: "download failed"})"
                        Result.failure(error)
                    }
                    completedDownloads += 1
                    updateOwnedLinkImportTransfer(transferGeneration) { state ->
                        state.copy(downloadProgress = 1f)
                    }
                    result
                }
            }
            val downloadOutcomesByVideoID = downloadOutcomes.associateBy { it.key }
            val adoptedVideoIDs = mutableSetOf<String>()
            selected.forEach { candidate ->
                val downloadCandidate = candidatesByVideoID.getValue(candidate.videoID)
                val initial = initialMatches[downloadCandidate]
                val track = downloadOutcomesByVideoID.getValue(candidate.videoID).result.getOrNull()
                if (track != null) {
                    if (adoptedVideoIDs.add(candidate.videoID)) {
                        initial?.serverSongID?.let { remoteID ->
                            adoptUploadedDownload(track.id, remoteID, client?.baseURL ?: mutableState.value.serverUrl)
                        }
                    }
                    if (imported.none { it.second.id == track.id }) imported += candidate to track
                }
            }
            requireLinkImportTransfer(transferGeneration)
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
                beginLinkUploads(transferGeneration, uploadQueue.size)
                uploadQueue.forEachIndexed { index, (_, track) ->
                    try {
                        uploadLinkTrackWithRetry(
                            track,
                            client,
                            index,
                            uploadQueue.size,
                            null,
                            requireNotNull(uploadSnapshot),
                            transferGeneration,
                        )
                    } catch (error: CancellationException) {
                        throw error
                    } catch (error: Throwable) {
                        uploadFailures += "${track.title} — ${track.artist} (${error.message ?: "upload failed"})"
                    }
                    updateOwnedLinkImportTransfer(transferGeneration) { state ->
                        state.copy(uploadProgress = (index + 1).toFloat() / uploadQueue.size)
                    }
                }
            }
            persistLibrary()
            hideOwnedLinkTransfers(transferGeneration)
            if (client != null) refreshCatalogAfterUpload()
            val summary = "Kept ${imported.size} of ${selected.size} selected songs in ${playlist.title}."
            val deviceSkips = initialMatches.values.count { it.isOnDevice }
            val serverSkips = if (uploadAfterImport) initialMatches.values.count { it.isOnServer } else 0
            when {
                downloadFailures.isNotEmpty() -> {
                    val detail = "Playlist import incomplete. Kept ${imported.size} song${if (imported.size == 1) "" else "s"}. Downloads failed after retrying: ${downloadFailures.joinToString("; ")}"
                    updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                        errorMessage = detail,
                        linkImport = state.linkImport.copy(
                            stage = LinkImportStage.Failed,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = summary,
                            batchCurrentTitle = null,
                            errorCode = "PLAYLIST_DOWNLOAD_PARTIAL_FAILURE",
                            errorMessage = detail,
                        ),
                    ) }
                }
                uploadFailures.isNotEmpty() -> {
                    val detail = "Saved every downloaded song locally. Server uploads failed after retrying: ${uploadFailures.joinToString("; ")}"
                    updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                        errorMessage = detail,
                        linkImport = state.linkImport.copy(
                            stage = LinkImportStage.Failed,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = summary,
                            batchCurrentTitle = null,
                            errorCode = "PLAYLIST_UPLOAD_PARTIAL_FAILURE",
                            errorMessage = detail,
                        ),
                    ) }
                }
                else -> {
                    updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                        linkImport = state.linkImport.copy(
                            stage = LinkImportStage.Complete,
                            completedTrackTitle = imported.firstOrNull()?.second?.title,
                            completedSummary = "$summary Skipped $deviceSkips device downloads and $serverSkips server uploads.",
                            batchCurrentTitle = null,
                        ),
                    ) }
                }
            }
        } catch (_: CancellationException) {
            upsertImportedPlaylist(playlist.title, imported.map { it.second })
            persistLibrary()
            hideOwnedLinkTransfers(transferGeneration)
            updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                linkImport = state.linkImport.copy(
                    stage = LinkImportStage.Cancelled,
                    batchCurrentTitle = null,
                    completedSummary = "Cancelled after keeping ${imported.size} of ${selected.size} songs.",
                ),
            ) }
        } catch (error: Throwable) {
            upsertImportedPlaylist(playlist.title, imported.map(Pair<LinkImportCandidate, Track>::second))
            persistLibrary()
            hideOwnedLinkTransfers(transferGeneration)
            val detail = error.message ?: "The playlist import failed."
            updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                errorMessage = detail,
                linkImport = state.linkImport.copy(
                    stage = LinkImportStage.Failed,
                    batchCurrentTitle = null,
                    errorCode = "LOCAL_IMPORT_FAILED",
                    errorMessage = detail,
                ),
            ) }
        } finally {
            finishOwnedLinkTransfer(transferGeneration)
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
        batchProgress: ((LinkImportProgress) -> Unit)? = null,
        linkTransferGeneration: Long? = null,
        finalMetadata: (() -> LinkImportTrack?)? = null,
    ): Track {
        val itemNumber = completedBefore + 1

        fun hideFailedAttemptBytes(expectedTitle: String) {
            val boundary = DownloadItemProgressPolicy.hiddenBoundary(
                currentItem = itemNumber,
                totalItems = total,
                title = expectedTitle,
            )
            if (batchProgress != null) {
                batchProgress(LinkImportProgress(LinkImportStage.Downloading))
            } else {
                publishDownloadItemProgress(
                    boundary,
                    linkTransferGeneration = linkTransferGeneration,
                    expectedItem = itemNumber,
                    expectedTitle = expectedTitle,
                )
            }
        }

        var lastError: Throwable? = null
        candidates.forEachIndexed { candidateIndex, candidate ->
            try {
                if (candidateIndex > 0) delay(400)
                linkTransferGeneration?.let(::requireLinkImportTransfer)
                val reset = LinkImportProgress(LinkImportStage.Downloading)
                if (batchProgress != null) {
                    batchProgress(reset)
                } else {
                    publishDownloadItemProgress(
                        DownloadItemProgressPolicy.fromBytes(
                            currentItem = itemNumber,
                            totalItems = total,
                            title = metadata.title,
                            bytesTransferred = 0L,
                            totalBytes = null,
                        ),
                        linkTransferGeneration,
                    )
                }
                val downloaded = linkImportService.download(
                    candidate = candidate,
                    metadata = metadata,
                    mediaMode = mediaMode,
                    includeArtwork = !deferArtwork,
                ) { progress ->
                    if (linkTransferGeneration != null) {
                        applyLinkImportProgress(progress, linkTransferGeneration)
                    }
                    val byteFraction = if (progress.totalBytes > 0) {
                        (progress.completedBytes.toFloat() / progress.totalBytes).coerceIn(0f, 1f)
                    } else 0f
                    if (batchProgress != null) {
                        batchProgress(progress)
                    } else {
                        publishDownloadItemProgress(
                            DownloadItemProgressPolicy.fromBytes(
                                currentItem = itemNumber,
                                totalItems = total,
                                title = metadata.title,
                                bytesTransferred = progress.completedBytes,
                                totalBytes = progress.totalBytes.takeIf { it > 0L },
                                isComplete = byteFraction >= 1f,
                            ),
                            linkTransferGeneration,
                        )
                    }
                }
                // Media acquisition and byte transfer are deliberately ahead of metadata
                // enrichment. Only consult the concurrent catalog task now, immediately before
                // the local file is tagged and registered.
                if (finalMetadata != null) {
                    mutableState.update { state -> state.copy(
                        downloadBytesTransferred = 0L,
                        downloadTotalBytes = null,
                    ) }
                }
                val download = finalMetadata?.invoke()?.let { enriched ->
                    val merged = enriched.copy(
                        album = enriched.album ?: downloaded.metadata.album,
                        durationSeconds = enriched.durationSeconds ?: downloaded.metadata.durationSeconds,
                        artworkURL = enriched.artworkURL ?: downloaded.metadata.artworkURL,
                        sourceURL = enriched.sourceURL.ifBlank { downloaded.metadata.sourceURL },
                    )
                    downloaded.copy(
                        metadata = merged,
                        durationMs = merged.durationSeconds
                            ?.coerceAtLeast(0)
                            ?.times(1_000L)
                            ?: downloaded.durationMs,
                    )
                } ?: downloaded
                linkTransferGeneration?.let(::requireLinkImportTransfer)
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
                    if (linkTransferGeneration != null) {
                        applyLinkImportProgress(
                            LinkImportProgress(LinkImportStage.SavingLocal),
                            linkTransferGeneration,
                        )
                    }
                    repository.registerLocalImport(download).also { imported ->
                        library = normalizeLiked(library.copy(tracks = library.tracks + imported))
                        if (persistImmediately) persistLibrary()
                    }
                }
                return track
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                // Clear this exact item's partial byte presentation before retry backoff or
                // before the final failure returns into persistence/sync work.
                linkTransferGeneration?.let(::requireLinkImportTransfer)
                hideFailedAttemptBytes(metadata.title)
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
        transferGeneration: Long,
    ): String {
        requireLinkImportTransfer(transferGeneration)
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
            requireLinkImportTransfer(transferGeneration)
            updateOwnedLinkImportTransfer(transferGeneration) { state -> state.copy(
                linkImport = state.linkImport.copy(stage = LinkImportStage.Syncing),
                uploadDetail = "Uploading ${index + 1} of $total • ${track.title}",
            ) }
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
                    .onFailure { error ->
                        if (ownsLinkImportTransfer(transferGeneration)) showError(error)
                    }
            }
            return uploaded.id
        }
        throw lastError ?: IllegalStateException("Upload failed")
    }

    private fun beginLinkImportTransfer(): Long {
        linkImportTransferOwnership.cancel()
        return linkImportTransferOwnership.begin()
    }

    private fun ownsLinkImportTransfer(generation: Long): Boolean =
        linkImportTransferOwnership.owns(generation)

    private fun requireLinkImportTransfer(generation: Long) {
        if (!ownsLinkImportTransfer(generation)) {
            throw CancellationException("A newer web import owns the transfer UI")
        }
    }

    private inline fun updateOwnedLinkImportTransfer(
        generation: Long,
        crossinline transform: (ResonanceUiState) -> ResonanceUiState,
    ) {
        if (!ownsLinkImportTransfer(generation)) return
        mutableState.update { state ->
            if (ownsLinkImportTransfer(generation)) transform(state) else state
        }
    }

    private fun cancelOwnedLinkImportTransfer() {
        if (linkImportTransferOwnership.cancel() == null) return
        mutableState.update { state ->
            if (linkImportTransferOwnership.hasActiveSession()) state else state.copy(
                isDownloading = false,
                isUploading = false,
                downloadCurrentItem = 0,
                downloadTotalItems = 0,
                downloadCurrentTitle = null,
                downloadBytesTransferred = 0L,
                downloadTotalBytes = null,
            )
        }
    }

    private fun beginLinkDownloads(
        generation: Long,
        total: Int,
        firstTitle: String? = null,
    ) {
        updateOwnedLinkImportTransfer(generation) { state -> state.copy(
            isUploading = false,
            isDownloading = true,
            downloadProgress = 0f,
            downloadDetail = "Preparing 1 of $total",
            downloadCurrentItem = 1,
            downloadTotalItems = total.coerceAtLeast(1),
            downloadCurrentTitle = firstTitle,
            downloadBytesTransferred = 0L,
            downloadTotalBytes = null,
        ) }
    }

    private fun publishDownloadItemProgress(
        progress: DownloadItemProgressPresentation,
        linkTransferGeneration: Long? = null,
        expectedItem: Int? = null,
        expectedTitle: String? = null,
    ) {
        if (linkTransferGeneration != null && !ownsLinkImportTransfer(linkTransferGeneration)) return
        mutableState.update { state ->
            if (
                (linkTransferGeneration != null && !ownsLinkImportTransfer(linkTransferGeneration)) ||
                (expectedItem != null && state.downloadCurrentItem != expectedItem) ||
                (expectedTitle != null && state.downloadCurrentTitle != expectedTitle)
            ) state else state.copy(
                downloadProgress = progress.fraction,
                downloadDetail = "${progress.currentItem}/${progress.totalItems} • ${progress.title}",
                downloadCurrentItem = progress.currentItem,
                downloadTotalItems = progress.totalItems,
                downloadCurrentTitle = progress.title,
                downloadBytesTransferred = progress.bytesTransferred,
                downloadTotalBytes = progress.totalBytes,
            )
        }
    }

    private fun beginLinkUploads(generation: Long, total: Int) {
        updateOwnedLinkImportTransfer(generation) { state -> state.copy(
            isDownloading = false,
            isUploading = true,
            uploadProgress = 0f,
            uploadDetail = "Preparing 1 of $total",
            linkImport = state.linkImport.copy(stage = LinkImportStage.Syncing),
        ) }
    }

    private fun hideOwnedLinkTransfers(generation: Long) {
        updateOwnedLinkImportTransfer(generation) { state ->
            state.copy(isDownloading = false, isUploading = false)
        }
    }

    private fun finishOwnedLinkTransfer(generation: Long) {
        if (!linkImportTransferOwnership.release(generation)) return
        mutableState.update { state ->
            if (linkImportTransferOwnership.hasActiveSession()) state
            else state.copy(isDownloading = false, isUploading = false)
        }
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
        cancelOwnedLinkImportTransfer()
        stopLinkImportPreview()
        linkImportJob?.cancel()
        linkImportJob = null
        mutableState.update { state -> state.copy(
            linkImport = LinkImportUiState(stage = LinkImportStage.Cancelled),
        ) }
    }

    private fun applyLinkImportProgress(progress: LinkImportProgress, generation: Long) {
        updateOwnedLinkImportTransfer(generation) { state -> state.copy(
            linkImport = state.linkImport.copy(
                stage = progress.stage,
                completedBytes = progress.completedBytes,
                totalBytes = progress.totalBytes,
            ),
        ) }
    }

    private fun applyLinkImportProgress(progress: LinkImportProgress) {
        // Resolver progress never owns a transfer popup and must not overwrite an active import.
        if (mutableState.value.isDownloading || mutableState.value.isUploading) return
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
                errorMessage = error.message ?: "The web import failed.",
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
                        errorMessage = "Use Import from Web so Resonance can preserve and register the direct source URL.",
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
                        authoritativeCatalogSnapshot = snapshot
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
        ).let { associated ->
            val hasCatalogArtwork = !mutableState.value.remoteSongs
                .firstOrNull { it.id == remoteID }
                ?.artworkURL
                .isNullOrBlank()
            if (hasCatalogArtwork) associated.copy(artworkScanComplete = false) else associated
        }
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
        if (mutableState.value.listenAlong.isGuest) return
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
        publishListenAlongSnapshot()
    }

    private fun listeningPlaybackSnapshot(player: Player): ListeningPlaybackSnapshot? {
        val mediaID = player.currentMediaItem?.mediaId?.takeIf(String::isNotBlank) ?: return null
        library.tracks.firstOrNull { it.id == mediaID }?.let { track ->
            val connectedServer = activeAccessToken().takeIf(String::isNotBlank)?.let { library.serverURL }
            return ListeningPlaybackSnapshot(
                track = track,
                serverURL = connectedServer ?: track.sourceServer,
                profileID = track.syncProfileID?.takeIf(String::isNotBlank) ?: library.syncProfileID,
                remoteSongID = track.remoteID,
                artworkURL = track.remoteID?.let { remoteID ->
                    mutableState.value.remoteSongs.firstOrNull { it.id == remoteID }?.artworkURL
                },
            )
        }
        val transient = activeStreamPresentation?.takeIf { it.id == mediaID } ?: return null
        val streamContext = activeStreamPolicyContext ?: currentServerProfileContext()
        return ListeningPlaybackSnapshot(
            track = transient,
            serverURL = streamContext?.serverURL,
            profileID = streamContext?.profileID ?: library.syncProfileID,
            remoteSongID = transient.remoteID ?: mediaID.removePrefix("remote-stream:")
                .substringBefore(':').takeIf(String::isNotBlank),
            artworkURL = mutableState.value.transientArtworkURL,
        )
    }

    private fun playbackPositionSeconds(player: Player): Double =
        (player.currentPosition.takeIf { it != C.TIME_UNSET && it >= 0L } ?: 0L) / 1_000.0

    private fun updateListeningSession(flush: Boolean = false) {
        val player = controller ?: return
        val snapshot = listeningPlaybackSnapshot(player)
        val activeID = activeListeningEntryID
        if (activeID == null) {
            if (player.isPlaying && snapshot != null) beginListeningSession(snapshot, player)
            return
        }
        val active = library.listeningHistory.firstOrNull { it.id == activeID }
        if (active == null) {
            clearListeningSessionState()
            if (player.isPlaying && snapshot != null) beginListeningSession(snapshot, player)
            return
        }
        val sameSession = snapshot != null && active.trackID == snapshot.track.id &&
            active.syncProfileID.ifBlank { "default" } == snapshot.profileID.ifBlank { "default" } &&
            active.serverOrigin == snapshot.serverURL?.let(RemoteTrackIdentityPolicy::normalizedOrigin)
        if (!sameSession) {
            finishListeningSession(flush = true)
            if (player.isPlaying && snapshot != null) beginListeningSession(snapshot, player)
            return
        }
        val position = playbackPositionSeconds(player)
        val updated = ListeningHistoryPlaybackPolicy.advance(
            active,
            position,
            lastListeningPositionSeconds,
            player.isPlaying,
            player.duration.takeIf { it != C.TIME_UNSET && it > 0L }?.div(1_000.0),
        )
        lastListeningPositionSeconds = position
        if (updated != active) {
            library = library.copy(listeningHistory = library.listeningHistory.map { if (it.id == activeID) updated else it })
            if (flush || updated.listenedSeconds - lastPersistedListeningSeconds >= 15.0) {
                lastPersistedListeningSeconds = updated.listenedSeconds
                saveSoon()
                scheduleListeningHistorySync()
            }
        } else if (flush) saveSoon()
    }

    private fun beginListeningSession(snapshot: ListeningPlaybackSnapshot, player: Player) {
        if (activeListeningEntryID != null) finishListeningSession(flush = true)
        val entry = ListeningHistoryRetentionPolicy.entry(
            snapshot.track,
            snapshot.serverURL,
            snapshot.profileID,
            snapshot.remoteSongID,
            snapshot.artworkURL,
        )
        library = library.copy(listeningHistory = ListeningHistoryRetentionPolicy.append(library.listeningHistory, entry))
        activeListeningEntryID = entry.id
        lastListeningPositionSeconds = playbackPositionSeconds(player)
        lastPersistedListeningSeconds = 0.0
        saveSoon()
    }

    private fun finishListeningSession(flush: Boolean) {
        val activeID = activeListeningEntryID ?: return
        val player = controller
        val snapshot = player?.let(::listeningPlaybackSnapshot)
        val active = library.listeningHistory.firstOrNull { it.id == activeID }
        if (active != null && player != null && snapshot != null &&
            active.trackID == snapshot.track.id &&
            active.syncProfileID.ifBlank { "default" } == snapshot.profileID.ifBlank { "default" }
        ) {
            val updated = ListeningHistoryPlaybackPolicy.advance(
                active,
                playbackPositionSeconds(player),
                lastListeningPositionSeconds,
                player.isPlaying,
                player.duration.takeIf { it != C.TIME_UNSET && it > 0L }?.div(1_000.0),
            )
            if (updated != active) {
                library = library.copy(listeningHistory = library.listeningHistory.map { if (it.id == activeID) updated else it })
            }
        }
        if (flush) {
            saveSoon()
            scheduleListeningHistorySync()
        }
        clearListeningSessionState()
    }

    private fun clearListeningSessionState() {
        activeListeningEntryID = null
        lastListeningPositionSeconds = 0.0
        lastPersistedListeningSeconds = 0.0
    }

    override fun togglePlayPause() {
        if (mutableState.value.listenAlong.isGuest) return
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
        publishListenAlongSnapshot()
    }

    override fun playNext() {
        if (activeStreamPresentation != null || mutableState.value.listenAlong.isGuest) return
        updateListeningSession(flush = true)
        controller?.seekToNextMediaItem()
        publishListenAlongSnapshot()
    }

    override fun playPrevious() {
        if (activeStreamPresentation != null || mutableState.value.listenAlong.isGuest) return
        controller?.let { player ->
            updateListeningSession(flush = true)
            val track = player.currentMediaItem?.mediaId?.let { id -> library.tracks.firstOrNull { it.id == id } }
            val start = track?.let(::playbackRange)?.startMs ?: 0L
            if (player.currentPosition > start + 3_000) player.seekTo(start) else player.seekToPreviousMediaItem()
        }
        publishListenAlongSnapshot()
    }

    override fun seekToFraction(fraction: Float) {
        if (mutableState.value.listenAlong.isGuest) return
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
        publishListenAlongSnapshot()
    }

    override fun setShuffleEnabled(enabled: Boolean) {
        if (activeStreamPresentation != null || mutableState.value.listenAlong.isGuest) return
        controller?.shuffleModeEnabled = enabled
        mutableState.value = mutableState.value.copy(shuffleEnabled = enabled)
        preferences.edit().putBoolean("shuffle", enabled).apply()
    }

    override fun setRepeatEnabled(enabled: Boolean) {
        if (mutableState.value.listenAlong.isGuest) return
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

    fun retryRemoteSongMetadataIfNeeded() {
        if (remoteSongMetadataHydrationJob?.isActive == true) return
        if (mutableState.value.remoteSongs.none(RemoteSong::isMetadataLoading)) return
        val context = currentServerProfileContext() ?: return
        if (activeAccessToken().isBlank()) return
        beginRemoteSongMetadataHydration(context, serverClient(context))
    }

    override fun setCrossfadeEnabled(enabled: Boolean) {
        mutableState.value = mutableState.value.copy(crossfadeEnabled = enabled)
        preferences.edit().putBoolean("crossfadeEnabled", enabled).apply()
    }

    override fun setCrossfadeSeconds(seconds: Float) {
        val normalized = CrossfadePolicy.normalizedSeconds(seconds)
        mutableState.value = mutableState.value.copy(crossfadeSeconds = normalized)
        preferences.edit().putFloat("crossfadeSeconds", normalized).apply()
    }

    override fun setThemeChoice(choice: ResonanceThemeChoice) {
        if (mutableState.value.themeChoice == choice) return
        mutableState.value = mutableState.value.copy(themeChoice = choice)
        appearancePreferences.edit().putString("theme", choice.storageID).apply()
    }

    override fun refreshDownloadedSongMetadata() {
        if (mutableState.value.isRefreshingDownloadedMetadata) return
        viewModelScope.launch {
            val candidates = library.tracks.filter { repository.fileForTrack(it).isFile }
            if (candidates.isEmpty()) {
                mutableState.update {
                    it.copy(downloadedMetadataRefreshDetail = "No downloaded songs are available to refresh.")
                }
                return@launch
            }

            mutableState.update {
                it.copy(
                    isRefreshingDownloadedMetadata = true,
                    downloadedMetadataRefreshDetail = "Preparing ${candidates.size} song${if (candidates.size == 1) "" else "s"}…",
                )
            }
            var sourceFailures = 0
            try {
                candidates.forEachIndexed { index, snapshot ->
                    mutableState.update {
                        it.copy(
                            downloadedMetadataRefreshDetail = "Refreshing ${index + 1} of ${candidates.size} • ${snapshot.title}",
                        )
                    }
                    val embedded = repository.refreshEmbeddedMetadata(snapshot)
                    var refreshed = embedded
                    val source = DownloadedSongMetadataRefreshPolicy.sourceURL(
                        embedded,
                        fileExists = repository.fileForTrack(embedded).isFile,
                    )
                    if (source != null) {
                        try {
                            val metadata = linkImportService.resolveMetadata(source)
                            val artwork = linkImportService.artworkData(metadata.artworkURL)
                            val artworkTrack = if (artwork != null) {
                                repository.persistArtwork(refreshed, artwork)
                            } else {
                                refreshed
                            }
                            refreshed = DownloadedSongMetadataRefreshPolicy.apply(
                                artworkTrack,
                                metadata,
                                artworkTrack.artworkFilename.takeIf { artwork != null },
                            )
                            val mediaKind = if (repository.fileForTrack(refreshed).extension.lowercase() in
                                setOf("mp4", "mov", "m4v", "webm")) "video" else "audio"
                            RemoteSongMetadataCachePolicy.key(source, mediaKind)?.let { cacheKey ->
                                library = library.copy(
                                    remoteSongMetadataCache = library.remoteSongMetadataCache + (
                                        cacheKey to RemoteSongMetadataCacheEntry(
                                            sourceURL = source,
                                            mediaKind = mediaKind,
                                            title = metadata.title,
                                            artist = metadata.artist,
                                            album = metadata.album,
                                            durationSeconds = metadata.durationSeconds?.toDouble(),
                                            artworkURL = metadata.artworkURL,
                                            cachedAtEpochMs = System.currentTimeMillis(),
                                        )
                                    ),
                                )
                            }
                            refreshed.remoteID?.let { remoteID ->
                                mutableState.update { state ->
                                    state.copy(remoteSongs = state.remoteSongs.map { song ->
                                        if (song.id == remoteID) applyRemoteSongMetadata(song, metadata) else song
                                    })
                                }
                            }
                        } catch (error: CancellationException) {
                            throw error
                        } catch (_: Throwable) {
                            sourceFailures += 1
                        }
                    }
                    library = library.copy(
                        tracks = library.tracks.map { current ->
                            if (current.id == snapshot.id) refreshed else current
                        },
                    )
                }
                persistLibrary()
                refreshQueuedClipMetadata()
                mutableState.update {
                    it.copy(
                        downloadedMetadataRefreshDetail = if (sourceFailures == 0) {
                            "Re-cached metadata for ${candidates.size} song${if (candidates.size == 1) "" else "s"}."
                        } else {
                            "Re-cached ${candidates.size} song${if (candidates.size == 1) "" else "s"} • $sourceFailures source refresh${if (sourceFailures == 1) "" else "es"} failed."
                        },
                    )
                }
            } finally {
                mutableState.update { it.copy(isRefreshingDownloadedMetadata = false) }
            }
        }
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
            val tracksBeforeDeletion = library.tracks
            val deletingTracks = tracksBeforeDeletion.filter { it.id in trackIds }
            val clipKeys = deletingTracks
                .mapTo(linkedSetOf(), ::clipRangeKey)
            val serverState = mutableState.value
            val catalogRemoteSongIDs = serverState.remoteSongs.mapTo(hashSetOf(), RemoteSong::id)
            val activeRemoteSongIDs = deletingTracks.mapNotNullTo(hashSetOf()) { track ->
                track.remoteID?.takeIf { remoteID ->
                    RemoteTrackIdentityPolicy.matches(
                        track,
                        library.serverURL,
                        library.syncProfileID,
                        remoteID,
                    ) && remoteID in catalogRemoteSongIDs
                }
            }
            val catalogIsAuthoritative = serverState.hasConnectedServerSession &&
                CatalogAuthorityPolicy.isFresh(
                    authoritativeSnapshot = authoritativeCatalogSnapshot,
                    currentContext = currentServerProfileContext(),
                    currentRequestGeneration = catalogRequestGeneration,
                    currentUploadMutationGeneration = uploadMutationGeneration,
                )
            val playlistsBeforeDeletion = library.playlists
            val playlistsAfterDeletion = playlistsBeforeDeletion.map { playlist ->
                PlaylistLocalDeletionPolicy.apply(
                    playlist = playlist,
                    tracks = tracksBeforeDeletion,
                    deletingTrackIDs = trackIds,
                    activeRemoteSongIDs = activeRemoteSongIDs,
                    activeServerURL = library.serverURL,
                    activeProfileID = library.syncProfileID,
                    // A stale, failed, or superseded refresh is not evidence of backing or deletion.
                    catalogIsAuthoritative = catalogIsAuthoritative,
                )
            }
            val remotelyChangedPlaylistIDs = playlistsBeforeDeletion.zip(playlistsAfterDeletion)
                .mapNotNull { (before, after) ->
                    before.id.takeIf {
                        !before.isSystem && before.remoteSongIDs != after.remoteSongIDs
                    }
                }
                .toSet()
            if (remotelyChangedPlaylistIDs.isNotEmpty()) playlistMutationGeneration += 1
            library = library.copy(
                playlists = playlistsAfterDeletion,
                dirtyPlaylistIDs = library.dirtyPlaylistIDs.orEmpty() + remotelyChangedPlaylistIDs,
                deletedPlaylistIDs = library.deletedPlaylistIDs.orEmpty() - remotelyChangedPlaylistIDs,
            )
            library = repository.deleteLocalTracks(library, trackIds)
            library = library.copy(
                clipRanges = library.clipRanges - clipKeys,
                dirtyClipRangeKeys = library.dirtyClipRangeKeys - clipKeys,
                deletedClipRangeKeys = library.deletedClipRangeKeys - clipKeys,
            )
            persistLibrary()
            if (remotelyChangedPlaylistIDs.isNotEmpty()) syncPlaylistsNow()
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
            PlaylistEntryOrderPolicy.move(
                playlist = playlist,
                tracks = mutableState.value.tracks,
                remoteSongs = mutableState.value.remoteSongs,
                fromIndex = fromIndex,
                toIndex = toIndex,
            )
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
        if (state.serverUploadMode != mode && state.linkImport.isRunning) {
            cancelOwnedLinkImportTransfer()
            linkImportJob?.cancel()
        }
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
            invalidateActiveRemoteDownload("Download stopped because the download mode changed")
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
        val refreshPresentation = mutableState.value.let { state ->
            ServerRefreshPresentationPolicy.snapshot(state.serverMessage, state.isConnected)
        }
        mutableState.value = mutableState.value.copy(
            isRefreshingServer = true,
            serverMessage = ServerRefreshPresentationPolicy.messageWhileRefreshing(refreshPresentation),
        )
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
                    hasConnectedServerSession = true,
                    serverMessage = if (applyCatalog) {
                        "Connected • ${catalog.count} song${if (catalog.count == 1) "" else "s"}"
                    } else {
                        "Connected"
                    },
                )
                if (applyCatalog) {
                    authoritativeCatalogSnapshot = catalogSnapshot
                    beginRemoteSongMetadataHydration(catalogSnapshot.context, client)
                }
                if (applyCatalog && backfillDownloadedArtwork(client, catalogSongs)) {
                    persistLibrary()
                } else {
                    saveSoon()
                }
                syncPlaylistsNow()
                syncListeningHistoryNow(force = true)
            }
            .onFailure { error ->
                if (currentServerProfileContext() != catalogSnapshot.context) return@onFailure
                val authenticationFailure = ServerRefreshPresentationPolicy.isAuthenticationFailure(error)
                val preservesSession = ServerRefreshPresentationPolicy.preservesConnectedSession(
                    refreshPresentation,
                    error,
                )
                if (authenticationFailure) cancelRemoteSongMetadataHydration()
                mutableState.value = mutableState.value.copy(
                    // A refresh is best-effort. Keep the last proven catalog/session and its
                    // connected presentation for transient failures. Authentication failures
                    // require a real reconnect and must not leave stale catalog state connected.
                    remoteSongs = if (authenticationFailure) emptyList() else mutableState.value.remoteSongs,
                    selectedRemoteSongIds = if (authenticationFailure) emptySet() else mutableState.value.selectedRemoteSongIds,
                    hasConnectedServerSession = if (preservesSession) {
                        mutableState.value.hasConnectedServerSession
                    } else {
                        false
                    },
                    serverMessage = ServerRefreshPresentationPolicy.messageAfterFailure(
                        refreshPresentation,
                        error.message,
                        authenticationFailure,
                    ),
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
            if (song.requiresOriginalSourcePage) {
                return@map applyOriginalSourceMetadataFailure(song)
            }
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
                ?: return@map song
            library.remoteSongMetadataCache[key]?.let { cached ->
                return@map applyRemoteSongMetadata(song, cached)
            }
            val resolutionKey = currentServerProfileContext()?.let { context ->
                RemoteSourceResolutionCachePolicy.key(
                    context = context,
                    mediaMode = if (song.isVideoMedia) LinkImportMediaMode.Video else LinkImportMediaMode.Audio,
                    sourceURL = song.sourceURL,
                    accountScope = accountSession?.accountID,
                )
            }
            resolutionKey
                ?.let(remoteSourceResolutions::get)
                ?.takeIf { resolution ->
                    RemoteSourceResolutionCachePolicy.canReuse(
                        resolution = resolution,
                        cachedKey = resolutionKey,
                        expectedKey = resolutionKey,
                        knownCatalogMetadata = null,
                    )
                }
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
        remoteSongMetadataHydrationGeneration += 1
        val generation = remoteSongMetadataHydrationGeneration
        remoteSongMetadataHydrationJob = viewModelScope.launch {
            var cacheChanged = false
            var failedAttemptCount = 0
            while (isActive && isCurrentRemoteSongMetadataHydration(generation, context)) {
                val requests = remoteSongMetadataRequests(mutableState.value.remoteSongs)
                if (requests.isEmpty()) break
                var anyFailure = false

                for (batch in requests.chunked(4)) {
                    val results = coroutineScope {
                        batch.map { request ->
                            async {
                                val task = remoteSongMetadataTask(request, generation, context)
                                val metadata = task.await()
                                RemoteSongMetadataResult(request, metadata)
                            }
                        }.awaitAll()
                    }
                    if (!isCurrentRemoteSongMetadataHydration(generation, context)) return@launch

                    var songs = mutableState.value.remoteSongs
                    results.forEach { result ->
                        val metadata = result.metadata
                        if (metadata == null) {
                            anyFailure = true
                            return@forEach
                        }
                        val songIDs = result.request.songIDs.toSet()
                        songs = songs.map { song ->
                            if (song.id !in songIDs || !song.isMetadataLoading) song
                            else applyRemoteSongMetadata(song, metadata)
                        }
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
                    mutableState.value = mutableState.value.copy(remoteSongs = songs)
                    results.forEach { result ->
                        forgetRemoteSongMetadataTask(result.request, generation, context)
                    }
                }

                if (!anyFailure) break
                failedAttemptCount += 1
                if (!RemoteSongMetadataRetryPolicy.shouldRetryAfterFailure(failedAttemptCount)) break
                delay(RemoteSongMetadataRetryPolicy.delayAfterFailureMs(failedAttemptCount))
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
        songs.filter { it.isMetadataLoading && !it.requiresOriginalSourcePage }.forEach { song ->
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

    private fun remoteSongMetadataTask(
        request: RemoteSongMetadataRequest,
        generation: Long,
        context: ServerProfileContext,
    ): Deferred<LinkImportTrack?> {
        val key = RemoteSongMetadataTaskKey(generation, context, request.cacheKey)
        return synchronized(remoteSongMetadataTaskLock) {
            remoteSongMetadataTasks[key] ?: viewModelScope.async(Dispatchers.IO) {
                try {
                    linkImportService.resolveMetadata(request.source)
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Throwable) {
                    null
                }
            }.also { remoteSongMetadataTasks[key] = it }
        }
    }

    private fun remoteSongMetadataTask(
        song: RemoteSong,
        context: ServerProfileContext,
    ): Deferred<LinkImportTrack?>? {
        val source = song.sourceURL?.trim().orEmpty()
        val cacheKey = remoteSongMetadataCacheKey(song) ?: return null
        val request = RemoteSongMetadataRequest(listOf(song.id), cacheKey, source, song.mediaKind)
        return remoteSongMetadataTask(request, remoteSongMetadataHydrationGeneration, context)
    }

    private fun forgetRemoteSongMetadataTask(
        request: RemoteSongMetadataRequest,
        generation: Long,
        context: ServerProfileContext,
    ) {
        synchronized(remoteSongMetadataTaskLock) {
            remoteSongMetadataTasks.remove(RemoteSongMetadataTaskKey(generation, context, request.cacheKey))
        }
    }

    private fun isCurrentRemoteSongMetadataHydration(
        generation: Long,
        context: ServerProfileContext,
    ): Boolean = generation == remoteSongMetadataHydrationGeneration &&
        currentServerProfileContext() == context

    private fun cancelRemoteSongMetadataHydration() {
        remoteSongMetadataHydrationJob?.cancel()
        remoteSongMetadataHydrationJob = null
        val tasks = synchronized(remoteSongMetadataTaskLock) {
            remoteSongMetadataTasks.values.toList().also { remoteSongMetadataTasks.clear() }
        }
        tasks.forEach { it.cancel() }
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

    private fun applyOriginalSourceMetadataFailure(song: RemoteSong): RemoteSong = song.copy(
        title = "Original source link needed",
        artist = "Re-import on the original device",
        album = "Legacy expired link",
        isMetadataLoading = false,
    )

    private fun recordRemoteSongMetadata(
        songID: String,
        metadata: LinkImportTrack,
        context: ServerProfileContext,
    ) {
        if (currentServerProfileContext() != context) return
        val song = mutableState.value.remoteSongs.firstOrNull { it.id == songID } ?: return
        if (!song.isMetadataLoading) return
        mutableState.value = mutableState.value.copy(
            remoteSongs = mutableState.value.remoteSongs.map { current ->
                if (current.id == songID && current.isMetadataLoading) {
                    applyRemoteSongMetadata(current, metadata)
                } else {
                    current
                }
            },
        )
        val cacheKey = remoteSongMetadataCacheKey(song) ?: return
        library = library.copy(
            remoteSongMetadataCache = library.remoteSongMetadataCache + (
                cacheKey to RemoteSongMetadataCacheEntry(
                    sourceURL = requireNotNull(song.sourceURL).trim(),
                    mediaKind = song.mediaKind,
                    title = metadata.title,
                    artist = metadata.artist,
                    album = metadata.album,
                    durationSeconds = metadata.durationSeconds?.toDouble(),
                    artworkURL = metadata.artworkURL,
                    cachedAtEpochMs = System.currentTimeMillis(),
                )
            ),
        )
    }

    private suspend fun backfillDownloadedArtwork(
        client: ServerClient,
        songs: List<RemoteSong>,
    ): Boolean {
        val songsByID = songs.associateBy(RemoteSong::id)
        val candidates = library.tracks.filter { track ->
            val existingArtwork = repository.artworkFile(track)?.takeIf(File::isFile)
            val song = track.takeIf(::trackBelongsToActiveContext)?.remoteID?.let(songsByID::get)
            trackBelongsToActiveContext(track) && RemoteArtworkPersistencePolicy.shouldBackfill(
                artworkScanComplete = track.artworkScanComplete,
                existingArtworkBytes = existingArtwork?.length(),
                artworkURL = song?.artworkURL,
            )
        }
        var changed = false

        for (track in candidates) {
            val song = track.remoteID?.let(songsByID::get) ?: continue
            val repaired = runCatching {
                client.fetchArtwork(song)?.let { repository.persistArtwork(track, it) }
            }.getOrNull() ?: track
            if (repaired != track) {
                // Metadata hydration and media downloads intentionally overlap. Merge only the
                // artwork fields into the latest library value so a concurrent downloaded track
                // or server association can never be replaced by this older iteration snapshot.
                library = library.copy(tracks = library.tracks.map { current ->
                    if (current.id != track.id) current else current.copy(
                        artworkFilename = repaired.artworkFilename,
                        artworkScanComplete = repaired.artworkScanComplete,
                    )
                })
                changed = true
            }
        }
        return changed
    }

    override fun saveServerConnection(url: String, accessToken: String, adminKey: String, profileName: String) {
        val state = mutableState.value
        if (state.isApplyingServerConnection || state.isRefreshingServer || state.isDownloading || state.isUploading || state.isSyncingPlaylists) {
            mutableState.value = state.copy(serverMessage = "Wait for the current connection or transfer to finish.")
            return
        }
        finishListeningSession(flush = true)
        listeningHistorySyncJob?.cancel()
        listeningHistorySyncJob = null
        listeningHistorySyncPending = false
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
        val previousConnectedSession = state.hasConnectedServerSession
        invalidateActiveRemoteDownload("Download stopped because the server connection changed")
        clearListenAlongSession(stopPlayback = true)
        connectionGeneration += 1
        remoteSourceResolutions.clear()
        authoritativeCatalogSnapshot = null
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
                hasConnectedServerSession = false,
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
            hasConnectedServerSession = false,
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
                        hasConnectedServerSession = previousConnectedSession,
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
        finishListeningSession(flush = true)
        listeningHistorySyncJob?.cancel()
        listeningHistorySyncJob = null
        listeningHistorySyncPending = false
        RemoteDownloadContextChangePolicy.mutateAfterInvalidation(
            invalidateDownload = {
                invalidateActiveRemoteDownload("Download stopped because the server profile changed")
            },
            mutation = {
                clearListenAlongSession(stopPlayback = true)
                cancelRemoteSongMetadataHydration()
                connectionGeneration += 1
                remoteSourceResolutions.clear()
                authoritativeCatalogSnapshot = null
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
                    hasConnectedServerSession = false,
                )
                resetClientConfigForCurrentContext("Safe defaults • profile changed")
            },
        )
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
        runCatching { requireDownloadPolicySnapshot(snapshot, requireOwnership = false) }.onFailure {
            mutableState.value = mutableState.value.copy(
                errorMessage = "The server download policy changed; review the mode and try again.",
            )
            return
        }
        val requestedSongs = mutableState.value.remoteSongs.filter { it.id in ids }
        if (requestedSongs.isEmpty()) return
        val existingRemoteIDs = library.tracks
            .filter(::trackBelongsToActiveContext)
            .mapNotNullTo(mutableSetOf(), Track::remoteID)
        val pendingSongs = PendingDownloadBatchPolicy.songs(requestedSongs, existingRemoteIDs)
        val cachedRequestedIDs = requestedSongs.mapNotNullTo(mutableSetOf()) { song ->
            song.id.takeIf(existingRemoteIDs::contains)
        }
        if (pendingSongs.isEmpty()) {
            mutableState.value = mutableState.value.copy(
                selectedRemoteSongIds = mutableState.value.selectedRemoteSongIds - ids,
                downloadDetail = "Already downloaded",
            )
            return
        }
        val pendingSourceSongs = pendingSongs.filter(RemoteSong::isSourceLinkRecord)
        val pendingFileSongs = pendingSongs.filterNot(RemoteSong::isSourceLinkRecord)
        val firstPendingSong = pendingSourceSongs.firstOrNull() ?: pendingFileSongs.first()
        mutableState.value = mutableState.value.copy(
            isDownloading = true,
            downloadProgress = 0f,
            downloadDetail = "Downloading",
            downloadCurrentItem = 1,
            downloadTotalItems = pendingSongs.size,
            downloadCurrentTitle = firstPendingSong.title,
            downloadBytesTransferred = 0L,
            downloadTotalBytes = firstPendingSong.size.takeIf { it > 0L },
        )
        activeDownloadPolicySnapshot = snapshot
        remoteDownloadJob?.cancel()
        remoteDownloadExpiryJob?.cancel()
        val downloadClient = serverClient(transferContext)
        val job = viewModelScope.launch {
            try {
                val sourceSongs = pendingSourceSongs
                var sourceDownloads = 0
                var sourceProcessed = 0
                val sourceFailures = mutableListOf<String>()
                val downloadedRemoteIDs = mutableSetOf<String>()
                if (sourceSongs.isNotEmpty()) {
                    try {
                        // The popup represents one song, so source-link items are intentionally
                        // serialized too; retries reset the same catalog title to zero bytes.
                        for (song in sourceSongs) {
                            requireDownloadPolicySnapshot(snapshot)
                            publishDownloadItemProgress(
                                DownloadItemProgressPolicy.fromBytes(
                                    currentItem = sourceProcessed + 1,
                                    totalItems = pendingSongs.size,
                                    title = song.title,
                                    bytesTransferred = 0L,
                                    totalBytes = song.size.takeIf { it > 0L },
                                ),
                            )
                            val itemResult = try {
                                val source = requireNotNull(song.sourceURL)
                                val mediaMode = if (song.isVideoMedia) {
                                    LinkImportMediaMode.Video
                                } else {
                                    LinkImportMediaMode.Audio
                                }
                                val knownCatalogMetadata = RemoteSongDownloadMetadataPolicy.knownTrack(song)
                                val concurrentMetadata = if (
                                    knownCatalogMetadata == null &&
                                    remoteSongMetadataHydrationJob?.isActive == true
                                ) {
                                    remoteSongMetadataTask(song, snapshot.context)
                                } else {
                                    null
                                }
                                val resolutionKey = requireNotNull(
                                    RemoteSourceResolutionCachePolicy.key(
                                        context = snapshot.context,
                                        mediaMode = mediaMode,
                                        sourceURL = source,
                                        accountScope = accountSession?.accountID,
                                    ),
                                ) { "The saved song source is not a valid HTTPS track URL." }
                                val acquisition = RemoteSourceDownloadCoordinator.acquireMedia(
                                    metadata = concurrentMetadata,
                                ) {
                                    val cachedResolution = remoteSourceResolutions[resolutionKey]
                                    cachedResolution?.takeIf { cached ->
                                        RemoteSourceResolutionCachePolicy.canReuse(
                                            resolution = cached,
                                            cachedKey = resolutionKey,
                                            expectedKey = resolutionKey,
                                            knownCatalogMetadata = knownCatalogMetadata,
                                        )
                                    } ?: linkImportService.resolveForDownload(
                                            source = source,
                                            mediaMode = mediaMode,
                                            knownTrackMetadata = knownCatalogMetadata,
                                        ) { }
                                            .also { remoteSourceResolutions[resolutionKey] = it }
                                }
                                val resolution = acquisition.media
                                check(resolution.kind == LinkImportKind.Track) {
                                    "A saved song link resolved to a playlist instead of one song."
                                }
                                val transferTitle = knownCatalogMetadata?.title ?: resolution.track.title
                                val track = downloadLinkTrack(
                                    metadata = resolution.track,
                                    candidates = resolution.candidates,
                                    mediaMode = mediaMode,
                                    completedBefore = sourceProcessed,
                                    total = pendingSongs.size,
                                    deferArtwork = true,
                                    persistImmediately = false,
                                    batchProgress = { progress ->
                                        requireDownloadPolicySnapshot(snapshot)
                                        publishDownloadItemProgress(
                                            DownloadItemProgressPolicy.fromBytes(
                                                currentItem = sourceProcessed + 1,
                                                totalItems = pendingSongs.size,
                                                title = transferTitle,
                                                bytesTransferred = progress.completedBytes,
                                                totalBytes = progress.totalBytes.takeIf { it > 0L },
                                                isComplete = progress.totalBytes > 0L &&
                                                    progress.completedBytes >= progress.totalBytes,
                                            ),
                                        )
                                    },
                                    finalMetadata = {
                                        requireDownloadPolicySnapshot(snapshot)
                                        val currentCatalogMetadata = mutableState.value.remoteSongs
                                            .firstOrNull { current -> current.id == song.id }
                                            ?.let(RemoteSongDownloadMetadataPolicy::knownTrack)
                                        if (currentCatalogMetadata != null) {
                                            currentCatalogMetadata
                                        } else {
                                            RemoteSourceDownloadCoordinator.completedMetadataOrNull(
                                                acquisition.metadata,
                                            )?.also { enriched ->
                                                recordRemoteSongMetadata(song.id, enriched, snapshot.context)
                                            }
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
                            itemResult.remoteID?.let {
                                downloadedRemoteIDs += it
                                sourceDownloads += 1
                            }
                            itemResult.failure?.let(sourceFailures::add)
                            sourceProcessed += 1
                        }
                    } finally {
                        // Source imports, provenance, and remote associations are
                        // checkpointed once for the batch (also on cancellation).
                        persistLibrary()
                    }
                }
                val catalog = mov.unblocked.resonance.data.RemoteCatalog(
                    pendingFileSongs,
                )
                val catalogTitlesByID = pendingSongs.associate { it.id to it.title }
                val result = downloadClient.downloadSelected(
                    catalog = catalog,
                    selectedIDs = catalog.songs.mapTo(mutableSetOf(), RemoteSong::id),
                    repository = repository,
                    existingRemoteIDs = existingRemoteIDs,
                    onProgress = { progress ->
                        publishDownloadItemProgress(
                            DownloadItemProgressPolicy.fromCatalogTransfer(
                                progress = progress,
                                completedBefore = sourceProcessed,
                                batchTotal = pendingSongs.size,
                                catalogTitlesByID = catalogTitlesByID,
                            ),
                        )
                    },
                    beforeEach = { requireDownloadPolicySnapshot(snapshot) },
                )
                requireDownloadPolicySnapshot(snapshot)
                downloadedRemoteIDs += result.tracks.mapNotNull(Track::remoteID)
                library = hydrateRemoteLikes(hydrateRemotePlaylists(
                    library.copy(tracks = library.tracks + result.tracks),
                ))
                // Media downloads stay serialized and fast; once the batch is complete, replace
                // temporary embedded covers with artwork bound to each catalog song ID.
                backfillDownloadedArtwork(downloadClient, mutableState.value.remoteSongs)
                persistLibrary()
                val downloadedCount = sourceDownloads + result.tracks.size
                val failedCount = sourceFailures.size + result.failures.size
                val detail = if (failedCount == 0) {
                    "Downloaded $downloadedCount song${if (downloadedCount == 1) "" else "s"}"
                } else {
                    "Downloaded $downloadedCount of ${pendingSongs.size} • $failedCount failed"
                }
                mutableState.value = mutableState.value.copy(
                    selectedRemoteSongIds = mutableState.value.selectedRemoteSongIds -
                        (cachedRequestedIDs + downloadedRemoteIDs),
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
                        retryRemoteSongMetadataIfNeeded()
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

    private fun invalidateActiveRemoteDownload(detail: String) {
        val job = remoteDownloadJob
        val hadActiveDownload = activeDownloadPolicySnapshot != null || job != null
        // Invalidate ownership before requesting cancellation. Any callback already queued on
        // Main will fail requireDownloadPolicySnapshot even if credential mutation follows now.
        activeDownloadPolicySnapshot = null
        remoteDownloadExpiryJob?.cancel()
        remoteDownloadExpiryJob = null
        remoteDownloadJob = null
        job?.cancel(CancellationException(detail))
        if (!hadActiveDownload) return
        mutableState.value = mutableState.value.copy(
            isDownloading = false,
            downloadProgress = 0f,
            downloadDetail = detail,
            downloadCurrentItem = 0,
            downloadTotalItems = 0,
            downloadCurrentTitle = null,
            downloadBytesTransferred = 0L,
            downloadTotalBytes = null,
        )
    }

    private fun requireDownloadPolicySnapshot(
        snapshot: ServerDownloadPolicySnapshot,
        requireOwnership: Boolean = true,
    ) {
        val state = mutableState.value
        if (requireOwnership && activeDownloadPolicySnapshot != snapshot) {
            throw CancellationException("The server download is no longer active")
        }
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
        activeStreamSourceURL = song.sourceURL
        val metadataExtras = Bundle().apply {
            song.artworkURL?.takeIf(String::isNotBlank)?.let {
                putString(STREAM_ARTWORK_URL_EXTRA, it)
            }
        }
        val metadata = publishedMediaMetadata(
            title = song.title,
            artist = song.artist,
            album = song.album,
            durationMs = presentation.durationMs,
            extras = metadataExtras,
        )
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
        publishStreamArtwork(song, presentation, handle, client)
        scheduleActiveStreamRenewal(authorizationExpiresAt)
        refreshPlaybackState()
    }

    private fun publishStreamArtwork(
        song: RemoteSong,
        presentation: Track,
        handle: AuthenticatedStreamHandle,
        client: ServerClient,
    ) {
        if (song.artworkURL.isNullOrBlank()) return
        streamArtworkJob?.cancel()
        streamArtworkJob = viewModelScope.launch {
            val artwork = client.fetchArtwork(song) ?: return@launch
            val publishable = withContext(Dispatchers.Default) {
                prepareArtworkForSystemPublication(artwork)
            } ?: return@launch
            if (
                activeStreamHandle?.id != handle.id ||
                activeStreamPresentation?.id != presentation.id
            ) return@launch
            val player = controller ?: return@launch
            val currentIndex = player.currentMediaItemIndex
            if (
                currentIndex == C.INDEX_UNSET ||
                player.currentMediaItem?.mediaId != presentation.id
            ) return@launch
            val extras = Bundle().apply {
                song.artworkURL.takeIf(String::isNotBlank)?.let {
                    putString(STREAM_ARTWORK_URL_EXTRA, it)
                }
            }
            val updated = MediaItem.Builder()
                .setMediaId(presentation.id)
                .setUri(handle.playbackURI)
                .setMediaMetadata(
                    publishedMediaMetadata(
                        title = presentation.title,
                        artist = presentation.artist,
                        album = presentation.album,
                        durationMs = presentation.durationMs,
                        extras = extras,
                        artworkData = publishable,
                    ),
                )
                .build()
            // Media3 preserves playback when the URI is unchanged and only metadata is enriched.
            player.replaceMediaItem(currentIndex, updated)
        }
    }

    private fun prepareArtworkForSystemPublication(source: ByteArray): ByteArray? {
        if (source.isEmpty()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sampleSize = 1
        while (
            bounds.outWidth / sampleSize > MAX_PUBLISHED_ARTWORK_EDGE * 2 ||
            bounds.outHeight / sampleSize > MAX_PUBLISHED_ARTWORK_EDGE * 2
        ) {
            sampleSize *= 2
        }
        val decoded = BitmapFactory.decodeByteArray(
            source,
            0,
            source.size,
            BitmapFactory.Options().apply { inSampleSize = sampleSize },
        ) ?: return null
        val largestEdge = maxOf(decoded.width, decoded.height)
        val scaled = if (largestEdge > MAX_PUBLISHED_ARTWORK_EDGE) {
            val ratio = MAX_PUBLISHED_ARTWORK_EDGE.toFloat() / largestEdge.toFloat()
            android.graphics.Bitmap.createScaledBitmap(
                decoded,
                (decoded.width * ratio).toInt().coerceAtLeast(1),
                (decoded.height * ratio).toInt().coerceAtLeast(1),
                true,
            )
        } else {
            decoded
        }
        val output = ByteArrayOutputStream()
        scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 82, output)
        if (output.size() > MAX_PUBLISHED_ARTWORK_BYTES) {
            output.reset()
            scaled.compress(android.graphics.Bitmap.CompressFormat.JPEG, 62, output)
        }
        if (scaled !== decoded) scaled.recycle()
        decoded.recycle()
        return output.toByteArray().takeIf {
            it.isNotEmpty() && it.size <= MAX_PUBLISHED_ARTWORK_BYTES
        }
    }

    private fun clearActiveStreamPresentation() {
        finishListeningSession(flush = true)
        streamConfigRenewalJob?.cancel()
        streamConfigRenewalJob = null
        streamLeaseExpiryJob?.cancel()
        streamLeaseExpiryJob = null
        pendingStreamRenewalMinimumExpiry = null
        streamArtworkJob?.cancel()
        streamArtworkJob = null
        AuthenticatedStreamRegistry.remove(activeStreamHandle?.id)
        activeStreamHandle = null
        activeStreamPresentation = null
        activeStreamPolicyContext = null
        activeStreamSourceURL = null
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
            durationMs = metadata.durationMs
                ?: player.duration.takeIf { it != C.TIME_UNSET && it > 0L }
                ?: 0L,
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

    override fun createListenAlong() {
        val context = currentServerProfileContext() ?: run {
            mutableState.update { it.copy(errorMessage = "Connect to Resonance before starting Listen Along.") }
            return
        }
        if (activeAccessToken().isBlank()) {
            mutableState.update { it.copy(errorMessage = "Sign in before starting Listen Along.") }
            return
        }
        val initial = runCatching { listenAlongSnapshotFromPlayer() }.getOrElse { error ->
            val message = error.message ?: "The current track cannot be shared."
            mutableState.update { state ->
                state.copy(
                    listenAlong = state.listenAlong.copy(errorMessage = message),
                    errorMessage = message,
                )
            }
            return
        }
        if (initial.sourceURL.isNullOrBlank()) {
            val message = "Play a track with a shareable source link before starting Listen Along."
            mutableState.update { state ->
                state.copy(
                    listenAlong = state.listenAlong.copy(errorMessage = message),
                    errorMessage = message,
                )
            }
            return
        }
        clearListenAlongSession(stopPlayback = false)
        val client = serverClient(context)
        mutableState.update { state ->
            state.copy(
                listenAlong = ListenAlongUiState(
                    status = ListenAlongConnectionStatus.Connecting,
                    message = "Starting a Listen Along room…",
                ),
                errorMessage = null,
            )
        }
        viewModelScope.launch {
            runCatching {
                val envelope = client.createListenAlong(initial)
                val code = envelope.inviteCode
                    ?: throw IllegalStateException("The server did not return a Listen Along code.")
                val hostToken = envelope.hostToken
                    ?: throw IllegalStateException("The server did not return a Listen Along host token.")
                require(code.isNotBlank() && hostToken.isNotBlank()) {
                    "The server did not return a Listen Along host token."
                }
                adoptListenAlongEnvelope(
                    envelope = envelope,
                    context = context,
                    role = ListenAlongRole.Host,
                    hostToken = hostToken,
                )
                startListenAlongPolling(context, code)
            }
                .onFailure { error ->
                    if (error !is CancellationException) {
                        mutableState.update { state ->
                            state.copy(
                                listenAlong = ListenAlongUiState(
                                    status = ListenAlongConnectionStatus.Failed,
                                    message = "Listen Along could not start",
                                    errorMessage = error.message ?: "The server rejected the room.",
                                ),
                                errorMessage = error.message ?: "Listen Along could not start.",
                            )
                        }
                    }
                }
        }
    }

    override fun joinListenAlong(code: String) {
        val normalizedCode = code.trim()
        if (normalizedCode.isBlank()) {
            mutableState.update { it.copy(errorMessage = "Enter the Listen Along code.") }
            return
        }
        val context = currentServerProfileContext() ?: run {
            mutableState.update { it.copy(errorMessage = "Connect to Resonance before joining Listen Along.") }
            return
        }
        if (activeAccessToken().isBlank()) {
            mutableState.update { it.copy(errorMessage = "Sign in before joining Listen Along.") }
            return
        }
        clearListenAlongSession(stopPlayback = true)
        mutableState.update { state ->
            state.copy(
                listenAlong = ListenAlongUiState(
                    status = ListenAlongConnectionStatus.Connecting,
                    code = normalizedCode,
                    role = ListenAlongRole.Guest,
                    message = "Joining Listen Along…",
                ),
                errorMessage = null,
            )
        }
        val client = serverClient(context)
        viewModelScope.launch {
            runCatching {
                val envelope = client.fetchListenAlong(normalizedCode)
                require(envelope.inviteCode?.equals(normalizedCode, ignoreCase = true) != false) {
                    "The server returned a different Listen Along room."
                }
                adoptListenAlongEnvelope(
                    envelope = envelope,
                    context = context,
                    role = ListenAlongRole.Guest,
                    hostToken = null,
                )
                startListenAlongPolling(context, normalizedCode)
            }
                .onFailure { error ->
                    if (error !is CancellationException) {
                        mutableState.update { state ->
                            state.copy(
                                listenAlong = state.listenAlong.copy(
                                    status = ListenAlongConnectionStatus.Failed,
                                    message = "Listen Along could not be joined",
                                    errorMessage = error.message ?: "The room is unavailable.",
                                ),
                                errorMessage = error.message ?: "Listen Along could not be joined.",
                            )
                        }
                    }
                }
        }
    }

    override fun leaveListenAlong() {
        val code = listenAlongCode
        val role = listenAlongRole
        val hostToken = listenAlongHostToken
        val context = listenAlongContext
        if (code != null && role == ListenAlongRole.Host && !hostToken.isNullOrBlank() && context != null) {
            viewModelScope.launch {
                runCatching { serverClient(context).endListenAlong(code, hostToken) }
                clearListenAlongSession(stopPlayback = true)
            }
        } else {
            clearListenAlongSession(stopPlayback = true)
        }
    }

    private fun startListenAlongPolling(context: ServerProfileContext, code: String) {
        listenAlongPollJob?.cancel()
        listenAlongPollJob = viewModelScope.launch {
            var delayMillis = LISTEN_ALONG_INITIAL_POLL_MS
            while (isActive && listenAlongContext == context && listenAlongCode == code &&
                listenAlongRole != null
            ) {
                delay(delayMillis)
                try {
                    val envelope = serverClient(context).fetchListenAlong(code)
                    if (listenAlongContext != context || listenAlongCode != code) break
                    if (envelope.revision >= listenAlongRevision) {
                        val currentRole = listenAlongRole ?: break
                        adoptListenAlongEnvelope(
                            envelope = envelope,
                            context = context,
                            role = currentRole,
                            hostToken = listenAlongHostToken,
                        )
                    }
                    delayMillis = LISTEN_ALONG_INITIAL_POLL_MS
                } catch (error: CancellationException) {
                    throw error
                } catch (error: ServerException) {
                    if (error.status == 404 || error.status == 410) {
                        val ended = mutableState.value.listenAlong.copy(
                            status = ListenAlongConnectionStatus.Ended,
                            message = "Listen Along room ended",
                            errorMessage = error.serverMessage ?: "The room has expired.",
                        )
                        clearListenAlongSession(stopPlayback = true)
                        mutableState.update { it.copy(listenAlong = ended) }
                        break
                    }
                    delayMillis = ListenAlongPollPolicy.nextFailureDelay(delayMillis)
                    mutableState.update { state ->
                        state.copy(listenAlong = state.listenAlong.copy(
                            status = ListenAlongConnectionStatus.Reconnecting,
                            message = "Reconnecting to Listen Along…",
                            errorMessage = error.message,
                        ))
                    }
                } catch (error: Throwable) {
                    delayMillis = ListenAlongPollPolicy.nextFailureDelay(delayMillis)
                    mutableState.update { state ->
                        if (state.listenAlong.isActive) {
                            state.copy(
                                listenAlong = state.listenAlong.copy(
                                    status = ListenAlongConnectionStatus.Reconnecting,
                                    message = "Reconnecting to Listen Along…",
                                    errorMessage = error.message,
                                ),
                            )
                        } else state
                    }
                    if (delayMillis >= LISTEN_ALONG_MAX_POLL_MS) delay(LISTEN_ALONG_MAX_POLL_MS)
                }
            }
        }
    }

    private fun adoptListenAlongEnvelope(
        envelope: ListenAlongEnvelope,
        context: ServerProfileContext,
        role: ListenAlongRole,
        hostToken: String?,
    ) {
        val code = envelope.inviteCode ?: listenAlongCode ?: return
        if (envelope.revision < listenAlongRevision && listenAlongCode == code) return
        val snapshot = envelope.normalizedSnapshot
        listenAlongContext = context
        listenAlongCode = code
        listenAlongRole = role
        listenAlongHostToken = hostToken ?: listenAlongHostToken
        listenAlongRevision = envelope.revision.coerceAtLeast(listenAlongRevision)
        listenAlongSnapshot = snapshot
        mutableState.update { state ->
            state.copy(
                listenAlong = ListenAlongUiState(
                    status = ListenAlongConnectionStatus.Active,
                    code = code,
                    role = role,
                    snapshot = snapshot,
                    revision = listenAlongRevision,
                    participantCount = envelope.normalizedParticipantCount,
                    message = if (role == ListenAlongRole.Host) {
                        "Share this code with your listeners"
                    } else {
                        "Following the host"
                    },
                ),
                errorMessage = null,
            )
        }
        if (role == ListenAlongRole.Guest) {
            applyListenAlongSnapshot(
                snapshot = snapshot,
                updatedAt = envelope.updatedAt,
                serverTime = envelope.serverTime,
            )
        }
    }

    private fun applyListenAlongSnapshot(
        snapshot: ListenAlongSnapshot,
        updatedAt: String?,
        serverTime: String?,
    ) {
        if (listenAlongRole != ListenAlongRole.Guest) return
        val normalized = runCatching { ListenAlongSnapshotPolicy.normalized(snapshot) }
            .getOrElse { error ->
                mutableState.update { state ->
                    state.copy(listenAlong = state.listenAlong.copy(
                        message = "The host sent an invalid track link.",
                        errorMessage = error.message,
                    ))
                }
                return
        }
        val desiredPositionMs = (ListenAlongSnapshotPolicy.projectedPositionSeconds(
            snapshot = normalized,
            updatedAtMillis = parseListenAlongTimeMillis(updatedAt),
            serverTimeMillis = parseListenAlongTimeMillis(serverTime),
            nowMillis = System.currentTimeMillis(),
        ) * 1_000.0).toLong().coerceAtLeast(0L)
        val currentSource = listenAlongPlaybackSourceURL
        val mediaKind = normalized.normalizedMediaKind
        val player = controller ?: return
        if (normalized.sourceURL.isNullOrBlank()) {
            listenAlongPlaybackJob?.cancel()
            stopListenAlongProviderPlayback()
            player.stop()
            player.clearMediaItems()
            listenAlongPlaybackSourceURL = null
            mutableState.update { state ->
                state.copy(listenAlong = state.listenAlong.copy(
                    message = "The host is listening to a source that is unavailable on this device.",
                    errorMessage = "This track has no source link to stream.",
                ))
            }
            return
        }
        val reusesCurrentPlayback = ListenAlongPlaybackPolicy.shouldReuse(
            currentSourceURL = currentSource,
            nextSourceURL = normalized.sourceURL,
            currentMediaKind = listenAlongPlaybackMediaKind,
            nextMediaKind = mediaKind,
            mediaItemCount = player.mediaItemCount,
        )
        if (!reusesCurrentPlayback) {
            val expectedCode = listenAlongCode
            val expectedRevision = listenAlongRevision
            listenAlongPlaybackJob?.cancel()
            listenAlongPlaybackJob = viewModelScope.launch {
                val prepared = runCatching {
                    prepareListenAlongPlayback(
                        sourceURL = normalized.sourceURL,
                        mediaKind = mediaKind,
                        code = expectedCode ?: "room",
                        revision = expectedRevision,
                    )
                }.getOrElse { error ->
                    if (error !is CancellationException) {
                        mutableState.update { state ->
                            if (state.listenAlong.isGuest) state.copy(
                                listenAlong = state.listenAlong.copy(
                                    message = "This track could not be resolved on this device.",
                                    errorMessage = error.message ?: "The source link could not be played.",
                                ),
                            ) else state
                        }
                    }
                    return@launch
                }
                if (listenAlongCode != expectedCode || listenAlongRole != ListenAlongRole.Guest ||
                    listenAlongRevision != expectedRevision
                ) return@launch
                installListenAlongPlayback(prepared, desiredPositionMs, normalized.isPlaying)
            }
        } else {
            val delta = abs(player.currentPosition - desiredPositionMs)
            if (delta > LISTEN_ALONG_SEEK_TOLERANCE_MS) player.seekTo(desiredPositionMs)
            if (normalized.isPlaying) {
                if (!player.isPlaying) player.play()
            } else if (player.isPlaying) {
                player.pause()
            }
        }
    }

    private data class PreparedListenAlongPlayback(
        val item: MediaItem,
        val localTrack: Track? = null,
        val presentation: Track? = null,
        val artworkURL: String? = null,
        val providerHandle: ListenAlongProviderStreamHandle? = null,
        val sourceURL: String,
        val mediaKind: String,
    )

    private suspend fun prepareListenAlongPlayback(
        sourceURL: String,
        mediaKind: String,
        code: String,
        revision: Long,
    ): PreparedListenAlongPlayback {
        val local = library.tracks.firstOrNull { track ->
            trackBelongsToActiveContext(track) &&
                sourceMatches(sourceURL, track.sourceURL ?: track.downloadSourceURL) &&
                repository.fileForTrack(track).isFile
        }
        if (local != null) {
            return PreparedListenAlongPlayback(
                item = requireNotNull(mediaItem(local)),
                localTrack = local,
                sourceURL = sourceURL,
                mediaKind = mediaKind,
            )
        }

        // A remote catalog match supplies presentation metadata only. Without
        // a downloaded local file, Listen Along always resolves the host's
        // shared source into a transient provider stream.
        val remote = mutableState.value.remoteSongs.firstOrNull { song ->
            sourceMatches(sourceURL, song.sourceURL)
        }
        val requestedMode = if (mediaKind == "video") LinkImportMediaMode.Video else LinkImportMediaMode.Audio
        val directHandle = runCatching {
            ListenAlongProviderStreamPolicy.register(sourceURL, emptyMap())
        }.getOrNull()
        val candidateAndMetadata = if (directHandle == null) {
            val resolution = linkImportService.resolve(sourceURL, requestedMode) { }
            val candidate = resolution.candidates.firstOrNull()
                ?: throw LinkImportException(
                    LinkImportStage.InspectingSource,
                    "LISTEN_ALONG_NO_STREAM",
                    "No playable rendition was found for this source link.",
                )
            val preview = linkImportService.preview(candidate)
            Triple(preview, resolution.track, candidate)
        } else null
        val providerHandle = directHandle ?: ListenAlongProviderStreamPolicy.register(
            url = requireNotNull(candidateAndMetadata).first.url,
            headers = candidateAndMetadata.first.headers,
        )
        val metadata = candidateAndMetadata?.second ?: LinkImportTrack(
            title = remote?.title ?: "Listen Along",
            artist = remote?.artist ?: "Resonance",
            album = remote?.album,
            durationSeconds = remote?.durationSeconds?.toInt(),
            artworkURL = remote?.artworkURL,
            sourceURL = sourceURL,
        )
        // A resolver may return the thumbnail on the selected candidate even when
        // its normalized track metadata has no artwork field. Keep that fallback
        // on the transient presentation so connected clients get the same cover.
        val artworkURL = ListenAlongArtworkPolicy.preferredURL(
            metadata.artworkURL,
            candidateAndMetadata?.third?.thumbnailURL,
            remote?.artworkURL,
        )
        val presentation = Track(
            id = "listen-along:$code:$revision:${providerHandle.id}",
            title = metadata.title,
            artist = metadata.artist,
            album = metadata.album ?: "Listen Along",
            durationMs = metadata.durationSeconds?.toLong()?.times(1_000L) ?: 0L,
            relativePath = "",
        )
        val extras = Bundle().apply {
            artworkURL?.takeIf(String::isNotBlank)?.let {
                putString(STREAM_ARTWORK_URL_EXTRA, it)
            }
        }
        val item = MediaItem.Builder()
            .setMediaId(presentation.id)
            .setUri(providerHandle.playbackURI)
            .setMediaMetadata(
                publishedMediaMetadata(
                    title = presentation.title,
                    artist = presentation.artist,
                    album = presentation.album,
                    durationMs = presentation.durationMs,
                    extras = extras,
                ),
            )
            .build()
        return PreparedListenAlongPlayback(
            item = item,
            presentation = presentation,
            artworkURL = artworkURL,
            providerHandle = providerHandle,
            sourceURL = sourceURL,
            mediaKind = mediaKind,
        )
    }

    private fun installListenAlongPlayback(
        prepared: PreparedListenAlongPlayback,
        positionMs: Long,
        isPlaying: Boolean,
    ) {
        val player = controller ?: return
        stopListenAlongProviderPlayback()
        clearActiveStreamPresentation()
        listenAlongProviderHandle = prepared.providerHandle
        listenAlongPlaybackSourceURL = prepared.sourceURL
        listenAlongPlaybackMediaKind = prepared.mediaKind
        activeQueue = listOf(prepared.item.mediaId)
        activePlaylistId = null
        val localTrack = prepared.localTrack
        mutableState.update { state ->
            state.copy(
                tracks = library.tracks.filter(::trackBelongsToActiveContext),
                currentTrackId = prepared.item.mediaId,
                transientCurrentTrack = prepared.presentation,
                transientArtworkURL = prepared.artworkURL,
                activePlaylistId = null,
                errorMessage = null,
                listenAlong = state.listenAlong.copy(
                    message = if (localTrack != null) "Playing the local copy with the host" else "Resolving the host's source",
                    errorMessage = null,
                ),
            )
        }
        player.setMediaItem(prepared.item)
        player.shuffleModeEnabled = false
        player.repeatMode = Player.REPEAT_MODE_OFF
        player.prepare()
        player.seekTo(positionMs.coerceAtLeast(0L))
        if (isPlaying) player.play() else player.pause()
        scheduleListenAlongArtwork(prepared)
        scheduleListenAlongProviderRefresh(prepared.providerHandle)
        refreshPlaybackState()
    }

    /**
     * Compose can load the transient artwork URL directly, but Media3's session and
     * Android's notification surfaces need bounded artwork bytes on the MediaItem.
     * Fetch it after playback is installed so artwork latency never delays audio.
     */
    private fun scheduleListenAlongArtwork(prepared: PreparedListenAlongPlayback) {
        listenAlongArtworkJob?.cancel()
        listenAlongArtworkJob = null
        val artworkURL = prepared.artworkURL?.trim()?.takeIf(String::isNotEmpty) ?: return
        val presentation = prepared.presentation ?: return
        val context = listenAlongContext ?: return
        val expectedCode = listenAlongCode ?: return
        val expectedMediaID = prepared.item.mediaId
        listenAlongArtworkJob = viewModelScope.launch {
            val artwork = serverClient(context).fetchArtworkURL(artworkURL) ?: return@launch
            val publishable = withContext(Dispatchers.Default) {
                prepareArtworkForSystemPublication(artwork)
            } ?: return@launch
            if (
                listenAlongCode != expectedCode ||
                listenAlongRole != ListenAlongRole.Guest ||
                listenAlongPlaybackSourceURL != prepared.sourceURL
            ) return@launch
            val player = controller ?: return@launch
            val currentIndex = player.currentMediaItemIndex
            if (
                currentIndex == C.INDEX_UNSET ||
                player.currentMediaItem?.mediaId != expectedMediaID
            ) return@launch
            val metadata = publishedMediaMetadata(
                title = presentation.title,
                artist = presentation.artist,
                album = presentation.album,
                durationMs = presentation.durationMs,
                extras = player.currentMediaItem?.mediaMetadata?.extras ?: Bundle(),
                artworkData = publishable,
            )
            player.replaceMediaItem(
                currentIndex,
                player.currentMediaItem!!.buildUpon()
                    .setMediaMetadata(metadata)
                    .build(),
            )
        }
    }

    private fun stopListenAlongProviderPlayback() {
        listenAlongArtworkJob?.cancel()
        listenAlongArtworkJob = null
        listenAlongProviderRefreshJob?.cancel()
        listenAlongProviderRefreshJob = null
        ListenAlongProviderStreamPolicy.remove(listenAlongProviderHandle?.id)
        listenAlongProviderHandle = null
        listenAlongPlaybackSourceURL = null
    }

    private fun scheduleListenAlongProviderRefresh(handle: ListenAlongProviderStreamHandle?) {
        listenAlongProviderRefreshJob?.cancel()
        if (handle == null) return
        val sourceURL = listenAlongPlaybackSourceURL ?: return
        val mediaKind = listenAlongPlaybackMediaKind
        val expectedCode = listenAlongCode ?: return
        val expectedRevision = listenAlongRevision
        listenAlongProviderRefreshJob = viewModelScope.launch {
            delay(LISTEN_ALONG_PROVIDER_REFRESH_MS)
            if (listenAlongProviderHandle?.id != handle.id || listenAlongRole != ListenAlongRole.Guest ||
                listenAlongCode != expectedCode || listenAlongRevision != expectedRevision ||
                listenAlongPlaybackSourceURL != sourceURL
            ) return@launch
            val player = controller ?: return@launch
            val positionMs = player.currentPosition.coerceAtLeast(0L)
            val isPlaying = player.isPlaying
            val replacement = runCatching {
                prepareListenAlongPlayback(sourceURL, mediaKind, expectedCode, expectedRevision)
            }.getOrNull() ?: return@launch
            if (listenAlongProviderHandle?.id != handle.id || listenAlongRole != ListenAlongRole.Guest ||
                listenAlongCode != expectedCode || listenAlongRevision != expectedRevision
            ) return@launch
            installListenAlongPlayback(replacement, positionMs, isPlaying)
        }
    }

    private fun clearListenAlongSession(stopPlayback: Boolean) {
        listenAlongPollJob?.cancel()
        listenAlongPollJob = null
        listenAlongPendingSnapshot = null
        listenAlongPublishJob?.cancel()
        listenAlongPublishJob = null
        listenAlongPlaybackJob?.cancel()
        listenAlongPlaybackJob = null
        val currentID = controller?.currentMediaItem?.mediaId.orEmpty()
        val wasListenPlayback = currentID.startsWith("listen-along:") ||
            listenAlongPlaybackSourceURL != null
        stopListenAlongProviderPlayback()
        if (stopPlayback && wasListenPlayback) {
            controller?.stop()
            controller?.clearMediaItems()
            activeQueue = emptyList()
            activePlaylistId = null
            rebuildPlaybackQueueForActiveContext()
        }
        listenAlongContext = null
        listenAlongCode = null
        listenAlongRole = null
        listenAlongHostToken = null
        listenAlongRevision = 0L
        listenAlongSnapshot = ListenAlongSnapshot()
        mutableState.update { state ->
            state.copy(
                transientCurrentTrack = if (wasListenPlayback) null else state.transientCurrentTrack,
                transientArtworkURL = if (wasListenPlayback) null else state.transientArtworkURL,
                listenAlong = ListenAlongUiState(),
            )
        }
    }

    private fun listenAlongSnapshotFromPlayer(): ListenAlongSnapshot {
        val player = controller
        val currentID = player?.currentMediaItem?.mediaId
        val track = currentID?.let { id -> library.tracks.firstOrNull { it.id == id } }
        val remote = track?.remoteID?.let { id -> mutableState.value.remoteSongs.firstOrNull { it.id == id } }
        val source = activeStreamSourceURL ?: track?.sourceURL ?: track?.downloadSourceURL ?: remote?.sourceURL
        val mediaKind = when {
            remote?.isVideoMedia == true -> "video"
            track?.relativePath?.substringAfterLast('.', "")?.lowercase() in
                setOf("mp4", "mov", "m4v", "webm") -> "video"
            else -> "audio"
        }
        return ListenAlongSnapshot(
            sourceURL = source,
            mediaKind = mediaKind,
            positionSeconds = (player?.currentPosition ?: 0L).coerceAtLeast(0L) / 1_000.0,
            isPlaying = player?.isPlaying == true,
        ).let(ListenAlongSnapshotPolicy::normalized)
    }

    private fun endListenAlongForMissingSource(
        context: ServerProfileContext,
        code: String,
        hostToken: String,
    ) {
        val state = mutableState.value.listenAlong
        if (state.message.startsWith("Ending Listen Along")) return
        mutableState.update {
            it.copy(listenAlong = state.copy(
                message = "Ending Listen Along…",
                errorMessage = "This track has no shareable source link; the room will be ended.",
            ))
        }
        listenAlongPublishJob?.cancel()
        listenAlongPublishJob = viewModelScope.launch {
            runCatching { serverClient(context).endListenAlong(code, hostToken) }
            clearListenAlongSession(stopPlayback = false)
            mutableState.update {
                it.copy(errorMessage = "Listen Along ended because the current track has no shareable source link.")
            }
        }
    }

    private fun publishListenAlongSnapshot() {
        if (listenAlongRole != ListenAlongRole.Host) return
        val code = listenAlongCode ?: return
        val hostToken = listenAlongHostToken ?: return
        val context = listenAlongContext ?: return
        val snapshot = runCatching { listenAlongSnapshotFromPlayer() }.getOrNull() ?: return
        if (snapshot.sourceURL.isNullOrBlank()) {
            endListenAlongForMissingSource(context, code, hostToken)
            return
        }
        listenAlongSnapshot = snapshot
        mutableState.update { state ->
            state.copy(listenAlong = state.listenAlong.copy(snapshot = snapshot))
        }
        // Keep one request in flight at a time. Cancelling every previous coroutine
        // can cancel its HTTP request after the server has accepted it, leaving the
        // next action with a stale revision and forcing a slow conflict recovery.
        // A conflated pending value preserves ordering while always sending the
        // newest host action as soon as the current request completes.
        listenAlongPendingSnapshot = snapshot
        if (listenAlongPublishJob?.isActive == true) return
        listenAlongPublishJob = viewModelScope.launch {
            delay(LISTEN_ALONG_PUBLISH_DEBOUNCE_MS)
            while (isActive && listenAlongCode == code && listenAlongRole == ListenAlongRole.Host) {
                val pending = listenAlongPendingSnapshot ?: break
                listenAlongPendingSnapshot = null
                runCatching {
                    sendListenAlongHostUpdate(
                        context = context,
                        code = code,
                        hostToken = hostToken,
                        snapshot = pending,
                    )
                }.onSuccess { envelope ->
                    if (listenAlongCode != code || listenAlongRole != ListenAlongRole.Host) return@onSuccess
                    listenAlongRevision = maxOf(listenAlongRevision, envelope.revision)
                    listenAlongSnapshot = envelope.normalizedSnapshot
                    mutableState.update { state ->
                        state.copy(listenAlong = state.listenAlong.copy(
                            status = ListenAlongConnectionStatus.Active,
                            snapshot = listenAlongPendingSnapshot ?: listenAlongSnapshot,
                            revision = listenAlongRevision,
                            errorMessage = null,
                        ))
                    }
                }.onFailure { error ->
                    if (error !is CancellationException && listenAlongCode == code) {
                        if (error.message?.contains("no shareable source", ignoreCase = true) == true) {
                            endListenAlongForMissingSource(context, code, hostToken)
                        } else {
                            mutableState.update { state ->
                                state.copy(listenAlong = state.listenAlong.copy(
                                    message = "Listen Along update failed",
                                    errorMessage = error.message,
                                ))
                            }
                        }
                    }
                }
                // If another action arrived while the request was in flight, send
                // that latest snapshot immediately using the newly advanced revision.
                if (listenAlongPendingSnapshot == null) break
            }
        }
    }

    private suspend fun sendListenAlongHostUpdate(
        context: ServerProfileContext,
        code: String,
        hostToken: String,
        snapshot: ListenAlongSnapshot,
    ): ListenAlongEnvelope {
        var revision = listenAlongRevision
        var pending = snapshot
        var recovered = false
        while (true) {
            try {
                return serverClient(context).updateListenAlong(
                    code = code,
                    revision = revision,
                    snapshot = pending,
                    hostToken = hostToken,
                )
            } catch (conflict: ListenAlongRevisionConflictException) {
                val current = conflict.current
                if (recovered || current == null) throw conflict
                val currentCode = current.inviteCode
                if (currentCode != null && !currentCode.equals(code, ignoreCase = true)) throw conflict
                adoptListenAlongEnvelope(
                    envelope = current,
                    context = context,
                    role = ListenAlongRole.Host,
                    hostToken = hostToken,
                )
                revision = maxOf(revision, current.revision, listenAlongRevision)
                pending = runCatching { listenAlongSnapshotFromPlayer() }.getOrElse { current.normalizedSnapshot }
                if (pending.sourceURL.isNullOrBlank()) throw IllegalStateException(
                    "This track has no shareable source link; the Listen Along room must end.",
                )
                recovered = true
            }
        }
    }

    private fun parseListenAlongTimeMillis(value: String?): Long? = value?.let {
        it.toLongOrNull() ?: runCatching { Instant.parse(it).toEpochMilli() }.getOrNull()
    }

    private fun sourceMatches(first: String?, second: String?): Boolean {
        val left = first?.trim()?.takeIf(String::isNotEmpty) ?: return false
        val right = second?.trim()?.takeIf(String::isNotEmpty) ?: return false
        val normalizedLeft = runCatching {
            URI(left).let { uri ->
                "${uri.scheme?.lowercase()}://${uri.host?.lowercase()}${uri.rawPath.orEmpty()}?${uri.rawQuery.orEmpty()}"
            }
        }.getOrElse { left.trimEnd('/') }
        val normalizedRight = runCatching {
            URI(right).let { uri ->
                "${uri.scheme?.lowercase()}://${uri.host?.lowercase()}${uri.rawPath.orEmpty()}?${uri.rawQuery.orEmpty()}"
            }
        }.getOrElse { right.trimEnd('/') }
        return normalizedLeft.trimEnd('?').trimEnd('/') == normalizedRight.trimEnd('?').trimEnd('/')
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

    fun syncListeningHistoryAutomatically() {
        if (activeAccessToken().isBlank()) return
        scheduleListeningHistorySync(delayMillis = 0L)
    }

    private fun scheduleListeningHistorySync(delayMillis: Long = 1_500L) {
        if (activeAccessToken().isBlank()) return
        listeningHistorySyncJob?.cancel()
        val retryDelay = (listeningHistoryRetryAt - System.currentTimeMillis()).coerceAtLeast(0L)
        listeningHistorySyncJob = viewModelScope.launch {
            delay(maxOf(delayMillis, retryDelay))
            listeningHistorySyncJob = null
            syncListeningHistoryNow()
        }
    }

    private suspend fun syncListeningHistoryNow(force: Boolean = false): Boolean {
        val token = activeAccessToken().trim()
        if (token.isEmpty() || (!force && System.currentTimeMillis() < listeningHistoryRetryAt)) return false
        if (listeningHistorySyncInFlight) {
            listeningHistorySyncPending = true
            return false
        }
        val expected = currentServerProfileContext() ?: return false
        listeningHistorySyncInFlight = true
        var shouldRetry = false
        try {
            val origin = RemoteTrackIdentityPolicy.normalizedOrigin(expected.serverURL) ?: return false
            val tracksByID = library.tracks.associateBy(Track::id)
            val pending = library.listeningHistory.filter { entry ->
                entry.originatedOnThisDevice &&
                    ListeningHistoryRetentionPolicy.matchesContext(entry, expected.serverURL, expected.profileID) &&
                    ListeningHistoryRetentionPolicy.qualifies(entry, tracksByID[entry.trackID]) &&
                    (listeningHistorySyncedSeconds[listeningHistorySyncKey(origin, expected.profileID, entry.id)] ?: -1.0) < entry.listenedSeconds
            }
            val client = ServerClient(
                expected.serverURL,
                token,
                token,
                expected.profileID,
                clientConfigStore.cohortKey,
            )
            for (batch in pending.sortedBy { it.startedAt }.chunked(ListeningHistoryRetentionPolicy.MAX_UPLOAD_BATCH)) {
                ensureListeningHistoryContext(expected, token)
                if (!client.postListeningHistory(batch)) {
                    shouldRetry = true
                    return false
                }
                batch.forEach { entry ->
                    listeningHistorySyncedSeconds[listeningHistorySyncKey(origin, expected.profileID, entry.id)] = entry.listenedSeconds
                }
            }
            ensureListeningHistoryContext(expected, token)
            val remote = client.fetchListeningHistory(ListeningHistoryRetentionPolicy.MAXIMUM_ENTRIES)
                ?: run { shouldRetry = true; return false }
            ensureListeningHistoryContext(expected, token)
            val merged = ListeningHistoryRetentionPolicy.mergeRemote(
                library.listeningHistory,
                remote,
                expected.serverURL,
                expected.profileID,
                library.tracks,
                mutableState.value.remoteSongs,
            )
            if (merged != library.listeningHistory) {
                library = library.copy(listeningHistory = merged)
                persistLibrary()
            }
            remote.entries.forEach { entry ->
                listeningHistorySyncedSeconds[listeningHistorySyncKey(origin, expected.profileID, entry.id)] = entry.listenedSeconds
            }
            return true
        } catch (_: CancellationException) {
            throw CancellationException()
        } catch (_: Throwable) {
            if (isListeningHistoryContextCurrent(expected, token)) shouldRetry = true
            return false
        } finally {
            listeningHistorySyncInFlight = false
            listeningHistoryRetryAt = if (shouldRetry) System.currentTimeMillis() + 60_000L else 0L
            if (listeningHistorySyncPending) {
                listeningHistorySyncPending = false
                scheduleListeningHistorySync(delayMillis = 0L)
            } else if (shouldRetry && isListeningHistoryContextCurrent(expected, token)) {
                scheduleListeningHistorySync(delayMillis = 60_000L)
            }
        }
    }

    private fun listeningHistorySyncKey(origin: String, profileID: String, eventID: String): String =
        "$origin#profile=${profileID.ifBlank { "default" }}#event=$eventID"

    private fun isListeningHistoryContextCurrent(expected: ServerProfileContext, token: String): Boolean =
        currentServerProfileContext() == expected && activeAccessToken().trim() == token

    private fun ensureListeningHistoryContext(expected: ServerProfileContext, token: String) {
        if (!isListeningHistoryContextCurrent(expected, token)) throw StaleServerProfileException()
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
                id = remote.id,
                name = remote.name,
                trackIDs = PlaylistOrderPolicy.merge(
                    existing[remote.id]?.trackIDs.orEmpty(),
                    downloaded,
                    localOnly,
                ),
                isSystem = false,
                remoteSongIDs = remote.songIDs,
                entryOrder = PlaylistEntryOrderPolicy.mergingRemoteOrder(
                    previous = existing[remote.id],
                    remoteSongIDs = remote.songIDs,
                    tracks = library.tracks,
                ),
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
        val updated = playlist.copy(remoteSongIDs = PlaylistOrderPolicy.merge(
            playlist.remoteSongIDs.orEmpty(),
            ordered,
            unresolved,
        ))
        return updated.copy(
            entryOrder = PlaylistEntryOrderPolicy.normalizedOrder(updated, library.tracks),
        )
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

    private suspend fun persistLibrary() = withContext(Dispatchers.Main.immediate) {
        libraryPersistenceGate.persist(
            latestValue = {
                RemoteTrackIdentityPolicy.reconcileLibraryTracks(
                    ProfileLibraryStatePolicy.captureActive(library),
                ).also { latest -> library = latest }
            },
            write = repository::save,
        )
        // Never assign the returned persisted snapshot here: library may have been enriched
        // while the IO write was in flight. A queued caller will capture that latest value.
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
        updateListeningSession()
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
        val metadata = publishedMediaMetadata(
            title = track.title,
            artist = track.artist,
            album = track.album,
            durationMs = track.durationMs,
            extras = extras,
            artworkUri = artworkUri,
        )
        return MediaItem.Builder()
            .setMediaId(track.id)
            .setUri(Uri.fromFile(audioFile))
            .setMediaMetadata(metadata)
            .build()
    }

    private fun publishedMediaMetadata(
        title: String,
        artist: String,
        album: String,
        durationMs: Long,
        extras: Bundle,
        artworkUri: Uri? = null,
        artworkData: ByteArray? = null,
    ): MediaMetadata {
        val published = PlaybackMetadataPolicy.published(title, artist, album, durationMs)
        return MediaMetadata.Builder()
            .setTitle(published.title)
            .setArtist(published.artist)
            .setAlbumTitle(published.album)
            .setDurationMs(published.durationMs)
            .setIsPlayable(true)
            .setMediaType(MediaMetadata.MEDIA_TYPE_MUSIC)
            .setArtworkUri(artworkUri)
            .apply {
                artworkData?.let {
                    setArtworkData(it, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
                }
            }
            .setExtras(extras)
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
