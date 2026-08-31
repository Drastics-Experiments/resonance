package mov.unblocked.resonance.update

import java.net.URL
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import mov.unblocked.resonance.data.RemoteURLPolicy

internal object AndroidUpdateCheckPolicy {
    const val DefaultIntervalMillis = 6 * 60 * 60 * 1_000L

    fun shouldCheck(
        lastSuccessfulCheckMillis: Long,
        nowMillis: Long,
        force: Boolean = false,
        intervalMillis: Long = DefaultIntervalMillis,
    ): Boolean {
        require(intervalMillis > 0L) { "The update interval must be positive." }
        if (force || lastSuccessfulCheckMillis <= 0L) return true
        val elapsed = nowMillis - lastSuccessfulCheckMillis
        return elapsed < 0L || elapsed >= intervalMillis
    }
}

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

@Serializable
private data class GitHubAndroidRelease(
    val draft: Boolean = false,
    val prerelease: Boolean = false,
    @SerialName("published_at") val publishedAt: String? = null,
    @SerialName("created_at") val createdAt: String? = null,
    val assets: List<GitHubAndroidReleaseAsset> = emptyList(),
)

@Serializable
private data class GitHubAndroidReleaseAsset(
    val name: String? = null,
    @SerialName("browser_download_url") val browserDownloadURL: String? = null,
)

internal object AndroidUpdateNetworkPolicy {
    private val approvedHosts = setOf(
        "api.github.com",
        "github.com",
        "www.github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
        "github-releases.githubusercontent.com",
    )

    fun isAllowedURL(value: String, allowLocalDevelopment: Boolean = false): Boolean = runCatching {
        RemoteURLPolicy.isSafeURL(
            URL(value.trim()),
            approvedHost = { host -> host in approvedHosts },
            allowCleartextDevelopment = allowLocalDevelopment,
        )
    }.getOrDefault(false)

    fun resolveRedirect(
        currentURL: URL,
        location: String,
        allowLocalDevelopment: Boolean = false,
    ): URL? = RemoteURLPolicy.resolveRedirect(
        currentURL = currentURL,
        location = location,
        approvedHost = { host -> host in approvedHosts },
        allowCleartextDevelopment = allowLocalDevelopment,
    )
}
internal object AndroidUpdatePolicy {
    private val json = Json { ignoreUnknownKeys = true }
    private val sha256Pattern = Regex("^[a-fA-F0-9]{64}$")

    /**
     * Resolves the newest published GitHub prerelease that carries an Android update manifest.
     * GitHub returns releases newest-first, but sorting by its timestamps also protects the
     * developer channel when a response contains releases from more than one feed page.
     */
    fun prereleaseManifestURL(rawReleaseList: String): String {
        val releases = json.decodeFromString<List<GitHubAndroidRelease>>(rawReleaseList)
            .asSequence()
            .filter { it.prerelease && !it.draft }
            .sortedByDescending { it.publishedAt ?: it.createdAt ?: "" }

        val assetURL = releases
            .mapNotNull { release ->
                release.assets.firstOrNull { it.name == ANDROID_MANIFEST_NAME }
                    ?.browserDownloadURL
            }
            .firstOrNull()
            ?: throw IllegalArgumentException(
                "No published Android prerelease contains $ANDROID_MANIFEST_NAME.",
            )

        require(AndroidUpdateNetworkPolicy.isAllowedURL(assetURL)) {
            "The prerelease update manifest URL is not secure."
        }
        return assetURL
    }

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
        require(AndroidUpdateNetworkPolicy.isAllowedURL(apkUrl, allowInsecureDownloadUrl)) {
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

    private const val ANDROID_MANIFEST_NAME = "latest-android.json"

}
