package mov.unblocked.resonance.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.BuildConfig
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.ServerNetworkPolicy
import mov.unblocked.resonance.data.Track
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.text.DecimalFormat
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun ResonanceBackground(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = listOf(Navy, DeepNavy),
                ),
            ),
    ) {
        CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onBackground) {
            content()
        }
    }
}

@Composable
fun Artwork(
    path: String?,
    modifier: Modifier = Modifier,
    showWaveform: Boolean = false,
) {
    val bitmap = remember(path) {
        path?.takeIf { it.isNotBlank() }?.let { runCatching { BitmapFactory.decodeFile(it)?.asImageBitmap() }.getOrNull() }
    }
    Box(
        modifier = modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(12.dp))
            .background(Brush.linearGradient(listOf(Violet, Color(0xFF874BFF), Color(0xFFB079FF)))),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap,
                contentDescription = "Album artwork",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Icon(
                imageVector = if (showWaveform) Icons.Default.MusicNote else Icons.Default.MusicNote,
                contentDescription = null,
                tint = Color.White.copy(alpha = .94f),
                modifier = Modifier.size(28.dp),
            )
        }
    }
}

@Composable
fun RemoteArtwork(
    artworkURL: String?,
    serverURL: String,
    modifier: Modifier = Modifier,
) {
    val resolvedURL = remember(artworkURL, serverURL) {
        resolveRemoteArtworkURL(serverURL, artworkURL)
    }
    val bitmap by produceState<Bitmap?>(initialValue = null, key1 = resolvedURL) {
        value = resolvedURL?.let { url ->
            withContext(Dispatchers.IO) { loadRemoteArtwork(serverURL, url) }
        }
    }
    Box(
        modifier = modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(12.dp))
            .background(Brush.linearGradient(listOf(Violet, Color(0xFF874BFF), Color(0xFFB079FF)))),
        contentAlignment = Alignment.Center,
    ) {
        if (bitmap != null) {
            Image(
                bitmap = bitmap!!.asImageBitmap(),
                contentDescription = "Album artwork",
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Icon(
                imageVector = Icons.Default.MusicNote,
                contentDescription = null,
                tint = Color.White.copy(alpha = .94f),
                modifier = Modifier.size(28.dp),
            )
        }
    }
}

internal fun resolveRemoteArtworkURL(
    serverURL: String,
    artworkURL: String?,
    allowCleartextDevelopment: Boolean = BuildConfig.DEBUG,
): String? {
    val trimmed = artworkURL?.trim()?.takeIf(String::isNotEmpty) ?: return null
    val allowCleartext = BuildConfig.DEBUG && allowCleartextDevelopment
    return runCatching {
        ServerNetworkPolicy.resolveArtworkURL(
            baseURL = serverURL,
            pathOrURL = trimmed,
            allowCleartextDevelopment = allowCleartext,
        ).toString()
    }.getOrNull()
}

private fun loadRemoteArtwork(serverURL: String, url: String): Bitmap? =
    loadRemoteArtworkBytes(serverURL, url)?.let { bytes ->
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }

/**
 * Fetches public artwork without credentials. Redirects are deliberately handled here so every
 * hop is checked by [ServerNetworkPolicy] before a connection is opened.
 */
internal fun loadRemoteArtworkBytes(
    serverURL: String,
    url: String,
    allowCleartextDevelopment: Boolean = BuildConfig.DEBUG,
    connectionFactory: (URL) -> HttpURLConnection = { target ->
        target.openConnection() as HttpURLConnection
    },
): ByteArray? = runCatching {
    val allowCleartext = BuildConfig.DEBUG && allowCleartextDevelopment
    var currentURL = ServerNetworkPolicy.requireArtworkURL(
        baseURL = serverURL,
        url = URL(url),
        allowCleartextDevelopment = allowCleartext,
    )

    for (redirectCount in 0..MAX_REMOTE_ARTWORK_REDIRECTS) {
        val connection = connectionFactory(currentURL)
        try {
            connection.requestMethod = "GET"
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.connectTimeout = REMOTE_ARTWORK_CONNECT_TIMEOUT_MS
            connection.readTimeout = REMOTE_ARTWORK_READ_TIMEOUT_MS
            connection.setRequestProperty("Accept", "image/*")

            val responseCode = connection.responseCode
            if (responseCode in REMOTE_ARTWORK_REDIRECT_STATUSES) {
                if (redirectCount == MAX_REMOTE_ARTWORK_REDIRECTS) {
                    throw IOException("The artwork download redirected too many times")
                }
                val location = connection.getHeaderField("Location")
                    ?.trim()
                    ?.takeIf(String::isNotEmpty)
                    ?: throw IOException("The artwork redirect is missing a location")
                currentURL = ServerNetworkPolicy.resolveArtworkRedirect(
                    baseURL = serverURL,
                    currentURL = currentURL,
                    location = location,
                    allowCleartextDevelopment = allowCleartext,
                )
                continue
            }
            if (responseCode !in 200..299) return@runCatching null

            val declaredBytes = connection.contentLengthLong
            if (declaredBytes > MAX_REMOTE_ARTWORK_BYTES) return@runCatching null
            return@runCatching connection.inputStream.use { input ->
                readRemoteArtworkBytes(input, MAX_REMOTE_ARTWORK_BYTES)
            }
        } finally {
            connection.disconnect()
        }
    }
    null
}.getOrNull()

