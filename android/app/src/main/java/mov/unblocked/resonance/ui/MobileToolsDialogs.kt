package mov.unblocked.resonance.ui

import android.graphics.Bitmap
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.HelpOutline
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.io.File
import java.nio.ByteOrder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import mov.unblocked.resonance.data.LinkImportStage
import mov.unblocked.resonance.data.LinkImportInput
import mov.unblocked.resonance.data.ServerUploadMode
import mov.unblocked.resonance.data.LinkImportKind
import mov.unblocked.resonance.data.LinkImportMediaMode
import mov.unblocked.resonance.data.LinkImportSearchProvider
import mov.unblocked.resonance.data.LinkImportSearchResponse
import mov.unblocked.resonance.data.LinkImportSearchResult
import mov.unblocked.resonance.data.LinkImportSourceProvider
import mov.unblocked.resonance.data.LinkImportExistingPolicy
import mov.unblocked.resonance.data.Track
import mov.unblocked.resonance.playback.PlaybackVolumePolicy

@Composable
fun ClipEditorDialog(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val palette = LocalResonancePalette.current
    var selectedTrackId by remember { mutableStateOf(state.currentTrackId ?: state.tracks.firstOrNull()?.id) }
    val selectedTrack = state.tracks.firstOrNull { it.id == selectedTrackId }
    var startMs by remember { mutableLongStateOf(0L) }
    var endMs by remember { mutableLongStateOf(selectedTrack?.durationMs?.takeIf { it > 0L } ?: 0L) }
    var startText by remember { mutableStateOf("0:00") }
    var endText by remember { mutableStateOf(selectedTrack?.durationMs?.let(::clipTime) ?: "0:00") }
    var previewing by remember { mutableStateOf(false) }
    var previewPositionMs by remember { mutableLongStateOf(0L) }
    var resumeMainAfterPreview by remember { mutableStateOf(false) }
    var settingsOpen by remember { mutableStateOf(false) }
    var helpOpen by remember { mutableStateOf(false) }
    var previewExpanded by remember { mutableStateOf(false) }
    var waveformSamples by remember { mutableStateOf<List<Float>>(emptyList()) }
    var videoFrames by remember { mutableStateOf<List<Bitmap>>(emptyList()) }
    var savedStartMs by remember { mutableLongStateOf(0L) }
    var savedEndMs by remember { mutableLongStateOf(0L) }
    var saveMessage by remember { mutableStateOf<String?>(null) }
    val previewPlayer = remember { ExoPlayer.Builder(context).build() }

    fun updateTexts() {
        startText = clipTime(startMs)
        endText = clipTime(endMs)
    }

    fun resetRange(track: Track?) {
        if (track == null || track.durationMs <= 0L) {
            startMs = 0L
            endMs = 0L
            previewPositionMs = 0L
            startText = "--:--"
            endText = "--:--"
            return
        }
        val saved = state.clipRangesByTrackId[track.id]
        val defaultStart = if (track.durationMs > 60_000) 15_000L else 0L
        startMs = saved?.startMs ?: defaultStart
        endMs = saved?.endMs ?: minOf(track.durationMs, defaultStart + 45_000L)
        savedStartMs = saved?.startMs ?: 0L
        savedEndMs = saved?.endMs ?: track.durationMs
        if (endMs - startMs < 250) {
            startMs = 0
            endMs = track.durationMs
        }
        previewPositionMs = startMs
        saveMessage = null
        updateTexts()
    }

    fun stopPreview(resumeMain: Boolean = true) {
        previewPlayer.pause()
        previewing = false
        if (resumeMain && resumeMainAfterPreview) actions.togglePlayPause()
        resumeMainAfterPreview = false
    }

    DisposableEffect(Unit) {
        onDispose {
            previewPlayer.release()
            if (resumeMainAfterPreview) actions.togglePlayPause()
        }
    }
    LaunchedEffect(state.volume) {
        previewPlayer.volume = PlaybackVolumePolicy.gainForSlider(state.volume)
    }
    LaunchedEffect(selectedTrackId) {
        stopPreview()
        resetRange(selectedTrack)
        val path = selectedTrack?.let { state.trackFilePathsById[it.id] }
        waveformSamples = emptyList()
        videoFrames = emptyList()
        if (path != null) {
            previewPlayer.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
            previewPlayer.prepare()
            previewPlayer.seekTo(startMs)
            if (selectedTrack?.let(::isVideoClipTrack) == true) {
                videoFrames = extractAndroidClipVideoFrames(path, selectedTrack.durationMs)
            } else {
                waveformSamples = extractAndroidClipWaveform(path)
            }
        } else {
            previewPlayer.clearMediaItems()
        }
    }
    LaunchedEffect(previewing, endMs) {
        while (previewing) {
            previewPositionMs = previewPlayer.currentPosition.coerceIn(startMs, endMs)
            if (previewPlayer.playbackState == Player.STATE_ENDED || previewPlayer.currentPosition + 20 >= endMs) {
                if (previewPlayer.currentPosition + 20 >= endMs) previewPositionMs = endMs
                stopPreview()
                break
            }
            delay(50)
        }
    }

    Dialog(
        onDismissRequest = {
            stopPreview()
            onDismiss()
        },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(palette.background.copy(alpha = .92f))
                .padding(horizontal = 8.dp, vertical = 10.dp),
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = palette.surface,
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, Color.White.copy(alpha = .08f)),
                tonalElevation = 8.dp,
            ) {
                Column(Modifier.fillMaxSize()) {
                    ClipEditorHeader(
                        selectedTrack = selectedTrack,
                        tracks = state.tracks,
                        saveEnabled = selectedTrack?.durationMs?.let { it >= 250 } == true
                            && (startMs != savedStartMs || endMs != savedEndMs),
                        onTrackSelected = { selectedTrackId = it },
                        onDone = {
                            focus.clearFocus()
                            stopPreview()
                            onDismiss()
                        },
                        onSave = {
                            val track = selectedTrack ?: return@ClipEditorHeader
                            focus.clearFocus()
                            stopPreview()
                            if (startMs <= 0L && endMs >= track.durationMs) {
                                actions.clearClipRange(track.id)
                                savedStartMs = 0L
                                savedEndMs = track.durationMs
                                saveMessage = "Saved full-song playback for ${activeSyncProfileName(state)}."
                            } else {
                                actions.saveClipRange(track.id, startMs, endMs)
                                savedStartMs = startMs
                                savedEndMs = endMs
                                saveMessage = "Saved ${clipTime(startMs)}–${clipTime(endMs)} for ${activeSyncProfileName(state)}."
                            }
                        },
                        onHelp = { helpOpen = !helpOpen; settingsOpen = false },
                        onSettings = { settingsOpen = !settingsOpen; helpOpen = false },
                    )

                    if (selectedTrack == null) {
                        ToolEmpty(
                            "No songs to edit",
                            "Import or download a song, then return to create a playback range.",
                        )
                    } else {
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .verticalScroll(rememberScrollState())
                                .padding(horizontal = 10.dp, vertical = 4.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            if (selectedTrack.durationMs <= 0L) {
                                Text(
                                    "Resonance couldn't read this song's duration. Re-import it or repair its metadata before setting a clip range.",
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                                    fontSize = 13.sp,
                                )
                            } else {
                                ClipPreviewStage(
                                    track = selectedTrack,
                                    artworkPath = state.artworkPathsByTrackId[selectedTrack.id],
                                    player = previewPlayer,
                                    isPlaying = previewing,
                                    expanded = previewExpanded,
                                    positionMs = previewPositionMs,
                                    endMs = endMs,
                                    enabled = state.trackFilePathsById[selectedTrack.id] != null,
                                    onToggle = {
                                        if (previewing) {
                                            stopPreview()
                                        } else {
                                            resumeMainAfterPreview = state.isPlaying
                                            if (state.isPlaying) actions.togglePlayPause()
                                            if (previewPositionMs !in startMs until endMs) {
                                                previewPositionMs = startMs
                                                previewPlayer.seekTo(startMs)
                                            }
                                            previewPlayer.play()
                                            previewing = true
                                        }
                                    },
                                    onSkipStart = {
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                    },
                                    onSkipEnd = {
                                        previewPositionMs = (endMs - 10).coerceAtLeast(startMs)
                                        previewPlayer.seekTo(previewPositionMs)
                                    },
                                    onExpand = { previewExpanded = !previewExpanded },
                                )

                                if (!previewExpanded) {
                                    ClipTimeline(
                                        track = selectedTrack,
                                        waveformSamples = waveformSamples,
                                        videoFrames = videoFrames,
                                        startMs = startMs,
                                        endMs = endMs,
                                        playheadMs = previewPositionMs,
                                        onRangeChange = { start, end ->
                                            stopPreview()
                                            startMs = start
                                            endMs = end
                                            previewPositionMs = start
                                            previewPlayer.seekTo(start)
                                            updateTexts()
                                            saveMessage = null
                                        },
                                        onSeek = { position ->
                                            previewPositionMs = position
                                            previewPlayer.seekTo(position)
                                        },
                                    )
                                }

                                Text(
                                    saveMessage ?: "Save before closing. The media file is never changed.",
                                    modifier = Modifier.padding(horizontal = 3.dp, vertical = 2.dp),
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .54f),
                                    fontSize = 12.sp,
                                )
                            }
                        }
                    }
                }
            }

            if (settingsOpen && selectedTrack != null) {
                ClipEditorOverlay(onOutsideClick = { settingsOpen = false }) {
                    Column(verticalArrangement = Arrangement.spacedBy(13.dp)) {
                        ClipOverlayHeader("Clip settings") { settingsOpen = false }
                        ClipSettingsTrackSummary(
                            track = selectedTrack,
                            artworkPath = state.artworkPathsByTrackId[selectedTrack.id],
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            ClipTimeField(
                                "Start",
                                startText,
                                { startText = it },
                                {
                                    parseClipTime(startText)?.let {
                                        stopPreview()
                                        startMs = it.coerceIn(0, (endMs - 250).coerceAtLeast(0))
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                    }
                                    updateTexts()
                                    saveMessage = null
                                },
                                Modifier.weight(1f),
                            )
                            ClipTimeField(
                                "End",
                                endText,
                                { endText = it },
                                {
                                    parseClipTime(endText)?.let {
                                        stopPreview()
                                        endMs = it.coerceIn(startMs + 250, selectedTrack.durationMs)
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                    }
                                    updateTexts()
                                    saveMessage = null
                                },
                                Modifier.weight(1f),
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column {
                                SectionLabel("Clip length")
                                Text(clipTime(endMs - startMs), color = palette.tertiary, fontWeight = FontWeight.Bold)
                            }
                            Spacer(Modifier.weight(1f))
                            OutlinedButton(onClick = {
                                stopPreview()
                                startMs = 0
                                endMs = selectedTrack.durationMs
                                previewPositionMs = startMs
                                previewPlayer.seekTo(startMs)
                                updateTexts()
                                saveMessage = null
                            }) { Text("Use full song") }
                        }
                    }
                }
            }

            if (helpOpen) {
                ClipEditorOverlay(onOutsideClick = { helpOpen = false }) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        ClipOverlayHeader("How it works") { helpOpen = false }
                        Text(
                            "Drag the handles to choose a range, or tap the timeline to seek. Use the playback controls to preview it.",
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                            fontSize = 13.sp,
                        )
                        Text(
                            "Save stores the range for the active profile without editing the media file. Closing discards unsaved changes.",
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                            fontSize = 13.sp,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ClipEditorHeader(
    selectedTrack: Track?,
    tracks: List<Track>,
    saveEnabled: Boolean,
    onTrackSelected: (String) -> Unit,
    onDone: () -> Unit,
    onSave: () -> Unit,
    onHelp: () -> Unit,
    onSettings: () -> Unit,
) {
    var trackMenu by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier.fillMaxWidth().height(50.dp).padding(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = onDone) {
            Text("Done", color = Color.White, fontWeight = FontWeight.Bold)
        }
        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
            TextButton(
                onClick = { trackMenu = true },
                enabled = tracks.isNotEmpty(),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    selectedTrack?.title ?: "Choose a song",
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 16.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(
                    Icons.Default.ArrowDropDown,
                    contentDescription = "Select a song to clip",
                    tint = Color.White.copy(alpha = .7f),
                )
            }
            DropdownMenu(expanded = trackMenu, onDismissRequest = { trackMenu = false }) {
                tracks.forEach { track ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                track.title + " — " + track.artist,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        leadingIcon = if (track.id == selectedTrack?.id) {
                            { Icon(Icons.Default.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.tertiary) }
                        } else null,
                        onClick = {
                            onTrackSelected(track.id)
                            trackMenu = false
                        },
                    )
                }
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = onSave,
                enabled = saveEnabled,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.primary),
            ) { Text("Save", fontWeight = FontWeight.Bold, fontSize = 13.sp) }
            IconButton(onClick = onHelp) {
                Icon(Icons.Default.HelpOutline, contentDescription = "Clip editor help", tint = Color.White)
            }
            IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, contentDescription = "Clip settings", tint = Color.White) }
        }
    }
}

