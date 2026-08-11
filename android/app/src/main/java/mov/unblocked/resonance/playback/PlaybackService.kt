package mov.unblocked.resonance.playback

import android.app.PendingIntent
import android.content.Intent
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import mov.unblocked.resonance.MainActivity

class PlaybackService : MediaSessionService() {
    private var player: ExoPlayer? = null
    private var session: MediaSession? = null
    private val clipListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            seekToClipStartIfNeeded(mediaItem)
        }

        override fun onPositionDiscontinuity(
            oldPosition: Player.PositionInfo,
            newPosition: Player.PositionInfo,
            reason: Int,
        ) {
            seekToClipStartIfNeeded(player?.currentMediaItem)
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

    @UnstableApi
    override fun onCreate() {
        super.onCreate()
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val dataSourceFactory = DefaultDataSource.Factory(
            this,
            AuthenticatedStreamDataSource.Factory(),
        )
        val exoPlayer = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
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

    private fun clipStartMs(mediaItem: MediaItem?): Long =
        mediaItem?.mediaMetadata?.extras?.getLong(CLIP_START_MS, 0L)?.coerceAtLeast(0L) ?: 0L

    override fun onDestroy() {
        player?.removeListener(clipListener)
        session?.release()
        session = null
        player?.release()
        player = null
        AuthenticatedStreamRegistry.clearAll()
        super.onDestroy()
    }

    companion object {
        const val CLIP_START_MS = "resonance.clip.start_ms"
        const val CLIP_END_MS = "resonance.clip.end_ms"
    }
}
