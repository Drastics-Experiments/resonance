package mov.unblocked.resonance.ui

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Track

@Composable
fun StorageScreen(state: ResonanceUiState, actions: ResonanceActions, modifier: Modifier = Modifier) {
    val focusManager = LocalFocusManager.current
    var search by remember { mutableStateOf("") }
    var scope by remember { mutableStateOf(StorageScope.Songs) }
    var sort by remember { mutableStateOf(StorageSort.Title) }
    var filterMenu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var confirmDelete by remember { mutableStateOf(false) }

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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Song Storage", fontSize = 36.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                TextButton(
                    enabled = state.tracks.isNotEmpty(),
                    onClick = {
                        editing = !editing
                        if (!editing) selected = emptySet()
                    },
                ) { Text(if (editing) "Done" else "Edit", fontWeight = FontWeight.SemiBold) }
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
                    Icon(Icons.Default.MusicNote, null, Modifier.size(44.dp), tint = Violet)
                    Text(if (query.isNotEmpty()) "No Results" else "No Stored Songs", style = MaterialTheme.typography.titleMedium)
                    Text("Import audio or download songs from your music server.", color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
                }
            }
        } else {
            if (visibleDownloaded.isNotEmpty()) item {
                StorageSection("Downloaded from server", visibleDownloaded, state, actions, editing, selected) { id ->
                    selected = if (id in selected) selected - id else selected + id
                }
            }
            if (visibleImported.isNotEmpty()) item {
                StorageSection("Imported on Android", visibleImported, state, actions, editing, selected) { id ->
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
}

@Composable
private fun StorageSummary(
    importedBytes: Long,
    importedCount: Int,
    downloadedBytes: Long,
    downloadedCount: Int,
    availableBytes: Long,
) {
    val total = (importedBytes + downloadedBytes + availableBytes).coerceAtLeast(1).toFloat()
    val importedSweep = importedBytes / total * 360f
    val downloadedSweep = downloadedBytes / total * 360f
    Row(
        modifier = Modifier.fillMaxWidth().background(Color.White.copy(alpha = .045f), RoundedCornerShape(20.dp)).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.fillMaxSize()) {
                drawArc(Color.White.copy(alpha = .08f), -90f, 360f, false, style = Stroke(14.dp.toPx()))
                if (importedSweep > 0) drawArc(Violet, -90f, importedSweep, false, style = Stroke(14.dp.toPx(), cap = StrokeCap.Butt))
                if (downloadedSweep > 0) drawArc(Accent, -90f + importedSweep, downloadedSweep, false, style = Stroke(14.dp.toPx(), cap = StrokeCap.Butt))
            }
            Icon(Icons.Default.MusicNote, null, tint = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(9.dp)) {
            Text("Local audio", fontSize = 13.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .6f))
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                StorageMetric(Violet, "Local", importedBytes, "$importedCount files", Modifier.weight(1f))
                StorageMetric(Accent, "Server", downloadedBytes, "$downloadedCount files", Modifier.weight(1f))
                StorageMetric(ElectricBlue, "Available", availableBytes, "on device", Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun StorageMetric(color: Color, label: String, bytes: Long, detail: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.size(7.dp).background(color, CircleShape))
            Text(label, fontSize = 10.sp, maxLines = 1)
        }
        Text(formatBytes(bytes), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(detail, fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f), maxLines = 1)
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
    onToggle: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Row(Modifier.padding(horizontal = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Eyebrow(title, Modifier.weight(1f))
            Text("${tracks.size} ${if (tracks.size == 1) "SONG" else "SONGS"}", fontSize = 10.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f))
        }
        Column(Modifier.fillMaxWidth().background(Color.White.copy(alpha = .045f), RoundedCornerShape(16.dp))) {
            tracks.forEach { track ->
                TrackRow(
                    track = track,
                    state = state,
                    actions = actions,
                    queue = tracks,
                    trailingText = formatBytes(state.trackSizesById[track.id] ?: 0),
                    showSelection = editing,
                    selected = track.id in selected,
                    onSelect = { onToggle(track.id) },
                    allowDeleteFromDevice = false,
                    showFavorite = false,
                    showMenu = false,
                )
            }
        }
    }
}