@Composable
private fun ClipSettingsTrackSummary(track: Track, artworkPath: String?) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        color = Color.White.copy(alpha = .055f),
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .08f)),
    ) {
        Row(
            modifier = Modifier.padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Artwork(
                path = artworkPath,
                modifier = Modifier.size(50.dp).clip(RoundedCornerShape(10.dp)),
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    track.title,
                    color = Color.White,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    track.artist,
                    color = Color.White.copy(alpha = .62f),
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                clipTime(track.durationMs),
                color = Color.White.copy(alpha = .55f),
                fontSize = 12.sp,
            )
        }
    }
}

@Composable
private fun ClipPreviewStage(
    track: Track,
    artworkPath: String?,
    player: ExoPlayer,
    isPlaying: Boolean,
    expanded: Boolean,
    positionMs: Long,
    endMs: Long,
    enabled: Boolean,
    onToggle: () -> Unit,
    onSkipStart: () -> Unit,
    onSkipEnd: () -> Unit,
    onExpand: () -> Unit,
) {
    val palette = LocalResonancePalette.current
    Surface(
        color = palette.surface,
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .09f)),
    ) {
        Column {
            if (isVideoClipTrack(track)) {
                Box(Modifier.fillMaxWidth().height(if (expanded) 500.dp else 286.dp)) {
                    ClipVideoPreview(player, track.title)
                }
            } else {
                Box(
                    modifier = Modifier.fillMaxWidth().height(if (expanded) 500.dp else 286.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        Artwork(
                            path = artworkPath,
                            modifier = Modifier.size(if (expanded) 176.dp else 116.dp).clip(RoundedCornerShape(if (expanded) 24.dp else 17.dp)),
                        )
                        Text(track.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = if (expanded) 23.sp else 18.sp, maxLines = 1)
                        Text(track.artist, color = Color.White.copy(alpha = .86f), fontSize = if (expanded) 17.sp else 14.sp, maxLines = 1)
                    }
                }
            }
            Box(
                modifier = Modifier.fillMaxWidth().height(54.dp).background(palette.raised).padding(horizontal = 14.dp),
            ) {
                Row(modifier = Modifier.align(Alignment.CenterStart), verticalAlignment = Alignment.CenterVertically) {
                    Text(clipTime(positionMs), color = palette.tertiary, fontSize = 12.sp)
                    Text(" / ", color = Color.White.copy(alpha = .5f), fontSize = 12.sp)
                    Text(clipTime(endMs), color = Color.White, fontSize = 12.sp)
                }
                Row(modifier = Modifier.align(Alignment.Center), horizontalArrangement = Arrangement.spacedBy(18.dp), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onSkipStart, enabled = enabled) { Icon(Icons.Default.SkipPrevious, contentDescription = "Go to clip start", tint = Color.White) }
                    IconButton(onClick = onToggle, enabled = enabled) { Icon(if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, contentDescription = if (isPlaying) "Pause preview" else "Play preview", tint = Color.White, modifier = Modifier.size(30.dp)) }
                    IconButton(onClick = onSkipEnd, enabled = enabled) { Icon(Icons.Default.SkipNext, contentDescription = "Go to clip end", tint = Color.White) }
                }
                IconButton(onClick = onExpand, modifier = Modifier.align(Alignment.CenterEnd)) {
                    Icon(if (expanded) Icons.Default.FullscreenExit else Icons.Default.Fullscreen, contentDescription = if (expanded) "Show timeline" else "Expand preview", tint = Color.White)
                }
            }
        }
    }
}

