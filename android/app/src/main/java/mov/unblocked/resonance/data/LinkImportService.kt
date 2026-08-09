package mov.unblocked.resonance.data

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.net.URLEncoder
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
    val downloadSourceURL: String,
    val sourceSHA256: String,
    val contentSHA256: String,
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

class LinkImportService(context: Context) {
    private data class SpotifyPlaylistResolution(
        val info: LinkImportPlaylist,
        val tracks: List<LinkImportTrack>,
    )
    private data class ResolvedAudio(
        val candidate: LinkImportCandidate,
        val streamURL: URL,
        val contentLength: Long,
    )

    private val appContext = context.applicationContext
    private val json = Json { ignoreUnknownKeys = true }
    private val spotifyHosts = setOf("open.spotify.com", "www.open.spotify.com", "spotify.link", "www.spotify.link")
    private val youtubeHosts = setOf("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com")
    private val maxAudioBytes = 256L * 1_024 * 1_024
    private val webAgent = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 Chrome/140 Mobile Safari/537.36"
    private val playerAgent = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L) gzip"

    suspend fun resolve(source: String, progress: (LinkImportProgress) -> Unit): LinkImportResolution =
        withContext(Dispatchers.IO) {
            if (SoundCloudImportUrls.source(source.trim()) != null) {
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
                        return@withContext LinkImportResolution(soundCloudTrack.metadata, candidates)
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
                val track = resolveSpotify(spotify)
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
            val resolved = resolveYouTube(id)
            val track = LinkImportTrack(
                resolved.candidate.title,
                resolved.candidate.artist ?: "Unknown uploader",
                durationSeconds = resolved.candidate.durationSeconds,
                artworkURL = resolved.candidate.thumbnailURL,
                sourceURL = resolved.candidate.sourceURL,
            )
            LinkImportResolution(track, listOf(resolved.candidate))
        }

    suspend fun search(value: String): LinkImportSearchResponse = withContext(Dispatchers.IO) {
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
            val youtubeTask = async { providerResultsOrEmpty { searchYouTubeResults(query) } }
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
                val candidates = listOfNotNull(soundCloudTrack.directCandidate()) +
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
                "Spotify, SoundCloud, and YouTube returned no previewable results for that search.",
            )
            LinkImportSearchResponse(query, results)
        }
    }

    suspend fun preview(candidate: LinkImportCandidate): LinkImportPreview = withContext(Dispatchers.IO) {
        if (candidate.sourceProvider == LinkImportSourceProvider.SoundCloud) {
            val stream = SoundCloudImport.resolveAudio(candidate.sourceURL)
            return@withContext LinkImportPreview(
                url = stream.url.toString(),
                headers = mapOf("User-Agent" to webAgent),
            )
        }
        val resolved = resolveYouTube(candidate.videoID)
        LinkImportPreview(
            url = resolved.streamURL.toString(),
            headers = mapOf(
                "User-Agent" to playerAgent,
                "Origin" to "https://www.youtube.com",
            ),
        )
    }

    suspend fun download(
        candidate: LinkImportCandidate,
        metadata: LinkImportTrack,
        progress: (LinkImportProgress) -> Unit,
    ): LinkImportDownload = withContext(Dispatchers.IO) {
        if (candidate.sourceProvider == LinkImportSourceProvider.SoundCloud) {
            val resolved = SoundCloudImport.resolveAudio(candidate.sourceURL)
            val directory = File(appContext.cacheDir, "resonance-link-import-" + System.nanoTime()).apply { mkdirs() }
            val output = File(directory, "source.mp3")
            try {
                val hash = SoundCloudImport.download(resolved, output, progress)
                val artwork = fetchArtwork(metadata.artworkURL ?: resolved.track.artworkURL)
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
                )
            } catch (error: Throwable) {
                directory.deleteRecursively()
                throw error
            }
        }
        val resolved = resolveYouTube(candidate.videoID)
        val directory = File(appContext.cacheDir, "resonance-link-import-" + System.nanoTime()).apply { mkdirs() }
        val output = File(directory, "source.m4a")
        try {
            val hash = downloadRanges(resolved, output, progress)
            val artwork = fetchArtwork(metadata.artworkURL ?: resolved.candidate.thumbnailURL)
            LinkImportDownload(
                output,
                metadata.copy(
                    title = metadata.title.ifBlank { resolved.candidate.title },
                    artist = metadata.artist.ifBlank { resolved.candidate.artist ?: "Unknown uploader" },
                ),
                artwork,
                ((metadata.durationSeconds ?: resolved.candidate.durationSeconds) ?: 0).coerceAtLeast(0) * 1_000L,
                resolved.streamURL.toString(),
                hash,
                hash,
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
                runCatching { resolveYouTube(id).candidate }.getOrNull()?.let(::add)
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

    private suspend fun searchYouTubeResults(query: String): List<LinkImportCandidate> = coroutineScope {
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
                    resolveYouTube(id).candidate
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
        val connection = open(
            url,
            "GET",
            mapOf(
                "Accept" to accept,
                "Accept-Language" to "en-US,en;q=0.8",
                "User-Agent" to LinkImportSearchRequestPolicy.USER_AGENT,
            ),
        )
        try {
            val status = connection.responseCode
            val final = connection.url
            if (status !in 200..299 || final.protocol != "https" || final.userInfo != null || final.host.lowercase() !in allowedHosts) {
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

    private suspend fun resolveYouTube(videoID: String): ResolvedAudio {
        val watch = request(
            URL("https://www.youtube.com/watch?v=" + videoID + "&bpctr=9999999999&has_verified=1"),
            6 * 1_024 * 1_024,
            "text/html",
        )
        val visitor = capture(watch, Regex("""\"(?:VISITOR_DATA|visitorData)\"\s*:\s*\"((?:\\.|[^\"\\]){1,1000})\""""))
        val body = buildJsonObject {
            put("videoId", videoID)
            put("contentCheckOk", true)
            put("racyCheckOk", true)
            put("context", buildJsonObject {
                put("client", buildJsonObject {
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
                })
            })
        }.toString().toByteArray()
        val headers = mutableMapOf(
            "Content-Type" to "application/json",
            "X-YouTube-Client-Name" to "28",
            "X-YouTube-Client-Version" to "1.65.10",
            "Origin" to "https://www.youtube.com",
            "User-Agent" to playerAgent,
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
            .filter {
                it.string("mimeType")?.startsWith("audio/mp4", true) == true
                    && it.string("url") != null && it.long("contentLength") > 0
                    && it["qualityLabel"] == null
            }
            .sortedByDescending { it.long("averageBitrate").takeIf { value -> value > 0 } ?: it.long("bitrate") }
        val format = formats.firstOrNull() ?: throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_NO_VERIFIED_M4A",
            "YouTube did not provide a direct, verifiable M4A audio stream for this video.",
        )
        val stream = URL(requireNotNull(format.string("url")))
        if (!isGoogleVideo(stream)) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_UNSAFE_STREAM",
            "YouTube returned an untrusted audio stream.",
        )
        val length = format.long("contentLength")
        if (length !in 1..maxAudioBytes) throw LinkImportException(
            LinkImportStage.InspectingSource,
            "YOUTUBE_AUDIO_TOO_LARGE",
            "The selected audio is too large to import on this device.",
        )
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
        return ResolvedAudio(candidate, stream, length)
    }

    private suspend fun downloadRanges(
        resolved: ResolvedAudio,
        destination: File,
        progress: (LinkImportProgress) -> Unit,
    ): String {
        val digest = MessageDigest.getInstance("SHA-256")
        var completed = 0L
        FileOutputStream(destination).use { output ->
            while (completed < resolved.contentLength) {
                currentCoroutineContext().ensureActive()
                val end = minOf(resolved.contentLength - 1, completed + 10L * 1_024 * 1_024 - 1)
                val connection = open(
                    resolved.streamURL,
                    "GET",
                    mapOf(
                        "Range" to "bytes=" + completed + "-" + end,
                        "Accept-Encoding" to "identity",
                        "User-Agent" to playerAgent,
                        "Origin" to "https://www.youtube.com",
                    ),
                )
                try {
                    val status = connection.responseCode
                    if (!isGoogleVideo(connection.url) || status !in listOf(200, 206)) {
                        throw LinkImportException(LinkImportStage.Downloading, "YOUTUBE_DOWNLOAD_FAILED", "The YouTube audio stream could not be read.")
                    }
                    val contentType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
                    if (contentType != "audio/mp4") throw LinkImportException(
                        LinkImportStage.Downloading,
                        "YOUTUBE_CONTENT_TYPE_MISMATCH",
                        "YouTube returned an unexpected audio format.",
                    )
                    val expectedBytes = if (status == 206) {
                        expectedRangeLength(
                            connection.getHeaderField("Content-Range"),
                            completed,
                            end,
                            resolved.contentLength,
                        )
                    } else {
                        if (completed != 0L || end != resolved.contentLength - 1) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_RANGE_MISMATCH",
                            "YouTube ignored a required audio range.",
                        )
                        resolved.contentLength
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
                                "YouTube returned more audio data than requested.",
                            )
                            output.write(buffer, 0, count)
                            digest.update(buffer, 0, count)
                            received += count
                            progress(LinkImportProgress(LinkImportStage.Downloading, completed + received, resolved.contentLength))
                        }
                        if (received != expectedBytes || completed + received > resolved.contentLength) throw LinkImportException(
                            LinkImportStage.Downloading,
                            "YOUTUBE_SIZE_MISMATCH",
                            "YouTube returned an unverifiable audio size.",
                        )
                        completed += received
                    }
                } finally {
                    connection.disconnect()
                }
            }
        }
        if (completed != resolved.contentLength) throw LinkImportException(
            LinkImportStage.Downloading,
            "YOUTUBE_SIZE_MISMATCH",
            "The downloaded audio size could not be verified.",
        )
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun fetchArtwork(value: String?): ByteArray? {
        val url = value?.takeIf(::isArtwork)?.let(::URL) ?: return null
        return runCatching { requestBytes(url, 10 * 1_024 * 1_024, "image/*") }.getOrNull()
    }

    private suspend fun spotifyURL(value: String): URL? {
        val source = runCatching { URL(value) }.getOrNull() ?: return null
        if (source.protocol != "https" || source.host.lowercase() !in spotifyHosts || source.userInfo != null) return null
        if (!source.host.lowercase().contains("spotify.link")) return source
        val connection = open(source, "HEAD")
        return try {
            connection.responseCode
            spotifyURL(connection.url.toString())
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

    private suspend fun request(url: URL, limit: Int, accept: String): String =
        requestBytes(url, limit, accept).decodeToString()

    private suspend fun requestBytes(
        url: URL,
        limit: Int,
        accept: String,
        method: String = "GET",
        body: ByteArray? = null,
        headers: Map<String, String> = emptyMap(),
    ): ByteArray {
        val connection = open(
            url,
            method,
            mapOf("Accept" to accept, "Accept-Language" to "en-US,en;q=0.8", "User-Agent" to webAgent) + headers,
        )
        try {
            if (body != null) {
                connection.doOutput = true
                connection.outputStream.use { it.write(body) }
            }
            val status = connection.responseCode
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

    private fun open(url: URL, method: String, headers: Map<String, String> = emptyMap()): HttpURLConnection =
        (url.openConnection() as HttpURLConnection).apply {
            requestMethod = method
            instanceFollowRedirects = true
            connectTimeout = 45_000
            readTimeout = 180_000
            headers.forEach(::setRequestProperty)
        }

    private fun isGoogleVideo(url: URL): Boolean =
        url.protocol == "https" && (url.host == "googlevideo.com" || url.host.endsWith(".googlevideo.com"))

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
        val host = url.host.lowercase()
        url.protocol == "https" && (
            host == "ytimg.com" || host.endsWith(".ytimg.com")
                || host == "ggpht.com" || host.endsWith(".ggpht.com")
                || host == "scdn.co" || host.endsWith(".scdn.co")
                || host == "spotifycdn.com" || host.endsWith(".spotifycdn.com")
                || host == "sndcdn.com" || host.endsWith(".sndcdn.com")
        )
    }.getOrDefault(false)

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
