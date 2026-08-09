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
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
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
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.preferredFrameRate
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
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
import mov.unblocked.resonance.data.SourceImportPolicy
import mov.unblocked.resonance.data.LinkImportKind
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
    var selectedTrackId by remember { mutableStateOf(state.currentTrackId ?: state.tracks.firstOrNull()?.id) }
    val selectedTrack = state.tracks.firstOrNull { it.id == selectedTrackId }
    var startMs by remember { mutableLongStateOf(0L) }
    var endMs by remember { mutableLongStateOf(selectedTrack?.durationMs?.takeIf { it > 0L } ?: 0L) }
    var startText by remember { mutableStateOf("0:00") }
    var endText by remember { mutableStateOf(selectedTrack?.durationMs?.let(::clipTime) ?: "0:00") }
    var trackMenu by remember { mutableStateOf(false) }
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
                .background(Color(0xFF03040A).copy(alpha = .92f))
                .padding(horizontal = 8.dp, vertical = 10.dp),
        ) {
            Surface(
                modifier = Modifier.fillMaxSize(),
                color = Color(0xFF080910),
                shape = RoundedCornerShape(18.dp),
                border = BorderStroke(1.dp, Color.White.copy(alpha = .08f)),
                tonalElevation = 8.dp,
            ) {
                Column(Modifier.fillMaxSize()) {
                    CinematicClipHeader(
                        saveEnabled = selectedTrack?.durationMs?.let { it >= 250 } == true
                            && (startMs != savedStartMs || endMs != savedEndMs),
                        onDone = {
                            focus.clearFocus()
                            stopPreview()
                            onDismiss()
                        },
                        onSave = {
                            val track = selectedTrack ?: return@CinematicClipHeader
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
                                CinematicClipStage(
                                    track = selectedTrack,
                                    artworkPath = state.artworkPathsByTrackId[selectedTrack.id],
                                    player = previewPlayer,
                                    waveformSamples = waveformSamples,
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
                                    CinematicClipTimeline(
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
                                    saveMessage ?: "Unsaved changes are discarded by Done. The original media file is never changed.",
                                    modifier = Modifier.padding(horizontal = 3.dp, vertical = 2.dp),
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .54f),
                                    fontSize = 10.sp,
                                )
                            }
                        }
                    }
                }
            }

            if (settingsOpen && selectedTrack != null) {
                CinematicClipOverlay(onOutsideClick = { settingsOpen = false }) {
                    Column(verticalArrangement = Arrangement.spacedBy(13.dp)) {
                        CinematicOverlayHeader("CLIP SETTINGS", "Fine tune your clip") { settingsOpen = false }
                        Eyebrow("Song")
                        Box {
                            OutlinedButton(onClick = { trackMenu = true }, modifier = Modifier.fillMaxWidth()) {
                                Text(selectedTrack.title + " — " + selectedTrack.artist, maxLines = 1)
                            }
                            DropdownMenu(expanded = trackMenu, onDismissRequest = { trackMenu = false }) {
                                state.tracks.forEach { track ->
                                    DropdownMenuItem(
                                        text = { Text(track.title + " — " + track.artist) },
                                        onClick = { selectedTrackId = track.id; trackMenu = false },
                                    )
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            ClipTimeField(
                                "START",
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
                                "END",
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
                                Eyebrow("Clip Length")
                                Text(clipTime(endMs - startMs), color = Color(0xFFB56AFF), fontWeight = FontWeight.Bold)
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
                            }) { Text("Use Full Song") }
                        }
                    }
                }
            }

            if (helpOpen) {
                CinematicClipOverlay(onOutsideClick = { helpOpen = false }) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        CinematicOverlayHeader("HOW IT WORKS", "Create your perfect playback range") { helpOpen = false }
                        Text(
                            "Drag the yellow handles to choose a range. Tap the waveform to scrub, then use the center controls to preview exactly what will play.",
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                            fontSize = 13.sp,
                        )
                        Text(
                            "Save updates playback for the active profile without changing the media file. Done closes the editor and discards anything not saved.",
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
private fun CinematicClipHeader(
    saveEnabled: Boolean,
    onDone: () -> Unit,
    onSave: () -> Unit,
    onHelp: () -> Unit,
    onSettings: () -> Unit,
) {
    Box(Modifier.fillMaxWidth().height(50.dp).padding(horizontal = 8.dp)) {
        TextButton(onClick = onDone, modifier = Modifier.align(Alignment.CenterStart)) {
            Text("Done", color = Color.White, fontWeight = FontWeight.Bold)
        }
        Text("My Clip", modifier = Modifier.align(Alignment.Center), color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 18.sp)
        Row(modifier = Modifier.align(Alignment.CenterEnd), verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = onSave,
                enabled = saveEnabled,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF7942DF)),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 13.dp, vertical = 0.dp),
                modifier = Modifier.height(34.dp),
            ) { Text("Save", fontWeight = FontWeight.Bold, fontSize = 13.sp) }
            IconButton(onClick = onHelp) {
                Surface(shape = RoundedCornerShape(999.dp), color = Color.Transparent, border = BorderStroke(1.5.dp, Color.White.copy(alpha = .9f))) {
                    Text("?", modifier = Modifier.padding(horizontal = 9.dp, vertical = 3.dp), color = Color.White, fontWeight = FontWeight.Bold)
                }
            }
            IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, contentDescription = "Clip settings", tint = Color.White) }
        }
    }
}

