package mov.unblocked.resonance.playback

import android.app.PendingIntent
import android.content.Intent
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.ShuffleOrder
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlin.random.Random
import mov.unblocked.resonance.MainActivity

@UnstableApi
class PlaybackService : MediaSessionService() {
    private var player: ExoPlayer? = null
    private var session: MediaSession? = null
    private lateinit var audioAttributes: AudioAttributes
    private lateinit var mediaSourceFactory: DefaultMediaSourceFactory
    private val crossfadeHandler = Handler(Looper.getMainLooper())
    private var crossfadePlayer: ExoPlayer? = null
    private var crossfadeNextMediaID: String? = null
    private var crossfadeDurationMs = 0L
    private var crossfadeStarted = false
    private var crossfadeUpdatesRunning = false
    private var shuffledQueueMediaIDs: List<String>? = null
    private var remainingShuffledMediaIDs = mutableSetOf<String>()
    private val playbackPreferences by lazy { getSharedPreferences("resonance.playback", 0) }
    private val playbackPreferenceListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == "crossfadeEnabled") refreshCrossfadeUpdateSchedule()
        }
    private val crossfadeRunnable = object : Runnable {
        override fun run() {
            if (!crossfadeUpdatesRunning) return
            updateCrossfade()
            if (crossfadeUpdatesRunning) {
                crossfadeHandler.postDelayed(
                    this,
                    if (crossfadeStarted) CrossfadeTickMs else CrossfadePreparationTickMs,
                )
            }
        }
    }
    private val clipListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            handlePrimaryTransition(mediaItem, reason)
            seekToClipStartIfNeeded(mediaItem)
            if (reason == Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED) {
                // Starting a queue again from a user-selected song deserves a new cycle even when
                // the queue contains the same IDs as before.
                shuffledQueueMediaIDs = null
                refreshShuffleOrderForQueue()
            } else {
                advanceShuffleCycle(mediaItem)
            }
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            if (reason == Player.DISCONTINUITY_REASON_SEEK) cancelCrossfade()
            seekToClipStartIfNeeded(player?.currentMediaItem)
        }

        override fun onIsPlayingChanged(isPlaying: Boolean) {
            refreshCrossfadeUpdateSchedule()
        }

        override fun onTimelineChanged(timeline: androidx.media3.common.Timeline, reason: Int) {
            refreshShuffleOrderForQueue()
            refreshCrossfadeUpdateSchedule()
        }

        override fun onShuffleModeEnabledChanged(shuffleModeEnabled: Boolean) {
            shuffledQueueMediaIDs = null
            remainingShuffledMediaIDs.clear()
            if (shuffleModeEnabled) refreshShuffleOrderForQueue()
            refreshCrossfadeUpdateSchedule()
        }

        override fun onRepeatModeChanged(repeatMode: Int) {
            refreshCrossfadeUpdateSchedule()
        }

        override fun onPlaybackParametersChanged(playbackParameters: androidx.media3.common.PlaybackParameters) {
            crossfadePlayer?.playbackParameters = playbackParameters
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            val player = player ?: return
            if (playbackState != Player.STATE_ENDED || player.repeatMode == Player.REPEAT_MODE_ONE) return
            val start = clipStartMs(player.currentMediaItem)
            player.pause()
            player.seekTo(start)
        }
    }
    private val sessionCallback = object : MediaSession.Callback {
        override fun onAddMediaItems(
            mediaSession: MediaSession,
            controller: MediaSession.ControllerInfo,
            mediaItems: List<MediaItem>,
        ): ListenableFuture<List<MediaItem>> = Futures.immediateFuture(
            mediaItems.map(::withExactClipEnd),
        )
    }

    override fun onCreate() {
        super.onCreate()
        audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val dataSourceFactory = DefaultDataSource.Factory(
            this,
            AuthenticatedStreamDataSource.Factory(),
        )
        mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)
        val exoPlayer = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .setAudioAttributes(audioAttributes, true)
            .setHandleAudioBecomingNoisy(true)
            .build()
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        player = exoPlayer
        exoPlayer.addListener(clipListener)
        session = MediaSession.Builder(this, exoPlayer)
            .setSessionActivity(pendingIntent)
            .setCallback(sessionCallback)
            .build()
        playbackPreferences.registerOnSharedPreferenceChangeListener(playbackPreferenceListener)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (player?.playWhenReady != true) stopSelf()
    }

    private fun withExactClipEnd(mediaItem: MediaItem): MediaItem {
        val extras = mediaItem.mediaMetadata.extras ?: return mediaItem
        val start = extras.getLong(CLIP_START_MS, 0L).coerceAtLeast(0L)
        val end = ClipBoundaryPolicy.exactEndMs(
            startMs = start,
            endMs = extras.getLong(CLIP_END_MS, C.TIME_UNSET),
        ) ?: return mediaItem
        return mediaItem.buildUpon()
            // Keep positions absolute because the clients persist and seek against source time.
            // Starting playback at CLIP_START_MS prevents pre-roll; Media3 owns the exact end.
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(0L)
                    .setEndPositionMs(end)
                    .build(),
            )
            .build()
    }

    private fun seekToClipStartIfNeeded(mediaItem: MediaItem?) {
        val player = player ?: return
        val start = clipStartMs(mediaItem)
        if (player.currentPosition < start) player.seekTo(start)
    }

    private fun refreshShuffleOrderForQueue() {
        val primary = player ?: return
        if (!primary.shuffleModeEnabled || primary.mediaItemCount <= 0) {
            shuffledQueueMediaIDs = null
            remainingShuffledMediaIDs.clear()
            return
        }
        val mediaIDs = (0 until primary.mediaItemCount).map { primary.getMediaItemAt(it).mediaId }
        if (mediaIDs == shuffledQueueMediaIDs) return
        installFreshShuffleOrder(primary, mediaIDs)
    }

    private fun advanceShuffleCycle(mediaItem: MediaItem?) {
        val primary = player ?: return
        if (!primary.shuffleModeEnabled || primary.mediaItemCount <= 1) return
        val mediaID = mediaItem?.mediaId ?: return
        if (!remainingShuffledMediaIDs.remove(mediaID) || remainingShuffledMediaIDs.isNotEmpty()) return
        val mediaIDs = (0 until primary.mediaItemCount).map { primary.getMediaItemAt(it).mediaId }
        installFreshShuffleOrder(primary, mediaIDs)
    }

    private fun installFreshShuffleOrder(primary: ExoPlayer, mediaIDs: List<String>) {
        shuffledQueueMediaIDs = mediaIDs
        val currentIndex = primary.currentMediaItemIndex
        val order = QueuePolicy.shuffledOrder(primary.mediaItemCount, currentIndex)
        remainingShuffledMediaIDs = mediaIDs.toMutableSet().apply {
            primary.currentMediaItem?.mediaId?.let(::remove)
        }
        primary.setShuffleOrder(ShuffleOrder.DefaultShuffleOrder(order, Random.nextLong()))
    }

    private fun clipStartMs(mediaItem: MediaItem?): Long =
        mediaItem?.mediaMetadata?.extras?.getLong(CLIP_START_MS, 0L)?.coerceAtLeast(0L) ?: 0L

    private fun clipEndMs(owner: Player, mediaItem: MediaItem?): Long {
        val configuredEnd = mediaItem?.mediaMetadata?.extras?.getLong(CLIP_END_MS, C.TIME_UNSET)
            ?: C.TIME_UNSET
        if (configuredEnd != C.TIME_UNSET && configuredEnd > 0L) return configuredEnd
        return owner.duration.takeIf { it != C.TIME_UNSET && it > 0L } ?: 0L
    }

    private fun crossfadeEnabled(): Boolean =
        playbackPreferences.getBoolean("crossfadeEnabled", false)

    private fun requestedCrossfadeSeconds(): Float = CrossfadePolicy.normalizedSeconds(
        playbackPreferences.getFloat("crossfadeSeconds", CrossfadePolicy.DefaultSeconds),
    )

    private fun userPlaybackGain(): Float = PlaybackVolumePolicy.gainForSlider(
        playbackPreferences.getFloat("volume", .8f).coerceIn(0f, 1f),
    )

    private fun startCrossfadeUpdates() {
        if (crossfadeUpdatesRunning) return
        crossfadeUpdatesRunning = true
        crossfadeHandler.post(crossfadeRunnable)
    }

    private fun refreshCrossfadeUpdateSchedule() {
        val primary = player
        val shouldRun = crossfadeEnabled()
            && primary?.isPlaying == true
            && primary.repeatMode != Player.REPEAT_MODE_ONE
            && primary.mediaItemCount > 1
            && primary.nextMediaItemIndex != C.INDEX_UNSET
        if (shouldRun) {
            startCrossfadeUpdates()
        } else {
            stopCrossfadeUpdates()
            if (crossfadePlayer != null) cancelCrossfade()
        }
    }

    private fun stopCrossfadeUpdates() {
        crossfadeUpdatesRunning = false
        crossfadeHandler.removeCallbacks(crossfadeRunnable)
    }

    private fun prepareCrossfadePlayer(primary: ExoPlayer, nextIndex: Int) {
        val nextItem = primary.getMediaItemAt(nextIndex)
        val secondary = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .setAudioAttributes(audioAttributes, false)
            .setHandleAudioBecomingNoisy(false)
            .build()
        secondary.volume = 0f
        secondary.playbackParameters = primary.playbackParameters
        secondary.setMediaItem(nextItem)
        secondary.seekTo(clipStartMs(nextItem))
        secondary.prepare()
        crossfadePlayer = secondary
        crossfadeNextMediaID = nextItem.mediaId
        crossfadeDurationMs = 0L
        crossfadeStarted = false
    }

    private fun updateCrossfade() {
        val primary = player ?: return
        if (!crossfadeEnabled()
            || primary.repeatMode == Player.REPEAT_MODE_ONE
            || !primary.isPlaying
            || primary.mediaItemCount < 2
            || primary.nextMediaItemIndex == C.INDEX_UNSET
        ) {
            cancelCrossfade()
            return
        }

        val currentItem = primary.currentMediaItem ?: return
        val currentEnd = clipEndMs(primary, currentItem)
        if (currentEnd <= 0L) return
        val remainingMs = currentEnd - primary.currentPosition
        if (remainingMs <= 0L) return

        val nextIndex = primary.nextMediaItemIndex
        val nextItem = primary.getMediaItemAt(nextIndex)
        if (crossfadeNextMediaID != null && crossfadeNextMediaID != nextItem.mediaId) {
            cancelCrossfade()
        }

        val secondary = crossfadePlayer
        val requestedMs = (requestedCrossfadeSeconds() * 1_000L).toLong()
        if (secondary == null) {
            if (remainingMs <= requestedMs + CrossfadePreloadLeadMs) {
                prepareCrossfadePlayer(primary, nextIndex)
            }
            return
        }
        if (secondary.playbackState != Player.STATE_READY) return

        val currentStart = clipStartMs(currentItem)
        val nextStart = clipStartMs(nextItem)
        val nextEnd = clipEndMs(secondary, nextItem)
        crossfadeDurationMs = CrossfadePolicy.effectiveDurationMs(
            requestedSeconds = requestedCrossfadeSeconds(),
            currentDurationMs = currentEnd - currentStart,
            nextDurationMs = nextEnd - nextStart,
        )
        if (crossfadeDurationMs < MinimumUsefulCrossfadeMs) {
            cancelCrossfade()
            return
        }

        if (!crossfadeStarted) {
            if (remainingMs > crossfadeDurationMs) return
            secondary.seekTo(nextStart)
            secondary.play()
            crossfadeStarted = true
        }

        val progress = CrossfadePolicy.progress(remainingMs, crossfadeDurationMs)
        val gain = userPlaybackGain()
        primary.volume = gain * (1f - progress)
        secondary.volume = gain * progress
    }

    private fun handlePrimaryTransition(mediaItem: MediaItem?, reason: Int) {
        val primary = player ?: return
        val secondary = crossfadePlayer ?: return
        if (crossfadeStarted
            && reason == Player.MEDIA_ITEM_TRANSITION_REASON_AUTO
            && mediaItem?.mediaId == crossfadeNextMediaID
        ) {
            val carriedPosition = secondary.currentPosition
            secondary.pause()
            secondary.release()
            clearCrossfadeState()
            if (carriedPosition > clipStartMs(mediaItem)) primary.seekTo(carriedPosition)
            primary.volume = userPlaybackGain()
        } else {
            cancelCrossfade()
        }
    }

    private fun clearCrossfadeState() {
        crossfadePlayer = null
        crossfadeNextMediaID = null
        crossfadeDurationMs = 0L
        crossfadeStarted = false
    }

    private fun cancelCrossfade() {
        crossfadePlayer?.run {
            pause()
            release()
        }
        clearCrossfadeState()
        player?.volume = userPlaybackGain()
    }

    override fun onDestroy() {
        playbackPreferences.unregisterOnSharedPreferenceChangeListener(playbackPreferenceListener)
        stopCrossfadeUpdates()
        cancelCrossfade()
        player?.removeListener(clipListener)
        session?.release()
        session = null
        player?.release()
        player = null
        AuthenticatedStreamRegistry.clearAll()
        ListenAlongProviderStreamPolicy.clearAll()
        super.onDestroy()
    }

    companion object {
        const val CLIP_START_MS = "resonance.clip.start_ms"
        const val CLIP_END_MS = "resonance.clip.end_ms"
        private const val CrossfadeTickMs = 50L
        private const val CrossfadePreparationTickMs = 250L
        private const val CrossfadePreloadLeadMs = 2_000L
        private const val MinimumUsefulCrossfadeMs = 250L
    }
}
