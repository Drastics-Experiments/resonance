package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Track

@Composable
fun StorageScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    modifier: Modifier = Modifier,
    onBack: () -> Unit,
) {
    val focusManager = LocalFocusManager.current
    var search by remember { mutableStateOf("") }
    var scope by remember { mutableStateOf(StorageScope.Songs) }
    var sort by remember { mutableStateOf(StorageSort.Title) }
    var filterMenu by remember { mutableStateOf(false) }
    var importMenu by remember { mutableStateOf(false) }
    var actionsMenu by remember { mutableStateOf(false) }
    var linkImportOpen by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var confirmDelete by remember { mutableStateOf(false) }
    var deleteCandidate by remember { mutableStateOf<Track?>(null) }

    LaunchedEffect(state.tracks.map(Track::id)) {
        selected = selected.intersect(state.tracks.mapTo(mutableSetOf(), Track::id))
        if (selected.isEmpty() && state.tracks.isEmpty()) editing = false
    }

    val downloaded = state.tracks.filter { it.sourceServer != null || it.remoteID != null }
    val imported = state.tracks.filter { it.sourceServer == null && it.remoteID == null }
    val scoped = when (scope) {
        StorageScope.Songs -> state.tracks
        StorageScope.Downloads -> downloaded
        StorageScope.Files -> imported
    }
    val query = search.trim()
    val visible = scoped.filter {
        query.isEmpty() || it.title.contains(query, true) || it.artist.contains(query, true) ||
            it.album.contains(query, true) || it.relativePath.contains(query, true)
    }.sortedWith { a, b ->
        when (sort) {
            StorageSort.Title -> a.title.compareTo(b.title, true)
            StorageSort.Artist -> a.artist.compareTo(b.artist, true)
            StorageSort.RecentlyAdded -> b.dateAddedEpochMs.compareTo(a.dateAddedEpochMs)
            StorageSort.FileSize -> state.trackSizesById.getOrDefault(b.id, 0).compareTo(state.trackSizesById.getOrDefault(a.id, 0))
        }
    }
    val visibleDownloaded = visible.filter { it.sourceServer != null || it.remoteID != null }
    val visibleImported = visible.filter { it.sourceServer == null && it.remoteID == null }
    val downloadedBytes = downloaded.sumOf { state.trackSizesById[it.id] ?: 0 }
    val importedBytes = imported.sumOf { state.trackSizesById[it.id] ?: 0 }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                IconButton(
                    onClick = onBack,
                    modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                ) { Icon(Icons.Default.ArrowBack, "Back to Library") }
                Text("Storage", fontSize = 34.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                Box {
                    IconButton(
                        onClick = { importMenu = true },
                        modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                    ) { Icon(Icons.Default.Add, "Import songs") }
                    DropdownMenu(expanded = importMenu, onDismissRequest = { importMenu = false }) {
                        DropdownMenuItem(
                            text = { Text("Import from Web") },
                            leadingIcon = { Icon(Icons.Default.Link, null) },
                            onClick = {
                                importMenu = false
                                linkImportOpen = true
                            },
                        )
                        DropdownMenuItem(
                            text = { Text("Import Files") },
                            leadingIcon = { Icon(Icons.Default.Add, null) },
                            onClick = {
                                importMenu = false
                                actions.importAudio()
                            },
                        )
                    }
                }
                Box {
                    IconButton(
                        onClick = { actionsMenu = true },
                        modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                    ) { Icon(Icons.Default.MoreVert, "Song storage actions") }
                    DropdownMenu(expanded = actionsMenu, onDismissRequest = { actionsMenu = false }) {
                        DropdownMenuItem(
                            text = { Text(if (editing) "Done Editing" else "Select Songs") },
                            leadingIcon = { Icon(if (editing) Icons.Default.Check else Icons.Default.Checklist, null) },
                            enabled = state.tracks.isNotEmpty(),
                            onClick = {
                                actionsMenu = false
                                editing = !editing
                                if (!editing) selected = emptySet()
                            },
                        )
                    }
                }
            }
        }
        item {
            StorageSummary(
                importedBytes = importedBytes,
                importedCount = imported.size,
                downloadedBytes = downloadedBytes,
                downloadedCount = downloaded.size,
                availableBytes = state.availableStorageBytes,
            )
        }
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(
                    value = search,
                    onValueChange = { search = it },
                    modifier = Modifier.weight(1f),
                    leadingIcon = { Icon(Icons.Default.Search, null) },
                    placeholder = { Text("Search songs, artists, albums, files…", maxLines = 1) },
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
                        onClick = { filterMenu = true },
                        modifier = Modifier.size(56.dp).background(Color.White.copy(alpha = .055f), RoundedCornerShape(13.dp)),
                    ) { Icon(Icons.Default.FilterList, "Sort") }
                    DropdownMenu(expanded = filterMenu, onDismissRequest = { filterMenu = false }) {
                        StorageSort.entries.forEach { option ->
                            DropdownMenuItem(
                                text = { Text(option.label) },
                                leadingIcon = { if (option == sort) Icon(Icons.Default.Check, null) },
                                onClick = { sort = option; filterMenu = false },
                            )
                        }
                    }
                }
            }
        }
        item {
            SegmentedControl(StorageScope.entries.map { it.label }, scope.ordinal, { scope = StorageScope.entries[it] })
        }
        if (editing && selected.isNotEmpty()) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("${selected.size} selected", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    TextButton(onClick = { confirmDelete = true }) {
                        Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.error)
                        Spacer(Modifier.size(5.dp))
                        Text("Delete", color = MaterialTheme.colorScheme.error)
                    }
                }
            }
        }
        if (visible.isEmpty()) {
            item {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 44.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(
                        Icons.Default.MusicNote,
                        null,
                        Modifier.size(44.dp),
                        tint = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(if (query.isNotEmpty()) "No Results" else "No Stored Songs", style = MaterialTheme.typography.titleMedium)
                    Text("Import audio or video, or download songs from your music server.", color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
                }
            }
        } else {
            if (visibleDownloaded.isNotEmpty()) item {
                StorageSection("Downloaded from server", visibleDownloaded, state, actions, editing, selected, { track ->
                    deleteCandidate = track
                }) { id ->
                    selected = if (id in selected) selected - id else selected + id
                }
            }
            if (visibleImported.isNotEmpty()) item {
                StorageSection("Imported on device", visibleImported, state, actions, editing, selected, { track ->
                    deleteCandidate = track
                }) { id ->
                    selected = if (id in selected) selected - id else selected + id
                }
            }
        }
        item { Spacer(Modifier.height(8.dp)) }
    }

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${selected.size} songs from this device?") },
            text = { Text("This removes the local song files. Songs stored on your server are not deleted.") },
            confirmButton = {
                TextButton(onClick = {
                    actions.deleteTracksFromDevice(selected)
                    selected = emptySet()
                    editing = false
                    confirmDelete = false
                }) { Text("Delete Songs", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
    deleteCandidate?.let { track ->
        AlertDialog(
            onDismissRequest = { deleteCandidate = null },
            title = { Text("Delete ${track.title} from this device?") },
            text = { Text("The server copy, if one exists, will remain available to download again.") },
            confirmButton = {
                TextButton(onClick = {
                    actions.deleteTracksFromDevice(setOf(track.id))
                    deleteCandidate = null
                }) { Text("Delete Song", color = MaterialTheme.colorScheme.error) }
            },
            dismissButton = { TextButton(onClick = { deleteCandidate = null }) { Text("Cancel") } },
        )
    }
    if (linkImportOpen) {
        LinkImportDialog(state, actions) { linkImportOpen = false }
    }
}

@Composable
private fun StorageSummary(
    importedBytes: Long,
    importedCount: Int,
    downloadedBytes: Long,
    downloadedCount: Int,
    availableBytes: Long,
) {
    val usedBytes = importedBytes + downloadedBytes
    val totalBytes = (usedBytes + availableBytes).coerceAtLeast(1L)
    Column(
        modifier = Modifier.fillMaxWidth().background(Color.White.copy(alpha = .045f), RoundedCornerShape(18.dp)).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.Bottom) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("${importedCount + downloadedCount} songs on device", fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                Text("${formatBytes(usedBytes)} used", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
            }
            Text("${formatBytes(availableBytes)} available", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
        }
        LinearProgressIndicator(
            progress = { usedBytes.toFloat() / totalBytes.toFloat() },
            modifier = Modifier.fillMaxWidth(),
            color = MaterialTheme.colorScheme.secondary,
        )
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("$importedCount local", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
            Text("$downloadedCount downloaded", fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
        }
    }
}

@Composable
private fun StorageSection(
    title: String,
    tracks: List<Track>,
    state: ResonanceUiState,
    actions: ResonanceActions,
    editing: Boolean,
    selected: Set<String>,
    onDelete: (Track) -> Unit,
    onToggle: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Row(Modifier.padding(horizontal = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Eyebrow(title, Modifier.weight(1f))
            Text("${tracks.size} ${if (tracks.size == 1) "SONG" else "SONGS"}", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
        }
        Column(Modifier.fillMaxWidth()) {
            SongListHeader(trailingTitle = "Size")
            tracks.forEachIndexed { index, track ->
                TrackRow(
                    track = track,
                    state = state,
                    actions = actions,
                    number = index + 1,
                    queue = tracks,
                    trailingText = formatBytes(state.trackSizesById[track.id] ?: 0),
                    showSelection = editing,
                    selected = track.id in selected,
                    onSelect = { onToggle(track.id) },
                    allowDeleteFromDevice = true,
                    onDeleteFromDevice = { onDelete(track) },
                    showMenu = !editing,
                )
            }
        }
    }
}
