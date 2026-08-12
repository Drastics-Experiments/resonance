package mov.unblocked.resonance.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Repeat
import androidx.compose.material.icons.filled.Shuffle
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import kotlin.math.roundToInt

@Composable
fun MiniPlayer(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val track = state.currentTrack ?: return
    val palette = LocalResonancePalette.current
    val singletonStream = state.isTransientPlayback
    val fraction = state.playbackProgressFraction
    val seekInput = if (state.canSeekPlayback) {
        Modifier
            .pointerInput(track.id) {
                detectTapGestures { offset -> actions.seekToFraction(offset.x / size.width.coerceAtLeast(1)) }
            }
            .pointerInput(track.id) {
                detectHorizontalDragGestures { change, _ ->
                    change.consume()
                    actions.seekToFraction(change.position.x / size.width.coerceAtLeast(1))
                }
            }
            .semantics {
                contentDescription = "Playback position"
                progressBarRangeInfo = ProgressBarRangeInfo(fraction ?: 0f, 0f..1f)
                setProgress { value ->
                    actions.seekToFraction(value.coerceIn(0f, 1f))
                    true
                }
            }
    } else {
        Modifier
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(palette.panel.copy(alpha = .98f))
            .padding(top = 8.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(
                    role = Role.Button,
                    onClickLabel = "Open now playing",
                    onClick = onOpen,
                )
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (singletonStream) {
                RemoteArtwork(state.transientArtworkURL, state.serverUrl, Modifier.size(46.dp))
            } else {
                Artwork(state.artworkPathsByTrackId[track.id] ?: track.artworkFilename, Modifier.size(46.dp))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(track.title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(track.artist, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f), maxLines = 1)
                CompactPlaybackStatus(state.playbackStatus)
            }
            IconButton(
                onClick = { actions.playPrevious() },
                enabled = !singletonStream,
            ) {
                Icon(
                    Icons.Default.SkipPrevious,
                    "Previous",
                    tint = if (singletonStream) {
                        Color.White.copy(alpha = .24f)
                    } else {
                        MaterialTheme.colorScheme.tertiary
                    },
                )
            }
            IconButton(
                onClick = { actions.togglePlayPause() },
                modifier = Modifier
                    .size(44.dp)
                    .background(palette.raised, CircleShape)
                    .border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = .72f), CircleShape),
            ) {
                if (state.playbackStatus == PlaybackUiStatus.Buffering) {
                    CircularProgressIndicator(Modifier.size(20.dp), color = Color.White, strokeWidth = 2.dp)
                } else {
                    Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (state.isPlaying) "Pause" else "Play", tint = Color.White)
                }
            }
            IconButton(
                onClick = { actions.playNext() },
                enabled = !singletonStream,
            ) {
                Icon(
                    Icons.Default.SkipNext,
                    "Next",
                    tint = if (singletonStream) {
                        Color.White.copy(alpha = .24f)
                    } else {
                        MaterialTheme.colorScheme.tertiary
                    },
                )
            }
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(48.dp)
                .then(seekInput)
                .padding(vertical = 22.dp)
                .background(Color.White.copy(alpha = .13f)),
            contentAlignment = Alignment.CenterStart,
        ) {
            fraction?.let {
                Box(
                    Modifier
                        .fillMaxWidth(it)
                        .fillMaxHeight()
                        .background(MaterialTheme.colorScheme.primary),
                )
            }
        }
    }
}

