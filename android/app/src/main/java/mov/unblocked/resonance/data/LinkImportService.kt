package mov.unblocked.resonance.data

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

enum class LinkImportStage {
    Idle, ResolvingMetadata, SearchingCandidates, AwaitingSelection, InspectingSource,
    Downloading, SavingLocal, Syncing, Complete, Failed, Cancelled,
}

data class LinkImportTrack(
    val title: String,
    val artist: String,
    val album: String? = null,
    val durationSeconds: Int? = null,
    val artworkURL: String? = null,
    val sourceURL: String,
    val trackNumber: Int? = null,
)

data class LinkImportCandidate(
    val videoID: String,
    val title: String,
    val artist: String?,
    val durationSeconds: Int?,
    val thumbnailURL: String?,
    val sourceURL: String,
    val score: Double,
    val importTrack: LinkImportTrack? = null,
    val playlistIndex: Int? = null,
    val fallbackCandidates: List<LinkImportCandidate> = emptyList(),
    val sourceProvider: LinkImportSourceProvider = LinkImportSourceProvider.YouTube,
)

enum class LinkImportSourceProvider { YouTube, SoundCloud }
enum class LinkImportMediaMode(val fileExtension: String) {
    Audio("m4a"), Video("mp4");
}
enum class LinkImportKind {
    Track, SpotifyPlaylist, SoundCloudPlaylist;

    val isPlaylist: Boolean get() = this != Track
}
data class LinkImportSkippedItem(
    val position: Int,
    val title: String,
    val artist: String?,
    val reason: String,
)
data class LinkImportPlaylist(
    val id: String,
    val title: String,
    val author: String,
    val artworkURL: String?,
    val sourceURL: String,
    val skippedItems: List<LinkImportSkippedItem>,
) {
    val unavailableCount: Int get() = skippedItems.size
}
data class LinkImportResolution(
    val track: LinkImportTrack,
    val candidates: List<LinkImportCandidate>,
    val kind: LinkImportKind = LinkImportKind.Track,
    val playlist: LinkImportPlaylist? = null,
    /** True when the explicit choices are bound to the active Reviewed-match policy. */
    val reviewedMatchPolicyBound: Boolean = false,
)
data class LinkImportProgress(val stage: LinkImportStage, val completedBytes: Long = 0, val totalBytes: Long = 0)
data class LinkImportDownload(
    val file: File,
    val metadata: LinkImportTrack,
    val artwork: ByteArray?,
    val durationMs: Long,
    val downloadSourceURL: String?,
    val sourceSHA256: String,
    val contentSHA256: String,
    val mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
)
data class LinkImportPreview(val url: String, val headers: Map<String, String>)

class LinkImportException(
    val stage: LinkImportStage,
    val code: String,
    override val message: String,
) : Exception(message)

internal object LinkImportSearchRequestPolicy {
    const val USER_AGENT =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"
}

internal object PreparedMediaReusePolicy {
    const val MaximumAgeNanos = 90L * 1_000_000_000
    const val MaximumEntries = 24

    fun key(videoID: String, mediaMode: LinkImportMediaMode): String =
        "${mediaMode.name.lowercase()}:$videoID"

    fun isFresh(preparedAtNanos: Long, nowNanos: Long): Boolean =
        nowNanos >= preparedAtNanos && nowNanos - preparedAtNanos <= MaximumAgeNanos
}

