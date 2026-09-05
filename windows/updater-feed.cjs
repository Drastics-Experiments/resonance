const { allowsMacUpdateURL, trustedFetch } = require("./mac-update.cjs");
const { readResponseJSON, readResponseText } = require("./response-body.cjs");

const RELEASES_API_URL = "https://api.github.com/repos/Drastics-Experiments/resonance/releases?per_page=100";
const WINDOWS_MANIFEST_NAME = "latest.yml";
const MAC_MANIFEST_NAME = "latest-mac.json";
const WINDOWS_DOWNLOAD_PREFIX = "https://github.com/Drastics-Experiments/resonance/releases/download/";
const MAX_RELEASE_LIST_RESPONSE_BYTES = 2 * 1024 * 1024;
const MAX_WINDOWS_MANIFEST_BYTES = 256 * 1024;
const WINDOWS_UPDATE_HOSTS = new Set([
  "api.github.com", "github.com", "objects.githubusercontent.com",
  "release-assets.githubusercontent.com", "github-releases.githubusercontent.com",
]);
const RELEASE_TAG_PATTERN = /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?:-pre\.([1-9]\d{9,11}))?$/;

function parseWindowsReleaseTag(value) {
  const tag = String(value || "").trim();
  const match = RELEASE_TAG_PATTERN.exec(tag);
  if (!match) return null;
  const sourceTimestamp = match[2] ? Number(match[2]) : null;
  if (sourceTimestamp !== null && (!Number.isSafeInteger(sourceTimestamp) || sourceTimestamp <= 0)) return null;
  return Object.freeze({
    tag,
    baseVersion: match[1],
    prerelease: sourceTimestamp !== null,
    sourceTimestamp,
    effectiveVersion: sourceTimestamp === null ? match[1] : `${match[1]}-pre.${match[2]}`,
  });
}

function compareBaseVersions(leftValue, rightValue) {
  const left = String(leftValue || "").split(".").map(Number);
  const right = String(rightValue || "").split(".").map(Number);
  if (left.length !== 3 || right.length !== 3 || left.some((part) => !Number.isSafeInteger(part)) || right.some((part) => !Number.isSafeInteger(part))) return 0;
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] > right[index] ? 1 : -1;
  }
  return 0;
}

function positiveBuild(value, { allowMissing = false } = {}) {
  const text = String(value ?? "").trim();
  if (!text && allowMissing) return 0;
  if (!/^\d{1,10}$/.test(text)) return null;
  const build = Number(text);
  return Number.isSafeInteger(build) && build >= 0 ? build : null;
}

function compareWindowsReleaseCandidates(left, right) {
  const leftTag = parseWindowsReleaseTag(left?.tag || left?.releaseTag);
  const rightTag = parseWindowsReleaseTag(right?.tag || right?.releaseTag);
  if (!leftTag || !rightTag) return 0;
  const versionResult = compareBaseVersions(leftTag.baseVersion, rightTag.baseVersion);
  if (versionResult) return versionResult;
  if (leftTag.prerelease !== rightTag.prerelease) return leftTag.prerelease ? -1 : 1;
  const leftBuild = positiveBuild(left?.build, { allowMissing: true }) || 0;
  const rightBuild = positiveBuild(right?.build, { allowMissing: true }) || 0;
  if (leftBuild !== rightBuild) return leftBuild > rightBuild ? 1 : -1;
  const leftTimestamp = leftTag.sourceTimestamp || 0;
  const rightTimestamp = rightTag.sourceTimestamp || 0;
  if (leftTimestamp !== rightTimestamp) return leftTimestamp > rightTimestamp ? 1 : -1;
  return leftTag.tag === rightTag.tag ? 0 : leftTag.tag > rightTag.tag ? 1 : -1;
}

function releaseAssetURL(value, tag, assetName) {
  let url;
  try { url = new URL(String(value || "")); } catch { return null; }
  if (!allowsMacUpdateURL(url, WINDOWS_UPDATE_HOSTS)) return null;
  const expectedURL = `${WINDOWS_DOWNLOAD_PREFIX}${tag}/${assetName}`;
  if (url.search || url.hash || url.href !== expectedURL) return null;
  return url;
}

function yamlValue(text, key) {
  const expression = new RegExp(`^${key}:\\s*(?:"([^"]*)"|'([^']*)'|([^#\\s]+))\\s*$`, "m");
  const match = expression.exec(String(text || ""));
  return match ? (match[1] ?? match[2] ?? match[3] ?? "") : null;
}

function parseWindowsUpdateManifest(text) {
  const version = yamlValue(text, "version");
  const buildText = yamlValue(text, "resonanceBuild");
  const build = buildText === null ? 0 : positiveBuild(buildText);
  if (!version || build === null) return null;
  return Object.freeze({ version, build });
}