@Composable
fun NowPlayingScreen(
    state: ResonanceUiState,
    actions: ResonanceActions,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val track = state.currentTrack ?: return
    val palette = LocalResonancePalette.current
    val isServerStream = state.transientCurrentTrack?.id == track.id
    var dragOffset by remember { mutableFloatStateOf(0f) }
    var speedMenu by remember { mutableStateOf(false) }
    val fraction = state.playbackProgressFraction
    val listState = rememberLazyListState()
    val dismissThreshold = with(LocalDensity.current) { 110.dp.toPx() }
    val dismissConnection = remember(listState, dismissThreshold, onDismiss) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput) return Offset.Zero
                if ((available.y > 0f && !listState.canScrollBackward) || dragOffset > 0f) {
                    val previous = dragOffset
                    dragOffset = (dragOffset + available.y).coerceAtLeast(0f)
                    return Offset(x = 0f, y = dragOffset - previous)
                }
                return Offset.Zero
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                if (dragOffset <= 0f) return Velocity.Zero
                val shouldDismiss = dragOffset >= dismissThreshold
                dragOffset = 0f
                if (shouldDismiss) onDismiss()
                return available
            }
        }
    }

    ResonanceBackground(
        modifier = modifier
            .fillMaxSize()
            .offset { IntOffset(0, dragOffset.roundToInt()) }
            .nestedScroll(dismissConnection),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            state = listState,
            contentPadding = PaddingValues(horizontal = 24.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            item {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    IconButton(
                        onClick = onDismiss,
                    ) { Icon(Icons.Default.KeyboardArrowDown, "Minimize") }
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        SectionLabel("Now playing")
                        Text("Resonance", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
                    }
                    Spacer(Modifier.weight(1f))
                    Spacer(Modifier.size(46.dp))
                }
            }
            item {
                if (isServerStream) {
                    RemoteArtwork(
                        state.transientArtworkURL,
                        state.serverUrl,
                        Modifier.fillMaxWidth().heightIn(max = 360.dp).aspectRatio(1f),
                    )
                } else {
                    Artwork(
                        state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
                        Modifier.fillMaxWidth().heightIn(max = 360.dp).aspectRatio(1f),
                    )
                }
            }
            item {
                Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(5.dp)) {
                        Text(track.title, fontSize = 25.sp, fontWeight = FontWeight.Bold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(track.artist, fontSize = 19.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .62f))
                        Text(track.album, fontSize = 14.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .52f))
                    }
                    if (!isServerStream) {
                        IconButton(onClick = { actions.toggleFavorite(track.id) }) {
                            Icon(
                                if (track.id in state.favoriteTrackIds) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                                "Favorite",
                                tint = if (track.id in state.favoriteTrackIds) {
                                    MaterialTheme.colorScheme.tertiary
                                } else {
                                    Color.White
                                },
                                modifier = Modifier.size(28.dp),
                            )
                        }
                    }
                }
            }
            item {
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    PlayerSeekBar(fraction = fraction, enabled = state.canSeekPlayback, onSeek = actions::seekToFraction)
                    Row {
                        Text(durationText(state.playbackElapsedMs), fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
                        Spacer(Modifier.weight(1f))
                        Text(
                            state.playbackDurationMs
                                ?.let { duration -> "-${durationText((duration - state.playbackElapsedMs).coerceAtLeast(0L))}" }
                                ?: "--:--",
                            fontSize = 12.sp,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f),
                        )
                    }
                }
            }
            if (state.playbackStatus == PlaybackUiStatus.Buffering || state.playbackStatus is PlaybackUiStatus.Failed) {
                item {
                    PlaybackStatusNotice(
                        status = state.playbackStatus,
                        onRetry = actions::togglePlayPause,
                    )
                }
            }
            item {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    IconButton(
                        onClick = actions::playPrevious,
                        enabled = !isServerStream,
                        modifier = Modifier.size(60.dp),
                    ) {
                        Icon(Icons.Default.SkipPrevious, "Previous", Modifier.size(35.dp))
                    }
                    IconButton(
                        onClick = actions::togglePlayPause,
                        modifier = Modifier
                            .size(76.dp)
                            .background(palette.raised, CircleShape)
                            .border(2.dp, MaterialTheme.colorScheme.primary.copy(alpha = .72f), CircleShape),
                    ) {
                        if (state.playbackStatus == PlaybackUiStatus.Buffering) {
                            CircularProgressIndicator(Modifier.size(30.dp), color = Color.White, strokeWidth = 3.dp)
                        } else {
                            Icon(if (state.isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow, if (state.isPlaying) "Pause" else "Play", tint = Color.White, modifier = Modifier.size(38.dp))
                        }
                    }
                    IconButton(
                        onClick = actions::playNext,
                        enabled = !isServerStream,
                        modifier = Modifier.size(60.dp),
                    ) {
                        Icon(Icons.Default.SkipNext, "Next", Modifier.size(35.dp))
                    }
                }
            }
            item {
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceAround,
                ) {
                    IconButton(
                        onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                        enabled = !isServerStream,
                    ) {
                        Icon(
                            Icons.Default.Shuffle,
                            "Shuffle",
                            tint = when {
                                isServerStream -> MaterialTheme.colorScheme.onSurface.copy(alpha = .24f)
                                state.shuffleEnabled -> MaterialTheme.colorScheme.tertiary
                                else -> MaterialTheme.colorScheme.onSurface.copy(alpha = .55f)
                            },
                        )
                    }
                    Box {
                        IconButton(onClick = { speedMenu = true }) {
                            Icon(
                                Icons.Default.Speed,
                                "Playback speed",
                                tint = if (state.playbackSpeed != 1f) {
                                    MaterialTheme.colorScheme.tertiary
                                } else {
                                    MaterialTheme.colorScheme.onSurface.copy(alpha = .55f)
                                },
                            )
                        }
                        DropdownMenu(expanded = speedMenu, onDismissRequest = { speedMenu = false }) {
                            listOf(.75f, 1f, 1.25f, 1.5f, 2f).forEach { speed ->
                                DropdownMenuItem(
                                    text = { Text("${speed}×") },
                                    onClick = { actions.setPlaybackSpeed(speed); speedMenu = false },
                                )
                            }
                        }
                    }
                    IconButton(onClick = { actions.setRepeatEnabled(!state.repeatEnabled) }) {
                        Icon(
                            Icons.Default.Repeat,
                            "Repeat",
                            tint = if (state.repeatEnabled) {
                                MaterialTheme.colorScheme.tertiary
                            } else {
                                MaterialTheme.colorScheme.onSurface.copy(alpha = .55f)
                            },
                        )
                    }
                }
            }
            item {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(18.dp))
                        .background(palette.raised)
                        .padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(11.dp),
                ) {
                    SectionLabel("Song details")
                    DetailRow("Title", track.title)
                    DetailRow("Artist", track.artist)
                    DetailRow("Album", track.album)
                    DetailRow("Duration", track.durationMs.takeIf { it > 0L }?.let(::durationText) ?: "Unknown")
                    DetailRow(
                        "Source",
                        when {
                            isServerStream -> "Server stream • not stored"
                            track.sourceServer == null -> "Stored locally"
                            else -> "Music server"
                        },
                    )
                    track.sourceServer?.let { DetailRow("Server", it) }
                }
            }
            item { Spacer(Modifier.height(22.dp)) }
        }
    }
}

