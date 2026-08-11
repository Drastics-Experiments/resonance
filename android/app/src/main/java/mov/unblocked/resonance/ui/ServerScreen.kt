package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CloudDownload
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.clerk.ui.auth.AuthView
import mov.unblocked.resonance.data.RemoteSong
import mov.unblocked.resonance.data.ServerDownloadMode
import mov.unblocked.resonance.data.ServerUploadMode
import mov.unblocked.resonance.data.AccountEmailPrivacy
import mov.unblocked.resonance.data.ResonanceAccountSignInServerURL
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
    var linkImportOpen by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) { actions.onServerScreenOpened() }

    val query = search.trim()
    val pendingMetadataCount = remember(state.remoteSongs) {
        state.remoteSongs.count(RemoteSong::isMetadataLoading)
    }
    val visible = remember(
        state.remoteSongs,
        state.downloadedRemoteSongIds,
        query,
        scope,
        sort,
        pendingMetadataCount,
    ) {
        state.remoteSongs.filter { song ->
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
                ServerSort.Title -> if (pendingMetadataCount > 0) {
                    a.filename.compareTo(b.filename, true)
                } else {
                    a.title.compareTo(b.title, true)
                }
                ServerSort.Artist -> if (pendingMetadataCount > 0) {
                    a.filename.compareTo(b.filename, true)
                } else {
                    a.artist.compareTo(b.artist, true)
                }
                ServerSort.FileSize -> b.size.compareTo(a.size)
                ServerSort.RecentlyUpdated -> b.modifiedAt.compareTo(a.modifiedAt)
            }
        }
    }
    val syncedCount = state.remoteSongs.count { it.id in state.downloadedRemoteSongIds }
    val host = remember(state.serverUrl) { runCatching { URI(state.serverUrl).host }.getOrNull() ?: state.serverUrl }
    val focusManager = LocalFocusManager.current
    val refreshEnabled = state.serverToken.isNotBlank() &&
        !state.isRefreshingServer &&
        !state.isApplyingServerConnection &&
        !state.isDownloading &&
        !state.isUploading &&
        !state.isSyncingPlaylists

    PullToRefreshBox(
        isRefreshing = state.isRefreshingServer,
        onRefresh = {
            // Material's pull refresh participates in the LazyColumn nested-scroll chain, so it
            // does not compete with Android's horizontal back gesture. Clearing focus first also
            // prevents an active search field/IME from consuming the initial drag.
            focusManager.clearFocus(force = true)
            actions.refreshServer()
        },
        enabled = refreshEnabled,
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Server", fontSize = 36.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                    if (state.isRefreshingServer) {
                        CircularProgressIndicator(
                            Modifier.size(28.dp),
                            strokeWidth = 2.dp,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    } else {
                        IconButton(
                            enabled = refreshEnabled,
                            onClick = {
                                focusManager.clearFocus(force = true)
                                actions.refreshServer()
                            },
                            modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                        ) { Icon(Icons.Default.Refresh, "Refresh server") }
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text(
                        if (state.isConnected) "\u25CF Connected" else "\u25CF Offline",
                        color = if (state.isConnected) {
                            LocalResonancePalette.current.success
                        } else {
                            MaterialTheme.colorScheme.onSurface.copy(alpha = .55f)
                        },
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        modifier = Modifier.background(
                            (if (state.isConnected) LocalResonancePalette.current.success else Color.White)
                                .copy(alpha = .11f),
                            CircleShape,
                        ).padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                    Row(
                        modifier = Modifier
                            .weight(1f)
                            .clickable { connectionOpen = true },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        Text(
                            host,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                            fontSize = 13.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Icon(Icons.Default.Settings, "Connection settings", Modifier.size(15.dp), tint = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                    }
                }
                Text(
                    "${state.remoteSongs.size} songs \u00B7 " +
                        "${state.playlists.count { !it.isSystem }} playlists \u00B7 " +
                        "$syncedCount on device",
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                )
            }
        }
        item {
            ServerActionBar(
                state = state,
                selecting = selecting,
                onDownload = {
                    actions.downloadSelectedRemoteSongs()
                    selecting = false
                },
                onUpload = {
                    linkImportOpen = true
                },
                onUploadMissing = actions::uploadMissingDownloads,
                onConnection = { connectionOpen = true },
                onToggleSelection = {
                    selecting = !selecting
                    if (selecting) scope = ServerScope.NotDownloaded else actions.clearRemoteSelection()
                },
            )
        }
        if (pendingMetadataCount > 0) {
            item {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(12.dp),
                        strokeWidth = 1.5.dp,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(
                        "Loading metadata for $pendingMetadataCount ${if (pendingMetadataCount == 1) "song" else "songs"}",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
            }
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    modifier = Modifier.weight(1f),
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    placeholder = { Text("Search server library") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
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
        if (visible.isEmpty() && state.remoteSongs.isEmpty() && state.isRefreshingServer) {
            repeat(7) { index ->
                item(key = "server-placeholder-$index") {
                    ServerSongPlaceholderRow(index + 1)
                }
            }
        } else if (visible.isEmpty()) {
            item {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 42.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Default.CloudDownload,
                        null,
                        Modifier.size(44.dp),
                        tint = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(if (state.remoteSongs.isEmpty()) "No Server Songs" else "No Results", style = MaterialTheme.typography.titleMedium)
                    Text("Connect and sync to load the server library.", color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
                }
            }
        } else {
            visible.forEachIndexed { index, song ->
                item(key = song.id) {
                    ServerSongRow(index + 1, song, state, actions, selecting, delete = { deleteCandidate = song })
                }
            }
        }
            item { Spacer(Modifier.height(8.dp)) }
        }
    }

    if (connectionOpen) {
        ConnectionDialog(state, actions) { connectionOpen = false }
    }
    if (linkImportOpen) {
        LinkImportDialog(state, actions) { linkImportOpen = false }
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
private fun ServerActionBar(
    state: ResonanceUiState,
    selecting: Boolean,
    onDownload: () -> Unit,
    onUpload: () -> Unit,
    onUploadMissing: () -> Unit,
    onConnection: () -> Unit,
    onToggleSelection: () -> Unit,
) {
    var moreOpen by remember { mutableStateOf(false) }
    val enabled = !state.isDownloading && !state.isUploading &&
        !state.isRefreshingServer && !state.isApplyingServerConnection && !state.isSyncingPlaylists
    val uploadEnabled = canStartServerUpload(state)
    val selectedStreamNeedsFile = state.serverDownloadMode == ServerDownloadMode.StreamOnly &&
        state.selectedRemoteSongIds.singleOrNull()?.let { selectedID ->
            state.remoteSongs.firstOrNull { it.id == selectedID }?.isVideoMedia
        } == true
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LocalResonancePalette.current.raised, RoundedCornerShape(18.dp))
            .border(1.dp, Color.White.copy(alpha = .085f), RoundedCornerShape(18.dp))
            .padding(horizontal = 4.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ServerAction(
            icon = Icons.Default.CloudDownload,
            label = when {
                selectedStreamNeedsFile -> "No video"
                state.serverDownloadMode == ServerDownloadMode.StreamOnly -> "Stream"
                else -> "Download"
            },
            enabled = enabled && if (state.serverDownloadMode == ServerDownloadMode.StreamOnly) {
                state.selectedRemoteSongIds.size == 1 && !selectedStreamNeedsFile
            } else {
                !selecting || state.selectedRemoteSongIds.isNotEmpty()
            },
            onClick = onDownload,
            modifier = Modifier.weight(1f),
        )
        ActionDivider()
        ServerAction(
            icon = Icons.Default.Checklist,
            label = if (selecting) "${state.selectedRemoteSongIds.size} Selected" else "Select",
            enabled = enabled,
            onClick = onToggleSelection,
            modifier = Modifier.weight(1f),
        )
        ActionDivider()
        Box {
            IconButton(onClick = { moreOpen = true }, modifier = Modifier.width(53.dp)) {
                Icon(Icons.Default.MoreVert, "More server actions")
            }
            DropdownMenu(expanded = moreOpen, onDismissRequest = { moreOpen = false }) {
                DropdownMenuItem(
                    text = { Text("Upload Missing Downloads") },
                    leadingIcon = { Icon(Icons.Default.CloudUpload, null) },
                    enabled = uploadEnabled && state.serverUploadMode == ServerUploadMode.LocalFile,
                    onClick = { moreOpen = false; onUploadMissing() },
                )
                DropdownMenuItem(
                    text = {
                        Text(
                            when (state.serverUploadMode) {
                                ServerUploadMode.ReviewedMatch -> "Review Upload"
                                ServerUploadMode.ServerSourceLink -> "Import from Web"
                                ServerUploadMode.LocalFile -> "Upload or Import"
                                null -> "Upload Disabled"
                            },
                        )
                    },
                    leadingIcon = { Icon(Icons.Default.CloudUpload, null) },
                    enabled = uploadEnabled,
                    onClick = { moreOpen = false; onUpload() },
                )
                DropdownMenuItem(
                    text = { Text("Account & Connection") },
                    leadingIcon = { Icon(Icons.Default.Settings, null) },
                    onClick = { moreOpen = false; onConnection() },
                )
            }
        }
    }
}

internal fun canStartServerUpload(state: ResonanceUiState): Boolean =
    !state.isDownloading &&
        !state.isUploading &&
        !state.isApplyingServerConnection &&
        state.hasServerUploadCredentials &&
        state.serverUploadMode != null &&
        state.serverUploadMode in state.availableServerUploadModes

@Composable
private fun ServerAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String?,
    enabled: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
    iconModifier: Modifier = Modifier,
) {
    val interaction = remember { MutableInteractionSource() }
    Row(
        modifier = modifier
            .clickable(
                enabled = enabled,
                interactionSource = interaction,
                indication = null,
                onClick = onClick,
            )
            .padding(horizontal = 7.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(
            icon,
            contentDescription = label ?: "Server action",
            modifier = iconModifier.size(21.dp),
            tint = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) .72f else .32f),
        )
        if (label != null) {
            Spacer(Modifier.width(6.dp))
            Text(
                label,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) .72f else .32f),
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun ActionDivider() {
    Box(Modifier.width(1.dp).height(34.dp).background(Color.White.copy(alpha = .10f)))
}

@Composable
fun TransferPopup(state: ResonanceUiState, modifier: Modifier = Modifier) {
    val isUploading = state.isUploading
    val progress = (if (isUploading) state.uploadProgress else state.downloadProgress)
        .coerceIn(0f, 1f)
    val counter = if (
        !isUploading && state.downloadCurrentItem > 0 && state.downloadTotalItems > 0
    ) {
        "${state.downloadCurrentItem}/${state.downloadTotalItems}"
    } else null
    val title = if (isUploading) "Uploading" else listOfNotNull("Downloading", counter).joinToString(" • ")
    val detail = if (isUploading) {
        state.uploadDetail
    } else {
        state.downloadCurrentTitle ?: state.downloadDetail
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .shadow(18.dp, RoundedCornerShape(20.dp))
            .background(LocalResonancePalette.current.panel.copy(alpha = .92f), RoundedCornerShape(20.dp))
            .border(1.dp, Color.White.copy(alpha = .15f), RoundedCornerShape(20.dp))
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Icon(
                if (isUploading) Icons.Default.CloudUpload else Icons.Default.CloudDownload,
                null,
                Modifier
                    .size(40.dp)
                    .background(MaterialTheme.colorScheme.secondary.copy(alpha = .17f), CircleShape)
                    .padding(9.dp),
                tint = MaterialTheme.colorScheme.tertiary,
            )
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    detail,
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .6f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text("${(progress * 100).toInt()}%", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f))
        }
        LinearProgressIndicator(
            progress = { progress },
            modifier = Modifier.fillMaxWidth(),
            color = MaterialTheme.colorScheme.secondary,
        )
        if (!isUploading) {
            val totalBytes = state.downloadTotalBytes?.takeIf { it > 0L }
            Text(
                if (totalBytes != null) {
                    "${formatBytes(state.downloadBytesTransferred)} / ${formatBytes(totalBytes)}"
                } else {
                    "${formatBytes(state.downloadBytesTransferred)} downloaded"
                },
                fontSize = 10.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f),
            )
        }
    }
}

