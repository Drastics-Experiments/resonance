package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.RemoteSong
import java.net.URI

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ServerScreen(state: ResonanceUiState, actions: ResonanceActions, modifier: Modifier = Modifier) {
    var connectionOpen by remember { mutableStateOf(false) }
    var search by remember { mutableStateOf("") }
    var scope by remember { mutableStateOf(ServerScope.All) }
    var sort by remember { mutableStateOf(ServerSort.Title) }
    var filterOpen by remember { mutableStateOf(false) }
    var selecting by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<RemoteSong?>(null) }

    LaunchedEffect(Unit) { actions.onServerScreenOpened() }

    val query = search.trim()
    val visible = state.remoteSongs.filter { song ->
        val synced = song.id in state.downloadedRemoteSongIds
        val matchesScope = when (scope) {
            ServerScope.All -> true
            ServerScope.OnDevice -> synced
            ServerScope.NotDownloaded -> !synced
        }
        matchesScope && (query.isEmpty() || song.title.contains(query, true) || song.artist.contains(query, true) ||
            song.album.contains(query, true) || song.filename.contains(query, true))
    }.sortedWith { a, b ->
        when (sort) {
            ServerSort.Title -> a.title.compareTo(b.title, true)
            ServerSort.Artist -> a.artist.compareTo(b.artist, true)
            ServerSort.FileSize -> b.size.compareTo(a.size)
            ServerSort.RecentlyUpdated -> b.modifiedAt.compareTo(a.modifiedAt)
        }
    }
    val syncedCount = state.remoteSongs.count { it.id in state.downloadedRemoteSongIds }
    val allSynced = state.remoteSongs.isNotEmpty() && syncedCount == state.remoteSongs.size
    val host = remember(state.serverUrl) { runCatching { URI(state.serverUrl).host }.getOrNull() ?: state.serverUrl }

    PullToRefreshBox(
        isRefreshing = state.isRefreshingServer,
        onRefresh = actions::refreshServer,
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Text("Music Server", fontSize = 36.sp, fontWeight = FontWeight.Bold)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(
                        if (state.isConnected) "● Connected" else "● Not Connected",
                        color = if (state.isConnected) SuccessGreen else MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        modifier = Modifier.background(
                            (if (state.isConnected) SuccessGreen else Color.White).copy(alpha = .11f),
                            CircleShape,
                        ).padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                    Text(host, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f), fontSize = 13.sp, maxLines = 1)
                    Spacer(Modifier.weight(1f))
                    IconButton(onClick = actions::refreshServer, enabled = !state.isDownloading && !state.isUploading) {
                        Icon(Icons.Default.Refresh, "Refresh server")
                    }
                }
            }
        }
        item {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.White.copy(alpha = .045f), RoundedCornerShape(17.dp))
                    .clickable { connectionOpen = true }
                    .padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(13.dp),
            ) {
                Icon(Icons.Default.Language, null, Modifier.size(30.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Connection", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                    Text(
                        "${state.serverUrl}  •  🔑 ${if (state.serverToken.isBlank()) "Not configured" else "•••• •••• ••••"}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Icon(Icons.Default.Settings, "Connection settings", Modifier.background(Color.White.copy(alpha = .06f), RoundedCornerShape(12.dp)).padding(10.dp))
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ServerMetric(Icons.Default.MusicNote, Violet, state.remoteSongs.size.toString(), "songs", Modifier.weight(1f))
                ServerMetric(Icons.Default.MoreVert, Violet, state.playlists.count { !it.isSystem }.toString(), "playlists", Modifier.weight(1f))
                ServerMetric(
                    Icons.Default.CheckCircle,
                    if (allSynced) SuccessGreen else Coral,
                    if (allSynced) "All" else "$syncedCount/${state.remoteSongs.size}",
                    "synced",
                    Modifier.weight(1f),
                )
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = actions::uploadAudio,
                    modifier = Modifier.weight(1f),
                    enabled = !state.isDownloading && !state.isUploading,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = .075f)),
                ) { Icon(Icons.Default.CloudUpload, null, tint = Coral); Spacer(Modifier.size(6.dp)); Text("Upload") }
                Button(
                    onClick = {
                        actions.downloadSelectedRemoteSongs()
                        selecting = false
                    },
                    modifier = Modifier.weight(1f),
                    enabled = !state.isDownloading && !state.isUploading,
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = .075f)),
                ) {
                    Icon(Icons.Default.CloudDownload, null, tint = Coral)
                    Spacer(Modifier.size(6.dp))
                    Text(if (state.selectedRemoteSongIds.isEmpty()) "Download" else "Get ${state.selectedRemoteSongIds.size}")
                }
            }
        }
        item { TransferPanel(state) }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    modifier = Modifier.weight(1f),
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    placeholder = { Text("Search server library") },
                    singleLine = true,
                    shape = RoundedCornerShape(13.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedContainerColor = Color.White.copy(alpha = .055f),
                        unfocusedContainerColor = Color.White.copy(alpha = .055f),
                        unfocusedBorderColor = Color.White.copy(alpha = .08f),
                    ),
                )
                Box {
                    IconButton(
                        onClick = { filterOpen = true },
                        modifier = Modifier.size(56.dp).background(Color.White.copy(alpha = .055f), RoundedCornerShape(13.dp)),
                    ) { Icon(Icons.Default.FilterList, "Filter and sort") }
                    DropdownMenu(expanded = filterOpen, onDismissRequest = { filterOpen = false }) {
                        Eyebrow("Filter", Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
                        ServerScope.entries.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                leadingIcon = { if (scope == option) Icon(Icons.Default.Check, null) },
                                onClick = { scope = option; filterOpen = false },
                            )
                        }
                        Eyebrow("Sort by", Modifier.padding(horizontal = 12.dp, vertical = 5.dp))
                        ServerSort.entries.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                leadingIcon = { if (sort == option) Icon(Icons.Default.Check, null) },
                                onClick = { sort = option; filterOpen = false },
                            )
                        }
                    }
                }
            }
        }
        item { SegmentedControl(ServerScope.entries.map { it.label }, scope.ordinal, { scope = ServerScope.entries[it] }) }
        item {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Eyebrow("Server Library")
                Text("  ${visible.size} songs", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                Spacer(Modifier.weight(1f))
                if (selecting && state.selectedRemoteSongIds.isNotEmpty()) {
                    TextButton(onClick = actions::downloadSelectedRemoteSongs) { Text("Download ${state.selectedRemoteSongIds.size}") }
                }
                TextButton(onClick = {
                    selecting = !selecting
                    if (!selecting) actions.clearRemoteSelection()
                }) { Text(if (selecting) "Done" else "Select", fontWeight = FontWeight.SemiBold) }
            }
        }
        if (visible.isEmpty()) {
            item {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 42.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Default.CloudDownload, null, Modifier.size(44.dp), tint = Violet)
                    Text(if (state.remoteSongs.isEmpty()) "No Server Songs" else "No Results", style = MaterialTheme.typography.titleMedium)
                    Text("Connect and sync to load the server library.", color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                }
            }
        } else {
            visible.forEach { song ->
                item(key = song.id) {
                    ServerSongRow(song, state, actions, selecting, delete = { deleteCandidate = song })
                }
            }
        }
            item { Spacer(Modifier.height(8.dp)) }
        }
    }

    if (connectionOpen) {
        ConnectionDialog(state, actions) { connectionOpen = false }
    }
    deleteCandidate?.let { song ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text("Delete ${song.title} from the server?") },
            text = { Text("This permanently deletes the server copy. A downloaded local copy is not removed.") },
            confirmButton = {
                TextButton(onClick = { actions.deleteRemoteSong(song.id); deleteCandidate = null }) {
                    Text("Delete from Server", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { deleteCandidate = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ServerMetric(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    color: Color,
    value: String,
    label: String,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier.background(Color.White.copy(alpha = .045f), RoundedCornerShape(15.dp)).padding(11.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, Modifier.size(30.dp).background(color.copy(alpha = .12f), CircleShape).padding(6.dp), tint = color)
            Spacer(Modifier.weight(1f))
            Text(value, fontWeight = FontWeight.SemiBold, fontSize = 19.sp, maxLines = 1)
        }
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
    }
}

@Composable
private fun TransferPanel(state: ResonanceUiState) {
    val active = state.isDownloading || state.isUploading || state.isSyncingPlaylists
    val progress = when {
        state.isDownloading -> state.downloadProgress
        state.isUploading -> state.uploadProgress
        else -> 0f
    }.coerceIn(0f, 1f)
    Column(
        modifier = Modifier.fillMaxWidth().background(Color.White.copy(alpha = .045f), RoundedCornerShape(17.dp)).padding(15.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row {
            Column(Modifier.weight(1f)) {
                Text(if (active) "Syncing in progress" else "Transfer activity", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    when {
                        state.isDownloading -> state.downloadDetail
                        state.isUploading -> state.uploadDetail
                        state.isSyncingPlaylists -> state.playlistSyncDetail
                        else -> "Downloads and uploads are idle"
                    },
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                )
            }
            Text(if (active && !state.isSyncingPlaylists) "${(progress * 100).toInt()}%" else "Idle", fontSize = 12.sp)
        }
        LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth(), color = Coral)
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("↓ Downloading\n${state.downloadDetail}", fontSize = 11.sp, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurface.copy(alpha = .65f))
            Text("↑ Uploading\n${state.uploadDetail}", fontSize = 11.sp, modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurface.copy(alpha = .65f))
        }
    }
}

@Composable
private fun ServerSongRow(
    song: RemoteSong,
    state: ResonanceUiState,
    actions: ResonanceActions,
    selecting: Boolean,
    delete: () -> Unit,
) {
    var menu by remember { mutableStateOf(false) }
    val synced = song.id in state.downloadedRemoteSongIds
    val selected = song.id in state.selectedRemoteSongIds
    val local = state.tracks.firstOrNull { it.remoteID == song.id }
    Row(
        modifier = Modifier.fillMaxWidth().clickable {
            when {
                selecting -> actions.toggleRemoteSelection(song.id)
                local != null -> actions.playTrack(local.id, state.tracks.map { it.id })
                else -> actions.downloadRemoteSong(song.id)
            }
        }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        if (selecting) {
            Box(
                Modifier.size(22.dp).background(if (selected) Coral else Color.White.copy(alpha = .08f), CircleShape),
                contentAlignment = Alignment.Center,
            ) { if (selected) Icon(Icons.Default.Check, null, Modifier.size(15.dp)) }
        }
        Artwork(local?.let { state.artworkPathsByTrackId[it.id] ?: it.artworkFilename }, Modifier.size(52.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(song.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(song.artist, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f), maxLines = 1)
            Text(song.album, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .48f), maxLines = 1)
        }
        Text(formatBytes(song.size), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
        Icon(if (synced) Icons.Default.CheckCircle else Icons.Default.CloudDownload, if (synced) "Downloaded" else "Download", tint = if (synced) SuccessGreen else Coral)
        if (!selecting) {
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, "More") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (!synced) DropdownMenuItem(
                        text = { Text("Download") },
                        leadingIcon = { Icon(Icons.Default.CloudDownload, null) },
                        onClick = { menu = false; actions.downloadRemoteSong(song.id) },
                    )
                    DropdownMenuItem(
                        text = { Text("Delete from Server", color = MaterialTheme.colorScheme.error) },
                        leadingIcon = { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error) },
                        onClick = { menu = false; delete() },
                    )
                }
            }
        }
    }
}

@Composable
private fun ConnectionDialog(state: ResonanceUiState, actions: ResonanceActions, dismiss: () -> Unit) {
    var url by remember(state.serverUrl) { mutableStateOf(state.serverUrl) }
    var token by remember(state.serverToken) { mutableStateOf(state.serverToken) }
    var admin by remember(state.serverAdminKey) { mutableStateOf(state.serverAdminKey) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Connection") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(url, { url = it }, label = { Text("Server URL") }, singleLine = true)
                OutlinedTextField(token, { token = it }, label = { Text("Server access token") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                OutlinedTextField(admin, { admin = it }, label = { Text("Server admin key") }, visualTransformation = PasswordVisualTransformation(), singleLine = true)
                Text(state.serverMessage, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
            }
        },
        confirmButton = {
            TextButton(onClick = { actions.saveServerConnection(url.trim(), token.trim(), admin.trim()); dismiss() }) { Text("Connect") }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
    )
}
