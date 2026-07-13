package mov.unblocked.resonance.data

import android.content.Context
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
            val decoded = runCatching {
                if (!stateFile.isFile) StoredLibrary()
                else json.decodeFromString<StoredLibrary>(stateFile.readText())
            }.getOrDefault(StoredLibrary())
            normalize(decoded)
        }
    }

    suspend fun save(library: StoredLibrary) = withContext(Dispatchers.IO) {
        stateMutex.withLock {
            rootDirectory.mkdirs()
            val temporary = File(rootDirectory, "${stateFile.name}.tmp")
            FileOutputStream(temporary).bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(json.encodeToString(normalize(library)))
                writer.flush()
            }
            if (!temporary.renameTo(stateFile)) {
                temporary.copyTo(stateFile, overwrite = true)
                temporary.delete()
            }
        }
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
                trackFromFile(destination, fallbackTitle = destination.nameWithoutExtension)
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

    /**
     * Registers a file already downloaded into this repository's Music directory.
     * The caller owns cleanup if metadata extraction fails.
     */
    suspend fun registerDownloadedFile(
        file: File,
        song: RemoteSong,
        sourceServer: String,
    ): Track = withContext(Dispatchers.IO) {
        require(file.parentFile?.canonicalFile == musicDirectory.canonicalFile) {
            "Downloaded audio must be inside the Resonance Music directory"
        }
        try {
            trackFromFile(
                file = file,
                fallbackTitle = song.title.ifBlank { file.nameWithoutExtension },
                fallbackArtist = usefulFallback(song.artist, "Unknown Artist"),
                fallbackAlbum = usefulFallback(song.album, "Server Library"),
                remoteID = song.id,
                sourceServer = sourceServer,
            )
        } catch (error: Throwable) {
            file.delete()
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

    internal fun newDownloadFile(preferredFilename: String): File =
        uniqueMusicFile(preferredFilename)

    private fun normalize(library: StoredLibrary): StoredLibrary {
        val existingTracks = library.tracks.filter { fileForTrack(it).isFile }
            .distinctBy { it.remoteID ?: it.id }
        val trackIDs = existingTracks.mapTo(linkedSetOf()) { it.id }
        val favorites = library.favorites.intersect(trackIDs)
        val cleanedPlaylists = library.playlists.map { playlist ->
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
        return library.copy(
            tracks = existingTracks,
            playlists = cleanedPlaylists,
            favorites = favorites,
        )
    }

    private fun trackFromFile(
        file: File,
        fallbackTitle: String,
        fallbackArtist: String = "Unknown Artist",
        fallbackAlbum: String = "Imported",
        remoteID: String? = null,
        sourceServer: String? = null,
    ): Track {
        val metadata = readMetadata(file)
        val id = UUID.randomUUID().toString()
        val artworkFilename = metadata.artwork?.let { artwork ->
            val filename = "$id.artwork"
            runCatching {
                File(artworkDirectory, filename).writeBytes(artwork)
                filename
            }.getOrNull()
        }
        return Track(
            id = id,
            title = metadata.title ?: fallbackTitle,
            artist = metadata.artist ?: fallbackArtist,
            album = metadata.album ?: fallbackAlbum,
            durationMs = metadata.durationMs,
            relativePath = file.name,
            remoteID = remoteID,
            sourceServer = sourceServer,
            artworkFilename = artworkFilename,
            artworkScanComplete = true,
        )
    }

    private fun readMetadata(file: File): ImportedMetadata {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            ImportedMetadata(
                title = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
                artist = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?: retriever.metadata(MediaMetadataRetriever.METADATA_KEY_AUTHOR),
                album = retriever.metadata(MediaMetadataRetriever.METADATA_KEY_ALBUM),
                durationMs = retriever
                    .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                    ?.toLongOrNull()
                    ?.coerceAtLeast(0L)
                    ?: 0L,
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
