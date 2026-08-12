package mov.unblocked.resonance.update

import java.net.URI
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class AndroidUpdateManifest(
    val schemaVersion: Int = 1,
    val versionCode: Long,
    val versionName: String,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long? = null,
    val releaseNotes: String? = null,
)

data class AndroidUpdateInfo(
    val versionCode: Long,
    val versionName: String,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long?,
    val releaseNotes: String?,
)

internal object AndroidUpdatePolicy {
    private val json = Json { ignoreUnknownKeys = true }
    private val sha256Pattern = Regex("^[a-fA-F0-9]{64}$")

    fun availableUpdate(
        rawManifest: String,
        currentVersionCode: Long,
        allowInsecureDownloadUrl: Boolean = false,
    ): AndroidUpdateInfo? {
        val manifest = json.decodeFromString<AndroidUpdateManifest>(rawManifest)
        require(manifest.schemaVersion == 1) { "Unsupported Android update manifest." }
        if (manifest.versionCode <= currentVersionCode) return null

        val versionName = manifest.versionName.trim()
        require(versionName.isNotEmpty()) { "The update version is missing." }
        val apkUrl = manifest.apkUrl.trim()
        require(isAllowedNetworkURL(apkUrl, allowInsecureDownloadUrl)) {
            "The update download URL is not secure."
        }
        val sha256 = manifest.sha256.trim().lowercase()
        require(sha256Pattern.matches(sha256)) { "The update checksum is invalid." }

        return AndroidUpdateInfo(
            versionCode = manifest.versionCode,
            versionName = versionName,
            apkUrl = apkUrl,
            sha256 = sha256,
            sizeBytes = manifest.sizeBytes?.takeIf { it > 0 },
            releaseNotes = manifest.releaseNotes?.trim()?.takeIf(String::isNotEmpty),
        )
    }

    fun requireMatchingDownloadedVersion(
        update: AndroidUpdateInfo,
        downloadedVersionCode: Long,
        downloadedVersionName: String?,
        currentVersionCode: Long,
    ) {
        require(downloadedVersionCode == update.versionCode && downloadedVersionName == update.versionName) {
            "The downloaded app version did not match the update manifest."
        }
        require(downloadedVersionCode > currentVersionCode) {
            "The downloaded app is not newer than this installation."
        }
    }

    fun isAllowedNetworkURL(value: String, allowLocalDevelopmentHttp: Boolean = false): Boolean = runCatching {
        val uri = URI(value)
        val host = uri.host?.lowercase().orEmpty()
        val commonRequirements = host.isNotBlank() && uri.rawUserInfo == null && uri.rawFragment == null
        commonRequirements && (
            uri.scheme.equals("https", ignoreCase = true) ||
                allowLocalDevelopmentHttp && uri.scheme.equals("http", ignoreCase = true) &&
                    host in localDevelopmentHosts && uri.port >= 0
        )
    }.getOrDefault(false)

    fun isLocalDevelopmentURL(value: String): Boolean = runCatching {
        val uri = URI(value)
        val host = uri.host?.lowercase().orEmpty()
        uri.scheme.equals("http", ignoreCase = true) &&
            host in localDevelopmentHosts &&
            uri.rawUserInfo == null && uri.rawFragment == null && uri.port >= 0
    }.getOrDefault(false)

    private val localDevelopmentHosts = setOf("10.0.2.2", "127.0.0.1", "localhost")
}
