package mov.unblocked.resonance.data

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.StatFs
import android.provider.OpenableColumns
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

class LibraryRepository(
    context: Context,
    private val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    },
) {
    private val appContext = context.applicationContext
    private val rootDirectory = File(appContext.filesDir, "Resonance")
    private val musicDirectory = File(rootDirectory, "Music")
    private val artworkDirectory = File(rootDirectory, "Artwork")
    private val stateFile = File(rootDirectory, "library.json")
    private val stateMutex = Mutex()

    init {
        musicDirectory.mkdirs()
        artworkDirectory.mkdirs()
    }

    suspend fun load(): StoredLibrary = withContext(Dispatchers.IO) {
        stateMutex.withLock {
            val decoded = if (!stateFile.isFile) {
                StoredLibrary()
            } else {
                try {
                    json.decodeFromString<StoredLibrary>(stateFile.readText())
                } catch (_: Throwable) {
                    // A corrupt state file cannot safely tell us which media is still owned.
                    // Keep every file in place so recovery remains possible.
                    return@withLock normalize(StoredLibrary())
                }
            }
            val migration = migrateUnlinkedDownloads(decoded)
            val providerURLMigration = migrateProviderMediaURLs(migration.library)
            val durationMigration = migratePlayableDurations(providerURLMigration.library)
            normalize(durationMigration.library).also { library ->
                if (migration.changed || providerURLMigration.changed || durationMigration.changed) writeState(library)
                cleanupUnreferencedAppOwnedFiles(library)
            }
        }
    }

    suspend fun save(library: StoredLibrary) = withContext(Dispatchers.IO) {
        stateMutex.withLock {
            writeState(normalize(library))
        }
    }

    private fun writeState(library: StoredLibrary) {
        rootDirectory.mkdirs()
        val temporary = File(rootDirectory, "${stateFile.name}.tmp")
        FileOutputStream(temporary).bufferedWriter(Charsets.UTF_8).use { writer ->
            writer.write(json.encodeToString(library))
            writer.flush()
        }
        if (!temporary.renameTo(stateFile)) {
            temporary.copyTo(stateFile, overwrite = true)
            temporary.delete()
        }
    }

    private data class LibraryMigration(
        val library: StoredLibrary,
        val changed: Boolean,
    )

    private fun migratePlayableDurations(library: StoredLibrary): LibraryMigration {
        if (PlayableDurationMigrationPolicy.Identifier in library.completedMigrations) {
            return LibraryMigration(library, changed = false)
        }
        val tracks = library.tracks.map { track ->
            val measured = fileForTrack(track).takeIf(File::isFile)?.let(::readPlayableDurationMs)
            if (measured != null && kotlin.math.abs(track.durationMs - measured) > 250L) {
                track.copy(durationMs = measured)
            } else {
                track
            }
        }
        return LibraryMigration(
            library.copy(
                tracks = tracks,
                completedMigrations = library.completedMigrations + PlayableDurationMigrationPolicy.Identifier,
            ),
            changed = true,
        )
    }

    private fun migrateProviderMediaURLs(library: StoredLibrary): LibraryMigration {
        if (ProviderMediaURLMigrationPolicy.Identifier in library.completedMigrations) {
            return LibraryMigration(library, changed = false)
        }
        val migrated = library.copy(
            tracks = library.tracks.map(ProviderMediaURLPolicy::sanitizeTrack),
            remoteSongMetadataCache = library.remoteSongMetadataCache.mapNotNull { (storedKey, entry) ->
                val sourceURL = ProviderMediaURLPolicy.persistableSourceURL(entry.sourceURL)
                    ?: return@mapNotNull null
                storedKey to entry.copy(
                    sourceURL = sourceURL,
                    artworkURL = ProviderMediaURLPolicy.sanitizeMetadataArtworkURL(entry.artworkURL),
                )
            }.toMap(),
            serverURL = ProviderMediaURLPolicy.boundedURL(library.serverURL) ?: StoredLibrary().serverURL,
            playlistSyncServerURL = ProviderMediaURLPolicy.boundedURL(library.playlistSyncServerURL),
            profileStates = library.profileStates
                .filterKeys { it.length <= ProviderMediaURLPolicy.MAX_URL_LENGTH }
                .mapValues { (_, state) ->
                    state.copy(playlistSyncServerURL = ProviderMediaURLPolicy.boundedURL(state.playlistSyncServerURL))
                },
            completedMigrations = library.completedMigrations + ProviderMediaURLMigrationPolicy.Identifier,
        )
        return LibraryMigration(migrated, changed = migrated != library)
    }

    private fun migrateUnlinkedDownloads(library: StoredLibrary): LibraryMigration {
        if (UnlinkedDownloadMigrationPolicy.Identifier in library.completedMigrations) {
            return LibraryMigration(library, changed = false)
        }

        val retained = mutableListOf<Track>()
        var completed = true
        var changed = false
        library.tracks.forEach { track ->
            val legacyDownloadOwned = RepositoryFilePolicy.downloadID(track.relativePath) != null
            val decision = UnlinkedDownloadMigrationPolicy.decision(track, legacyDownloadOwned)
            changed = changed || decision.track != track
            if (!decision.shouldDelete) {
                retained += decision.track
                return@forEach
            }

            val mediaFile = fileForTrack(decision.track)
            if (!isDirectChild(mediaFile, musicDirectory)) {
                retained += decision.track
                completed = false
                return@forEach
            }
            val deleted = !mediaFile.exists() || (mediaFile.isFile && mediaFile.delete())
            if (!deleted) {
                retained += decision.track
                completed = false
                return@forEach
            }
            artworkFile(decision.track)?.takeIf { isDirectChild(it, artworkDirectory) }?.delete()
            changed = true
        }

        val retainedIDs = retained.mapTo(linkedSetOf(), Track::id)
        val migrations = if (completed) {
            changed = true
            library.completedMigrations + UnlinkedDownloadMigrationPolicy.Identifier
        } else {
            library.completedMigrations
        }
        val migrated = library.copy(
            tracks = retained,
            playlists = library.playlists.map { playlist ->
                playlist.copy(trackIDs = playlist.trackIDs.filter(retainedIDs::contains))
            },
            favorites = library.favorites.intersect(retainedIDs),
            profileStates = library.profileStates.mapValues { (_, state) ->
                state.copy(
                    playlists = state.playlists.map { playlist ->
                        playlist.copy(trackIDs = playlist.trackIDs.filter(retainedIDs::contains))
                    },
                    favorites = state.favorites.intersect(retainedIDs),
                )
            },
            completedMigrations = migrations,
        )
        return LibraryMigration(migrated, changed)
    }

    suspend fun importAudio(uri: Uri, preferredFilename: String? = null): Track =
        withContext(Dispatchers.IO) {
            val displayName = preferredFilename
                ?.takeIf { it.isNotBlank() }
                ?: displayName(uri)
                ?: "Audio-${System.currentTimeMillis()}"
            val destination = uniqueMusicFile(displayName)
            try {
                appContext.contentResolver.openInputStream(uri)?.use { input ->
                    destination.outputStream().use(input::copyTo)
                } ?: error("Unable to open the selected audio file")
                trackFromFile(
                    destination,
                    fallbackTitle = destination.nameWithoutExtension,
                    preservesUnlinkedImport = true,
                )
            } catch (error: Throwable) {
                destination.delete()
                throw error
            }
        }

    suspend fun importAudio(
        uris: List<Uri>,
        onProgress: (TransferProgress) -> Unit = {},
    ): List<Track> = withContext(Dispatchers.IO) {
        uris.mapIndexedNotNull { index, uri ->
            val name = displayName(uri) ?: "Audio-${index + 1}"
            onProgress(TransferProgress(index, uris.size, name))
            runCatching { importAudio(uri, name) }.getOrNull().also {
                onProgress(TransferProgress(index + 1, uris.size, name))
            }
        }
    }

    suspend fun registerLocalImport(download: LinkImportDownload): Track =
        withContext(Dispatchers.IO) {
            val extension = download.file.extension.lowercase().takeIf { it in setOf("m4a", "mp3", "mp4") }
                ?: download.mediaMode.fileExtension
            val preferred = safeFilename(download.metadata.artist + " - " + download.metadata.title) + "." + extension
            val destination = uniqueMusicFile(preferred)
            try {
                if (!download.file.renameTo(destination)) {
                    download.file.copyTo(destination)
                    download.file.delete()
                }
                trackFromFile(
                    file = destination,
                    fallbackTitle = download.metadata.title,
                    fallbackArtist = download.metadata.artist,
                    fallbackAlbum = download.metadata.album ?: "Imported",
                    fallbackDurationMs = download.durationMs,
                    fallbackArtwork = download.artwork,
                    sourceURL = download.metadata.sourceURL,
                    downloadSourceURL = download.downloadSourceURL,
                    sourceSHA256 = download.sourceSHA256,
                    contentSHA256 = download.contentSHA256,
                    preservesUnlinkedImport = true,
                )
            } catch (error: Throwable) {
                destination.delete()
                throw error
            } finally {
                download.file.parentFile?.deleteRecursively()
            }
        }

    /** Registers an app-owned file already downloaded into this repository's Music directory. */
    suspend fun registerDownloadedFile(
        file: File,
        song: RemoteSong,
        sourceServer: String,
        syncProfileID: String,
        fallbackArtwork: ByteArray? = null,
        verifiedContentSHA256: String,
    ): Track = withContext(Dispatchers.IO) {
        require(file.parentFile?.canonicalFile == musicDirectory.canonicalFile) {
            "Downloaded audio must be inside the Resonance Music directory"
        }
        val trackID = requireNotNull(RepositoryFilePolicy.downloadID(file.name)) {
            "Downloaded audio must use an app-owned random filename"
        }
        try {
            trackFromFile(
                file = file,
                trackID = trackID,
                fallbackTitle = song.title.ifBlank { file.nameWithoutExtension },
                fallbackArtist = usefulFallback(song.artist, "Unknown Artist"),
                fallbackAlbum = usefulFallback(song.album, "Server Library"),
                remoteID = song.id,
                sourceServer = sourceServer,
                syncProfileID = syncProfileID,
                sourceURL = song.sourceURL,
                downloadSourceURL = ProviderMediaURLPolicy.persistableDownloadURL(song.sourceURL),
                fallbackArtwork = fallbackArtwork,
                contentSHA256 = verifiedContentSHA256,
                preservesUnlinkedImport = false,
            ).copy(
                // Catalog artwork is authoritative for a server song. Preserve embedded artwork
                // only as a temporary fallback until the non-blocking catalog backfill completes.
                artworkScanComplete = song.artworkURL.isNullOrBlank(),
            )
        } catch (error: Throwable) {
            discardUncommittedDownload(file)
            throw error
        }
    }

    suspend fun deleteLocalTrack(library: StoredLibrary, trackID: String): StoredLibrary =
        withContext(Dispatchers.IO) {
            val track = library.tracks.firstOrNull { it.id == trackID } ?: return@withContext library
            fileForTrack(track).delete()
            artworkFile(track)?.delete()
            normalize(
                library.copy(
                    tracks = library.tracks.filterNot { it.id == trackID },
                    favorites = library.favorites - trackID,
                    playlists = library.playlists.map { playlist ->
                        playlist.copy(trackIDs = playlist.trackIDs.filterNot { it == trackID })
                    },
                ),
            )
        }

    suspend fun deleteLocalTracks(library: StoredLibrary, trackIDs: Set<String>): StoredLibrary =
        withContext(Dispatchers.IO) {
            trackIDs.fold(library) { current, id -> deleteLocalTrack(current, id) }
        }

    suspend fun storageStats(library: StoredLibrary): StorageStats = withContext(Dispatchers.IO) {
        var importedBytes = 0L
        var downloadedBytes = 0L
        var importedCount = 0
        var downloadedCount = 0
        library.tracks.forEach { track ->
            val bytes = fileForTrack(track).takeIf(File::isFile)?.length() ?: 0L
            if (track.remoteID != null || track.sourceServer != null) {
                downloadedBytes += bytes
                downloadedCount += 1
            } else {
                importedBytes += bytes
                importedCount += 1
            }
        }
        StorageStats(
            importedBytes = importedBytes,
            downloadedBytes = downloadedBytes,
            availableBytes = StatFs(rootDirectory.absolutePath).availableBytes,
            importedCount = importedCount,
            downloadedCount = downloadedCount,
        )
    }

    fun fileForTrack(track: Track): File = File(musicDirectory, track.relativePath)

    fun artworkFile(track: Track): File? =
        track.artworkFilename?.let { File(artworkDirectory, it) }

    suspend fun persistArtwork(track: Track, artwork: ByteArray): Track =
        withContext(Dispatchers.IO) {
            val filename = writeArtwork(track.id, artwork) ?: return@withContext track
            track.copy(artworkFilename = filename, artworkScanComplete = true)
        }

    suspend fun refreshEmbeddedMetadata(track: Track): Track = withContext(Dispatchers.IO) {
        val file = fileForTrack(track)
        if (!file.isFile) return@withContext track
        val metadata = readMetadata(file)
        var refreshed = track.copy(
            title = metadata.title ?: track.title,
            artist = metadata.artist ?: track.artist,
            album = metadata.album ?: track.album,
            durationMs = metadata.durationMs.takeIf { it > 0L } ?: track.durationMs,
        )
        metadata.artwork?.let { artwork ->
            writeArtwork(track.id, artwork)?.let { filename ->
                refreshed = refreshed.copy(artworkFilename = filename, artworkScanComplete = true)
            }
        }
        refreshed
    }

    internal fun newDownloadFile(preferredFilename: String): File = File(
        musicDirectory,
        RepositoryFilePolicy.newDownloadFilename(
            preferredFilename = preferredFilename,
            randomID = UUID.randomUUID().toString(),
        ),
    )

    internal fun newDownloadStagingFile(): File {
        repeat(4) {
            val candidate = File(
                musicDirectory,
                RepositoryFilePolicy.newStagingFilename(UUID.randomUUID().toString()),
            )
            if (candidate.createNewFile()) return candidate
        }
        error("Unable to allocate a temporary download file")
    }

    internal fun discardUncommittedDownload(file: File) {
        if (!isDirectChild(file, musicDirectory)) return
        val downloadID = RepositoryFilePolicy.downloadID(file.name) ?: return
        file.delete()
        File(artworkDirectory, "$downloadID.artwork").delete()
    }

    private fun cleanupUnreferencedAppOwnedFiles(library: StoredLibrary) {
        val referencedMusic = library.tracks.mapTo(linkedSetOf(), Track::relativePath)
        val musicFiles = musicDirectory.listFiles().orEmpty().filter(File::isFile)
        val removableMusic = RepositoryFilePolicy.orphanedMusicFilenames(
            candidateFilenames = musicFiles.map(File::getName),
            referencedFilenames = referencedMusic,
            stateIsTrustworthy = true,
        )
        musicFiles.filter { it.name in removableMusic }.forEach(File::delete)

        val referencedArtwork = library.tracks
            .mapNotNullTo(linkedSetOf(), Track::artworkFilename)
        val artworkFiles = artworkDirectory.listFiles().orEmpty().filter(File::isFile)
        val removableArtwork = RepositoryFilePolicy.orphanedArtworkFilenames(
            candidateFilenames = artworkFiles.map(File::getName),
            referencedFilenames = referencedArtwork,
            stateIsTrustworthy = true,
        )
        artworkFiles.filter { it.name in removableArtwork }.forEach(File::delete)
    }

    private fun isDirectChild(file: File, directory: File): Boolean = runCatching {
        file.parentFile?.canonicalFile == directory.canonicalFile
    }.getOrDefault(false)

    private fun normalize(library: StoredLibrary): StoredLibrary {
        val reconciled = RemoteTrackIdentityPolicy.reconcileLibraryTracks(
            library = library,
            candidateTracks = library.tracks.filter { fileForTrack(it).isFile },
        )
        val existingTracks = reconciled.tracks.map(ProviderMediaURLPolicy::sanitizeTrack)
        val trackIDs = existingTracks.mapTo(linkedSetOf()) { it.id }
        val favorites = reconciled.favorites.intersect(trackIDs)
        val cleanedPlaylists = reconciled.playlists.map { playlist ->
            playlist.copy(trackIDs = playlist.trackIDs.filter { it in trackIDs }.distinct())
        }.toMutableList()
        val likedIndex = cleanedPlaylists.indexOfFirst(Playlist::isSystem)
        val liked = Playlist(
            id = cleanedPlaylists.getOrNull(likedIndex)?.id ?: UUID.randomUUID().toString(),
            name = "Liked Songs",
            trackIDs = existingTracks.map(Track::id).filter { it in favorites },
            isSystem = true,
        )
        if (likedIndex >= 0) cleanedPlaylists[likedIndex] = liked else cleanedPlaylists.add(0, liked)
        return reconciled.copy(
            serverURL = ProviderMediaURLPolicy.boundedURL(reconciled.serverURL) ?: StoredLibrary().serverURL,
            playlistSyncServerURL = ProviderMediaURLPolicy.boundedURL(reconciled.playlistSyncServerURL),
            tracks = existingTracks,
            playlists = cleanedPlaylists,
            favorites = favorites,
            listeningHistory = ListeningHistoryRetentionPolicy.normalize(reconciled.listeningHistory),
            remoteSongMetadataCache = RemoteSongMetadataCachePolicy.normalized(
                reconciled.remoteSongMetadataCache,
            ),
            profileStates = reconciled.profileStates
                .filterKeys { it.length <= ProviderMediaURLPolicy.MAX_URL_LENGTH }
                .mapValues { (_, state) ->
                    normalizeProfileState(state, existingTracks).copy(
                        playlistSyncServerURL = ProviderMediaURLPolicy.boundedURL(state.playlistSyncServerURL),
                    )
                },
        )
    }

    private fun normalizeProfileState(
        state: ProfileLibraryState,
        existingTracks: List<Track>,
    ): ProfileLibraryState {
        val trackIDs = existingTracks.mapTo(linkedSetOf(), Track::id)
        val favorites = state.favorites.intersect(trackIDs)
        val playlists = state.playlists.map { playlist ->
            playlist.copy(trackIDs = playlist.trackIDs.filter(trackIDs::contains).distinct())
        }.toMutableList()
        val likedIndex = playlists.indexOfFirst(Playlist::isSystem)
        val liked = Playlist(
            id = playlists.getOrNull(likedIndex)?.id ?: UUID.randomUUID().toString(),
            name = "Liked Songs",
            trackIDs = existingTracks.map(Track::id).filter(favorites::contains),
            isSystem = true,
        )
        if (likedIndex >= 0) playlists[likedIndex] = liked else playlists.add(0, liked)
        return state.copy(playlists = playlists, favorites = favorites)
    }

    private fun trackFromFile(
        file: File,
        trackID: String = UUID.randomUUID().toString(),
        fallbackTitle: String,
        fallbackArtist: String = "Unknown Artist",
        fallbackAlbum: String = "Imported",
        remoteID: String? = null,
        sourceServer: String? = null,
        syncProfileID: String? = null,
        sourceURL: String? = null,
        downloadSourceURL: String? = null,
        fallbackArtwork: ByteArray? = null,
        fallbackDurationMs: Long = 0L,
        sourceSHA256: String? = null,
        contentSHA256: String? = null,
        preservesUnlinkedImport: Boolean? = null,
    ): Track {
        val metadata = readMetadata(file)
        var artworkFilename: String? = null
        return try {
            artworkFilename = (metadata.artwork ?: fallbackArtwork)?.let {
                writeArtwork(trackID, it)
            }
            Track(
                id = trackID,
                title = metadata.title ?: fallbackTitle,
                artist = metadata.artist ?: fallbackArtist,
                album = metadata.album ?: fallbackAlbum,
                durationMs = metadata.durationMs.takeIf { it > 0 } ?: fallbackDurationMs,
                relativePath = file.name,
                remoteID = remoteID,
                sourceServer = sourceServer,
                syncProfileID = syncProfileID,
                sourceURL = ProviderMediaURLPolicy.persistableSourceURL(sourceURL),
                downloadSourceURL = ProviderMediaURLPolicy.persistableDownloadURL(downloadSourceURL),
                artworkFilename = artworkFilename,
                artworkScanComplete = true,
                sourceSHA256 = sourceSHA256,
                contentSHA256 = contentSHA256,
                preservesUnlinkedImport = preservesUnlinkedImport,
            )
        } catch (error: Throwable) {
            artworkFilename?.let { File(artworkDirectory, it).delete() }
            throw error
        }
    }

    private fun writeArtwork(trackID: String, artwork: ByteArray): String? {
        if (artwork.isEmpty()) return null
        val filename = "$trackID.artwork"
        return runCatching {
            File(artworkDirectory, filename).writeBytes(artwork)
            filename
        }.getOrNull()
    }

    private fun readMetadata(file: File): ImportedMetadata {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val containerDurationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?.coerceAtLeast(0L)
            ImportedMetadata(
                title = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
                artist = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?: retriever.metadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR),
                album = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                durationMs = MediaDurationPolicy.preferredMilliseconds(
                    stored = containerDurationMs,
                    playable = listOf(readPlayableDurationMs(file)),
                ) ?: 0L,
                artwork = retriever.embeddedPicture,
            )
        } catch (_: RuntimeException) {
            ImportedMetadata()
        } finally {
            runCatching { retriever.release() }
        }
    }

    private fun MediaMetadataRetriever.metadata(key: Int): String? =
        extractMetadata(key)?.trim()?.takeIf { it.isNotEmpty() }

    private fun readPlayableDurationMs(file: File): Long? {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.absolutePath)
            (0 until extractor.trackCount).mapNotNull { index ->
                val format = extractor.getTrackFormat(index)
                val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
                if (!mime.startsWith("audio/") && !mime.startsWith("video/")) return@mapNotNull null
                if (!format.containsKey(MediaFormat.KEY_DURATION)) return@mapNotNull null
                format.getLong(MediaFormat.KEY_DURATION)
                    .takeIf { it > 0L }
                    ?.div(1_000L)
            }.minOrNull()
        } catch (_: RuntimeException) {
            null
        } finally {
            runCatching { extractor.release() }
        }
    }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        return runCatching {
            appContext.contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull()
    }

    private fun uniqueMusicFile(preferredFilename: String): File {
        val sanitized = preferredFilename
            .replace('/', '-')
            .replace('\\', '-')
            .trim()
            .ifEmpty { "Audio-${System.currentTimeMillis()}" }
        val extension = sanitized.substringAfterLast('.', "")
        val base = if (extension.isEmpty()) sanitized else sanitized.dropLast(extension.length + 1)
        var candidate = File(musicDirectory, sanitized)
        var counter = 2
        while (candidate.exists()) {
            candidate = File(
                musicDirectory,
                if (extension.isEmpty()) "$base $counter" else "$base $counter.$extension",
            )
            counter += 1
        }
        return candidate
    }

    private fun safeFilename(value: String): String {
        val cleaned = value
            .replace(Regex("""[<>:"/\\|?*\p{Cntrl}]"""), "-")
            .trim()
            .replace(Regex("""\s+"""), " ")
            .take(180)
        return cleaned.ifEmpty { "Track-" + System.currentTimeMillis() }
    }

    private fun usefulFallback(value: String, fallback: String): String {
        val trimmed = value.trim()
        val placeholders = setOf("unknown artist", "server library", "local file")
        return if (trimmed.isEmpty() || trimmed.lowercase() in placeholders) fallback else trimmed
    }

    private data class ImportedMetadata(
        val title: String? = null,
        val artist: String? = null,
        val album: String? = null,
        val durationMs: Long = 0L,
        val artwork: ByteArray? = null,
    )
}

