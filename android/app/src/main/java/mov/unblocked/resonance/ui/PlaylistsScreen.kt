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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Playlist

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
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color.White.copy(alpha = .045f), RoundedCornerShape(16.dp))
                        .clickable { onOpen(playlist.id) }
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Artwork(null, Modifier.size(54.dp))
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        Text(playlist.name, fontWeight = FontWeight.SemiBold)
                        Text(
                            "${playlist.trackIDs.size} tracks",
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
    val tracks = playlist.trackIDs.mapNotNull { id -> state.tracks.firstOrNull { it.id == id } }
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
                    if (tracks.size > 1) {
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
                    onClick = { if (isActivePlaylist) actions.togglePlayPause() else actions.playPlaylist(playlist.id) },
                    colors = ButtonDefaults.buttonColors(containerColor = Accent),
                ) {
                    Icon(if (state.isPlaying && isActivePlaylist) Icons.Default.Pause else Icons.Default.PlayArrow, null)
                    Spacer(Modifier.size(6.dp))
                    Text(if (state.isPlaying && isActivePlaylist) "Pause" else "Play", fontWeight = FontWeight.Bold)
                }
                IconButton(
                    onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                    modifier = Modifier.size(46.dp).background(if (state.shuffleEnabled) Violet else Color.White.copy(alpha = .08f), CircleShape),
                ) { Icon(Icons.Default.Shuffle, "Shuffle") }
            }
        }
        if (tracks.isEmpty()) {
            item { EmptyPlaylistMessage("No Songs", if (playlist.isSystem) "Like songs to add them here." else "Add songs from your library.") }
        } else {
            items(tracks, key = { it.id }) { track ->
                val index = tracks.indexOfFirst { it.id == track.id }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) {
                        TrackRow(track, state, actions, queue = tracks, playlistId = playlist.id, allowDeleteFromDevice = false)
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
        }
    }
    if (addSongs) {
        AlertDialog(
            onDismissRequest = { addSongs = false },
            title = { Text("Add Songs") },
            text = {
                LazyColumn(Modifier.heightIn(max = 440.dp)) {
                    items(state.tracks, key = { it.id }) { track ->
                        val added = track.id in playlist.trackIDs
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                if (added) actions.removeTrackFromPlaylist(playlist.id, track.id)
                                else actions.addTrackToPlaylist(playlist.id, track.id)
                            }.padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Artwork(state.artworkPathsByTrackId[track.id] ?: track.artworkFilename, Modifier.size(42.dp))
                            Column(Modifier.weight(1f)) {
                                Text(track.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text(track.artist, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                            }
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