@Composable
private fun ServerSongRow(
    number: Int,
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
    val metadataLoading = song.isMetadataLoading && local == null
    val displayTitle = local?.title?.takeIf(String::isNotBlank) ?: song.title
    val displayArtist = local?.artist?.takeIf { it.isNotBlank() && it != "Unknown Artist" } ?: song.artist
    val displayAlbum = local?.album?.takeIf { it.isNotBlank() && it != "Server Library" } ?: song.album
    val trailingDetail = local?.durationText ?: song.durationText ?: formatBytes(song.size)

    Box(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 76.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(if (selected) Color.White.copy(alpha = .05f) else Color.Transparent)
                .combinedClickable(
                    onClick = {
                        when {
                            selecting -> actions.toggleRemoteSelection(song.id)
                            local != null -> actions.playTrack(local.id, state.tracks.map { it.id })
                            else -> actions.downloadRemoteSong(song.id)
                        }
                    },
                    onLongClick = if (selecting) null else ({ menu = true }),
                )
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.width(24.dp), contentAlignment = Alignment.CenterStart) {
                if (selecting) {
                    Icon(
                        if (selected) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                        contentDescription = if (selected) "Selected" else "Not selected",
                        modifier = Modifier.size(18.dp),
                        tint = if (selected) {
                            MaterialTheme.colorScheme.tertiary
                        } else {
                            MaterialTheme.colorScheme.onSurface.copy(alpha = .42f)
                        },
                    )
                } else {
                    Text(number.toString(), fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .5f))
                }
            }
            if (local != null) {
                Artwork(
                    state.artworkPathsByTrackId[local.id] ?: local.artworkFilename,
                    Modifier.size(52.dp),
                )
            } else if (metadataLoading) {
                Box(
                    Modifier
                        .size(52.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(Color.White.copy(alpha = .07f)),
                    contentAlignment = Alignment.Center,
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                        color = Color.White.copy(alpha = .68f),
                    )
                }
            } else {
                RemoteArtwork(song.artworkURL, state.serverUrl, Modifier.size(52.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                if (metadataLoading) {
                    ServerMetadataPlaceholder(148.dp, 11.dp)
                    ServerMetadataPlaceholder(96.dp, 8.dp)
                    ServerMetadataPlaceholder(88.dp, 9.dp)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(
                            displayTitle,
                            modifier = Modifier.weight(1f, fill = false),
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (synced) {
                            Icon(
                                Icons.Default.CheckCircle,
                                contentDescription = "Downloaded",
                                modifier = Modifier.size(9.dp),
                                tint = LocalResonancePalette.current.success,
                            )
                        }
                    }
                    Text(
                        "$displayArtist / ${song.mediaKindLabel}",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (displayAlbum.isNotBlank()) {
                        Text(
                            displayAlbum,
                            fontSize = 11.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .43f),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            if (metadataLoading) {
                Box(Modifier.width(44.dp), contentAlignment = Alignment.CenterEnd) {
                    ServerMetadataPlaceholder(42.dp, 9.dp)
                }
            } else {
                Text(
                    trailingDetail,
                    modifier = Modifier.width(44.dp),
                    fontSize = 11.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                    textAlign = TextAlign.End,
                    maxLines = 1,
                )
            }
        }
        Box(Modifier.align(Alignment.CenterEnd)) {
            if (!selecting) {
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    if (!synced) DropdownMenuItem(
                        text = {
                            Text(
                                when {
                                    state.serverDownloadMode == ServerDownloadMode.StreamOnly && song.isVideoMedia ->
                                        "Video streaming unavailable"
                                    state.serverDownloadMode == ServerDownloadMode.StreamOnly -> "Stream"
                                    else -> "Download"
                                },
                            )
                        },
                        leadingIcon = { Icon(Icons.Default.CloudDownload, null) },
                        enabled = state.serverDownloadMode != ServerDownloadMode.StreamOnly || !song.isVideoMedia,
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
        androidx.compose.material3.HorizontalDivider(
            modifier = Modifier.align(Alignment.BottomCenter),
            color = Color.White.copy(alpha = .10f),
        )
    }
}

@Composable
private fun ServerSongPlaceholderRow(number: Int) {
    Column {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 76.dp)
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                number.toString(),
                modifier = Modifier.width(24.dp),
                fontSize = 11.sp,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .25f),
            )
            Box(
                Modifier
                    .size(52.dp)
                    .clip(RoundedCornerShape(9.dp))
                    .background(Color.White.copy(alpha = .07f)),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = Color.White.copy(alpha = .58f),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(7.dp)) {
                ServerMetadataPlaceholder(148.dp, 11.dp)
                ServerMetadataPlaceholder(96.dp, 8.dp)
                ServerMetadataPlaceholder(88.dp, 9.dp)
            }
            Box(Modifier.width(44.dp), contentAlignment = Alignment.CenterEnd) {
                ServerMetadataPlaceholder(42.dp, 9.dp)
            }
        }
        androidx.compose.material3.HorizontalDivider(color = Color.White.copy(alpha = .10f))
    }
}

@Composable
private fun ServerMetadataPlaceholder(
    width: androidx.compose.ui.unit.Dp,
    height: androidx.compose.ui.unit.Dp,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .width(width)
            .height(height)
            .background(Color.White.copy(alpha = .09f), RoundedCornerShape(height / 2)),
    )
}

private val RemoteSong.mediaKindLabel: String
    get() = if (isVideoMedia) "Video" else "Audio"

@Composable
internal fun ConnectionDialog(state: ResonanceUiState, actions: ResonanceActions, dismiss: () -> Unit) {
    var connectRequested by remember { mutableStateOf(false) }
    var isEmailRevealed by remember(state.accountEmail) { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val connecting = state.isApplyingServerConnection || state.isRefreshingServer || state.isSigningIn

    LaunchedEffect(connectRequested, connecting, state.isConnected, state.serverMessage) {
        if (connectRequested && !connecting && state.isConnected) dismiss()
    }

    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("Connection") },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(
                    ResonanceAccountSignInServerURL,
                    {},
                    readOnly = true,
                    label = { Text("Server URL") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                    keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
                )
                if (state.accountEmail != null) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column {
                            Text(
                                AccountEmailPrivacy.safeDisplayName(state.accountDisplayName, state.accountEmail),
                                fontWeight = FontWeight.SemiBold,
                            )
                            TextButton(
                                onClick = { isEmailRevealed = !isEmailRevealed },
                                contentPadding = PaddingValues(0.dp),
                            ) {
                                Text(
                                    AccountEmailPrivacy.displayedAddress(state.accountEmail, isEmailRevealed),
                                    fontSize = 11.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                )
                            }
                            Text(
                                if (state.accountRole == "admin") "Administrator" else "Member",
                                fontSize = 11.sp,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                            )
                        }
                        TextButton(onClick = actions::signOutAccount, enabled = !connecting) { Text("Sign out") }
                    }
                } else {
                    Text(
                        if (state.serverToken.isBlank()) "Sign in with your account" else "Legacy connection • continue with Clerk",
                        fontWeight = FontWeight.SemiBold,
                    )
                    Button(
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
                        enabled = !connecting,
                        shape = RoundedCornerShape(14.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = MaterialTheme.colorScheme.primary,
                            contentColor = Color.White,
                        ),
                        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 13.dp),
                        onClick = {
                            focusManager.clearFocus()
                            actions.startNativeAccountSignIn()
                        },
                    ) {
                        if (connecting) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(18.dp),
                                color = Color.White,
                                strokeWidth = 2.dp,
                            )
                        } else {
                            Icon(Icons.Default.Lock, contentDescription = null, modifier = Modifier.size(18.dp))
                        }
                        Spacer(Modifier.size(8.dp))
                        Text(
                            "Sign in with Clerk",
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center,
                            maxLines = 2,
                        )
                    }
                    Text(
                        "Account sign-in always uses https://resonance-core.blithe-haven-9710.chatgpt.site/.",
                        fontSize = 11.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
                Text(state.serverMessage, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
            }
        },
        confirmButton = {
            TextButton(
                enabled = !connecting && state.serverToken.isNotBlank(),
                onClick = {
                    focusManager.clearFocus()
                    connectRequested = true
                    actions.saveServerConnection(
                        ResonanceAccountSignInServerURL,
                        state.serverToken,
                        state.serverAdminKey,
                        AccountEmailPrivacy.safeDisplayName(
                            state.accountDisplayName ?: activeSyncProfileName(state),
                            state.accountEmail,
                        ),
                    )
                },
            ) {
                if (connecting) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(7.dp))
                }
                Text(if (connecting) "Connecting…" else "Connect")
            }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } },
    )

    if (state.isNativeAccountSignInOpen) {
        Dialog(
            onDismissRequest = actions::dismissNativeAccountSignIn,
            properties = DialogProperties(usePlatformDefaultWidth = false),
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = MaterialTheme.colorScheme.background,
            ) {
                AuthView(
                    isDismissible = true,
                    onDismiss = actions::dismissNativeAccountSignIn,
                    onAuthComplete = actions::completeNativeAccountSignIn,
                )
            }
        }
    }
}
