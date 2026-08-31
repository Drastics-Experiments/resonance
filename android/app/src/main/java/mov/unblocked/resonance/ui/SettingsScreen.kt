package mov.unblocked.resonance.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cloud
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import mov.unblocked.resonance.BuildConfig
import mov.unblocked.resonance.data.AccountEmailPrivacy

@Composable
fun SettingsScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onDismiss: () -> Unit,
    developerMode: Boolean = false,
    onDeveloperModeChanged: (Boolean) -> Unit = {},
) {
    var connectionOpen by remember { mutableStateOf(false) }
    var appearanceOpen by remember { mutableStateOf(false) }
    val displayName = AccountEmailPrivacy.safeDisplayName(
        state.accountDisplayName ?: activeSyncProfileName(state),
        state.accountEmail,
    )
    val accountStatus = when {
        state.accountRole == "admin" -> "Administrator"
        state.accountEmail != null -> "Member"
        state.serverToken.isNotBlank() -> "Legacy connection"
        else -> "Not signed in"
    }

    ResonanceBackground {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Settings", fontSize = 28.sp, fontWeight = FontWeight.Bold)
                    Text(
                        "Manage how Resonance behaves on this Android device.",
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        fontSize = 11.sp,
                    )
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(40.dp)) {
                    Surface(shape = CircleShape, color = Color.White.copy(alpha = .07f)) {
                        Icon(
                            Icons.Default.Close,
                            contentDescription = "Close settings",
                            modifier = Modifier.padding(10.dp),
                        )
                    }
                }
            }

            HorizontalDivider(color = Color.White.copy(alpha = .08f))

            LazyColumn(
                modifier = Modifier.weight(1f),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp),
            ) {
                item { SettingsIdentityCard(displayName, accountStatus) }

                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SettingsSectionHeading("PLAYBACK", "Defaults saved on this device.")
                        SettingsCard {
                            VolumeSettings(state, actions)
                            SettingsDivider()
                            CrossfadeSettings(state, actions)
                        }
                    }
                }

                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SettingsSectionHeading("APP", "Connection and mobile playback behavior.")
                        SettingsCard {
                            SettingsRow(
                                icon = Icons.Default.Palette,
                                title = "Appearance",
                                detail = "Choose a color theme for this device.",
                                trailing = state.themeChoice.label,
                                onClick = { appearanceOpen = true },
                            )
                            SettingsDivider()
                            SettingsRow(
                                icon = Icons.Default.Cloud,
                                title = "Music Server",
                                detail = if (state.isConnected) "Connected as $displayName" else state.serverMessage,
                                trailing = "Configure",
                                onClick = { connectionOpen = true },
                            )
                            SettingsDivider()
                            SettingsRow(
                                icon = Icons.Default.MusicNote,
                                title = "Background Audio",
                                detail = "Playback continues while Resonance is in the background.",
                                trailing = "Enabled",
                            )
                            SettingsDivider()
                            SettingsRow(
                                icon = Icons.Default.Refresh,
                                title = "Refresh song metadata",
                                detail = state.downloadedMetadataRefreshDetail,
                                trailing = if (state.isRefreshingDownloadedMetadata) "Refreshing…" else "Refresh",
                                onClick = if (state.isRefreshingDownloadedMetadata) {
                                    null
                                } else {
                                    actions::refreshDownloadedSongMetadata
                                },
                            )
                            SettingsDivider()
                            DeveloperModeSettings(
                                enabled = developerMode,
                                onEnabledChanged = onDeveloperModeChanged,
                            )
                        }
                    }
                }

                item {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        SettingsSectionHeading("ABOUT", "Installed application information.")
                        SettingsCard {
                            SettingsRow(
                                icon = Icons.Default.Info,
                                title = "Resonance",
                                detail = "Android",
                                trailing = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                            )
                        }
                    }
                }
            }

            HorizontalDivider(color = Color.White.copy(alpha = .08f))
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
                horizontalArrangement = Arrangement.End,
            ) {
                Button(
                    onClick = onDismiss,
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.secondary,
                    ),
                    contentPadding = PaddingValues(horizontal = 24.dp, vertical = 10.dp),
                ) {
                    Text("Done", fontWeight = FontWeight.Bold)
                }
            }
        }
    }

    if (connectionOpen) {
        ConnectionDialog(state, actions) { connectionOpen = false }
    }
    if (appearanceOpen) {
        AppearanceDialog(
            selected = state.themeChoice,
            onSelected = actions::setThemeChoice,
            onDismiss = { appearanceOpen = false },
        )
    }
}