/**
 * Restricts automatic cleanup to names generated randomly by this repository. User-imported
 * filenames are deliberately never inferred to be disposable.
 */
internal object RepositoryFilePolicy {
    private const val DOWNLOAD_PREFIX = "resonance-download-"
    private const val STAGING_PREFIX = ".resonance-staging-"
    private const val STAGING_SUFFIX = ".download"
    private val uuidText = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    private val uuidPattern = Regex("^$uuidText$", RegexOption.IGNORE_CASE)
    private val downloadPattern = Regex(
        "^$DOWNLOAD_PREFIX($uuidText)(?:\\.[a-z0-9]{1,16})?$",
        RegexOption.IGNORE_CASE,
    )
    private val stagingPattern = Regex(
        "^\\$STAGING_PREFIX$uuidText\\$STAGING_SUFFIX$",
        RegexOption.IGNORE_CASE,
    )
    private val artworkPattern = Regex("^$uuidText\\.artwork$", RegexOption.IGNORE_CASE)

    fun newDownloadFilename(preferredFilename: String, randomID: String): String {
        require(uuidPattern.matches(randomID)) { "Download ID must be a UUID" }
        val rawExtension = File(preferredFilename).name.substringAfterLast('.', "")
        val extension = rawExtension
            .filter(Char::isLetterOrDigit)
            .lowercase()
            .take(16)
        return buildString {
            append(DOWNLOAD_PREFIX)
            append(randomID.lowercase())
            if (extension.isNotEmpty()) {
                append('.')
                append(extension)
            }
        }
    }