@Composable
private fun ClipTimeline(
    track: Track,
    waveformSamples: List<Float>,
    videoFrames: List<Bitmap>,
    startMs: Long,
    endMs: Long,
    playheadMs: Long,
    onRangeChange: (Long, Long) -> Unit,
    onSeek: (Long) -> Unit,
) {
    Surface(
        color = Color.White.copy(alpha = .035f),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .09f)),
    ) {
        Column {
            Row(Modifier.fillMaxWidth().padding(horizontal = 9.dp, vertical = 7.dp)) {
                repeat(3) { index ->
                    Text(clipTime(track.durationMs * index / 2), color = Color.White.copy(alpha = .68f), fontSize = 12.sp)
                    if (index < 2) Spacer(Modifier.weight(1f))
                }
            }
            Canvas(Modifier.fillMaxWidth().height(14.dp).padding(horizontal = 8.dp)) {
                repeat(31) { index ->
                    val x = size.width * index / 30
                    drawRect(Color.White.copy(alpha = if (index % 6 == 0) .4f else .2f), topLeft = Offset(x, 0f), size = androidx.compose.ui.geometry.Size(1.dp.toPx(), if (index % 6 == 0) size.height else size.height * .58f))
                }
            }
            ClipTimelineWaveform(track, waveformSamples, videoFrames, startMs, endMs, playheadMs, onRangeChange, onSeek)
        }
    }
}

