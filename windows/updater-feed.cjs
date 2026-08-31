const RELEASES_API_URL = "https://api.github.com/repos/Drastics-Experiments/resonance/releases?per_page=30";
const WINDOWS_MANIFEST_NAME = "latest.yml";
const MAC_MANIFEST_NAME = "latest-mac.json";
const WINDOWS_DOWNLOAD_PREFIX = "https://github.com/Drastics-Experiments/resonance/releases/download/";
const MAX_RELEASE_LIST_RESPONSE_BYTES = 2 * 1024 * 1024;
const MAX_WINDOWS_MANIFEST_BYTES = 256 * 1024;
const { readResponseJSON, readResponseText } = require("./response-body.cjs");

async function resolveReleaseManifest(manifestName, fetchImpl = fetch, { prerelease = false } = {}) {
  const response = await fetchImpl(RELEASES_API_URL, {
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok) throw new Error(`GitHub release lookup failed with HTTP ${response.status}.`);

  const releases = await readResponseJSON(response, MAX_RELEASE_LIST_RESPONSE_BYTES, "GitHub release list");
  if (!Array.isArray(releases)) throw new Error("GitHub returned an invalid release list.");

  for (const release of releases) {
    if (!release
      || release.draft
      || Boolean(release.prerelease) !== Boolean(prerelease)
      || !Array.isArray(release.assets)) continue;
    const manifest = release.assets.find((asset) => asset?.name === manifestName);
    if (!manifest?.browser_download_url) continue;

    const manifestURL = new URL(manifest.browser_download_url);
    if (manifestURL.protocol !== "https:" || !manifestURL.href.startsWith(WINDOWS_DOWNLOAD_PREFIX)) {
      throw new Error("GitHub returned an unsafe desktop update URL.");
    }
    return {
      tag: String(release.tag_name || ""),
      manifestURL: manifestURL.href,
      feedURL: new URL("./", manifestURL).href,
    };
  }

  const channel = prerelease ? "prerelease" : "stable release";
  throw new Error(`No published ${channel} contains ${manifestName}.`);
}

async function resolveWindowsUpdateFeed(fetchImpl = fetch, options = {}) {
  const release = await resolveReleaseManifest(WINDOWS_MANIFEST_NAME, fetchImpl, options);
  return { tag: release.tag, feedURL: release.feedURL };
}

async function resolveMacUpdateManifest(fetchImpl = fetch, options = {}) {
  const release = await resolveReleaseManifest(MAC_MANIFEST_NAME, fetchImpl, options);
  return { tag: release.tag, manifestURL: release.manifestURL };
}

async function fetchWindowsUpdateVersion(manifestURL, fetchImpl = fetch) {
  let url;
  try { url = new URL(String(manifestURL)); } catch { throw new Error("The Windows update manifest URL is invalid."); }
  if (url.protocol !== "https:"
    || !url.href.startsWith(WINDOWS_DOWNLOAD_PREFIX)
    || !url.pathname.endsWith(`/${WINDOWS_MANIFEST_NAME}`)
    || url.search
    || url.hash) {
    throw new Error("The Windows update manifest URL is unsafe.");
  }
  const response = await fetchImpl(url, { headers: { Accept: "text/yaml", "Cache-Control": "no-cache" } });
  if (!response?.ok) throw new Error(`Windows update manifest returned HTTP ${response?.status || 0}.`);
  const manifest = await readResponseText(response, MAX_WINDOWS_MANIFEST_BYTES, "Windows update manifest");
  const version = manifest.match(/^version:\s*["']?([^\s"']+)["']?\s*$/m)?.[1] || "";
  if (!version) throw new Error("The Windows update manifest has no version.");
  return version;
}

function conciseUpdaterError(error) {
  const message = String(error?.message || "Update check failed").split(/\r?\n/, 1)[0].trim();
  if (/latest\.yml/i.test(message) && /404|not found/i.test(message)) {
    return "The Windows update feed is temporarily unavailable.";
  }
  return message.length > 240 ? `${message.slice(0, 237)}...` : message;
}

function installDownloadedWindowsUpdate(updater) {
  updater.quitAndInstall(true, true);
  return true;
}

module.exports = {
  RELEASES_API_URL,
  conciseUpdaterError,
  fetchWindowsUpdateVersion,
  installDownloadedWindowsUpdate,
  resolveMacUpdateManifest,
  resolveWindowsUpdateFeed,
};