    fun newStagingFilename(randomID: String): String {
        require(uuidPattern.matches(randomID)) { "Download ID must be a UUID" }
        return "$STAGING_PREFIX${randomID.lowercase()}$STAGING_SUFFIX"
    }

    fun downloadID(filename: String): String? = downloadPattern
        .matchEntire(filename)
        ?.groupValues
        ?.get(1)
        ?.lowercase()

    fun isAppOwnedArtwork(filename: String): Boolean = artworkPattern.matches(filename)

    fun orphanedMusicFilenames(
        candidateFilenames: Iterable<String>,
        referencedFilenames: Set<String>,
        stateIsTrustworthy: Boolean,
    ): Set<String> {
        if (!stateIsTrustworthy) return emptySet()
        return candidateFilenames.filterTo(linkedSetOf()) { filename ->
            filename !in referencedFilenames &&
                (downloadPattern.matches(filename) || stagingPattern.matches(filename))
        }
    }

    fun orphanedArtworkFilenames(
        candidateFilenames: Iterable<String>,
        referencedFilenames: Set<String>,
        stateIsTrustworthy: Boolean,
    ): Set<String> {
        if (!stateIsTrustworthy) return emptySet()
        return candidateFilenames.filterTo(linkedSetOf()) { filename ->
            filename !in referencedFilenames && isAppOwnedArtwork(filename)
        }
    }
}