@Composable
private fun DeveloperModeSettings(
    enabled: Boolean,
    onEnabledChanged: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onEnabledChanged(!enabled) }
            .padding(horizontal = 15.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SettingsIcon(Icons.Default.Code)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("Developer Mode", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(
                if (enabled) {
                    "Check prerelease updates instead of stable releases."
                } else {
                    "Check stable releases only."
                },
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                fontSize = 11.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Switch(
            checked = enabled,
            onCheckedChange = onEnabledChanged,
        )
    }
}

@Composable
private fun VolumeSettings(state: ResonanceUiState, actions: ResonanceActions) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Default.VolumeUp,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.tertiary,
            )
            Text(
                "Volume",
                modifier = Modifier.padding(start = 12.dp),
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "${(state.volume * 100).roundToInt()}%",
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .62f),
                fontSize = 12.sp,
            )
        }
        Slider(
            value = state.volume,
            onValueChange = actions::setVolume,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun CrossfadeSettings(state: ResonanceUiState, actions: ResonanceActions) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 13.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SettingsIcon(Icons.Default.GraphicEq)
            Column(
                modifier = Modifier.weight(1f).padding(start = 12.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Text("Crossfade", fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                Text(
                    if (state.crossfadeEnabled) {
                        "Overlap songs by ${state.crossfadeSeconds.roundToInt()} seconds."
                    } else {
                        "Start the next song early while fading between both."
                    },
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                    fontSize = 11.sp,
                )
            }
            Switch(
                checked = state.crossfadeEnabled,
                onCheckedChange = actions::setCrossfadeEnabled,
            )
        }
        Slider(
            value = state.crossfadeSeconds,
            onValueChange = actions::setCrossfadeSeconds,
            valueRange = 1f..12f,
            steps = 10,
            enabled = state.crossfadeEnabled,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun SettingsIdentityCard(displayName: String, accountStatus: String) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = Color.White.copy(alpha = .055f),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .09f)),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(13.dp),
        ) {
            Surface(
                modifier = Modifier.size(48.dp),
                shape = CircleShape,
                color = MaterialTheme.colorScheme.secondary,
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(
                        syncProfileInitial(displayName),
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 17.sp,
                    )
                }
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    displayName,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    accountStatus,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    fontSize = 12.sp,
                )
            }
        }
    }
}

@Composable
private fun SettingsSectionHeading(label: String, detail: String) {
    Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            label,
            color = MaterialTheme.colorScheme.tertiary,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.5.sp,
        )
        Text(
            detail,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .56f),
            fontSize = 12.sp,
        )
    }
}

@Composable
private fun SettingsCard(content: @Composable ColumnScope.() -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = LocalResonancePalette.current.panel,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .09f)),
    ) {
        Column(content = content)
    }
}

@Composable
private fun SettingsIcon(icon: ImageVector) {
    Surface(
        modifier = Modifier.size(38.dp),
        shape = RoundedCornerShape(10.dp),
        color = MaterialTheme.colorScheme.primary.copy(alpha = .11f),
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.tertiary,
            modifier = Modifier.padding(9.dp),
        )
    }
}

@Composable
private fun SettingsRow(
    icon: ImageVector,
    title: String,
    detail: String,
    trailing: String,
    onClick: (() -> Unit)? = null,
) {
    val interactionModifier = if (onClick == null) Modifier else Modifier.clickable(onClick = onClick)
    Row(
        modifier = interactionModifier.fillMaxWidth().padding(horizontal = 15.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SettingsIcon(icon)
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
            Text(
                detail,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f),
                fontSize = 11.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            trailing,
            color = if (onClick == null) {
                MaterialTheme.colorScheme.onSurface.copy(alpha = .58f)
            } else {
                MaterialTheme.colorScheme.tertiary
            },
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun SettingsDivider() {
    HorizontalDivider(color = Color.White.copy(alpha = .08f))
}