class LinkImportService(context: Context) {
    private data class SpotifyPlaylistResolution(
        val info: LinkImportPlaylist,
        val tracks: List<LinkImportTrack>,
    )
    private data class ResolvedStream(
        val url: URL,
        val contentLength: Long,
        val contentType: String,
        val itag: Int?,
        val headers: Map<String, String>,
    )
    private data class ResolvedMedia(
        val mediaMode: LinkImportMediaMode,
        val candidate: LinkImportCandidate,
        val primary: ResolvedStream,
        val companionAudio: ResolvedStream? = null,
    )
    private data class ProviderConnection(
        val finalURL: URL,
        val connection: HttpURLConnection,
    )
    private data class PreparedMedia(
        val media: ResolvedMedia,
        val preparedAtNanos: Long,
    )
    private data class PreparedSoundCloudAudio(
        val audio: SoundCloudAudio,
        val preparedAtNanos: Long,
    )
    private data class YouTubePlayerClient(
        val context: JsonObject,
        val clientNumber: String,
        val clientVersion: String,
        val userAgent: String,
    ) {
        val streamHeaders: Map<String, String>
            get() = mapOf("User-Agent" to userAgent, "Origin" to "https://www.youtube.com")
    }

    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }
    private val spotifyHosts = setOf("open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link")
    private val youtubeHosts = setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com")
    private val youtubeProviderHosts = youtubeHosts + setOf("youtu.be", "www.youtu.be")
    private val maxAudioBytes = 256L * 1_024 * 1_024
    private val maxVideoBytes = 1_024L * 1_024 * 1_024
    private val webAgent = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/140 Mobile Safari/537.36"
    private val playerAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L) gzip"
    private val visionPlayerAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
    private val preparedMedia = linkedMapOf<String, PreparedMedia>()
    private val preparedSoundCloudAudio = linkedMapOf<String, PreparedSoundCloudAudio>()
    private val preparedMediaLock = Any()

    suspend fun resolveMetadata(source: String): LinkImportTrack = withContext(Dispatchers.IO) {
        val input = source.trim()
        if (SoundCloudImportUrls.source(input) != null) {
            return@withContext when (val resolved = SoundCloudImport.resolve(input)) {
                is SoundCloudSource.Track -> resolved.value.metadata
                is SoundCloudSource.Playlist -> throw LinkImportException(
                    LinkImportStage.ResolvingMetadata,
                    "PLAYLIST_METADATA_UNSUPPORTED",
                    "A saved server song must identify one track, not a playlist.",
                )
            }
        }

        val spotify = spotifyURL(input)
        if (spotify != null) {
            val parts = spotify.path.split('/').filter(String::isNotBlank).let {
                if (it.firstOrNull()?.startsWith("intl-") == true) it.drop(1) else it
            }
            if (parts.firstOrNull() == "playlist") throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "PLAYLIST_METADATA_UNSUPPORTED",
                "A saved server song must identify one track, not a playlist.",
            )
            return@withContext resolveSpotify(spotify)
        }

        val videoID = youtubeID(input) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "UNSUPPORTED_SOURCE",
            "Enter a Spotify, SoundCloud, or supported YouTube track URL.",
        )
        resolveYouTubeMetadata(videoID)
    }

    suspend fun resolve(
        source: String,
        mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportResolution = resolveInternal(
        source = source,
        mediaMode = mediaMode,
        knownTrackMetadata = null,
        progress = progress,
    )

    /**
     * Resolves a saved server source for download without fetching track metadata a second time.
     * Provider stream inspection/search can still be required because those URLs are short-lived.
     */
    suspend fun resolveForDownload(
        source: String,
        mediaMode: LinkImportMediaMode,
        knownTrackMetadata: LinkImportTrack?,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportResolution = resolveInternal(source, mediaMode, knownTrackMetadata, progress)

    private suspend fun resolveInternal(
        source: String,
        mediaMode: LinkImportMediaMode,
        knownTrackMetadata: LinkImportTrack?,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportResolution =
        withContext(Dispatchers.IO) {
            if (SoundCloudImportUrls.source(source.trim()) != null) {
                if (mediaMode == LinkImportMediaMode.Video) throw LinkImportException(
                    LinkImportStage.ResolvingMetadata,
                    "VIDEO_REQUIRES_YOUTUBE",
                    "Video downloads require a YouTube link or video search result. SoundCloud links provide audio only.",
                )
                // Resolve the playable rendition first. This single operation provides the
                // short-lived audio URL and enough fallback tags, so catalog metadata hydration
                // can continue independently instead of sitting in front of the media transfer.
                progress(LinkImportProgress(LinkImportStage.InspectingSource))
                val audio = try {
                    SoundCloudImport.resolveAudio(source.trim())
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
                if (audio != null) {
                    rememberPreparedSoundCloudAudio(audio)
                    val metadata = knownTrackMetadata ?: audio.track
                    val candidate = LinkImportCandidate(
                        videoID = "soundcloud:saved",
                        title = metadata.title,
                        artist = metadata.artist,
                        durationSeconds = metadata.durationSeconds,
                        thumbnailURL = metadata.artworkURL,
                        sourceURL = audio.track.sourceURL,
                        score = 1.0,
                        sourceProvider = LinkImportSourceProvider.SoundCloud,
                    )
                    return@withContext LinkImportResolution(metadata, listOf(candidate))
                }
                progress(LinkImportProgress(LinkImportStage.ResolvingMetadata))
                when (val resolved = SoundCloudImport.resolve(source.trim())) {
                    is SoundCloudSource.Track -> {
                        val soundCloudTrack = resolved.value
                        progress(LinkImportProgress(LinkImportStage.SearchingCandidates))
                        var candidates = listOfNotNull(soundCloudTrack.directCandidate())
                        if (candidates.isEmpty()) {
                            candidates = runCatching { searchYouTube(soundCloudTrack.metadata) }.getOrElse { emptyList() }
                        }
                        if (candidates.isEmpty()) throw LinkImportException(
                            LinkImportStage.SearchingCandidates,
                            "SOUNDCLOUD_STREAM_UNAVAILABLE",
                            "This SoundCloud track has no direct public audio rendition and no matching alternate source was found.",
                        )
                        return@withContext LinkImportResolution(
                            knownTrackMetadata ?: soundCloudTrack.metadata,
                            candidates,
                        )
                    }

                    is SoundCloudSource.Playlist -> {
                        val soundCloudPlaylist = resolved.value
                        progress(LinkImportProgress(LinkImportStage.SearchingCandidates))
                        val matched = mutableListOf<LinkImportCandidate>()
                        val skipped = mutableListOf<LinkImportSkippedItem>()
                        var searchedTrackCount = 0
                        soundCloudPlaylist.tracks.forEachIndexed { index, soundCloudTrack ->
                            currentCoroutineContext().ensureActive()
                            val position = soundCloudTrack.metadata.trackNumber ?: index + 1
                            val direct = soundCloudTrack.directCandidate(position)
                            if (direct != null) {
                                matched += direct
                            } else {
                                if (searchedTrackCount > 0) delay(250)
                                searchedTrackCount += 1
                                val alternatives = runCatching {
                                    searchYouTube(soundCloudTrack.metadata, maximumMatches = 4, inspectLimit = 10)
                                }.getOrElse { emptyList() }.map {
                                    it.copy(importTrack = soundCloudTrack.metadata, playlistIndex = position)
                                }
                                val primary = alternatives.firstOrNull()
                                if (primary == null) {
                                    skipped += LinkImportSkippedItem(
                                        position,
                                        soundCloudTrack.metadata.title,
                                        soundCloudTrack.metadata.artist,
                                        "No public SoundCloud rendition or close alternate audio match.",
                                    )
                                } else {
                                    matched += primary.copy(fallbackCandidates = alternatives.drop(1))
                                }
                            }
                        }
                        val firstUnavailablePosition = (soundCloudPlaylist.tracks.mapNotNull { it.metadata.trackNumber }.maxOrNull()
                            ?: soundCloudPlaylist.tracks.size) + 1
                        repeat(soundCloudPlaylist.unavailableCount) { offset ->
                            skipped += LinkImportSkippedItem(
                                firstUnavailablePosition + offset,
                                "Unavailable SoundCloud track",
                                null,
                                "SoundCloud did not return public metadata for this playlist item.",
                            )
                        }
                        if (matched.isEmpty()) throw LinkImportException(
                            LinkImportStage.SearchingCandidates,
                            "NO_AUDIO_MATCH",
                            "No public audio source could be imported from this SoundCloud playlist.",
                        )
                        val info = LinkImportPlaylist(
                            id = soundCloudPlaylist.id,
                            title = soundCloudPlaylist.title,
                            author = soundCloudPlaylist.author,
                            artworkURL = soundCloudPlaylist.artworkURL,
                            sourceURL = soundCloudPlaylist.sourceURL,
                            skippedItems = skipped.sortedBy(LinkImportSkippedItem::position),
                        )
                        val summary = LinkImportTrack(
                            title = info.title,
                            artist = info.author,
                            durationSeconds = soundCloudPlaylist.tracks.mapNotNull { it.metadata.durationSeconds }.sum().takeIf { it > 0 },
                            artworkURL = info.artworkURL,
                            sourceURL = info.sourceURL,
                        )
                        return@withContext LinkImportResolution(
                            track = summary,
                            candidates = matched.sortedBy { it.playlistIndex },
                            kind = LinkImportKind.SoundCloudPlaylist,
                            playlist = info,
                        )
                    }
                }
            }
            val spotify = spotifyURL(source.trim())
            if (spotify != null) {
                if (mediaMode == LinkImportMediaMode.Video) throw LinkImportException(
                    LinkImportStage.ResolvingMetadata,
                    "VIDEO_REQUIRES_YOUTUBE",
                    "Video downloads require a YouTube link or video search result. Spotify links provide audio metadata only.",
                )
                progress(LinkImportProgress(LinkImportStage.ResolvingMetadata))
                val parts = spotify.path.split('/').filter(String::isNotBlank).let {
                    if (it.firstOrNull()?.startsWith("intl-") == true) it.drop(1) else it
                }
                if (parts.firstOrNull() == "playlist") {
                    val playlist = resolveSpotifyPlaylist(spotify)
                    progress(LinkImportProgress(LinkImportStage.SearchingCandidates))
                    val matched = mutableListOf<LinkImportCandidate>()
                    val skipped = playlist.info.skippedItems.toMutableList()
                    playlist.tracks.forEachIndexed { index, track ->
                        currentCoroutineContext().ensureActive()
                        if (index > 0) delay(250)
                        var candidates = runCatching {
                            searchYouTube(track, maximumMatches = 4, inspectLimit = 8)
                        }.getOrElse { emptyList() }
                        if (candidates.isEmpty()) {
                            delay(500)
                            candidates = runCatching {
                                searchYouTube(track, maximumMatches = 4, inspectLimit = 10)
                            }.getOrElse { emptyList() }
                        }
                        val position = track.trackNumber ?: index + 1
                        val prepared = candidates.map {
                            it.copy(importTrack = track, playlistIndex = position)
                        }
                        val primary = prepared.firstOrNull()
                        if (primary == null) {
                            skipped += LinkImportSkippedItem(
                                position,
                                track.title,
                                track.artist,
                                "No sufficiently close audio match was found after retrying.",
                            )
                        } else {
                            matched += primary.copy(fallbackCandidates = prepared.drop(1))
                        }
                    }
                    if (matched.isEmpty()) throw LinkImportException(
                        LinkImportStage.SearchingCandidates,
                        "NO_AUDIO_MATCH",
                        "No sufficiently close YouTube audio match was found for the public tracks in this Spotify playlist.",
                    )
                    val info = playlist.info
                    val summary = LinkImportTrack(
                        title = info.title,
                        artist = info.author,
                        durationSeconds = playlist.tracks.mapNotNull { it.durationSeconds }.sum().takeIf { it > 0 },
                        artworkURL = info.artworkURL,
                        sourceURL = info.sourceURL,
                    )
                    return@withContext LinkImportResolution(
                        track = summary,
                        candidates = matched,
                        kind = LinkImportKind.SpotifyPlaylist,
                        playlist = info.copy(skippedItems = skipped.sortedBy(LinkImportSkippedItem::position)),
                    )
                }
                val trackID = parts.takeIf { it.firstOrNull() == "track" }
                    ?.getOrNull(1)
                    ?.takeIf { it.matches(Regex("[A-Za-z0-9]{22}")) }
                val track = knownTrackMetadata?.takeIf { trackID != null } ?: resolveSpotify(spotify)
                progress(LinkImportProgress(LinkImportStage.SearchingCandidates))
                val matches = searchYouTube(track)
                if (matches.isEmpty()) throw LinkImportException(
                    LinkImportStage.SearchingCandidates,
                    "NO_AUDIO_MATCH",
                    "No sufficiently close YouTube audio match was found. Try a YouTube URL instead.",
                )
                return@withContext LinkImportResolution(track, matches)
            }
            val id = youtubeID(source) ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "UNSUPPORTED_SOURCE",
                "Enter a Spotify, SoundCloud, or supported YouTube track or playlist URL.",
            )
            progress(LinkImportProgress(LinkImportStage.InspectingSource))
            val resolved = resolveYouTube(id, mediaMode).also(::rememberPreparedMedia)
            val track = knownTrackMetadata ?: LinkImportTrack(
                resolved.candidate.title,
                resolved.candidate.artist ?: "Unknown uploader",
                durationSeconds = resolved.candidate.durationSeconds,
                artworkURL = resolved.candidate.thumbnailURL,
                sourceURL = resolved.candidate.sourceURL,
            )
            LinkImportResolution(track, listOf(resolved.candidate))
        }

    suspend fun search(
        value: String,
        mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
    ): LinkImportSearchResponse = withContext(Dispatchers.IO) {
        val query = value.replace(Regex("\\s+"), " ").trim()
        if (query.isEmpty()) throw LinkImportException(
            LinkImportStage.SearchingCandidates,
            "MISSING_SEARCH_QUERY",
            "Enter a song, artist, or album to search.",
        )
        if (query.length > 200) throw LinkImportException(
            LinkImportStage.SearchingCandidates,
            "SEARCH_QUERY_TOO_LONG",
            "Keep music searches under 200 characters.",
        )
        if (LinkImportInput.looksLikeLink(value)) throw LinkImportException(
            LinkImportStage.SearchingCandidates,
            "SEARCH_QUERY_IS_LINK",
            "Links are inspected directly instead of being sent to music search providers.",
        )

        coroutineScope {
            val spotifyTask = async { providerResultsOrEmpty { searchSpotifyTracks(query) } }
            val soundCloudTask = async { providerResultsOrEmpty { searchSoundCloudTracks(query) } }
            val youtubeTask = async { providerResultsOrEmpty { searchYouTubeResults(query, mediaMode) } }
            val spotifyTracks = spotifyTask.await()
            val soundCloudTracks = soundCloudTask.await()
            val youtubeCandidates = youtubeTask.await()
            currentCoroutineContext().ensureActive()

            val spotify = spotifyTracks.mapNotNull { track ->
                val candidates = scoreCandidates(track, youtubeCandidates).take(3)
                candidates.takeIf(List<LinkImportCandidate>::isNotEmpty)?.let {
                    LinkImportSearchResult(LinkImportSearchProvider.Spotify, track, it)
                }
            }
            val soundCloud = soundCloudTracks.mapNotNull { soundCloudTrack ->
                val directCandidates = if (mediaMode == LinkImportMediaMode.Audio) {
                    listOfNotNull(soundCloudTrack.directCandidate())
                } else {
                    emptyList()
                }
                val candidates = directCandidates +
                    scoreCandidates(soundCloudTrack.metadata, youtubeCandidates).take(3)
                val unique = candidates.distinctBy(LinkImportCandidate::videoID)
                unique.takeIf(List<LinkImportCandidate>::isNotEmpty)?.let {
                    LinkImportSearchResult(LinkImportSearchProvider.SoundCloud, soundCloudTrack.metadata, it)
                }
            }
            val youtube = youtubeCandidates.take(6).map { candidate ->
                val track = LinkImportTrack(
                    title = candidate.title,
                    artist = candidate.artist ?: "Unknown uploader",
                    durationSeconds = candidate.durationSeconds,
                    artworkURL = candidate.thumbnailURL,
                    sourceURL = candidate.sourceURL,
                )
                LinkImportSearchResult(LinkImportSearchProvider.YouTube, track, listOf(candidate.copy(score = 1.0)))
            }
            val results = spotify + soundCloud + youtube
            if (results.isEmpty()) throw LinkImportException(
                LinkImportStage.SearchingCandidates,
                "NO_SEARCH_RESULTS",
                if (mediaMode == LinkImportMediaMode.Video) {
                    "Spotify, SoundCloud, and YouTube returned no downloadable video results for that search."
                } else {
                    "Spotify, SoundCloud, and YouTube returned no previewable results for that search."
                },
            )
            LinkImportSearchResponse(query, results)
        }
    }

    private suspend fun resolveYouTubeMetadata(videoID: String): LinkImportTrack {
        val canonical = "https://www.youtube.com/watch?v=$videoID"
        val metadataURL = URL(
            "https://www.youtube.com/oembed?url=" + URLEncoder.encode(canonical, "UTF-8") + "&format=json",
        )
        val payload = json.parseToJsonElement(
            request(metadataURL, 256 * 1_024, "application/json") { finalURL ->
                finalURL.protocol.equals("https", ignoreCase = true) &&
                    finalURL.host.equals("www.youtube.com", ignoreCase = true) &&
                    finalURL.path == "/oembed"
            },
        ) as? JsonObject ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "YOUTUBE_INVALID_METADATA",
            "YouTube returned invalid video metadata.",
        )
        val title = payload.string("title")?.trim().orEmpty()
        val artist = payload.string("author_name")?.trim().orEmpty()
        if (payload.string("provider_name") != "YouTube" ||
            payload.string("type") != "video" || title.isEmpty() || artist.isEmpty()
        ) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "YOUTUBE_INVALID_METADATA",
            "YouTube returned invalid video metadata.",
        )
        return LinkImportTrack(
            title = title,
            artist = artist,
            artworkURL = payload.string("thumbnail_url")?.takeIf(::isArtwork),
            sourceURL = canonical,
        )
    }

    suspend fun preview(candidate: LinkImportCandidate): LinkImportPreview = withContext(Dispatchers.IO) {
        if (candidate.sourceProvider == LinkImportSourceProvider.SoundCloud) {
            val stream = SoundCloudImport.resolveAudio(candidate.sourceURL)
                .also(::rememberPreparedSoundCloudAudio)
            return@withContext LinkImportPreview(
                url = stream.url.toString(),
                headers = mapOf(
                    "Accept" to "audio/mpeg,*/*;q=0.5",
                    "Accept-Encoding" to "identity",
                    "User-Agent" to webAgent,
                ),
            )
        }
        val resolved = resolveYouTube(candidate.videoID, LinkImportMediaMode.Audio)
            .also(::rememberPreparedMedia)
        LinkImportPreview(
            url = resolved.primary.url.toString(),
            headers = resolved.primary.headers,
        )
    }

    suspend fun download(
        candidate: LinkImportCandidate,
        metadata: LinkImportTrack,
        mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
        includeArtwork: Boolean = true,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportDownload = withContext(Dispatchers.IO) {
        if (candidate.sourceProvider == LinkImportSourceProvider.SoundCloud) {
            if (mediaMode == LinkImportMediaMode.Video) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "VIDEO_REQUIRES_YOUTUBE",
                "This SoundCloud result is audio only. Choose a YouTube result for video.",
            )
            val resolved = takePreparedSoundCloudAudio(candidate.sourceURL)
                ?: SoundCloudImport.resolveAudio(candidate.sourceURL)
            val directory = File(appContext.cacheDir, "resonance-link-import-" + System.nanoTime()).apply { mkdirs() }
            val output = File(directory, "source.mp3")
            try {
                val hash = SoundCloudImport.download(resolved, output, progress)
                val artwork = if (includeArtwork) {
                    fetchArtwork(metadata.artworkURL ?: resolved.track.artworkURL)
                } else null
                return@withContext LinkImportDownload(
                    output,
                    metadata.copy(
                        title = metadata.title.ifBlank { resolved.track.title },
                        artist = metadata.artist.ifBlank { resolved.track.artist },
                        album = metadata.album ?: resolved.track.album ?: "SoundCloud",
                        artworkURL = metadata.artworkURL ?: resolved.track.artworkURL,
                    ),
                    artwork,
                    ((metadata.durationSeconds ?: resolved.track.durationSeconds) ?: 0).coerceAtLeast(0) * 1_000L,
                    resolved.url.toString(),
                    hash,
                    hash,
                    LinkImportMediaMode.Audio,
                )
            } catch (error: Throwable) {
                directory.deleteRecursively()
                throw error
            }
        }
        val resolved = takePreparedMedia(candidate, mediaMode)
            ?: resolveYouTube(candidate.videoID, mediaMode)
        val directory = File(appContext.cacheDir, "resonance-link-import-" + System.nanoTime()).apply { mkdirs() }
        val primaryFile = File(directory, "primary.${mediaMode.fileExtension}")
        val companionFile = resolved.companionAudio?.let { File(directory, "companion.m4a") }
        val output = File(directory, "source.${mediaMode.fileExtension}")
        try {
            val totalBytes = resolved.primary.contentLength + (resolved.companionAudio?.contentLength ?: 0L)
            val progressByStream = LongArray(2)
            val progressLock = Any()
            val progressThrottle = TransferProgressThrottle()
            fun reportProgress(streamIndex: Int, completedBytes: Long) {
                val aggregate = synchronized(progressLock) {
                    progressByStream[streamIndex] = completedBytes
                    progressByStream.sum().takeIf {
                        progressThrottle.shouldEmit(it, totalBytes, System.nanoTime())
                    }
                }
                if (aggregate != null) {
                    progress(LinkImportProgress(LinkImportStage.Downloading, aggregate, totalBytes))
                }
            }
            val (primaryHash, companionHash) = if (resolved.companionAudio != null && companionFile != null) {
                coroutineScope {
                    val primary = async {
                        downloadRanges(resolved.primary, primaryFile) { reportProgress(0, it) }
                    }
                    val companion = async {
                        downloadRanges(resolved.companionAudio, companionFile) { reportProgress(1, it) }
                    }
                    primary.await() to companion.await()
                }
            } else {
                downloadRanges(resolved.primary, primaryFile) { reportProgress(0, it) } to null
            }
            if (companionFile != null) {
                muxVideoAndAudio(primaryFile, companionFile, output)
            } else if (!primaryFile.renameTo(output)) {
                primaryFile.copyTo(output)
                primaryFile.delete()
            }
            validateDownloadedMedia(output, mediaMode)
            val sourceHash = if (companionHash == null) primaryHash else combinedHash(primaryHash, companionHash)
            val contentHash = if (companionHash == null) sourceHash else sha256(output)
            val artwork = if (includeArtwork) {
                fetchArtwork(metadata.artworkURL ?: resolved.candidate.thumbnailURL)
            } else null
            LinkImportDownload(
                output,
                metadata.copy(
                    title = metadata.title.ifBlank { resolved.candidate.title },
                    artist = metadata.artist.ifBlank { resolved.candidate.artist ?: "Unknown uploader" },
                ),
                artwork,
                ((metadata.durationSeconds ?: resolved.candidate.durationSeconds) ?: 0).coerceAtLeast(0) * 1_000L,
                resolved.companionAudio?.let { null } ?: resolved.primary.url.toString(),
                sourceHash,
                contentHash,
                mediaMode,
            )
        } catch (error: Throwable) {
            directory.deleteRecursively()
            throw error
        }
    }

    private suspend fun resolveSpotify(source: URL): LinkImportTrack {
        val parts = source.path.split('/').filter(String::isNotBlank)
        val trackIndex = parts.indexOf("track")
        val id = trackIndex.takeIf { it >= 0 }?.let { parts.getOrNull(it + 1) }
            ?.takeIf { it.matches(Regex("[A-Za-z0-9]{22}")) }
            ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "UNSUPPORTED_SPOTIFY_RESOURCE",
                "Only Spotify track and playlist links are supported.",
            )
        val canonical = "https://open.spotify.com/track/" + id
        val embed = json.parseToJsonElement(
            request(
                URL("https://open.spotify.com/oembed?url=" + URLEncoder.encode(canonical, "UTF-8")),
                256 * 1_024,
                "application/json",
            ),
        ) as JsonObject
        if (embed.string("provider_name") != "Spotify" || embed.string("type") != "rich") throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INVALID_PREVIEW",
            "Spotify returned an invalid track preview.",
        )
        val html = request(URL("https://open.spotify.com/embed/track/" + id), 6 * 1_024 * 1_024, "text/html")
        val script = Regex(
            """<script[^>]*\bid=[\"']__NEXT_DATA__[\"'][^>]*>([\s\S]*?)</script>""",
            RegexOption.IGNORE_CASE,
        ).find(html)?.groupValues?.getOrNull(1)
        val root = script?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        val entity = root?.obj("props")?.obj("pageProps")?.obj("state")?.obj("data")?.obj("entity")
            ?: throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "SPOTIFY_MISMATCH",
                "Spotify returned mismatched track metadata.",
            )
        if (entity.string("type") != "track" || entity.string("id") != id) throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_MISMATCH",
            "Spotify returned mismatched track metadata.",
        )
        val title = entity.string("title")?.trim()?.takeIf(String::isNotEmpty) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INCOMPLETE_METADATA",
            "Spotify returned incomplete track metadata.",
        )
        val artist = entity.array("artists").mapNotNull { item ->
            (item as? JsonObject)?.string("name")?.trim()?.takeIf(String::isNotEmpty)
        }.joinToString(", ").takeIf(String::isNotEmpty) ?: throw LinkImportException(
            LinkImportStage.ResolvingMetadata,
            "SPOTIFY_INCOMPLETE_METADATA",
            "Spotify returned incomplete track metadata.",
        )
        val artwork = entity.obj("visualIdentity")?.array("image").orEmpty()
            .mapNotNull { it as? JsonObject }
            .sortedByDescending { it.long("maxWidth") }
            .mapNotNull { it.string("url")?.takeIf(::isArtwork) }
            .firstOrNull()
        val durationMs = entity.long("duration")
        return LinkImportTrack(
            title,
            artist,
            durationSeconds = durationMs.takeIf { it > 0 }?.let { (it / 1_000.0).toInt() },
            artworkURL = artwork ?: embed.string("thumbnail_url")?.takeIf(::isArtwork),
            sourceURL = canonical,
        )
    }

    private suspend fun resolveSpotifyPlaylist(source: URL): SpotifyPlaylistResolution {
        val parts = source.path.split('/').filter(String::isNotBlank).let {
            if (it.firstOrNull()?.startsWith("intl-") == true) it.drop(1) else it
        }
        val id = parts.takeIf { it.firstOrNull() == "playlist" }?.getOrNull(1)
            ?.takeIf { it.matches(Regex("[A-Za-z0-9]{22}")) }
            ?: throw LinkImportException(LinkImportStage.ResolvingMetadata, "UNSUPPORTED_SPOTIFY_RESOURCE", "Only Spotify track and playlist links are supported.")
        val canonical = "https://open.spotify.com/playlist/" + id
        val embed = json.parseToJsonElement(request(
            URL("https://open.spotify.com/oembed?url=" + URLEncoder.encode(canonical, "UTF-8")),
            256 * 1_024,
            "application/json",
        )) as? JsonObject ?: throw LinkImportException(LinkImportStage.ResolvingMetadata, "SPOTIFY_INVALID_PREVIEW", "Spotify returned an invalid playlist preview.")
        if (embed.string("provider_name") != "Spotify" || embed.string("type") != "rich") throw LinkImportException(
            LinkImportStage.ResolvingMetadata, "SPOTIFY_INVALID_PREVIEW", "Spotify returned an invalid playlist preview.",
        )
        val html = request(URL("https://open.spotify.com/embed/playlist/" + id), 6 * 1_024 * 1_024, "text/html")
        val script = Regex(
            """<script[^>]*\bid=[\"']__NEXT_DATA__[\"'][^>]*>([\s\S]*?)</script>""",
            RegexOption.IGNORE_CASE,
        ).find(html)?.groupValues?.getOrNull(1)
        val entity = script?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
            ?.obj("props")?.obj("pageProps")?.obj("state")?.obj("data")?.obj("entity")
            ?: throw LinkImportException(LinkImportStage.ResolvingMetadata, "SPOTIFY_MISMATCH", "Spotify returned mismatched playlist metadata.")
        if (entity.string("type") != "playlist" || entity.string("id") != id) throw LinkImportException(
            LinkImportStage.ResolvingMetadata, "SPOTIFY_MISMATCH", "Spotify returned mismatched playlist metadata.",
        )
        val title = (entity.string("title") ?: entity.string("name"))?.trim()?.takeIf(String::isNotEmpty)
            ?: throw LinkImportException(LinkImportStage.ResolvingMetadata, "SPOTIFY_INCOMPLETE_METADATA", "Spotify returned incomplete playlist metadata.")
        val author = entity.string("subtitle")?.trim()?.takeIf(String::isNotEmpty) ?: "Spotify"
        val artwork = entity.obj("coverArt")?.array("sources").orEmpty()
            .mapNotNull { it as? JsonObject }
            .sortedByDescending { it.long("width") }
            .mapNotNull { it.string("url")?.takeIf(::isArtwork) }
            .firstOrNull() ?: embed.string("thumbnail_url")?.takeIf(::isArtwork)
        val skipped = mutableListOf<LinkImportSkippedItem>()
        val tracks = entity.array("trackList").mapIndexedNotNull { index, element ->
            val item = element as? JsonObject
            val uri = item?.string("uri")
            val match = uri?.let { Regex("^spotify:track:([A-Za-z0-9]{22})$").matchEntire(it) }
            val itemTitle = item?.string("title")?.trim()?.takeIf(String::isNotEmpty)
            val artist = item?.string("subtitle")?.trim()?.takeIf(String::isNotEmpty)
            val playable = item?.get("isPlayable")?.jsonPrimitive?.booleanOrNull
            if (item?.string("entityType") != "track" || playable == false || match == null || itemTitle == null || artist == null) {
                skipped += LinkImportSkippedItem(
                    position = index + 1,
                    title = itemTitle ?: "Unknown Spotify item",
                    artist = artist,
                    reason = when {
                        item?.string("entityType") != "track" -> "Not a Spotify song."
                        playable == false -> "Unavailable on Spotify."
                        match == null -> "Missing public track link."
                        itemTitle == null -> "Missing title metadata."
                        else -> "Missing artist metadata."
                    },
                )
                null
            } else {
                val trackID = match.groupValues[1]
                LinkImportTrack(
                    title = itemTitle,
                    artist = artist,
                    durationSeconds = item.long("duration").takeIf { it > 0 }?.let { kotlin.math.round(it / 1_000.0).toInt() },
                    artworkURL = null,
                    sourceURL = "https://open.spotify.com/track/" + trackID,
                    trackNumber = index + 1,
                )
            }
        }
        if (tracks.isEmpty()) throw LinkImportException(
            LinkImportStage.ResolvingMetadata, "SPOTIFY_PLAYLIST_EMPTY", "This Spotify playlist has no public, playable tracks.",
        )
        val hydratedTracks = tracks.map { track ->
            val trackID = track.sourceURL.substringAfterLast('/')
            track.copy(artworkURL = resolveSpotifyPlaylistTrackArtwork(trackID))
        }
        return SpotifyPlaylistResolution(
            LinkImportPlaylist(id, title, author, artwork, canonical, skipped),
            hydratedTracks,
        )
    }

    private suspend fun resolveSpotifyPlaylistTrackArtwork(trackID: String): String? = try {
        val canonical = "https://open.spotify.com/track/" + trackID
        val payload = json.parseToJsonElement(request(
            URL("https://open.spotify.com/oembed?url=" + URLEncoder.encode(canonical, "UTF-8")),
            256 * 1_024,
            "application/json",
        )) as? JsonObject
        if (payload?.string("provider_name") != "Spotify" || payload.string("type") != "rich") null
        else payload.string("thumbnail_url")?.takeIf(::isArtwork)
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        null
    }

    private suspend fun searchYouTube(
        track: LinkImportTrack,
        maximumMatches: Int = 8,
        inspectLimit: Int = 10,
    ): List<LinkImportCandidate> {
        val query = URLEncoder.encode(track.artist + " " + track.title + " official audio", "UTF-8")
        val documents = listOf(
            URL("https://music.youtube.com/search?q=" + query),
            URL("https://www.youtube.com/results?search_query=" + query),
        ).mapNotNull { url -> runCatching { request(url, 6 * 1_024 * 1_024, "text/html") }.getOrNull() }
        val ids = documents.asSequence().flatMap { html ->
            Regex("""\"videoId\"\s*:\s*\"([A-Za-z0-9_-]{11})\"""")
                .findAll(html).map { it.groupValues[1] }
        }.distinct().take(inspectLimit).toList()
        val candidates = buildList {
            for (id in ids) {
                currentCoroutineContext().ensureActive()
                runCatching { resolveYouTube(id).also(::rememberPreparedMedia).candidate }
                    .getOrNull()
                    ?.let(::add)
            }
        }
        return scoreCandidates(track, candidates).take(maximumMatches)
    }

    private fun scoreCandidates(
        track: LinkImportTrack,
        candidates: List<LinkImportCandidate>,
    ): List<LinkImportCandidate> = candidates.map { candidate ->
            val titleScore = overlap(normalize(track.title), normalize(candidate.title))
            val artistScore = maxOf(
                overlap(normalize(track.artist), normalize(candidate.title)),
                overlap(normalize(track.artist), normalize(candidate.artist.orEmpty())),
            )
            val durationScore = if (track.durationSeconds == null || candidate.durationSeconds == null) .5 else {
                (1.0 - kotlin.math.abs(track.durationSeconds - candidate.durationSeconds) / 30.0).coerceIn(0.0, 1.0)
            }
            candidate.copy(score = titleScore * .62 + artistScore * .28 + durationScore * .1)
        }.filter { it.score >= .42 }.sortedByDescending(LinkImportCandidate::score)

    private suspend fun searchSpotifyTracks(query: String): List<LinkImportTrack> {
        val source = URL(
            "https://debridvault.elfhosted.com/api/search?q=" + URLEncoder.encode(query, "UTF-8") + "&provider=spotify",
        )
        val payload = searchRequest(
            source,
            2 * 1_024 * 1_024,
            "application/json",
            setOf("debridvault.elfhosted.com"),
        ).decodeToString()
        return LinkImportSearchParser.spotifyTracks(payload, json)
            .sortedByDescending { searchRelevance(query, it.title, it.artist) }
            .take(6)
    }

    private suspend fun searchSoundCloudTracks(query: String): List<SoundCloudTrack> {
        val page = URL("https://soundcloud.com/search/sounds?q=" + URLEncoder.encode(query, "UTF-8"))
        val html = searchRequest(
            page,
            8 * 1_024 * 1_024,
            "text/html,application/xhtml+xml",
            setOf("soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"),
        ).decodeToString()
        val hydration = SoundCloudImportParser.hydration(html, json)
        val clientID = SoundCloudImportParser.clientID(hydration) ?: throw LinkImportException(
            LinkImportStage.SearchingCandidates,
            "SOUNDCLOUD_SEARCH_UNAVAILABLE",
            "SoundCloud did not provide an anonymous search session.",
        )
        val api = URL(
            "https://api-v2.soundcloud.com/search/tracks?q=" + URLEncoder.encode(query, "UTF-8") +
                "&client_id=" + URLEncoder.encode(clientID, "UTF-8") +
                "&limit=20&offset=0&linked_partitioning=1",
        )
        val payload = json.parseToJsonElement(
            searchRequest(api, 8 * 1_024 * 1_024, "application/json", setOf("api-v2.soundcloud.com")).decodeToString(),
        ) as? JsonObject ?: return emptyList()
        return (payload["collection"] as? JsonArray).orEmpty()
            .mapNotNull { SoundCloudImportParser.track(it) }
            .sortedByDescending { searchRelevance(query, it.metadata.title, it.metadata.artist) }
            .take(6)
    }

    private suspend fun searchYouTubeResults(
        query: String,
        mediaMode: LinkImportMediaMode,
    ): List<LinkImportCandidate> = coroutineScope {
        val encoded = URLEncoder.encode(query, "UTF-8")
        val sources = listOf(
            URL("https://music.youtube.com/search?q=$encoded"),
            URL("https://www.youtube.com/results?search_query=$encoded&sp=EgIQAQ%3D%3D"),
        )
        val documents = sources.map { source ->
            async {
                try {
                    searchRequest(
                        source,
                        8 * 1_024 * 1_024,
                        "text/html,application/xhtml+xml",
                        setOf("music.youtube.com", "www.youtube.com", "m.youtube.com", "youtube.com"),
                    ).decodeToString()
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
            }
        }.awaitAll().filterNotNull()
        val ids = documents.asSequence().flatMap { html ->
            Regex("""\"videoId\"\s*:\s*\"([A-Za-z0-9_-]{11})\"""")
                .findAll(html).map { it.groupValues[1] }
        }.distinct().take(6).toList()
        ids.map { id ->
            async {
                try {
                    resolveYouTube(id, mediaMode).also(::rememberPreparedMedia).candidate
                } catch (error: CancellationException) {
                    throw error
                } catch (_: Exception) {
                    null
                }
            }
        }.awaitAll().filterNotNull()
            .sortedByDescending { searchRelevance(query, it.title, it.artist.orEmpty()) }
            .take(6)
    }

    private suspend fun <T> providerResultsOrEmpty(block: suspend () -> List<T>): List<T> = try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Exception) {
        emptyList()
    }

    private fun searchRelevance(query: String, title: String, artist: String): Double {
        val expected = normalize(query)
        val actual = normalize("$title $artist")
        if (expected.isEmpty() || actual.isEmpty()) return 0.0
        if (expected == actual) return 3.0
        return overlap(expected, actual) + if (actual.contains(expected)) 1.0 else 0.0
    }

    private suspend fun searchRequest(
        url: URL,
        limit: Int,
        accept: String,
        allowedHosts: Set<String>,
    ): ByteArray {
        val response = openProviderConnection(
            initialURL = url,
            method = "GET",
            headers = mapOf(
                "Accept" to accept,
                "Accept-Language" to "en-US,en;q=0.8",
                "User-Agent" to LinkImportSearchRequestPolicy.USER_AGENT,
            ),
            stage = LinkImportStage.SearchingCandidates,
            approvedURL = { candidate ->
                RemoteURLPolicy.isSafeURL(candidate, approvedHost = { host -> host in allowedHosts })
            },
        )
        val connection = response.connection
        try {
            val status = connection.responseCode
            if (status !in 200..299) {
                throw LinkImportException(
                    LinkImportStage.SearchingCandidates,
                    "SEARCH_PROVIDER_FAILED",
                    "A music search provider returned an invalid response.",
                )
            }
            if (connection.contentLengthLong > limit) throw LinkImportException(
                LinkImportStage.SearchingCandidates,
                "SEARCH_RESPONSE_TOO_LARGE",
                "A provider search response was too large.",
            )
            return connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1_024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw LinkImportException(
                        LinkImportStage.SearchingCandidates,
                        "SEARCH_RESPONSE_TOO_LARGE",
                        "A provider search response was too large.",
                    )
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun resolveYouTube(
        videoID: String,
        mediaMode: LinkImportMediaMode = LinkImportMediaMode.Audio,
    ): ResolvedMedia {
        val clients = listOf(
            YouTubePlayerClient(
                context = buildJsonObject {
                    put("clientName", "VISIONOS")
                    put("clientVersion", "1.02")
                    put("deviceMake", "Apple")
                    put("deviceModel", "RealityDevice17,1")
                    put("osName", "visionOS")
                    put("osVersion", "26.5.23O471")
                    put("hl", "en")
                    put("timeZone", "UTC")
                    put("utcOffsetMinutes", 0)
                    put("userAgent", visionPlayerAgent)
                },
                clientNumber = "101",
                clientVersion = "1.02",
                userAgent = visionPlayerAgent,
            ),
            YouTubePlayerClient(
                context = buildJsonObject {
                    put("clientName", "ANDROID_VR")
                    put("clientVersion", "1.65.10")
                    put("deviceMake", "Oculus")
                    put("deviceModel", "Quest 3")
                    put("androidSdkVersion", 32)
                    put("osName", "Android")
                    put("osVersion", "12L")
                    put("hl", "en")
                    put("timeZone", "UTC")
                    put("utcOffsetMinutes", 0)
                    put("userAgent", playerAgent)
                },
                clientNumber = "28",
                clientVersion = "1.65.10",
                userAgent = playerAgent,
            ),
        )
        var verificationError: LinkImportException? = null
        var lastError: LinkImportException? = null
        for (client in clients) {
            try {
                val resolved = resolveYouTubeWithClient(videoID, mediaMode, client)
                verifyYouTubeMedia(resolved)
                return resolved
            } catch (error: LinkImportException) {
                if (error.code == "YOUTUBE_PLAYBACK_VERIFICATION_REQUIRED") verificationError = error
                else lastError = error
            }
        }
        throw verificationError ?: lastError ?: LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_UNAVAILABLE",
            "YouTube could not provide anonymous playback for this video.",
        )
    }

    private suspend fun resolveYouTubeWithClient(
        videoID: String,
        mediaMode: LinkImportMediaMode,
        client: YouTubePlayerClient,
    ): ResolvedMedia {
        val watch = request(
            URL("https://www.youtube.com/watch?v=" + videoID + "&bpctr=9999999999&has_verified=1"),
            6 * 1_024 * 1_024,
            "text/html",
        )
        val visitor = capture(watch, Regex("""\"(?:VISITOR_DATA|visitorData)\"\s*:\s*\"((?:\\.|[^\"\\]){1,1000})\""""))
            ?.let { encoded ->
                runCatching { json.parseToJsonElement("\"$encoded\"").jsonPrimitive.content }.getOrNull()
            }
        val body = buildJsonObject {
            put("videoId", videoID)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            put("context", buildJsonObject {
                put("client", buildJsonObject {
                    client.context.forEach { (key, value) -> put(key, value) }
                    if (!visitor.isNullOrBlank()) put("visitorData", visitor)
                })
            })
            put("playbackContext", buildJsonObject {
                put("contentPlaybackContext", buildJsonObject {
                    put("html5Preference", "HTML5_PREF_WANTS")
                })
            })
        }.toString().toByteArray()
        val headers = mutableMapOf(
            "Content-Type" to "application/json",
            "X-YouTube-Client-Name" to client.clientNumber,
            "X-YouTube-Client-Version" to client.clientVersion,
            "Origin" to "https://www.youtube.com",
            "User-Agent" to client.userAgent,
        )
        if (!visitor.isNullOrBlank()) headers["X-Goog-Visitor-Id"] = visitor
        val player = json.parseToJsonElement(
            requestBytes(
                URL("https://www.youtube.com/youtubei/v1/player?prettyPrint=false"),
                4 * 1_024 * 1_024,
                "application/json",
                "POST",
                body,
                headers,
            ).decodeToString(),
        ) as JsonObject
        if (player.obj("playabilityStatus")?.string("status") != "OK") {
            throw LinkImportException(LinkImportStage.InspectingSource, "YOUTUBE_UNAVAILABLE", "YouTube could not provide anonymous playback for this video.")
        }
        val details = player.obj("videoDetails") ?: JsonObject(emptyMap())
        if (details.bool("isLive") || details.bool("isLiveContent") || details.bool("isUpcoming")) {
            throw LinkImportException(LinkImportStage.InspectingSource, "YOUTUBE_LIVE_UNSUPPORTED", "Live and upcoming YouTube videos are not supported.")
        }
        val streaming = player.obj("streamingData") ?: JsonObject(emptyMap())
        val formats = (streaming.array("adaptiveFormats") + streaming.array("formats"))
            .mapNotNull { it as? JsonObject }
            .filter(::isVerifiedYouTubeFormat)
        val audioFormat = formats
            .filter {
                it.string("mimeType")?.startsWith("audio/mp4", true) == true &&
                    it["qualityLabel"] == null && it.long("contentLength") <= maxAudioBytes
            }
            .maxByOrNull(::formatBitrate)
        val thumbs = details.obj("thumbnail")?.array("thumbnails").orEmpty().mapNotNull { it as? JsonObject }
        val thumbnail = thumbs.maxByOrNull { it.long("width") }?.string("url")?.takeIf(::isArtwork)
        val candidate = LinkImportCandidate(
            videoID,
            details.string("title") ?: videoID,
            details.string("author"),
            details.string("lengthSeconds")?.toIntOrNull() ?: details["lengthSeconds"]?.jsonPrimitive?.intOrNull,
            thumbnail,
            "https://www.youtube.com/watch?v=" + videoID,
            1.0,
        )
        if (mediaMode == LinkImportMediaMode.Audio) {
            val format = audioFormat ?: throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_NO_VERIFIED_M4A",
                "YouTube did not provide a direct, verifiable M4A audio stream for this video.",
            )
            return ResolvedMedia(mediaMode, candidate, verifiedStream(format, maxAudioBytes, "audio", client.streamHeaders))
        }

        val progressive = formats
            .filter {
                it.string("mimeType")?.startsWith("video/mp4", true) == true &&
                    it.string("qualityLabel") != null && formatHasAudio(it) &&
                    it.long("contentLength") <= maxVideoBytes
            }
            .maxWithOrNull(compareBy<JsonObject>({ isH264(it) }, { formatHeight(it) }, { formatBitrate(it) }))
        val adaptive = formats
            .filter {
                    it.string("mimeType")?.startsWith("video/mp4", true) == true &&
                    it.string("qualityLabel") != null && !formatHasAudio(it) &&
                    it.long("contentLength") <= maxVideoBytes - (audioFormat?.long("contentLength") ?: maxVideoBytes)
            }
            .maxWithOrNull(compareBy<JsonObject>({ isH264(it) }, { formatHeight(it) }, { formatBitrate(it) }))
        val useAdaptive = adaptive != null && audioFormat != null &&
            (progressive == null || formatHeight(adaptive) > formatHeight(progressive))
        if (useAdaptive) {
            val video = requireNotNull(adaptive)
            val audio = requireNotNull(audioFormat)
            val primary = verifiedStream(video, maxVideoBytes, "video", client.streamHeaders)
            val companion = verifiedStream(audio, maxAudioBytes, "audio", client.streamHeaders)
            return ResolvedMedia(mediaMode, candidate, primary, companion)
        }
        val format = progressive ?: throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_NO_VERIFIED_MP4",
            "YouTube did not provide a direct, verifiable MP4 video for this result.",
        )
        return ResolvedMedia(mediaMode, candidate, verifiedStream(format, maxVideoBytes, "video", client.streamHeaders))
    }

    private suspend fun verifyYouTubeMedia(media: ResolvedMedia) {
        verifyYouTubeStream(media.primary)
        media.companionAudio?.let { verifyYouTubeStream(it) }
    }

    private suspend fun verifyYouTubeStream(stream: ResolvedStream) {
        val response = openProviderConnection(
            initialURL = stream.url,
            method = "GET",
            headers = stream.headers + mapOf("Range" to "bytes=0-0", "Accept-Encoding" to "identity"),
            stage = LinkImportStage.InspectingSource,
            approvedURL = ::isGoogleVideo,
        )
        val connection = response.connection
        try {
            val status = connection.responseCode
            if (!isGoogleVideo(response.finalURL)) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_UNSAFE_REDIRECT",
                "YouTube returned an unsafe stream redirect.",
            )
            if (status == 403) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_PLAYBACK_VERIFICATION_REQUIRED",
                "YouTube requires playback verification for this stream. Trying another playback client.",
            )
            if (status == 429) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_RATE_LIMITED",
                "YouTube rate-limited the stream probe.",
            )
            val responseType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
            if (status != 206 || connection.contentLengthLong != 1L || responseType != stream.contentType ||
                expectedRangeLength(connection.getHeaderField("Content-Range"), 0, 0, stream.contentLength) != 1L
            ) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_STREAM_UNAVAILABLE",
                "YouTube returned an unverifiable media stream.",
            )
            val body = connection.inputStream.use { input -> input.read() to input.read() }
            if (body.first < 0 || body.second >= 0) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "YOUTUBE_STREAM_UNAVAILABLE",
                "YouTube returned an unverifiable media stream body.",
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun rememberPreparedMedia(media: ResolvedMedia) {
        val now = System.nanoTime()
        synchronized(preparedMediaLock) {
            preparedMedia.entries.removeAll { (_, prepared) ->
                !PreparedMediaReusePolicy.isFresh(prepared.preparedAtNanos, now)
            }
            val key = PreparedMediaReusePolicy.key(media.candidate.videoID, media.mediaMode)
            preparedMedia.remove(key)
            preparedMedia[key] = PreparedMedia(media, now)
            while (preparedMedia.size > PreparedMediaReusePolicy.MaximumEntries) {
                preparedMedia.remove(preparedMedia.keys.first())
            }
        }
    }

    private fun takePreparedMedia(
        candidate: LinkImportCandidate,
        mediaMode: LinkImportMediaMode,
    ): ResolvedMedia? {
        if (candidate.sourceProvider != LinkImportSourceProvider.YouTube) return null
        val now = System.nanoTime()
        return synchronized(preparedMediaLock) {
            preparedMedia.entries.removeAll { (_, prepared) ->
                !PreparedMediaReusePolicy.isFresh(prepared.preparedAtNanos, now)
            }
            val key = PreparedMediaReusePolicy.key(candidate.videoID, mediaMode)
            preparedMedia.remove(key)?.media?.takeIf { prepared ->
                prepared.candidate.sourceURL == candidate.sourceURL
            }
        }
    }

    private fun rememberPreparedSoundCloudAudio(audio: SoundCloudAudio) {
        val key = SoundCloudImportUrls.normalizePermalink(audio.track.sourceURL) ?: return
        val now = System.nanoTime()
        synchronized(preparedMediaLock) {
            preparedSoundCloudAudio.entries.removeAll { (_, prepared) ->
                !PreparedMediaReusePolicy.isFresh(prepared.preparedAtNanos, now)
            }
            preparedSoundCloudAudio.remove(key)
            preparedSoundCloudAudio[key] = PreparedSoundCloudAudio(audio, now)
            while (preparedSoundCloudAudio.size > PreparedMediaReusePolicy.MaximumEntries) {
                preparedSoundCloudAudio.remove(preparedSoundCloudAudio.keys.first())
            }
        }
    }

    private fun takePreparedSoundCloudAudio(sourceURL: String): SoundCloudAudio? {
        val key = SoundCloudImportUrls.normalizePermalink(sourceURL) ?: return null
        val now = System.nanoTime()
        return synchronized(preparedMediaLock) {
            preparedSoundCloudAudio.entries.removeAll { (_, prepared) ->
                !PreparedMediaReusePolicy.isFresh(prepared.preparedAtNanos, now)
            }
            preparedSoundCloudAudio.remove(key)?.audio
        }
    }

    private fun isVerifiedYouTubeFormat(format: JsonObject): Boolean {
        if (format.string("url").isNullOrBlank() || format.long("contentLength") <= 0) return false
        if (format.string("type") == "FORMAT_STREAM_TYPE_OTF") return false
        if (format["drmFamilies"] != null || format.string("drmTrackType") != null) return false
        return runCatching { isGoogleVideo(URL(requireNotNull(format.string("url")))) }.getOrDefault(false)
    }

    private fun formatHasAudio(format: JsonObject): Boolean =
        format.string("audioQuality") != null ||
            format.string("mimeType").orEmpty().substringAfter("codecs=", "").contains("mp4a", true)

    private fun isH264(format: JsonObject): Boolean =
        format.string("mimeType").orEmpty().contains("avc1", true)

    private fun formatHeight(format: JsonObject): Int =
        format.long("height").toInt().takeIf { it > 0 }
            ?: format.string("qualityLabel")?.filter(Char::isDigit)?.toIntOrNull()
            ?: 0

    private fun formatBitrate(format: JsonObject): Long =
        format.long("averageBitrate").takeIf { it > 0 } ?: format.long("bitrate")

    private fun verifiedStream(
        format: JsonObject,
        maximumBytes: Long,
        kind: String,
        headers: Map<String, String>,
    ): ResolvedStream {
        val url = runCatching { URL(requireNotNull(format.string("url"))) }.getOrNull()
            ?: throw LinkImportException(LinkImportStage.InspectingSource, "YOUTUBE_UNSAFE_STREAM", "YouTube returned an invalid $kind stream.")
        if (!isGoogleVideo(url)) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_UNSAFE_STREAM",
            "YouTube returned an untrusted $kind stream.",
        )
        val length = format.long("contentLength")
        if (length !in 1..maximumBytes) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_${kind.uppercase()}_TOO_LARGE",
            "The selected $kind is too large to import on this device.",
        )
        val contentType = format.string("mimeType")?.substringBefore(';')?.trim()?.lowercase()
        if (contentType !in setOf("audio/mp4", "video/mp4")) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_UNSUPPORTED_FORMAT",
            "YouTube returned an unsupported $kind format.",
        )
        return ResolvedStream(
            url,
            length,
            requireNotNull(contentType),
            format.long("itag").toInt().takeIf { it > 0 },
            headers,
        )
    }

    private suspend fun downloadRanges(
        stream: ResolvedStream,
        destination: File,
        progress: (Long) -> Unit,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        var completed = 0L
        FileOutputStream(destination).use { output ->
            while (completed < stream.contentLength) {
                currentCoroutineContext().ensureActive()
                val end = minOf(stream.contentLength - 1, completed + 10L * 1_024 * 1_024 - 1)
                val response = openProviderConnection(
                    initialURL = stream.url,
                    method = "GET",
                    headers = stream.headers + mapOf(
                        "Range" to "bytes=" + completed + "-" + end,
                        "Accept-Encoding" to "identity",
                    ),
                    stage = LinkImportStage.Downloading,
                    approvedURL = ::isGoogleVideo,
                )
                val connection = response.connection
                try {
                    val status = connection.responseCode
                    if (!isGoogleVideo(response.finalURL) || status !in listOf(200, 206)) {
                        throw LinkImportException(LinkImportStage.Downloading, "YOUTUBE_DOWNLOAD_FAILED", "The YouTube media stream could not be read.")
                    }
                    val contentType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
                    if (contentType != stream.contentType) throw LinkImportException(
                        LinkImportStage.Downloading,
                        "YOUTUBE_CONTENT_TYPE_MISMATCH",
                        "YouTube returned an unexpected media format.",
                    )
                    val expectedBytes = if (status == 206) {
                        expectedRangeLength(
                            connection.getHeaderField("Content-Range"),
                            completed,
                            end,
                            stream.contentLength,
                        )
                    } else {
                        if (completed != 0L || end != stream.contentLength - 1) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_RANGE_MISMATCH",
                            "YouTube ignored a required media range.",
                        )
                        stream.contentLength
                    }
                    connection.inputStream.use { input ->
                        val buffer = ByteArray(64 * 1_024)
                        var received = 0L
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            if (received + count > expectedBytes) throw LinkImportException(
                                LinkImportStage.Downloading,
                                "YOUTUBE_RANGE_OVERFLOW",
                                "YouTube returned more media data than requested.",
                            )
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            received += count
                            progress(completed + received)
                        }
                        if (received != expectedBytes || completed + received > stream.contentLength) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_SIZE_MISMATCH",
                            "YouTube returned an unverifiable media size.",
                        )
                        completed += received
                    }
                } finally {
                    connection.disconnect()
                }
            }
        }
        if (completed != stream.contentLength) throw LinkImportException(
            LinkImportStage.Downloading,
            "YOUTUBE_SIZE_MISMATCH",
            "The downloaded media size could not be verified.",
        )
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun muxVideoAndAudio(video: File, audio: File, output: File) {
        data class MuxTrack(
            val extractor: MediaExtractor,
            val format: MediaFormat,
            var destinationIndex: Int = -1,
            var complete: Boolean = false,
        )

        fun track(file: File, mimePrefix: String): MuxTrack {
            val extractor = MediaExtractor().apply { setDataSource(file.absolutePath) }
            val index = (0 until extractor.trackCount).firstOrNull { position ->
                extractor.getTrackFormat(position).getString(MediaFormat.KEY_MIME)?.startsWith(mimePrefix) == true
            } ?: run {
                extractor.release()
                throw LinkImportException(LinkImportStage.SavingLocal, "VIDEO_TRACK_MISSING", "The downloaded video could not be assembled.")
            }
            return MuxTrack(extractor, extractor.getTrackFormat(index)).also { extractor.selectTrack(index) }
        }

        val videoTrack = track(video, "video/")
        val audioTrack = try {
            track(audio, "audio/")
        } catch (error: Throwable) {
            videoTrack.extractor.release()
            throw error
        }
        val tracks = listOf(videoTrack, audioTrack)
        val muxer = try {
            MediaMuxer(output.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (error: Throwable) {
            tracks.forEach { it.extractor.release() }
            throw error
        }
        var started = false
        try {
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(video.absolutePath)
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull()?.takeIf { it in setOf(90, 180, 270) }?.let(muxer::setOrientationHint)
            } finally {
                retriever.release()
            }
            tracks.forEach { it.destinationIndex = muxer.addTrack(it.format) }
            muxer.start()
            started = true
            val maximumSampleSize = tracks.maxOf { item ->
                runCatching { item.format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) }.getOrDefault(0)
            }.coerceIn(1 * 1_024 * 1_024, 16 * 1_024 * 1_024)
            val buffer = ByteBuffer.allocateDirect(maximumSampleSize)
            val info = MediaCodec.BufferInfo()
            while (tracks.any { !it.complete }) {
                currentCoroutineContext().ensureActive()
                val next = tracks.filterNot(MuxTrack::complete).minByOrNull { item ->
                    item.extractor.sampleTime.takeIf { it >= 0 } ?: Long.MAX_VALUE
                } ?: break
                val time = next.extractor.sampleTime
                if (time < 0) {
                    next.complete = true
                    continue
                }
                buffer.clear()
                val count = next.extractor.readSampleData(buffer, 0)
                if (count < 0) {
                    next.complete = true
                    continue
                }
                info.set(0, count, time, next.extractor.sampleFlags)
                muxer.writeSampleData(next.destinationIndex, buffer, info)
                if (!next.extractor.advance()) next.complete = true
            }
        } catch (error: Throwable) {
            output.delete()
            if (error is CancellationException) throw error
            if (error is LinkImportException) throw error
            throw LinkImportException(LinkImportStage.SavingLocal, "VIDEO_MUX_FAILED", "The downloaded video and audio could not be assembled.")
        } finally {
            if (started) runCatching { muxer.stop() }
            muxer.release()
            tracks.forEach { it.extractor.release() }
        }
    }

    private fun validateDownloadedMedia(file: File, mediaMode: LinkImportMediaMode) {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            val mimeTypes = (0 until extractor.trackCount).mapNotNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
            }
            val valid = when (mediaMode) {
                LinkImportMediaMode.Audio -> mimeTypes.any { it.startsWith("audio/") }
                LinkImportMediaMode.Video -> mimeTypes.any { it.startsWith("video/") } && mimeTypes.any { it.startsWith("audio/") }
            }
            if (!valid) throw LinkImportException(
                LinkImportStage.SavingLocal,
                "IMPORTED_MEDIA_INVALID",
                "The downloaded ${mediaMode.name.lowercase()} was not a playable media file.",
            )
        } finally {
            extractor.release()
        }
    }

    private fun combinedHash(primary: String, companion: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest("$primary\n$companion".toByteArray())
            .joinToString("") { "%02x".format(it) }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1_024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun fetchArtwork(value: String?): ByteArray? {
        val url = value?.takeIf(::isArtwork)?.let(::URL) ?: return null
        return runCatching { requestArtworkBytes(url) }.getOrNull()
    }

    private suspend fun requestArtworkBytes(initialURL: URL): ByteArray = withContext(Dispatchers.IO) {
        var currentURL = initialURL
        repeat(MAX_ARTWORK_REDIRECTS + 1) { redirectCount ->
            currentCoroutineContext().ensureActive()
            val connection = (currentURL.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                useCaches = false
                connectTimeout = ARTWORK_CONNECT_TIMEOUT_MS
                readTimeout = ARTWORK_READ_TIMEOUT_MS
                setRequestProperty("Accept", "image/*")
            }
            try {
                val status = connection.responseCode
                if (status in ARTWORK_REDIRECT_STATUSES) {
                    if (redirectCount == MAX_ARTWORK_REDIRECTS) {
                        throw IOException("Artwork redirected too many times")
                    }
                    val location = connection.getHeaderField("Location")
                        ?.trim()
                        ?.takeIf(String::isNotEmpty)
                        ?: throw IOException("Artwork redirect is missing a location")
                    val redirected = currentURL.toURI().resolve(URI(location)).toURL()
                    if (!isArtwork(redirected.toString())) {
                        throw IOException("Artwork redirect left the approved provider hosts")
                    }
                    currentURL = redirected
                    return@repeat
                }
                if (status !in 200..299) throw IOException("Artwork provider returned HTTP $status")
                if (connection.contentLengthLong > ArtworkPayloadPolicy.MAX_BYTES) {
                    throw IOException("Artwork response is too large")
                }
                val bytes = connection.inputStream.use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(32 * 1_024)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size().toLong() + count > ArtworkPayloadPolicy.MAX_BYTES) {
                            throw IOException("Artwork response is too large")
                        }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                }
                if (!ArtworkPayloadPolicy.hasSafeDecodedBounds(bytes)) {
                    throw IOException("Artwork image dimensions are unsafe")
                }
                return@withContext bytes
            } finally {
                connection.disconnect()
            }
        }
        throw IOException("Artwork redirected too many times")
    }

    private suspend fun spotifyURL(value: String): URL? {
        val source = runCatching { URL(value) }.getOrNull() ?: return null
        if (!RemoteURLPolicy.isSafeURL(source, approvedHost = { it in spotifyHosts })) return null
        if (!source.host.lowercase().contains("spotify.link")) return source
        val response = openProviderConnection(
            initialURL = source,
            method = "HEAD",
            headers = mapOf("Accept" to "text/html", "User-Agent" to webAgent),
            stage = LinkImportStage.ResolvingMetadata,
            approvedURL = { candidate ->
                RemoteURLPolicy.isSafeURL(candidate, approvedHost = { it in spotifyHosts })
            },
        )
        val connection = response.connection
        return try {
            connection.responseCode
            response.finalURL
        } finally {
            connection.disconnect()
        }
    }

    private fun youtubeID(value: String): String? {
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        if (uri.scheme != "https" || uri.userInfo != null) return null
        if (uri.rawQuery.orEmpty().split('&').any { it.substringBefore('=') == "list" }) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "UNSUPPORTED_YOUTUBE_COLLECTION",
            "Only individual YouTube videos are supported.",
        )
        val host = uri.host?.lowercase() ?: return null
        val segments = uri.path.split('/').filter(String::isNotBlank)
        val id = when {
            host == "youtu.be" || host == "www.youtu.be" -> segments.firstOrNull()
            host in youtubeHosts && uri.path == "/watch" -> uri.rawQuery.orEmpty().split('&')
                .firstOrNull { it.substringBefore('=') == "v" }?.substringAfter('=')
            host in youtubeHosts && segments.firstOrNull() in setOf("shorts", "live", "embed") -> segments.getOrNull(1)
            else -> null
        }
        return id?.takeIf { it.matches(Regex("[A-Za-z0-9_-]{11}")) }
    }

    private suspend fun request(
        url: URL,
        limit: Int,
        accept: String,
        validatesFinalURL: ((URL) -> Boolean)? = null,
    ): String = requestBytes(
        url,
        limit,
        accept,
        validatesFinalURL = validatesFinalURL,
    ).decodeToString()

    private suspend fun requestBytes(
        url: URL,
        limit: Int,
        accept: String,
        method: String = "GET",
        body: ByteArray? = null,
        headers: Map<String, String> = emptyMap(),
        validatesFinalURL: ((URL) -> Boolean)? = null,
    ): ByteArray {
        val response = openProviderConnection(
            initialURL = url,
            method = method,
            body = body,
            headers = mapOf("Accept" to accept, "Accept-Language" to "en-US,en;q=0.8", "User-Agent" to webAgent) + headers,
            stage = LinkImportStage.InspectingSource,
            approvedURL = providerURLValidator(url),
        )
        val connection = response.connection
        try {
            val status = connection.responseCode
            if (validatesFinalURL?.invoke(response.finalURL) == false) throw LinkImportException(
                LinkImportStage.ResolvingMetadata,
                "UNSAFE_PROVIDER_REDIRECT",
                "The media provider redirected metadata to an untrusted destination.",
            )
            if (status !in 200..299) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "PROVIDER_HTTP_" + status,
                "The media provider returned HTTP " + status + ".",
            )
            if (connection.contentLengthLong > limit) throw LinkImportException(
                LinkImportStage.InspectingSource,
                "PROVIDER_RESPONSE_TOO_LARGE",
                "A media provider returned an oversized response.",
            )
            return connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(32 * 1_024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw LinkImportException(
                        LinkImportStage.InspectingSource,
                        "PROVIDER_RESPONSE_TOO_LARGE",
                        "A media provider returned an oversized response.",
                    )
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    private suspend fun openProviderConnection(
        initialURL: URL,
        method: String,
        headers: Map<String, String>,
        stage: LinkImportStage,
        approvedURL: (URL) -> Boolean,
        body: ByteArray? = null,
    ): ProviderConnection {
        var currentURL = initialURL
        var currentMethod = method
        var currentBody = body
        var redirects = 0
        while (true) {
            currentCoroutineContext().ensureActive()
            if (!approvedURL(currentURL)) unsafeProviderRedirect(stage)
            val connection = open(currentURL, currentMethod, headers)
            try {
                if (currentBody != null) {
                    connection.doOutput = true
                    connection.outputStream.use { it.write(currentBody) }
                }
                val status = connection.responseCode
                if (status !in PROVIDER_REDIRECT_STATUSES) {
                    return ProviderConnection(currentURL, connection)
                }
                if (redirects++ >= MAX_PROVIDER_REDIRECTS) unsafeProviderRedirect(stage)
                val location = connection.getHeaderField("Location")?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?: unsafeProviderRedirect(stage)
                val nextURL = runCatching {
                    currentURL.toURI().resolve(URI(location)).toURL()
                }.getOrNull()?.takeIf(approvedURL::invoke)
                    ?: unsafeProviderRedirect(stage)
                currentURL = nextURL
                if (status == HttpURLConnection.HTTP_MOVED_PERM ||
                    status == HttpURLConnection.HTTP_MOVED_TEMP ||
                    status == HttpURLConnection.HTTP_SEE_OTHER
                ) {
                    currentMethod = "GET"
                    currentBody = null
                }
            } finally {
                connection.disconnect()
            }
        }
    }

    private fun open(url: URL, method: String, headers: Map<String, String> = emptyMap()): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = false
            connectTimeout = 45_000
            readTimeout = 180_000
            headers.forEach(::setRequestProperty)
        }

    private fun isGoogleVideo(url: URL): Boolean = RemoteURLPolicy.isSafeURL(
        url,
        approvedHost = { host -> host == "googlevideo.com" || host.endsWith(".googlevideo.com") },
    )

    private fun providerURLValidator(initialURL: URL): (URL) -> Boolean {
        val host = initialURL.host.trimEnd('.').lowercase()
        val allowedHosts = when {
            host in youtubeHosts || host == "youtu.be" || host == "www.youtu.be" -> youtubeProviderHosts
            host in spotifyHosts -> spotifyHosts
            host == "debridvault.elfhosted.com" -> setOf(host)
            else -> emptySet()
        }
        return { candidate ->
            RemoteURLPolicy.isSafeURL(candidate, approvedHost = { candidateHost -> candidateHost in allowedHosts })
        }
    }

    private fun unsafeProviderRedirect(stage: LinkImportStage): Nothing = throw LinkImportException(
        stage,
        "UNSAFE_PROVIDER_REDIRECT",
        "The media provider redirected to an untrusted destination.",
    )

    private fun expectedRangeLength(value: String?, start: Long, end: Long, total: Long): Long {
        val match = Regex("""^bytes\s+(\d+)-(\d+)/(\d+)$""", RegexOption.IGNORE_CASE)
            .matchEntire(value?.trim().orEmpty())
        val actualStart = match?.groupValues?.getOrNull(1)?.toLongOrNull()
        val actualEnd = match?.groupValues?.getOrNull(2)?.toLongOrNull()
        val actualTotal = match?.groupValues?.getOrNull(3)?.toLongOrNull()
        if (actualStart != start || actualEnd != end || actualTotal != total) throw LinkImportException(
            LinkImportStage.Downloading,
            "YOUTUBE_RANGE_MISMATCH",
            "YouTube returned an unverifiable audio range.",
        )
        return end - start + 1
    }

    private fun isArtwork(value: String): Boolean = runCatching {
        val url = URL(value)
        RemoteURLPolicy.isSafeURL(url, ::isArtworkHost)
    }.getOrDefault(false)

    private fun isArtworkHost(host: String): Boolean =
        artworkHostSuffixes.any { suffix -> host == suffix || host.endsWith(".$suffix") }

    private companion object {
        const val MAX_PROVIDER_REDIRECTS = 5
        const val MAX_ARTWORK_REDIRECTS = 5
        const val ARTWORK_CONNECT_TIMEOUT_MS = 10_000
        const val ARTWORK_READ_TIMEOUT_MS = 20_000
        val PROVIDER_REDIRECT_STATUSES = setOf(
            HttpURLConnection.HTTP_MOVED_PERM,
            HttpURLConnection.HTTP_MOVED_TEMP,
            HttpURLConnection.HTTP_SEE_OTHER,
            307,
            308,
        )
        val ARTWORK_REDIRECT_STATUSES = setOf(
            HttpURLConnection.HTTP_MOVED_PERM,
            HttpURLConnection.HTTP_MOVED_TEMP,
            HttpURLConnection.HTTP_SEE_OTHER,
            307,
            308,
        )
        val artworkHostSuffixes = setOf(
            "ytimg.com",
            "ggpht.com",
            "scdn.co",
            "spotifycdn.com",
            "sndcdn.com",
        )
    }

    private fun capture(value: String, pattern: Regex): String? =
        pattern.find(value)?.groupValues?.getOrNull(1)?.let { encoded ->
            runCatching { json.decodeFromString<String>("\"" + encoded + "\"") }.getOrDefault(encoded)
        }

    private fun normalize(value: String): String =
        value.lowercase().replace(Regex("""[^\p{L}\p{N}]+"""), " ").trim()

    private fun overlap(expected: String, actual: String): Double {
        val tokens = expected.split(' ').filter { it.length > 1 }.toSet()
        if (tokens.isEmpty()) return 0.0
        val actualTokens = actual.split(' ').toSet()
        return tokens.count(actualTokens::contains).toDouble() / tokens.size
    }

    private fun JsonObject.string(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.long(key: String): Long =
        this[key]?.jsonPrimitive?.longOrNull ?: this[key]?.jsonPrimitive?.contentOrNull?.toLongOrNull() ?: 0L
    private fun JsonObject.bool(key: String): Boolean =
        (this[key] as? JsonPrimitive)?.contentOrNull?.toBooleanStrictOrNull() ?: false
    private fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject
    private fun JsonObject.array(key: String): List<JsonElement> = (this[key] as? JsonArray)?.toList().orEmpty()
}
