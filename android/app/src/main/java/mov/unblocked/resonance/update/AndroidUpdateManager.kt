package mov.unblocked.resonance.update

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.edit
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import mov.unblocked.resonance.BuildConfig

sealed interface AndroidUpdateState {
    data object Idle : AndroidUpdateState
    data object Checking : AndroidUpdateState
    data class Available(val update: AndroidUpdateInfo) : AndroidUpdateState
    data class Downloading(val update: AndroidUpdateInfo, val progress: Float?) : AndroidUpdateState
    data class ReadyToInstall(val update: AndroidUpdateInfo) : AndroidUpdateState
    data class Failed(val message: String, val update: AndroidUpdateInfo?) : AndroidUpdateState
}

sealed interface AndroidInstallRequest {
    data class Install(val intent: Intent) : AndroidInstallRequest
    data class AllowUnknownSource(val intent: Intent) : AndroidInstallRequest
}

class AndroidUpdateManager(
    context: Context,
    private val manifestUrl: String = DEFAULT_MANIFEST_URL,
) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val updateDirectory = File(appContext.cacheDir, "updates")
    private val mutableState = MutableStateFlow<AndroidUpdateState>(AndroidUpdateState.Idle)
    val state = mutableState.asStateFlow()

    suspend fun checkForUpdateOnStartup() {
        checkForUpdate(force = true)
    }

    suspend fun checkForUpdateIfDue() {
        checkForUpdate(force = false)
    }

    private suspend fun checkForUpdate(force: Boolean) {
        if (mutableState.value !is AndroidUpdateState.Idle) return
        val lastCheck = preferences.getLong(LAST_CHECK_KEY, 0L)
        if (!AndroidUpdateCheckPolicy.shouldCheck(lastCheck, System.currentTimeMillis(), force)) return

        mutableState.value = AndroidUpdateState.Checking
        runCatching {
            val rawManifest = withContext(Dispatchers.IO) { fetchText(manifestUrl) }
            AndroidUpdatePolicy.availableUpdate(
                rawManifest = rawManifest,
                currentVersionCode = BuildConfig.VERSION_CODE.toLong(),
                allowInsecureDownloadUrl = BuildConfig.DEBUG && isEmulatorTestUrl(manifestUrl),
            )
        }.onSuccess { update ->
            preferences.edit { putLong(LAST_CHECK_KEY, System.currentTimeMillis()) }
            mutableState.value = update?.let(AndroidUpdateState::Available) ?: AndroidUpdateState.Idle
        }.onFailure {
            // Automatic checks stay quiet when the device is offline or no release manifest exists yet.
            mutableState.value = AndroidUpdateState.Idle
        }
    }

    suspend fun downloadUpdate(update: AndroidUpdateInfo): File? {
        if (mutableState.value is AndroidUpdateState.Downloading) return null
        mutableState.value = AndroidUpdateState.Downloading(update, null)
        return runCatching {
            withContext(Dispatchers.IO) { downloadAndVerify(update) }
        }.onSuccess {
            mutableState.value = AndroidUpdateState.ReadyToInstall(update)
        }.onFailure { error ->
            mutableState.value = AndroidUpdateState.Failed(
                message = error.message?.takeIf(String::isNotBlank) ?: "The update could not be downloaded.",
                update = update,
            )
        }.getOrNull()
    }

    fun downloadedFile(update: AndroidUpdateInfo): File? =
        File(updateDirectory, apkFilename(update)).takeIf(File::isFile)

    fun createInstallRequest(file: File): AndroidInstallRequest {
        require(file.isFile && file.canonicalFile.parentFile == updateDirectory.canonicalFile) {
            "The downloaded update is missing."
        }
        if (!appContext.packageManager.canRequestPackageInstalls()) {
            return AndroidInstallRequest.AllowUnknownSource(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    "package:${appContext.packageName}".toUri(),
                ),
            )
        }

        val uri = FileProvider.getUriForFile(
            appContext,
            "${appContext.packageName}.fileprovider",
            file,
        )
        return AndroidInstallRequest.Install(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME_TYPE)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    fun dismiss() {
        if (mutableState.value !is AndroidUpdateState.Downloading) {
            mutableState.value = AndroidUpdateState.Idle
        }
    }

    fun reportInstallFailure(error: Throwable) {
        val current = mutableState.value
        val update = when (current) {
            is AndroidUpdateState.Available -> current.update
            is AndroidUpdateState.Downloading -> current.update
            is AndroidUpdateState.ReadyToInstall -> current.update
            is AndroidUpdateState.Failed -> current.update
            else -> null
        }
        mutableState.value = AndroidUpdateState.Failed(
            error.message?.takeIf(String::isNotBlank) ?: "Android could not open the update installer.",
            update,
        )
    }

    private fun fetchText(url: String): String {
        val connection = openConnection(url)
        return try {
            val responseCode = connection.responseCode
            if (responseCode !in 200..299) throw IOException("Update check returned HTTP $responseCode.")
            val length = connection.contentLengthLong
            if (length > MAX_MANIFEST_BYTES) throw IOException("The update manifest is too large.")
            connection.inputStream.bufferedReader(Charsets.UTF_8).use { reader ->
                val text = reader.readText()
                if (text.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST_BYTES) {
                    throw IOException("The update manifest is too large.")
                }
                text
            }
        } finally {
            connection.disconnect()
        }
    }

    private fun downloadAndVerify(update: AndroidUpdateInfo): File {
        updateDirectory.mkdirs()
        val target = File(updateDirectory, apkFilename(update))
        val partial = File(updateDirectory, "${apkFilename(update)}.part")
        partial.delete()
        target.delete()

        val connection = openConnection(update.apkUrl)
        try {
            val responseCode = connection.responseCode
            if (responseCode !in 200..299) throw IOException("Update download returned HTTP $responseCode.")
            val responseLength = connection.contentLengthLong.takeIf { it > 0 }
            val expectedLength = update.sizeBytes ?: responseLength
            if (expectedLength != null && expectedLength > MAX_APK_BYTES) {
                throw IOException("The update download is unexpectedly large.")
            }

            val digest = MessageDigest.getInstance("SHA-256")
            var downloadedBytes = 0L
            connection.inputStream.use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        downloadedBytes += count
                        if (downloadedBytes > MAX_APK_BYTES) {
                            throw IOException("The update download is unexpectedly large.")
                        }
                        digest.update(buffer, 0, count)
                        output.write(buffer, 0, count)
                        mutableState.value = AndroidUpdateState.Downloading(
                            update,
                            expectedLength?.let { (downloadedBytes.toDouble() / it).toFloat().coerceIn(0f, 1f) },
                        )
                    }
                    output.fd.sync()
                }
            }
            if (expectedLength != null && downloadedBytes != expectedLength) {
                throw IOException("The update download was incomplete.")
            }
            val actualChecksum = digest.digest().joinToString("") { byte -> "%02x".format(byte) }
            if (!actualChecksum.equals(update.sha256, ignoreCase = true)) {
                throw IOException("The update checksum did not match.")
            }
            if (!partial.renameTo(target)) partial.copyTo(target, overwrite = true)
            if (partial.exists()) partial.delete()
            verifyPackageIdentity(target, update)
            return target
        } catch (error: Throwable) {
            partial.delete()
            target.delete()
            throw error
        } finally {
            connection.disconnect()
        }
    }

    private fun verifyPackageIdentity(apk: File, update: AndroidUpdateInfo) {
        val packageManager = appContext.packageManager
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            @Suppress("DEPRECATION")
            PackageManager.GET_SIGNATURES
        }
        @Suppress("DEPRECATION")
        val archive = packageManager.getPackageArchiveInfo(apk.absolutePath, flags)
            ?: throw IOException("Android could not read the downloaded update.")
        if (archive.packageName != appContext.packageName) {
            throw IOException("The update belongs to a different application.")
        }
        @Suppress("DEPRECATION")
        val archiveVersionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            archive.longVersionCode
        } else {
            archive.versionCode.toLong()
        }
        AndroidUpdatePolicy.requireMatchingDownloadedVersion(
            update = update,
            downloadedVersionCode = archiveVersionCode,
            downloadedVersionName = archive.versionName,
            currentVersionCode = BuildConfig.VERSION_CODE.toLong(),
        )
        @Suppress("DEPRECATION")
        val installed = packageManager.getPackageInfo(appContext.packageName, flags)
        val installedSigners = installed.signerDigests()
        val archiveSigners = archive.signerDigests()
        if (installedSigners.isEmpty() || archiveSigners.none(installedSigners::contains)) {
            throw IOException("The update signature did not match this installation.")
        }
    }

    @Suppress("DEPRECATION")
    private fun PackageInfo.signerDigests(): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            signingInfo?.let { info ->
                if (info.hasMultipleSigners()) info.apkContentsSigners else info.signingCertificateHistory
            }.orEmpty()
        } else {
            signatures.orEmpty()
        }
        return signatures.mapTo(mutableSetOf()) { signature ->
            MessageDigest.getInstance("SHA-256")
                .digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte) }
        }
    }

    private fun openConnection(url: String): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT_MS
            readTimeout = READ_TIMEOUT_MS
            instanceFollowRedirects = true
            useCaches = false
            setRequestProperty("Accept", "application/json, application/vnd.android.package-archive")
            setRequestProperty("User-Agent", "Resonance-Android/${BuildConfig.VERSION_NAME}")
        }

    private fun apkFilename(update: AndroidUpdateInfo) = "resonance-${update.versionCode}.apk"

    private fun isEmulatorTestUrl(url: String): Boolean =
        DEBUG_EMULATOR_HTTP_PREFIXES.any(url::startsWith)

    companion object {
        const val DEFAULT_MANIFEST_URL =
            "https://github.com/Drastics-Experiments/resonance/releases/latest/download/latest-android.json"
        private const val PREFERENCES_NAME = "resonance.android-updater"
        private const val LAST_CHECK_KEY = "last-successful-check-ms"
        private const val CONNECT_TIMEOUT_MS = 15_000
        private const val READ_TIMEOUT_MS = 30_000
        private const val MAX_MANIFEST_BYTES = 128 * 1024L
        private const val MAX_APK_BYTES = 1024 * 1024 * 1024L
        private const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        private val DEBUG_EMULATOR_HTTP_PREFIXES = listOf(
            "http://10.0.2.2:",
            "http://127.0.0.1:",
        )
    }
}