@Composable
private fun CinematicClipStage(
    track: Track,
    artworkPath: String?,
    player: ExoPlayer,
    waveformSamples: List<Float>,
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
    Surface(
        color = Color(0xFF090A10),
        shape = RoundedCornerShape(16.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = .09f)),
    ) {
        Column {
            if (isVideoClipTrack(track)) {
                Box(Modifier.fillMaxWidth().height(if (expanded) 500.dp else 230.dp)) {
                    ClipVideoPreview(player, isPlaying, track.title)
                }
            } else {
                Box(
                    modifier = Modifier.fillMaxWidth().height(if (expanded) 500.dp else 230.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    CinematicAndroidVisualizer(
                        samples = waveformSamples,
                        isPlaying = isPlaying,
                        positionMs = positionMs,
                        durationMs = track.durationMs,
                        player = player,
                    )
                    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        Artwork(
                            path = artworkPath,
                            modifier = Modifier.size(if (expanded) 176.dp else 116.dp).clip(RoundedCornerShape(if (expanded) 24.dp else 17.dp)),
                        )
                        Text(track.title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = if (expanded) 23.sp else 18.sp, maxLines = 1)
                        Text(track.artist, color = Color.White.copy(alpha = .86f), fontSize = if (expanded) 17.sp else 14.sp, maxLines = 1)
                        Text("[Visualizer]", color = Color(0xFFB56AFF), fontSize = 14.sp)
                    }
                }
            }
            Box(
                modifier = Modifier.fillMaxWidth().height(54.dp).background(Color(0xFF0D0E15)).padding(horizontal = 14.dp),
            ) {
                Row(modifier = Modifier.align(Alignment.CenterStart), verticalAlignment = Alignment.CenterVertically) {
                    Text(clipTime(positionMs), color = Color(0xFFAC75FF), fontSize = 11.sp)
                    Text("  /  ", color = Color.White.copy(alpha = .35f), fontSize = 11.sp)
                    Text(clipTime(endMs), color = Color.White, fontSize = 11.sp)
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
private fun CinematicAndroidVisualizer(
    samples: List<Float>,
    isPlaying: Boolean,
    positionMs: Long,
    durationMs: Long,
    player: ExoPlayer,
) {
    var livePositionMs by remember(player) { mutableLongStateOf(positionMs) }

    LaunchedEffect(isPlaying, player, durationMs) {
        if (!isPlaying) {
            livePositionMs = positionMs
            return@LaunchedEffect
        }
        var lastRenderNanos = Long.MIN_VALUE
        val renderIntervalNanos = 1_000_000_000L / 60L
        while (true) {
            withFrameNanos { frameTimeNanos ->
                if (lastRenderNanos == Long.MIN_VALUE || frameTimeNanos - lastRenderNanos >= renderIntervalNanos) {
                    livePositionMs = player.currentPosition.coerceIn(0L, durationMs)
                    lastRenderNanos = frameTimeNanos
                }
            }
        }
    }
    LaunchedEffect(positionMs, isPlaying) {
        if (!isPlaying) livePositionMs = positionMs
    }

    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .preferredFrameRate(60f)
            .background(Brush.radialGradient(listOf(Color(0xFF2C1647), Color.Black))),
    ) {
        val barCount = 96
        val gap = 1.5.dp.toPx()
        val width = (size.width - gap * (barCount - 1)) / barCount
        val renderedPositionMs = if (isPlaying) livePositionMs else positionMs
        val progress = if (durationMs > 0) renderedPositionMs.toFloat() / durationMs else 0f
        repeat(barCount) { index ->
            val barProgress = index.toFloat() / (barCount - 1)
            val samplePosition = if (isPlaying) {
                (progress + (barProgress - .3f) * .24f).coerceIn(0f, 1f)
            } else {
                barProgress
            }
            val level = sampledAndroidClipLevel(samples, samplePosition)
            val height = (size.height * .72f * level).coerceAtLeast(5f)
            drawRoundRect(
                color = Color(0xFF8D43D8).copy(alpha = .76f),
                topLeft = Offset(index * (width + gap), size.height - height),
                size = androidx.compose.ui.geometry.Size(width.coerceAtLeast(1f), height),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(width / 2),
            )
        }
    }
}

@Composable
private fun CinematicClipTimeline(
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
            Row(Modifier.fillMaxWidth().padding(horizontal = 9.dp, vertical = 5.dp)) {
                repeat(6) { index ->
                    Text(clipTime(track.durationMs * index / 5), color = Color.White.copy(alpha = .58f), fontSize = 9.sp)
                    if (index < 5) Spacer(Modifier.weight(1f))
                }
            }
            Canvas(Modifier.fillMaxWidth().height(12.dp).padding(horizontal = 8.dp)) {
                repeat(31) { index ->
                    val x = size.width * index / 30
                    drawRect(Color.White.copy(alpha = if (index % 6 == 0) .4f else .2f), topLeft = Offset(x, 0f), size = androidx.compose.ui.geometry.Size(1.dp.toPx(), if (index % 6 == 0) size.height else size.height * .58f))
                }
            }
            CinematicAndroidWaveform(track, waveformSamples, videoFrames, startMs, endMs, playheadMs, onRangeChange, onSeek)
        }
    }
}

@Composable
private fun CinematicAndroidWaveform(
    track: Track,
    waveformSamples: List<Float>,
    videoFrames: List<Bitmap>,
    startMs: Long,
    endMs: Long,
    playheadMs: Long,
    onRangeChange: (Long, Long) -> Unit,
    onSeek: (Long) -> Unit,
) {
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
            .height(88.dp)
            .semantics { contentDescription = "Clip waveform with yellow draggable handles" }
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
        drawRect(Color(0xFF7130AF).copy(alpha = .14f), topLeft = Offset(startX, 0f), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), size.height))
        if (frameImages.isEmpty()) {
            val gap = 1.dp.toPx()
            val barWidth = (size.width - gap * (levels.size - 1)) / levels.size
            levels.forEachIndexed { index, level ->
                val ratio = (index + .5f) / levels.size
                val selected = ratio >= startMs.toFloat() / duration && ratio <= endMs.toFloat() / duration
                val height = size.height * (.16f + .56f * level)
                drawRect(
                    color = if (selected) Color(0xFF934ADD) else Color.White.copy(alpha = .25f),
                    topLeft = Offset(index * (barWidth + gap), (size.height - height) / 2),
                    size = androidx.compose.ui.geometry.Size(barWidth.coerceAtLeast(1f), height),
                )
            }
        }
        drawRect(Color(0xFFFFD329), topLeft = Offset(startX, 0f), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), 2.dp.toPx()))
        drawRect(Color(0xFFFFD329), topLeft = Offset(startX, size.height - 2.dp.toPx()), size = androidx.compose.ui.geometry.Size((endX - startX).coerceAtLeast(0f), 2.dp.toPx()))
        drawCinematicHandle(startX, true)
        drawCinematicHandle(endX, false)
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

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawCinematicHandle(x: Float, pointsRight: Boolean) {
    val handleWidth = 26.dp.toPx()
    val left = (x - handleWidth / 2).coerceIn(0f, size.width - handleWidth)
    drawRoundRect(
        color = Color(0xFFFFD329),
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
private fun CinematicClipOverlay(
    onOutsideClick: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier.fillMaxSize().background(Color.Black.copy(alpha = .52f)).clickable(onClick = onOutsideClick),
        contentAlignment = Alignment.Center,
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().padding(18.dp).clickable {},
            color = Color(0xF511121B),
            shape = RoundedCornerShape(20.dp),
            border = BorderStroke(1.dp, Color.White.copy(alpha = .12f)),
            tonalElevation = 12.dp,
        ) {
            Box(Modifier.padding(18.dp)) { content() }
        }
    }
}

