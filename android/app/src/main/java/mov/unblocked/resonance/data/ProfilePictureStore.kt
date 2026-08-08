package mov.unblocked.resonance.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

object ProfilePictureScope {
    fun contextKey(serverURL: String, profileID: String): String {
        val trimmed = serverURL.trim()
        val normalizedServer = runCatching {
            ServerNetworkPolicy.canonicalOrigin(trimmed, allowCleartextDevelopment = true)
        }.getOrDefault(trimmed)
        val profile = profileID.trim().ifEmpty { "default" }
        return "$normalizedServer#profile=$profile"
    }

    fun filename(serverURL: String, profileID: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(contextKey(serverURL, profileID).toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return "$digest.jpg"
    }
}

class ProfilePictureStore(context: Context) {
    private val appContext = context.applicationContext
    private val directory = File(appContext.filesDir, "Resonance/ProfilePictures")

    fun existingPath(serverURL: String, profileID: String): String? =
        file(serverURL, profileID).takeIf(File::isFile)?.absolutePath

    fun save(source: Uri, serverURL: String, profileID: String): String {
        val descriptorLength = appContext.contentResolver.openAssetFileDescriptor(source, "r")
            ?.use { it.length }
            ?: -1L
        require(descriptorLength < 0 || descriptorLength <= MAX_SOURCE_BYTES) {
            "Profile pictures must be smaller than 32 MB."
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        appContext.contentResolver.openInputStream(source)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            ?: error("The selected picture could not be opened.")
        require(bounds.outWidth > 0 && bounds.outHeight > 0) {
            "The selected file is not a supported picture."
        }
        var sampleSize = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sampleSize > DECODE_PIXEL_SIZE) {
            sampleSize *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sampleSize }
        val decoded = appContext.contentResolver.openInputStream(source)?.use {
            BitmapFactory.decodeStream(it, null, options)
        } ?: error("The selected picture could not be decoded.")
        val side = minOf(decoded.width, decoded.height)
        val cropped = Bitmap.createBitmap(
            decoded,
            (decoded.width - side) / 2,
            (decoded.height - side) / 2,
            side,
            side,
        )
        val output = if (side > OUTPUT_PIXEL_SIZE) {
            Bitmap.createScaledBitmap(cropped, OUTPUT_PIXEL_SIZE, OUTPUT_PIXEL_SIZE, true)
        } else {
            cropped
        }
        directory.mkdirs()
        val destination = file(serverURL, profileID)
        val temporary = File(directory, "${destination.name}.tmp")
        try {
            FileOutputStream(temporary).use { stream ->
                check(output.compress(Bitmap.CompressFormat.JPEG, 88, stream)) {
                    "The profile picture could not be saved."
                }
                stream.flush()
            }
            if (!temporary.renameTo(destination)) {
                temporary.copyTo(destination, overwrite = true)
                temporary.delete()
            }
        } finally {
            if (output !== cropped) output.recycle()
            if (cropped !== decoded) cropped.recycle()
            decoded.recycle()
            temporary.takeIf(File::exists)?.delete()
        }
        return destination.absolutePath
    }

    fun remove(serverURL: String, profileID: String) {
        file(serverURL, profileID).delete()
    }

    private fun file(serverURL: String, profileID: String): File =
        File(directory, ProfilePictureScope.filename(serverURL, profileID))

    private companion object {
        const val MAX_SOURCE_BYTES = 32L * 1_024L * 1_024L
        const val DECODE_PIXEL_SIZE = 1_024
        const val OUTPUT_PIXEL_SIZE = 512
    }
}
