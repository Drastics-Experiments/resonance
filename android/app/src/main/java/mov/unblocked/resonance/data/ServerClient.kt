package mov.unblocked.resonance.data

import mov.unblocked.resonance.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.Instant
import kotlin.coroutines.coroutineContext

internal object ServerUploadNaming {
    fun filename(sourceFilename: String, title: String? = null): String {
        val sourceName = File(sourceFilename).name
        val rawExtension = sourceName.substringAfterLast('.', "")
        val extension = rawExtension.filter(Char::isLetterOrDigit).take(16)
        val sourceStem = if (rawExtension.isEmpty()) sourceName else sourceName.dropLast(rawExtension.length + 1)
        var preferredStem = title.orEmpty().trim()
        if (extension.isNotEmpty() && preferredStem.endsWith(".$extension", ignoreCase = true)) {
            preferredStem = preferredStem.dropLast(extension.length + 1)
        }
        val stem = cleanStem(preferredStem).ifEmpty { cleanStem(sourceStem) }.ifEmpty { "Untitled song" }
        return if (extension.isEmpty()) stem else "$stem.$extension"
    }

    private fun cleanStem(value: String): String = value
        .replace(Regex("""[<>:"/\\|?*\p{Cntrl}]"""), "-")
        .replace(Regex("""\s+"""), " ")
        .trim()
        .trimEnd('.', ' ')
        .take(180)
}

internal object SourceLinkSchemaCompatibility {
    private const val UnsupportedSchema = "Unsupported source-link schema_version"

    fun shouldRetryLegacy(status: Int, error: String?, mediaKind: String): Boolean =
        status == HttpURLConnection.HTTP_BAD_REQUEST &&
            error == UnsupportedSchema &&
            mediaKind == "audio"
}

data class ServerDownloadFailure(
    val songID: String,
    val filename: String,
    val message: String,
)

data class ServerDownloadBatchResult(
    val tracks: List<Track>,
    val failures: List<ServerDownloadFailure>,
)

private data class ServerDownloadItemResult(
    val index: Int,
    val track: Track? = null,
    val failure: ServerDownloadFailure? = null,
)

internal class TransferProgressThrottle(
    private val minimumByteDelta: Long = 512L * 1_024,
    private val minimumIntervalNanos: Long = 100L * 1_000_000,
) {
    private var lastBytes = 0L
    private var lastEmissionNanos = 0L

    fun shouldEmit(transferred: Long, totalBytes: Long?, nowNanos: Long): Boolean {
        val isComplete = totalBytes != null && transferred >= totalBytes
        val byteDeltaReached = transferred - lastBytes >= minimumByteDelta
        val intervalReached = lastEmissionNanos == 0L || nowNanos - lastEmissionNanos >= minimumIntervalNanos
        if (!isComplete && !byteDeltaReached && !intervalReached) return false
        lastBytes = transferred
        lastEmissionNanos = nowNanos
        return true
    }
}