@Composable
private fun CinematicOverlayHeader(eyebrow: String, title: String, onClose: () -> Unit) {
    Row(verticalAlignment = Alignment.Top) {
        Column {
            Eyebrow(eyebrow)
            Text(title, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
        }
        Spacer(Modifier.weight(1f))
        IconButton(onClick = onClose) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
    }
}

private fun waveformLevels(seedText: String, count: Int): List<Float> {
    var seed = seedText.hashCode().toLong().and(0xffffffffL).coerceAtLeast(1L)
    var previous = .58f
    return List(count) { index ->
        seed = (seed * 1_664_525 + 1_013_904_223).and(0xffffffffL)
        val noise = seed.toFloat() / 0xffffffffL.toFloat()
        previous = previous * .54f + noise * .46f
        val envelope = .58f + kotlin.math.sin(index * .083f) * .16f + kotlin.math.sin(index * .029f) * .11f
        (previous * .62f + envelope * .38f).coerceIn(.12f, 1f)
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
private fun LegacyClipEditorDialog(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    var selectedTrackId by remember { mutableStateOf(state.currentTrackId ?: state.tracks.firstOrNull()?.id) }
    val selectedTrack = state.tracks.firstOrNull { it.id == selectedTrackId }
    var startMs by remember { mutableLongStateOf(0L) }
    var endMs by remember { mutableLongStateOf(selectedTrack?.durationMs?.takeIf { it > 0L } ?: 0L) }
    var startText by remember {
        mutableStateOf(if ((selectedTrack?.durationMs ?: 0L) > 0L) "0:00" else "--:--")
    }
    var endText by remember {
        mutableStateOf(selectedTrack?.durationMs?.takeIf { it > 0L }?.let(::clipTime) ?: "--:--")
    }
    var trackMenu by remember { mutableStateOf(false) }
    var previewing by remember { mutableStateOf(false) }
    var previewPositionMs by remember { mutableLongStateOf(0L) }
    var resumeMainAfterPreview by remember { mutableStateOf(false) }
    val previewPlayer = remember { ExoPlayer.Builder(context).build() }

    fun updateTexts() {
        startText = clipTime(startMs)
        endText = clipTime(endMs)
    }

    fun resetRange(track: Track?) {
        if (track == null) return
        if (track.durationMs <= 0L) {
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
        if (endMs - startMs < 250) {
            startMs = 0
            endMs = track.durationMs
        }
        previewPositionMs = startMs
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
        if (path != null) {
            previewPlayer.setMediaItem(MediaItem.fromUri(Uri.fromFile(File(path))))
            previewPlayer.prepare()
            previewPlayer.seekTo(startMs)
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
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxHeight(.92f).padding(horizontal = 14.dp),
            color = Color(0xFF08090E),
            shape = RoundedCornerShape(22.dp),
            tonalElevation = 8.dp,
        ) {
            Column(Modifier.fillMaxSize()) {
                ToolHeader("Clip Editor", "Choose the range this profile should play.", onDismiss)
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    if (selectedTrack == null) {
                        ToolEmpty("No songs to edit", "Import or download a song, then return to set its playback range.")
                    } else {
                        Box {
                            OutlinedButton(onClick = { trackMenu = true }, modifier = Modifier.fillMaxWidth()) {
                                Text(selectedTrack.title + " — " + selectedTrack.artist, maxLines = 1)
                            }
                            DropdownMenu(expanded = trackMenu, onDismissRequest = { trackMenu = false }) {
                                state.tracks.forEach { track ->
                                    DropdownMenuItem(
                                        text = { Text(track.title + " — " + track.artist) },
                                        onClick = {
                                            selectedTrackId = track.id
                                            trackMenu = false
                                        },
                                    )
                                }
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Artwork(
                                path = state.artworkPathsByTrackId[selectedTrack.id],
                                modifier = Modifier.size(54.dp),
                            )
                            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                Text(selectedTrack.title, fontWeight = FontWeight.Bold, maxLines = 1)
                                Text(
                                    selectedTrack.artist + " • " + selectedTrack.album,
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                    maxLines = 1,
                                )
                            }
                            Text(selectedTrack.durationText, fontSize = 12.sp)
                        }
                        if (selectedTrack.durationMs <= 0L) {
                            Text(
                                "Resonance couldn't read this song's duration. Re-import it or repair its metadata before setting a clip range.",
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                                fontSize = 13.sp,
                            )
                        } else {
                        if (isVideoClipTrack(selectedTrack)) {
                            ClipVideoPreview(
                                player = previewPlayer,
                                isPlaying = previewing,
                                title = selectedTrack.title,
                            )
                        }
                        ClipWaveform(
                            track = selectedTrack,
                            startMs = startMs,
                            endMs = endMs,
                            onRangeChange = { start, end ->
                                stopPreview()
                                startMs = start
                                endMs = end
                                previewPositionMs = start
                                previewPlayer.seekTo(start)
                                updateTexts()
                            },
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            ClipTimeField(
                                "START",
                                startText,
                                {
                                    startText = it
                                },
                                {
                                    val parsed = parseClipTime(startText)
                                    if (parsed != null) {
                                        stopPreview()
                                        startMs = parsed.coerceIn(0, endMs - 250)
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                    }
                                    updateTexts()
                                },
                                Modifier.weight(1f),
                            )
                            Column(
                                Modifier.weight(1f).padding(top = 8.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                            ) {
                                Eyebrow("Clip Length")
                                Text(clipTime(endMs - startMs), color = Violet, fontWeight = FontWeight.Bold)
                            }
                            ClipTimeField(
                                "END",
                                endText,
                                {
                                    endText = it
                                },
                                {
                                    val parsed = parseClipTime(endText)
                                    if (parsed != null) {
                                        stopPreview()
                                        endMs = parsed.coerceIn(startMs + 250, selectedTrack.durationMs)
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                    }
                                    updateTexts()
                                },
                                Modifier.weight(1f),
                            )
                        }
                        ClipPreviewTransport(
                            enabled = state.trackFilePathsById[selectedTrack.id] != null,
                            isPlaying = previewing,
                            positionMs = previewPositionMs,
                            startMs = startMs,
                            endMs = endMs,
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
                            onSeek = { position ->
                                previewPositionMs = position
                                previewPlayer.seekTo(position)
                            },
                        )
                        Text(
                            "Saved for " + activeSyncProfileName(state) + ". The song file is never changed.",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (selectedTrack.id in state.clipRangesByTrackId) {
                                OutlinedButton(
                                    onClick = {
                                        stopPreview()
                                        actions.clearClipRange(selectedTrack.id)
                                        startMs = 0
                                        endMs = selectedTrack.durationMs
                                        previewPositionMs = startMs
                                        previewPlayer.seekTo(startMs)
                                        updateTexts()
                                    },
                                    modifier = Modifier.weight(1f),
                                ) { Text("Use Full Song") }
                            } else {
                                Spacer(Modifier.weight(1f))
                            }
                            Button(
                                onClick = {
                                    focus.clearFocus()
                                    stopPreview()
                                    actions.saveClipRange(selectedTrack.id, startMs, endMs)
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Violet),
                                modifier = Modifier.weight(1f),
                            ) { Text("Save Range") }
                        }
                        }
                    }
                }
            }
        }
    }
}

@Composable
@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
private fun ClipVideoPreview(
    player: ExoPlayer,
    isPlaying: Boolean,
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
        if (!isPlaying) {
            Surface(
                color = Color.Black.copy(alpha = .58f),
                shape = RoundedCornerShape(999.dp),
            ) {
                Icon(
                    Icons.Default.PlayArrow,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.padding(14.dp).size(26.dp),
                )
            }
        }
        Surface(
            modifier = Modifier.align(Alignment.TopStart).padding(10.dp),
            color = Color.Black.copy(alpha = .65f),
            shape = RoundedCornerShape(999.dp),
        ) {
            Text(
                "VIDEO PREVIEW",
                modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                color = Color.White,
                fontSize = 9.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 1.sp,
            )
        }
    }
}

@Composable
private fun ClipPreviewTransport(
    enabled: Boolean,
    isPlaying: Boolean,
    positionMs: Long,
    startMs: Long,
    endMs: Long,
    onToggle: () -> Unit,
    onSeek: (Long) -> Unit,
) {
    val safeEnd = endMs.coerceAtLeast(startMs + 250)
    Surface(
        color = Color.White.copy(alpha = .05f),
        shape = RoundedCornerShape(14.dp),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = .08f)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconButton(onClick = onToggle, enabled = enabled) {
                Surface(color = Violet, shape = RoundedCornerShape(999.dp)) {
                    Icon(
                        if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        contentDescription = if (isPlaying) "Pause preview" else "Play preview",
                        tint = Color.White,
                        modifier = Modifier.padding(9.dp).size(20.dp),
                    )
                }
            }
            Text(
                clipTime(positionMs.coerceIn(startMs, safeEnd)),
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .62f),
                fontSize = 10.sp,
            )
            Slider(
                value = positionMs.coerceIn(startMs, safeEnd).toFloat(),
                onValueChange = { onSeek(it.toLong().coerceIn(startMs, safeEnd)) },
                valueRange = startMs.toFloat()..safeEnd.toFloat(),
                enabled = enabled,
                modifier = Modifier.weight(1f).semantics { contentDescription = "Preview position" },
            )
            Text(
                clipTime(endMs),
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = .62f),
                fontSize = 10.sp,
            )
        }
    }
}