@Composable
private fun ClipTimelineWaveform(
    track: Track,
    waveformSamples: List<Float>,
    videoFrames: List<Bitmap>,
    startMs: Long,
    endMs: Long,
    playheadMs: Long,
    onRangeChange: (Long, Long) -> Unit,
    onSeek: (Long) -> Unit,
) {
    val palette = LocalResonancePalette.current
    var draggingStart by remember { mutableStateOf(true) }
    val duration = track.durationMs.coerceAtLeast(250)
    val levels = remember(waveformSamples) {
        List(92) { index -> sampledAndroidClipLevel(waveformSamples, index / 91f) }
    }
    val frameImages = remember(videoFrames) { videoFrames.map(Bitmap::asImageBitmap) }
    val currentStart by rememberUpdatedState(startMs)
    val currentEnd by rememberUpdatedState(endMs)
    val currentOnRangeChange by rememberUpdatedState(onRangeChange)
    val currentOnSeek by rememberUpdatedState(onSeek)
    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(108.dp)
            .semantics {
                contentDescription = "Clip range"
                stateDescription = "Start ${clipTime(currentStart)}, end ${clipTime(currentEnd)}"
                customActions = listOf(
                    CustomAccessibilityAction("Move start earlier") {
                        val next = (currentStart - 1_000L).coerceAtLeast(0L)
                        if (next == currentStart) false else {
                            currentOnRangeChange(next, currentEnd)
                            true
                        }
                    },
                    CustomAccessibilityAction("Move start later") {
                        val next = (currentStart + 1_000L).coerceAtMost(currentEnd - 250L)
                        if (next == currentStart) false else {
                            currentOnRangeChange(next, currentEnd)
                            true
                        }
                    },
                    CustomAccessibilityAction("Move end earlier") {
                        val next = (currentEnd - 1_000L).coerceAtLeast(currentStart + 250L)
                        if (next == currentEnd) false else {
                            currentOnRangeChange(currentStart, next)
                            true
                        }
                    },
                    CustomAccessibilityAction("Move end later") {
                        val next = (currentEnd + 1_000L).coerceAtMost(duration)
                        if (next == currentEnd) false else {
                            currentOnRangeChange(currentStart, next)
                            true
                        }
                    },
                )
            }
            .pointerInput(track.id, duration) {
                detectTapGestures { offset ->
                    val value = (offset.x / size.width.coerceAtLeast(1) * duration).toLong().coerceIn(currentStart, currentEnd)
                    currentOnSeek(value)
                }
            }
            .pointerInput(track.id, duration) {
                detectDragGestures(
                    onDragStart = { offset ->
                        val startX = size.width * currentStart.toFloat() / duration
                        val endX = size.width * currentEnd.toFloat() / duration
                        draggingStart = kotlin.math.abs(offset.x - startX) <= kotlin.math.abs(offset.x - endX)
                    },
                ) { change, _ ->
                    change.consume()
                    val value = (change.position.x / size.width.coerceAtLeast(1) * duration).toLong().coerceIn(0, duration)
                    if (draggingStart) currentOnRangeChange(value.coerceAtMost(currentEnd - 250), currentEnd)
                    else currentOnRangeChange(currentStart, value.coerceAtLeast(currentStart + 250))
                }
            },
    ) {
        val startX = size.width * startMs / duration.toFloat()
        val endX = size.width * endMs / duration.toFloat()
        if (frameImages.isNotEmpty()) {
            val frameWidth = size.width / frameImages.size
            frameImages.forEachIndexed { index, image ->
                drawImage(
                    image = image,
                    dstOffset = IntOffset((index * frameWidth).toInt(), 0),
                    dstSize = IntSize((frameWidth + 1).toInt(), size.height.toInt()),
                )
            }
            drawRect(Color.Black.copy(alpha = .62f), size = androidx.compose.ui.geometry.Size(startX.coerceAtLeast(0f), size.height))
            drawRect(
                Color.Black.copy(alpha = .62f),
                topLeft = Offset(endX, 0f),
                size = androidx.compose.ui.geometry.Size((size.width - endX).coerceAtLeast(0f), size.height),
            )
        }
        drawRect(palette.secondary.copy(alpha = .14f), topLeft = Offset(startX, 0f), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), size.height))
        if (frameImages.isEmpty()) {
            val gap = 1.dp.toPx()
            val barWidth = (size.width - gap * (levels.size - 1)) / levels.size
            levels.forEachIndexed { index, level ->
                val ratio = (index + .5f) / levels.size
                val selected = ratio >= startMs.toFloat() / duration && ratio <= endMs.toFloat() / duration
                val height = size.height * (.16f + .56f * level)
                drawRect(
                    color = if (selected) palette.tertiary else Color.White.copy(alpha = .25f),
                    topLeft = Offset(index * (barWidth + gap), (size.height - height) / 2),
                    size = androidx.compose.ui.geometry.Size(barWidth.coerceAtLeast(1f), height),
                )
            }
        }
        drawRect(palette.tertiary, topLeft = Offset(startX, 0f), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), 2.dp.toPx()))
        drawRect(palette.tertiary, topLeft = Offset(startX, size.height - 2.dp.toPx()), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), 2.dp.toPx()))
        drawClipHandle(startX, true, palette.tertiary)
        drawClipHandle(endX, false, palette.tertiary)
        val playheadX = size.width * playheadMs.coerceIn(0, duration) / duration.toFloat()
        drawRect(Color.White, topLeft = Offset(playheadX, 0f), size = androidx.compose.ui.geometry.Size(1.5.dp.toPx(), size.height))
    }
}

private suspend fun extractAndroidClipVideoFrames(
    path: String,
    durationMs: Long,
    count: Int = 12,
): List<Bitmap> = withContext(Dispatchers.IO) {
    if (durationMs <= 0L || count <= 0) return@withContext emptyList()
    val retriever = MediaMetadataRetriever()
    try {
        retriever.setDataSource(path)
        (0 until count).mapNotNull { index ->
            val timeUs = durationMs * 1_000L * (index * 2L + 1L) / (count * 2L)
            val frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: return@mapNotNull null
            val scaled = Bitmap.createScaledBitmap(frame, 240, 135, true)
            if (scaled !== frame) frame.recycle()
            scaled
        }
    } catch (_: Exception) {
        emptyList()
    } finally {
        retriever.release()
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawClipHandle(
    x: Float,
    pointsRight: Boolean,
    color: Color,
) {
    val handleWidth = 26.dp.toPx()
    val left = (x - handleWidth / 2).coerceIn(0f, size.width - handleWidth)
    drawRoundRect(
        color = color,
        topLeft = Offset(left, 0f),
        size = androidx.compose.ui.geometry.Size(handleWidth, size.height),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(10.dp.toPx()),
    )
    val centerX = left + handleWidth / 2
    val path = Path().apply {
        if (pointsRight) {
            moveTo(centerX - 3.dp.toPx(), size.height / 2 - 6.dp.toPx())
            lineTo(centerX + 4.dp.toPx(), size.height / 2)
            lineTo(centerX - 3.dp.toPx(), size.height / 2 + 6.dp.toPx())
        } else {
            moveTo(centerX + 3.dp.toPx(), size.height / 2 - 6.dp.toPx())
            lineTo(centerX - 4.dp.toPx(), size.height / 2)
            lineTo(centerX + 3.dp.toPx(), size.height / 2 + 6.dp.toPx())
        }
        close()
    }
    drawPath(path, Color.Black.copy(alpha = .8f))
}

@Composable
private fun ClipEditorOverlay(
    onOutsideClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier.fillMaxSize(),
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = .52f))
                .clickable(
                    role = Role.Button,
                    onClickLabel = "Close overlay",
                    onClick = onOutsideClick,
                ),
        )
        Surface(
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(horizontal = 18.dp)
                .padding(top = 58.dp, bottom = 18.dp)
                .widthIn(max = 430.dp)
                .fillMaxWidth()
                .pointerInput(Unit) { detectTapGestures { } },
            color = LocalResonancePalette.current.raised,
            shape = RoundedCornerShape(20.dp),
            border = BorderStroke(1.dp, Color.White.copy(alpha = .12f)),
            tonalElevation = 12.dp,
        ) {
            Box(Modifier.padding(18.dp)) { content() }
        }
    }
}

@Composable
private fun ClipOverlayHeader(title: String, onClose: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onClose) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
    }
}

private fun sampledAndroidClipLevel(samples: List<Float>, normalizedPosition: Float): Float {
    if (samples.isEmpty()) return .08f
    val position = normalizedPosition.coerceIn(0f, 1f) * (samples.size - 1)
    val lower = position.toInt().coerceIn(samples.indices)
    val upper = (lower + 1).coerceAtMost(samples.lastIndex)
    val fraction = position - lower
    return (samples[lower] * (1 - fraction) + samples[upper] * fraction).coerceAtLeast(.04f)
}