class ServerClient(
    serverURL: String,
    private val accessToken: String,
    private val adminToken: String = "",
    private val profileID: String = "default",
    private val installationCohortKey: String = "",
    private val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    },
    private val allowCleartextDevelopment: Boolean = BuildConfig.DEBUG,
) {
    private val cleartextDevelopmentEnabled = BuildConfig.DEBUG && allowCleartextDevelopment
    val baseURL: String = normalizeServerURL(serverURL, cleartextDevelopmentEnabled)
    val configOrigin: String = canonicalServerOrigin(baseURL, cleartextDevelopmentEnabled)

    suspend fun fetchCatalog(): RemoteCatalog = withContext(Dispatchers.IO) {
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/songs"),
            token = requireAccessToken(),
            accept = "application/json",
            maxResponseBytes = MAX_CATALOG_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        json.decodeFromString<RemoteCatalog>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun createListenAlong(snapshot: ListenAlongSnapshot): ListenAlongEnvelope =
        withContext(Dispatchers.IO) {
            val response = request(
                method = "POST",
                url = endpoint("/api/v1/listen-along"),
                token = requireAccessToken(),
                body = json.encodeToString(ListenAlongSnapshotPolicy.normalized(snapshot))
                    .toByteArray(Charsets.UTF_8),
                contentType = "application/json",
                accept = "application/json",
                requestHeaders = clientContextHeaders(requireInstallationCohortKey()),
                maxResponseBytes = MAX_LISTEN_ALONG_RESPONSE_BYTES,
            )
            decodeListenAlongResponse(response)
        }

    suspend fun fetchListenAlong(code: String): ListenAlongEnvelope = withContext(Dispatchers.IO) {
        val normalizedCode = code.trim()
        require(normalizedCode.length in 4..64) { "Enter a valid listen-along code" }
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/listen-along/${encodePathSegment(normalizedCode)}"),
            token = requireAccessToken(),
            accept = "application/json",
            requestHeaders = clientContextHeaders(requireInstallationCohortKey()),
            maxResponseBytes = MAX_LISTEN_ALONG_RESPONSE_BYTES,
        )
        decodeListenAlongResponse(response)
    }

    suspend fun updateListenAlong(
        code: String,
        revision: Long,
        snapshot: ListenAlongSnapshot,
        hostToken: String,
    ): ListenAlongEnvelope = withContext(Dispatchers.IO) {
        require(hostToken.isNotBlank()) { "The listen-along host token is missing" }
        val normalizedCode = code.trim()
        require(normalizedCode.length in 4..64) { "The listen-along code is invalid" }
        val normalizedSnapshot = ListenAlongSnapshotPolicy.normalized(snapshot)
        val body = ListenAlongUpdatePayload(
            revision = revision,
            sourceURL = normalizedSnapshot.sourceURL,
            mediaKind = normalizedSnapshot.mediaKind,
            positionSeconds = normalizedSnapshot.positionSeconds,
            isPlaying = normalizedSnapshot.isPlaying,
        )
        val response = request(
            method = "PUT",
            url = endpoint("/api/v1/listen-along/${encodePathSegment(normalizedCode)}"),
            token = requireAccessToken(),
            body = json.encodeToString(body).toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            accept = "application/json",
            requestHeaders = clientContextHeaders(requireInstallationCohortKey()) +
                ("X-Resonance-Listen-Host" to hostToken),
            maxResponseBytes = MAX_LISTEN_ALONG_RESPONSE_BYTES,
        )
        if (response.status == HttpURLConnection.HTTP_CONFLICT) {
            val current = runCatching {
                json.decodeFromString<ListenAlongEnvelope>(response.body.toString(Charsets.UTF_8))
            }.getOrNull()
            throw ListenAlongRevisionConflictException(current)
        }
        decodeListenAlongResponse(response)
    }

    suspend fun endListenAlong(code: String, hostToken: String) = withContext(Dispatchers.IO) {
        require(hostToken.isNotBlank()) { "The listen-along host token is missing" }
        val normalizedCode = code.trim()
        require(normalizedCode.length in 4..64) { "The listen-along code is invalid" }
        val response = request(
            method = "DELETE",
            url = endpoint("/api/v1/listen-along/${encodePathSegment(normalizedCode)}"),
            token = requireAccessToken(),
            requestHeaders = clientContextHeaders(requireInstallationCohortKey()) +
                ("X-Resonance-Listen-Host" to hostToken),
            maxResponseBytes = MAX_LISTEN_ALONG_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_NO_CONTENT))
    }

    private fun decodeListenAlongResponse(response: Response): ListenAlongEnvelope {
        if (response.status !in 200..299) throw serverException(response)
        return json.decodeFromString(response.body.toString(Charsets.UTF_8))
    }

    suspend fun fetchClientConfig(cohortKey: String): ClientConfigFetchResult = withContext(Dispatchers.IO) {
        val bearer = requireClientConfigToken()
        val context = clientConfigRequestContext(cohortKey)
        val connection = open(
            url = endpoint("/api/v1/client-config"),
            method = "GET",
            token = bearer,
        ).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = CLIENT_CONFIG_TIMEOUT_MS
            setRequestProperty("Accept", "application/json")
            applyClientContextHeaders(cohortKey)
        }
        try {
            when (val status = connection.responseCode) {
                HttpURLConnection.HTTP_NOT_FOUND, HttpURLConnection.HTTP_BAD_METHOD -> {
                    runCatching {
                        connection.errorStream?.use { readBoundedBytes(it, MAX_ERROR_BYTES) }
                    }
                    ClientConfigFetchResult.Unsupported
                }
                HttpURLConnection.HTTP_OK -> {
                    val body = try {
                        connection.inputStream.use {
                            readBoundedBytes(it, ClientConfigVerifier.MAX_BODY_BYTES)
                        }
                    } catch (error: ResponseTooLargeException) {
                        throw ClientConfigResponsePolicy.oversizedBody(error)
                    }
                    val envelope = SignedClientConfigEnvelope(
                        body = body,
                        contentDigest = connection.getHeaderField("Content-Digest").orEmpty(),
                        signature = connection.getHeaderField("X-Resonance-Config-Signature").orEmpty(),
                    )
                    val config = ClientConfigVerifier.verify(
                        envelope = envelope,
                        bearer = bearer,
                        expected = context,
                        // Validate at response completion, not request start, so a lease
                        // that expires while the network is in flight cannot be applied.
                        now = Instant.now(),
                    )
                    ClientConfigFetchResult.Verified(config, envelope, clientConfigCacheScope())
                }
                else -> {
                    val errorBody = runCatching {
                        connection.errorStream?.use { readBoundedBytes(it, MAX_ERROR_BYTES) }
                    }.getOrNull() ?: ByteArray(0)
                    throw serverException(Response(status, errorBody))
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    fun verifyCachedClientConfig(
        envelope: SignedClientConfigEnvelope,
        cohortKey: String,
        now: Instant = Instant.now(),
    ): EffectiveClientConfig = ClientConfigVerifier.verify(
        envelope = envelope,
        bearer = requireClientConfigToken(),
        expected = clientConfigRequestContext(cohortKey),
        now = now,
        source = ClientConfigSource.VerifiedCache,
    )

    fun clientConfigCacheScope(): ClientConfigCacheScope {
        val bearer = requireClientConfigToken()
        return ClientConfigCacheScope(
            origin = configOrigin,
            profileID = profileID,
            platform = CLIENT_CONFIG_PLATFORM,
            appVersion = BuildConfig.VERSION_NAME,
            appBuild = BuildConfig.VERSION_CODE.toLong(),
            tokenFingerprint = ClientConfigVerifier.tokenFingerprint(bearer),
        )
    }

    suspend fun fetchArtwork(song: RemoteSong): ByteArray? = fetchArtworkURL(song.artworkURL)

    /**
     * Fetches a public artwork URL for transient playback metadata.
     *
     * Listen Along guests resolve the host's source locally, so the artwork does not
     * necessarily belong to a catalog [RemoteSong]. Keep the same origin/HTTPS,
     * redirect, size, and credential rules as catalog artwork while allowing that
     * transient URL to be fetched for Media3 system metadata.
     */
    suspend fun fetchArtworkURL(rawArtworkURL: String?): ByteArray? = withContext(Dispatchers.IO) {
        val rawURL = rawArtworkURL?.trim()?.takeIf(String::isNotEmpty) ?: return@withContext null
        runCatching {
            val url = ServerNetworkPolicy.resolveArtworkURL(
                baseURL,
                rawURL,
                cleartextDevelopmentEnabled,
            )
            val connection = openArtworkConnection(url)
            try {
                if (connection.responseCode !in 200..299) return@runCatching null
                val contentLength = connection.contentLengthLong
                if (contentLength > MAX_ARTWORK_BYTES) return@runCatching null
                val contentType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
                if (contentType != null && !contentType.startsWith("image/")) return@runCatching null
                connection.inputStream.use(::readArtworkBytes)?.takeIf(ArtworkPayloadPolicy::hasSafeDecodedBounds)
            } finally {
                connection.disconnect()
            }
        }.getOrElse { error ->
            if (error is CancellationException) throw error
            null
        }
    }

    suspend fun downloadSelected(
        catalog: RemoteCatalog,
        selectedIDs: Set<String>,
        repository: LibraryRepository,
        existingRemoteIDs: Set<String> = emptySet(),
        onProgress: (TransferProgress) -> Unit = {},
        beforeEach: () -> Unit,
    ): ServerDownloadBatchResult = downloadSongs(
        songs = catalog.songs.filter { it.id in selectedIDs },
        repository = repository,
        existingRemoteIDs = existingRemoteIDs,
        onProgress = onProgress,
        beforeEach = beforeEach,
    )

    suspend fun downloadAll(
        catalog: RemoteCatalog,
        repository: LibraryRepository,
        existingRemoteIDs: Set<String> = emptySet(),
        onProgress: (TransferProgress) -> Unit = {},
        beforeEach: () -> Unit,
    ): ServerDownloadBatchResult = downloadSongs(
        songs = catalog.songs,
        repository = repository,
        existingRemoteIDs = existingRemoteIDs,
        onProgress = onProgress,
        beforeEach = beforeEach,
    )

    suspend fun upload(
        track: Track,
        authorize: () -> Unit,
    ): RemoteUpload = withContext(Dispatchers.IO) {
        val sourceURL = (track.sourceURL ?: track.downloadSourceURL)?.trim()?.takeIf(String::isNotEmpty)
            ?: throw IllegalStateException(
                "Only songs downloaded from a preserved source link can be uploaded. Download this song from its link again first.",
            )
        val sourceURI = runCatching { URI(sourceURL) }.getOrNull()
        require(sourceURI?.scheme.equals("https", ignoreCase = true) && sourceURI?.rawUserInfo == null) {
            "The preserved source link must be a public HTTPS URL without credentials"
        }
        val mediaKind = if (track.relativePath.substringAfterLast('.', "").lowercase() in
            setOf("mp4", "mov", "m4v", "webm")) "video" else "audio"
        val payload = SourceLinkUploadRequest(
            sourceURL = sourceURL,
            mediaKind = mediaKind,
        )
        authorize()
        var response = request(
            method = "PUT",
            url = endpoint("/api/v1/admin/songs"),
            token = requireAdminToken(),
            body = json.encodeToString(payload).toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            accept = "application/json",
            requestHeaders = clientContextHeaders(requireInstallationCohortKey()),
            maxResponseBytes = MAX_SOURCE_IMPORT_RESPONSE_BYTES,
        )
        val error = runCatching {
            json.decodeFromString<ServerErrorPayload>(response.body.toString(Charsets.UTF_8)).error
        }.getOrNull()
        if (SourceLinkSchemaCompatibility.shouldRetryLegacy(response.status, error, mediaKind)) {
            authorize()
            response = request(
                method = "PUT",
                url = endpoint("/api/v1/admin/songs"),
                token = requireAdminToken(),
                body = json.encodeToString(LegacySourceLinkUploadRequest(sourceURL))
                    .toByteArray(Charsets.UTF_8),
                contentType = "application/json",
                accept = "application/json",
                requestHeaders = clientContextHeaders(requireInstallationCohortKey()),
                maxResponseBytes = MAX_SOURCE_IMPORT_RESPONSE_BYTES,
            )
        }
        requireStatus(response, setOf(HttpURLConnection.HTTP_CREATED, HttpURLConnection.HTTP_CONFLICT))
        if (response.status == HttpURLConnection.HTTP_CONFLICT) {
            json.decodeFromString<DuplicateRemoteUpload>(response.body.toString(Charsets.UTF_8)).duplicateOf
        } else {
            json.decodeFromString<RemoteUpload>(response.body.toString(Charsets.UTF_8))
        }
    }

    suspend fun importSource(
        sourcePageURL: String,
        cohortKey: String,
        authorize: () -> Unit,
    ): RemoteUpload = withContext(Dispatchers.IO) {
        val canonicalSource = SourceImportPolicy.canonicalYouTubePageURL(sourcePageURL)
        val payload = SourceImportRequest(
            sourcePageURL = canonicalSource,
        )
        authorize()
        val response = request(
            method = "POST",
            url = endpoint("/api/v1/admin/source-imports"),
            token = requireAdminToken(),
            body = json.encodeToString(payload).toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            accept = "application/json",
            requestHeaders = clientContextHeaders(cohortKey),
            maxResponseBytes = MAX_SOURCE_IMPORT_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_CREATED, HttpURLConnection.HTTP_CONFLICT))
        if (response.status == HttpURLConnection.HTTP_CONFLICT) {
            val decoded = json.decodeFromString<SourceImportResponse>(response.body.toString(Charsets.UTF_8))
            if (decoded.schemaVersion != 1 || decoded.status != "duplicate") {
                throw IOException("The source-import duplicate response is invalid")
            }
            decoded.duplicateOf
                ?.toRemoteUpload()
                ?: throw IOException("The source-import duplicate response is invalid")
        } else {
            val decoded = json.decodeFromString<SourceImportResponse>(response.body.toString(Charsets.UTF_8))
            if (decoded.schemaVersion != 1 || decoded.status !in setOf("imported", "restored")) {
                throw IOException("The source-import response is invalid")
            }
            decoded.song
                ?.toRemoteUpload()
                ?: throw IOException("The source-import response is invalid")
        }
    }

    suspend fun resolveReviewedMatch(
        source: String,
        cohortKey: String,
    ): LinkImportResolution = withContext(Dispatchers.IO) {
        val requestedSource = source.trim()
        require(requestedSource.length in 1..8_192) { "Enter one supported track link to review" }
        val response = request(
            method = "POST",
            url = endpoint("/api/v1/admin/debrid/resolve"),
            token = requireAdminToken(),
            body = json.encodeToString(ReviewedMatchResolveRequest(requestedSource))
                .toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            accept = "application/json",
            requestHeaders = clientContextHeaders(cohortKey),
            maxResponseBytes = MAX_REVIEWED_MATCH_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        val decoded = json.decodeFromString<ReviewedMatchResolveResponse>(
            response.body.toString(Charsets.UTF_8),
        )
        decoded.validatedResolution()
    }

    suspend fun deleteRemoteSong(songID: String) = withContext(Dispatchers.IO) {
        val response = request(
            method = "DELETE",
            url = endpoint("/api/v1/admin/songs/${encodePathSegment(songID)}"),
            token = requireAdminToken(),
        )
        requireStatus(
            response,
            setOf(HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_NO_CONTENT),
        )
    }

    suspend fun fetchPlaylists(): RemotePlaylistsDocument = withContext(Dispatchers.IO) {
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/playlists"),
            token = requireAccessToken(),
            accept = "application/json",
            maxResponseBytes = MAX_PLAYLIST_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        json.decodeFromString<RemotePlaylistsDocument>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun postListeningHistory(entries: List<ListeningHistoryEntry>): Boolean =
        withContext(Dispatchers.IO) {
            if (entries.isEmpty()) return@withContext true
            require(entries.size <= ListeningHistoryRetentionPolicy.MAX_UPLOAD_BATCH)
            val body = json.encodeToString(
                ListeningHistoryUploadDocument(entries.map { entry ->
                    ListeningHistoryUploadEntry(
                        id = entry.id,
                        trackID = entry.trackID,
                        songID = entry.remoteSongID,
                        startedAt = entry.startedAt,
                        listenedSeconds = entry.listenedSeconds,
                        title = entry.title,
                        artist = entry.artist,
                        album = entry.album,
                        durationSeconds = entry.durationSeconds,
                    )
                }),
            ).toByteArray(Charsets.UTF_8)
            val response = request(
                method = "POST",
                url = endpoint("/api/v1/listening-history"),
                token = requireAccessToken(),
                body = body,
                contentType = "application/json",
                accept = "application/json",
                maxResponseBytes = MAX_ERROR_BYTES,
            )
            when (response.status) {
                HttpURLConnection.HTTP_NOT_FOUND, HttpURLConnection.HTTP_BAD_METHOD -> false
                in 200..299 -> true
                else -> throw serverException(response)
            }
        }

    suspend fun fetchListeningHistory(limit: Int = 2_000): RemoteListeningHistoryDocument? =
        withContext(Dispatchers.IO) {
            require(limit in 1..2_000)
            val response = request(
                method = "GET",
                url = URL("$baseURL/api/v1/listening-history?limit=$limit"),
                token = requireAccessToken(),
                accept = "application/json",
                maxResponseBytes = MAX_LISTENING_HISTORY_RESPONSE_BYTES,
            )
            when (response.status) {
                HttpURLConnection.HTTP_NOT_FOUND, HttpURLConnection.HTTP_BAD_METHOD -> null
                HttpURLConnection.HTTP_OK -> json.decodeFromString(response.body.toString(Charsets.UTF_8))
                else -> throw serverException(response)
            }
        }

    suspend fun fetchProfiles(): SyncProfilesResponse = withContext(Dispatchers.IO) {
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/profiles"),
            token = requireAccessToken(),
            accept = "application/json",
            includeProfile = false,
            maxResponseBytes = MAX_PROFILE_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        json.decodeFromString<SyncProfilesResponse>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun createProfile(name: String): SyncProfile = withContext(Dispatchers.IO) {
        val response = request(
            method = "POST",
            url = endpoint("/api/v1/profiles"),
            token = requireAccessToken(),
            body = json.encodeToString(CreateProfileRequest(name)).toByteArray(Charsets.UTF_8),
            contentType = "application/json",
            accept = "application/json",
            includeProfile = false,
            maxResponseBytes = MAX_PROFILE_RESPONSE_BYTES,
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_CREATED))
        json.decodeFromString<SyncProfile>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun putPlaylists(document: RemotePlaylistsDocument): PlaylistPutResult =
        withContext(Dispatchers.IO) {
            val response = request(
                method = "PUT",
                url = endpoint("/api/v1/playlists"),
                token = requireAccessToken(),
                body = json.encodeToString(document).toByteArray(Charsets.UTF_8),
                contentType = "application/json",
                accept = "application/json",
                maxResponseBytes = MAX_PLAYLIST_RESPONSE_BYTES,
            )
            val updated = when (response.status) {
                HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_CONFLICT ->
                    json.decodeFromString<RemotePlaylistsDocument>(
                        response.body.toString(Charsets.UTF_8),
                    )
                else -> throw serverException(response)
            }
            when (response.status) {
                HttpURLConnection.HTTP_OK -> PlaylistPutResult.Updated(updated)
                else -> PlaylistPutResult.Conflict(updated)
            }
        }

    private suspend fun downloadSongs(
        songs: List<RemoteSong>,
        repository: LibraryRepository,
        existingRemoteIDs: Set<String>,
        onProgress: (TransferProgress) -> Unit,
        beforeEach: () -> Unit,
    ): ServerDownloadBatchResult {
        val allocatedDownloads = mutableListOf<File>()
        return try {
            withContext(Dispatchers.IO) {
                val pending = PendingDownloadBatchPolicy.songs(songs, existingRemoteIDs)
                var processed = 0

                suspend fun downloadItem(index: Int, song: RemoteSong): ServerDownloadItemResult {
                    coroutineContext.ensureActive()
                    // Re-evaluate the exact snapshotted client policy immediately
                    // before each file allocation and authenticated media request.
                    beforeEach()
                    val itemProgress = TransferProgress(
                        completed = processed,
                        total = pending.size,
                        currentFilename = song.filename,
                        currentItem = index + 1,
                        currentSongID = song.id,
                        currentTitle = song.title,
                        bytesTransferred = 0L,
                        totalBytes = song.size.takeIf { it > 0L },
                    )
                    onProgress(itemProgress)
                    val destination = repository.newDownloadFile(song.filename)
                    synchronized(allocatedDownloads) { allocatedDownloads += destination }
                    val result = try {
                        val verifiedContentSHA256 = downloadToFile(
                            song,
                            destination,
                            repository,
                            beforeRead = beforeEach,
                        ) { transferred, totalBytes ->
                            onProgress(
                                TransferProgress(
                                    completed = processed,
                                    total = pending.size,
                                    currentFilename = song.filename,
                                    currentItem = index + 1,
                                    currentSongID = song.id,
                                    currentTitle = song.title,
                                    bytesTransferred = transferred,
                                    totalBytes = totalBytes,
                                ),
                            )
                        }
                        // The media stream is complete. Hide its byte card before local media
                        // inspection/tag extraction, which may take time but is not downloading.
                        onProgress(TransferProgressBoundaryPolicy.hidden(itemProgress))
                        ServerDownloadItemResult(
                            index = index,
                            track = repository.registerDownloadedFile(
                                destination,
                                song,
                                baseURL,
                                profileID,
                                // Artwork is intentionally backfilled after the media batch so
                                // a slow image host cannot block the next song download.
                                fallbackArtwork = null,
                                verifiedContentSHA256 = verifiedContentSHA256,
                            ),
                        )
                    } catch (error: CancellationException) {
                        repository.discardUncommittedDownload(destination)
                        throw error
                    } catch (error: Throwable) {
                        repository.discardUncommittedDownload(destination)
                        // A transient item failure should not discard completed
                        // downloads, but a policy/profile change must stop the
                        // batch immediately instead of becoming an item error.
                        beforeEach()
                        ServerDownloadItemResult(
                            index = index,
                            failure = ServerDownloadFailure(
                                songID = song.id,
                                filename = song.filename,
                                message = error.message ?: "Download failed",
                            ),
                        )
                    }
                    beforeEach()
                    processed += 1
                    onProgress(
                        TransferProgressBoundaryPolicy.hidden(
                            itemProgress.copy(
                                completed = processed,
                                currentItemComplete = result.track != null,
                            ),
                        ),
                    )
                    return result
                }

                // A single popup can only truthfully represent one active item. Keep catalog
                // downloads sequential so its title, byte count, and progress bar cannot race.
                val results = pending.mapIndexed { index, song ->
                    downloadItem(index, song)
                }

                ServerDownloadBatchResult(
                    tracks = results.mapNotNull(ServerDownloadItemResult::track),
                    failures = results.mapNotNull(ServerDownloadItemResult::failure),
                )
            }
        } catch (error: Throwable) {
            // A cancellation or policy/profile interruption means the caller
            // cannot commit this result, so remove every uncommitted allocation.
            synchronized(allocatedDownloads) {
                allocatedDownloads.forEach(repository::discardUncommittedDownload)
            }
            throw error
        }
    }

    private suspend fun downloadToFile(
        song: RemoteSong,
        destination: File,
        repository: LibraryRepository,
        beforeRead: () -> Unit,
        onBytes: (Long, Long?) -> Unit,
    ): String = withContext(Dispatchers.IO) {
        val requirements = DownloadIntegrityPolicy.requirements(
            catalogBytes = song.size,
            contentSHA256 = song.contentSHA256,
        )
        val connection = openAuthorizedMediaConnection(
            url = resolveRemoteURL(song.downloadURL),
            readTimeoutMs = DOWNLOAD_TIMEOUT_MS,
        )
        try {
            val status = connection.responseCode
            beforeRead()
            if (status != HttpURLConnection.HTTP_OK) {
                throw serverException(connection.response(MAX_ERROR_BYTES))
            }
            val expectations = DownloadIntegrityPolicy.withResponseLength(
                requirements = requirements,
                responseBytes = connection.contentLengthLong.takeIf { it >= 0L },
            )
            val temporary = repository.newDownloadStagingFile()
            try {
                val digest = MessageDigest.getInstance("SHA-256")
                val progressThrottle = TransferProgressThrottle()
                var transferred = 0L
                connection.inputStream.use { input ->
                    temporary.outputStream().use { output ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buffer)
                            beforeRead()
                            if (read < 0) break
                            if (read == 0) continue
                            val updatedTransferred = DownloadIntegrityPolicy.checkedTotalBytes(
                                expectations = expectations,
                                currentBytes = transferred,
                                incomingBytes = read,
                                filename = song.filename,
                            )
                            output.write(buffer, 0, read)
                            digest.update(buffer, 0, read)
                            transferred = updatedTransferred
                            if (progressThrottle.shouldEmit(
                                    transferred = transferred,
                                    totalBytes = expectations.expectedBytes,
                                    nowNanos = System.nanoTime(),
                                )
                            ) {
                                onBytes(transferred, expectations.expectedBytes)
                            }
                        }
                    }
                }
                onBytes(transferred, expectations.expectedBytes)
                val verifiedContentSHA256 = DownloadIntegrityPolicy.verify(
                    expectations = expectations,
                    actualBytes = transferred,
                    actualSHA256 = digest.digest().toHexString(),
                    filename = song.filename,
                )
                DownloadAdoptionPolicy.authorizeAndMove(
                    staging = temporary,
                    destination = destination,
                    authorize = beforeRead,
                )
                verifiedContentSHA256
            } catch (error: Throwable) {
                temporary.delete()
                throw error
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun request(
        method: String,
        url: URL,
        token: String,
        body: ByteArray? = null,
        contentType: String? = null,
        accept: String? = null,
        includeProfile: Boolean = true,
        requestHeaders: Map<String, String> = emptyMap(),
        maxResponseBytes: Int? = null,
    ): Response {
        val connection = open(url, method, token, includeProfile).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = REQUEST_TIMEOUT_MS
            accept?.let { setRequestProperty("Accept", it) }
            contentType?.let { setRequestProperty("Content-Type", it) }
            requestHeaders.forEach(::setRequestProperty)
            if (body != null) {
                doOutput = true
                setFixedLengthStreamingMode(body.size)
            }
        }
        return try {
            if (body != null) connection.outputStream.use { it.write(body) }
            connection.response(maxResponseBytes ?: MAX_ERROR_BYTES)
        } finally {
            connection.disconnect()
        }
    }

    private fun open(
        url: URL,
        method: String,
        token: String,
        includeProfile: Boolean = true,
    ): HttpURLConnection {
        val authorizedURL = ServerNetworkPolicy.requireAuthorizedURL(
            baseURL,
            url,
            cleartextDevelopmentEnabled,
        )
        return (authorizedURL.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            useCaches = false
            setRequestProperty("Authorization", "Bearer $token")
            if (includeProfile) setRequestProperty("X-Resonance-Profile", profileID)
        }
    }

    private fun openAuthorizedMediaConnection(
        url: URL,
        readTimeoutMs: Int,
    ): HttpURLConnection {
        var currentURL = ServerNetworkPolicy.requireAuthorizedURL(
            baseURL,
            url,
            cleartextDevelopmentEnabled,
        )
        repeat(MAX_MEDIA_REDIRECTS + 1) { redirectCount ->
            val connection = open(
                url = currentURL,
                method = "GET",
                token = requireAccessToken(),
            ).apply {
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = readTimeoutMs
                applyClientContextHeaders(requireInstallationCohortKey())
            }
            if (connection.responseCode !in REDIRECT_STATUSES) return connection
            if (redirectCount == MAX_MEDIA_REDIRECTS) {
                connection.disconnect()
                throw IOException("The media download redirected too many times")
            }
            val location = connection.getHeaderField("Location")
            if (location.isNullOrBlank()) return connection
            val redirectedURL = try {
                ServerNetworkPolicy.resolveAuthorizedRedirect(
                    baseURL,
                    currentURL,
                    location,
                    cleartextDevelopmentEnabled,
                )
            } catch (error: Throwable) {
                connection.disconnect()
                throw error
            }
            connection.disconnect()
            currentURL = redirectedURL
        }
        throw IOException("The media download redirected too many times")
    }

    private fun openArtworkConnection(url: URL): HttpURLConnection {
        var currentURL = ServerNetworkPolicy.requireArtworkURL(
            baseURL,
            url,
            cleartextDevelopmentEnabled,
        )
        repeat(MAX_MEDIA_REDIRECTS + 1) { redirectCount ->
            val isServerOrigin = hasSameOrigin(currentURL, URL("$baseURL/"))
            val connection = (currentURL.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                useCaches = false
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = DOWNLOAD_TIMEOUT_MS
                if (isServerOrigin) {
                    setRequestProperty("Authorization", "Bearer ${requireAccessToken()}")
                    setRequestProperty("X-Resonance-Profile", profileID)
                    applyClientContextHeaders(requireInstallationCohortKey())
                }
            }
            if (connection.responseCode !in REDIRECT_STATUSES) return connection
            if (redirectCount == MAX_MEDIA_REDIRECTS) {
                connection.disconnect()
                throw IOException("The artwork download redirected too many times")
            }
            val location = connection.getHeaderField("Location")
            if (location.isNullOrBlank()) return connection
            val redirectedURL = try {
                ServerNetworkPolicy.resolveArtworkRedirect(
                    baseURL,
                    currentURL,
                    location,
                    cleartextDevelopmentEnabled,
                )
            } catch (error: Throwable) {
                connection.disconnect()
                throw error
            }
            connection.disconnect()
            currentURL = redirectedURL
        }
        throw IOException("The artwork download redirected too many times")
    }

    private fun HttpURLConnection.response(maxBytes: Int): Response {
        val status = responseCode
        val source = if (status in 200..299) inputStream else errorStream
        return Response(
            status,
            source?.use { input ->
                if (contentLengthLong > maxBytes) throw ResponseTooLargeException()
                readBoundedBytes(input, maxBytes)
            } ?: ByteArray(0),
        )
    }

    private fun requireStatus(response: Response, accepted: Set<Int>) {
        if (response.status !in accepted) throw serverException(response)
    }

    private fun serverException(response: Response): ServerException {
        val message = runCatching {
            json.decodeFromString<ServerErrorPayload>(response.body.toString(Charsets.UTF_8)).error
        }.getOrNull()?.takeIf { it.isNotBlank() }
        return ServerException(response.status, message)
    }

    private fun endpoint(path: String): URL = URL("$baseURL$path")

    private fun resolveRemoteURL(pathOrURL: String): URL =
        ServerNetworkPolicy.resolveAuthorizedMediaURL(
            baseURL,
            pathOrURL,
            cleartextDevelopmentEnabled,
        )

    private fun readArtworkBytes(input: java.io.InputStream): ByteArray? {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(BUFFER_SIZE)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            if (total > MAX_ARTWORK_BYTES) return null
            output.write(buffer, 0, read)
        }
        return output.toByteArray().takeIf(ByteArray::isNotEmpty)
    }

    private fun requireAccessToken(): String =
        accessToken.trim().takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("Sign in to your Resonance account")

    private fun requireAdminToken(): String =
        adminToken.trim().takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("Sign in to your Resonance account")

    private fun requireClientConfigToken(): String =
        accessToken.trim().takeIf(String::isNotEmpty)
            ?: adminToken.trim().takeIf(String::isNotEmpty)
            ?: throw IllegalStateException("Sign in to your Resonance account")

    private fun requireInstallationCohortKey(): String = installationCohortKey
        .takeIf(String::isNotBlank)
        ?: throw IllegalStateException("The anonymous client cohort key is unavailable")

    private fun clientConfigRequestContext(cohortKey: String) = ClientConfigRequestContext(
        origin = configOrigin,
        profileID = profileID,
        appVersion = BuildConfig.VERSION_NAME,
        appBuild = BuildConfig.VERSION_CODE.toLong(),
        cohortKey = cohortKey,
    )

    private fun clientContextHeaders(cohortKey: String): Map<String, String> =
        ClientContextHeaderPolicy.headers(
            cohortKey = cohortKey,
            appVersion = BuildConfig.VERSION_NAME,
            appBuild = BuildConfig.VERSION_CODE.toLong(),
        )

    private fun HttpURLConnection.applyClientContextHeaders(cohortKey: String) {
        clientContextHeaders(cohortKey).forEach(::setRequestProperty)
    }

    private fun readBoundedBytes(input: java.io.InputStream, maximum: Int): ByteArray {
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(BUFFER_SIZE.coerceAtMost(maximum + 1))
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            if (output.size() > maximum - read) {
                throw ResponseTooLargeException()
            }
            output.write(buffer, 0, read)
        }
        return output.toByteArray()
    }

    private fun encodePathSegment(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

    private data class Response(val status: Int, val body: ByteArray)

    private class ResponseTooLargeException : IOException("The server response is too large")

    @Serializable
    private data class ServerErrorPayload(val error: String = "")

    @Serializable
    private data class CreateProfileRequest(val name: String)

    companion object {
        private const val CONNECT_TIMEOUT_MS = 20_000
        private const val REQUEST_TIMEOUT_MS = 60_000
        private const val DOWNLOAD_TIMEOUT_MS = 120_000
        private const val CLIENT_CONFIG_TIMEOUT_MS = 15_000
        private const val MAX_ERROR_BYTES = 64 * 1_024
        private const val MAX_LISTENING_HISTORY_RESPONSE_BYTES = 8 * 1_024 * 1_024
        private const val MAX_CATALOG_RESPONSE_BYTES = 16 * 1_024 * 1_024
        private const val MAX_PLAYLIST_RESPONSE_BYTES = 4 * 1_024 * 1_024
        private const val MAX_PROFILE_RESPONSE_BYTES = 512 * 1_024
        private const val MAX_SOURCE_IMPORT_RESPONSE_BYTES = 256 * 1_024
        private const val MAX_REVIEWED_MATCH_RESPONSE_BYTES = 512 * 1_024
        private const val MAX_LISTEN_ALONG_RESPONSE_BYTES = 256 * 1_024
        private const val MAX_ARTWORK_BYTES = 10L * 1_024L * 1_024L
        private const val BUFFER_SIZE = 64 * 1_024
        private const val MAX_MEDIA_REDIRECTS = 5
        private val REDIRECT_STATUSES = setOf(
            HttpURLConnection.HTTP_MOVED_PERM,
            HttpURLConnection.HTTP_MOVED_TEMP,
            HttpURLConnection.HTTP_SEE_OTHER,
            307,
            308,
        )

        fun normalizeServerURL(
            value: String,
            allowCleartextDevelopment: Boolean = BuildConfig.DEBUG,
        ): String {
            return ServerNetworkPolicy.normalizeServerURL(
                value,
                BuildConfig.DEBUG && allowCleartextDevelopment,
            )
        }

        fun canonicalServerOrigin(
            value: String,
            allowCleartextDevelopment: Boolean = BuildConfig.DEBUG,
        ): String = ServerNetworkPolicy.canonicalOrigin(
            value,
            BuildConfig.DEBUG && allowCleartextDevelopment,
        )
    }
}

internal object ServerNetworkPolicy {
    private val cleartextDevelopmentHosts = setOf(
        "localhost",
        "127.0.0.1",
        "10.0.2.2",
    )

    fun normalizeServerURL(value: String, allowCleartextDevelopment: Boolean): String {
        val trimmed = value.trim().trimEnd('/')
        val uri = runCatching { URI(trimmed) }.getOrNull()
            ?: throw IllegalArgumentException("Enter a valid server URL")
        val scheme = uri.scheme?.lowercase()
        require(scheme == "https" || scheme == "http") {
            "Server URL must start with https://"
        }
        val host = normalizedHost(uri.host)
        require(host.isNotEmpty()) { "Server URL is missing a host" }
        require(uri.rawUserInfo == null) { "Server URL must not contain credentials" }
        require(uri.rawQuery == null && uri.rawFragment == null) {
            "Server URL must not contain a query or fragment"
        }
        require(uri.port in -1..65_535) { "Server URL has an invalid port" }
        require(
            scheme == "https" ||
                allowCleartextDevelopment && host in cleartextDevelopmentHosts,
        ) {
            "Server URL must use HTTPS outside local development"
        }
        return if (
            scheme == "https" && host == "music.unblocked.mov" &&
            (uri.port == -1 || uri.port == 443) && uri.path.orEmpty().isEmpty()
        ) {
            "https://resonance-core.blithe-haven-9710.chatgpt.site"
        } else {
            trimmed
        }
    }

    fun canonicalOrigin(value: String, allowCleartextDevelopment: Boolean): String {
        val normalized = URI(normalizeServerURL(value, allowCleartextDevelopment))
        val scheme = normalized.scheme.lowercase()
        val host = normalizedHost(normalized.host)
        val port = normalized.port.takeUnless {
            it == -1 || scheme == "https" && it == 443 || scheme == "http" && it == 80
        } ?: -1
        return URI(scheme, null, host, port, null, null, null).toASCIIString()
    }

    fun resolveAuthorizedMediaURL(
        baseURL: String,
        pathOrURL: String,
        allowCleartextDevelopment: Boolean = false,
    ): URL {
        val base = URI("${normalizeServerURL(baseURL, allowCleartextDevelopment)}/")
        val resolved = runCatching { base.resolve(URI(pathOrURL.trim())) }
            .getOrElse { throw IllegalArgumentException("The media URL is invalid", it) }
        return requireAuthorizedURI(baseURL, resolved, allowCleartextDevelopment)
    }

    fun resolveArtworkURL(
        baseURL: String,
        pathOrURL: String,
        allowCleartextDevelopment: Boolean = false,
    ): URL {
        val base = URI("${normalizeServerURL(baseURL, allowCleartextDevelopment)}/")
        val resolved = runCatching { base.resolve(URI(pathOrURL.trim())) }
            .getOrElse { throw IllegalArgumentException("The artwork URL is invalid", it) }
        return requireArtworkURI(baseURL, resolved, allowCleartextDevelopment)
    }

    fun resolveAuthorizedRedirect(
        baseURL: String,
        currentURL: URL,
        location: String,
        allowCleartextDevelopment: Boolean = false,
    ): URL {
        val resolved = runCatching { currentURL.toURI().resolve(URI(location.trim())) }
            .getOrElse { throw IOException("The media redirect URL is invalid", it) }
        return try {
            requireAuthorizedURI(baseURL, resolved, allowCleartextDevelopment)
        } catch (error: IllegalArgumentException) {
            throw IOException("The media redirect left the configured server origin", error)
        }
    }

    fun resolveArtworkRedirect(
        baseURL: String,
        currentURL: URL,
        location: String,
        allowCleartextDevelopment: Boolean = false,
    ): URL {
        val resolved = runCatching { currentURL.toURI().resolve(URI(location.trim())) }
            .getOrElse { throw IOException("The artwork redirect URL is invalid", it) }
        return try {
            requireArtworkURI(baseURL, resolved, allowCleartextDevelopment)
        } catch (error: IllegalArgumentException) {
            throw IOException("The artwork redirect URL is not secure", error)
        }
    }

    fun requireAuthorizedURL(
        baseURL: String,
        url: URL,
        allowCleartextDevelopment: Boolean = false,
    ): URL = requireAuthorizedURI(baseURL, url.toURI(), allowCleartextDevelopment)

    fun requireArtworkURL(
        baseURL: String,
        url: URL,
        allowCleartextDevelopment: Boolean = false,
    ): URL = requireArtworkURI(baseURL, url.toURI(), allowCleartextDevelopment)

    private fun requireAuthorizedURI(
        baseURL: String,
        uri: URI,
        allowCleartextDevelopment: Boolean,
    ): URL {
        val normalizedBase = URI(normalizeServerURL(baseURL, allowCleartextDevelopment))
        require(uri.rawUserInfo == null) { "Media URL must not contain credentials" }
        require(uri.rawFragment == null) { "Media URL must not contain a fragment" }
        val url = runCatching { uri.toURL() }
            .getOrElse { throw IllegalArgumentException("The media URL is invalid", it) }
        val base = normalizedBase.toURL()
        require(hasSameOrigin(url, base)) {
            "Media URL must use the configured server origin"
        }
        return url
    }

    private fun requireArtworkURI(
        baseURL: String,
        uri: URI,
        allowCleartextDevelopment: Boolean,
    ): URL {
        val normalizedBase = URI(normalizeServerURL(baseURL, allowCleartextDevelopment))
        require(uri.rawUserInfo == null) { "Artwork URL must not contain credentials" }
        require(uri.rawFragment == null) { "Artwork URL must not contain a fragment" }
        val url = runCatching { uri.toURL() }
            .getOrElse { throw IllegalArgumentException("The artwork URL is invalid", it) }
        val base = normalizedBase.toURL()
        val sameOrigin = hasSameOrigin(url, base)
        val host = normalizedHost(url.host)
        require(sameOrigin || isApprovedArtworkHost(host)) {
            "Artwork URL must use the configured server or an approved artwork host"
        }
        require(sameOrigin || url.port == -1 || url.port == 443) {
            "Artwork URL must use the standard HTTPS port"
        }
        val isDevelopmentOrigin = sameOrigin && allowCleartextDevelopment
        require(!isPrivateOrLocalHost(host) || isDevelopmentOrigin) {
            "Artwork URL must not target a private or local host"
        }
        require(url.protocol.equals("https", ignoreCase = true) || sameOrigin) {
            "Artwork URL must use HTTPS"
        }
        return url
    }

    private fun isApprovedArtworkHost(host: String): Boolean = artworkHostSuffixes.any { suffix ->
        host == suffix || host.endsWith(".$suffix")
    }

    internal fun isPrivateOrLocalHost(host: String): Boolean {
        val normalized = host.trimEnd('.').lowercase()
        if (
            normalized == "localhost" || normalized.endsWith(".localhost") ||
            normalized.endsWith(".local") || normalized == "local" ||
            normalized == "0.0.0.0" || normalized == "::" || normalized == "::1" ||
            normalized.all(Char::isDigit)
        ) return true
        if (normalized.contains(':')) {
            val address = runCatching { java.net.InetAddress.getByName(normalized) }.getOrNull()
            return address?.let {
                it.isAnyLocalAddress || it.isLoopbackAddress || it.isLinkLocalAddress ||
                    it.isSiteLocalAddress || it.hostAddress?.lowercase()?.startsWith("fc") == true ||
                    it.hostAddress?.lowercase()?.startsWith("fd") == true
            } == true
        }
        val octets = normalized.split('.').mapNotNull(String::toIntOrNull)
        if (octets.size == 4 && octets.joinToString(".") == normalized && octets.all { it in 0..255 }) {
            val first = octets[0]
            val second = octets[1]
            return first == 0 || first == 10 || first == 127 ||
                first == 169 && second == 254 ||
                first == 172 && second in 16..31 ||
                first == 192 && second == 168
        }
        return false
    }

    private fun normalizedHost(value: String?): String = value
        .orEmpty()
        .trim()
        .removePrefix("[")
        .removeSuffix("]")
        .lowercase()

    private val artworkHostSuffixes = setOf(
        "ytimg.com",
        "ggpht.com",
        "scdn.co",
        "spotifycdn.com",
        "sndcdn.com",
    )
}

internal data class DownloadRequirements(
    val expectedSHA256: String,
    val catalogBytes: Long?,
)

internal data class DownloadExpectations(
    val expectedSHA256: String,
    val expectedBytes: Long?,
)

internal object DownloadIntegrityPolicy {
    // Resonance accepts both audio and video. Keep the streamed transfer bounded without
    // imposing an audio-only ceiling on valid local-first media libraries.
    const val MAX_MEDIA_BYTES = 2L * 1_024L * 1_024L * 1_024L
    private val sha256Pattern = Regex("^[a-f0-9]{64}$")

    fun requirements(catalogBytes: Long, contentSHA256: String?): DownloadRequirements {
        if (catalogBytes < 0L) throw IOException("The catalog contains an invalid download size")
        if (catalogBytes > MAX_MEDIA_BYTES) throw IOException("The catalog download is too large")
        val expectedSHA256 = contentSHA256?.trim()?.lowercase().orEmpty()
        if (!sha256Pattern.matches(expectedSHA256)) {
            throw IOException("The catalog is missing a valid SHA-256 checksum")
        }
        return DownloadRequirements(
            expectedSHA256 = expectedSHA256,
            catalogBytes = catalogBytes.takeIf { it > 0L },
        )
    }

    fun withResponseLength(
        requirements: DownloadRequirements,
        responseBytes: Long?,
    ): DownloadExpectations {
        if (responseBytes != null && responseBytes <= 0L) {
            throw IOException("The server returned an empty download")
        }
        if (responseBytes != null && responseBytes > MAX_MEDIA_BYTES) {
            throw IOException("The server download is too large")
        }
        if (
            requirements.catalogBytes != null &&
            responseBytes != null &&
            requirements.catalogBytes != responseBytes
        ) {
            throw IOException("The download size does not match the server catalog")
        }
        return DownloadExpectations(
            expectedSHA256 = requirements.expectedSHA256,
            expectedBytes = requirements.catalogBytes ?: responseBytes,
        )
    }

    fun verify(
        expectations: DownloadExpectations,
        actualBytes: Long,
        actualSHA256: String,
        filename: String,
    ): String {
        if (actualBytes <= 0L) throw IOException("$filename downloaded no audio data")
        if (actualBytes > MAX_MEDIA_BYTES) throw IOException("$filename exceeds the maximum download size")
        if (expectations.expectedBytes != null && actualBytes != expectations.expectedBytes) {
            throw IOException("Download ended before $filename was complete")
        }
        val normalizedActual = actualSHA256.trim().lowercase()
        if (!sha256Pattern.matches(normalizedActual) || normalizedActual != expectations.expectedSHA256) {
            throw IOException("The SHA-256 checksum for $filename does not match the server catalog")
        }
        return normalizedActual
    }

    fun checkedTotalBytes(
        expectations: DownloadExpectations,
        currentBytes: Long,
        incomingBytes: Int,
        filename: String,
    ): Long {
        require(currentBytes >= 0L) { "Transferred byte count must not be negative" }
        require(incomingBytes > 0) { "Incoming byte count must be positive" }
        if (currentBytes > MAX_MEDIA_BYTES - incomingBytes.toLong()) {
            throw IOException("$filename exceeds the maximum download size")
        }
        val updatedBytes = currentBytes + incomingBytes
        if (expectations.expectedBytes != null && updatedBytes > expectations.expectedBytes) {
            throw IOException("$filename exceeded the expected download size")
        }
        return updatedBytes
    }
}

internal object DownloadAdoptionPolicy {
    fun authorizeAndMove(
        staging: File,
        destination: File,
        authorize: () -> Unit,
    ) {
        try {
            // Integrity validation can be expensive. Reauthorize the captured
            // lease immediately before the verified bytes enter the library.
            authorize()
            Files.move(
                staging.toPath(),
                destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (error: Throwable) {
            staging.delete()
            throw error
        }
    }
}

private fun ByteArray.toHexString(): String =
    joinToString(separator = "") { byte -> "%02x".format(byte.toInt() and 0xff) }

internal fun hasSameOrigin(first: URL, second: URL): Boolean {
    fun URL.effectivePort(): Int = if (port >= 0) port else defaultPort
    return first.protocol.equals(second.protocol, ignoreCase = true)
        && first.host.equals(second.host, ignoreCase = true)
        && first.effectivePort() == second.effectivePort()
}

@Serializable
data class RemoteUpload(
    val id: String,
    val filename: String = "",
    val size: Long = 0,
)

@Serializable
private data class SourceLinkUploadRequest(
    @SerialName("schema_version") val schemaVersion: Int = 3,
    @SerialName("source_url") val sourceURL: String,
    @SerialName("media_kind") val mediaKind: String,
)

@Serializable
private data class LegacySourceLinkUploadRequest(
    @SerialName("source_url") val sourceURL: String,
    @SerialName("schema_version") val schemaVersion: Int = 2,
)

sealed interface ClientConfigFetchResult {
    data class Verified(
        val config: EffectiveClientConfig,
        val envelope: SignedClientConfigEnvelope,
        val cacheScope: ClientConfigCacheScope,
    ) : ClientConfigFetchResult

    data object Unsupported : ClientConfigFetchResult
}

@Serializable
private data class ReviewedMatchResolveRequest(val source: String)

@Serializable
internal data class ReviewedMatchResolveResponse(
    val provider: String = "",
    val type: String = "",
    val source: String = "",
    @SerialName("video_id") val videoID: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val author: String? = null,
    val album: String? = null,
    @SerialName("track_number") val trackNumber: Int? = null,
    @SerialName("duration_seconds") val durationSeconds: Int? = null,
    @SerialName("artwork_url") val artworkURL: String? = null,
    @SerialName("thumbnail_url") val thumbnailURL: String? = null,
    @SerialName("review_candidates") val reviewCandidates: List<ReviewedMatchCandidate> = emptyList(),
) {
    fun validatedResolution(): LinkImportResolution {
        val metadata = when (provider) {
            "spotify" -> LinkImportTrack(
                title = title.requireReviewedText("title"),
                artist = artist.requireReviewedText("artist"),
                album = album?.trim()?.takeIf(String::isNotEmpty),
                durationSeconds = durationSeconds?.takeIf { it in 1..86_400 },
                artworkURL = artworkURL?.trim()?.takeIf(String::isNotEmpty),
                sourceURL = source.requireReviewedText("source"),
                trackNumber = trackNumber?.takeIf { it > 0 },
            )
            "youtube" -> LinkImportTrack(
                title = title.requireReviewedText("title"),
                artist = author?.trim()?.takeIf(String::isNotEmpty) ?: "Unknown uploader",
                durationSeconds = durationSeconds?.takeIf { it in 1..86_400 },
                artworkURL = thumbnailURL?.trim()?.takeIf(String::isNotEmpty),
                sourceURL = videoID?.let { "https://www.youtube.com/watch?v=$it" }
                    ?: throw IOException("The reviewed-match response is missing a video ID"),
            )
            else -> throw IOException("The reviewed-match response uses an unsupported provider")
        }
        // Only explicit review_candidates participate. Top-level metadata is
        // never an implicit or automatically selected transfer choice.
        val candidates = reviewCandidates
            .mapNotNull(ReviewedMatchCandidate::validatedCandidate)
            .distinctBy(LinkImportCandidate::videoID)
        if (candidates.isEmpty()) throw IOException("The server returned no explicit review candidates")
        return LinkImportResolution(
            track = metadata,
            candidates = candidates,
            reviewedMatchPolicyBound = true,
        )
    }
}

@Serializable
internal data class ReviewedMatchCandidate(
    val provider: String = "",
    @SerialName("source_url") val sourceURL: String? = null,
    @SerialName("video_id") val videoID: String? = null,
    val title: String? = null,
    val artist: String? = null,
    val album: String? = null,
    @SerialName("duration_seconds") val durationSeconds: Int? = null,
    @SerialName("thumbnail_url") val thumbnailURL: String? = null,
    val score: Double? = null,
    val actionable: Boolean? = null,
    @SerialName("auto_selectable") val autoSelectable: Boolean? = null,
    @SerialName("requires_review") val requiresReview: Boolean? = null,
) {
    fun validatedCandidate(): LinkImportCandidate? {
        if (provider !in setOf("youtube", "youtube_music")) return null
        // Metadata-only candidates are deliberately non-actionable and may
        // become usable only through this explicit local review + byte ingest.
        if (actionable != false || autoSelectable != false || requiresReview != true) return null
        val id = videoID?.takeIf { it.matches(Regex("^[A-Za-z0-9_-]{11}$")) } ?: return null
        val canonical = runCatching {
            SourceImportPolicy.canonicalYouTubePageURL(sourceURL.orEmpty())
        }.getOrNull() ?: return null
        if (canonical != "https://www.youtube.com/watch?v=$id") return null
        val normalizedScore = score?.takeIf { it.isFinite() && it in 0.0..1.0 } ?: return null
        return LinkImportCandidate(
            videoID = id,
            title = title?.trim()?.takeIf(String::isNotEmpty) ?: return null,
            artist = artist?.trim()?.takeIf(String::isNotEmpty),
            durationSeconds = durationSeconds?.takeIf { it in 1..86_400 },
            thumbnailURL = thumbnailURL?.trim()?.takeIf(String::isNotEmpty),
            sourceURL = canonical,
            score = normalizedScore,
            sourceProvider = LinkImportSourceProvider.YouTube,
        )
    }
}

private fun String?.requireReviewedText(field: String): String = this
    ?.trim()
    ?.takeIf(String::isNotEmpty)
    ?: throw IOException("The reviewed-match response is missing $field")

@Serializable
private data class SourceImportRequest(
    @SerialName("schema_version") val schemaVersion: Int = 1,
    @SerialName("source_page_url") val sourcePageURL: String,
)

@Serializable
private data class SourceImportResponse(
    @SerialName("schema_version") val schemaVersion: Int = 0,
    val status: String = "",
    val song: SourceImportSong? = null,
    @SerialName("duplicate_of") val duplicateOf: SourceImportSong? = null,
)

@Serializable
private data class SourceImportSong(
    val id: String,
    val filename: String = "",
    val name: String = "",
    val size: Long = 0,
) {
    fun toRemoteUpload(): RemoteUpload = RemoteUpload(
        id = id,
        filename = filename.ifBlank { name },
        size = size,
    )
}

internal object SourceImportPolicy {
    fun canonicalYouTubePageURL(value: String): String {
        val trimmed = value.trim()
        require(trimmed.length in 1..2_048) { "The source page URL is too long" }
        val uri = runCatching { URI(trimmed) }.getOrNull()
            ?: throw IllegalArgumentException("Enter a valid YouTube page URL")
        require(uri.scheme.equals("https", ignoreCase = true)) {
            "Source page URLs must use HTTPS"
        }
        val host = uri.host.orEmpty()
        require(host == "www.youtube.com") {
            "Protocol v1 requires the exact www.youtube.com YouTube source page"
        }
        require(uri.rawUserInfo == null && uri.port == -1) {
            "The source page URL must not contain credentials or a custom port"
        }
        require(uri.rawFragment == null) { "The source page URL must not contain a fragment" }
        val videoID = uri.rawQuery
            ?.takeIf { uri.path == "/watch" }
            ?.split('&')
            ?.firstOrNull { it.startsWith("v=") }
            ?.removePrefix("v=")
        require(videoID?.matches(Regex("^[A-Za-z0-9_-]{11}$")) == true) {
            "Enter a YouTube video page URL with a valid video ID"
        }
        val canonical = "https://www.youtube.com/watch?v=$videoID"
        require(trimmed == canonical) {
            "Source-link upload requires the exact canonical YouTube page with no extra query or fragment"
        }
        return canonical
    }
}

@Serializable
private data class DuplicateRemoteUpload(
    @SerialName("duplicate_of") val duplicateOf: RemoteUpload,
)

class ServerException(
    val status: Int,
    val serverMessage: String? = null,
) : IOException(
    buildString {
        append("Server returned HTTP ")
        append(status)
        if (!serverMessage.isNullOrBlank()) {
            append(": ")
            append(serverMessage)
        }
    },
)