internal fun readRemoteArtworkBytes(
    input: java.io.InputStream,
    maxBytes: Long,
): ByteArray? {
    require(maxBytes > 0L) { "Artwork byte limit must be positive" }
    val output = ByteArrayOutputStream()
    val buffer = ByteArray(REMOTE_ARTWORK_BUFFER_SIZE)
    var totalBytes = 0L
    while (true) {
        val read = input.read(buffer)
        if (read < 0) break
        totalBytes += read
        if (totalBytes > maxBytes) return null
        output.write(buffer, 0, read)
    }
    return output.toByteArray().takeIf(ByteArray::isNotEmpty)
}

internal const val MAX_REMOTE_ARTWORK_BYTES = 10L * 1_024L * 1_024L
private const val MAX_REMOTE_ARTWORK_REDIRECTS = 5
private const val REMOTE_ARTWORK_CONNECT_TIMEOUT_MS = 10_000
private const val REMOTE_ARTWORK_READ_TIMEOUT_MS = 20_000
private const val REMOTE_ARTWORK_BUFFER_SIZE = 32 * 1_024
private val REMOTE_ARTWORK_REDIRECT_STATUSES = setOf(
    HttpURLConnection.HTTP_MOVED_PERM,
    HttpURLConnection.HTTP_MOVED_TEMP,
    HttpURLConnection.HTTP_SEE_OTHER,
    307,
    308,
)

@Composable
fun Eyebrow(text: String, modifier: Modifier = Modifier) {
    Text(
        text = text.uppercase(),
        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 1.6.sp,
        modifier = modifier,
    )
}

@Composable
fun SegmentedControl(
    labels: List<String>,
    selectedIndex: Int,
    onSelected: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = .055f))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        labels.forEachIndexed { index, label ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(40.dp)
                    .clip(RoundedCornerShape(11.dp))
                    .background(if (index == selectedIndex) Accent else Color.Transparent)
                    .clickable { onSelected(index) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = label,
                    color = if (index == selectedIndex) Color.White else MaterialTheme.colorScheme.onSurface.copy(alpha = .62f),
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

@Composable
fun SongListHeader(
    trailingTitle: String = "Time",
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.fillMaxWidth().height(38.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                "#",
                modifier = Modifier.width(24.dp),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f),
            )
            Text(
                "Title",
                modifier = Modifier.weight(1f),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f),
            )
            Text(
                trailingTitle,
                modifier = Modifier.width(44.dp),
                textAlign = TextAlign.End,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f),
            )
        }
        HorizontalDivider(color = Color.White.copy(alpha = .10f))
    }
}