private suspend fun extractAndroidClipWaveform(path: String, count: Int = 192): List<Float> = withContext(Dispatchers.IO) {
    if (count <= 0) return@withContext emptyList()
    val extractor = MediaExtractor()
    var codec: MediaCodec? = null
    try {
        extractor.setDataSource(path)
        val trackIndex = (0 until extractor.trackCount).firstOrNull { index ->
            extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: return@withContext emptyList()
        val inputFormat = extractor.getTrackFormat(trackIndex)
        val mime = inputFormat.getString(MediaFormat.KEY_MIME) ?: return@withContext emptyList()
        val durationUs = inputFormat.getLong(MediaFormat.KEY_DURATION).coerceAtLeast(1L)
        extractor.selectTrack(trackIndex)
        val decoder = MediaCodec.createDecoderByType(mime).also {
            it.configure(inputFormat, null, null, 0)
            it.start()
        }
        codec = decoder

        val peaks = FloatArray(count)
        val info = MediaCodec.BufferInfo()
        var inputFinished = false
        var outputFinished = false
        var pcmEncoding = AudioFormat.ENCODING_PCM_16BIT
        while (!outputFinished) {
            if (!inputFinished) {
                val inputIndex = decoder.dequeueInputBuffer(10_000)
                if (inputIndex >= 0) {
                    val inputBuffer = decoder.getInputBuffer(inputIndex)
                    val sampleSize = inputBuffer?.let { extractor.readSampleData(it, 0) } ?: -1
                    if (sampleSize < 0) {
                        decoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputFinished = true
                    } else {
                        decoder.queueInputBuffer(inputIndex, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            when (val outputIndex = decoder.dequeueOutputBuffer(info, 10_000)) {
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    val outputFormat = decoder.outputFormat
                    if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                        pcmEncoding = outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                    }
                }
                MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                else -> if (outputIndex >= 0) {
                    val outputBuffer = decoder.getOutputBuffer(outputIndex)
                    if (outputBuffer != null && info.size > 0) {
                        val data = outputBuffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
                        data.position(info.offset)
                        data.limit((info.offset + info.size).coerceAtMost(data.capacity()))
                        val slice = data.slice().order(ByteOrder.LITTLE_ENDIAN)
                        var peak = 0f
                        if (pcmEncoding == AudioFormat.ENCODING_PCM_FLOAT) {
                            val values = slice.asFloatBuffer()
                            while (values.hasRemaining()) peak = maxOf(peak, kotlin.math.abs(values.get()).coerceAtMost(1f))
                        } else {
                            val values = slice.asShortBuffer()
                            while (values.hasRemaining()) {
                                peak = maxOf(peak, kotlin.math.abs(values.get().toInt()) / Short.MAX_VALUE.toFloat())
                            }
                        }
                        val bin = (info.presentationTimeUs.toDouble() / durationUs * count)
                            .toInt()
                            .coerceIn(0, count - 1)
                        peaks[bin] = maxOf(peaks[bin], peak)
                    }
                    outputFinished = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    decoder.releaseOutputBuffer(outputIndex, false)
                }
            }
        }

        var last = 0f
        for (index in peaks.indices) {
            if (peaks[index] > 0f) last = peaks[index] else if (last > 0f) peaks[index] = last
        }
        last = 0f
        for (index in peaks.indices.reversed()) {
            if (peaks[index] > 0f) last = peaks[index] else if (last > 0f) peaks[index] = last
        }
        val maximum = peaks.maxOrNull()?.takeIf { it > 0f } ?: return@withContext emptyList()
        peaks.map { kotlin.math.sqrt((it / maximum).coerceIn(0f, 1f)).coerceAtLeast(.04f) }
    } catch (_: Exception) {
        emptyList()
    } finally {
        runCatching { codec?.stop() }
        codec?.release()
        extractor.release()
    }
}


@Composable
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private fun ClipVideoPreview(
    player: ExoPlayer,
    title: String,
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.Black)
            .semantics { contentDescription = "Video preview for $title" },
        contentAlignment = Alignment.Center,
    ) {
        AndroidView(
            factory = { context ->
                PlayerView(context).apply {
                    useController = false
                    resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                    this.player = player
                }
            },
            update = { it.player = player },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

private fun isVideoClipTrack(track: Track): Boolean = isVideoClipPath(track.relativePath)

internal fun isVideoClipPath(path: String): Boolean =
    path.substringAfterLast('.', "").lowercase() in setOf("mp4", "mov", "m4v", "webm")

@Composable
private fun ClipTimeField(
    label: String,
    value: String,
    onChange: (String) -> Unit,
    onCommit: () -> Unit,
    modifier: Modifier,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        modifier = modifier,
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onCommit() }),
    )
}

@Composable
fun LinkImportDialog(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onDismiss: () -> Unit,
) {
    var source by remember { mutableStateOf(state.linkImport.requestedSource.orEmpty()) }
    val canUploadReviewedLink = state.hasServerUploadCredentials &&
        state.serverUploadMode != null
    var uploadAfterImport by rememberSaveable { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val clipboard = LocalClipboardManager.current
    val importState = state.linkImport
    val mediaLabel = importState.mediaMode.name.lowercase()
    val reviewedMatchPolicyBound = importState.resolution?.reviewedMatchPolicyBound == true
    val uploadInputAccepted = when (state.serverUploadMode) {
        ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink -> source.isNotBlank()
        ServerUploadMode.ReviewedMatch -> LinkImportInput.isReviewedTrackLink(source)
        null -> false
    }
    val modeSubtitle = when (state.serverUploadMode) {
        ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink ->
            "Downloads the selected $mediaLabel to this device, then registers its source link with the server."
        ServerUploadMode.ReviewedMatch ->
            "Server uploads require one full Spotify track or YouTube video link. Searches and SoundCloud stay on this device."
        else -> "Search Spotify, SoundCloud, or YouTube, or paste a supported link."
    }
    val inputLabel = when (state.serverUploadMode) {
        ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink -> "Search or link"
        ServerUploadMode.ReviewedMatch -> "Spotify/YouTube track link or device-only search"
        else -> "Search or link"
    }
    val inputPlaceholder = when (state.serverUploadMode) {
        ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink -> "Song, artist, album, or link"
        ServerUploadMode.ReviewedMatch -> "Spotify track or YouTube video link"
        else -> "Song, artist, album, or link"
    }
    LaunchedEffect(reviewedMatchPolicyBound) {
        if (reviewedMatchPolicyBound) uploadAfterImport = true
    }
    LaunchedEffect(source, state.serverUploadMode, canUploadReviewedLink) {
        if (!reviewedMatchPolicyBound && (!canUploadReviewedLink || !uploadInputAccepted)) {
            uploadAfterImport = false
        }
    }
    val close = {
        if (importState.isRunning) actions.cancelLinkImport()
        else actions.stopLinkImportPreview()
        onDismiss()
    }
    DisposableEffect(Unit) {
        onDispose { actions.stopLinkImportPreview() }
    }
    Dialog(
        onDismissRequest = close,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxHeight(.92f).padding(horizontal = 14.dp),
            color = LocalResonancePalette.current.surface,
            shape = RoundedCornerShape(22.dp),
        ) {
            Column(Modifier.fillMaxSize()) {
                ToolHeader("Import from web", modeSubtitle, close)
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = source,
                            onValueChange = {
                                source = it
                                actions.updateLinkImportSource(it)
                            },
                            modifier = Modifier.weight(1f),
                            label = { Text(inputLabel) },
                            placeholder = { Text(inputPlaceholder) },
                            leadingIcon = { Icon(Icons.Default.Search, null) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = {
                                focus.clearFocus()
                                actions.resolveLinkImport(source)
                            }),
                        )
                        TextButton(onClick = {
                            clipboard.getText()?.text?.takeIf(String::isNotBlank)?.let {
                                source = it
                                actions.updateLinkImportSource(it)
                            }
                        }) { Text("Paste") }
                    }
                    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        SectionLabel("Download as")
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            LinkImportMediaMode.entries.forEach { mode ->
                                FilterChip(
                                    selected = importState.mediaMode == mode,
                                    onClick = { actions.setLinkImportMediaMode(mode) },
                                    enabled = !importState.isRunning,
                                    label = { Text(mode.name) },
                                )
                            }
                        }
                        Text(
                            if (importState.mediaMode == LinkImportMediaMode.Video) {
                                "YouTube links and video search results download as verified MP4 video. Spotify and SoundCloud links are audio-only."
                            } else {
                                "Downloads a verified local audio file."
                            },
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        )
                    }
                    Surface(color = Color.White.copy(alpha = .045f), shape = RoundedCornerShape(13.dp)) {
                        Row(
                            Modifier.fillMaxWidth().padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text("Upload after downloading", fontWeight = FontWeight.SemiBold)
                                Text(
                                    if (canUploadReviewedLink) {
                                        if (reviewedMatchPolicyBound) {
                                            "Choose one server-ranked candidate explicitly. It is downloaded and verified locally, then its preserved direct source link is registered."
                                        } else if (!uploadInputAccepted) {
                                            when (state.serverUploadMode) {
                                                ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink ->
                                                    "Enter a search or supported link before enabling server registration."
                                                ServerUploadMode.ReviewedMatch ->
                                                    "Server upload is off until this is one full Spotify track or individual YouTube video link. Generic search, SoundCloud, and playlists remain device-only."
                                            }
                                        } else when (state.serverUploadMode) {
                                            ServerUploadMode.LocalFile, ServerUploadMode.ServerSourceLink ->
                                                "Only the direct media URL preserved by the local download is registered with the active server profile."
                                            ServerUploadMode.ReviewedMatch ->
                                                "After review, the preserved direct media URL is registered with the active server profile."
                                        }
                                    } else {
                                        "Choose an enabled upload mode in Server settings, or keep this import only on this device."
                                    },
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                )
                            }
                            Switch(
                                checked = uploadAfterImport && canUploadReviewedLink &&
                                    (reviewedMatchPolicyBound || uploadInputAccepted),
                                enabled = canUploadReviewedLink && uploadInputAccepted && !reviewedMatchPolicyBound,
                                onCheckedChange = { uploadAfterImport = it },
                            )
                        }
                    }
                    LinkStageCard(importState)
                    if (importState.searchResponse != null) {
                        LinkSearchResults(importState.searchResponse, state, actions)
                    } else importState.resolution?.let { resolution ->
                        val isPlaylist = resolution.kind.isPlaylist
                        val playlistProvider = if (resolution.kind == LinkImportKind.SoundCloudPlaylist) "SoundCloud" else "Spotify"
                        Surface(color = Color.White.copy(alpha = .045f), shape = RoundedCornerShape(13.dp)) {
                            Column(Modifier.fillMaxWidth().padding(14.dp)) {
                                SectionLabel(if (isPlaylist) "$playlistProvider playlist" else "Matched track")
                                Text(resolution.track.title, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                                Text(
                                    buildList {
                                        add(resolution.track.artist)
                                        resolution.track.album?.let(::add)
                                        if (isPlaylist) add("${resolution.candidates.size} matched songs")
                                    }.joinToString(" • "),
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                )
                                val existing = LinkImportExistingPolicy.match(
                                    resolution.track,
                                    state.tracks,
                                    state.remoteSongs,
                                    state.serverUrl,
                                    state.syncProfileId,
                                    importState.mediaMode,
                                )
                                if (!isPlaylist && (existing.isOnDevice || existing.isOnServer)) {
                                    Text(
                                        linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                                        fontSize = 12.sp,
                                        color = LocalResonancePalette.current.success,
                                    )
                                }
                            }
                        }
                        resolution.playlist?.skippedItems?.takeIf { it.isNotEmpty() }?.let { skippedItems ->
                            Surface(color = Color(0xFFFF9800).copy(alpha = .10f), shape = RoundedCornerShape(13.dp)) {
                                Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                    SectionLabel("Skipped items")
                                    skippedItems.forEach { skipped ->
                                        Text(
                                            "${skipped.position}. ${skipped.title}${skipped.artist?.let { " — $it" }.orEmpty()}",
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        Text(
                                            skipped.reason,
                                            fontSize = 12.sp,
                                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                        )
                                    }
                                }
                            }
                        }
                        SectionLabel(
                            when {
                                reviewedMatchPolicyBound -> "Choose one candidate"
                                isPlaylist -> "Tracks to import"
                                else -> "${importState.mediaMode.name} source"
                            },
                        )
                        resolution.candidates.forEach { candidate ->
                            val metadata = candidate.importTrack
                            val selected = if (isPlaylist) {
                                candidate.videoID in importState.selectedVideoIds
                            } else {
                                candidate.videoID == importState.selectedVideoId
                            }
                            Surface(
                                color = Color.White.copy(alpha = if (selected) .08f else .035f),
                                shape = RoundedCornerShape(12.dp),
                            ) {
                                Row(
                                    Modifier
                                        .fillMaxWidth()
                                        .toggleable(
                                            value = selected,
                                            role = if (isPlaylist) Role.Checkbox else Role.RadioButton,
                                            onValueChange = { actions.selectLinkImportCandidate(candidate.videoID) },
                                        )
                                        .padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    if (isPlaylist) {
                                        Checkbox(checked = selected, onCheckedChange = null)
                                    } else {
                                        RadioButton(selected = selected, onClick = null)
                                    }
                                    RemoteArtwork(
                                        metadata?.artworkURL ?: candidate.thumbnailURL,
                                        state.serverUrl,
                                        Modifier.size(44.dp),
                                    )
                                    Spacer(Modifier.width(10.dp))
                                    Column(Modifier.weight(1f)) {
                                        Text(metadata?.title ?: candidate.title, fontWeight = FontWeight.SemiBold, maxLines = 2)
                                        Text(
                                            listOfNotNull(
                                                candidate.playlistIndex?.let { "#$it" },
                                                metadata?.artist ?: candidate.artist ?: "Unknown uploader",
                                                (metadata?.durationSeconds ?: candidate.durationSeconds)?.let { clipTime(it * 1_000L) },
                                                if (candidate.sourceProvider == LinkImportSourceProvider.SoundCloud) "SoundCloud" else "YouTube",
                                            ).joinToString(" • "),
                                            fontSize = 12.sp,
                                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                        )
                                        metadata?.let {
                                            val existing = LinkImportExistingPolicy.match(
                                                it,
                                                state.tracks,
                                                state.remoteSongs,
                                                state.serverUrl,
                                                state.syncProfileId,
                                                importState.mediaMode,
                                            )
                                            if (existing.isOnDevice || existing.isOnServer) {
                                                Text(
                                                    linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                                                    fontSize = 12.sp,
                                                    color = LocalResonancePalette.current.success,
                                                )
                                            }
                                        }
                                    }
                                    IconButton(onClick = { actions.toggleLinkImportPreview(candidate.videoID) }) {
                                        if (importState.previewLoadingVideoId == candidate.videoID) {
                                            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                                        } else {
                                            Icon(
                                                if (importState.previewingVideoId == candidate.videoID) Icons.Default.Pause else Icons.Default.PlayArrow,
                                                if (importState.previewingVideoId == candidate.videoID) "Stop preview" else "Preview ${metadata?.title ?: candidate.title}",
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                    importState.previewError?.let {
                        Text(it, fontSize = 12.sp, color = Color(0xFFFFB74D))
                    }
                    if (importState.errorMessage != null) {
                        Surface(color = Color.Red.copy(alpha = .12f), shape = RoundedCornerShape(13.dp)) {
                            Column(Modifier.fillMaxWidth().padding(14.dp)) {
                                Text("Import stopped", fontWeight = FontWeight.Bold)
                                Text(importState.errorMessage)
                                importState.errorCode?.let { Text(it, fontSize = 12.sp, color = Color.White.copy(alpha = .55f)) }
                            }
                        }
                    }
                }
                Row(
                    Modifier.fillMaxWidth().padding(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.End),
                ) {
                    TextButton(onClick = close) { Text("Close") }
                    if (importState.resolution == null) {
                        Button(
                            onClick = {
                                focus.clearFocus()
                                actions.resolveLinkImport(source)
                            },
                            enabled = !importState.isRunning,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.secondary,
                            ),
                        ) {
                            Icon(Icons.Default.Search, null)
                            Spacer(Modifier.size(6.dp))
                            Text(if (importState.mediaMode == LinkImportMediaMode.Video) "Find Video" else "Find Audio")
                        }
                    } else {
                        Button(
                            onClick = {
                                val serverUploadRequested = uploadAfterImport && canUploadReviewedLink &&
                                    (reviewedMatchPolicyBound || uploadInputAccepted)
                                if (actions.confirmLinkImport(serverUploadRequested)) onDismiss()
                            },
                            enabled = !importState.isRunning && if (importState.resolution.kind.isPlaylist) {
                                importState.selectedVideoIds.isNotEmpty()
                            } else {
                                importState.selectedVideoId != null
                            },
                            colors = ButtonDefaults.buttonColors(
                                containerColor = MaterialTheme.colorScheme.secondary,
                            ),
                        ) { Text("Import") }
                    }
                }
            }
        }
    }
}

@Composable
private fun LinkSearchResults(
    response: LinkImportSearchResponse,
    state: ResonanceUiState,
    actions: ResonanceActions,
) {
    Column(
        modifier = Modifier.selectableGroup(),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SectionLabel("Search results")
            Spacer(Modifier.weight(1f))
            Text(
                "${response.results.size} ${if (state.linkImport.mediaMode == LinkImportMediaMode.Video) "downloadable" else "previewable"}",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.tertiary,
            )
        }
        LinkImportSearchProvider.entries.forEach { provider ->
            val results = response.resultsFor(provider)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    SectionLabel(provider.displayName)
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${results.size} result${if (results.size == 1) "" else "s"}",
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    )
                }
                if (results.isEmpty()) {
                    Surface(color = Color.White.copy(alpha = .025f), shape = RoundedCornerShape(11.dp)) {
                        Text(
                            "No previewable results.",
                            modifier = Modifier.fillMaxWidth().padding(12.dp),
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        )
                    }
                } else {
                    results.forEach { result ->
                        LinkSearchResultRow(result, state, actions)
                    }
                }
            }
        }
    }
}

