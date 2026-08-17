package mov.unblocked.resonance.ui

import android.net.Uri
import android.os.SystemClock
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
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
import androidx.compose.material.icons.filled.Groups
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
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.alpha
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt
import androidx.media3.common.PlaybackException
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import mov.unblocked.resonance.data.Track
import java.io.File

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
    val listenAlongGuest = state.listenAlong.showsParticipantPlaybackIndicator
    val transportLocked = singletonStream || listenAlongGuest
    val fraction = state.playbackProgressFraction
    val seekInput = if (state.canSeekPlayback && !listenAlongGuest) {
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
    } else {
        Modifier
    }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(palette.panel.copy(alpha = .98f))
            .clickable(onClick = onOpen)
            .padding(top = 8.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp),
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
                Text(track.artist, fontSize = 11.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f), maxLines = 1)
                CompactPlaybackStatus(state.playbackStatus)
            }
            if (listenAlongGuest) {
                ListenAlongParticipantIndicator(
                    count = state.listenAlong.participantCount,
                    compact = true,
                )
            } else {
                IconButton(
                    onClick = { actions.playPrevious() },
                    enabled = !transportLocked,
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
                    enabled = !transportLocked,
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
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(8.dp)
                .then(seekInput)
                .background(Color.White.copy(alpha = .13f)),
            contentAlignment = Alignment.CenterStart,
        ) {
            fraction?.let {
                Box(
                    Modifier
                        .fillMaxWidth(it)
                        .height(3.dp)
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
    val listenAlongGuest = state.listenAlong.showsParticipantPlaybackIndicator
    val transportLocked = isServerStream || listenAlongGuest
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
                        modifier = Modifier.size(46.dp).background(Color.White.copy(alpha = .08f), CircleShape),
                    ) { Icon(Icons.Default.KeyboardArrowDown, "Minimize") }
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Eyebrow("Now Playing")
                        Text("Resonance", fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurface.copy(alpha = .58f))
                    }
                    Spacer(Modifier.weight(1f))
                    Spacer(Modifier.size(46.dp))
                }
            }
            item {
                NowPlayingMedia(
                    state = state,
                    track = track,
                    playbackPlayerProvider = actions::playbackPlayer,
                    isServerStream = isServerStream,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 360.dp).aspectRatio(1f),
                )
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
                    PlayerSeekBar(
                        fraction = fraction,
                        enabled = state.canSeekPlayback && !listenAlongGuest,
                        onSeek = actions::seekToFraction,
                    )
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
            if (listenAlongGuest) {
                item {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        ListenAlongParticipantIndicator(
                            count = state.listenAlong.participantCount,
                            compact = false,
                        )
                    }
                }
            } else {
                item {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceEvenly,
                    ) {
                        IconButton(
                            onClick = actions::playPrevious,
                            enabled = !transportLocked,
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
                            enabled = !transportLocked,
                            modifier = Modifier.size(60.dp),
                        ) {
                            Icon(Icons.Default.SkipNext, "Next", Modifier.size(35.dp))
                        }
                    }
                }
            }
            if (!listenAlongGuest) {
                item {
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceAround,
                    ) {
                        IconButton(
                            onClick = { actions.setShuffleEnabled(!state.shuffleEnabled) },
                            enabled = !transportLocked,
                        ) {
                            Icon(
                                Icons.Default.Shuffle,
                                "Shuffle",
                                tint = when {
                                    transportLocked -> MaterialTheme.colorScheme.onSurface.copy(alpha = .24f)
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
                    Eyebrow("Song Details")
                    DetailRow("Title", track.title)
                    DetailRow("Artist", track.artist)
                    DetailRow("Album", track.album)
                    DetailRow("Duration", track.durationMs.takeIf { it > 0L }?.let(::durationText) ?: "Unknown")
                    DetailRow(
                        "Source",
                        when {
                            isServerStream -> "Server stream • not stored"
                            listenAlongGuest -> "Listen Along • following host"
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

internal object MobileInstalledVideoPolicy {
    private val videoExtensions = setOf("mp4", "mov", "m4v", "webm")
    const val audioRemainsAudibleOwner = true
    const val usesDedicatedMutedCompanionPlayer = true
    const val allowsSteadyStateReseeking = false
    const val playbackDiscontinuityThresholdMs = 750L
    const val synchronizationPollIntervalMs = 250L

    fun catchUpRate(audioRate: Float, audioPositionMs: Long, videoPositionMs: Long): Float {
        if (!audioRate.isFinite() || audioRate <= 0f) return 1f
        val driftSeconds = (videoPositionMs - audioPositionMs) / 1_000.0
        if (abs(driftSeconds) <= 0.04) return audioRate
        val multiplier = exp(-0.35 * driftSeconds).coerceIn(0.85, 1.20)
        return audioRate * multiplier.toFloat()
    }

    fun isVideo(relativePath: String): Boolean =
        relativePath.substringAfterLast('.', "").lowercase() in videoExtensions
}

@Composable
@androidx.annotation.OptIn(UnstableApi::class)
private fun NowPlayingMedia(
    state: ResonanceUiState,
    track: Track,
    playbackPlayerProvider: () -> Player?,
    isServerStream: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val isInstalledVideo = !isServerStream && MobileInstalledVideoPolicy.isVideo(track.relativePath)
    val videoPlayer = remember(track.id, isInstalledVideo) {
        if (isInstalledVideo) {
            ExoPlayer.Builder(context).build().apply {
                volume = 0f
                repeatMode = Player.REPEAT_MODE_OFF
            }
        } else {
            null
        }
    }
    var firstFrameReady by remember(track.id) { mutableStateOf(false) }
    var videoFailed by remember(track.id) { mutableStateOf(false) }
    val artworkAlpha by animateFloatAsState(
        targetValue = if (isInstalledVideo && firstFrameReady && !videoFailed) 0f else 1f,
        animationSpec = tween(durationMillis = 140),
        label = "installed video artwork",
    )

    LaunchedEffect(track.id, videoPlayer) {
        firstFrameReady = false
        videoFailed = false
    }

    DisposableEffect(track.id, videoPlayer, isInstalledVideo) {
        if (!isInstalledVideo || videoPlayer == null) return@DisposableEffect onDispose {}
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                firstFrameReady = true
            }

            override fun onPlayerError(error: PlaybackException) {
                videoFailed = true
            }
        }
        videoPlayer.addListener(listener)
        onDispose {
            videoPlayer.removeListener(listener)
            videoPlayer.volume = 0f
            videoPlayer.pause()
            videoPlayer.release()
        }
    }

    LaunchedEffect(track.id, videoPlayer, isInstalledVideo) {
        if (!isInstalledVideo || videoPlayer == null) return@LaunchedEffect
        var playbackPlayer = playbackPlayerProvider()
        while (playbackPlayer == null) {
            delay(50L)
            playbackPlayer = playbackPlayerProvider()
        }
        val file = state.trackFilePathsById[track.id]
            ?.let(::File)
            ?.takeIf(File::isFile)
            ?: run { videoFailed = true; return@LaunchedEffect }
        videoPlayer.volume = 0f
        videoPlayer.setPlaybackSpeed(playbackPlayer.playbackParameters.speed)
        videoPlayer.playWhenReady = playbackPlayer.isPlaying
        videoPlayer.setMediaItem(
            MediaItem.fromUri(Uri.fromFile(file)),
            playbackPlayer.currentPosition.coerceAtLeast(0L),
        )
        videoPlayer.prepare()
        var activePlaybackPlayer = playbackPlayer
        var lastAudioPosition = activePlaybackPlayer.currentPosition.coerceAtLeast(0L)
        var lastSampleTime = SystemClock.elapsedRealtime()
        while (true) {
            delay(MobileInstalledVideoPolicy.synchronizationPollIntervalMs)
            val currentPlaybackPlayer = playbackPlayerProvider()
            if (currentPlaybackPlayer == null) {
                videoPlayer.playWhenReady = false
                continue
            }
            if (currentPlaybackPlayer !== activePlaybackPlayer) {
                activePlaybackPlayer = currentPlaybackPlayer
                val replacementPosition = activePlaybackPlayer.currentPosition.coerceAtLeast(0L)
                videoPlayer.seekTo(replacementPosition)
                lastAudioPosition = replacementPosition
                lastSampleTime = SystemClock.elapsedRealtime()
            }
            videoPlayer.volume = 0f
            val audioPosition = activePlaybackPlayer.currentPosition.coerceAtLeast(0L)
            val videoPosition = videoPlayer.currentPosition.coerceAtLeast(0L)
            val audioRate = activePlaybackPlayer.playbackParameters.speed
            val now = SystemClock.elapsedRealtime()
            val expectedAdvance = if (activePlaybackPlayer.isPlaying) {
                ((now - lastSampleTime) * activePlaybackPlayer.playbackParameters.speed).toLong()
            } else {
                0L
            }
            val positionDiscontinuity = abs((audioPosition - lastAudioPosition) - expectedAdvance) >
                MobileInstalledVideoPolicy.playbackDiscontinuityThresholdMs
            lastAudioPosition = audioPosition
            lastSampleTime = now
            val videoRate = if (positionDiscontinuity) {
                videoPlayer.seekTo(audioPosition)
                audioRate
            } else {
                MobileInstalledVideoPolicy.catchUpRate(audioRate, audioPosition, videoPosition)
            }
            if (abs(videoPlayer.playbackParameters.speed - videoRate) > 0.001f) {
                videoPlayer.setPlaybackSpeed(videoRate)
            }
            videoPlayer.playWhenReady = activePlaybackPlayer.isPlaying
        }
    }

    Box(modifier.clip(RoundedCornerShape(18.dp)).background(Color.Black)) {
        if (isInstalledVideo) {
            AndroidView(
                factory = { context ->
                    PlayerView(context).apply {
                        useController = false
                        resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                        setKeepContentOnPlayerReset(true)
                    }
                },
                update = { view -> view.player = videoPlayer },
                onRelease = { view -> view.player = null },
                modifier = Modifier.fillMaxSize(),
            )
        }

        if (isServerStream) {
            RemoteArtwork(
                state.transientArtworkURL,
                state.serverUrl,
                Modifier.fillMaxSize(),
            )
        } else {
            Artwork(
                state.artworkPathsByTrackId[track.id] ?: track.artworkFilename,
                Modifier.fillMaxSize().alpha(artworkAlpha),
                showWaveform = !isInstalledVideo || videoFailed,
            )
        }

        if (isInstalledVideo && !firstFrameReady && !videoFailed) {
            CircularProgressIndicator(
                modifier = Modifier.align(Alignment.Center).size(38.dp),
                color = Color.White,
                strokeWidth = 3.dp,
            )
        }
    }
}

@Composable
private fun ListenAlongParticipantIndicator(count: Int?, compact: Boolean) {
    val palette = LocalResonancePalette.current
    val height = if (compact) 44.dp else 76.dp
    Row(
        modifier = Modifier
            .height(height)
            .background(palette.raised, CircleShape)
            .border(
                width = if (compact) 1.dp else 2.dp,
                color = MaterialTheme.colorScheme.primary.copy(alpha = .72f),
                shape = CircleShape,
            )
            .padding(horizontal = if (compact) 13.dp else 22.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(if (compact) 7.dp else 10.dp),
    ) {
        Icon(
            imageVector = Icons.Default.Groups,
            contentDescription = if (count == null) {
                "Listening Along; playback is controlled by the session host"
            } else {
                "Listening Along with $count people; playback is controlled by the session host"
            },
            tint = Color.White,
            modifier = Modifier.size(if (compact) 22.dp else 34.dp),
        )
        count?.let {
            Text(
                text = it.toString(),
                color = Color.White,
                fontSize = if (compact) 14.sp else 20.sp,
                fontWeight = FontWeight.Bold,
            )
        }
    }
}

@Composable
private fun PlayerSeekBar(
    fraction: Float?,
    enabled: Boolean,
    onSeek: (Float) -> Unit,
) {
    val palette = LocalResonancePalette.current
    val clampedFraction = fraction?.coerceIn(0f, 1f) ?: 0f
    val thumbDiameterPx = with(LocalDensity.current) { 20.dp.toPx() }
    val seekInput = if (enabled) {
        Modifier
            .pointerInput(Unit) {
                detectTapGestures { offset -> onSeek(offset.x / size.width.coerceAtLeast(1)) }
            }
            .pointerInput(Unit) {
                detectHorizontalDragGestures { change, _ ->
                    change.consume()
                    onSeek(change.position.x / size.width.coerceAtLeast(1))
                }
            }
    } else {
        Modifier
    }
    BoxWithConstraints(
        modifier = Modifier
            .fillMaxWidth()
            .height(32.dp)
            .then(seekInput),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            Modifier
                .fillMaxWidth()
                .height(4.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = .15f)),
        )
        Box(
            Modifier
                .fillMaxWidth(clampedFraction)
                .height(4.dp)
                .clip(CircleShape)
                .background(MaterialTheme.colorScheme.primary),
        )
        if (enabled) {
            Box(
                Modifier
                    .offset {
                        IntOffset(
                            x = (clampedFraction * (constraints.maxWidth - thumbDiameterPx)).roundToInt(),
                            y = 0,
                        )
                    }
                    .size(20.dp)
                    .background(palette.tertiary, CircleShape),
            )
        }
    }
}

@Composable
private fun CompactPlaybackStatus(status: PlaybackUiStatus) {
    when (status) {
        PlaybackUiStatus.Buffering -> Text(
            "Buffering…",
            fontSize = 10.sp,
            color = MaterialTheme.colorScheme.tertiary,
            maxLines = 1,
        )
        is PlaybackUiStatus.Failed -> Text(
            status.message,
            fontSize = 10.sp,
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
