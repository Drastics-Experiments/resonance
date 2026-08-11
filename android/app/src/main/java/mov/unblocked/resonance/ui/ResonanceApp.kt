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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.PlaylistPlay
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.Icon
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
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
import mov.unblocked.resonance.update.AndroidUpdateInfo
import mov.unblocked.resonance.update.AndroidUpdateState

@Composable
fun ResonanceApp(
    state: ResonanceUiState,
    actions: ResonanceActions,
    updateState: AndroidUpdateState = AndroidUpdateState.Idle,
    onDownloadUpdate: (AndroidUpdateInfo) -> Unit = {},
    onInstallUpdate: (AndroidUpdateInfo) -> Unit = {},
    onDismissUpdate: () -> Unit = {},
) {
    ResonanceTheme(state.themeChoice) {
        var selectedTab by rememberSaveable { mutableStateOf(ResonanceTab.Library) }
        var openPlaylistId by rememberSaveable { mutableStateOf<String?>(null) }
        var showNowPlaying by rememberSaveable { mutableStateOf(false) }
        val focusManager = LocalFocusManager.current
        val palette = LocalResonancePalette.current
        val navigationItemColors = NavigationBarItemDefaults.colors(
            selectedIconColor = MaterialTheme.colorScheme.onSecondaryContainer,
            selectedTextColor = MaterialTheme.colorScheme.onSurface,
            indicatorColor = MaterialTheme.colorScheme.secondaryContainer,
            unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
            unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
            disabledIconColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .38f),
            disabledTextColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = .38f),
        )

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
                            NavigationBar(containerColor = palette.panel.copy(alpha = .96f)) {
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
                                        colors = navigationItemColors,
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
                visible = shouldShowTransferPopup(state),
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
            val errorMessage = state.errorMessage
            if (errorMessage != null) {
                AlertDialog(
                    onDismissRequest = actions::dismissError,
                    title = { Text("Resonance") },
                    text = { Text(errorMessage) },
                    confirmButton = { TextButton(onClick = actions::dismissError) { Text("OK") } },
                )
            } else {
                AndroidUpdateDialog(
                    state = updateState,
                    onDownload = onDownloadUpdate,
                    onInstall = onInstallUpdate,
                    onDismiss = onDismissUpdate,
                )
            }
        }
    }
}

internal fun shouldShowTransferPopup(state: ResonanceUiState): Boolean =
    state.isDownloading || state.isUploading

@Composable
private fun AndroidUpdateDialog(
    state: AndroidUpdateState,
    onDownload: (AndroidUpdateInfo) -> Unit,
    onInstall: (AndroidUpdateInfo) -> Unit,
    onDismiss: () -> Unit,
) {
    when (state) {
        AndroidUpdateState.Idle, AndroidUpdateState.Checking -> Unit

        is AndroidUpdateState.Available -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Update available") },
            text = {
                Column {
                    Text("Resonance ${state.update.versionName} is ready to download.")
                    state.update.releaseNotes?.let { notes ->
                        Text(notes, modifier = Modifier.padding(top = 12.dp))
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = { onDownload(state.update) }) { Text("Update") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Later") } },
        )

        is AndroidUpdateState.Downloading -> AlertDialog(
            onDismissRequest = {},
            title = { Text("Downloading update") },
            text = {
                Column {
                    Text("Resonance ${state.update.versionName}")
                    if (state.progress == null) {
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                        )
                    } else {
                        LinearProgressIndicator(
                            progress = { state.progress },
                            modifier = Modifier.fillMaxWidth().padding(top = 16.dp),
                        )
                    }
                }
            },
            confirmButton = {},
        )

        is AndroidUpdateState.ReadyToInstall -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Ready to install") },
            text = {
                Text("Android will ask you to confirm the Resonance ${state.update.versionName} update.")
            },
            confirmButton = {
                TextButton(onClick = { onInstall(state.update) }) { Text("Install") }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Later") } },
        )

        is AndroidUpdateState.Failed -> AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("Update failed") },
            text = { Text(state.message) },
            confirmButton = {
                state.update?.let { update ->
                    TextButton(onClick = { onDownload(update) }) { Text("Retry") }
                }
            },
            dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } },
        )
    }
}
