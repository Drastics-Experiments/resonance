package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Playlist
import mov.unblocked.resonance.data.PlaylistPresentationEntry
import mov.unblocked.resonance.data.PlaylistPresentationPolicy

@Composable
fun PlaylistsScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    openPlaylistId: String?,
    onOpenPlaylist: (String) -> Unit,
    onClosePlaylist: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val playlist = openPlaylistId?.let { id -> state.playlists.firstOrNull { it.id == id } }
    if (playlist != null) {
        PlaylistDetailScreen(playlist, state, actions, onClosePlaylist, modifier)
    } else {
        PlaylistCollectionScreen(state, actions, onOpenPlaylist, modifier)
    }
}

@Composable
private fun PlaylistCollectionScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onOpen: (String) -> Unit,
    modifier: Modifier,
) {
    val focusManager = LocalFocusManager.current
    var creating by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var deletion by remember { mutableStateOf<Playlist?>(null) }
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(20.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Eyebrow("Your collections")
                    Text("Playlists", fontSize = 36.sp, fontWeight = FontWeight.Bold)
                }
                IconButton(
                    onClick = { creating = true },
                    modifier = Modifier.size(46.dp).background(Accent, CircleShape),
                ) { Icon(Icons.Default.Add, "New playlist") }
            }
        }
        if (state.playlists.isEmpty()) {
            item { EmptyPlaylistMessage("No playlists", "Create a playlist to organize your music.") }
        } else {
            items(state.playlists, key = { it.id }) { playlist ->
                val trackCount = PlaylistPresentationPolicy.entries(
                    playlist,
                    state.tracks,
                    state.remoteSongs,
                ).size
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White.copy(alpha = .045f), RoundedCornerShape(16.dp))
                        .clickable { onOpen(playlist.id) }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    PlaylistArtwork(playlist, state, Modifier.size(54.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(playlist.name, fontWeight = FontWeight.SemiBold)
                        Text(
                            "$trackCount tracks",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        )
                    }
                    if (!playlist.isSystem) {
                        IconButton(onClick = { deletion = playlist }) {
                            Icon(Icons.Default.Delete, "Delete playlist", tint = MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
        }
    }
    if (creating) {
        AlertDialog(
            onDismissRequest = { creating = false },
            title = { Text("New Playlist") },
            text = {
                OutlinedTextField(
                    name,
                    { name = it },
                    placeholder = { Text("Name") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                )
            },
            confirmButton = {
                TextButton(
                    enabled = name.isNotBlank(),
                    onClick = { actions.createPlaylist(name.trim()); name = ""; creating = false },
                ) { Text("Create") }
            },
            dismissButton = { TextButton(onClick = { creating = false }) { Text("Cancel") } },
        )
    }
    deletion?.let { target ->
        AlertDialog(
            onDismissRequest = { deletion = null },
            title = { Text("Delete ${target.name}?") },
            text = { Text("Songs in this playlist will remain in your music library.") },
            confirmButton = {
                TextButton(onClick = { actions.deletePlaylist(target.id); deletion = null }) {
                    Text("Delete Playlist", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deletion = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun PlaylistDetailScreen(
    playlist: Playlist,
    state: ResonanceUiState,
    actions: ResonanceActions,
    onBack: () -> Unit,
    modifier: Modifier,
) {
    var addSongs by remember { mutableStateOf(false) }
    var reorder by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val entries = PlaylistPresentationPolicy.entries(playlist, state.tracks, state.remoteSongs)
    val tracks = entries.mapNotNull { (it as? PlaylistPresentationEntry.Downloaded)?.track }
    val hasUnavailableEntries = entries.any { it is PlaylistPresentationEntry.Unavailable }
    val isActivePlaylist = state.activePlaylistId == playlist.id && state.currentTrackId != null
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = onBack) { Icon(Icons.Default.ArrowBack, "Back") }
                Text(playlist.name, style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                if (!playlist.isSystem) {
                    IconButton(onClick = { addSongs = true }) { Icon(Icons.Default.Add, "Add songs") }
                    if (tracks.size > 1 && !hasUnavailableEntries) {
                        TextButton(onClick = { reorder = !reorder }) { Text(if (reorder) "Done" else "Reorder") }
                    }
                    IconButton(onClick = { confirmDelete = true }) {
                        Icon(Icons.Default.Delete, "Delete playlist", tint = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(
                    enabled = tracks.isNotEmpty(),
                    onClick = { if (isActivePlaylist) actions.togglePlayPause() else actions.playPlaylist(playlist.id) },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent),
                ) {
                    Icon(
                        if (state.isPlaying && isActivePlaylist) Icons.Default.Pause
                        else if (state.shuffleEnabled && !isActivePlaylist) Icons.Default.Shuffle
                        else Icons.Default.PlayArrow,
                        null,
                    )
                    Spacer(Modifier.size(6.dp))
                    Text(
                        if (state.isPlaying && isActivePlaylist) "Pause"
                        else if (state.shuffleEnabled && !isActivePlaylist) "Shuffle Play"
                        else "Play",
                        fontWeight = FontWeight.Bold,
                    )
                }
                IconButton(
                    enabled = tracks.isNotEmpty() && !state.isTransientPlayback,
                    onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                    modifier = Modifier.size(46.dp).background(
                        if (state.shuffleEnabled && !state.isTransientPlayback) Violet
                        else Color.White.copy(alpha = .08f),
                        CircleShape,
                    ),
                ) { Icon(Icons.Default.Shuffle, "Shuffle") }
            }
        }
        if (entries.isEmpty()) {
            item { EmptyPlaylistMessage("No Songs", if (playlist.isSystem) "Like songs to add them here." else "Add songs from your library.") }
        } else {
            item { SongListHeader() }
            itemsIndexed(entries, key = { _, entry -> entry.stableID }) { index, entry ->
                when (entry) {
                    is PlaylistPresentationEntry.Downloaded -> {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.weight(1f)) {
                                TrackRow(
                                    entry.track,
                                    state,
                                    actions,
                                    number = index + 1,
                                    queue = tracks,
                                    playlistId = playlist.id,
                                    allowDeleteFromDevice = false,
                                )
                            }
                            if (reorder) {
                                Column {
                                    IconButton(
                                        enabled = index > 0,
                                        onClick = { actions.movePlaylistTrack(playlist.id, index, index - 1) },
                                    ) { Icon(Icons.Default.KeyboardArrowUp, "Move up") }
                                    IconButton(
                                        enabled = index < tracks.lastIndex,
                                        onClick = { actions.movePlaylistTrack(playlist.id, index, index + 1) },
                                    ) { Icon(Icons.Default.KeyboardArrowDown, "Move down") }
                                }
                            }
                        }
                    }
                    is PlaylistPresentationEntry.Unavailable -> UnavailablePlaylistSongRow(
                        entry = entry,
                        number = index + 1,
                        serverURL = state.serverUrl,
                    )
                }
            }
        }
    }
    if (addSongs) {
        AlertDialog(
            onDismissRequest = { addSongs = false },
            title = { Text("Add Songs") },
            text = {
                LazyColumn(Modifier.heightIn(max = 440.dp)) {
                    item { SongListHeader() }
                    itemsIndexed(state.tracks, key = { _, track -> track.id }) { index, track ->
                        val added = track.id in playlist.trackIDs
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                if (added) actions.removeTrackFromPlaylist(playlist.id, track.id)
                                else actions.addTrackToPlaylist(playlist.id, track.id)
                            }.padding(horizontal = 8.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Text(
                                (index + 1).toString(),
                                modifier = Modifier.width(24.dp),
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f),
                            )
                            Artwork(state.artworkPathsByTrackId[track.id] ?: track.artworkFilename, Modifier.size(52.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(track.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(
                                    "${track.artist} / ${track.mediaKindLabel}",
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                                    maxLines = 1,
                                )
                                Text(
                                    track.album.ifBlank { "Unknown Album" },
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .42f),
                                    maxLines = 1,
                                )
                            }
                            Text(track.durationText, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                            Icon(if (added) Icons.Default.Check else Icons.Default.Add, null, tint = if (added) Accent else Color.White)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { addSongs = false }) { Text("Done") } },
        )
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${playlist.name}?") },
            text = { Text("Songs in this playlist will remain in your music library.") },
            confirmButton = {
                TextButton(onClick = { actions.deletePlaylist(playlist.id); confirmDelete = false; onBack() }) {
                    Text("Delete Playlist", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun UnavailablePlaylistSongRow(
    entry: PlaylistPresentationEntry.Unavailable,
    number: Int,
    serverURL: String,
) {
    val song = entry.remoteSong
    val title = song?.title ?: "Unavailable song"
    val artist = song?.artist ?: "Not downloaded on this device"
    val album = song?.album ?: "Server playlist"
    val mediaKind = if (song?.isVideoMedia == true) "Video" else "Audio"

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 76.dp)
            .alpha(.52f)
            .padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            number.toString(),
            modifier = Modifier.width(24.dp),
            fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .65f),
        )
        if (song != null) {
            RemoteArtwork(song.artworkURL, serverURL, Modifier.size(52.dp))
        } else {
            Artwork(null, Modifier.size(52.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(
                "$artist / $mediaKind / Not downloaded",
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                album,
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Column(horizontalAlignment = Alignment.End) {
            Icon(Icons.Default.CloudDownload, "Not downloaded", Modifier.size(17.dp))
            Text(
                song?.durationText ?: "—",
                modifier = Modifier.width(44.dp),
                fontSize = 11.sp,
                textAlign = TextAlign.End,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun EmptyPlaylistMessage(title: String, detail: String) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 52.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.MusicNote, null, Modifier.size(44.dp), tint = Violet)
        Text(title, style = MaterialTheme.typography.titleMedium)
        Text(detail, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
    }
}
