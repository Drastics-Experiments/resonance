package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun LibraryScreen(state: ResonanceUiState, actions: ResonanceActions, modifier: Modifier = Modifier) {
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
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Eyebrow("Music Library")
                    Text("Resonance", fontSize = 38.sp, fontWeight = FontWeight.Normal)
                    Text(
                        "${state.tracks.size} tracks • Stored locally",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
                Artwork(null, Modifier.size(86.dp), showWaveform = true)
            }
        }
        item {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = actions::togglePlayPause,
                    colors = ButtonDefaults.buttonColors(containerColor = Coral),
                    contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, null)
                    Spacer(Modifier.size(7.dp))
                    Text(if (state.isPlaying) "Pause" else "Play", fontWeight = FontWeight.Bold)
                }
                IconButton(
                    onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                    modifier = Modifier
                        .size(46.dp)
                        .background(if (state.shuffleEnabled) Violet else Color.White.copy(alpha = .08f), CircleShape),
                ) { Icon(Icons.Default.Shuffle, "Shuffle") }
                Spacer(Modifier.weight(1f))
                Button(
                    onClick = actions::importAudio,
                    colors = ButtonDefaults.buttonColors(containerColor = Violet),
                ) {
                    Icon(Icons.Default.Add, null)
                    Spacer(Modifier.size(6.dp))
                    Text("Import", fontWeight = FontWeight.Bold)
                }
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
                shape = RoundedCornerShape(13.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = Color.White.copy(alpha = .055f),
                    unfocusedContainerColor = Color.White.copy(alpha = .055f),
                    unfocusedBorderColor = Color.White.copy(alpha = .08f),
                ),
            )
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
                        if (state.tracks.isEmpty()) "Import audio or sync your music server." else "Try another search term.",
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
            }
        } else {
            item {
                Column(
                    modifier = Modifier.fillMaxWidth().background(Color.White.copy(alpha = .035f), RoundedCornerShape(16.dp)),
                ) {
                    tracks.forEach { track ->
                        TrackRow(track, state, actions, queue = tracks)
                    }
                }
            }
        }
        item { Spacer(Modifier.height(8.dp)) }
    }
}
