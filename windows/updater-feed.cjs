const RELEASES_API_URL = "https://api.github.com/repos/Drastics-Experiments/resonance/releases?per_page=30";
const WINDOWS_MANIFEST_NAME = "latest.yml";
const WINDOWS_DOWNLOAD_PREFIX = "https://github.com/Drastics-Experiments/resonance/releases/download/";

async function resolveWindowsUpdateFeed(fetchImpl = fetch) {
  const response = await fetchImpl(RELEASES_API_URL, {
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    },
  });
  if (!response.ok) throw new Error(`GitHub release lookup failed with HTTP ${response.status}.`);

  const releases = await response.json();
  if (!Array.isArray(releases)) throw new Error("GitHub returned an invalid release list.");

  for (const release of releases) {
    if (!release || release.draft || release.prerelease || !Array.isArray(release.assets)) continue;
    const manifest = release.assets.find((asset) => asset?.name === WINDOWS_MANIFEST_NAME);
    if (!manifest?.browser_download_url) continue;

    const manifestURL = new URL(manifest.browser_download_url);
    if (manifestURL.protocol !== "https:" || !manifestURL.href.startsWith(WINDOWS_DOWNLOAD_PREFIX)) {
      throw new Error("GitHub returned an unsafe Windows update URL.");
    }
    return {
      tag: String(release.tag_name || ""),
      feedURL: new URL("./", manifestURL).href,
    };
  }

  throw new Error("No published Windows release contains latest.yml.");
}

function conciseUpdaterError(error) {
  const message = String(error?.message || "Update check failed").split(/\r?\n/, 1)[0].trim();
  if (/latest\.yml/i.test(message) && /404|not found/i.test(message)) {
    return "The Windows update feed is temporarily unavailable.";
  }
  return message.length > 240 ? `${message.slice(0, 237)}...` : message;
}

module.exports = {
  RELEASES_API_URL,
  conciseUpdaterError,
  resolveWindowsUpdateFeed,
};