@Composable
private fun PlayerSeekBar(
    fraction: Float?,
    enabled: Boolean,
    onSeek: (Float) -> Unit,
) {
    Slider(
        value = fraction?.coerceIn(0f, 1f) ?: 0f,
        onValueChange = onSeek,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .semantics { contentDescription = "Playback position" },
    )
}

@Composable
private fun CompactPlaybackStatus(status: PlaybackUiStatus) {
    when (status) {
        PlaybackUiStatus.Buffering -> Text(
            "Buffering…",
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.tertiary,
            maxLines = 1,
        )
        is PlaybackUiStatus.Failed -> Text(
            status.message,
            fontSize = 12.sp,
            color = MaterialTheme.colorScheme.error,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        else -> Unit
    }
}

@Composable
private fun PlaybackStatusNotice(
    status: PlaybackUiStatus,
    onRetry: () -> Unit,
) {
    val palette = LocalResonancePalette.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(palette.raised)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        when (status) {
            PlaybackUiStatus.Buffering -> {
                CircularProgressIndicator(
                    Modifier.size(20.dp),
                    color = MaterialTheme.colorScheme.primary,
                    strokeWidth = 2.dp,
                )
                Text("Buffering audio…", modifier = Modifier.weight(1f), fontSize = 13.sp)
            }
            is PlaybackUiStatus.Failed -> {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        "Playback failed",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 13.sp,
                        color = MaterialTheme.colorScheme.error,
                    )
                    Text(
                        status.message,
                        fontSize = 12.sp,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = .68f),
                    )
                }
                if (status.retryable) TextButton(onClick = onRetry) { Text("Retry") }
            }
            else -> Unit
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(verticalAlignment = Alignment.Top) {
        Text(label, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .55f), fontSize = 14.sp)
        Spacer(Modifier.weight(1f))
        Text(value, fontSize = 14.sp, textAlign = TextAlign.End, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.fillMaxWidth(.65f))
    }
}
