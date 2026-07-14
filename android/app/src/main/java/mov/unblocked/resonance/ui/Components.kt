package mov.unblocked.resonance.ui

import android.graphics.BitmapFactory
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.Track
import java.text.DecimalFormat

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
fun TrackRow(
    track: Track,
    state: ResonanceUiState,
    actions: ResonanceActions,
    modifier: Modifier = Modifier,
    queue: List<Track> = state.tracks,
    playlistId: String? = null,
    playlistsForAdding: List<Playlist> = state.playlists.filterNot { it.isSystem },
    trailingText: String = durationText(track.durationMs),
    showSelection: Boolean = false,
    selected: Boolean = false,
    onSelect: (() -> Unit)? = null,
    allowDeleteFromDevice: Boolean = true,
    showFavorite: Boolean = true,
    showMenu: Boolean = true,
) {
    var menuOpen by remember { mutableStateOf(false) }
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable {
                if (showSelection) onSelect?.invoke()
                else actions.playTrack(track.id, queue.map { it.id }, playlistId)
            }
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (showSelection) {
            Box(
                modifier = Modifier
                    .size(22.dp)
                    .clip(CircleShape)
                    .background(if (selected) Accent else Color.Transparent)
                    .then(if (selected) Modifier else Modifier.background(Color.White.copy(alpha = .08f))),
                contentAlignment = Alignment.Center,
            ) {
                if (selected) Icon(Icons.Default.Check, null, Modifier.size(15.dp), tint = Color.White)
            }
        }
        Artwork(
            path = state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
            modifier = Modifier.size(50.dp),
            showWaveform = state.currentTrackId == track.id && state.isPlaying,
        )
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(track.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "${track.artist} • ${track.album}",
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(trailingText, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
        if (!showSelection) {
            if (showFavorite) {
                IconButton(onClick = { actions.toggleFavorite(track.id) }, modifier = Modifier.size(38.dp)) {
                    Icon(
                        if (track.id in state.favoriteTrackIds) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                        contentDescription = "Favorite",
                        tint = if (track.id in state.favoriteTrackIds) Accent else MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                    )
                }
            }
            if (showMenu) Box {
                IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(38.dp)) {
                    Icon(Icons.Default.MoreVert, "More options")
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Play") },
                        leadingIcon = { Icon(Icons.Default.PlayArrow, null) },
                        onClick = {
                            menuOpen = false
                            actions.playTrack(track.id, queue.map { it.id }, playlistId)
                        },
                    )
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
                                actions.deleteTracksFromDevice(setOf(track.id))
                            },
                        )
                    }
                }
            }
        }
    }
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
