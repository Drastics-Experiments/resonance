package mov.unblocked.resonance.playback

import android.app.PendingIntent
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import mov.unblocked.resonance.MainActivity

class PlaybackService : MediaSessionService() {
    private var player: ExoPlayer? = null
    private var session: MediaSession? = null
    private val handler = Handler(Looper.getMainLooper())
    private val boundaryCheck = object : Runnable {
        override fun run() {
            enforceClipBoundary()
            handler.postDelayed(this, 100)
        }
    }
    private val clipListener = object : Player.Listener {
        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            if (reason !in setOf(Player.MEDIA_ITEM_TRANSITION_REASON_AUTO, Player.MEDIA_ITEM_TRANSITION_REASON_SEEK)) return
            val start = mediaItem?.mediaMetadata?.extras?.getLong(CLIP_START_MS, 0L) ?: 0L
            if (start > 0L) player?.seekTo(start)
        }
    }

    override fun onCreate() {
        super.onCreate()
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
            .build()
        val exoPlayer = ExoPlayer.Builder(this)
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
            .build()
        handler.post(boundaryCheck)
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (player?.playWhenReady != true) stopSelf()
    }

    private fun enforceClipBoundary() {
        val player = player ?: return
        val extras = player.currentMediaItem?.mediaMetadata?.extras ?: return
        val start = extras.getLong(CLIP_START_MS, 0L).coerceAtLeast(0L)
        val end = extras.getLong(CLIP_END_MS, C.TIME_UNSET)
        if (end <= start) return
        when {
            player.currentPosition < start -> player.seekTo(start)
            player.isPlaying && player.currentPosition + 20L >= end -> when {
                player.repeatMode == Player.REPEAT_MODE_ONE -> player.seekTo(start)
                player.hasNextMediaItem() -> {
                    player.seekToNextMediaItem()
                    player.play()
                }
                else -> {
                    player.pause()
                    player.seekTo(start)
                }
            }
        }
    }

    override fun onDestroy() {
        handler.removeCallbacks(boundaryCheck)
        player?.removeListener(clipListener)
        session?.release()
        session = null
        player?.release()
        player = null
        super.onDestroy()
    }

    companion object {
        const val CLIP_START_MS = "resonance.clip.start_ms"
        const val CLIP_END_MS = "resonance.clip.end_ms"
    }
}
