package mov.unblocked.resonance.ui

import android.net.Uri
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import java.io.File
import kotlinx.coroutines.delay
import mov.unblocked.resonance.data.LinkImportStage
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
    var endMs by remember { mutableLongStateOf(1L) }
    var startText by remember { mutableStateOf("0:00") }
    var endText by remember { mutableStateOf("0:01") }
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
        val saved = state.clipRangesByTrackId[track.id]
        val defaultStart = if (track.durationMs > 60_000) 15_000L else 0L
        startMs = saved?.startMs ?: defaultStart
        endMs = saved?.endMs ?: minOf(track.durationMs, defaultStart + 45_000L)
        if (endMs - startMs < 250) {
            startMs = 0
            endMs = track.durationMs.coerceAtLeast(250)
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
    var source by remember { mutableStateOf("") }
    var uploadAfterImport by rememberSaveable { mutableStateOf(true) }
    val focus = LocalFocusManager.current
    val clipboard = LocalClipboardManager.current
    val importState = state.linkImport
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
                ToolHeader("Import from Link", "Search Spotify, SoundCloud, and YouTube, or inspect a supported link directly.", close)
                Column(
                    modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedTextField(
                            value = source,
                            onValueChange = { source = it },
                            modifier = Modifier.weight(1f),
                            label = { Text("Search or link") },
                            placeholder = { Text("Song, artist, album, or link") },
                            leadingIcon = { Icon(Icons.Default.Search, null) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Text, imeAction = ImeAction.Search),
                            keyboardActions = KeyboardActions(onSearch = {
                                focus.clearFocus()
                                actions.resolveLinkImport(source)
                            }),
                        )
                        TextButton(onClick = {
                            clipboard.getText()?.text?.takeIf(String::isNotBlank)?.let { source = it }
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
                                    if (state.serverUrl.isNotBlank() && state.serverToken.isNotBlank() && state.serverAdminKey.isNotBlank()) {
                                        "Downloads every selected song first, then uploads missing songs to the active server profile."
                                    } else {
                                        "Configure the access token and admin key, or turn this off for a local-only import."
                                    },
                                    fontSize = 12.sp,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                                )
                            }
                            Switch(checked = uploadAfterImport, onCheckedChange = { uploadAfterImport = it })
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
                                val existing = LinkImportExistingPolicy.match(resolution.track, state.tracks, state.remoteSongs)
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
                        Eyebrow(if (isPlaylist) "Tracks to Import" else "Audio Source")
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
                                        "",
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
                                            val existing = LinkImportExistingPolicy.match(it, state.tracks, state.remoteSongs)
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
                                if (actions.confirmLinkImport(uploadAfterImport)) onDismiss()
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
                "${result.track.title} artwork",
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
                val existing = LinkImportExistingPolicy.match(result.track, state.tracks, state.remoteSongs)
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
        Modifier.fillMaxWidth().padding(vertical = 64.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Default.MusicNote, null, Modifier.size(44.dp), tint = Violet)
        Text(title, fontWeight = FontWeight.Bold)
        Text(detail, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
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