@Composable
private fun LinkSearchResultRow(
    result: LinkImportSearchResult,
    state: ResonanceUiState,
    actions: ResonanceActions,
) {
    val importState = state.linkImport
    val candidate = result.candidates.firstOrNull()
    val selected = importState.selectedSearchResultId == result.id
    Surface(
        color = Color.White.copy(alpha = if (selected) .08f else .035f),
        shape = RoundedCornerShape(12.dp),
    ) {
        Row(
            Modifier
                .fillMaxWidth()
                .selectable(
                    selected = selected,
                    role = Role.RadioButton,
                    onClick = { actions.selectLinkImportSearchResult(result.id) },
                )
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RadioButton(selected = selected, onClick = null)
            RemoteArtwork(
                result.track.artworkURL ?: candidate?.thumbnailURL,
                state.serverUrl,
                Modifier.size(44.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(result.track.title, fontWeight = FontWeight.SemiBold, maxLines = 2)
                Text(
                    buildList {
                        add(result.track.artist)
                        result.track.album?.let(::add)
                        result.track.durationSeconds?.let { add(clipTime(it * 1_000L)) }
                        add(result.provider.displayName)
                        candidate?.let {
                            val previewProvider = if (it.sourceProvider == LinkImportSourceProvider.SoundCloud) "SoundCloud" else "YouTube"
                            if (previewProvider != result.provider.displayName) add("Preview via $previewProvider")
                        }
                    }.joinToString(" • "),
                    fontSize = 12.sp,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                    maxLines = 2,
                )
                val existing = LinkImportExistingPolicy.match(
                    result.track,
                    state.tracks,
                    state.remoteSongs,
                    state.serverUrl,
                    state.syncProfileId,
                    importState.mediaMode,
                )
                if (existing.isOnDevice || existing.isOnServer) {
                    Text(
                        linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                        fontSize = 12.sp,
                        color = LocalResonancePalette.current.success,
                    )
                }
            }
            candidate?.let {
                IconButton(onClick = {
                    actions.selectLinkImportSearchResult(result.id)
                    actions.toggleLinkImportPreview(it.videoID)
                }) {
                    if (importState.previewLoadingVideoId == it.videoID) {
                        CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(
                            if (importState.previewingVideoId == it.videoID) Icons.Default.Pause else Icons.Default.PlayArrow,
                            if (importState.previewingVideoId == it.videoID) "Stop preview" else "Preview ${result.track.title}",
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LinkStageCard(state: LinkImportUiState) {
    Surface(color = Color.White.copy(alpha = .045f), shape = RoundedCornerShape(13.dp)) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    when {
                        state.stage == LinkImportStage.Complete -> Icons.Default.CheckCircle
                        state.mediaMode == LinkImportMediaMode.Video -> Icons.Default.PlayArrow
                        else -> Icons.Default.MusicNote
                    },
                    null,
                    tint = if (state.stage == LinkImportStage.Complete) {
                        LocalResonancePalette.current.success
                    } else {
                        MaterialTheme.colorScheme.tertiary
                    },
                )
                Spacer(Modifier.size(8.dp))
                Text(linkStageTitle(state.stage, state.mediaMode), fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                if (state.isRunning) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }
            Text(linkStageDetail(state.stage, state.mediaMode), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
            if (state.totalBytes > 0) {
                LinearProgressIndicator(
                    progress = { state.completedBytes.toFloat() / state.totalBytes.coerceAtLeast(1) },
                    modifier = Modifier.fillMaxWidth(),
                    color = MaterialTheme.colorScheme.secondary,
                )
                Text(
                    android.text.format.Formatter.formatFileSize(LocalContext.current, state.completedBytes) + " of " +
                        android.text.format.Formatter.formatFileSize(LocalContext.current, state.totalBytes),
                    fontSize = 12.sp,
                )
            }
            state.completedTrackTitle?.let {
                Text(
                    "Added “" + it + "” to this device.",
                    color = LocalResonancePalette.current.success,
                    fontSize = 13.sp,
                )
            }
            state.batchCurrentTitle?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .7f)) }
            state.completedSummary?.let {
                Text(it, color = LocalResonancePalette.current.success, fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun ToolHeader(title: String, subtitle: String, onDismiss: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 22.sp, fontWeight = FontWeight.Bold)
            Text(subtitle, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
        }
        IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, "Close") }
    }
}

@Composable
private fun ToolEmpty(title: String, detail: String) {
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            Icons.Default.MusicNote,
            null,
            Modifier.size(44.dp),
            tint = MaterialTheme.colorScheme.tertiary,
        )
        Text(title, fontWeight = FontWeight.Bold)
        Text(
            detail,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
            textAlign = TextAlign.Center,
        )
    }
}

private fun parseClipTime(value: String): Long? {
    val parts = value.trim().split(':')
    if (parts.size !in 1..3 || parts.any(String::isEmpty)) return null
    val seconds = parts.last().toDoubleOrNull() ?: return null
    if (seconds < 0 || parts.size > 1 && seconds >= 60) return null
    if (parts.size == 1) return (seconds * 1_000).toLong()
    val minutes = parts[parts.lastIndex - 1].toDoubleOrNull() ?: return null
    if (minutes < 0 || parts.size == 3 && minutes >= 60) return null
    val hours = if (parts.size == 3) parts[0].toDoubleOrNull() ?: return null else 0.0
    return ((hours * 3_600 + minutes * 60 + seconds) * 1_000).toLong()
}

private fun clipTime(valueMs: Long): String {
    val safe = valueMs.coerceAtLeast(0)
    val whole = safe / 1_000
    val tenth = safe % 1_000 / 100
    val base = if (whole >= 3_600) {
        "%d:%02d:%02d".format(whole / 3_600, whole / 60 % 60, whole % 60)
    } else {
        "%d:%02d".format(whole / 60, whole % 60)
    }
    return if (tenth == 0L) base else base + "." + tenth
}

private fun linkStageTitle(stage: LinkImportStage, mediaMode: LinkImportMediaMode): String = when (stage) {
    LinkImportStage.Idle -> "Ready"
    LinkImportStage.ResolvingMetadata -> "Resolving Metadata"
    LinkImportStage.SearchingCandidates -> "Searching ${mediaMode.name} Sources"
    LinkImportStage.AwaitingSelection -> "Choose a ${mediaMode.name} Source"
    LinkImportStage.InspectingSource -> "Inspecting Source"
    LinkImportStage.Downloading -> "Downloading"
    LinkImportStage.SavingLocal -> "Saving on Device"
    LinkImportStage.Syncing -> "Uploading"
    LinkImportStage.Complete -> "Import Complete"
    LinkImportStage.Failed -> "Import Failed"
    LinkImportStage.Cancelled -> "Cancelled"
}

private fun linkStageDetail(stage: LinkImportStage, mediaMode: LinkImportMediaMode): String {
    val media = mediaMode.name.lowercase()
    return when (stage) {
        LinkImportStage.Idle -> "Enter text to search Spotify, SoundCloud, and YouTube, or paste a supported link."
        LinkImportStage.ResolvingMetadata -> "Reading title, artist, artwork, and duration."
        LinkImportStage.SearchingCandidates -> "Querying Spotify, SoundCloud, and YouTube for downloadable $media."
        LinkImportStage.AwaitingSelection -> "Review the match before saving $media locally."
        LinkImportStage.InspectingSource -> "Verifying direct $media streams."
        LinkImportStage.Downloading -> "Downloading verified $media directly to this device."
        LinkImportStage.SavingLocal -> "Adding the finished file to Resonance."
        LinkImportStage.Syncing -> "Uploading locally saved songs to the active server profile."
        LinkImportStage.Complete -> "The song is stored locally and ready to play."
        LinkImportStage.Failed -> "Review the error below and try another source."
        LinkImportStage.Cancelled -> "No unfinished import was kept."
    }
}

private fun linkExistingStatus(onDevice: Boolean, onServer: Boolean): String = when {
    onDevice && onServer -> "On device and server — both transfers will be skipped"
    onDevice -> "On device — download will be skipped"
    onServer -> "On server — upload will be skipped"
    else -> ""
}