async function fetchReleaseList(fetchImpl) {
  const response = await trustedFetch(RELEASES_API_URL, {
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Cache-Control": "no-cache",
    },
  }, { fetchImpl, allowedHosts: WINDOWS_UPDATE_HOSTS });
  if (!response?.ok) throw new Error(`GitHub release lookup failed with HTTP ${response?.status || 0}.`);
  const releases = await readResponseJSON(response, MAX_RELEASE_LIST_RESPONSE_BYTES, "GitHub release list");
  if (!Array.isArray(releases)) throw new Error("GitHub returned an invalid release list.");
  return releases;
}

async function releaseManifestCandidates(manifestName, fetchImpl, { prerelease = false } = {}) {
  const releases = await fetchReleaseList(fetchImpl);
  return releases
    .filter((release) => release && !release.draft && Boolean(release.prerelease) === Boolean(prerelease) && Array.isArray(release.assets))
    .map((release) => ({ release, tag: parseWindowsReleaseTag(release.tag_name) }))
    .filter(({ release, tag }) => tag && tag.prerelease === Boolean(release.prerelease))
    .map(({ release, tag }) => {
      const asset = release.assets.find((candidate) => candidate?.name === manifestName);
      const manifestURL = releaseAssetURL(asset?.browser_download_url, tag.tag, manifestName);
      return manifestURL ? { tag, manifestURL } : null;
    })
    .filter(Boolean)
    .sort((left, right) => compareWindowsReleaseCandidates({ tag: right.tag.tag }, { tag: left.tag.tag }));
}

async function fetchWindowsUpdateManifest(manifestURL, fetchImpl) {
  const response = await trustedFetch(manifestURL, {
    headers: { Accept: "text/yaml, text/plain", "Cache-Control": "no-cache" },
  }, { fetchImpl, allowedHosts: WINDOWS_UPDATE_HOSTS });
  if (!response?.ok) throw new Error(`The Windows update manifest returned HTTP ${response?.status || 0}.`);
  return readResponseText(response, MAX_WINDOWS_MANIFEST_BYTES, "The Windows update manifest");
}

async function resolveWindowsUpdateFeed(fetchImpl = fetch, options = {}) {
  const candidates = await releaseManifestCandidates(WINDOWS_MANIFEST_NAME, fetchImpl, options);
  for (const { tag, manifestURL } of candidates) {
    try {
      const manifest = parseWindowsUpdateManifest(await fetchWindowsUpdateManifest(manifestURL.href, fetchImpl));
      if (!manifest || manifest.version !== tag.effectiveVersion) continue;
      return Object.freeze({
        tag: tag.tag,
        feedURL: new URL("./", manifestURL).href,
        version: manifest.version,
        baseVersion: tag.baseVersion,
        build: manifest.build,
        prerelease: tag.prerelease,
        sourceTimestamp: tag.sourceTimestamp,
      });
    } catch {
      // An incomplete release must not hide an older usable release in the same channel.
    }
  }
  const channel = options.prerelease ? "prerelease" : "stable release";
  throw new Error(`No published ${channel} contains ${WINDOWS_MANIFEST_NAME}.`);
}

async function resolveMacUpdateManifest(fetchImpl = fetch, options = {}) {
  const candidates = await releaseManifestCandidates(MAC_MANIFEST_NAME, fetchImpl, options);
  const candidate = candidates[0];
  if (!candidate) {
    const channel = options.prerelease ? "prerelease" : "stable release";
    throw new Error(`No published ${channel} contains ${MAC_MANIFEST_NAME}.`);
  }
  return Object.freeze({ tag: candidate.tag.tag, manifestURL: candidate.manifestURL.href });
}

async function fetchWindowsUpdateVersion(manifestURL, fetchImpl = fetch) {
  let url;
  try { url = new URL(String(manifestURL)); } catch { throw new Error("The Windows update manifest URL is invalid."); }
  const tag = url.pathname.split("/").at(-2);
  if (!releaseAssetURL(url.href, tag, WINDOWS_MANIFEST_NAME)) throw new Error("The Windows update manifest URL is unsafe.");
  const manifest = parseWindowsUpdateManifest(await fetchWindowsUpdateManifest(url.href, fetchImpl));
  if (!manifest?.version) throw new Error("The Windows update manifest has no version.");
  return manifest.version;
}

function conciseUpdaterError(error) {
  const message = String(error?.message || "Update check failed").split(/\r?\n/, 1)[0].trim();
  if (/latest\.yml/i.test(message) && /404|not found/i.test(message)) return "The Windows update feed is temporarily unavailable.";
  return message.length > 240 ? `${message.slice(0, 237)}...` : message;
}

function installDownloadedWindowsUpdate(updater) {
  updater.quitAndInstall(true, true);
  return true;
}

module.exports = {
  RELEASES_API_URL,
  WINDOWS_MANIFEST_NAME,
  MAX_RELEASE_LIST_RESPONSE_BYTES,
  MAX_WINDOWS_MANIFEST_BYTES,
  conciseUpdaterError,
  compareWindowsReleaseCandidates,
  fetchWindowsUpdateVersion,
  installDownloadedWindowsUpdate,
  parseWindowsReleaseTag,
  parseWindowsUpdateManifest,
  resolveMacUpdateManifest,
  resolveWindowsUpdateFeed,
};
