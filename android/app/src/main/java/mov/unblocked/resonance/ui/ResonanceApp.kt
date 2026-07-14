package mov.unblocked.resonance.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.unit.dp

@Composable
fun ResonanceApp(state: ResonanceUiState, actions: ResonanceActions) {
    ResonanceTheme {
        var selectedTab by rememberSaveable { mutableStateOf(ResonanceTab.Library) }
        var openPlaylistId by rememberSaveable { mutableStateOf<String?>(null) }
        var showNowPlaying by rememberSaveable { mutableStateOf(false) }
        val focusManager = LocalFocusManager.current

        BackHandler(enabled = showNowPlaying) { showNowPlaying = false }
        BackHandler(enabled = !showNowPlaying && openPlaylistId != null) { openPlaylistId = null }

        Box(Modifier.fillMaxSize()) {
            ResonanceBackground {
                Scaffold(
                    containerColor = Color.Transparent,
                    contentColor = MaterialTheme.colorScheme.onBackground,
                    bottomBar = {
                        Column {
                            if (state.currentTrack != null) {
                                MiniPlayer(state, actions, onOpen = { showNowPlaying = true })
                            }
                            NavigationBar(containerColor = Color(0xF5050609)) {
                                ResonanceTab.entries.forEach { tab ->
                                    val icon = when (tab) {
                                        ResonanceTab.Library -> Icons.Default.LibraryMusic
                                        ResonanceTab.Playlists -> Icons.Default.PlaylistPlay
                                        ResonanceTab.Storage -> Icons.Default.Storage
                                        ResonanceTab.Server -> Icons.Default.Cloud
                                    }
                                    NavigationBarItem(
                                        selected = selectedTab == tab,
                                        onClick = {
                                            focusManager.clearFocus()
                                            selectedTab = tab
                                            if (tab != ResonanceTab.Playlists) openPlaylistId = null
                                        },
                                        icon = { Icon(icon, tab.label) },
                                        label = { Text(tab.label) },
                                    )
                                }
                            }
                        }
                    },
                ) { insets ->
                    when (selectedTab) {
                        ResonanceTab.Library -> LibraryScreen(state, actions, Modifier.padding(insets))
                        ResonanceTab.Playlists -> PlaylistsScreen(
                            state = state,
                            actions = actions,
                            openPlaylistId = openPlaylistId,
                            onOpenPlaylist = { openPlaylistId = it },
                            onClosePlaylist = { openPlaylistId = null },
                            modifier = Modifier.padding(insets),
                        )
                        ResonanceTab.Storage -> StorageScreen(state, actions, Modifier.padding(insets))
                        ResonanceTab.Server -> ServerScreen(state, actions, Modifier.padding(insets))
                    }
                }
            }
            AnimatedVisibility(
                visible = state.isDownloading || state.isUploading || state.isSyncingPlaylists,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 18.dp)
                    .padding(bottom = if (state.currentTrack != null) 158.dp else 86.dp),
                enter = fadeIn() + slideInVertically { it / 2 },
                exit = fadeOut() + slideOutVertically { it / 2 },
            ) {
                TransferPopup(state)
            }
            if (showNowPlaying && state.currentTrack != null) {
                NowPlayingScreen(state, actions, onDismiss = { showNowPlaying = false })
            }
            state.errorMessage?.let { message ->
                AlertDialog(
                    onDismissRequest = actions::dismissError,
                    title = { Text("Resonance") },
                    text = { Text(message) },
                    confirmButton = { TextButton(onClick = actions::dismissError) { Text("OK") } },
                )
            }
        }
    }
}
