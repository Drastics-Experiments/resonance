package mov.unblocked.resonance.ui

import android.graphics.BitmapFactory
import java.net.HttpURLConnection
import java.net.URL
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.Image
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.data.AccountEmailPrivacy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun LibraryScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    modifier: Modifier = Modifier,
    onOpenStorage: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    var clipEditorOpen by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val query = state.librarySearch.trim()
    val tracks = if (query.isEmpty()) state.tracks else state.tracks.filter {
        it.title.contains(query, true) || it.artist.contains(query, true) ||
            it.album.contains(query, true) || it.relativePath.contains(query, true)
    }
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Library", fontSize = 36.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "${state.tracks.size} songs on this device",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
                IconButton(
                    onClick = onOpenStorage,
                    modifier = Modifier.size(44.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                ) { Icon(Icons.Default.Storage, "Storage") }
                ProfileButton(
                    state = state,
                    onSettings = onOpenSettings,
                    onClipEditor = { clipEditorOpen = true },
                )
            }
        }
        item {
            OutlinedTextField(
                value = state.librarySearch,
                onValueChange = actions::setLibrarySearch,
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Search your music") },
                leadingIcon = { Icon(Icons.Default.Search, null) },
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
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    enabled = state.tracks.isNotEmpty(),
                    onClick = actions::togglePlayPause,
                    colors = ButtonDefaults.buttonColors(containerColor = Accent),
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, null)
                    Spacer(Modifier.size(7.dp))
                    Text(if (state.isPlaying) "Pause" else "Play", fontWeight = FontWeight.Bold)
                }
                IconButton(
                    enabled = state.tracks.isNotEmpty() && !state.isTransientPlayback,
                    onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                    modifier = Modifier
                        .size(46.dp)
                        .background(
                            if (state.shuffleEnabled && !state.isTransientPlayback) Violet
                            else Color.White.copy(alpha = .08f),
                            CircleShape,
                        ),
                ) { Icon(Icons.Default.Shuffle, "Shuffle") }
                Spacer(Modifier.weight(1f))
            }
        }
        val recentlyAdded = recentlyAddedTracks(state.tracks)
        if (query.isEmpty() && recentlyAdded.isNotEmpty()) {
            item {
                RecentlyAddedSection(
                    tracks = recentlyAdded,
                    state = state,
                    actions = actions,
                )
            }
        }
        if (tracks.isEmpty()) {
            item {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 48.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Icon(Icons.Default.MusicNote, null, Modifier.size(44.dp), tint = Violet)
                    Text(if (state.tracks.isEmpty()) "No songs yet" else "No results", style = MaterialTheme.typography.titleMedium)
                    Text(
                        if (state.tracks.isEmpty()) "Import audio or video, or sync your music server." else "Try another search term.",
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
            }
        } else {
            item {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text("All Songs", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        Text(
                            tracks.size.toString(),
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                        )
                    }
                    tracks.forEachIndexed { index, track ->
                        TrackRow(track, state, actions, number = index + 1, queue = tracks)
                    }
                }
            }
        }
        item { Spacer(Modifier.height(8.dp)) }
    }

    if (clipEditorOpen) {
        ClipEditorDialog(state, actions) { clipEditorOpen = false }
    }
}

@Composable
private fun ProfileButton(
    state: ResonanceUiState,
    onSettings: () -> Unit,
    onClipEditor: () -> Unit,
) {
    val profileName = AccountEmailPrivacy.safeDisplayName(
        state.accountDisplayName ?: activeSyncProfileName(state),
        state.accountEmail,
    )
    var expanded by remember { mutableStateOf(false) }
    var isEmailRevealed by remember(state.accountEmail) { mutableStateOf(false) }
    val profileBitmap = rememberAccountImage(state.accountImageURL)
    Box {
        IconButton(
            onClick = { expanded = true },
            modifier = Modifier
                .size(44.dp)
                .background(Violet, CircleShape)
                .semantics {
                    contentDescription = "Profile: $profileName. Open profile tools"
                },
        ) {
            if (profileBitmap != null) {
                Image(
                    bitmap = profileBitmap,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().clearAndSetSemantics { },
                )
            } else {
                Text(
                    text = syncProfileInitial(profileName),
                    color = Color.White,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.clearAndSetSemantics { },
                )
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            if (state.accountEmail != null) {
                DropdownMenuItem(
                    text = {
                        Text(AccountEmailPrivacy.displayedAddress(state.accountEmail, isEmailRevealed))
                    },
                    onClick = { isEmailRevealed = !isEmailRevealed },
                )
            }
            DropdownMenuItem(
                text = { Text("Clip Editor") },
                leadingIcon = { Icon(Icons.Default.GraphicEq, null) },
                onClick = {
                    expanded = false
                    onClipEditor()
                },
            )
            DropdownMenuItem(
                text = { Text("Settings") },
                leadingIcon = { Icon(Icons.Default.Settings, null) },
                onClick = {
                    expanded = false
                    onSettings()
                },
            )
        }
    }
}

@Composable
private fun rememberAccountImage(imageURL: String?): androidx.compose.ui.graphics.ImageBitmap? {
    val bitmap by produceState<androidx.compose.ui.graphics.ImageBitmap?>(null, imageURL) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                val url = URL(imageURL?.takeIf(String::isNotBlank) ?: return@runCatching null)
                require(url.protocol.equals("https", ignoreCase = true))
                val connection = url.openConnection() as HttpURLConnection
                try {
                    connection.connectTimeout = 5_000
                    connection.readTimeout = 5_000
                    connection.instanceFollowRedirects = true
                    connection.connect()
                    require(connection.responseCode in 200..299)
                    require(connection.contentLengthLong <= 5 * 1024 * 1024 || connection.contentLengthLong < 0)
                    connection.inputStream.use { BitmapFactory.decodeStream(it)?.asImageBitmap() }
                } finally {
                    connection.disconnect()
                }
            }.getOrNull()
        }
    }
    return bitmap
}

@Composable
private fun RecentlyAddedSection(
    tracks: List<Track>,
    state: ResonanceUiState,
    actions: ResonanceActions,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Eyebrow("Recently Added")
        LazyRow(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(tracks, key = Track::id) { track ->
                Column(
                    modifier = Modifier
                        .width(132.dp)
                        .clickable { actions.playTrack(track.id, state.tracks.map(Track::id)) },
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    Artwork(
                        path = state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
                        modifier = Modifier.size(132.dp),
                        showWaveform = state.currentTrackId == track.id && state.isPlaying,
                    )
                    Text(
                        text = track.title,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = track.artist,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

internal fun activeSyncProfileName(state: ResonanceUiState): String =
    AccountEmailPrivacy.safeDisplayName(
        state.syncProfiles
        .firstOrNull { it.id == state.syncProfileId }
        ?.name
        ?.trim()
        ?.takeIf(String::isNotEmpty)
            ?: "Default",
        state.accountEmail,
    )

internal fun syncProfileInitial(name: String): String =
    name.trim().firstOrNull(Char::isLetterOrDigit)?.uppercase() ?: "?"

internal fun recentlyAddedTracks(tracks: List<Track>, limit: Int = 6): List<Track> {
    if (limit <= 0) return emptyList()
    return tracks.sortedByDescending(Track::dateAddedEpochMs).take(limit)
}