@Composable
fun TrackRow(
    track: Track,
    state: ResonanceUiState,
    actions: ResonanceActions,
    modifier: Modifier = Modifier,
    number: Int? = null,
    queue: List<Track> = state.tracks,
    playlistId: String? = null,
    playlistsForAdding: List<Playlist> = state.playlists.filterNot { it.isSystem },
    trailingText: String = track.durationText,
    showSelection: Boolean = false,
    selected: Boolean = false,
    onSelect: (() -> Unit)? = null,
    allowDeleteFromDevice: Boolean = true,
    onDeleteFromDevice: (() -> Unit)? = null,
    showFavorite: Boolean = true,
    showMenu: Boolean = true,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val displayedNumber = number ?: queue.indexOfFirst { it.id == track.id }.takeIf { it >= 0 }?.plus(1)
    Box(modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 76.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(if (selected) Color.White.copy(alpha = .05f) else Color.Transparent)
                .combinedClickable(
                    onClick = {
                        if (showSelection) onSelect?.invoke()
                        else actions.playTrack(track.id, queue.map { it.id }, playlistId)
                    },
                    onLongClick = if (!showSelection && showMenu) ({ menuOpen = true }) else null,
                )
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.width(24.dp), contentAlignment = Alignment.CenterStart) {
                if (showSelection) {
                    Icon(
                        if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                        contentDescription = if (selected) "Selected" else "Not selected",
                        modifier = Modifier.size(18.dp),
                        tint = if (selected) Accent else MaterialTheme.colorScheme.onSurface.copy(alpha = .42f),
                    )
                } else {
                    Text(
                        displayedNumber?.toString().orEmpty(),
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                    )
                }
            }
            Artwork(
                path = state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
                modifier = Modifier.size(52.dp),
                showWaveform = state.currentTrackId == track.id && state.isPlaying,
            )
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        track.title,
                        modifier = Modifier.weight(1f, fill = false),
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = "Stored on device",
                        modifier = Modifier.size(9.dp),
                        tint = SuccessGreen,
                    )
                }
                Text(
                    "${track.artist} / ${track.mediaKindLabel}",
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    track.album.ifBlank { "Unknown Album" },
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .43f),
                    fontSize = 11.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                trailingText,
                modifier = Modifier.width(44.dp),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                textAlign = TextAlign.End,
                maxLines = 1,
            )
        }
        HorizontalDivider(
            modifier = Modifier.align(Alignment.BottomCenter),
            color = Color.White.copy(alpha = .10f),
        )
        if (!showSelection && showMenu) {
            Box(Modifier.align(Alignment.CenterEnd)) {
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    if (!showFavorite) {
                        DropdownMenuItem(
                            text = { Text("Play") },
                            leadingIcon = { Icon(Icons.Default.PlayArrow, null) },
                            onClick = {
                                menuOpen = false
                                actions.playTrack(track.id, queue.map { it.id }, playlistId)
                            },
                        )
                    } else {
                        val liked = track.id in state.favoriteTrackIds
                        DropdownMenuItem(
                            text = { Text(if (liked) "Remove from Liked Songs" else "Add to Liked Songs") },
                            leadingIcon = { Icon(if (liked) Icons.Default.Favorite else Icons.Default.FavoriteBorder, null) },
                            onClick = {
                                menuOpen = false
                                actions.toggleFavorite(track.id)
                            },
                        )
                    }
                    if (playlistId != null) {
                        DropdownMenuItem(
                            text = { Text("Remove from playlist") },
                            leadingIcon = { Icon(Icons.Default.Delete, null) },
                            onClick = {
                                menuOpen = false
                                actions.removeTrackFromPlaylist(playlistId, track.id)
                            },
                        )
                    }
                    if (playlistsForAdding.isNotEmpty()) {
                        HorizontalDivider()
                        playlistsForAdding.forEach { playlist ->
                            val alreadyAdded = track.id in playlist.trackIDs
                            DropdownMenuItem(
                                text = { Text(if (alreadyAdded) "${playlist.name} ✓" else "Add to ${playlist.name}") },
                                leadingIcon = { Icon(if (alreadyAdded) Icons.Default.Check else Icons.Default.Add, null) },
                                enabled = !alreadyAdded,
                                onClick = {
                                    menuOpen = false
                                    actions.addTrackToPlaylist(playlist.id, track.id)
                                },
                            )
                        }
                    }
                    if (allowDeleteFromDevice) {
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Remove from library", color = MaterialTheme.colorScheme.error) },
                            leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
                            onClick = {
                                menuOpen = false
                                onDeleteFromDevice?.invoke()
                                    ?: actions.deleteTracksFromDevice(setOf(track.id))
                            },
                        )
                    }
                }
            }
        }
    }
}

internal val Track.mediaKindLabel: String
    get() {
        val extension = relativePath.substringAfterLast('.', "").lowercase()
        return if (extension in setOf("mp4", "mov", "m4v", "webm")) "Video" else "Audio"
    }

fun durationText(milliseconds: Long): String {
    val seconds = (milliseconds.coerceAtLeast(0) / 1_000).toInt()
    return "${seconds / 60}:${(seconds % 60).toString().padStart(2, '0')}"
}

fun formatBytes(bytes: Long): String {
    if (bytes < 1_000) return "$bytes B"
    val units = arrayOf("KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = -1
    while (value >= 1_000 && unit < units.lastIndex) {
        value /= 1_000
        unit++
    }
    return "${DecimalFormat(if (value >= 10) "0.#" else "0.##").format(value)} ${units[unit]}"
}