private fun isVideoClipTrack(track: Track): Boolean = isVideoClipPath(track.relativePath)

internal fun isVideoClipPath(path: String): Boolean =
    path.substringAfterLast('.', "").lowercase() in setOf("mp4", "mov", "m4v", "webm")

@Composable
private fun ClipWaveform(
    track: Track,
    startMs: Long,
    endMs: Long,
    onRangeChange: (Long, Long) -> Unit,
) {
    var draggingStart by remember { mutableStateOf(true) }
    val duration = track.durationMs.coerceAtLeast(250)
    val levels = remember(track.id) { waveformLevels(track.id) }
    val currentStartMs by rememberUpdatedState(startMs)
    val currentEndMs by rememberUpdatedState(endMs)
    val currentOnRangeChange by rememberUpdatedState(onRangeChange)
    Canvas(
        modifier = Modifier
            .fillMaxWidth()
            .height(108.dp)
            .background(Color.White.copy(alpha = .035f), RoundedCornerShape(14.dp))
            .semantics { contentDescription = "Clip waveform with draggable start and end handles" }
            .pointerInput(track.id, duration) {
                detectDragGestures(
                    onDragStart = { offset ->
                        val startX = size.width * currentStartMs.toFloat() / duration
                        val endX = size.width * currentEndMs.toFloat() / duration
                        draggingStart = kotlin.math.abs(offset.x - startX) <= kotlin.math.abs(offset.x - endX)
                    },
                ) { change, _ ->
                    change.consume()
                    val value = (change.position.x / size.width.coerceAtLeast(1) * duration)
                        .toLong().coerceIn(0, duration)
                    if (draggingStart) {
                        currentOnRangeChange(value.coerceAtMost(currentEndMs - 250), currentEndMs)
                    } else {
                        currentOnRangeChange(currentStartMs, value.coerceAtLeast(currentStartMs + 250))
                    }
                }
            },
    ) {
        val gap = 2.dp.toPx()
        val barWidth = (size.width - gap * (levels.size - 1)) / levels.size
        levels.forEachIndexed { index, level ->
            val x = index * (barWidth + gap)
            val center = (index + .5f) / levels.size
            val selected = center >= startMs.toFloat() / duration && center <= endMs.toFloat() / duration
            val height = size.height * (.2f + .65f * level)
            drawRoundRect(
                color = if (selected) Violet else Color.White.copy(alpha = .16f),
                topLeft = Offset(x, (size.height - height) / 2),
                size = androidx.compose.ui.geometry.Size(barWidth.coerceAtLeast(1f), height),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(barWidth / 2),
            )
        }
        val startX = size.width * startMs / duration.toFloat()
        val endX = size.width * endMs / duration.toFloat()
        drawHandle(startX, pointsRight = true)
        drawHandle(endX, pointsRight = false)
        drawRoundRect(
            color = Color.White.copy(alpha = .08f),
            style = Stroke(1.dp.toPx()),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(14.dp.toPx()),
        )
    }
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawHandle(x: Float, pointsRight: Boolean) {
    val halfWidth = 11.dp.toPx()
    val halfHeight = 20.dp.toPx()
    drawRoundRect(
        color = Violet,
        topLeft = Offset((x - halfWidth).coerceIn(0f, size.width - halfWidth * 2), size.height / 2 - halfHeight),
        size = androidx.compose.ui.geometry.Size(halfWidth * 2, halfHeight * 2),
        cornerRadius = androidx.compose.ui.geometry.CornerRadius(halfWidth),
    )
    val centerX = x.coerceIn(halfWidth, size.width - halfWidth)
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
    drawPath(path, Color.White)
}

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
        state.serverUploadMode in setOf(
            ServerUploadMode.ServerSourceLink,
            ServerUploadMode.ReviewedMatch,
        )
    var uploadAfterImport by rememberSaveable { mutableStateOf(false) }
    val focus = LocalFocusManager.current
    val clipboard = LocalClipboardManager.current
    val importState = state.linkImport
    val reviewedMatchPolicyBound = importState.resolution?.reviewedMatchPolicyBound == true
    val uploadInputAccepted = when (state.serverUploadMode) {
        ServerUploadMode.ServerSourceLink -> runCatching {
            SourceImportPolicy.canonicalYouTubePageURL(source)
        }.isSuccess
        ServerUploadMode.ReviewedMatch -> LinkImportInput.isReviewedTrackLink(source)
        else -> false
    }
    val modeSubtitle = when (state.serverUploadMode) {
        ServerUploadMode.ServerSourceLink ->
            "For server upload, paste the exact https://www.youtube.com/watch?v=… page. Searches and other links stay device-only."
        ServerUploadMode.ReviewedMatch ->
            "For server upload, paste one full Spotify track or individual YouTube video link. Search text and SoundCloud stay device-only."
        else -> "Search Spotify, SoundCloud, and YouTube, or inspect a supported link directly."
    }
    val inputLabel = when (state.serverUploadMode) {
        ServerUploadMode.ServerSourceLink -> "Exact YouTube page or device-only search"
        ServerUploadMode.ReviewedMatch -> "Spotify/YouTube track link or device-only search"
        else -> "Search or link"
    }
    val inputPlaceholder = when (state.serverUploadMode) {
        ServerUploadMode.ServerSourceLink -> "https://www.youtube.com/watch?v=…"
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
            color = Color(0xFF08090E),
            shape = RoundedCornerShape(22.dp),
        ) {
            Column(Modifier.fillMaxSize()) {
                ToolHeader("Import from Link", modeSubtitle, close)
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
                                            "Choose one server-ranked candidate explicitly. The exact selected audio is downloaded, verified, then uploaded as local bytes; hidden fallbacks are disabled."
                                        } else if (!uploadInputAccepted) {
                                            when (state.serverUploadMode) {
                                                ServerUploadMode.ServerSourceLink ->
                                                    "Server upload is off until this is the exact canonical YouTube watch page. Generic searches, SoundCloud, Spotify, shortened links, and playlists remain device-only."
                                                ServerUploadMode.ReviewedMatch ->
                                                    "Server upload is off until this is one full Spotify track or individual YouTube video link. Generic search, SoundCloud, and playlists remain device-only."
                                                else -> "Server upload is unavailable for this input."
                                            }
                                        } else when (state.serverUploadMode) {
                                            ServerUploadMode.ServerSourceLink ->
                                                "The original YouTube page is sent to the active server profile; no provider playback URL is stored."
                                            ServerUploadMode.ReviewedMatch ->
                                                "After you review the match, its verified local bytes upload to the active server profile."
                                            else -> "Server upload is unavailable for link-derived audio."
                                        }
                                    } else {
                                        "Choose Source link or Reviewed match in Server settings, or keep this import only on this device."
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
                                Eyebrow(if (isPlaylist) "$playlistProvider Playlist" else "Matched Track")
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
                                )
                                if (!isPlaylist && (existing.isOnDevice || existing.isOnServer)) {
                                    Text(
                                        linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                                        fontSize = 12.sp,
                                        color = SuccessGreen,
                                    )
                                }
                            }
                        }
                        resolution.playlist?.skippedItems?.takeIf { it.isNotEmpty() }?.let { skippedItems ->
                            Surface(color = Color(0xFFFF9800).copy(alpha = .10f), shape = RoundedCornerShape(13.dp)) {
                                Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                                    Eyebrow("Skipped by $playlistProvider or Matching")
                                    skippedItems.forEach { skipped ->
                                        Text(
                                            "${skipped.position}. ${skipped.title}${skipped.artist?.let { " — $it" }.orEmpty()}",
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.SemiBold,
                                        )
                                        Text(
                                            skipped.reason,
                                            fontSize = 11.sp,
                                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                        )
                                    }
                                }
                            }
                        }
                        Eyebrow(
                            when {
                                reviewedMatchPolicyBound -> "Review-only candidates • explicit choice required"
                                isPlaylist -> "Tracks to Import"
                                else -> "Audio Source"
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
                                onClick = { actions.selectLinkImportCandidate(candidate.videoID) },
                                color = Color.White.copy(alpha = if (selected) .08f else .035f),
                                shape = RoundedCornerShape(12.dp),
                            ) {
                                Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                    if (isPlaylist) {
                                        Checkbox(checked = selected, onCheckedChange = { actions.selectLinkImportCandidate(candidate.videoID) })
                                    } else {
                                        RadioButton(selected = selected, onClick = { actions.selectLinkImportCandidate(candidate.videoID) })
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
                                            )
                                            if (existing.isOnDevice || existing.isOnServer) {
                                                Text(
                                                    linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                                                    fontSize = 11.sp,
                                                    color = SuccessGreen,
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
                                importState.errorCode?.let { Text(it, fontSize = 11.sp, color = Color.White.copy(alpha = .55f)) }
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
                            colors = ButtonDefaults.buttonColors(containerColor = Violet),
                        ) {
                            Icon(Icons.Default.Search, null)
                            Spacer(Modifier.size(6.dp))
                            Text("Find Audio")
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
                            colors = ButtonDefaults.buttonColors(containerColor = Violet),
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
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Eyebrow("Search Results")
            Spacer(Modifier.weight(1f))
            Text(
                "${response.results.size} previewable",
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = Violet,
            )
        }
        LinkImportSearchProvider.entries.forEach { provider ->
            val results = response.resultsFor(provider)
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Eyebrow(provider.displayName)
                    Spacer(Modifier.weight(1f))
                    Text(
                        "${results.size} result${if (results.size == 1) "" else "s"}",
                        fontSize = 11.sp,
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
        onClick = { actions.selectLinkImportSearchResult(result.id) },
        color = Color.White.copy(alpha = if (selected) .08f else .035f),
        shape = RoundedCornerShape(12.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            RadioButton(selected = selected, onClick = { actions.selectLinkImportSearchResult(result.id) })
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
                )
                if (existing.isOnDevice || existing.isOnServer) {
                    Text(
                        linkExistingStatus(existing.isOnDevice, existing.isOnServer),
                        fontSize = 11.sp,
                        color = SuccessGreen,
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
                    if (state.stage == LinkImportStage.Complete) Icons.Default.CheckCircle else Icons.Default.MusicNote,
                    null,
                    tint = if (state.stage == LinkImportStage.Complete) SuccessGreen else Violet,
                )
                Spacer(Modifier.size(8.dp))
                Text(linkStageTitle(state.stage), fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                if (state.isRunning) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            }
            Text(linkStageDetail(state.stage), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
            if (state.totalBytes > 0) {
                LinearProgressIndicator(
                    progress = { state.completedBytes.toFloat() / state.totalBytes.coerceAtLeast(1) },
                    modifier = Modifier.fillMaxWidth(),
                    color = Violet,
                )
                Text(
                    android.text.format.Formatter.formatFileSize(LocalContext.current, state.completedBytes) + " of " +
                        android.text.format.Formatter.formatFileSize(LocalContext.current, state.totalBytes),
                    fontSize = 11.sp,
                )
            }
            state.completedTrackTitle?.let {
                Text("Added “" + it + "” to this device.", color = SuccessGreen, fontSize = 13.sp)
            }
            state.batchCurrentTitle?.let { Text(it, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .7f)) }
            state.completedSummary?.let { Text(it, color = SuccessGreen, fontSize = 13.sp) }
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
        Icon(Icons.Default.MusicNote, null, Modifier.size(44.dp), tint = Violet)
        Text(title, fontWeight = FontWeight.Bold)
        Text(
            detail,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
            textAlign = TextAlign.Center,
        )
    }
}

private fun waveformLevels(seedValue: String): List<Float> {
    var seed = seedValue.hashCode().toLong().let { if (it == 0L) 1L else it }
    var previous = .58f
    return List(72) { index ->
        seed = seed * 1_664_525 + 1_013_904_223
        val noise = (seed and 0xffff).toFloat() / 0xffff
        previous = previous * .54f + noise * .46f
        val envelope = .58f + kotlin.math.sin(index * .083).toFloat() * .16f +
            kotlin.math.sin(index * .029).toFloat() * .11f
        (previous * .62f + envelope * .38f).coerceIn(.12f, 1f)
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

private fun linkStageTitle(stage: LinkImportStage): String = when (stage) {
    LinkImportStage.Idle -> "Ready"
    LinkImportStage.ResolvingMetadata -> "Resolving Metadata"
    LinkImportStage.SearchingCandidates -> "Searching Audio Sources"
    LinkImportStage.AwaitingSelection -> "Choose an Audio Source"
    LinkImportStage.InspectingSource -> "Inspecting Source"
    LinkImportStage.Downloading -> "Downloading"
    LinkImportStage.SavingLocal -> "Saving on Device"
    LinkImportStage.Syncing -> "Uploading"
    LinkImportStage.Complete -> "Import Complete"
    LinkImportStage.Failed -> "Import Failed"
    LinkImportStage.Cancelled -> "Cancelled"
}

private fun linkStageDetail(stage: LinkImportStage): String = when (stage) {
    LinkImportStage.Idle -> "Enter text to search Spotify, SoundCloud, and YouTube, or paste a supported link."
    LinkImportStage.ResolvingMetadata -> "Reading title, artist, artwork, and duration."
    LinkImportStage.SearchingCandidates -> "Querying Spotify, SoundCloud, and YouTube for previewable audio."
    LinkImportStage.AwaitingSelection -> "Review the match before saving audio locally."
    LinkImportStage.InspectingSource -> "Verifying a direct audio stream."
    LinkImportStage.Downloading -> "Downloading verified audio directly to this device."
    LinkImportStage.SavingLocal -> "Adding the finished file to Resonance."
    LinkImportStage.Syncing -> "Uploading locally saved songs to the active server profile."
    LinkImportStage.Complete -> "The song is stored locally and ready to play."
    LinkImportStage.Failed -> "Review the error below and try another source."
    LinkImportStage.Cancelled -> "No unfinished import was kept."
}

private fun linkExistingStatus(onDevice: Boolean, onServer: Boolean): String = when {
    onDevice && onServer -> "On device and server — both transfers will be skipped"
    onDevice -> "On device — download will be skipped"
    onServer -> "On server — upload will be skipped"
    else -> ""
}
