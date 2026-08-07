package mov.unblocked.resonance.playback

import java.io.IOException

internal data class ValidatedContentRange(
    val start: Long,
    val endInclusive: Long,
    val totalBytes: Long?,
) {
    val length: Long get() = endInclusive - start + 1L
}

internal object StreamRangePolicy {
    private val pattern = Regex("^bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)$")

    fun validatePartialResponse(
        contentRange: String?,
        requestedStart: Long,
        requestedLength: Long?,
        responseLength: Long?,
    ): ValidatedContentRange {
        val match = contentRange?.let(pattern::matchEntire)
            ?: throw IOException("The server stream returned an invalid Content-Range")
        val start = match.groupValues[1].toLongOrNull()
            ?: throw IOException("The server stream returned an invalid Content-Range")
        val end = match.groupValues[2].toLongOrNull()
            ?: throw IOException("The server stream returned an invalid Content-Range")
        val rawTotal = match.groupValues[3]
        val total = if (rawTotal == "*") {
            null
        } else {
            rawTotal.toLongOrNull()
                ?: throw IOException("The server stream returned an invalid Content-Range")
        }
        if (start != requestedStart || end < start || total != null && (total <= end || total <= 0L)) {
            throw IOException("The server stream Content-Range does not match the request")
        }
        val length = try {
            Math.addExact(Math.subtractExact(end, start), 1L)
        } catch (error: ArithmeticException) {
            throw IOException("The server stream Content-Range is too large", error)
        }
        if (responseLength != null && responseLength != length) {
            throw IOException("The server stream length does not match Content-Range")
        }
        if (requestedLength != null && length > requestedLength) {
            throw IOException("The server stream returned more bytes than requested")
        }
        return ValidatedContentRange(start, end, total)
    }

    fun remainingLength(
        requestedLength: Long?,
        responseLength: Long?,
        requestedPosition: Long,
        partialRange: ValidatedContentRange?,
    ): Long? = when {
        partialRange != null -> partialRange.length
        responseLength != null -> {
            val available = (responseLength - requestedPosition).coerceAtLeast(0L)
            requestedLength?.let { minOf(it, available) } ?: available
        }
        requestedLength != null -> requestedLength
        else -> null
    }
}
