package mov.unblocked.resonance.playback

import androidx.media3.common.PlaybackException
import mov.unblocked.resonance.ui.PlaybackUiStatus

/** Converts Media3 failures into render-only, user-actionable playback state. */
object PlaybackFailurePolicy {
    fun status(errorCode: Int, message: String?): PlaybackUiStatus.Failed =
        PlaybackUiStatus.Failed(
            message = message?.trim()?.takeIf { it.isNotEmpty() } ?: "This audio could not be played.",
            retryable = isRetryable(errorCode),
        )

    fun isRetryable(errorCode: Int): Boolean = errorCode in setOf(
        PlaybackException.ERROR_CODE_IO_UNSPECIFIED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
        PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
        PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
        PlaybackException.ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE,
        PlaybackException.ERROR_CODE_DECODING_RESOURCES_RECLAIMED,
    )
}
