package mov.unblocked.resonance.data

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
import java.net.URLConnection
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

class ServerClient(
    serverURL: String,
    private val accessToken: String,
    private val adminToken: String = "",
    private val profileID: String = "default",
    private val json: Json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        explicitNulls = false
    },
) {
    val baseURL: String = normalizeServerURL(serverURL)

    suspend fun fetchCatalog(): RemoteCatalog = withContext(Dispatchers.IO) {
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/songs"),
            token = requireAccessToken(),
            accept = "application/json",
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        json.decodeFromString<RemoteCatalog>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun fetchArtwork(song: RemoteSong): ByteArray? = withContext(Dispatchers.IO) {
        val rawURL = song.artworkURL?.trim()?.takeIf(String::isNotEmpty) ?: return@withContext null
        runCatching {
            val url = resolveRemoteURL(rawURL)
            val connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = true
                useCaches = false
                connectTimeout = CONNECT_TIMEOUT_MS
                readTimeout = DOWNLOAD_TIMEOUT_MS
                if (hasSameOrigin(url, URL("$baseURL/"))) {
                    setRequestProperty("Authorization", "Bearer ${requireAccessToken()}")
                    setRequestProperty("X-Resonance-Profile", profileID)
                }
            }
            try {
                if (connection.responseCode !in 200..299) return@runCatching null
                val contentLength = connection.contentLengthLong
                if (contentLength > MAX_ARTWORK_BYTES) return@runCatching null
                connection.inputStream.use(::readArtworkBytes)
            } finally {
                connection.disconnect()
            }
        }.getOrNull()
    }

    suspend fun download(
        song: RemoteSong,
        repository: LibraryRepository,
        onProgress: (TransferProgress) -> Unit = {},
    ): Track = withContext(Dispatchers.IO) {
        val destination = repository.newDownloadFile(song.filename)
        try {
            downloadToFile(song, destination) { transferred, total ->
                onProgress(
                    TransferProgress(
                        completed = 0,
                        total = 1,
                        currentFilename = song.filename,
                        bytesTransferred = transferred,
                        totalBytes = total,
                    ),
                )
            }
            repository.registerDownloadedFile(
                destination,
                song,
                baseURL,
                profileID,
                fallbackArtwork = fetchArtwork(song),
            )
                .also {
                    onProgress(
                        TransferProgress(
                            completed = 1,
                            total = 1,
                            currentFilename = song.filename,
                            bytesTransferred = destination.length(),
                            totalBytes = song.size.takeIf { size -> size > 0L },
                        ),
                    )
                }
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    suspend fun downloadSelected(
        catalog: RemoteCatalog,
        selectedIDs: Set<String>,
        repository: LibraryRepository,
        existingRemoteIDs: Set<String> = emptySet(),
        onProgress: (TransferProgress) -> Unit = {},
    ): List<Track> = downloadSongs(
        songs = catalog.songs.filter { it.id in selectedIDs },
        repository = repository,
        existingRemoteIDs = existingRemoteIDs,
        onProgress = onProgress,
    )

    suspend fun downloadAll(
        catalog: RemoteCatalog,
        repository: LibraryRepository,
        existingRemoteIDs: Set<String> = emptySet(),
        onProgress: (TransferProgress) -> Unit = {},
    ): List<Track> = downloadSongs(
        songs = catalog.songs,
        repository = repository,
        existingRemoteIDs = existingRemoteIDs,
        onProgress = onProgress,
    )

    suspend fun upload(file: File, title: String? = null): RemoteUpload = withContext(Dispatchers.IO) {
        require(file.isFile) { "Upload file does not exist: ${file.name}" }
        val uploadFilename = ServerUploadNaming.filename(file.name, title)
        val encodedFilename = URLEncoder.encode(uploadFilename, Charsets.UTF_8.name())
            .replace("+", "%20")
        val connection = open(
            url = endpoint("/api/v1/admin/songs?filename=$encodedFilename"),
            method = "PUT",
            token = requireAdminToken(),
        ).apply {
            doOutput = true
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = UPLOAD_TIMEOUT_MS
            setRequestProperty(
                "Content-Type",
                URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream",
            )
            setFixedLengthStreamingMode(file.length())
        }
        try {
            file.inputStream().use { input ->
                connection.outputStream.use { output -> input.copyTo(output, BUFFER_SIZE) }
            }
            val response = connection.response()
            requireStatus(response, setOf(HttpURLConnection.HTTP_CREATED, HttpURLConnection.HTTP_CONFLICT))
            if (response.status == HttpURLConnection.HTTP_CONFLICT) {
                json.decodeFromString<DuplicateRemoteUpload>(response.body.toString(Charsets.UTF_8)).duplicateOf
            } else {
                json.decodeFromString<RemoteUpload>(response.body.toString(Charsets.UTF_8))
            }
        } finally {
            connection.disconnect()
        }
    }

    suspend fun upload(
        files: List<File>,
        onProgress: (TransferProgress) -> Unit = {},
    ): List<RemoteUpload> = withContext(Dispatchers.IO) {
        buildList {
            files.forEachIndexed { index, file ->
                coroutineContext.ensureActive()
                onProgress(TransferProgress(index, files.size, file.name))
                add(upload(file))
                onProgress(
                    TransferProgress(
                        completed = index + 1,
                        total = files.size,
                        currentFilename = file.name,
                        bytesTransferred = file.length(),
                        totalBytes = file.length(),
                    ),
                )
            }
        }
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
        )
        requireStatus(response, setOf(HttpURLConnection.HTTP_OK))
        json.decodeFromString<RemotePlaylistsDocument>(response.body.toString(Charsets.UTF_8))
    }

    suspend fun fetchProfiles(): SyncProfilesResponse = withContext(Dispatchers.IO) {
        val response = request(
            method = "GET",
            url = endpoint("/api/v1/profiles"),
            token = requireAccessToken(),
            accept = "application/json",
            includeProfile = false,
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
    ): List<Track> = withContext(Dispatchers.IO) {
        buildList {
            songs.forEachIndexed { index, song ->
                coroutineContext.ensureActive()
                if (song.id in existingRemoteIDs) {
                    onProgress(TransferProgress(index + 1, songs.size, song.filename))
                    return@forEachIndexed
                }
                val destination = repository.newDownloadFile(song.filename)
                try {
                    downloadToFile(song, destination) { transferred, totalBytes ->
                        onProgress(
                            TransferProgress(
                                completed = index,
                                total = songs.size,
                                currentFilename = song.filename,
                                bytesTransferred = transferred,
                                totalBytes = totalBytes,
                            ),
                        )
                    }
                    add(repository.registerDownloadedFile(
                        destination,
                        song,
                        baseURL,
                        profileID,
                        fallbackArtwork = fetchArtwork(song),
                    ))
                    onProgress(
                        TransferProgress(
                            completed = index + 1,
                            total = songs.size,
                            currentFilename = song.filename,
                            bytesTransferred = destination.length(),
                            totalBytes = song.size.takeIf { it > 0L },
                        ),
                    )
                } catch (error: Throwable) {
                    destination.delete()
                    throw error
                }
            }
        }
    }

    private suspend fun downloadToFile(
        song: RemoteSong,
        destination: File,
        onBytes: (Long, Long?) -> Unit,
    ) = withContext(Dispatchers.IO) {
        val connection = open(
            url = resolveRemoteURL(song.downloadURL),
            method = "GET",
            token = requireAccessToken(),
        ).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = DOWNLOAD_TIMEOUT_MS
        }
        try {
            val status = connection.responseCode
            if (status != HttpURLConnection.HTTP_OK) {
                throw serverException(connection.response())
            }
            val total = connection.contentLengthLong.takeIf { it >= 0L }
                ?: song.size.takeIf { it > 0L }
            val temporary = File(destination.parentFile, "${destination.name}.download")
            temporary.delete()
            try {
                connection.inputStream.use { input ->
                    temporary.outputStream().use { output ->
                        val buffer = ByteArray(BUFFER_SIZE)
                        var transferred = 0L
                        while (true) {
                            coroutineContext.ensureActive()
                            val read = input.read(buffer)
                            if (read < 0) break
                            output.write(buffer, 0, read)
                            transferred += read
                            onBytes(transferred, total)
                        }
                    }
                }
                if (total != null && temporary.length() != total) {
                    throw IOException("Download ended before ${song.filename} was complete")
                }
                if (!temporary.renameTo(destination)) {
                    temporary.copyTo(destination, overwrite = true)
                    temporary.delete()
                }
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
    ): Response {
        val connection = open(url, method, token, includeProfile).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = REQUEST_TIMEOUT_MS
            accept?.let { setRequestProperty("Accept", it) }
            contentType?.let { setRequestProperty("Content-Type", it) }
            if (body != null) {
                doOutput = true
                setFixedLengthStreamingMode(body.size)
            }
        }
        return try {
            if (body != null) connection.outputStream.use { it.write(body) }
            connection.response()
        } finally {
            connection.disconnect()
        }
    }

    private fun open(
        url: URL,
        method: String,
        token: String,
        includeProfile: Boolean = true,
    ): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = true
            useCaches = false
            setRequestProperty("Authorization", "Bearer $token")
            if (includeProfile) setRequestProperty("X-Resonance-Profile", profileID)
        }

    private fun HttpURLConnection.response(): Response {
        val status = responseCode
        val source = if (status in 200..299) inputStream else errorStream
        return Response(status, source?.use { it.readBytes() } ?: ByteArray(0))
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
        runCatching { URL(pathOrURL) }.getOrElse { URL(URL("$baseURL/"), pathOrURL) }

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
            ?: throw IllegalStateException("Enter the access token")

    private fun requireAdminToken(): String =
        adminToken.trim().takeIf { it.isNotEmpty() }
            ?: throw IllegalStateException("Enter the server admin key")

    private fun encodePathSegment(value: String): String =
        URLEncoder.encode(value, Charsets.UTF_8.name()).replace("+", "%20")

    private data class Response(val status: Int, val body: ByteArray)

    @Serializable
    private data class ServerErrorPayload(val error: String = "")

    @Serializable
    private data class CreateProfileRequest(val name: String)

    companion object {
        private const val CONNECT_TIMEOUT_MS = 20_000
        private const val REQUEST_TIMEOUT_MS = 60_000
        private const val DOWNLOAD_TIMEOUT_MS = 120_000
        private const val UPLOAD_TIMEOUT_MS = 600_000
        private const val MAX_ARTWORK_BYTES = 10L * 1_024L * 1_024L
        private const val BUFFER_SIZE = 64 * 1_024

        fun normalizeServerURL(value: String): String {
            val trimmed = value.trim().trimEnd('/')
            val uri = runCatching { URI(trimmed) }.getOrNull()
                ?: throw IllegalArgumentException("Enter a valid server URL")
            require(uri.scheme == "https" || uri.scheme == "http") {
                "Server URL must start with http:// or https://"
            }
            require(!uri.host.isNullOrBlank()) { "Server URL is missing a host" }
            return trimmed
        }
    }
}

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
    val size: Long,
)

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
