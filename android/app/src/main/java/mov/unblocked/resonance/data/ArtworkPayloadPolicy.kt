package mov.unblocked.resonance.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Bounds both the compressed artwork response and the decoded image. A small compressed
 * response can otherwise expand into a very large bitmap before Compose or Media3 sees it.
 */
internal object ArtworkPayloadPolicy {
    const val MAX_BYTES = 10L * 1_024L * 1_024L
    const val MAX_DECODED_EDGE = 8_192
    const val MAX_DECODED_PIXELS = 16L * 1_024L * 1_024L

    fun hasSafeDecodedBounds(bytes: ByteArray): Boolean {
        if (bytes.isEmpty() || bytes.size.toLong() > MAX_BYTES) return false
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        // The bounds-only decode intentionally returns null; dimensions are populated on the
        // options object without allocating the decoded bitmap.
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val width = bounds.outWidth
        val height = bounds.outHeight
        return width > 0 && height > 0 &&
            width <= MAX_DECODED_EDGE && height <= MAX_DECODED_EDGE &&
            width.toLong() * height.toLong() <= MAX_DECODED_PIXELS
    }

    fun decode(bytes: ByteArray): Bitmap? {
        if (!hasSafeDecodedBounds(bytes)) return null
        return BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
    }
}
