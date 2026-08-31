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
    val releaseTag: String? = null,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long? = null,
    val releaseNotes: String? = null,
)

data class AndroidUpdateInfo(
    val versionCode: Long,
    val versionName: String,
    val releaseTag: String?,
    val apkUrl: String,
    val sha256: String,
    val sizeBytes: Long?,
    val releaseNotes: String?,
)

@Serializable
internal data class AndroidGitHubRelease(
    @SerialName("tag_name") val tagName: String = "",
    val draft: Boolean = false,
    val prerelease: Boolean = false,
    val assets: List<AndroidGitHubReleaseAsset> = emptyList(),
)

@Serializable
internal data class AndroidGitHubReleaseAsset(
    val name: String? = null,
    @SerialName("browser_download_url") val browserDownloadURL: String? = null,
)

internal data class AndroidReleaseTag(
    val tag: String,
    val versionName: String,
    val prerelease: Boolean,
    val sourceTimestamp: Long?,
)

internal data class AndroidPrereleaseManifest(
    val releaseTag: String,
    val url: String,
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

    fun isExactReleaseAssetURL(value: String, releaseTag: String, assetName: String): Boolean = runCatching {
        val url = URL(value.trim())
        isAllowedURL(url.toString()) &&
            url.protocol == "https" &&
            url.host.equals("github.com", ignoreCase = true) &&
            url.port == -1 &&
            url.query == null &&
            url.ref == null &&
            url.path == "/Drastics-Experiments/resonance/releases/download/$releaseTag/$assetName"
    }.getOrDefault(false)

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
    private val releaseTagPattern = Regex("^v((?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*))(?:-pre\\.([1-9][0-9]{9,11}))?$")

    fun decodeReleaseList(raw: String): List<AndroidGitHubRelease> =
        json.decodeFromString<List<AndroidGitHubRelease>>(raw)

    fun parseReleaseTag(value: String?): AndroidReleaseTag? {
        val tag = value?.trim().orEmpty()
        val match = releaseTagPattern.matchEntire(tag) ?: return null
        val timestamp = match.groupValues[2].takeIf(String::isNotEmpty)?.toLongOrNull()
        if (match.groupValues[2].isNotEmpty() && timestamp == null) return null
        return AndroidReleaseTag(tag, match.groupValues[1], timestamp != null, timestamp)
    }

    fun compareReleaseTags(left: AndroidReleaseTag, right: AndroidReleaseTag): Int {
        val leftVersion = left.versionName.split('.').map(String::toLong)
        val rightVersion = right.versionName.split('.').map(String::toLong)
        for (index in 0..2) {
            if (leftVersion[index] != rightVersion[index]) {
                return leftVersion[index].compareTo(rightVersion[index])
            }
        }
        if (left.prerelease != right.prerelease) return if (left.prerelease) -1 else 1
        val timestamp = (left.sourceTimestamp ?: 0L).compareTo(right.sourceTimestamp ?: 0L)
        return if (timestamp != 0) timestamp else left.tag.compareTo(right.tag)
    }

    fun newestUpdate(candidates: List<AndroidUpdateInfo>): AndroidUpdateInfo? = candidates.maxWithOrNull(
        compareBy<AndroidUpdateInfo> { it.versionCode }
            .thenBy { parseReleaseTag(it.releaseTag)?.sourceTimestamp ?: 0L }
            .thenBy { it.releaseTag.orEmpty() },
    )

    /**
     * Resolves the newest published GitHub prerelease that carries an Android update manifest.
     * GitHub returns releases newest-first, but sorting by its timestamps also protects the
     * developer channel when a response contains releases from more than one feed page.
     */
    fun prereleaseManifest(rawReleaseList: String): AndroidPrereleaseManifest {
        val releases = decodeReleaseList(rawReleaseList)
            .asSequence()
            .mapNotNull { release ->
                val tag = parseReleaseTag(release.tagName)
                if (release.draft || !release.prerelease || tag?.prerelease != true) null else release to tag
            }
            .sortedWith { left, right -> compareReleaseTags(right.second, left.second) }

        val manifest = releases
            .mapNotNull { (release, tag) ->
                release.assets.firstOrNull { it.name == ANDROID_MANIFEST_NAME }
                    ?.browserDownloadURL
                    ?.takeIf {
                        AndroidUpdateNetworkPolicy.isExactReleaseAssetURL(
                            it,
                            tag.tag,
                            ANDROID_MANIFEST_NAME,
                        )
                    }
                    ?.let { AndroidPrereleaseManifest(tag.tag, it) }
            }
            .firstOrNull()
            ?: throw IllegalArgumentException(
                "No published Android prerelease contains $ANDROID_MANIFEST_NAME.",
            )

        return manifest
    }

    fun prereleaseManifestURL(rawReleaseList: String): String = prereleaseManifest(rawReleaseList).url

    fun availableUpdate(
        rawManifest: String,
        currentVersionCode: Long,
        allowInsecureDownloadUrl: Boolean = false,
        expectedReleaseTag: String? = null,
    ): AndroidUpdateInfo? {
        val manifest = json.decodeFromString<AndroidUpdateManifest>(rawManifest)
        require(manifest.schemaVersion == 1) { "Unsupported Android update manifest." }
        if (manifest.versionCode <= currentVersionCode) return null

        val versionName = manifest.versionName.trim()
        require(versionName.isNotEmpty()) { "The update version is missing." }
        val releaseTag = manifest.releaseTag?.trim()?.takeIf(String::isNotEmpty)
        if (expectedReleaseTag != null) {
            val parsedTag = parseReleaseTag(expectedReleaseTag)
            require(parsedTag != null && parsedTag.versionName == versionName && releaseTag == parsedTag.tag) {
                "The update manifest release tag is invalid."
            }
        }
        val apkUrl = manifest.apkUrl.trim()
        require(AndroidUpdateNetworkPolicy.isAllowedURL(apkUrl, allowInsecureDownloadUrl)) {
            "The update download URL is not secure."
        }
        if (expectedReleaseTag != null) {
            require(AndroidUpdateNetworkPolicy.isExactReleaseAssetURL(
                apkUrl,
                expectedReleaseTag,
                "Resonance-Android-$versionName.apk",
            )) { "The update manifest points to the wrong release." }
        }
        val sha256 = manifest.sha256.trim().lowercase()
        require(sha256Pattern.matches(sha256)) { "The update checksum is invalid." }

        return AndroidUpdateInfo(
            versionCode = manifest.versionCode,
            versionName = versionName,
            releaseTag = releaseTag,
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
